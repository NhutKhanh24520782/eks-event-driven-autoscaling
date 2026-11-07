terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # http provider: tải ALB Controller IAM policy JSON từ GitHub (ghim phiên bản controller)
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    # kubernetes provider: cấu hình cluster sau khi EKS tạo xong
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    # helm provider: cài ALB Controller và tùy chọn KEDA
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }

  # ---------------------------------------------------------------------------
  # Backend S3 – sau khi chạy bootstrap, copy output backend_config_hint vào đây
  # Hoặc chạy: terraform init -backend-config=backend.hcl
  # ---------------------------------------------------------------------------
  backend "s3" {
    # Các giá trị này được điền sau khi chạy bootstrap
    bucket         = "multiaz-autoscaling-tfstate-274118253913"
    key            = "envs/dev/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "multiaz-autoscaling-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "multiaz-autoscaling"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.region,
    ]
  }
}

provider "helm" {
  # Dùng cache riêng trong thư mục .terraform để không phụ thuộc
  # vào helm repo add đã chạy trước hay chưa trên máy local
  repository_cache      = "${path.module}/.terraform/helm_cache"
  repository_config_path = "${path.module}/.terraform/helm_repositories.yaml"

  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.region,
      ]
    }
  }
}
