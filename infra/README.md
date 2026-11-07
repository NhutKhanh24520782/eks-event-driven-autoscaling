# Infrastructure

Terraform provisions the AWS resources for the EKS event-driven worker
project. The active root module is [`envs/dev/`](envs/dev/README.md). Reusable
modules are in [`modules/`](modules/README.md); one-time remote-state
prerequisites are in [`bootstrap/`](bootstrap/README.md).

## What is provisioned

- VPC with public/private subnets across the configured Availability Zones,
  NAT gateway, and an EKS managed node group.
- EKS cluster, OIDC provider, VPC CNI, CoreDNS, and kube-proxy add-ons.
- SQS main queue and DLQ with a redrive policy.
- ECR repositories for API and worker images.
- Queue-scoped IRSA roles for the API, worker, and (when enabled) KEDA.
- AWS Load Balancer Controller and EBS CSI driver with IAM roles.
- Optional KEDA Helm release controlled by `install_keda`.
- Monthly AWS Budget with configured email thresholds.

This configuration does not install Prometheus, Grafana, Loki, Promtail,
Metrics Server, or a cluster autoscaler. Those steps are documented in the
Kubernetes and observability guides. KEDA scales worker pods, not EC2 nodes.

## Prerequisites

- Terraform >= 1.6 and AWS CLI v2.
- An AWS identity with permissions for the resources above.
- A configured backend bucket and DynamoDB lock table (or run bootstrap).
- A reviewed `infra/envs/dev/terraform.tfvars`; restrict public EKS endpoint
  CIDRs and supply valid administrator ARNs and budget alert emails.

Never commit `terraform.tfvars`, state files, plans containing sensitive
values, credentials, or generated `.terraform` directories.

## Apply the dev environment

From the repository root:

```powershell
terraform -chdir=infra\envs\dev init
terraform -chdir=infra\envs\dev validate
terraform -chdir=infra\envs\dev plan -out=tfplan
terraform -chdir=infra\envs\dev apply tfplan
```

Inspect the plan and account/region before applying. If backend configuration
has changed, determine whether the existing state must be migrated before
running `terraform init -reconfigure` or `terraform init -migrate-state`.
Do not switch backend configuration blindly.

Useful outputs:

```powershell
terraform -chdir=infra\envs\dev output
terraform -chdir=infra\envs\dev output -raw queue_url
terraform -chdir=infra\envs\dev output -raw api_role_arn
terraform -chdir=infra\envs\dev output -raw worker_role_arn
terraform -chdir=infra\envs\dev output -raw ecr_api_url
terraform -chdir=infra\envs\dev output -raw ecr_worker_url
```

See the [root deployment guide](../README.md#deployment) for image publishing,
Kubernetes setup, monitoring installation, and smoke tests.

## KEDA

KEDA is disabled by default. Set `install_keda = true` in the dev tfvars,
review the Terraform plan, and apply it before creating a `ScaledObject`.
Terraform creates a dedicated KEDA IRSA role with queue-attribute read access.
The `ScaledObject` itself is managed by the Kubernetes manifest, not Terraform.

## Teardown and cost

Resources such as EKS, EC2, NAT Gateway, ALB, EBS, and data transfer can incur
ongoing charges. Before destroying the environment, delete Kubernetes Ingress
resources and wait for ALBs to be removed. Review the destroy plan and retain
the bootstrap state bucket and lock table unless there is a specific approved
reason to remove them. Never destroy shared infrastructure without confirming
ownership and state.

## Follow-up work

- Pin and validate supported Kubernetes and EKS add-on versions.
- Replace broad/default CIDRs and improve least-privilege policies.
- Add environment separation, drift checks, and automated plan review.
- Add a safe, documented state migration and backup/restore procedure.
- Review all costs and retention policies against a real project budget.
