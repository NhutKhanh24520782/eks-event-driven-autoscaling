#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Collect timestamped application/KEDA logs, replica samples, SQS attributes, and
Kubernetes snapshots for one controlled experiment. This script does not
generate workload or change cluster resources.

Required environment:
  KUBE_CONTEXT=<exact active kubectl context>
  QUEUE_URL=<test SQS queue URL>
  AWS_REGION=<queue region>

Optional:
  RUN_ID=<experiment id>                 (default: UTC timestamp)
  NAMESPACE=app
  SAMPLE_INTERVAL_SECONDS=1              (1-30)
  COLLECTION_DURATION_SECONDS=0           (0=run until interrupted; max 3600)
  EVIDENCE_DIR=docs/evidence/<run-id>

Run k6 in a separate terminal, then press Ctrl+C here to finish collection.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

for command in kubectl aws date sleep mkdir grep tee tr; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: Required command '$command' was not found." >&2
    exit 1
  }
done

: "${KUBE_CONTEXT:?Set KUBE_CONTEXT to the exact active kubectl context.}"
: "${QUEUE_URL:?Set QUEUE_URL to the test SQS queue URL.}"
: "${AWS_REGION:?Set AWS_REGION to the test queue region.}"

NAMESPACE="${NAMESPACE:-app}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-1}"
COLLECTION_DURATION_SECONDS="${COLLECTION_DURATION_SECONDS:-0}"
EVIDENCE_DIR="${EVIDENCE_DIR:-docs/evidence/$RUN_ID}"

if [[ "$NAMESPACE" == "default" ]] ||
  printf '%s' "$NAMESPACE" | grep -Eiq '(^|[-])(prod|production)([-]|$)'; then
  echo "ERROR: Refusing to collect against namespace '$NAMESPACE'." >&2
  exit 1
fi
if [[ "$(kubectl config current-context)" != "$KUBE_CONTEXT" ]]; then
  echo "ERROR: KUBE_CONTEXT must match the active kubectl context." >&2
  exit 1
fi
if ! [[ "$SAMPLE_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] ||
  (( SAMPLE_INTERVAL_SECONDS < 1 || SAMPLE_INTERVAL_SECONDS > 30 )); then
  echo "ERROR: SAMPLE_INTERVAL_SECONDS must be an integer from 1 to 30." >&2
  exit 1
fi
if ! [[ "$COLLECTION_DURATION_SECONDS" =~ ^[0-9]+$ ]] ||
  (( COLLECTION_DURATION_SECONDS > 3600 )); then
  echo "ERROR: COLLECTION_DURATION_SECONDS must be an integer from 0 to 3600." >&2
  exit 1
fi
case "$QUEUE_URL" in
  "https://sqs.${AWS_REGION}.amazonaws.com/"*) ;;
  *)
    echo "ERROR: QUEUE_URL must be an AWS SQS URL in region '$AWS_REGION'." >&2
    exit 1
    ;;
esac

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get deployment api-service worker-service >/dev/null
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get scaledobject worker-scaledobject >/dev/null
kubectl --context "$KUBE_CONTEXT" -n keda get deployment keda-operator >/dev/null
aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --region "$AWS_REGION" \
  --attribute-names VisibilityTimeout >/dev/null

mkdir -p "$EVIDENCE_DIR"
QUEUE_NAME="${QUEUE_URL##*/}"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
printf 'run_id=%s\nstarted_at=%s\ncontext=%s\nnamespace=%s\nregion=%s\nqueue_name=%s\nsample_interval_seconds=%s\ncollection_duration_seconds=%s\n' \
  "$RUN_ID" "$STARTED_AT" "$KUBE_CONTEXT" "$NAMESPACE" "$AWS_REGION" \
  "$QUEUE_NAME" "$SAMPLE_INTERVAL_SECONDS" "$COLLECTION_DURATION_SECONDS" \
  > "$EVIDENCE_DIR/run.txt"
printf 'mark,timestamp,source,uncertainty_ms\n' > "$EVIDENCE_DIR/run-events.csv"
printf 'observed_at_utc\tdesired_replicas\tready_replicas\tavailable_replicas\n' \
  > "$EVIDENCE_DIR/replicas.tsv"
printf 'observed_at_utc\tpod_name\tcreation_timestamp\tready_status\tready_transition_time\tnode_name\n' \
  > "$EVIDENCE_DIR/worker-pod-observations.tsv"
printf 'observed_at_utc\tvisible_messages\tin_flight_messages\tdelayed_messages\n' \
  > "$EVIDENCE_DIR/sqs-attributes.tsv"
: > "$EVIDENCE_DIR/kubernetes-events.jsonl"

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pods -o wide \
  > "$EVIDENCE_DIR/pods-before.txt"
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pods \
  -l app=worker-service -o json > "$EVIDENCE_DIR/worker-pods-before.json"
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get hpa,scaledobject -o yaml \
  > "$EVIDENCE_DIR/autoscaler-before.yaml"
kubectl --context "$KUBE_CONTEXT" get nodes -L topology.kubernetes.io/zone \
  > "$EVIDENCE_DIR/nodes-before.txt"

collector_pids=()
start_log_collector() {
  local namespace="$1"
  local source="$2"
  local output="$3"
  if [[ "$source" == label:* ]]; then
    kubectl --context "$KUBE_CONTEXT" -n "$namespace" logs \
      -l "${source#label:}" --max-log-requests=20 \
      --all-containers=true --prefix --timestamps --since=2m -f \
      > "$EVIDENCE_DIR/$output" 2>&1 &
  else
    kubectl --context "$KUBE_CONTEXT" -n "$namespace" logs "$source" \
      --all-containers=true --prefix --timestamps --since=2m -f \
      > "$EVIDENCE_DIR/$output" 2>&1 &
  fi
  collector_pids+=("$!")
}

start_log_collector "$NAMESPACE" "label:app=api-service" "api.log"
start_log_collector "$NAMESPACE" "label:app=worker-service" "worker.log"
start_log_collector "keda" "deployment/keda-operator" "keda-operator.log"

aws_sampler() {
  while true; do
    local timestamp attributes
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    if attributes="$(aws sqs get-queue-attributes \
      --queue-url "$QUEUE_URL" \
      --region "$AWS_REGION" \
      --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed \
      --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible,ApproximateNumberOfMessagesDelayed]' \
      --output text 2>> "$EVIDENCE_DIR/aws-errors.log")"; then
      printf '%s\t%s\n' "$timestamp" "$attributes" >> "$EVIDENCE_DIR/sqs-attributes.tsv"
    else
      echo "ERROR: Failed to sample SQS queue attributes at $timestamp; see aws-errors.log." >&2
    fi
    sleep 5
  done
}

aws_sampler &
collector_pids+=("$!")

cleanup() {
  trap - EXIT INT TERM
  for pid in "${collector_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${collector_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pods -o wide \
    > "$EVIDENCE_DIR/pods-after.txt"
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get hpa,scaledobject -o yaml \
    > "$EVIDENCE_DIR/autoscaler-after.yaml"
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get events \
    --sort-by=.metadata.creationTimestamp > "$EVIDENCE_DIR/app-events.txt"
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get events -o json \
    > "$EVIDENCE_DIR/app-events.json"
  kubectl --context "$KUBE_CONTEXT" -n keda get events -o json \
    > "$EVIDENCE_DIR/keda-events.json"
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pods \
    -l app=worker-service -o json > "$EVIDENCE_DIR/worker-pods.json"
  printf 'finished_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
    >> "$EVIDENCE_DIR/run.txt"
  echo "Evidence saved to $EVIDENCE_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Collecting run_id=$RUN_ID in context=$KUBE_CONTEXT. Start the workload in another terminal."
if (( COLLECTION_DURATION_SECONDS == 0 )); then
  echo "Press Ctrl+C here after the queue drains and the run is complete."
else
  echo "Collection will stop after ${COLLECTION_DURATION_SECONDS}s and save final snapshots."
fi

collection_started_seconds="$SECONDS"
while true; do
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  replicas="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get deployment worker-service \
    -o jsonpath='{.spec.replicas}{"\t"}{.status.readyReplicas}{"\t"}{.status.availableReplicas}')"
  printf '%s\t%s\n' "$timestamp" "$replicas" >> "$EVIDENCE_DIR/replicas.tsv"
  pod_observations="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get pods -l app=worker-service \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.creationTimestamp}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.conditions[?(@.type=="Ready")].lastTransitionTime}{"\t"}{.spec.nodeName}{"\n"}{end}')"
  if [[ -n "$pod_observations" ]]; then
    while IFS= read -r pod_row; do
      [[ -n "$pod_row" ]] && printf '%s\t%s\n' "$timestamp" "$pod_row" \
        >> "$EVIDENCE_DIR/worker-pod-observations.tsv"
    done <<< "$pod_observations"
  fi
  for event_namespace in "$NAMESPACE" keda; do
    event_snapshot="$(kubectl --context "$KUBE_CONTEXT" -n "$event_namespace" get events -o json | tr -d '\r\n')"
    printf '%s\n' "$event_snapshot" >> "$EVIDENCE_DIR/kubernetes-events.jsonl"
  done
  if (( COLLECTION_DURATION_SECONDS > 0 &&
        SECONDS - collection_started_seconds >= COLLECTION_DURATION_SECONDS )); then
    break
  fi
  sleep "$SAMPLE_INTERVAL_SECONDS"
done
