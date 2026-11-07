# Autoscaling Manifests

Two mutually exclusive autoscaler configurations are provided for
`worker-service`:

- `keda-scaledobject.yaml`: KEDA SQS queue-length trigger, target queue length
  5, polling interval 15 seconds, min/max replicas 1/4. KEDA must first be
  installed by setting `install_keda = true` and applying Terraform. Replace
  the queue URL placeholder before applying.
- `hpa-baseline.yaml`: Kubernetes CPU HPA targeting 70% average CPU utilization,
  min/max replicas 1/4. It requires Metrics Server, which is not installed by
  the current Terraform configuration.

Do not run both against the same Deployment at the same time. The worker's
default timer-based job simulation is not CPU-heavy; it can build an SQS
backlog for KEDA but may not trigger the CPU HPA.

Inspect the active controller with `kubectl get scaledobject,hpa -n app` and
`kubectl describe` before load testing.

## Follow-up work

- Add validated KEDA trigger and cooldown experiments.
- Add a safe CPU workload mode or use a separate CPU-test Deployment for HPA.
- Add queue-depth and scaling-event dashboards and compare scale-up/down
  latency under repeatable workloads.
