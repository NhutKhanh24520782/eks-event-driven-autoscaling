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
7. Deploy the API build that logs `client_sent_at` in `[SQS SENT]` before
   collecting a new run; otherwise jobs still queued at collector shutdown may
   not have a recorded T0.
8. On Windows, check time synchronization before measuring client-to-API latency:
   ```powershell
   w32tm /query /status
   w32tm /resync
   ```
   The k6 setup also estimates the client/API clock offset and reports its
   round-trip uncertainty. This correction does not replace NTP synchronization.

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
- API-to-SQS time (`T1 - api_received_at`) p95 < 20ms.
- No negative client-to-API intervals (`api_received_at - T0`).
- Worker processing duration (`T6 - JOB START`) = 1000ms ± 5ms.
- No autoscaler rescaling triggered (queue depth remains < 5).

---

## 3. Tier 2: Load Increase & Autoscaling Experiment

### Objective
Subject the system to an increasing workload that exceeds the capacity of the baseline worker replica, triggering KEDA scale-out up to the required replica count, followed by queue drainage and cooldown scale-down.

### Profile Parameters
- Phases: 1 VU baseline for 30s, ramp to 10 VUs over 60s, hold for 120s,
  then ramp down to 0 over 30s (4 minutes total).
- Request pacing: 1-second pause per VU to keep the workload bounded.
- Job processing time: 1000ms.
- KEDA ScaledObject target: `queueLength=5`.
- Allow additional time after k6 for backlog drainage and the 60-second KEDA
  cooldown; the collector runs for 660 seconds by default.

### Execution

#### PowerShell (Windows):
```powershell
$runId = "load-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$apiUrl = "http://<DEV-ALB-HOSTNAME>"

# 1. Start Collector in Terminal 1
.\scripts\metrics\collect-control-loop-latency.ps1 -RunId $runId -QueueUrl "<DEV-QUEUE-URL>" -CollectionDurationSeconds 660

# 2. Run k6 in Terminal 2
.\scripts\load-test\run-k6.ps1 -Profile load -RunId $runId -ApiUrl $apiUrl `
  -PeakVUs 10 -BaselineDuration 30s -RampUpDuration 60s `
  -HoldDuration 120s -RampDownDuration 30s -RequestPauseSeconds 1 `
  -ProcessTimeMs 1000
```

#### Bash (Linux / macOS / Git Bash):
```bash
RUN_ID="load-$(date -u +%Y%m%dT%H%M%SZ)"
API_URL="http://<DEV-ALB-HOSTNAME>"
K6_PROFILE=load PEAK_VUS=10 BASELINE_DURATION=30s RAMP_UP_DURATION=60s \
HOLD_DURATION=120s RAMP_DOWN_DURATION=30s REQUEST_PAUSE_SECONDS=1 \
./scripts/load-test/run-k6.sh load "$API_URL" 10
```

### Post-Test Verification
- Verify that SQS visible backlog returns to 0.
- Verify that Worker desired and ready replicas scale down to baseline after `cooldownPeriod` (60s in `keda-scaledobject.yaml`). Queue drainage can take longer and must be observed before stopping the collector.

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
# Canonical analyzer (Windows / Linux / macOS)
python scripts/metrics/analyze-control-loop-latency.py "docs/evidence/<run-id>"

# Optional Node.js compatibility launcher (requires Python)
node scripts/metrics/analyze-control-loop-latency.js "docs/evidence/<run-id>"
```

Output artifacts generated in `docs/evidence/<run-id>/`:
- `job-latencies.csv`: Per-job T0 (`client_sent_at`), T1 (`enqueued_at`),
  and T6 (`t6_completed`) timestamps and intervals. `api_received_at` is
  retained separately to audit clock skew.
- `scale-events.csv`: System-level T2–T5 rows only. T2/T3 remain unavailable
  unless captured from an actual KEDA/Prometheus or HPA event; they are never
  synthesized from one job or fixed offsets.
- `run-latencies.csv`: Intervals between captured T2, T3, T4, and T5 events.
- `latency-summary.csv`: Percentiles (min, p50, p90, p95, max) for `api_to_sqs_ms`, `worker_processing_ms`, and `job_end_to_end_ms`.
- `latency-analysis.json`: Integrity verification, negative client-to-API
  clock intervals, total correlated jobs, and missing event counts.
- `summary.md`: Markdown narrative summarizing outcomes, RTO, and autoscaling dynamics.

The collector stores Kubernetes Event snapshots from both `app` and `keda`
in `kubernetes-events.jsonl` while the test runs, plus final snapshots in
`app-events.json` and `keda-events.json`. Kubernetes Events can expire; the
live capture is required for reliable scale-event analysis. If T2 is sourced
from Prometheus or an operator log, record its observed UTC timestamp, source,
and uncertainty in `run-events.csv` (`mark=T2`). Do not infer it from the
configured polling interval.

---

## 7. Historical Evidence Index

| Run ID | Type | Workload / Traffic | Jobs Correlated | Scale Replicas | p50 End-to-End | p95 End-to-End | Status |
|---|---|---|---|---|---|---|---|
| `baseline-20261118T1152Z` | Baseline | 1 VU, 30s | 38 | 1 → 1 (steady) | 1036.0 ms | 1076.6 ms | PASS |
| `load-20261118T1155Z` | Scale-out | Ramp to 10 VUs, hold 60s | 434 | 1 → 4 (KEDA scaled) | 2676.0 ms | 12261.5 ms | PASS |
| `pod-failure-20261118T1205Z` | Chaos | Active Pod Termination | 1 (in-flight) | Pod healed in 8.2s | RTO: 8.2s | Redelivered: Yes | PASS |
| `pod-failure-20261118T1345Z` | Chaos | Visibility Timeout Redelivery | 1 (in-flight) | Replacement Ready in 9.1s | Visibility: 60s | Zero Data Loss | PASS |
| `baseline-20261123T142740Z` | Baseline (EKS Official) | 1 VU steady, 60s | 56 | 1 → 1 (steady, no scaling) | 1034.0 ms | 1050.0 ms | PASS |
| `load-20261123T143919Z` | Scale-out & In (EKS Official) | 10 VUs, short burst | 3241 | 1 → 4 → 1 (reported) | 56560.0 ms | 102411.2 ms | INCOMPLETE |

---

## 8. Chi Tiết Thực Nghiệm Chính Thức (EKS Official Benchmark Runs)

### 8.1 Run 1: Baseline Experiment (`baseline-20261123T142740Z`)
- **Mục tiêu**: Chứng minh hệ thống xử lý ổn định khi tải thấp, số Worker giữ nguyên ở `minReplicaCount = 1`, không kích hoạt autoscaling.
- **Dữ liệu**: [docs/evidence/baseline-20261123T142740Z/](evidence/baseline-20261123T142740Z/)
- **Kết quả đo lường thực tế**:
  - Tổng số jobs: **56/56 accepted (100%)**, không lỗi, 100% hoàn tất (`status = completed`).
  - `api_to_sqs_ms` ($T_1 - T_0$): Min = 6.0 ms, p50 = 7.0 ms, p95 = 13.25 ms.
  - `worker_processing_ms` (Pure worker duration): Min = 1000.0 ms, p50 = 1001.0 ms, p95 = 1002.0 ms.
  - `job_end_to_end_ms` ($T_6 - T_0$): Min = 1032.0 ms, p50 = 1034.0 ms, p95 = 1050.0 ms, Max = 1059.0 ms.
  - **Autoscaler**: Queue depth duy trì = 0, Desired Replicas = 1, Ready Replicas = 1 xuyên suốt bài đo.
  - **Clock Skew**: Độ lệch đồng hồ client ngoài VPC đo được là ~ -580 ms; $T_0$, $T_1$, $T_6$ được chuẩn hóa đồng bộ theo đồng hồ EC2 node (Amazon Time Sync Service).

### 8.2 Run 2: Scale-Out & Scale-In Experiment (`load-20261123T143919Z`)
- **Mục tiêu**: Tải tăng dần vượt ngưỡng `queueLength = 5` của KEDA để backlog dồn lên, ghi nhận chuỗi sự kiện scale-out từ 1 lên 4 Pods, giải tỏa backlog và tự động scale-in về 1 Pod sau cooldown.
- **Dữ liệu**: [docs/evidence/load-20261123T143919Z/](evidence/load-20261123T143919Z/)
- **Chuỗi mốc thời gian hệ thống (System Scale Events)**:
  - $T_0$: Bắt đầu phát tải dồn vào SQS (10 VUs, ~32 req/s).
  - $T_3$ (HPA Rescale): `2026-11-23T14:40:04.793Z` (HPA quyết định tăng replicas từ 1 lên 4).
  - $T_4$ (Pod Created): `2026-11-23T14:40:03.000Z` (Pod mới `worker-service-b4bc846b9-fbswn` được tạo trên node `ip-10-0-17-1`).
  - $T_5$ (Pod Ready): `2026-11-23T14:40:05.000Z` (Pod mới vượt qua readiness probe sau đúng 2.0s).
  - $T_4 \to T_5$ (Pod startup latency): **2000.0 ms** (2.0s).
  - First enqueue to Ready: **39,339 ms** (~39.3s từ request đầu tiên đến khi Pod mới online).
- **Kết quả đo lường độ trễ**:
  - Tổng jobs nhận vào SQS: **3,241 jobs** (HTTP 202: 100%); evidence analyzer reports **2,301 jobs without T0 and T6**, plus **940 negative client-to-API intervals**.
  - `api_to_sqs_ms`: Min = 4.0 ms, p50 = 7.0 ms, p95 = 14.0 ms.
  - `job_end_to_end_ms`: Các percentile chỉ áp dụng cho jobs có T6; không đại diện cho toàn bộ 3,241 jobs.
  - **Acceptance status: INCOMPLETE**. `run-events.csv` is empty (T2 unavailable), the prior report inferred T3 from a one-second replica sample observed after T4, and the updated analysis finds 2,301 jobs without T0/T6 plus 940 negative client-to-API intervals. These artifacts do not prove a complete T2–T5 timeline, valid cross-clock T0, or full job completion. Keep this run as historical evidence, but rerun with the updated collector and analyzer before using it as final evidence.

Final evidence for this workload must be collected with the updated scripts and re-run; historical artifacts are not retroactively corrected.
