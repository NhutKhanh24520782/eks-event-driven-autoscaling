# Grafana

Grafana is installed as part of `kube-prometheus-stack`. The provided values
configure persistence, an existing admin Secret, and a Loki datasource.
Follow [`observability/README.md`](../README.md) for installation and access.

The [`dashboards/`](dashboards/README.md) directory contains an importable
worker overview dashboard. It currently charts worker counters/gauges,
Deployment replica metrics, and worker logs.

## Follow-up work

- Provision dashboards automatically through ConfigMaps or chart sidecars.
- Add autoscaler conditions, SQS depth, DLQ, pod readiness, and latency panels
  when those metrics are integrated.
- Add alert rules with documented thresholds and runbooks.
- Validate dashboard datasource identifiers against the deployed chart.
