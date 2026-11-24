# Load Test & Workload Generation

`k6-workload.js` generates controlled, repeatable HTTP workloads against the API service (`POST /jobs`). It publishes structured JSON payloads containing unique run-scoped `job_id`, UTC `client_sent_at`, and simulated `processTimeMs`.

All parameters can be configured via CLI flags or environment variables, allowing identical reproduction of experiments across local and EKS environments.

---

## 1. Workload Profiles

| Profile | Behavior & Stages | Intended Experiment |
|---|---|---|
| `smoke` | 1 VU for 2s | Quick sanity check to verify API connectivity and SQS reachability |
| `baseline` | 1 VU ramp (5s), hold (30s), ramp down (5s) | Establishes the baseline single-worker latency without queue backlog or scaling |
| `load` | 1 VU baseline (30s), ramp to 10 (60s), hold (120s), ramp down to 0 (30s) | 4-minute bounded event-driven autoscaling run |
| `spike` | 1 VU to 20 VUs in 5s, hold 30s, drop to 1 VU | Tests rapid backlog accumulation, scale-out responsiveness, and recovery |
| `stress` | Ramp to 20 VUs (20s), hold 40s at 20 VUs, ramp to 30 VUs (60s) | Validates upper capacity limits (`maxReplicaCount=10`) and multi-AZ pod balancing |
| `soak` | 3–5 VUs sustained for 3–10 minutes | Validates system memory stability, connection pools, and absence of leaks |

---

## 2. Configurable Parameter Reference

All variables can be passed as `-e NAME=value` to `k6 run`:

| Variable | Type / Constraints | Default | Description |
|---|---|---|---|
| `API_URL` | Valid HTTP/S URL | `http://localhost:3000` | Target endpoint without trailing `/jobs` |
| `RUN_ID` | String | Auto UTC timestamp | Correlates k6 logs, API records, and worker outcomes |
| `K6_PROFILE` | `smoke` \| `baseline` \| `load` \| `spike` \| `stress` \| `soak` | `baseline` | Active load generation profile |
| `PROCESS_TIME_MS` | Integer (1–60000) | `1000` | Job execution time requested by the client (ms) |
| `BASELINE_VUS` | Integer (1–50) | `1` | Concurrency for baseline runs |
| `PEAK_VUS` | Integer (1–50) | `10` | Peak concurrency for load & stress runs |
| `SPIKE_VUS` | Integer (1–50) | `20` | Peak concurrency for spike profile |
| `BASELINE_DURATION` | Duration string (`30s`, `1m`) | `30s` | Steady-state duration for baseline |
| `RAMP_UP_DURATION` | Duration string | `60s` | Ramp-up time to peak concurrency |
| `HOLD_DURATION` | Duration string | `120s` | Hold duration at peak concurrency |
| `RAMP_DOWN_DURATION` | Duration string | `30s` | Ramp-down duration back to 0 VUs |
| `SOAK_DURATION` | Duration string | `3m` | Sustained duration for soak profile |
| `REQUEST_PAUSE_SECONDS`| Float (0–60) | `1.0` (`0.1` on smoke)| Inter-request sleep per VU |
| `FAILURE_RATE` | Float (0.0–1.0) | `0.0` | Probability of injecting `shouldFail: true` to test DLQ |

---

## 3. Fast Reproduction Commands

### Option A: Using the Automated Runner Scripts

#### Windows PowerShell:
```powershell
# 1. Run Baseline Test
.\scripts\load-test\run-k6.ps1 -Profile baseline -ApiUrl "http://localhost:3000"

# 2. Run Scale-Out Load Test
.\scripts\load-test\run-k6.ps1 -Profile load -PeakVUs 10 -ApiUrl "http://<DEV-ALB-HOSTNAME>"

# 3. Run Sudden Spike Test
.\scripts\load-test\run-k6.ps1 -Profile spike -SpikeVUs 25 -ApiUrl "http://<DEV-ALB-HOSTNAME>"
```

#### Linux / macOS / Git Bash:
```bash
# Make executable
chmod +x scripts/load-test/run-k6.sh

# 1. Run Baseline Test
./scripts/load-test/run-k6.sh baseline "http://localhost:3000"

# 2. Run Scale-Out Load Test
./scripts/load-test/run-k6.sh load "http://<DEV-ALB-HOSTNAME>" 10

# 3. Run Spike Test with Custom Environment
PROFILE=spike SPIKE_VUS=25 API_URL="http://<DEV-ALB-HOSTNAME>" ./scripts/load-test/run-k6.sh
```

---

## 4. Manual k6 Invocations (Exact CLI syntax)

```bash
# Define experiment Run ID and directory
RUN_ID="load-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "docs/evidence/$RUN_ID"

# Execute bounded load profile
k6 run \
  -e API_URL="http://<DEV-ALB-HOSTNAME>" \
  -e RUN_ID="$RUN_ID" \
  -e K6_PROFILE=load \
  -e PEAK_VUS=10 \
  -e BASELINE_DURATION=30s \
  -e RAMP_UP_DURATION=60s \
  -e HOLD_DURATION=120s \
  -e RAMP_DOWN_DURATION=30s \
  -e REQUEST_PAUSE_SECONDS=1 \
  -e PROCESS_TIME_MS=1000 \
  --out "csv=docs/evidence/$RUN_ID/k6.csv" \
  scripts/load-test/k6-workload.js
```

---

## 5. Output Interpretation

Each run outputs:
- `accepted_jobs`: HTTP 202 responses acknowledged by SQS.
- `rejected_jobs`: HTTP 4xx/5xx failures (rate must stay `< 1%`).
- `enqueue_ack_ms`: Duration from client POST until SQS returns `SendMessageResult` (p95 target `< 500ms`).
- `k6.csv`: Raw second-by-second metrics saved in `docs/evidence/<run-id>/k6.csv`.

> **Important**: HTTP 202 signifies that the message was accepted by AWS SQS; it does **not** indicate that the worker has completed the job. Correlate with Worker logs and Prometheus `worker_jobs_processed_total` to measure true end-to-end completion.
