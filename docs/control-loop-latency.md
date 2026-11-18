# Measuring the KEDA Control Loop (T0–T6)

## Purpose and scope

This method measures how a job moves from API submission through SQS and KEDA
scale-up to successful worker processing. It separates queueing, scaling,
scheduling, and processing delays so a slow end-to-end result is not
incorrectly attributed to KEDA alone.

The measurements require a development EKS cluster with KEDA enabled, the SQS
queue used by the ScaledObject, and the worker deployed with the current
`/health` and `/metrics` endpoints. Docker Compose with ElasticMQ is useful for
validating API-to-worker delivery, but it does not run KEDA and cannot measure
the KEDA control loop.

## Event definitions

Use one unique `job_id` per request and correlate every record by that ID.
Times are UTC ISO-8601 timestamps with milliseconds where available.

| Mark | Event | Preferred source | Notes |
| --- | --- | --- | --- |
| **T0** | API begins accepting the job request | API log field `api_received_at` | This is the operational start of the measured job. k6 also includes `client_sent_at` for client-to-API diagnostics. |
| **T1** | SQS accepts the message | API `[SQS SENT]` log field `enqueued_at`; corroborate with the worker's SQS `SentTimestamp` attribute | `enqueued_at` is recorded immediately after the successful `SendMessage` response. |
| **T2** | KEDA observes a queue metric that satisfies the scale trigger | Timestamped KEDA operator/scaler log or a sampled KEDA external metric | KEDA does not necessarily log every poll at its default log level. If no qualifying observation is observable, report T2 as unavailable rather than infer an exact value. |
| **T3** | Desired worker replicas first increase above the pre-test baseline | Timestamped Deployment/HPA watch or a 1-second poll of `Deployment.spec.replicas` | A polling timestamp is an observation, not the exact control-plane write time. Record the sampling interval. |
| **T4** | Replacement/scale-up worker Pod is created | Pod `metadata.creationTimestamp` | Obtain from the Kubernetes API. Keep the Pod name and node/AZ in the run record. |
| **T5** | That Pod first becomes Ready | Pod Ready condition `lastTransitionTime` | Read the condition associated with `type=Ready`, not the time the test client first notices readiness. |
| **T6** | The correlated job is successfully processed | Worker `[JOB SUCCESS]` log field `completed_at` | A redelivered job can have multiple `[JOB START]` records; use the successful completion for T6. |

The API records `api_received_at` and `enqueued_at`; the worker logs
`client_sent_at`, SQS `SentTimestamp` when supplied, receive count, job start,
and completion. For T2–T5, collect KEDA logs and Kubernetes API state/events
alongside the application logs. These are separate clocks; synchronize clients
and nodes (Amazon Time Sync Service on EC2), retain UTC, and record any known
clock offset. Do not calculate cross-host intervals when clock skew is
unknown.

T0/T1/T6 are job-level events. T2–T5 are usually **run/scale-event-level**
events because one backlog threshold crossing can affect many jobs. Correlate
them to a defined load step or the first job in that step that causes the
trigger; do not duplicate one scale event as independent per-job samples.

## Derived intervals

Calculate intervals per job/run where the events are observable:

| Interval | Formula | Interpretation |
| --- | --- | --- |
| API-to-queue | `T1 - T0` | API processing plus SQS enqueue acknowledgement |
| Queue detection | `T2 - T1` | Time until KEDA observes a scale-triggering metric |
| Scale decision | `T3 - T2` | KEDA/HPA decision and desired-replica update |
| Pod startup | `T5 - T4` | Scheduling, image pull, container startup, and readiness |
| Queue-to-capacity | `T5 - T1` | End-to-end scale-up time to a Ready worker |
| Ready-to-job-start | `worker JOB START - T5` | Polling/backlog delay after a worker is Ready |
| Processing | `T6 - worker JOB START` | Worker processing duration |
| Job end-to-end | `T6 - T0` | Full observed path from API receipt to successful completion |

Do not use `T6 - T5` as pure processing time: it also includes queue polling
and dispatch. Likewise, `T5 - T1` is an observed scale-to-capacity result, not
a KEDA-only latency.

For T2, use the actual first qualifying scaler observation only if the
instrumentation exposes it. If T2 is estimated from sampled metrics, label it
`T2_observed` and report its sampling interval. If it is unavailable, report
`T2` and `T3-T2` as unavailable; still report `T5-T1` and `T6-T0`.

## Experimental design

1. Use a dev-only queue and cluster. Record the Git revision, cluster/region,
   KEDA version, ScaledObject settings, queue visibility timeout, worker image,
   node types/AZs, and test-run ID.
2. Verify KEDA is healthy, the ScaledObject is Ready, and no other workload is
   adding messages to the queue. Record initial queue depth and worker replica
   count.
3. Keep the worker image, process time, queue, `pollingInterval`,
   `cooldownPeriod`, `queueLength`, and node capacity constant between runs.
   Change one factor at a time.
4. Run one low-load baseline and at least five repeatable scale-up trials.
   Allow the queue and replicas to return to the same baseline between trials.
   Do not run trials concurrently.
5. Capture application logs, KEDA logs, Deployment/HPA observations, Pod
   timestamps, k6 CSV, and the final queue/replica state. Record failed,
   dropped, or uncorrelated jobs rather than excluding them silently.
6. Report sample count, median (p50), p90, p95, min/max, and spread for each
   interval. Include missing-event counts and observer resolution. Do not
   claim precision finer than the timestamp source or polling interval.

The current ScaledObject polls every 15 seconds and the Kubernetes HPA
controller also samples periodically. Queue arrival just after a poll can
therefore add nearly one polling interval before the next observation. This
phase relationship is expected variability; preserve it in repeated trials
instead of reporting a single best run.

## Evidence and interpretation

Save the k6 CSV and a short run manifest in `docs/evidence/`. Retain raw,
timestamped logs locally; redact account IDs, endpoints, and other sensitive
details before sharing them. The CSV output includes k6 metric timestamps,
`run_id` tags, HTTP timing metrics, `enqueue_ack_ms`, and `accepted_jobs`.
Application/Kubernetes logs provide per-job and scale-event correlation.

If `minReplicaCount` is already at the required capacity, the run does not
measure scale-up. If KEDA is absent, the ScaledObject is not Ready, the queue
trigger is not configured for the test queue, or metrics are not observable,
do not label the result a KEDA measurement. See
[`scripts/metrics/collect-control-loop-latency.md`](../scripts/metrics/collect-control-loop-latency.md)
for the collection procedure.
