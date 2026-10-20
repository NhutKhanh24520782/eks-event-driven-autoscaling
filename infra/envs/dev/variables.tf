variable "region" {
  description = "AWS region để triển khai toàn bộ hệ thống"
  type        = string
  default     = "ap-southeast-1"
}

variable "cluster_name" {
  description = "Tên EKS cluster"
  type        = string
  default     = "multiaz-eks"
}

variable "kubernetes_version" {
  description = "Phiên bản Kubernetes của EKS cluster (khuyến nghị dùng bản mới nhất được AWS hỗ trợ)"
  type        = string
  default     = "1.30"
}

variable "azs" {
  description = "Danh sách AZ (mặc định 2 AZ đầu của ap-southeast-1: 1a và 1b)"
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
}

variable "vpc_cidr" {
  description = "CIDR block cho VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "instance_types" {
  description = "Loại EC2 cho node group (t3.medium: 2vCPU 4GB, đủ cho KEDA+api+worker)"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "capacity_type" {
  description = "Loại capacity: ON_DEMAND (ổn định) hoặc SPOT (rẻ hơn ~60% nhưng có thể bị thu hồi)"
  type        = string
  default     = "ON_DEMAND"
}

variable "node_min_size" {
  description = "Số node tối thiểu trong managed node group"
  type        = number
  default     = 2
}

variable "node_desired_size" {
  description = "Số node mong muốn khi khởi tạo"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Số node tối đa (CA/KEDA có thể scale đến đây)"
  type        = number
  default     = 4
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Danh sách CIDR được phép gọi Kubernetes API (mặc định mở, nên giới hạn IP công ty/nhà)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "admin_principal_arns" {
  description = "Danh sách IAM user/role ARN cần cấp cluster-admin (thêm ARN của 3 thành viên nhóm)"
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# ALB Controller
# ---------------------------------------------------------------------------
variable "alb_controller_version" {
  description = "Phiên bản Helm chart aws-load-balancer-controller (ghim để tránh breaking change)"
  type        = string
  # 1.8.x là stable tại thời điểm viết; kiểm tra https://github.com/aws/eks-charts/releases
  default     = "1.8.3"
}

# ---------------------------------------------------------------------------
# SQS
# ---------------------------------------------------------------------------
variable "sqs_queue_name" {
  description = "Tên SQS queue chính (DLQ sẽ là <name>-dlq)"
  type        = string
  default     = "jobs-queue"
}

variable "sqs_visibility_timeout" {
  description = "Visibility timeout (giây) của SQS queue; nên >= timeout xử lý của Worker"
  type        = number
  default     = 60
}

variable "sqs_receive_wait_time" {
  description = "Long polling wait time (giây) giảm số API call khi queue trống"
  type        = number
  default     = 20
}

# ---------------------------------------------------------------------------
# KEDA (Phase 3 – tắt mặc định)
# ---------------------------------------------------------------------------
variable "install_keda" {
  description = "Có cài KEDA bằng Helm hay không (bật ở Phase 3)"
  type        = bool
  default     = false
}

variable "keda_chart_version" {
  description = "Phiên bản Helm chart KEDA (chỉ dùng khi install_keda = true)"
  type        = string
  # 2.15.x là stable tại thời điểm viết; kiểm tra https://github.com/kedacore/charts/releases
  default     = "2.15.1"
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------
variable "ecr_name_prefix" {
  description = "Prefix namespace cho ECR repository (ví dụ: 'multiaz-autoscaling')"
  type        = string
  default     = "multiaz-autoscaling"
}

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------
variable "monthly_budget_usd" {
  description = "Ngưỡng ngân sách tháng (USD) để gửi cảnh báo email"
  type        = string
  default     = "50"
}

variable "alert_emails" {
  description = "Danh sách email nhận cảnh báo chi phí (bắt buộc điền)"
  type        = list(string)
  default     = []
}
