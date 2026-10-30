# Terraform Backend Bootstrap

This Terraform root creates the S3 bucket and DynamoDB table used for the dev
environment's remote state. It is a one-time prerequisite and keeps its own
state locally unless a separate backend is configured.

Resources include an S3 bucket with versioning, server-side encryption,
public-access blocking, a TLS-only bucket policy, and a DynamoDB state-lock
table. The bucket has `prevent_destroy`; retain it to preserve environment
state.

## Run

From the repository root, authenticate to the intended AWS account first:

```powershell
aws sts get-caller-identity
terraform -chdir=infra\bootstrap init
terraform -chdir=infra\bootstrap plan
terraform -chdir=infra\bootstrap apply
terraform -chdir=infra\bootstrap output
```

Use the outputs to configure `infra/envs/dev/versions.tf` only when setting
up a new backend. The checked-in dev configuration may already refer to an
existing bucket/table. Do not overwrite that configuration or reinitialize
an existing backend without confirming the state location and migration plan.

Keep the bootstrap `terraform.tfstate` and backups secure; they contain
infrastructure metadata. Do not commit generated state.

## Follow-up work

- Move bootstrap state into an independently managed protected backend.
- Document access controls, state recovery, and DynamoDB lock-table
  migration/deprecation strategy.
- Add a check that prevents using the wrong AWS account or project name.
