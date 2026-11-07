variable "monthly_budget_usd" {
  description = "Ngưỡng ngân sách hàng tháng tính bằng USD (cảnh báo khi đạt % threshold)"
  type        = string
  default     = "50"
}

variable "alert_emails" {
  description = "Danh sách email nhận cảnh báo khi chi phí vượt ngưỡng"
  type        = list(string)
}

variable "alert_thresholds" {
  description = "Danh sách % ngưỡng cảnh báo (mặc định: 50%, 80%, 100%)"
  type        = list(number)
  default     = [50, 80, 100]
}
