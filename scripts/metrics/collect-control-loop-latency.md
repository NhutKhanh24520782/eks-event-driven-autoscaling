# Collecting Control-Loop Latency

This runbook collects evidence for T0–T6 as defined in
[`docs/control-loop-latency.md`](../../docs/control-loop-latency.md). Run it
only in a development EKS environment. Local Docker Compose tests API-to-worker
delivery but has no KEDA control loop.

## Prerequisites

- `kubectl`, `k6`, and Bash (Git Bash/WSL is suitable for the shell examples).
- Access to the intended EKS context and read access to `app` and `keda`.
- A Ready `worker-scaledobject` targeting the same dev SQS queue as the API.
- Synchronized UTC clocks. Record the local machine's time source/offset if
  using client timestamps.
- A quiet queue and no concurrent load generators.

Confirm the target before collecting:

```bash
kubectl config current-context
kubectl get scaledobject,hpa -n app
kubectl describe scaledobject worker-scaledobject -n app
kubectl get pods -n app -o wide
kubectl get nodes -L topology.kubernetes.io/zone
```

Check that the ScaledObject is Ready and its queue URL, region, trigger
threshold, minimum/maximum replicas, polling interval, and cooldown match the
test plan. Do not proceed if the current context or queue is uncertain.

## Start collectors

From the repository root, create a unique run directory. Keep the ID the same
for k6, logs, and the run manifest:

```bash
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="docs/evidence/$RUN_ID"
mkdir -p "$OUT"
printf 'run_id=%s\nstarted_at=%s\ncontext=%s\n' \
  "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
  "$(kubectl config current-context)" > "$OUT/run.txt"
```

In a collector terminal, save timestamped application and KEDA logs:

```bash
# In each terminal, set the same run ID created above.
RUN_ID='<run-id>'
OUT="docs/evidence/$RUN_ID"
mkdir -p "$OUT"

kubectl logs -n app -l app=api-service --all-containers=true \
  --prefix --timestamps --since=2m -f > "$OUT/api.log" 2>&1
```

Run the API, worker, and KEDA log collectors in separate terminals. For the
worker and KEDA operator use:

```bash
kubectl logs -n app -l app=worker-service --all-containers=true \
  --prefix --timestamps --since=2m -f > "$OUT/worker.log" 2>&1
kubectl logs -n keda deployment/keda-operator \
  --timestamps --since=2m -f > "$OUT/keda-operator.log" 2>&1
```

The log commands follow until interrupted with Ctrl+C. KEDA's default log
level may not emit each polling observation. Do not change a shared cluster's
operator log level for this test; if T2 is not logged, mark it unavailable or
use a separately approved dev-only metrics collection method.

In another terminal, sample desired/ready replicas once per second. These are
client observation times; state that resolution in the results:

```bash
RUN_ID='<run-id>'
OUT="docs/evidence/$RUN_ID"
mkdir -p "$OUT"
while true; do
  printf '%s\t' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  kubectl get deployment worker-service -n app \
    -o jsonpath='desired={.spec.replicas} ready={.status.readyReplicas}{"\n"}'
  sleep 1
done > "$OUT/replicas.tsv" 2>&1
```

Capture a pre-test baseline for queue depth (CloudWatch/SQS metrics), worker
replicas, Pod placement, and `worker_jobs_processed_total`. The current worker
does not export queue depth or KEDA event timestamps as Prometheus metrics.

## Run the workload and save CSV

The k6 script uses the API response time as the `enqueue_ack_ms` trend and
tags samples with `run_id`. Each request has a unique job ID containing that
run ID and includes `client_sent_at`; API and worker logs correlate the ID.

```bash
RUN_ID='<run-id>'
OUT="docs/evidence/$RUN_ID"
mkdir -p "$OUT"
API_URL="https://<DEV-ALB-HOSTNAME>"
k6 run \
  -e API_URL="$API_URL" \
  -e RUN_ID="$RUN_ID" \
  --out "csv=$OUT/k6.csv" \
  scripts/load-test/k6-workload.js
```

For local Compose only, use `API_URL=http://localhost:3000`; this does not
produce KEDA measurements. The default k6 profile ramps to 50 VUs and may
create a backlog. Use only a dev queue, confirm cost/limits, and stop the test
if errors, queue age, or resource usage exceed the agreed bounds.

While the test runs, record the first qualifying KEDA observation (T2), the
first increase in desired replicas (T3), and any HPA/ScaledObject events. After
the run, capture Pod creation timestamps and Ready transition timestamps:

```bash
kubectl get pods -n app -l app=worker-service -o json \
  > "$OUT/worker-pods.json"
kubectl get events -n app --sort-by=.metadata.creationTimestamp \
  > "$OUT/app-events.txt"
kubectl get hpa,scaledobject -n app -o yaml \
  > "$OUT/autoscaler-final.yaml"
kubectl get pods -n app -o wide > "$OUT/pods-final.txt"
```

Correlate the k6 job IDs with API `[SQS SENT]` records and worker
`[JOB START]`, `[REDELIVERY]`, and `[JOB SUCCESS]` records. For each job,
record T0–T6, source, UTC timestamp, observer resolution, and whether it is
measured, estimated, or unavailable. Calculate intervals using the formulas
in the methodology document; do not infer T2 from a replica change.

## Close out and report

- Stop all log and replica collectors with Ctrl+C.
- Record the queue depth, desired/ready replicas, and any remaining backlog.
- Confirm accepted jobs eventually reached success or document why not.
- Report run ID, test settings, sample/missing counts, p50/p90/p95, and
  measurement limitations.
- CSV files under `docs/evidence/` are not ignored by Git. Review them and
  remove any sensitive data before committing; other raw logs may remain local
  unless explicitly selected as sanitized evidence.
