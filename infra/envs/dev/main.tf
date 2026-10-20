data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# 1. VPC – dùng module chính thức để giảm lỗi cấu hình
# single_nat_gateway = true: tiết kiệm ~$32/tháng so với multi-NAT
# Trong prod, nên bật enable_nat_gateway = true + single_nat_gateway = false
# ---------------------------------------------------------------------------
module "vpc" {
  # terraform-aws-modules/vpc/aws v5.x – stable, được AWS dùng trong workshop chính thức
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = var.azs

  # /20 mỗi AZ: 4094 địa chỉ – đủ cho node + pod IP (VPC CNI dùng nhiều IP)
  private_subnets = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 4, i + length(var.azs))]

  enable_nat_gateway   = true
  single_nat_gateway   = true # 1 NAT để tiết kiệm chi phí cho đồ án
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tag để AWS Load Balancer Controller tự phát hiện subnet đúng loại
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = {
    Project     = "multiaz-autoscaling"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------------------------
# 2. EKS Cluster – module chính thức v20.x
# ---------------------------------------------------------------------------
module "eks" {
  # v20.x hỗ trợ access entries (thay aws-auth ConfigMap deprecated từ 1.29+)
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.26"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  # Public endpoint cho phép kubectl từ máy local (cần cho đồ án)
  # Giới hạn CIDR qua biến cluster_endpoint_public_access_cidrs để tăng bảo mật
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets # Node chạy trong private subnet

  # OIDC provider – bật IRSA (IAM Roles for Service Accounts)
  enable_irsa = true

  # ---------------------------------------------------------------------------
  # EKS Managed Add-ons – AWS quản lý lifecycle, tự động patch security
  # ---------------------------------------------------------------------------
  cluster_addons = {
    vpc-cni = {
      # "most_recent" trong module context = addon version mới nhất compatible
      most_recent = true
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
  }

  # ---------------------------------------------------------------------------
  # Managed Node Group – chạy trong cả 2 private subnet để đảm bảo Multi-AZ
  # ---------------------------------------------------------------------------
  eks_managed_node_groups = {
    main = {
      name = "${var.cluster_name}-ng"

      # Đặt node vào cả 2 private subnet → EKS sẽ phân bổ đều 2 AZ
      subnet_ids = module.vpc.private_subnets

      # AL2023 là AMI mặc định từ EKS 1.30+; AL2_x86_64 không còn được hỗ trợ
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.instance_types
      capacity_type  = var.capacity_type # ON_DEMAND mặc định

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size

      # IMDSv2 bắt buộc – bảo mật tốt hơn IMDSv1
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      labels = {
        "role" = "worker"
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Access Entries – cấp cluster-admin cho người chạy Terraform và thành viên nhóm
  # Dùng access entries (API mới) thay aws-auth ConfigMap (deprecated EKS 1.29+)
  # ---------------------------------------------------------------------------
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    for arn in var.admin_principal_arns : arn => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  tags = {
    Project     = "multiaz-autoscaling"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------------------------
# 3. ALB Controller – IAM Policy
# Tải policy chính thức từ repo kubernetes-sigs; ghim SHA để tránh thay đổi ngoài ý muốn
# ---------------------------------------------------------------------------
data "http" "alb_controller_policy" {
  # v2.8.3 – phiên bản stable tương ứng chart 1.8.3
  # Xem: https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.3/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "alb_controller" {
  name        = "${var.cluster_name}-alb-controller-policy"
  description = "IAM policy cho AWS Load Balancer Controller (phiên bản v2.8.3)"
  policy      = data.http.alb_controller_policy.response_body

  tags = {
    Project     = "multiaz-autoscaling"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# IRSA role cho ALB Controller service account
resource "aws_iam_role" "alb_controller" {
  name = "${var.cluster_name}-alb-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Project     = "multiaz-autoscaling"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ---------------------------------------------------------------------------
# 4. ALB Controller – Helm Release
# Chart: aws-load-balancer-controller từ eks-charts repo
# Ghim version 1.8.3 tương ứng controller v2.8.3
# ---------------------------------------------------------------------------
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_version # "1.8.3"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller.arn
  }

  # Chờ tất cả pod của controller Ready trước khi terraform xem là xong
  wait    = true
  timeout = 300

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.alb_controller,
  ]
}

# ---------------------------------------------------------------------------
# 5. SQS Queue + DLQ
# ---------------------------------------------------------------------------
module "sqs" {
  source = "../../modules/sqs"

  queue_name                 = var.sqs_queue_name
  visibility_timeout_seconds = var.sqs_visibility_timeout
  receive_wait_time_seconds  = var.sqs_receive_wait_time
  max_receive_count          = 3
}

# ---------------------------------------------------------------------------
# 6a. IRSA – API Service (namespace: app, sa: api)
# Quyền: SendMessage + GetQueueAttributes trên jobs-queue cụ thể (least privilege)
# ---------------------------------------------------------------------------
module "irsa_api" {
  source = "../../modules/irsa"

  role_name            = "${var.cluster_name}-irsa-api"
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider
  namespace            = "app"
  service_account_name = "api"

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSSendMessage"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes",
        ]
        # Giới hạn theo ARN cụ thể – không dùng wildcard *
        Resource = module.sqs.queue_arn
      }
    ]
  })

  depends_on = [module.eks, module.sqs]
}

# ---------------------------------------------------------------------------
# 6b. IRSA – Worker Service (namespace: app, sa: worker)
# Quyền: Receive + Delete + ChangeVisibility + GetAttributes trên jobs-queue
# ---------------------------------------------------------------------------
module "irsa_worker" {
  source = "../../modules/irsa"

  role_name            = "${var.cluster_name}-irsa-worker"
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider
  namespace            = "app"
  service_account_name = "worker"

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSWorkerAccess"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility",
          "sqs:GetQueueAttributes",
        ]
        Resource = module.sqs.queue_arn
      }
    ]
  })

  depends_on = [module.eks, module.sqs]
}

# ---------------------------------------------------------------------------
# 6c. IRSA – KEDA Operator (namespace: keda, sa: keda-operator)
# Quyền: chỉ GetQueueAttributes để KEDA đọc queue depth và scale
# ---------------------------------------------------------------------------
module "irsa_keda" {
  source = "../../modules/irsa"

  role_name            = "${var.cluster_name}-irsa-keda"
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider
  namespace            = "keda"
  service_account_name = "keda-operator"

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KEDASQSRead"
        Effect = "Allow"
        Action = [
          "sqs:GetQueueAttributes",
        ]
        Resource = module.sqs.queue_arn
      }
    ]
  })

  depends_on = [module.eks, module.sqs]
}

# ---------------------------------------------------------------------------
# 7. KEDA – Helm Release (chỉ cài khi install_keda = true)
# Tắt mặc định vì Phase 3 mới dùng; IRSA role đã tạo sẵn ở trên
# ---------------------------------------------------------------------------
resource "helm_release" "keda" {
  count = var.install_keda ? 1 : 0

  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = var.keda_chart_version # "2.15.1"
  namespace  = "keda"

  create_namespace = true

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_keda.role_arn
  }

  wait    = true
  timeout = 300

  depends_on = [module.eks, module.irsa_keda]
}

# ---------------------------------------------------------------------------
# 8. ECR Repositories
# ---------------------------------------------------------------------------
module "ecr" {
  source = "../../modules/ecr"

  name_prefix      = var.ecr_name_prefix
  repository_names = ["api", "worker"]
}

# ---------------------------------------------------------------------------
# 9. AWS Budget
# ---------------------------------------------------------------------------
module "budget" {
  source = "../../modules/budget"

  monthly_budget_usd = var.monthly_budget_usd
  alert_emails       = var.alert_emails
  alert_thresholds   = [50, 80, 100]
}

# ---------------------------------------------------------------------------
# 10. Kubernetes Namespace "app" – tạo sẵn để K8s manifest có thể deploy vào
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "app" {
  metadata {
    name = "app"
    labels = {
      "managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}
