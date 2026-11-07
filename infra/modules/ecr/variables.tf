variable "name_prefix" {
  description = "Prefix namespace cho ECR repository (ví dụ: 'multiaz-autoscaling')"
  type        = string
}

variable "repository_names" {
  description = "Danh sách tên repository cần tạo (ví dụ: ['api', 'worker'])"
  type        = list(string)
  default     = ["api", "worker"]
}
