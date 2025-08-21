module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.1.0"

  name    = "myapp-eks-cluster"
  kubernetes_version = "1.33"

  vpc_id     = module.myapp-vpc.vpc_id
  subnet_ids = module.myapp-vpc.private_subnets

  endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns   = {}
    kube-proxy = {}
    vpc-cni   = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    dev = {
      min_size     = 1
      max_size     = 3
      desired_size = 3
      instance_types = ["t2.small"]
    }
  }

  tags = {
    environment = "development"
    application = "myapp"
  }
}