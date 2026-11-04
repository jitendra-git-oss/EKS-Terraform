terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

############################
# VARIABLES
############################

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for resources"
}

variable "cluster_name" {
  type        = string
  default     = "naresh"
  description = "EKS cluster name"
}

variable "cluster_version" {
  type        = string
  default     = "1.31"
  description = "Kubernetes control plane version"
}

variable "github_actions_role_arn" {
  type        = string
  default     = "arn:aws:iam::392211784798:role/GitHubActionsRole-K8"
  description = "IAM role ARN assumed by GitHub Actions for cluster administration"
}

############################
# VPC & INTERNET GATEWAY
############################

resource "aws_vpc" "eks_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "eks-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eks_vpc.id

  tags = {
    Name = "eks-igw"
  }
}

############################
# SUBNETS
############################

resource "aws_subnet" "public1" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "eks-public-1a"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "public2" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "eks-public-1b"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private1" {
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name                                        = "eks-private-1a"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private2" {
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "${var.aws_region}b"

  tags = {
    Name                                        = "eks-private-1b"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

############################
# NAT GATEWAY & EIP
############################

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "eks-nat-eip"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public1.id

  tags = {
    Name = "eks-nat-gw"
  }

  depends_on = [aws_internet_gateway.igw]
}

############################
# ROUTE TABLES
############################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "eks-public-rt"
  }
}

resource "aws_route_table_association" "pub1" {
  subnet_id      = aws_subnet.public1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "pub2" {
  subnet_id      = aws_subnet.public2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "eks-private-rt"
  }
}

resource "aws_route_table_association" "priv1" {
  subnet_id      = aws_subnet.private1.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "priv2" {
  subnet_id      = aws_subnet.private2.id
  route_table_id = aws_route_table.private.id
}

############################
# SECURITY GROUPS
############################

resource "aws_security_group" "bastion_sg" {
  name        = "bastion-sg"
  description = "Security group for bastion instance"
  vpc_id      = aws_vpc.eks_vpc.id

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "bastion-sg"
  }
}

############################
# IAM ROLES - CONTROL PLANE & NODES
############################

resource "aws_iam_role" "cluster_role" {
  name = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "worker_role" {
  name = "eks-worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "worker_node" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

############################
# EKS CLUSTER
############################

resource "aws_eks_cluster" "eks" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster_role.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids = [
      aws_subnet.private1.id,
      aws_subnet.private2.id,
      aws_subnet.public1.id,
      aws_subnet.public2.id
    ]

    endpoint_public_access = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]
}

############################
# EKS ACCESS ENTRIES (AUTHENTICATION / RBAC)
############################

resource "aws_eks_access_entry" "github_actions" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = var.github_actions_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_actions_admin" {
  cluster_name  = aws_eks_cluster.eks.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_eks_access_entry.github_actions.principal_arn

  access_scope {
    type = "cluster"
  }
}

############################
# IAM OIDC PROVIDER (IRSA)
############################

data "tls_certificate" "eks" {
  url = aws_eks_cluster.eks.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.eks.identity[0].oidc[0].issuer
}

############################
# NODE GROUP
############################

resource "aws_eks_node_group" "node_group" {
  cluster_name    = aws_eks_cluster.eks.name
  node_group_name = "eks-node-group"
  node_role_arn   = aws_iam_role.worker_role.arn
  version         = var.cluster_version

  subnet_ids = [
    aws_subnet.private1.id,
    aws_subnet.private2.id
  ]

  instance_types = ["c7i-flex.large"]

  scaling_config {
    desired_size = 4
    max_size     = 6
    min_size     = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_node,
    aws_iam_role_policy_attachment.cni,
    aws_iam_role_policy_attachment.ecr
  ]

  tags = {
    Name        = "eks-node"
    Environment = "dev"
    Project     = "eks-project"
    Owner       = "veeraops"
  }
}

############################
# BASTION HOST
############################

resource "aws_instance" "eks" {
  ami                    = "ami-0c230065b91270bc6"
  instance_type          = "c7i-flex.large"
  subnet_id              = aws_subnet.public1.id
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]

  root_block_device {
    volume_size = 30
  }

  tags = {
    Name = "eks-bastion"
  }

  user_data = <<-EOF
              #!/bin/bash
              yum update -y

              # Install stable kubectl
              KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
              curl -LO "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
              chmod +x kubectl
              mv kubectl /usr/local/bin/kubectl

              # Install eksctl
              curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
              mv /tmp/eksctl /usr/local/bin/eksctl
              EOF
}

############################
# EKS CORE ADD-ONS
############################

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.eks.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.node_group]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.eks.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.node_group]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.eks.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.node_group]
}

############################
# EBS CSI DRIVER (VIA IRSA / OIDC)
############################

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "ebs_csi_role" {
  name               = "AmazonEKS_EBS_CSI_DriverRole"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.eks.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.ebs_csi_role.arn

  depends_on = [
    aws_eks_node_group.node_group,
    aws_iam_role_policy_attachment.ebs_csi_policy
  ]
}

############################
# OUTPUTS
############################

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.eks.endpoint
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = aws_eks_cluster.eks.name
}

output "bastion_public_ip" {
  description = "Public IP of the bastion instance"
  value       = aws_instance.eks.public_ip
}
