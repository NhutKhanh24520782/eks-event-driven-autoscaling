output "role_arn" {
  description = "ARN của IAM role được tạo (annotate vào Kubernetes service account)"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Tên IAM role được tạo"
  value       = aws_iam_role.this.name
}
