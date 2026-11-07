# Observability

This directory contains Helm values for Prometheus/Grafana and Loki/Promtail,
a PodMonitor for the worker, and an importable Grafana dashboard. It assumes
the application is deployed in namespace `app` and uses `observability` for the
monitoring stack.

## Install

Install Helm and `kubectl`, connect to the target EKS cluster, and ensure the
application is deployed first. Create the monitoring namespace and a Grafana
admin Secret; supply a strong password through your normal secret-management
process rather than committing it to this repository:

```powershell
terraform -chdir=infra\envs\dev apply
kubectl apply -f k8s\storage\ebs-gp3.yaml
kubectl get pods -n kube-system
kubectl get storageclass gp3
kubectl create namespace observability --dry-run=client -o yaml |
  kubectl apply -f -
# Create this Secret once; use your secret manager if updating an existing install.
kubectl create secret generic grafana-admin -n observability `
  --from-literal=admin-user=admin `
  --from-literal=admin-password='<set-a-strong-password>'
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack `
  --namespace observability `
  --values observability\prometheus-values.yaml
helm upgrade --install loki grafana/loki `
  --namespace observability `
  --values observability\loki\values.yaml
helm upgrade --install promtail grafana/promtail `
  --namespace observability `
  --values observability\loki\promtail-values.yaml
kubectl apply -f observability\prometheus\worker-podmonitor.yaml
```

Terraform installs the EBS CSI managed add-on and its IRSA role. The `gp3`
StorageClass explicitly selects that CSI driver; it is not marked default.
Confirm the `aws-ebs-csi-driver` add-on is `ACTIVE` and its controller pods are
ready before installing charts that create persistent volume claims. The
Prometheus, Grafana, and Loki values explicitly request `gp3`.

The PodMonitor requires the Prometheus Operator CRDs installed by
`kube-prometheus-stack`. It scrapes the worker's existing `/metrics` endpoint
on the `metrics` port. Re-apply it after installing the monitoring stack if
the CRD was not yet available.

Open Grafana by forwarding its service:

```powershell
kubectl port-forward -n observability service/monitoring-grafana 3000:80
```

Log in with the username and password used to create `grafana-admin`, then
import [the autoscaling dashboard](grafana/dashboards/autoscaling-overview.json).
Prometheus is installed as the default datasource; Loki is added by the values
file. For service status and Prometheus targets, check:

```powershell
kubectl get pods,pvc -n observability
kubectl port-forward -n observability service/monitoring-kube-prometheus-prometheus 9090
```

The Prometheus UI is then available at `http://localhost:9090`. Confirm that
the `worker-service` PodMonitor target is up before relying on dashboard data.

## Recover existing Pending PVCs

The Helm release may already have created claims without a StorageClass. After
the CSI add-on is active and `gp3` exists, inspect the claims:

```powershell
kubectl get pvc -n observability
```

Re-run the `helm upgrade --install monitoring ...` command above to apply the
updated values. If Helm reports that the Prometheus StatefulSet's
`volumeClaimTemplates` are immutable, first confirm the affected claims are
still `Pending` with no volume bound. Only then remove the monitoring
StatefulSet and those unbound claims so the operator can recreate them with
`gp3`:

```powershell
kubectl delete statefulset prometheus-monitoring-kube-prometheus-prometheus -n observability
kubectl delete pvc monitoring-grafana prometheus-monitoring-kube-prometheus-prometheus-db-prometheus-monitoring-kube-prometheus-prometheus-0 -n observability
```

Do not delete a `Bound` claim or a PVC with a non-empty `VOLUME` unless its
data is backed up and you intend to remove it. The StatefulSet is managed by
Prometheus Operator and should be recreated automatically; verify with
`kubectl get pods,pvc -n observability`.

## Metrics and limitations

The worker exports the following Prometheus metrics:

| Metric | Type | Meaning |
| --- | --- | --- |
| `worker_in_flight_jobs` | Gauge | Jobs currently being processed by this worker pod |
| `worker_jobs_processed_total` | Counter | Successfully processed jobs |
| `worker_jobs_duplicate_total` | Counter | Duplicate jobs skipped |
| `worker_jobs_error_total` | Counter | Failed jobs |

Counters are process-local and reset when a pod restarts; use `rate()` or
`increase()` and aggregate across pods for dashboards. Kubernetes replica
panels use kube-state-metrics, included with kube-prometheus-stack.

The worker does not currently export SQS queue depth, per-job duration, or
T0–T6 autoscaling timestamps. Queue depth is available from AWS CloudWatch and
the KEDA scaler, but neither source is configured here as a Prometheus target.
Consequently, the dashboard shows worker throughput, errors, in-flight work,
replicas, and logs—not queue depth or control-loop latency. Do not interpret
the scrape interval as an autoscaling latency measurement. the T0–T6
measurement process and its external evidence are described in
[`docs/control-loop-latency.md`](../docs/control-loop-latency.md).

Loki in this configuration is a single-binary, filesystem-backed deployment
with one replica and seven-day log retention. It is suitable for development
and controlled experiments, not highly available production use. Use durable,
shared object storage and a production Loki deployment mode for production.

## Follow-up work

- Pin Helm chart versions and validate values against those versions.
- Add SQS queue depth, API request metrics, worker duration histograms, and
  T0–T6 signals to Prometheus and the dashboard.
- Add alert rules and a production logging/storage retention plan.
- Provision dashboards and datasources declaratively instead of importing
  dashboards manually.
