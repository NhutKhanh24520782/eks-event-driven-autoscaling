# Experiment Plan & Execution Guide

## 1. Safety Principles and Test Order

To ensure safe, non-destructive, and cost-controlled testing on Amazon EKS, all experiments must be executed in the following strict three-tier sequence:

```
┌─────────────────┐       ┌──────────────────────┐       ┌──────────────────────┐
│ Tier 1:         │  ──►  │ Tier 2:              │  ──►  │ Tier 3:              │
│ Baseline Test   │       │ Load & Scale-Out     │       │ Worker Pod Failure   │
│ (1 VU steady)   │       │ (Bounded to 10 VUs)  │       │ (SQS Redelivery Check│
└─────────────────┘       └──────────────────────┘       └──────────────────────┘
                                                                    │
                                                                    ▼
                                                         ┌──────────────────────┐
                                                         │ GATED: Node / AZ     │
                                                         │ Failure (NOT RUN     │
                                                         │ without team sign-off│
                                                         └──────────────────────┘
```

### Preflight Verification Checklist
Before running any experiment:
1. Verify Kubernetes context: must be the dedicated development EKS cluster (`multiaz-eks`).
2. Verify SQS Queue: must be the dedicated test queue (`jobs-queue`).
3. Verify queue depth: `ApproximateNumberOfMessages` and `ApproximateNumberOfMessagesNotVisible` must be 0.
4. Verify ScaledObject: KEDA ScaledObject `worker-scaledobject` must report `Ready=True`.
5. Verify baseline replicas: worker deployment must be at steady state (`replicas=1` or `2`).
6. Do not run multiple load tests concurrently.

---

## 2. Tier 1: Baseline Experiment

### Objective
Measure baseline single-job performance without queueing delays, autoscaler intervention, or contention.

### Execution

#### PowerShell (Windows):
```powershell
$runId = "baseline-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$apiUrl = "http://<DEV-ALB-HOSTNAME>"

# 1. Start Collector in Terminal 1
.\scripts\metrics\collect-control-loop-latency.ps1 -RunId $runId -QueueUrl "<DEV-QUEUE-URL>" -CollectionDurationSeconds 120

# 2. Run k6 in Terminal 2
.\scripts\load-test\run-k6.ps1 -Profile baseline -RunId $runId -ApiUrl $apiUrl -BaselineVUs 1 -ProcessTimeMs 1000
```

#### Bash (Linux / macOS / Git Bash):
```bash
RUN_ID="baseline-$(date -u +%Y%m%dT%H%M%SZ)"
API_URL="http://<DEV-ALB-HOSTNAME>"
mkdir -p "docs/evidence/$RUN_ID"

# Run k6
./scripts/load-test/run-k6.sh baseline "$API_URL"
```

### Success Criteria
- HTTP 202 acceptance rate = 100%.
- API-to-SQS enqueue time (`T1 - T0`) p95 < 20ms.
- Worker processing duration (`T6 - JOB START`) = 1000ms ± 5ms.
- No autoscaler rescaling triggered (queue depth remains < 5).

---

## 3. Tier 2: Load Increase & Autoscaling Experiment

### Objective
Subject the system to an increasing workload that exceeds the capacity of the baseline worker replica, triggering KEDA scale-out up to the required replica count, followed by queue drainage and cooldown scale-down.

### Profile Parameters
- Concurrency: Ramp from 1 to 10 VUs over 30s, hold at 10 VUs for 60s, ramp down over 30s.
- Total expected messages: ~400–450 jobs.
- Job processing time: 1000ms.
- KEDA ScaledObject target: `queueLength=5`.

### Execution

#### PowerShell (Windows):
```powershell
$runId = "load-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$apiUrl = "http://<DEV-ALB-HOSTNAME>"

# 1. Start Collector in Terminal 1
.\scripts\metrics\collect-control-loop-latency.ps1 -RunId $runId -QueueUrl "<DEV-QUEUE-URL>" -CollectionDurationSeconds 240

# 2. Run k6 in Terminal 2
.\scripts\load-test\run-k6.ps1 -Profile load -RunId $runId -ApiUrl $apiUrl -PeakVUs 10 -ProcessTimeMs 1000
```

#### Bash (Linux / macOS / Git Bash):
```bash
RUN_ID="load-$(date -u +%Y%m%dT%H%M%SZ)"
API_URL="http://<DEV-ALB-HOSTNAME>"
./scripts/load-test/run-k6.sh load "$API_URL" 10
```

### Post-Test Verification
- Verify that SQS visible backlog returns to 0.
- Verify that Worker desired and ready replicas scale down to baseline after `cooldownPeriod` (default 300s).

---

## 4. Tier 3: Worker Pod Failure (Self-Healing & Redelivery)

### Objective
Verify that when an active Worker Pod is terminated unexpectedly while processing an in-flight job, the message is not lost: SQS Visibility Timeout protects the message, allows redelivery, and a replacement Pod successfully completes the task.

### Execution

#### PowerShell (Windows):
```powershell
$env:CHAOS_ENVIRONMENT = "dev"
$env:KUBE_CONTEXT = (kubectl config current-context)
$env:API_URL = "http://<DEV-ALB-HOSTNAME>"
$env:AWS_REGION = "ap-southeast-1"
$env:SQS_QUEUE_URL = "<DEV-QUEUE-URL>"

.\scripts\chaos\pod-failure.ps1
```

#### Bash (Linux / macOS / Git Bash):
```bash
export CHAOS_ENVIRONMENT=dev
export KUBE_CONTEXT="$(kubectl config current-context)"
export API_URL="http://<DEV-ALB-HOSTNAME>"
export AWS_REGION=ap-southeast-1
export SQS_QUEUE_URL="<DEV-QUEUE-URL>"

bash scripts/chaos/pod-failure.sh
```

### Verification Criteria
- Active worker pod running the long-running job is deleted.
- Kubernetes replica controller schedules a replacement Pod (Pod RTO measured in seconds).
- SQS Visibility Timeout expires (60s).
- Message `ApproximateReceiveCount` increments to 2.
- Replacement worker logs `[REDELIVERY]` and `[JOB SUCCESS]`.
- Dead Letter Queue (DLQ) remains at 0 messages.
- Total message loss = 0.

---

## 5. Tier 4: Node Failure & AZ Failure (Gated — NOT RUN)

Node draining and Availability Zone capacity termination are **strictly gated** and **not executed** in standard runs.
Execution is prohibited until the team establishes:
1. Confirmation of complete cluster isolation (zero shared dependencies).
2. Explicit cost limits and budget caps.
3. Pre-defined rollback and uncordon automation.
4. Second-person operator confirmation.

Refer to [`fault-tolerance.md`](fault-tolerance.md) for planning checklists.

---

## 6. Correlation and Post-Run Analysis

After each experiment completes, run the analyzer to generate correlated latency CSVs and summary percentiles:

```bash
# Using Node.js (Universal / Windows / Linux)
node scripts/metrics/analyze-control-loop-latency.js "docs/evidence/<run-id>"

# Or using Python (where python3 is available)
python scripts/metrics/analyze-control-loop-latency.py "docs/evidence/<run-id>"
```

Output artifacts generated in `docs/evidence/<run-id>/`:
- `job-latencies.csv`: Correlated T0, T1, and T6 timestamps with per-job intervals.
- `run-latencies.csv`: T2, T3, T4, T5 system-level scaling intervals.
- `latency-summary.csv`: Percentiles (min, p50, p90, p95, max) for `api_to_sqs_ms`, `worker_processing_ms`, and `job_end_to_end_ms`.
- `latency-analysis.json`: Integrity verification, total correlated jobs, and missing event counts.
- `summary.md`: Markdown narrative summarizing outcomes, RTO, and autoscaling dynamics.

---

## 7. Historical Evidence Index

| Run ID | Type | Workload / Traffic | Jobs Correlated | Scale Replicas | p50 End-to-End | p95 End-to-End | Status |
|---|---|---|---|---|---|---|---|
| `baseline-20261118T1152Z` | Baseline | 1 VU, 30s | 38 | 1 → 1 (steady) | 1036.0 ms | 1076.6 ms | PASS |
| `load-20261118T1155Z` | Scale-out | Ramp to 10 VUs, hold 60s | 434 | 1 → 4 (KEDA scaled) | 2676.0 ms | 12261.5 ms | PASS |
| `pod-failure-20261118T1205Z` | Chaos | Active Pod Termination | 1 (in-flight) | Pod healed in 8.2s | RTO: 8.2s | Redelivered: Yes | PASS |
| `pod-failure-20261118T1345Z` | Chaos | Visibility Timeout Redelivery | 1 (in-flight) | Replacement Ready in 9.1s | Visibility: 60s | Zero Data Loss | PASS |
