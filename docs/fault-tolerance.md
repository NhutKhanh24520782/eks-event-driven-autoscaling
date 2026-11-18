# Fault-Tolerance & Resilience Architecture

This document details the failure modes, resilience mechanisms, and chaos experiment verification for the **Multi-AZ Event-Driven Autoscaling microservices system on Amazon EKS**.

---

## 1. Resilience Architecture Overview

The system is designed with defense-in-depth across the microservice, queue, and cluster orchestration layers:

```
                  ┌────────────────────────────────────────────────────────┐
                  │                 Failure Resilience Tiers               │
                  │                                                        │
Microservice      │  • In-memory TTL Deduplication Cache (Idempotency)     │
Application       │  • Graceful SIGTERM shutdown handler (25s drain wait)  │
                  │  • ReceiveCount & DLQ routing for poison messages     │
                  ├────────────────────────────────────────────────────────┤
Message Queue     │  • SQS Visibility Timeout (60s at-least-once delivery) │
(AWS SQS)         │  • Dead Letter Queue (DLQ) after 3 receive attempts    │
                  │  • Cross-AZ durable message storage by AWS             │
                  ├────────────────────────────────────────────────────────┤
Kubernetes &      │  • Pod Topology Spread Constraints across 3 AZs        │
EKS Orchestration │  • Automatic Pod self-healing via ReplicaSet controller│
                  │  • KEDA event-driven autoscaling based on queue depth  │
                  └────────────────────────────────────────────────────────┘
```

---

## 2. Tested Scenario: Worker Pod Termination (Chaos Test)

### 2.1 Mechanism of Protection (At-Least-Once Delivery)
When a Worker Pod is forcibly terminated while processing an active in-flight job:
1. **Unacknowledged Message**: The Worker has received the message from SQS, but has **not** issued `DeleteMessageCommand`.
2. **Visibility Timeout Window**: The message remains "in-flight" (invisible to other workers) in SQS for the configured `VisibilityTimeout` (currently 60s).
3. **Pod Self-Healing**: The Kubernetes Deployment controller detects that current running replicas are below desired replicas, and immediately schedules a replacement Worker Pod. The new Pod becomes Ready within **~8 to 10 seconds**.
4. **Visibility Expiration & Redelivery**: Once the 60-second visibility timeout expires, SQS automatically makes the message visible again.
5. **Worker Pickup**: The replacement Worker Pod receives the message during its long-polling loop (`ReceiveMessageCommand`).
6. **Redelivery Detection**: SQS reports `ApproximateReceiveCount = 2`. The worker logs:
   ```
   [WORKER worker-service-789] [REDELIVERY] Message is being retried! job_id=chaos-job-xxx, receive_count=2
   ```
7. **Successful Completion & Deletion**: The replacement worker finishes the job, logs `[JOB SUCCESS]`, and safely issues `DeleteMessageCommand`.

### 2.2 Critical Timing Constraint
For fault-tolerant redelivery to work without premature duplicate execution:
$$\text{Worker Processing Time} < \text{Worker Graceful Shutdown Wait (25s)} < \text{SQS Visibility Timeout (60s)}$$

If the visibility timeout were shorter than processing time, SQS would redeliver the message while the first worker was still processing it, causing false duplication.

---

## 3. Idempotency & Deduplication Under Chaos

In distributed systems, network partitions or process crashes right after processing but before `DeleteMessageCommand` can cause duplicate deliveries.

To protect business logic against duplicate execution:
1. Every message carries a unique, invariant `job_id`.
2. Each Worker maintains an in-memory `IdempotencyCache` backed by a sliding TTL window (default 10 minutes).
3. Upon receiving a message, the worker checks `deduplicationCache.isDuplicate(jobId)`:
   - If true: The worker skips processing, increments the Prometheus counter `worker_jobs_duplicate_total`, logs `[IDEMPOTENT SKIP]`, and safely deletes the duplicate from SQS:
     ```
     [WORKER worker-service-456] [IDEMPOTENT SKIP] Duplicate detected for job_id=xxx. Deleting without reprocessing.
     ```
   - If false: The worker proceeds with processing and records the `job_id` upon completion.

---

## 4. Poison Pill Handling & Dead Letter Queue (DLQ)

If a message has a malformed payload or triggers an unhandled application exception (`shouldFail: true`):
1. The worker catches the exception in `processSingleMessage`.
2. **Intentional Non-Deletion**: The worker logs `[JOB FAILURE]` and **does not** delete the message from SQS.
3. SQS redelivers the message after visibility timeout expires.
4. If the message fails `maxReceiveCount` (configured to 3 attempts), SQS automatically transfers the message to the Dead Letter Queue (`jobs-queue-dlq`).
5. This prevents a bad message from infinitely blocking worker concurrency (Poison Pill protection).

---

## 5. Multi-AZ Pod Topology Spread

Worker Pods are protected against single-AZ datacenter outages via `topologySpreadConstraints` configured in `k8s/topology/topology-spread-worker.yaml`:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: "topology.kubernetes.io/zone"
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: worker-service
```

This guarantees that when KEDA scales Worker replicas from 1 to 4+, the Kubernetes scheduler distributes replicas evenly across:
- `ap-southeast-1a`
- `ap-southeast-1b`
- `ap-southeast-1c`

If any single Availability Zone experiences a complete infrastructure failure, workers in the remaining two AZs continue draining the SQS queue without downtime.

---

## 6. Gated Scenarios: Node Failure & AZ Disruption

Node cordoning/draining (`scripts/chaos/node-failure.sh`) and multi-node AZ impairment (`scripts/chaos/az-failure.md`) are **explicitly gated** and not approved for routine test runs.

### Prerequisites for Node/AZ Failure Approval
Before executing any Node or AZ failure test, the team must complete and sign off on:
1. **Environment Isolation**: Dedicated, isolated EKS cluster confirmed with zero shared production state.
2. **Named Operator**: Two-person rule with an active operator monitoring CloudWatch, EKS console, and cost explorer.
3. **Automated Stop / Rollback Conditions**:
   - Queue age exceeds 120 seconds.
   - SQS DLQ receives more than 5 messages.
   - Worker desired replicas exceed maximum approved ceiling (`maxReplicaCount=10`).
4. **Uncordon Verification**: Immediate execution of `kubectl uncordon <node>` upon test completion.
5. **Cost Budget Cap**: Explicit financial cap on EC2 Auto Scaling Group capacity recreation.

---

## 7. Recovery Metrics Summary

Based on empirical runs stored in `docs/evidence/`:

| Failure Mode | Recovery Mechanism | Measured RTO (Recovery Time Objective) | Measured RPO (Data Loss) | Outcome |
|---|---|---|---|---|
| **Worker Pod Crash** | K8s Pod Recreation + SQS Redelivery | Pod Ready in 8.2s; Job complete in 68.4s | 0 messages lost | **PASS** |
| **Worker SIGTERM** | Graceful Shutdown (25s drain wait) | In-flight completed before process exit | 0 messages lost | **PASS** |
| **Duplicate Delivery** | In-Memory TTL Idempotency Cache | 0.2 ms (instant cache skip) | 0 duplicate executions | **PASS** |
| **Poison Message** | SQS Redrive Policy to DLQ | Diverted to DLQ after 3 retries | Main queue unblocked | **PASS** |
