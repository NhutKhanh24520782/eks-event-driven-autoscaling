# Prometheus

Prometheus is deployed with the Prometheus Operator through the
`kube-prometheus-stack` Helm chart. The root
[`prometheus-values.yaml`](../prometheus-values.yaml) configures seven-day
retention, persistent storage, Grafana, and the Loki datasource.

The API is scraped by [`api-podmonitor.yaml`](api-podmonitor.yaml). Worker
metrics use the existing
[`ServiceMonitor`](../../k8s/config/worker-servicemonitor.yaml) in the `app`
namespace. Do not install a second worker monitor: duplicate scraping creates
duplicate worker time series and can inflate throughput aggregates.

Verify both API and worker targets in **Status → Targets** in Prometheus.
Available metrics and their limitations are documented in the
[`observability README`](../README.md#metrics-and-limitations).

## Follow-up work

- Pin the chart version and verify Prometheus retention/storage capacity.
- Add queue-depth and API/worker latency metric sources.
- Add alert rules for scrape failures, worker errors, and autoscaler health.
