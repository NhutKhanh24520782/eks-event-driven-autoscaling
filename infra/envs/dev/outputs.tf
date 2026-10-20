output "cluster_name" {
  description = "Tên EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = module.eks.cluster_endpoint
}

output "region" {
  description = "AWS region đang dùng"
  value       = var.region
}

output "vpc_id" {
  description = "ID của VPC"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Danh sách ID của private subnet (node EKS chạy ở đây)"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Danh sách ID của public subnet (ALB tạo ở đây)"
  value       = module.vpc.public_subnets
}

output "queue_url" {
  description = "URL của SQS main queue (jobs-queue)"
  value       = module.sqs.queue_url
}

output "queue_arn" {
  description = "ARN của SQS main queue"
  value       = module.sqs.queue_arn
}

output "dlq_url" {
  description = "URL của Dead-Letter Queue"
  value       = module.sqs.dlq_url
}

output "dlq_arn" {
  description = "ARN của Dead-Letter Queue"
  value       = module.sqs.dlq_arn
}

output "ecr_api_url" {
  description = "ECR repository URL cho api service (dùng để docker push)"
  value       = module.ecr.repository_urls["api"]
}

output "ecr_worker_url" {
  description = "ECR repository URL cho worker service"
  value       = module.ecr.repository_urls["worker"]
}

output "api_role_arn" {
  description = "IAM role ARN để annotate vào service account 'app/api'"
  value       = module.irsa_api.role_arn
}

output "worker_role_arn" {
  description = "IAM role ARN để annotate vào service account 'app/worker'"
  value       = module.irsa_worker.role_arn
}

output "keda_role_arn" {
  description = "IAM role ARN chuẩn bị cho KEDA operator (Phase 3)"
  value       = module.irsa_keda.role_arn
}

output "kubeconfig_command" {
  description = "Lệnh cập nhật kubeconfig để kubectl kết nối vào cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
