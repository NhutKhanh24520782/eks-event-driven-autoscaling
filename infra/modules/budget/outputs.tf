output "budget_name" {
  description = "Tên AWS Budget đã tạo"
  value       = aws_budgets_budget.monthly.name
}
