resource "aws_budgets_budget" "monthly" {
  name         = "multiaz-autoscaling-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # ---------------------------------------------------------------------------
  # Notification – 3 mức cảnh báo: 50%, 80%, 100% để kịp thời xử lý
  # ---------------------------------------------------------------------------
  dynamic "notification" {
    for_each = var.alert_thresholds

    content {
      comparison_operator = "GREATER_THAN"
      threshold           = notification.value
      threshold_type      = "PERCENTAGE"
      notification_type   = "ACTUAL"

      subscriber_email_addresses = var.alert_emails
    }
  }
}
