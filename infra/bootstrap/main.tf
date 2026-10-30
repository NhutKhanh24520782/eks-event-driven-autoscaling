data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# S3 Bucket – lưu Terraform remote state
# Tên bucket ghép account_id để đảm bảo toàn cầu duy nhất và idempotent
# (chạy lại bootstrap không sinh bucket mới)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "tf_state" {
  # Tên tối đa 63 ký tự; account_id = 12 chữ số
  bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"

  # Ngăn xóa nhầm bucket khi destroy bootstrap
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Chỉ Terraform state mới được đọc/ghi – không ai khác
resource "aws_s3_bucket_policy" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonSSL"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.tf_state.arn,
          "${aws_s3_bucket.tf_state.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.tf_state]
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "${var.project}-tflock"
  billing_mode = "PAY_PER_REQUEST" # On-demand; phù hợp tần suất thấp của sinh viên
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
