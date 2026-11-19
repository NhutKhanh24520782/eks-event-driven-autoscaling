# Chaos Experiments

These are controlled development-cluster procedures, not production
operations:

| File | Scenario | Safeguards |
| --- | --- | --- |
| [`pod-failure.sh`](pod-failure.sh) | Submit a long-running job, identify the worker processing it, delete that Pod, then verify SQS redelivery and successful completion | Requires `CHAOS_ENVIRONMENT=dev`, explicit context/API/queue/region, empty queue, actual visibility-timeout preflight, typed confirmation, and evidence output |
| [`node-failure.sh`](node-failure.sh) | Cordon and drain one named node, evicting only worker Pods, then verify Ready worker capacity outside the target AZ | Guarded, but not approved for execution until the team agrees isolation, stop conditions, rollback, and cost limits |
| [`az-failure.md`](az-failure.md) | Multi-node AZ capacity-loss planning and optional separately approved AWS network-isolation experiment | Planning only; no Node/AZ failure is authorized by the current sequence |

The scripts require Bash, `kubectl`, and an explicitly selected development
context. The Pod test also requires AWS CLI, `curl`, access to the development
API, and the same quiet test queue used by the API.
Review each script's `--help` and the runbook before execution. The scripts
make Kubernetes changes and are intentionally interactive; do not remove the
confirmation or point them at production.

Collect a baseline and define abort thresholds before each test. Keep an
operator available to uncordon nodes, watch worker recovery, and stop load
generation. Save sanitized run IDs, UTC times, Pod placement, queue state,
logs, and recovery measurements under `docs/evidence/`.

For latency definitions and timestamp collection, see
[`scripts/metrics/collect-control-loop-latency.md`](../metrics/collect-control-loop-latency.md).
