output "state_bucket_name" {
  description = "Tên S3 bucket lưu Terraform remote state"
  value       = aws_s3_bucket.tf_state.id
}

output "state_bucket_arn" {
  description = "ARN của S3 bucket remote state"
  value       = aws_s3_bucket.tf_state.arn
}

output "lock_table_name" {
  description = "Tên DynamoDB table dùng làm Terraform state lock"
  value       = aws_dynamodb_table.tf_lock.name
}

output "backend_config_hint" {
  description = "Đoạn backend config cần copy vào envs/dev/backend.tf"
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.tf_state.id}"
        key            = "envs/dev/terraform.tfstate"
        region         = "${var.region}"
        dynamodb_table = "${aws_dynamodb_table.tf_lock.name}"
        encrypt        = true
      }
    }
  EOT
}
