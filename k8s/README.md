# Kubernetes Manifests

This directory contains Kustomize resources for the `app` namespace:

- API and worker Deployments, Services, probes, resource requests/limits, and
  service accounts.
- ConfigMap for AWS region and SQS queue URL.
- API Ingress for the AWS Load Balancer Controller.
- Topology-spread patches for multi-AZ scheduling.
- `gp3` EBS CSI StorageClass.
- Optional KEDA SQS ScaledObject and CPU HPA baseline.

The EKS cluster, AWS Load Balancer Controller, EBS CSI driver, SQS, ECR, and
IRSA roles are provisioned by Terraform. Prometheus and logging components are
installed separately; see [`observability/`](../observability/README.md).

## Before applying

1. Apply Terraform and connect `kubectl` to the intended EKS cluster.
2. Confirm nodes are Ready and the EBS CSI add-on is `ACTIVE`; apply
   `storage/ebs-gp3.yaml`.
3. Build and push API and worker images to ECR.
4. Replace `REPLACE_WITH_TERRAFORM_QUEUE_URL` in
   `config/configmap.yaml` with the `queue_url` Terraform output.

Do not put AWS credentials in manifests. Use the IRSA role outputs to annotate
the `api` and `worker` service accounts after applying the resources.

## Deploy application

From the repository root, after replacing the queue placeholder:

```powershell
kubectl apply -k k8s
$apiRoleArn = terraform -chdir=infra\envs\dev output -raw api_role_arn
$workerRoleArn = terraform -chdir=infra\envs\dev output -raw worker_role_arn
if ([string]::IsNullOrWhiteSpace($apiRoleArn) -or
    [string]::IsNullOrWhiteSpace($workerRoleArn)) {
  throw "Missing application IRSA role ARN."
}
kubectl annotate serviceaccount api -n app `
  "eks.amazonaws.com/role-arn=$apiRoleArn" --overwrite
kubectl annotate serviceaccount worker -n app `
  "eks.amazonaws.com/role-arn=$workerRoleArn" --overwrite
kubectl set image deployment/api-service api=<ECR_API_URL>:<TAG> -n app
kubectl set image deployment/worker-service worker=<ECR_WORKER_URL>:<TAG> -n app
kubectl rollout status deployment/api-service -n app
kubectl rollout status deployment/worker-service -n app
kubectl get pods,services,ingress -n app
```

Wait for the ALB address to appear on `api-ingress`. The API role needs
`sqs:SendMessage`; the worker role needs receive/delete/queue-attribute
permissions. KEDA uses its own role. If pods use the node-group role instead,
check their service-account annotation and restart the pods.

## Choose one autoscaler

### KEDA / SQS

KEDA is disabled by default in `infra/envs/dev/terraform.tfvars`. Enable it and
apply Terraform before creating the ScaledObject, because the KEDA chart
installs the `scaledobjects.keda.sh` CRD:

```powershell
terraform -chdir=infra\envs\dev plan
terraform -chdir=infra\envs\dev apply
kubectl get crd scaledobjects.keda.sh
kubectl get pods -n keda
```

Replace the queue URL placeholder in `autoscaling/keda-scaledobject.yaml`,
then apply and inspect:

```powershell
kubectl apply -f k8s\autoscaling\keda-scaledobject.yaml
kubectl get scaledobject,hpa -n app
kubectl describe scaledobject worker-scaledobject -n app
```

### CPU HPA baseline

Do not create the KEDA ScaledObject while the baseline HPA is managing the
same Deployment. Metrics Server is not installed by the current Terraform
configuration. Install it separately and confirm `kubectl top pods -n app`
works before applying:

```powershell
kubectl apply -f k8s\autoscaling\hpa-baseline.yaml
kubectl get hpa -n app -w
```

The worker's current timer-based simulated workload is not CPU-intensive, so
the existing k6 test is not expected to drive CPU utilization high enough for
the HPA to scale.

## Verify and debug

```powershell
kubectl get pods,services,ingress -n app
kubectl logs -n app deployment/api-service --since=10m
kubectl logs -n app deployment/worker-service --since=10m
kubectl port-forward -n app service/worker-service 8081:8081
```

Worker health is at `/health`; Prometheus metrics are at `/metrics`. A 202
from the API confirms enqueue success, not worker processing. Check worker
logs for `JOB SUCCESS` and confirm `worker_jobs_processed_total` in Prometheus.

## Follow-up work

- Replace mutable `latest` and inline placeholders with a reproducible image
  release process or Kustomize image transformations.
- Add NetworkPolicies, PodDisruptionBudgets, and explicit security-context
  policies after validating cluster requirements.
- Install and manage Metrics Server for a meaningful HPA baseline.
- Add alerts and dashboards for autoscaler conditions and queue depth.
