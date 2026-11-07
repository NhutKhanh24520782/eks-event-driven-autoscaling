# Terraform Modules

Reusable Terraform modules called by `envs/dev`:

| Module | Responsibility |
| --- | --- |
| [`budget/`](budget/README.md) | Monthly AWS cost budget and email notifications |
| [`ecr/`](ecr/README.md) | ECR repositories and image lifecycle policy |
| [`irsa/`](irsa/README.md) | OIDC trust role and inline policy for a Kubernetes service account |
| [`sqs/`](sqs/README.md) | Main SQS queue and dead-letter queue |

These are local modules, not independently deployed root modules. Keep
resource names, outputs, and variable contracts compatible with their callers.

## Follow-up work

- Add module-level validation/tests and documented examples.
- Review least privilege, resource tagging, retention, and deletion safeguards.
- Keep provider/module versions under an explicit compatibility policy.
