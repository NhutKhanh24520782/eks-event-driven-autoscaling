variable "queue_name" {
  description = "Tên của main SQS queue (DLQ sẽ được tự động đặt tên <queue_name>-dlq)"
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "Thời gian (giây) message bị ẩn sau khi consumer nhận; phải >= timeout của Worker"
  type        = number
  default     = 60
}

variable "receive_wait_time_seconds" {
  description = "Long polling: thời gian chờ tối đa (giây) khi queue trống, giảm số API call"
  type        = number
  default     = 20
}

variable "max_receive_count" {
  description = "Số lần nhận tối đa trước khi message chuyển sang DLQ"
  type        = number
  default     = 3
}
