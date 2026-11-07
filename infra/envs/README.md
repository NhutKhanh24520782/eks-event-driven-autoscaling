# Terraform Environments

Environment-specific Terraform root modules live here. The repository
currently contains [`dev/`](dev/README.md), which provisions the EKS
development environment.

Keep environment-specific values in untracked `terraform.tfvars` files. Share
only reviewed examples and defaults; do not copy credentials, account-specific
secrets, or state files between environments.

## Follow-up work

- Add isolated staging/production environments only when their resource,
  account, state, and access boundaries are defined.
- Extract shared policy and infrastructure safely without coupling state.
