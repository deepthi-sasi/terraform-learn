module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.1.3"

  name = "myapp-eks-cluster"
  kubernetes_version = "1.33"
  endpoint_public_access  = true

  subnet_ids = module.myapp-vpc.private_subnets
  vpc_id = module.myapp-vpc.vpc_id

  enable_cluster_creator_admin_permissions = true  

  addons = {
    coredns                = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy             = {}
    vpc-cni                = {
      before_compute = true
    }
  }
  
  tags = {
    environment = "development"
    application = "myapp"
  }

  eks_managed_node_groups = {
    dev = {
    instance_types = ["t2.small"]
    ami_type       = "AL2023_x86_64_STANDARD"
    min_size       = 1
    max_size       = 3
    desired_size   = 3
    }
  }
}