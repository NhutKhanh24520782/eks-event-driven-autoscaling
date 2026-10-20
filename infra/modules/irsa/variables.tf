variable "role_name" {
  description = "Tên IAM role sẽ được tạo (phải duy nhất trong AWS account)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN của OIDC provider của EKS cluster (từ module eks output)"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL của OIDC provider (không có prefix https://, ví dụ: oidc.eks.ap-southeast-1.amazonaws.com/id/XXXX)"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace chứa service account (ví dụ: 'app', 'keda')"
  type        = string
}

variable "service_account_name" {
  description = "Tên Kubernetes service account sẽ assume role này"
  type        = string
}

variable "policy_json" {
  description = "IAM policy JSON string (dùng jsonencode() hoặc data.aws_iam_policy_document để tạo)"
  type        = string
}
