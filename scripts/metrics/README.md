# Metrics Collection

Use [`collect-control-loop-latency.sh`](collect-control-loop-latency.sh) to
capture timestamped API/worker/KEDA logs, SQS attributes, replica samples,
Pod snapshots, and live Kubernetes Event changes from the `app` and `keda`
namespaces. Run k6 separately and use
[`analyze-control-loop-latency.py`](analyze-control-loop-latency.py) to
correlate per-job T0/T1/T6 and summarize observable intervals.

The API `/metrics` endpoint exports approximate visible, in-flight, and
delayed SQS message gauges by queue. The worker `/metrics` endpoint exports
process-local received/processed/duplicate/error counters, the in-flight
gauge, and `worker_job_processing_seconds` histogram. The API returns HTTP 503
if it cannot read SQS queue attributes; Prometheus marks the scrape failed
instead of receiving a fabricated zero.

T0 is k6's `client_sent_at`; T1 is the API's actual SQS enqueue acknowledgement;
T6 is the Worker `[JOB SUCCESS] completed_at` timestamp. API receive time is
kept separately for clock-skew checks. KEDA T2 is not guaranteed to appear in
default operator logs. Record it only from an actual timestamped qualifying
observation; otherwise leave it unavailable. T3 uses an actual HPA
`SuccessfulRescale` event, while T4/T5 use Kubernetes Pod creation and Ready
timestamps. Replica samples are for charts, not substitutes for scale events.
See
[`docs/control-loop-latency.md`](../../docs/control-loop-latency.md) for
formulas and cross-clock limitations.
