# Project Documentation

This directory contains design notes, experiment plans, and operational
evidence for the EKS event-driven autoscaling project.

| Document | Purpose | Status |
| --- | --- | --- |
| [`architecture.md`](architecture.md) | High-level system flow | Overview only |
| [`control-loop-latency.md`](control-loop-latency.md) | T0–T6 latency definitions | Needs implementation and measured values |
| [`fault-tolerance.md`](fault-tolerance.md) | Pod, node, and AZ failure scenarios | Scenario outline; execution evidence is not included |
| [`experiments.md`](experiments.md) | Experiment priorities | Planned work; currently a placeholder |
| [`team-work-allocation.md`](team-work-allocation.md) | Team responsibility notes | Update as ownership changes |
| [`evidence/`](evidence/README.md) | Location for reproducible test artifacts | No evidence is committed yet |

The architecture and experiment descriptions should not be read as proof that
all listed capabilities are implemented. The current runtime limitations and
next steps are summarized in the [root README](../README.md#next-development-steps).

## Follow-up work

- Replace TODO placeholders with protocols, commands, results, timestamps,
  and links to reproducible evidence.
- Record environment, image version, cluster configuration, workload
  parameters, and test date with every experiment.
- Document safety checks and abort criteria for fault-injection exercises.
