# Measuring the KEDA Control Loop Latency (T0–T6)

## 1. Purpose and Scope

In an event-driven architecture on Amazon EKS, understanding system performance requires decomposing the end-to-end latency of a request into its constituent components.

Attributing end-to-end delay solely to "KEDA" or "Kubernetes" is an analytical error. Delays can originate at multiple distinct layers:
1. API ingestion and network round-trip.
2. SQS visibility and queueing delays.
3. KEDA polling interval and metrics server synchronization.
4. Kubernetes HPA decision loop and Deployment reconciliation.
5. Kube-scheduler node selection, volume attachment, and image pulling.
6. Container startup, readiness probe verification, and SQS long-polling pickup.
7. Application business logic execution.

This document formalizes the **T0–T6 measurement methodology**, specifying event definitions, preferred data sources, mathematical intervals, observer resolutions, margin of error, and analytical rules.

---

## 2. Event Definitions (T0 to T6)

Each request is tagged with a unique, run-scoped `job_id` (e.g., `load-20261118T1155Z-vu2-iter5`). All timestamps are recorded in UTC ISO-8601 with millisecond precision where available.

```
  T0               T1           T2          T3             T4          T5            T6
  │                │            │           │              │           │             │
  ▼                ▼            ▼           ▼              ▼           ▼             ▼
[API Recv] ──► [SQS Enqueue] ──► [KEDA Poll] ──► [HPA Scale] ──► [Pod Create] ──► [Pod Ready] ──► [Job Done]
  │                │            │           │              │           │             │
  └──── T1 - T0 ───┴── T2 - T1 ─┴─ T3 - T2 ─┴─── T4 - T3 ──┴── T5 - T4 ─┴── T6 - T5 ──┘
                   │                                                   │
                   └───────────────────── T5 - T1 ─────────────────────┘
  │                                                                                  │
  └─────────────────────────────────── T6 - T0 ──────────────────────────────────────┘
```

| Mark | Event Definition | Canonical Source | Clock & Precision | Notes & Caveats |
|---|---|---|---|---|
| **T0** | Workload / job received by the API | API structured log: `api_received_at` | Node.js monotonic/system clock (ms) | Represents the instant the API route handler accepts the request body. |
| **T1** | Message acknowledged as sent to SQS | API log: `enqueued_at`; corroborated by SQS `SentTimestamp` attribute | Node.js system clock (ms) & AWS SQS clock | Recorded immediately upon successful return of `SendMessageCommand`. Corresponds to message visibility in the queue. |
| **T2** | KEDA observes scaling signal | KEDA Operator log: `scaler.go` or sampled external metric | KEDA container clock | ScaledObject polls SQS every 15s (`pollingInterval: 15`). T2 is an event-level timestamp, not per-message. If KEDA logging level does not expose the exact poll, mark as `unavailable`. |
| **T3** | Desired Worker replica count updated | HPA `SuccessfulRescale` event or 1-second Deployment spec poll | Kubernetes API server clock (sec/ms) | Transition of `Deployment.spec.replicas` from baseline (e.g. 1) to target (e.g. 4). Sampling rate introduces a ±1000ms measurement uncertainty. |
| **T4** | First new Worker Pod created | Kubernetes Pod `metadata.creationTimestamp` | Kubernetes API Server (1s resolution) | Instant the Pod object is committed to etcd and queued for scheduling. |
| **T5** | That Worker Pod becomes Ready | Kubernetes Pod condition `type=Ready`, `lastTransitionTime` | Kubelet node clock (1s resolution) | Container has started, passed the `/health` readiness probe, and begun polling SQS. |
| **T6** | Correlated job processed successfully | Worker log: `[JOB SUCCESS] completed_at` | Worker container clock (ms) | Timestamp recorded right after successful execution, immediately before `DeleteMessageCommand`. |

---

## 3. Derived Latency Formulas and Component Breakdown

| Metric Interval | Formula | Target Layer | Expected Value | Operational Significance |
|---|---|---|---|---|
| **API-to-Queue** | `T1 - T0` | Ingress & Network | 5–15 ms | API execution time + AWS SQS HTTP network round-trip. Spikes indicate network contention or AWS SQS rate limits. |
| **Queue Detection** | `T2 - T1` | KEDA Scaler | 0–15 s | Delay until KEDA's polling loop queries SQS and notices `ApproximateNumberOfMessages >= queueLength`. Dominated by `pollingInterval`. |
| **Scale Decision** | `T3 - T2` | KEDA + HPA Controller | 1–15 s | Time taken for KEDA External Metrics Server to serve the metric to Kubernetes HPA controller and trigger rescale. |
| **Pod Scheduling** | `T4 - T3` | Kube-Scheduler | 1–3 s | Time for `kube-scheduler` to evaluate node affinity, taints, and `topologySpreadConstraints`. |
| **Pod Startup & Ready** | `T5 - T4` | Kubelet & Container Engine | 3–8 s | Container image pull (cached), container creation, process boot, and initial HTTP readiness probe success. |
| **Queue-to-Capacity** | `T5 - T1` | End-to-End Autoscaling | 15–35 s | Composite latency from message arrival until a new worker is online and polling. |
| **Ready-to-Execution** | `worker JOB START - T5` | SQS Dispatch Delay | 1–5 s | Delay between Pod readiness and polling the specific message (depends on worker batch size and concurrency). |
| **Pure Processing** | `T6 - worker JOB START` | Worker Business Logic | User-configured (`processTimeMs`) | Monotonic timing of the job execution loop (`observeProcessingDuration`). |
| **End-to-End Job** | `T6 - T0` | Entire System Path | Baseline: ~1.05s<br>Under load: 2–20s | Full elapsed time from initial HTTP submission until complete processing. |

---

## 4. Measurement Uncertainty & Margin of Error

When analyzing latency data, the following physical and logical measurement boundaries **must** be accounted for:

### 4.1 Clock Drift & Synchronization
- **AWS Infrastructure**: EKS EC2 worker nodes utilize the **Amazon Time Sync Service** (accessible at `169.254.169.123` via Chrony), maintaining cross-node clock synchronization within a sub-millisecond envelope (< 1ms).
- **Client Clock Skew**: If the workload generator (k6) runs outside the AWS VPC, its local machine clock may drift by hundreds of milliseconds relative to AWS servers. Therefore, `T1 - T0` is measured strictly from the API container clock (`api_received_at` vs `enqueued_at`), eliminating client clock skew.

### 4.2 Observer Resolution & Polling Jitter
- **KEDA Polling Phase (`pollingInterval = 15s`)**: KEDA polls SQS periodically. If a message arrives immediately after a polling cycle, it will wait up to 14.99 seconds before KEDA observes it. If it arrives just before a cycle, detection is almost instantaneous (< 1s). This creates an inherent uniform distribution variance:
  $$\Delta t_{\text{detection}} \sim U(0, 15)\text{ seconds}$$
- **HPA Evaluation Sync Period (`--horizontal-pod-autoscaler-sync-period = 15s`)**: The Kubernetes controller manager syncs HPA recommendations every 15 seconds.
- **Kubernetes Condition Timestamps**: Conditions in `metadata.creationTimestamp` and `lastTransitionTime` have a **1-second truncation resolution** (ISO-8601 without fractional seconds). Any interval calculated using T4 or T5 carries a measurement uncertainty of $\pm 1000\text{ms}$.
- **SQS Approximate Counts**: Metrics from `GetQueueAttributes` (`ApproximateNumberOfMessages`) are statistical estimates from AWS distributed queue nodes, not exact atomic counters.

---

## 5. Analytical Discipline: Avoiding Premature Bottleneck Attribution

> **Principle**: Never declare a system bottleneck based on a single metric or an aggregate `T6 - T0` spike without decomposing each phase.

Follow this systematic isolation procedure:

1. **Rule 1 — Verify Ingress Health First**:
   If `T1 - T0` is high (> 100ms), the delay is at the API service or AWS SQS network tier, not in KEDA or the workers.
2. **Rule 2 — Differentiate Queue Wait from Processing Time**:
   If `T6 - T0` is large (e.g. 15s) while pure processing duration `T6 - JOB START` is normal (1s), the job spent 14s waiting in the SQS backlog. This is an expected consequence of capacity queuing before autoscaling completes.
3. **Rule 3 — Isolate Pod Scheduling from Image Startup**:
   Examine `T4 - T3` vs `T5 - T4`. If `T4 - T3` is long, the bottleneck is node capacity or scheduling constraints (Topology Spread, lack of CPU/Memory). If `T5 - T4` is long, the bottleneck is container image pull time or slow process initialization.
4. **Rule 4 — Compare Baseline vs Scaled Trials**:
   Evaluate median (p50), 90th percentile (p90), and 95th percentile (p95) across at least 3 distinct runs before reaching conclusions.
