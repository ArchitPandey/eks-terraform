terraform {
  required_providers {
    aws = {
        source = "hashicorp/aws"
        version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "my-eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = data.aws_availability_zones.available.names
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  enable_vpn_gateway = true

  tags = {
    Terraform = "true"
    Environment = "dev"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
}

locals {
  vpc_id              = module.vpc.vpc_id
  vpc_cidr            = module.vpc.vpc_cidr_block
  public_subnets_ids  = module.vpc.public_subnets
  private_subnets_ids = module.vpc.private_subnets
  subnets_ids         = concat(local.public_subnets_ids, local.private_subnets_ids)
}


################
#  EKS MODULE  #
################

# find ami of amazon linux 2023 ami
data "aws_ami" "eks_ami" {
    most_recent = true

    filter {
      name = "image-id"
      values = ["ami-0df8c184d5f6ae949"]
    }
}

# do we need to add autoscaling policies to the nodegroup ?
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "my-eks-cluster"
  cluster_version = "1.31"

  cluster_endpoint_public_access = true

  # Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent              = true
      before_compute           = true
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
      configuration_values = jsonencode({
        env = {
          # Reference docs https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
  }

  vpc_id                   = local.vpc_id
  subnet_ids               = local.private_subnets_ids
  control_plane_subnet_ids = local.private_subnets_ids

  # EKS Managed Node Group(s)
  eks_managed_node_group_defaults = {
    ami_type                   = "AL2_x86_64"
    instance_types             = ["t2.micro"]
    iam_role_attach_cni_policy = true
  }

  eks_managed_node_groups = {
    my_node_grp = {
      min_size     = 3
      max_size     = 4
      desired_size = 3
    }
  }

}


################################
#  ROLES FOR SERVICE ACCOUNTS  #
################################

module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name_prefix      = "VPC-CNI-IRSA"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
}


# role for load balancer controller
module "lb_role" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "my_eks_lb_role"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# retrieve eks cluster information to setup kubernetes connection to eks cluster
locals {
    cluster_name = module.eks.cluster_name
    cluster_endpoint = module.eks.cluster_endpoint
    cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
}

data "aws_eks_cluster_auth" "my_eks_cluster_auth" {
    name = local.cluster_name
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name]
    command     = "aws"
  }
}

resource "kubernetes_service_account" "eks_load_balancer_controller_sa" {
  metadata {
    name = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
        "app.kubernetes.io/name"= "aws-load-balancer-controller"
        "app.kubernetes.io/component"= "controller"
    }
    annotations = {
      "eks.amazonaws.com/role-arn" = module.lb_role.iam_role_arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
    }
  }

  depends_on = [module.eks]
}

# helm provider to install load balancer controller helm chart
provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_certificate_authority_data)
    exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name]
    command     = "aws"
  }
  }
}

resource "helm_release" "lb-controller" {
    name = "lb-controller-release"
    repository = "https://aws.github.io/eks-charts"
    chart = "aws-load-balancer-controller"
    namespace  = "kube-system"
    depends_on = [kubernetes_service_account.eks_load_balancer_controller_sa]

    set {
        name = "image.repository"
        value = "602401143452.dkr.ecr.us-east-1.amazonaws.com/amazon/aws-load-balancer-controller"
    }

    set {
            name = "serviceAccount.create"
            value = "false"
    }

    set {
            name = "serviceAccount.name"
            value = "aws-load-balancer-controller"
    }

    set {
        name = "clusterName"
        value = "my-eks-cluster"

    }

    set {
        name = "region"
        value = "us-east-1"
    }

    set {
        name = "vpcId"
        value = local.vpc_id
    }

}

# create ingress controller via tf so it can destroy it and associated security groups. this also helps tf in completing destroy of public subnet and vpc cause without ALB destroy those
# always show pending delete