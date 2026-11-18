# Observability Stack: Prometheus, Grafana, and Loki

This directory provides the complete observability configuration and deployment guide for the **Multi-AZ Event-Driven Autoscaling (KEDA + SQS) microservices architecture on Amazon EKS**.

The monitoring stack collects time-series metrics from the API and Worker microservices, Kubernetes control plane, and AWS SQS, while aggregating distributed application and system logs with Loki and Promtail.

---

## 1. Quick Architecture Overview

```
                      ┌────────────────────────────────────────┐
                      │             Amazon EKS Cluster         │
                      │                                        │
  [ Inbound Traffic ] │   ┌───────────────┐                    │
───────────►──────────┼──►│  api-service  │──► [ AWS SQS Queue ]
                      │   └───────┬───────┘          │         │
                      │           │ /metrics         │         │
                      │           ▼                  ▼         │
                      │   ┌───────────────┐     ┌───────────┐  │
                      │   │  PodMonitor   │     │   KEDA    │  │
                      │   └───────┬───────┘     └─────┬─────┘  │
                      │           │                   ▼        │
                      │           ▼            [ Worker Pods ] │
                      │   ┌───────────────┐           │        │
                      │   │  Prometheus   │◄──────────┤        │
                      │   │    Server     │   /metrics         │
                      │   └───────┬───────┘                    │
                      │           │                            │
                      │           ▼                            │
                      │   ┌───────────────┐    ┌─────────────┐ │
                      │   │    Grafana    │◄───│ Loki Server │ │
                      │   │  Dashboards   │    └──────▲──────┘ │
                      │   └───────────────┘           │ logs   │
                      │                          [ Promtail ]  │
                      └────────────────────────────────────────┘
```

---

## 2. Complete Installation Guide (EKS)

### Prerequisites
- Active `kubectl` context pointing to your development EKS cluster:
  ```powershell
  kubectl config current-context
  ```
- Helm 3.x installed.
- AWS EBS CSI Driver add-on active and `gp3` StorageClass created (from `k8s/storage/ebs-gp3.yaml`).
- Application deployed in namespace `app`.

### Step 2.1: Prepare Namespace, StorageClass, and Grafana Credentials
```powershell
# 1. Apply gp3 StorageClass
kubectl apply -f k8s\storage\ebs-gp3.yaml
kubectl get storageclass gp3

# 2. Create observability namespace
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

# 3. Create Grafana Admin Secret (use strong credentials in non-eval setups)
kubectl create secret generic grafana-admin -n observability `
  --from-literal=admin-user=admin `
  --from-literal=admin-password='YourStrongPassword123!' `
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 2.2: Add Helm Repositories
```powershell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### Step 2.3: Deploy Prometheus & Grafana (kube-prometheus-stack)
`observability/prometheus-values.yaml` configures:
- 7-day metric retention with a 15GB volume limit.
- 15s–30s scrape interval to capture rapid autoscaling transients.
- Automatic binding to `gp3` persistent volumes.
- Pre-configured Loki datasource (`http://loki.observability.svc.cluster.local:3100`).
- PodMonitor & ServiceMonitor selector matching without release restrictions.

```powershell
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack `
  --namespace observability `
  --values observability\prometheus-values.yaml
```

### Step 2.4: Deploy Loki & Promtail for Centralized Log Aggregation
`observability/loki/values.yaml` provisions Loki in `SingleBinary` mode using local `tsdb` index on `gp3` storage with a 7-day retention period. Promtail runs as a DaemonSet scraping CRI container logs.

```powershell
# Deploy Loki
helm upgrade --install loki grafana/loki `
  --namespace observability `
  --values observability\loki\values.yaml

# Deploy Promtail DaemonSet
helm upgrade --install promtail grafana/promtail `
  --namespace observability `
  --values observability\loki\promtail-values.yaml
```

### Step 2.5: Apply Metrics Scrape Monitors
```powershell
# Apply API Service PodMonitor (scrapes /metrics on port 8080)
kubectl apply -f observability\prometheus\api-podmonitor.yaml

# Apply Worker Service ServiceMonitor (scrapes /metrics on port 8081)
kubectl apply -f k8s\config\worker-servicemonitor.yaml
```

### Step 2.6: Deploy Grafana Dashboards via GitOps ConfigMap
```powershell
# Apply Master Autoscaling & Chaos Dashboard
kubectl apply -f k8s\config\grafana-dashboard-master.yaml

# Apply Dedicated Worker & SQS Dashboard
kubectl create configmap worker-monitoring-dashboard -n observability `
  --from-file=worker-monitoring.json=observability\grafana\dashboards\worker-monitoring.json `
  --dry-run=client -o yaml |
  kubectl label --local -f - grafana_dashboard=1 -o yaml |
  kubectl apply -f -
```

---

## 3. Verifying the Observability Stack

### Pod and PVC Health Check
```powershell
kubectl get pods,pvc -n observability
```
Expected output:
- `monitoring-kube-prometheus-prometheus-0`: `Running` (1/1), PVC `Bound`
- `monitoring-grafana-...`: `Running` (1/1), PVC `Bound`
- `loki-0`: `Running` (1/1), PVC `Bound`
- `promtail-...` (one per node): `Running` (1/1)

### Accessing Grafana
Port-forward Grafana to localhost:
```powershell
kubectl port-forward -n observability service/monitoring-grafana 3000:80
```
Open `http://localhost:3000` in your browser. Log in with user `admin` and the password configured in `grafana-admin`.

### Accessing Prometheus UI (for target inspection & ad-hoc PromQL)
```powershell
kubectl port-forward -n observability service/monitoring-kube-prometheus-prometheus 9090:9090
```
Open `http://localhost:9090/targets` to confirm:
- `podMonitor/observability/api-service/0` (UP)
- `serviceMonitor/app/worker-monitor/0` (UP)

---

## 4. Key Metrics and Dashboard Tracking

The monitoring dashboards track five critical dimensions required for event-driven autoscaling analysis:

### 1. Queue Backlog & In-Flight Jobs
- **Metrics**:
  - `api_sqs_approximate_messages_visible`: Approximate visible messages waiting in SQS.
  - `api_sqs_approximate_messages_not_visible`: Messages polled by workers currently in flight.
- **PromQL**:
  ```promql
  max(api_sqs_approximate_messages_visible)
  max(api_sqs_approximate_messages_not_visible)
  ```
  *(Note: `max()` is used instead of `sum()` because all API replicas query the same underlying SQS queue).*

### 2. Worker Replicas (KEDA / HPA Autoscaling)
- **Metrics**:
  - `kube_deployment_spec_replicas{deployment="worker-service"}`: Desired replicas demanded by KEDA/HPA.
  - `kube_deployment_status_replicas_ready{deployment="worker-service"}`: Replicas currently in Ready status.
- **PromQL**:
  ```promql
  max(kube_deployment_spec_replicas{namespace="app",deployment="worker-service"})
  max(kube_deployment_status_replicas_ready{namespace="app",deployment="worker-service"})
  ```

### 3. Throughput (Ingress & Processing Rate)
- **Metrics**:
  - `worker_jobs_processed_total`: Successful job executions.
  - `api_jobs_accepted_total`: Enqueue acceptances (HTTP 202).
- **PromQL**:
  ```promql
  # Worker Processing Throughput (jobs/sec)
  sum(rate(worker_jobs_processed_total[1m]))

  # API Ingress Enqueue Rate (requests/sec)
  sum(rate(api_jobs_accepted_total[1m]))
  ```

### 4. Processing Latency (Histogram & Quantiles)
- **Metrics**:
  - `worker_job_processing_seconds_bucket`: Execution durations (monotonic performance timer).
- **PromQL**:
  ```promql
  # p95 Processing Latency (seconds)
  histogram_quantile(0.95, sum by (le) (rate(worker_job_processing_seconds_bucket[5m])))

  # p50 Median Processing Latency (seconds)
  histogram_quantile(0.50, sum by (le) (rate(worker_job_processing_seconds_bucket[5m])))
  ```

### 5. Worker Pod Status, Readiness, & Multi-AZ Topology
- **Metrics**:
  - `kube_pod_status_ready{namespace="app",pod=~"worker-service-.*"}`: Ready status per Pod.
  - `kube_pod_info{namespace="app"}`: Pod-to-Node mapping.
  - `kube_node_labels{label_topology_kubernetes_io_zone=~".*"}`: Multi-AZ node distribution.
- **PromQL**:
  ```promql
  # Pod Readiness status (1 = Ready, 0 = Unready)
  kube_pod_status_ready{namespace="app",pod=~"worker-service-.*"}

  # Multi-AZ Pod Distribution
  count by (node) (kube_pod_info{namespace="app",pod=~"worker-service-.*"})
  ```

### 6. Resilience & Reliability Indicators
- **Idempotency duplicates skipped**: `sum(increase(worker_jobs_duplicate_total[1m]))`
- **Error & DLQ retry rate**: `sum(increase(worker_jobs_error_total[1m]))`

---

## 5. Centralized Logging Queries with Loki (LogQL)

With Loki and Promtail running, query application logs in Grafana Explore (`http://localhost:3000/explore`):

- **Trace a specific job from API to Worker**:
  ```logql
  {namespace="app"} |= "job_id=" |= "<YOUR_JOB_ID>"
  ```
- **Track SQS Enqueue events**:
  ```logql
  {namespace="app", container="api-service"} |= "[SQS SENT]"
  ```
- **Filter Worker Successes**:
  ```logql
  {namespace="app", container="worker-service"} |= "[JOB SUCCESS]"
  ```
- **Detect Redeliveries & Retries**:
  ```logql
  {namespace="app", container="worker-service"} |= "[REDELIVERY]"
  ```
- **Idempotency Cache Skips**:
  ```logql
  {namespace="app", container="worker-service"} |= "[IDEMPOTENT SKIP]"
  ```
- **Detect Pod Termination & SIGTERM**:
  ```logql
  {namespace="app", container="worker-service"} |= "[SHUTDOWN]"
  ```

---

## 6. Troubleshooting & Recovery

### Immutable VolumeClaimTemplates on Prometheus Upgrade
If Helm complains that `volumeClaimTemplates` cannot be updated when redeploying Prometheus:
1. Verify whether the existing claims are `Pending` (unbound):
   ```powershell
   kubectl get pvc -n observability
   ```
2. If unbound and safe to recreate, delete the StatefulSet and the unbound PVC:
   ```powershell
   kubectl delete statefulset prometheus-monitoring-kube-prometheus-prometheus -n observability
   kubectl delete pvc prometheus-monitoring-kube-prometheus-prometheus-db-prometheus-monitoring-kube-prometheus-prometheus-0 -n observability
   ```
3. Re-run `helm upgrade --install monitoring ...`. The Prometheus Operator will automatically recreate the StatefulSet and bind a fresh `gp3` persistent volume.

## Metrics and limitations

The worker exports the following Prometheus metrics:

| Metric | Type | Meaning |
| --- | --- | --- |
| `worker_in_flight_jobs` | Gauge | Jobs currently being processed by this worker pod |
| `worker_jobs_processed_total` | Counter | Successfully processed jobs |
| `worker_jobs_duplicate_total` | Counter | Duplicate jobs skipped |
| `worker_jobs_error_total` | Counter | Failed jobs |
| `worker_jobs_received_total` | Counter | Messages received by the worker |
| `worker_job_processing_seconds` | Histogram | Per-attempt processing duration, including failures |

Counters are process-local and reset when a pod restarts; use `rate()` or
`increase()` and aggregate across pods for dashboards. Kubernetes replica
panels use kube-state-metrics, included with kube-prometheus-stack.

The API exports `api_sqs_approximate_messages_visible`,
`api_sqs_approximate_messages_not_visible`, and
`api_sqs_approximate_messages_delayed` from `GetQueueAttributes`. API replicas
see the same queue, so use `max()` rather than `sum()` for queue depth. The API
returns HTTP 503 if SQS attributes cannot be read instead of reporting a false
zero.

The queue gauges are approximate and are scraped every 30 seconds; they do
not supply T2 or per-message event times. The dashboard adds backlog,
desired/ready worker replicas, processed throughput, worker processing p95,
and Pod readiness. Do not interpret the scrape interval as an autoscaling
latency measurement. The T0–T6 process and evidence limitations are described in
[`docs/control-loop-latency.md`](../docs/control-loop-latency.md).

Loki in this configuration is a single-binary, filesystem-backed deployment
with one replica and seven-day log retention. It is suitable for development
and controlled experiments, not highly available production use. Use durable,
shared object storage and a production Loki deployment mode for production.
The current EKS namespace inspection showed Promtail but no Loki workload;
verify Loki is Ready before expecting Grafana log queries to work. Installing
the chart is a separate resource/cost change.

## Dashboard provisioning

The chart's dashboard sidecar can load a labeled ConfigMap. From the
repository root:

```powershell
kubectl create configmap worker-monitoring-dashboard -n observability `
  --from-file=worker-monitoring.json=observability\grafana\dashboards\worker-monitoring.json `
  --dry-run=client -o yaml |
  kubectl label --local -f - grafana_dashboard=1 -o yaml |
  kubectl apply -f -
```

Allow the sidecar to reload the dashboard, then check the Grafana dashboard
list. Alternatively, import the JSON manually. Keep Helm chart versions,
retention, PVC usage, and Loki storage/cost under review before using this
development configuration for production.
