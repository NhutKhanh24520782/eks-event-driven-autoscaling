# Development Environment

This is the Terraform root module for the development EKS environment. It
provisions the VPC, cluster, managed nodes, ECR/SQS, application and operator
IRSA roles, AWS Load Balancer Controller, EBS CSI add-on, and optional KEDA.

## Configure

Copy `terraform.tfvars.example` to the ignored `terraform.tfvars` file and
review every value. In particular:

- Set `cluster_endpoint_public_access_cidrs` to trusted public IP ranges.
- Add IAM principal ARNs that need cluster administrator access.
- Set valid `alert_emails` and a cost-conscious node size.
- Set `install_keda = true` only when enabling SQS-based scaling.
- Confirm `region`, `cluster_name`, and backend in `versions.tf`.

## Plan and apply

From the repository root:

```powershell
terraform -chdir=infra\envs\dev init
terraform -chdir=infra\envs\dev validate
terraform -chdir=infra\envs\dev plan -out=tfplan
terraform -chdir=infra\envs\dev apply tfplan
```

Review the plan before applying. The EKS endpoint is public in this
configuration; access must be restricted with the CIDR variable. Terraform
outputs include queue, ECR, role, cluster, and kubeconfig values.

After apply, use `aws eks update-kubeconfig` with the actual cluster name and
region. Apply the `gp3` StorageClass from `k8s/storage/` after the EBS CSI
managed add-on is active. Continue with the [root deployment guide](../../../README.md#deployment).

## State and cleanup

The backend is S3 with DynamoDB locking. If Terraform reports that
initialization is required after a backend change, stop and verify the source
and destination state before choosing `-reconfigure` or `-migrate-state`.
Review `terraform destroy` plans carefully. Delete Ingress resources and wait
for their ALBs to be removed before cluster teardown. The separate bootstrap
state resources should normally remain.

## Follow-up work

- Add variables for EBS CSI and other add-on versions instead of selecting
  unpinned versions.
- Add validation for CIDRs, email lists, node sizing, and region/AZ support.
- Automate cluster readiness and application deployment without exposing
  credentials.
- Add safe plan policies and cost estimates.
