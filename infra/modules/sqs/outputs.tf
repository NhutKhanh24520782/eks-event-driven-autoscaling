output "queue_url" {
  description = "URL của main SQS queue (dùng trong ứng dụng)"
  value       = aws_sqs_queue.main.url
}

output "queue_arn" {
  description = "ARN của main SQS queue (dùng trong IAM policy)"
  value       = aws_sqs_queue.main.arn
}

output "dlq_url" {
  description = "URL của Dead-Letter Queue"
  value       = aws_sqs_queue.dlq.url
}

output "dlq_arn" {
  description = "ARN của Dead-Letter Queue"
  value       = aws_sqs_queue.dlq.arn
}
