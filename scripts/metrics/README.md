# Metrics Collection

`collect-control-loop-latency.md` is currently a placeholder for collecting
autoscaling control-loop timestamps. The worker currently exports processing
counters and an in-flight gauge, but no SQS queue-depth metric or T0–T6
timestamps. The dashboard therefore cannot calculate end-to-end autoscaling
latency from the existing application metrics.

For current worker metrics and Prometheus setup, see
[`observability/README.md`](../../observability/README.md). For the planned
measurement scope, see [`docs/control-loop-latency.md`](../../docs/control-loop-latency.md).

## Follow-up work

- Define observable timestamp sources for job creation, SQS visibility,
  KEDA polling, replica changes, pod scheduling/readiness, and first
  successful processing.
- Use synchronized clocks and identify whether each event comes from client,
  AWS, Kubernetes, or worker logs.
- Export histogram/event metrics without unbounded labels such as job IDs.
- Automate run metadata, calculations, percentiles, and evidence capture.
