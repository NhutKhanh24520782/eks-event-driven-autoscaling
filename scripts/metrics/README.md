# Metrics Collection

The current worker exposes process-local counters and a gauge at `/metrics`:

- `worker_in_flight_jobs`
- `worker_jobs_processed_total`
- `worker_jobs_duplicate_total`
- `worker_jobs_error_total`

The API logs `api_received_at` and `enqueued_at` by `job_id`. The worker logs
job start, SQS receive count/SentTimestamp when available, redelivery, and
successful completion timestamps. k6 emits a run-tagged CSV containing request
metrics and the `enqueue_ack_ms` trend.

The application does not currently export queue depth or a KEDA polling
timestamp as Prometheus metrics. T2 may therefore be estimated from
timestamped scaler logs/metrics or reported unavailable; do not infer it from
the replica change. Kubernetes Pod creation and Ready condition timestamps
provide T4 and T5.

Use the step-by-step
[`collect-control-loop-latency.md`](collect-control-loop-latency.md) procedure
and report limitations with the T0–T6 method in
[`docs/control-loop-latency.md`](../../docs/control-loop-latency.md).
