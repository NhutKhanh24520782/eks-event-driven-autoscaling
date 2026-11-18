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

Optional:
  NAMESPACE=app
  JOB_PROCESS_TIME_MS=40000
  SQS_VISIBILITY_TIMEOUT_SECONDS=60
  ACTIVE_JOB_WAIT_SECONDS=60
  REDELIVERY_WAIT_SECONDS=180

The processing time must be greater than the worker's 25-second shutdown wait
and shorter than the SQS visibility timeout. Set the visibility timeout to
the actual value configured on the test queue.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

for command in kubectl curl grep sed date sleep; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: Required command '$command' was not found." >&2
    exit 1
  }
done

: "${CHAOS_ENVIRONMENT:?Set CHAOS_ENVIRONMENT=dev explicitly.}"
: "${KUBE_CONTEXT:?Set KUBE_CONTEXT to the exact dev kubectl context.}"
: "${API_URL:?Set API_URL to the dev API base URL.}"
[[ "$CHAOS_ENVIRONMENT" == "dev" ]] || {
  echo "ERROR: This script only permits CHAOS_ENVIRONMENT=dev." >&2
  exit 1
}

NAMESPACE="${NAMESPACE:-app}"
JOB_PROCESS_TIME_MS="${JOB_PROCESS_TIME_MS:-40000}"
SQS_VISIBILITY_TIMEOUT_SECONDS="${SQS_VISIBILITY_TIMEOUT_SECONDS:-60}"
ACTIVE_JOB_WAIT_SECONDS="${ACTIVE_JOB_WAIT_SECONDS:-60}"
REDELIVERY_WAIT_SECONDS="${REDELIVERY_WAIT_SECONDS:-180}"
API_URL="${API_URL%/}"

if [[ "$NAMESPACE" == "default" ]] || printf '%s' "$NAMESPACE" | grep -Eiq '(^|[-])(prod|production)([-]|$)'; then
  echo "ERROR: Refusing to run in namespace '$NAMESPACE'." >&2
  exit 1
fi
if printf '%s' "$KUBE_CONTEXT" | grep -Eiq '(^|[^[:alnum:]])(prod|production)([^[:alnum:]]|$)'; then
  echo "ERROR: Refusing to run against a context whose name indicates production." >&2
  exit 1
fi

for value in "$JOB_PROCESS_TIME_MS" "$SQS_VISIBILITY_TIMEOUT_SECONDS" \
  "$ACTIVE_JOB_WAIT_SECONDS" "$REDELIVERY_WAIT_SECONDS"; do
  [[ "$value" =~ ^[0-9]+$ ]] || {
    echo "ERROR: Timing settings must be positive integers." >&2
    exit 1
  }
done

if (( JOB_PROCESS_TIME_MS <= 25000 ||
      JOB_PROCESS_TIME_MS >= SQS_VISIBILITY_TIMEOUT_SECONDS * 1000 )); then
  echo "ERROR: JOB_PROCESS_TIME_MS must be >25000 and less than the SQS visibility timeout in milliseconds." >&2
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

confirm="DELETE ONE WORKER POD IN $NAMESPACE ON $KUBE_CONTEXT AND SUBMIT TO $API_URL"
echo "Target context: $KUBE_CONTEXT"
echo "Target namespace: $NAMESPACE"
echo "API endpoint: $API_URL"
echo "This test submits one job and deletes its active worker Pod."
read -r -p "Type exactly '$confirm' to continue: " answer
[[ "$answer" == "$confirm" ]] || {
  echo "Cancelled; no test job or Pod was changed."
  exit 1
}

JOB_ID="chaos-pod-$(date -u +%Y%m%dT%H%M%SZ)-$$"
CLIENT_SENT_AT="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
body="{\"job_id\":\"$JOB_ID\",\"client_sent_at\":\"$CLIENT_SENT_AT\",\"processTimeMs\":$JOB_PROCESS_TIME_MS,\"payload\":{\"chaos_test\":\"pod-failure\"}}"
response="$(curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  -d "$body" "$API_URL/jobs")"
printf '%s' "$response" | grep -q '"status":"accepted"' || {
  echo "ERROR: API did not accept the test job: $response" >&2
  exit 1
}
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
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pods -l app=worker-service -o wide
