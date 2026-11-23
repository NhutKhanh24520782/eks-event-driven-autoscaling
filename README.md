# EKS Event-Driven Autoscaling

A development project for an asynchronous API and worker system on Amazon EKS.
The API publishes jobs to Amazon SQS. A worker Deployment consumes them.
KEDA can scale workers from queue depth; an optional CPU HPA is provided for
comparison. Prometheus, Grafana, and Loki provide metrics and log collection.

> **Scope:** this repository contains a working infrastructure/application
> implementation plus experiment scaffolding. T0–T6 latency instrumentation,
> a Prometheus SQS queue-depth datasource, a CPU-intensive HPA workload, and
> automated chaos workflows are not complete. See [Next development steps](#next-development-steps).

## Architecture

```text
Client
  |
  v
AWS ALB -> API Service (EKS) -> Amazon SQS + DLQ -> Worker Deployment
                                                   ^       |
                                                   |       +-> /metrics
                                             KEDA (optional)

Prometheus Operator -> Prometheus -> Grafana
Kubernetes logs -> Promtail -> Loki -> Grafana
```

Terraform provisions a VPC across two Availability Zones, an EKS managed node
group, SQS queues, ECR repositories, IAM roles/IRSA, AWS Load Balancer
Controller, EBS CSI driver, and an optional KEDA installation. Kubernetes
workloads are spread across available zones where scheduling capacity permits.
This project uses managed node groups; it does not configure Karpenter or
cluster autoscaling.

## Repository map

| Path                                         | Purpose                                                            |
| -------------------------------------------- | ------------------------------------------------------------------ |
| [`apps/`](apps/README.md)                   | Backend services and frontend dashboard                            |
| [`infra/`](infra/README.md)                 | Terraform bootstrap, EKS environment, and reusable modules         |
| [`k8s/`](k8s/README.md)                     | Application, storage, ingress, topology, and autoscaling manifests |
| [`observability/`](observability/README.md) | Prometheus/Grafana, Loki/Promtail, and dashboard                   |
| [`scripts/`](scripts/README.md)             | Local load test, chaos placeholders, and latency collection notes  |
| [`docs/`](docs/README.md)                   | Architecture, experiments, fault tolerance, and evidence           |

## Requirements

- AWS account with permissions to create EKS, VPC, EC2, IAM, SQS, ECR, ELB,
  S3, DynamoDB, Budgets, and EKS add-ons.
- AWS CLI v2, Terraform >= 1.6, kubectl compatible with the cluster version,
  Helm 3, Docker, and (for load tests) k6.
- A Docker-compatible shell for image build commands. Examples below use
  PowerShell from the repository root.
- Budget alert email addresses and the IAM principal ARNs that need EKS
  administrator access.

Review current AWS pricing before deploying. EKS, EC2, NAT Gateway, EBS,
load balancers, and data transfer can incur costs even when idle.

## Deployment Guide (End-to-End)

Follow this step-by-step guide to deploy the entire project onto Amazon EKS from scratch. Commands are provided for both **Git Bash** and **PowerShell**.

---

### Step 1: Configure Environment Variables

Authenticate with your AWS account and set required environment variables.

#### Git Bash
```bash
aws sts get-caller-identity
export AWS_REGION="ap-southeast-1"
export CLUSTER_NAME="multiaz-eks"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "Account ID: $ACCOUNT_ID"
echo "ECR Registry: $ECR_REGISTRY"
```

#### PowerShell
```powershell
aws sts get-caller-identity
$env:AWS_REGION = "ap-southeast-1"
$env:CLUSTER_NAME = "multiaz-eks"
$env:ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)
$env:ECR_REGISTRY = "$($env:ACCOUNT_ID).dkr.ecr.$($env:AWS_REGION).amazonaws.com"

Write-Host "Account ID: $env:ACCOUNT_ID"
Write-Host "ECR Registry: $env:ECR_REGISTRY"
```

---

### Step 2: Provision Infrastructure (Terraform)

Prepare `infra/envs/dev/terraform.tfvars` (copy from `terraform.tfvars.example` if not already created), then initialize and apply Terraform.

#### Git Bash
```bash
cd infra/envs/dev
terraform init
terraform plan
terraform apply -auto-approve
cd ../../../
```

#### PowerShell
```powershell
cd infra\envs\dev
terraform init
terraform plan
terraform apply -auto-approve
cd ..\..\..
```

> [!TIP]
> Retrieve Terraform outputs anytime with:
> `terraform -chdir=infra/envs/dev output` (Git Bash) or `terraform -chdir=infra\envs\dev output` (PowerShell).

---

### Step 3: Connect kubectl & Install StorageClass

Update `kubeconfig` to connect `kubectl` to EKS, then apply the `gp3` StorageClass for Persistent Volumes (Prometheus/Grafana).

#### Git Bash
```bash
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
kubectl get nodes
kubectl apply -f k8s/storage/ebs-gp3.yaml
```

#### PowerShell
```powershell
aws eks update-kubeconfig --region $env:AWS_REGION --name $env:CLUSTER_NAME
kubectl get nodes
kubectl apply -f k8s\storage\ebs-gp3.yaml
```

---

### Step 4: Build & Push Container Images to ECR

Log in to Amazon ECR, then build and push API, Worker, and Frontend images.

#### Git Bash
```bash
# Log in to ECR
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY

# Build & push API Service
docker build -t ${ECR_REGISTRY}/multiaz-autoscaling/api:latest -f apps/backend/api-service/Dockerfile apps/backend/api-service
docker push ${ECR_REGISTRY}/multiaz-autoscaling/api:latest

# Build & push Worker Service
docker build -t ${ECR_REGISTRY}/multiaz-autoscaling/worker:latest -f apps/backend/worker-service/Dockerfile apps/backend/worker-service
docker push ${ECR_REGISTRY}/multiaz-autoscaling/worker:latest

# Build & push Frontend (uses nginx.eks.conf for Kubernetes routing)
docker build --build-arg NGINX_CONFIG=nginx.eks.conf -t ${ECR_REGISTRY}/multiaz-autoscaling/frontend:latest -f apps/frontend/Dockerfile apps/frontend
docker push ${ECR_REGISTRY}/multiaz-autoscaling/frontend:latest
```

#### PowerShell
```powershell
# Log in to ECR
aws ecr get-login-password --region $env:AWS_REGION | docker login --username AWS --password-stdin $env:ECR_REGISTRY

# Build & push API Service
docker build -t "$($env:ECR_REGISTRY)/multiaz-autoscaling/api:latest" -f apps\backend\api-service\Dockerfile apps\backend\api-service
docker push "$($env:ECR_REGISTRY)/multiaz-autoscaling/api:latest"

# Build & push Worker Service
docker build -t "$($env:ECR_REGISTRY)/multiaz-autoscaling/worker:latest" -f apps\backend\worker-service\Dockerfile apps\backend\worker-service
docker push "$($env:ECR_REGISTRY)/multiaz-autoscaling/worker:latest"

# Build & push Frontend (uses nginx.eks.conf for Kubernetes routing)
docker build --build-arg NGINX_CONFIG=nginx.eks.conf -t "$($env:ECR_REGISTRY)/multiaz-autoscaling/frontend:latest" -f apps\frontend\Dockerfile apps\frontend
docker push "$($env:ECR_REGISTRY)/multiaz-autoscaling/frontend:latest"
```

---

### Step 5: Deploy Application Workloads & Annotate IRSA

Sync the SQS Queue URL into the ConfigMap, apply Kustomize manifests, annotate IAM roles onto ServiceAccounts, and restart pods.

#### Git Bash
```bash
# 1. Sync Queue URL into ConfigMap
export QUEUE_URL=$(terraform -chdir=infra/envs/dev output -raw queue_url)
sed -i "s|QUEUE_URL:.*|QUEUE_URL: ${QUEUE_URL}|g" k8s/config/configmap.yaml

# 2. Apply Kubernetes manifests
kubectl apply -k k8s

# 3. Annotate ServiceAccounts with IRSA Role ARNs
export API_ROLE_ARN=$(terraform -chdir=infra/envs/dev output -raw api_role_arn)
export WORKER_ROLE_ARN=$(terraform -chdir=infra/envs/dev output -raw worker_role_arn)
kubectl annotate serviceaccount api -n app "eks.amazonaws.com/role-arn=${API_ROLE_ARN}" --overwrite
kubectl annotate serviceaccount worker -n app "eks.amazonaws.com/role-arn=${WORKER_ROLE_ARN}" --overwrite

# 4. Restart deployments & verify status
kubectl rollout restart deployment/api-service deployment/worker-service deployment/frontend-service -n app
kubectl rollout status deployment/api-service -n app
kubectl rollout status deployment/worker-service -n app
kubectl rollout status deployment/frontend-service -n app
```

#### PowerShell
```powershell
# 1. Sync Queue URL into ConfigMap
$queueUrl = terraform -chdir=infra\envs\dev output -raw queue_url
(Get-Content k8s\config\configmap.yaml) -replace 'QUEUE_URL:.*', "QUEUE_URL: $queueUrl" | Set-Content k8s\config\configmap.yaml

# 2. Apply Kubernetes manifests
kubectl apply -k k8s

# 3. Annotate ServiceAccounts with IRSA Role ARNs
$apiRoleArn = terraform -chdir=infra\envs\dev output -raw api_role_arn
$workerRoleArn = terraform -chdir=infra\envs\dev output -raw worker_role_arn
kubectl annotate serviceaccount api -n app "eks.amazonaws.com/role-arn=$apiRoleArn" --overwrite
kubectl annotate serviceaccount worker -n app "eks.amazonaws.com/role-arn=$workerRoleArn" --overwrite

# 4. Restart deployments & verify status
kubectl rollout restart deployment/api-service deployment/worker-service deployment/frontend-service -n app
kubectl rollout status deployment/api-service -n app
kubectl rollout status deployment/worker-service -n app
kubectl rollout status deployment/frontend-service -n app
```

---

### Step 6: Deploy Observability Stack (Prometheus & Grafana)

Install Prometheus & Grafana with Helm, create Grafana credentials, apply Worker ServiceMonitor, and import the master dashboard.

#### Git Bash
```bash
# 1. Add Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 2. Create namespace and Grafana admin secret
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic grafana-admin -n observability \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=admin123 \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Install kube-prometheus-stack
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace observability \
  --values observability/prometheus-values.yaml

# 4. Apply Worker ServiceMonitor & Master Dashboard
kubectl apply -f k8s/config/worker-servicemonitor.yaml
kubectl apply -f k8s/config/grafana-dashboard-master.yaml
```

#### PowerShell
```powershell
# 1. Add Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 2. Create namespace and Grafana admin secret
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic grafana-admin -n observability `
  --from-literal=admin-user=admin `
  --from-literal=admin-password=admin123 `
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Install kube-prometheus-stack
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack `
  --namespace observability `
  --values observability\prometheus-values.yaml

# 4. Apply Worker ServiceMonitor & Master Dashboard
kubectl apply -f k8s\config\worker-servicemonitor.yaml
kubectl apply -f k8s\config\grafana-dashboard-master.yaml
```

---

### Step 7: Verification & Load Testing

#### 7.1 Verify Pods & Ingress
```bash
kubectl get pods -n app
kubectl get pods -n observability
kubectl get ingress api-ingress -n app
```

#### 7.2 Access Services via Port-Forwarding (Local Testing)
In a separate terminal window:
* **Frontend Web:** `kubectl port-forward svc/frontend-service 8080:80 -n app` -> Open `http://localhost:8080`
* **Grafana Dashboard:** `kubectl port-forward svc/monitoring-grafana 3000:80 -n observability` -> Open `http://localhost:3000` (`admin` / `admin123`)

#### 7.3 Run k6 Load Test
* **Git Bash:**
  ```bash
  export TARGET_URL="http://localhost:8080"
  k6 run scripts/load-test/k6-workload.js
  ```
* **PowerShell:**
  ```powershell
  $env:TARGET_URL = "http://localhost:8080"
  k6 run scripts\load-test\k6-workload.js
  ```

---

### Step 8: Autoscaling Options (Optional)

* **KEDA / SQS (Recommended Event-Driven):** Set `install_keda = true` in `infra/envs/dev/terraform.tfvars`, run `terraform apply`. Then update `queueURL` in `k8s/autoscaling/keda-scaledobject.yaml` and apply:
  ```bash
  kubectl apply -f k8s/autoscaling/keda-scaledobject.yaml
  ```
* **CPU HPA (Baseline comparison):** Apply `k8s/autoscaling/hpa-baseline.yaml` without KEDA ScaledObject.

> [!WARNING]
> Do not let KEDA and CPU HPA manage `worker-service` simultaneously.

---

### Step 9: Clean Up & Teardown

To avoid AWS `DependencyViolation` errors during VPC deletion, always clean up Kubernetes Ingress (ALB) and storage before running `terraform destroy`:

#### Git Bash
```bash
# 1. Delete Ingress to remove ALB
kubectl delete ingress api-ingress -n app

# 2. Delete monitoring resources and PVCs
helm uninstall monitoring -n observability
kubectl delete pvc --all -n observability
kubectl delete pvc --all -n app
kubectl delete -k k8s

# 3. Destroy Terraform infrastructure
cd infra/envs/dev
terraform destroy -auto-approve
cd ../../../
```

#### PowerShell
```powershell
# 1. Delete Ingress to remove ALB
kubectl delete ingress api-ingress -n app

# 2. Delete monitoring resources and PVCs
helm uninstall monitoring -n observability
kubectl delete pvc --all -n observability
kubectl delete pvc --all -n app
kubectl delete -k k8s

# 3. Destroy Terraform infrastructure
cd infra\envs\dev
terraform destroy -auto-approve
cd ..\..\..
```


## Local development

The local compose stack uses ElasticMQ instead of AWS SQS:

```powershell
docker compose -f docker-compose.local.yml up --build
```

Frontend: `http://localhost:8181`; API: `http://localhost:3000`; worker health and metrics:
`http://localhost:3001/health` and `http://localhost:3001/metrics`.
The Failure Scenarios page can start two bounded local tests: `traffic-spike`
(up to 20 `POST /jobs` requests) and `sqs-backlog-spike` (up to 12 queued jobs).
Stop prevents further jobs from being sent; jobs already accepted by SQS may
still be processed.
Database, deploy, network, storage, and poison-message scenarios are disabled
because this Compose stack does not provide safe implementations for them.
Chaos controls are enabled only by the local Compose configuration and its
frontend/API ports bind to loopback.
Send a job with:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:3000/jobs `
  -ContentType 'application/json' `
  -Body '{"payload":{"test":true},"processTimeMs":500}'
```

## Next development steps

1. Instrument and document T0–T6 timestamps with a consistent clock and
   publish latency histograms/measurements.
2. Integrate SQS queue depth into Prometheus/Grafana (for example via
   CloudWatch exporter or an approved metrics adapter).
3. Add worker processing-duration histograms and API request metrics.
4. Provide a bounded CPU workload mode and install Metrics Server for a valid
   HPA comparison.
5. Add dashboard panels and alerts for KEDA/HPA state, queue depth, retries,
   DLQ, pod readiness, and latency.
6. Add additional scenario implementations only alongside their dependencies,
   cleanup behavior, bounded limits, and environment guards.
7. Pin and test Helm chart versions; establish backups and production-grade
   storage/retention for Loki and Prometheus.
8. Add automated tests, image scanning policy, and immutable image tags.

## Documentation

See each top-level directory README for subsystem-specific configuration and
the [`docs/`](docs/README.md) index for experiment and fault-tolerance notes.
