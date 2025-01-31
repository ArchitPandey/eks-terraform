### Terraform code to do following things - ###

1. Configure an AWS Provider. Do following to configure terraform to pick aws credentials -
    1. export AWS_ACCESS_KEY_ID=your_aws_access_key
    2. export AWS_SECRET_ACCESS_KEY=your_aws_secret_access_key
2. Create a VPC with 3 public and 3 private subnets
3. Create an EKS cluster in the VPC using node groups (ec2 instances)
4. Creates a role for load balancer controller and attach it to k8s service account (ingress class)


4. Configure kubernetes and helm providers
5. Create kubernetes service account (the one load-balancer-controller is supposed to use)
6. Create a helm load-balancer-controller release (this installs the ingress controller 'alb' to eks clsuter)

7. to do -> create an deployment, service and ingress object using the terraform kubernetes resource (currently using k8s yml files to do this)