locals {
  common_tags = {
    Project     = "multiaz-autoscaling"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Dead-Letter Queue – nhận message sau maxReceiveCount lần thất bại
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  name = "${var.queue_name}-dlq"

  message_retention_seconds = 1209600 # 14 ngày – tối đa để debug
  tags                      = local.common_tags
}

# ---------------------------------------------------------------------------
# Main Queue
# visibility_timeout >= Lambda/Worker timeout; mặc định 60s
# receive_wait_time = 20s (long polling) giảm cost API call
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "main" {
  name                       = var.queue_name
  visibility_timeout_seconds = var.visibility_timeout_seconds
  receive_wait_time_seconds  = var.receive_wait_time_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = local.common_tags
}
