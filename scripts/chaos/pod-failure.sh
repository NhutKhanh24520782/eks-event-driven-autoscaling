#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Delete one worker Pod while a controlled long-running test job is in flight,
then verify SQS redelivery and successful completion.

Required environment:
  CHAOS_ENVIRONMENT=dev
  KUBE_CONTEXT=<exact kubectl context>
  API_URL=<dev API base URL, without /jobs>
  AWS_REGION=<test queue region>
  SQS_QUEUE_URL=<same test queue used by the API>

Optional:
  NAMESPACE=app
  JOB_PROCESS_TIME_MS=40000
  ACTIVE_JOB_WAIT_SECONDS=60
  REDELIVERY_WAIT_SECONDS=180
  EVIDENCE_DIR=docs/evidence/<run-id>

The script reads the queue's actual visibility timeout and refuses to run if
the test queue is not empty. Processing time must be greater than the worker's
25-second shutdown wait and shorter than that actual visibility timeout.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

for command in kubectl curl grep sed date sleep aws tee mkdir; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: Required command '$command' was not found." >&2
    exit 1
  }
done

: "${CHAOS_ENVIRONMENT:?Set CHAOS_ENVIRONMENT=dev explicitly.}"
: "${KUBE_CONTEXT:?Set KUBE_CONTEXT to the exact dev kubectl context.}"
: "${API_URL:?Set API_URL to the dev API base URL.}"
: "${AWS_REGION:?Set AWS_REGION to the test queue region.}"
: "${SQS_QUEUE_URL:?Set SQS_QUEUE_URL to the API's test queue URL.}"
[[ "$CHAOS_ENVIRONMENT" == "dev" ]] || {
  echo "ERROR: This script only permits CHAOS_ENVIRONMENT=dev." >&2
  exit 1
}

NAMESPACE="${NAMESPACE:-app}"
JOB_PROCESS_TIME_MS="${JOB_PROCESS_TIME_MS:-40000}"
ACTIVE_JOB_WAIT_SECONDS="${ACTIVE_JOB_WAIT_SECONDS:-60}"
REDELIVERY_WAIT_SECONDS="${REDELIVERY_WAIT_SECONDS:-180}"
API_URL="${API_URL%/}"
EVIDENCE_DIR="${EVIDENCE_DIR:-docs/evidence/pod-failure-$(date -u +%Y%m%dT%H%M%SZ)}"

case "$SQS_QUEUE_URL" in
  "https://sqs.${AWS_REGION}.amazonaws.com/"*) ;;
  *)
    echo "ERROR: SQS_QUEUE_URL must be an AWS SQS URL in region '$AWS_REGION'." >&2
    exit 1
    ;;
esac

if [[ "$NAMESPACE" == "default" ]] || printf '%s' "$NAMESPACE" | grep -Eiq '(^|[-])(prod|production)([-]|$)'; then
  echo "ERROR: Refusing to run in namespace '$NAMESPACE'." >&2
  exit 1
fi
if printf '%s' "$KUBE_CONTEXT" | grep -Eiq '(^|[^[:alnum:]])(prod|production)([^[:alnum:]]|$)'; then
  echo "ERROR: Refusing to run against a context whose name indicates production." >&2
  exit 1
fi

for value in "$JOB_PROCESS_TIME_MS" "$ACTIVE_JOB_WAIT_SECONDS" "$REDELIVERY_WAIT_SECONDS"; do
  [[ "$value" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Timing settings must be positive integers." >&2
    exit 1
  }
done

queue_attributes="$(aws sqs get-queue-attributes \
  --queue-url "$SQS_QUEUE_URL" \
  --region "$AWS_REGION" \
  --attribute-names VisibilityTimeout ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --query 'Attributes.[VisibilityTimeout,ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]' \
  --output text)"
read -r SQS_VISIBILITY_TIMEOUT_SECONDS VISIBLE_MESSAGES IN_FLIGHT_MESSAGES <<< "$queue_attributes"

for value in "$SQS_VISIBILITY_TIMEOUT_SECONDS" "$VISIBLE_MESSAGES" "$IN_FLIGHT_MESSAGES"; do
  [[ "$value" =~ ^[0-9]+$ ]] || {
    echo "ERROR: AWS CLI returned invalid SQS attributes: $queue_attributes" >&2
    exit 1
  }
done

if (( VISIBLE_MESSAGES != 0 || IN_FLIGHT_MESSAGES != 0 )); then
  echo "ERROR: Refusing to inject while the queue is not empty (visible=$VISIBLE_MESSAGES, in-flight=$IN_FLIGHT_MESSAGES)." >&2
  exit 1
fi

if (( JOB_PROCESS_TIME_MS <= 25000 ||
      JOB_PROCESS_TIME_MS >= SQS_VISIBILITY_TIMEOUT_SECONDS * 1000 )); then
  echo "ERROR: JOB_PROCESS_TIME_MS must be >25000 and less than the queue's actual visibility timeout (${SQS_VISIBILITY_TIMEOUT_SECONDS}s)." >&2
  exit 1
fi

kubectl --context "$KUBE_CONTEXT" get namespace "$NAMESPACE" >/dev/null
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get deployment worker-service >/dev/null

health="$(curl --fail --silent --show-error "$API_URL/health")"
printf '%s' "$health" | grep -q '"status":"healthy"' || {
  echo "ERROR: API health check did not report healthy: $health" >&2
  exit 1
}
printf '%s' "$health" | grep -q '"queueConfigured":true' || {
  echo "ERROR: API does not report a configured queue." >&2
  exit 1
}

mkdir -p "$EVIDENCE_DIR"
LOG_FILE="$EVIDENCE_DIR/pod-failure.log"
exec > >(tee -a "$LOG_FILE") 2>&1

confirm="DELETE ONE WORKER POD IN $NAMESPACE ON $KUBE_CONTEXT AND SUBMIT TO $API_URL"
echo "Target context: $KUBE_CONTEXT"
echo "Target namespace: $NAMESPACE"
echo "API endpoint: $API_URL"
echo "Test queue: ${SQS_QUEUE_URL##*/} (visibility timeout ${SQS_VISIBILITY_TIMEOUT_SECONDS}s)"
echo "Evidence directory: $EVIDENCE_DIR"
echo "This test submits one job and deletes its active worker Pod."
read -r -p "Type exactly '$confirm' to continue: " answer
[[ "$answer" == "$confirm" ]] || {
  echo "Cancelled; no test job or Pod was changed."
  exit 1
}

JOB_ID="chaos-pod-$(date -u +%Y%m%dT%H%M%SZ)-$$"
CLIENT_SENT_AT="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
printf 'job_id=%s\ncontext=%s\nnamespace=%s\nqueue_name=%s\nprocess_time_ms=%s\nvisibility_timeout_seconds=%s\nstarted_at=%s\n' \
  "$JOB_ID" "$KUBE_CONTEXT" "$NAMESPACE" "${SQS_QUEUE_URL##*/}" \
  "$JOB_PROCESS_TIME_MS" "$SQS_VISIBILITY_TIMEOUT_SECONDS" "$CLIENT_SENT_AT" \
  > "$EVIDENCE_DIR/run.txt"
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pods -l app=worker-service -o wide \
  > "$EVIDENCE_DIR/pods-before.txt"
curl --silent --show-error --max-time 15 \
  -H 'Content-Type: application/json' \
  --output "$EVIDENCE_DIR/api-response.json" \
  --write-out '%{http_code}' \
  -d "{\"job_id\":\"$JOB_ID\",\"client_sent_at\":\"$CLIENT_SENT_AT\",\"processTimeMs\":$JOB_PROCESS_TIME_MS,\"payload\":{\"chaos_test\":\"pod-failure\"}}" \
  "$API_URL/jobs" > "$EVIDENCE_DIR/api-status.txt"
if ! grep -qx '202' "$EVIDENCE_DIR/api-status.txt" ||
  ! grep -q '"status":"accepted"' "$EVIDENCE_DIR/api-response.json"; then
  echo "ERROR: API did not accept the test job (HTTP $(sed -n '1p' "$EVIDENCE_DIR/api-status.txt")); response:" >&2
  sed -n '1p' "$EVIDENCE_DIR/api-response.json" >&2
  exit 1
fi
echo "Submitted job_id=$JOB_ID"

active_pod=""
deadline=$((SECONDS + ACTIVE_JOB_WAIT_SECONDS))
while (( SECONDS < deadline )); do
  pod_list="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get pods -l app=worker-service --field-selector=status.phase=Running \
    -o name)"
  while IFS= read -r pod_ref; do
    [[ -n "$pod_ref" ]] || continue
    pod="${pod_ref#pod/}"
    if logs="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
      logs "$pod" -c worker --since=3m --tail=500 2>/dev/null)"; then
      if printf '%s' "$logs" | grep -Fq "[JOB START] job_id=$JOB_ID"; then
        active_pod="$pod"
        break
      fi
    fi
  done <<< "$pod_list"
  [[ -n "$active_pod" ]] && break
  sleep 2
done

[[ -n "$active_pod" ]] || {
  echo "ERROR: No worker logged an active JOB START for $JOB_ID within ${ACTIVE_JOB_WAIT_SECONDS}s; no Pod was deleted." >&2
  exit 1
}

echo "Job is active on pod/$active_pod; requesting Pod deletion."
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pod "$active_pod" -o yaml \
  > "$EVIDENCE_DIR/active-pod-before-delete.yaml"
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" logs "$active_pod" -c worker \
  --since=5m --tail=1000 > "$EVIDENCE_DIR/active-worker-before-delete.log"
started_at="$SECONDS"
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  delete pod "$active_pod" --wait=true --timeout=90s

redelivered_at=""
completed_at=""
deadline=$((SECONDS + REDELIVERY_WAIT_SECONDS))
while (( SECONDS < deadline )); do
  pod_list="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
    get pods -l app=worker-service --field-selector=status.phase=Running \
    -o name)"
  while IFS= read -r pod_ref; do
    [[ -n "$pod_ref" ]] || continue
    pod="${pod_ref#pod/}"
    if logs="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
      logs "$pod" -c worker --since=5m --tail=2000 2>/dev/null)"; then
      if [[ -z "$redelivered_at" ]] &&
        printf '%s' "$logs" | grep -Fq "[REDELIVERY] Message is being retried! job_id=$JOB_ID"; then
        redelivered_at="$SECONDS"
        echo "SQS redelivery observed after $((redelivered_at - started_at))s."
      fi
      if [[ -n "$redelivered_at" ]] &&
        printf '%s' "$logs" | grep -Fq "[JOB SUCCESS] job_id=$JOB_ID"; then
        completed_at="$SECONDS"
        break
      fi
    fi
  done <<< "$pod_list"
  [[ -n "$completed_at" ]] && break
  sleep 3
done

if [[ -z "$redelivered_at" ]]; then
  echo "ERROR: No redelivery log for $JOB_ID within ${REDELIVERY_WAIT_SECONDS}s." >&2
  echo "Inspect worker logs, SQS visibility timeout, and the DLQ before retrying." >&2
  exit 1
fi

if [[ -z "$completed_at" ]]; then
  echo "ERROR: Redelivery occurred, but successful completion was not observed within ${REDELIVERY_WAIT_SECONDS}s." >&2
  echo "Inspect worker logs, queue depth, and the DLQ." >&2
  exit 1
fi

echo "PASS: job_id=$JOB_ID was redelivered and completed."
echo "Seconds from Pod deletion to redelivery: $((redelivered_at - started_at))"
echo "Seconds from Pod deletion to successful completion: $((completed_at - started_at))"
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pods -l app=worker-service -o wide \
  | tee "$EVIDENCE_DIR/pods-after.txt"
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get events \
  --field-selector "involvedObject.name=$active_pod" \
  --sort-by=.metadata.creationTimestamp > "$EVIDENCE_DIR/active-pod-events.txt"
printf 'finished_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
  >> "$EVIDENCE_DIR/run.txt"
