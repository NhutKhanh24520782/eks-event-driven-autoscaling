#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Cordon and drain one explicitly selected dev node, evicting only worker-service
Pods. The script verifies worker readiness in another AZ and always attempts
to uncordon the node on exit.

Required environment:
  CHAOS_ENVIRONMENT=dev
  KUBE_CONTEXT=<exact kubectl context>
  NODE_NAME=<exact node name>

Optional:
  NAMESPACE=app
  DRAIN_TIMEOUT_SECONDS=180
  RECOVERY_TIMEOUT_SECONDS=180
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

for command in kubectl grep awk date sort sleep; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: Required command '$command' was not found." >&2
    exit 1
  }
done

: "${CHAOS_ENVIRONMENT:?Set CHAOS_ENVIRONMENT=dev explicitly.}"
: "${KUBE_CONTEXT:?Set KUBE_CONTEXT to the exact dev kubectl context.}"
: "${NODE_NAME:?Set NODE_NAME to the exact node to cordon and drain.}"
[[ "$CHAOS_ENVIRONMENT" == "dev" ]] || {
  echo "ERROR: This script only permits CHAOS_ENVIRONMENT=dev." >&2
  exit 1
}

NAMESPACE="${NAMESPACE:-app}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-180}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-180}"

if [[ "$NAMESPACE" == "default" ]] || printf '%s' "$NAMESPACE" | grep -Eiq '(^|[-])(prod|production)([-]|$)'; then
  echo "ERROR: Refusing to run in namespace '$NAMESPACE'." >&2
  exit 1
fi
if printf '%s' "$KUBE_CONTEXT" | grep -Eiq '(^|[^[:alnum:]])(prod|production)([^[:alnum:]]|$)'; then
  echo "ERROR: Refusing to run against a context whose name indicates production." >&2
  exit 1
fi
[[ "$DRAIN_TIMEOUT_SECONDS" =~ ^[0-9]+$ && "$RECOVERY_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || {
  echo "ERROR: Timeout settings must be positive integers." >&2
  exit 1
}

kubectl --context "$KUBE_CONTEXT" get namespace "$NAMESPACE" >/dev/null
target_zone="$(kubectl --context "$KUBE_CONTEXT" get node "$NODE_NAME" \
  -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
node_ready="$(kubectl --context "$KUBE_CONTEXT" get node "$NODE_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
[[ -n "$target_zone" && "$node_ready" == "True" ]] || {
  echo "ERROR: Target node must be Ready and have a topology.kubernetes.io/zone label." >&2
  exit 1
}

deployment_replicas="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get deployment worker-service -o jsonpath='{.spec.replicas}')"
[[ "$deployment_replicas" =~ ^[0-9]+$ && "$deployment_replicas" -ge 2 ]] || {
  echo "ERROR: worker-service must have at least two desired replicas for a multi-AZ placement test." >&2
  exit 1
}

ready_zones="$(kubectl --context "$KUBE_CONTEXT" get nodes \
  -o 'custom-columns=ZONE:.metadata.labels.topology\.kubernetes\.io/zone,READY:.status.conditions[?(@.type=="Ready")].status' \
  --no-headers | awk '$2=="True" && $1!="<none>" {print $1}' | sort -u)"
zone_count="$(printf '%s\n' "$ready_zones" | awk 'NF {count++} END {print count+0}')"
[[ "$zone_count" -ge 2 ]] || {
  echo "ERROR: Need Ready nodes in at least two AZs before testing failover." >&2
  exit 1
}

initial_pods="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  get pods -l app=worker-service \
  -o 'custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase,READY:.status.containerStatuses[0].ready' \
  --no-headers)"
printf '%s\n' "$initial_pods" | awk -v node="$NODE_NAME" \
  '$2==node && $3=="Running" && $4=="true" {found=1} END {exit !found}' || {
  echo "ERROR: No Ready worker Pod is currently running on $NODE_NAME." >&2
  exit 1
}

has_other_zone_worker=false
while read -r pod pod_node phase ready; do
  [[ "$phase" == "Running" && "$ready" == "true" ]] || continue
  pod_zone="$(kubectl --context "$KUBE_CONTEXT" get node "$pod_node" \
    -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
  if [[ "$pod_zone" != "$target_zone" ]]; then
    has_other_zone_worker=true
    break
  fi
done <<< "$initial_pods"
[[ "$has_other_zone_worker" == true ]] || {
  echo "ERROR: Need a Ready worker in another AZ as a survivor before draining this node." >&2
  exit 1
}

confirm="CORDON AND DRAIN $NODE_NAME IN $target_zone ON $KUBE_CONTEXT"
echo "Target namespace: $NAMESPACE"
echo "Desired worker replicas: $deployment_replicas"
echo "Worker Pods on target node will be evicted; other workloads will not be drained."
read -r -p "Type exactly '$confirm' to continue: " answer
[[ "$answer" == "$confirm" ]] || {
  echo "Cancelled; node state was not changed."
  exit 1
}

cordoned=false
restore_node() {
  result=$?
  if [[ "$cordoned" == true ]]; then
    echo "Restoring schedulability on node $NODE_NAME."
    if ! kubectl --context "$KUBE_CONTEXT" uncordon "$NODE_NAME"; then
      echo "ERROR: Automatic uncordon failed; run: kubectl --context '$KUBE_CONTEXT' uncordon '$NODE_NAME'" >&2
      result=1
    fi
  fi
  exit "$result"
}
trap restore_node EXIT

cordoned=true
kubectl --context "$KUBE_CONTEXT" cordon "$NODE_NAME"
kubectl --context "$KUBE_CONTEXT" drain "$NODE_NAME" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --pod-selector=app=worker-service \
  --timeout="${DRAIN_TIMEOUT_SECONDS}s"

echo "Waiting for all desired worker replicas to be Ready outside $target_zone."
deadline=$((SECONDS + RECOVERY_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  pods="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get pods -l app=worker-service \
    -o 'custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase,READY:.status.containerStatuses[0].ready' \
    --no-headers)"
  ready_count=0
  ready_in_other_zone=false
  worker_on_target_node=false

  while read -r pod pod_node phase ready; do
    [[ -n "$pod" ]] || continue
    if [[ "$phase" == "Running" && "$ready" == "true" ]]; then
      ready_count=$((ready_count + 1))
      pod_zone="$(kubectl --context "$KUBE_CONTEXT" get node "$pod_node" \
        -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
      [[ "$pod_node" != "$NODE_NAME" ]] || worker_on_target_node=true
      [[ "$pod_zone" == "$target_zone" ]] || ready_in_other_zone=true
    fi
  done <<< "$pods"

  if (( ready_count >= deployment_replicas )) &&
    [[ "$worker_on_target_node" == false && "$ready_in_other_zone" == true ]]; then
    echo "PASS: $ready_count Ready worker replica(s) are available and a worker is Ready outside $target_zone."
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pods -l app=worker-service -o wide
    exit 0
  fi
  sleep 3
done

echo "ERROR: Worker recovery/spread condition was not met within ${RECOVERY_TIMEOUT_SECONDS}s." >&2
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pods -l app=worker-service -o wide >&2
exit 1
