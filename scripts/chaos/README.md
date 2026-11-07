# Chaos Experiments

This directory contains:

- `pod-failure.sh` and `node-failure.sh`: placeholder shell scripts, not
  executable test procedures yet.
- `az-failure.md`: a high-level AZ failure scenario outline.

Do not treat the shell scripts as ready-to-run tools. Before implementing or
running fault injection, require an explicit development cluster and namespace,
check the current kube context, bound the blast radius, capture a baseline,
and define an abort/rollback procedure. Never run against production.

## Follow-up work

- Implement safe pod and node tests with target/context confirmation and
  timeouts.
- Define the AZ test as a controlled simulation, not an instruction to disrupt
  AWS infrastructure indiscriminately.
- Capture pod placement, queue depth, retries, throughput, and recovery time.
- Require reviewer approval and preserve evidence for every run.
