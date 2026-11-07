# Prometheus

Prometheus is deployed with the Prometheus Operator through the
`kube-prometheus-stack` Helm chart. The root
[`prometheus-values.yaml`](../prometheus-values.yaml) configures seven-day
retention, persistent storage, Grafana, and the Loki datasource.

[`worker-podmonitor.yaml`](worker-podmonitor.yaml) selects worker pods in the
`app` namespace and scrapes their named `metrics` port at `/metrics`. Apply it
after installing the chart, which provides the `PodMonitor` CRD. The stack's
`podMonitorSelectorNilUsesHelmValues: false` setting allows this monitor to be
selected without release-specific labels.

Verify the `worker-service` target in **Status → Targets** in Prometheus.
Available metrics and sources not yet integrated (SQS queue depth and T0–T5
latency) are documented in the
[`observability README`](../README.md#metrics-and-limitations).

## Follow-up work

- Pin the chart version and verify Prometheus retention/storage capacity.
- Add queue-depth and API/worker latency metric sources.
- Add alert rules for scrape failures, worker errors, and autoscaler health.
