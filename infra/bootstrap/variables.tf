variable "region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name, used to namespace S3 bucket and DynamoDB table"
  type        = string
  default     = "multiaz-autoscaling"
}
