locals {
  common_tags = {
    Project     = "multiaz-autoscaling"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------------------------
# ECR Repositories: api và worker
# scan_on_push: phát hiện CVE ngay khi push image, miễn phí với Enhanced Scanning
# image_tag_mutability = MUTABLE: cho phép overwrite tag (tiện dev, prod nên IMMUTABLE)
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "repos" {
  for_each = toset(var.repository_names)

  name                 = "${var.name_prefix}/${each.key}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Lifecycle Policy – giữ 10 image mới nhất để tiết kiệm storage
# ---------------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "repos" {
  for_each = aws_ecr_repository.repos

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Giữ tối đa 10 image mới nhất, xoá image cũ hơn"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
