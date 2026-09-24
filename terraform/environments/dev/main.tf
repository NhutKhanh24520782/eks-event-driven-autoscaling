# TODO: Call modules (vpc, eks, alb, sqs, iam) for dev environment
module "vpc" {
  source = "../../modules/vpc"
  # ...
}

module "eks" {
  source = "../../modules/eks"
  # ...
}

module "sqs" {
  source = "../../modules/sqs"
  # ...
}

module "alb" {
  source = "../../modules/alb"
  # ...
}

module "iam" {
  source = "../../modules/iam"
  # ...
}
