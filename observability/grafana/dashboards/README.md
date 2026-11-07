# Grafana dashboards

`autoscaling-overview.json` is a ready-to-import dashboard for the worker metrics
and Kubernetes replica metrics available in this repository. It includes a Loki
log panel when the Loki datasource is configured.

Import it from **Grafana → Dashboards → New → Import** and upload the JSON file.
Choose the Prometheus and Loki datasources when prompted if Grafana does not
automatically match them.

The dashboard does not show SQS queue depth or T0–T5 control-loop latency:
neither is currently exported as a Prometheus metric. See the observability
README for the available metrics and measurement limitations.

## Follow-up work

- Add queue depth, autoscaler state, API latency, and processing-duration
  panels after integrating their data sources.
- Add dashboard provisioning and test the JSON against the deployed Grafana
  version.
- Include links to experiment evidence and operational runbooks.
