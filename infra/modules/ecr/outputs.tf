output "repository_urls" {
  description = "Map từ tên repo sang URL đầy đủ (dùng để docker push)"
  value       = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}

output "repository_arns" {
  description = "Map từ tên repo sang ARN"
  value       = { for k, v in aws_ecr_repository.repos : k => v.arn }
}
