# Chaos Experiments

These are controlled development-cluster procedures, not production
operations:

| File | Scenario | Safeguards |
| --- | --- | --- |
| [`pod-failure.sh`](pod-failure.sh) | Submit a long-running job, identify the worker processing it, delete that Pod, then verify SQS redelivery and successful completion | Requires `CHAOS_ENVIRONMENT=dev`, explicit context/API URL, a typed confirmation, and a process time shorter than the queue visibility timeout |
| [`node-failure.sh`](node-failure.sh) | Cordon and drain one named node, evicting only worker Pods, then verify Ready worker capacity outside the target AZ | Requires `CHAOS_ENVIRONMENT=dev`, explicit context/node, at least two desired replicas and two Ready AZs, typed confirmation, and automatic uncordon |
| [`az-failure.md`](az-failure.md) | Multi-node AZ capacity-loss simulation and optional separately approved AWS network-isolation experiment | Does not delete subnets or mutate shared route tables/network ACLs |

The scripts require Bash, `kubectl`, and an explicitly selected development
context. The Pod test also requires `curl` and access to the development API.
Review each script's `--help` and the runbook before execution. The scripts
make Kubernetes changes and are intentionally interactive; do not remove the
confirmation or point them at production.

Collect a baseline and define abort thresholds before each test. Keep an
operator available to uncordon nodes, watch worker recovery, and stop load
generation. Save sanitized run IDs, UTC times, Pod placement, queue state,
logs, and recovery measurements under `docs/evidence/`.

For latency definitions and timestamp collection, see
[`scripts/metrics/collect-control-loop-latency.md`](../metrics/collect-control-loop-latency.md).
