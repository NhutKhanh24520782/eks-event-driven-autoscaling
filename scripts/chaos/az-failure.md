# Availability-Zone Failure Exercise (AWS)

## What this exercise proves

The safe default in this runbook is a **Kubernetes scheduling/capacity
simulation**: worker Pods in one AZ are evicted and nodes in that AZ are made
unschedulable while the nodes, subnet, routes, and AWS control plane remain
intact. This tests whether worker capacity and queued work recover in another
AZ. It is not a real subnet outage and does not prove that the VPC data plane
or AWS services remain reachable during a physical AZ failure.

Do not delete a subnet, change a shared route table, or edit a shared network
ACL/security group to simulate an outage. Those actions can disrupt unrelated
workloads and can be difficult to roll back.

## Preconditions and abort criteria

Run only in an isolated development EKS cluster and dev queue, with explicit
approval from the environment owner. Before starting:

- Confirm the exact AWS account, region, EKS context, namespace, and target AZ.
- Verify Ready worker capacity exists in at least one other AZ and that
  `topology.kubernetes.io/zone` is present on every node.
- Verify the worker Deployment has at least two replicas, the topology-spread
  patch is applied, SQS/DLQ are healthy, and KEDA (if in scope) is Ready.
- Capture baseline replicas, Pod placements, API health, queue depth/age,
  worker throughput, and current errors.
- Define an operator who can stop the test and run the rollback from a second
  terminal that can still reach the Kubernetes API.

Abort and restore immediately if all workers become unavailable, the API or
SQS path fails unexpectedly, queue age exceeds the agreed limit, the remaining
AZ runs out of schedulable capacity, or the test affects a non-test workload.
Choose numeric limits with the environment owner before the run.

## Stage 1: scheduling/capacity simulation

Choose the target AZ from the live cluster output; do not copy an AZ name from
another account because AZ names can map differently between accounts:

```bash
kubectl config current-context
kubectl get nodes -L topology.kubernetes.io/zone
kubectl get pods -n app -l app=worker-service -o wide
kubectl get scaledobject,hpa -n app
```

In a dedicated Bash terminal, set and review the exact target. Drain is
restricted to worker Pods; cordoning also stops new scheduling of any Pod on
the selected nodes. Do not drain all application Pods or system DaemonSets:

```bash
set -euo pipefail
CHAOS_ENVIRONMENT="${CHAOS_ENVIRONMENT:?Set CHAOS_ENVIRONMENT=dev explicitly}"
[[ "$CHAOS_ENVIRONMENT" == 'dev' ]] || {
  echo "Only CHAOS_ENVIRONMENT=dev is permitted." >&2
  exit 1
}
KUBE_CONTEXT='<dev-context>'
NAMESPACE='app'
TARGET_ZONE='<zone-from-kubectl-output>'

mapfile -t TARGET_NODES < <(
  kubectl --context "$KUBE_CONTEXT" get nodes \
    -l "topology.kubernetes.io/zone=$TARGET_ZONE" -o name
)
if ((${#TARGET_NODES[@]} == 0)); then
  echo "No nodes found in target zone; aborting." >&2
  exit 1
fi

printf 'Context: %s\nNamespace: %s\nTarget AZ: %s\nNodes:\n' \
  "$KUBE_CONTEXT" "$NAMESPACE" "$TARGET_ZONE"
printf '  %s\n' "${TARGET_NODES[@]}"
read -r -p "Type SIMULATE AZ CAPACITY LOSS to continue: " confirmation
[[ "$confirmation" == 'SIMULATE AZ CAPACITY LOSS' ]] || exit 1

restore_nodes() {
  for node in "${TARGET_NODES[@]}"; do
    kubectl --context "$KUBE_CONTEXT" uncordon "$node" || \
      echo "MANUAL ACTION REQUIRED: kubectl --context '$KUBE_CONTEXT' uncordon '$node'" >&2
  done
}
trap restore_nodes EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for node in "${TARGET_NODES[@]}"; do
  kubectl --context "$KUBE_CONTEXT" cordon "$node"
done
for node in "${TARGET_NODES[@]}"; do
  kubectl --context "$KUBE_CONTEXT" drain "$node" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --pod-selector=app=worker-service \
    --timeout=180s
done
```

Keep the target nodes cordoned only for the pre-agreed observation window.
Draining evicts only worker Pods, but cordoning prevents all new Pods from
scheduling onto the selected nodes. While the test is active, record API
health, worker Ready replicas and AZs,
SQS visible/in-flight counts and oldest-message age, KEDA/HPA state, and
worker `[REDELIVERY]`/`[JOB SUCCESS]` logs. The
[`node-failure.sh`](node-failure.sh) helper is for a single-node evacuation;
it automatically uncordons that node on exit. Use it for a node-level test,
not as a substitute for this multi-node AZ-capacity exercise.

When the observation window ends, stop load generation and confirm the queue
has drained (or record the remaining backlog). The trap uncordons all selected
nodes. Verify that every target node is schedulable again and that worker
replicas return to the expected placement:

```bash
kubectl --context "$KUBE_CONTEXT" get nodes -L topology.kubernetes.io/zone
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pods -l app=worker-service -o wide
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get deploy worker-service
```

If the shell exits before the trap runs, use the printed node list and
uncordon each node explicitly. Do not remove or terminate the nodes as part of
this stage.

## Stage 2: optional network-isolation experiment

Only if a real subnet/AZ data-plane failure is an approved project objective,
use a disposable VPC/cluster and an AWS Fault Injection Service (FIS)
experiment reviewed by the account owner. Scope targets to dedicated,
explicitly tagged test worker instances/ENIs in one AZ; use the shortest
approved duration, a stop condition, and a tested rollback. Verify the exact
target resource IDs and blast radius in the FIS experiment template before
starting it. Do not target shared control-plane, NAT, route-table, or
production resources. If FIS cannot safely isolate only the test resources,
do not run this stage.

Treat Stage 2 as a separate experiment with its own approval, cost review,
evidence, and recovery window. The scheduling simulation in Stage 1 is the
recommended baseline.

## Success criteria and evidence

Agree on thresholds before starting. A successful capacity simulation should
show that:

- Worker Pods from the target AZ are replaced by Ready workers in surviving
  AZs within the agreed recovery time.
- Jobs remain in SQS during the disruption and eventually complete; any
  expected redelivery is correlated by `job_id`.
- The queue backlog and oldest-message age return to baseline after the test.
- Nodes are uncordoned and the baseline topology is restored afterward.

Save the run ID, account/region/context (redact account identifiers before
sharing), target AZ and node names, start/end UTC times, test load, queue
settings, Pod placements, metrics, events, and recovery observations under
`docs/evidence/`. See
[`docs/control-loop-latency.md`](../../docs/control-loop-latency.md) for
timestamp definitions and
[`scripts/metrics/collect-control-loop-latency.md`](../metrics/collect-control-loop-latency.md)
for collection commands.
