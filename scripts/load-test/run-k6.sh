#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Reproducible k6 Load Test Runner for Linux / macOS / Git Bash.

Usage:
  ./run-k6.sh [PROFILE] [API_URL] [PEAK_VUS]

Environment / Options:
  PROFILE=baseline|load|spike|smoke|stress|soak  (default: baseline)
  API_URL=http://<host>:<port>                   (default: http://localhost:3000)
  RUN_ID=<unique-run-id>                         (default: <profile>-<UTC>)
  PEAK_VUS=10                                    (1-50)
  BASELINE_VUS=1                                 (1-50)
  SPIKE_VUS=20                                   (1-50)
  PROCESS_TIME_MS=1000                           (1-60000)
  FAILURE_RATE=0.0                               (0.0-1.0)
  EVIDENCE_DIR=docs/evidence/<run-id>

Examples:
  ./run-k6.sh baseline
  ./run-k6.sh load http://k8s-alb-endpoint.amazonaws.com 12
  PROFILE=spike SPIKE_VUS=25 ./run-k6.sh
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

command -v k6 >/dev/null 2>&1 || {
  echo "ERROR: k6 was not found in PATH. Install from https://k6.io/docs/get-started/installation/" >&2
  exit 1
}

PROFILE="${1:-${PROFILE:-baseline}}"
API_URL="${2:-${API_URL:-http://localhost:3000}}"
PEAK_VUS="${3:-${PEAK_VUS:-10}}"
API_URL="${API_URL%/}"

RUN_ID="${RUN_ID:-$PROFILE-$(date -u +%Y%m%dT%H%M%SZ)}"
EVIDENCE_DIR="${EVIDENCE_DIR:-docs/evidence/$RUN_ID}"
mkdir -p "$EVIDENCE_DIR"
CSV_PATH="$EVIDENCE_DIR/k6.csv"
SCRIPT_PATH="scripts/load-test/k6-workload.js"

echo "=========================================================="
echo "  REPRODUCIBLE K6 WORKLOAD RUNNER"
echo "=========================================================="
echo "  Run ID:           $RUN_ID"
echo "  Profile:          $PROFILE"
echo "  Target API URL:   $API_URL"
echo "  Output Directory: $EVIDENCE_DIR"
echo "  Output CSV:       $CSV_PATH"
echo "=========================================================="

k6 run \
  -e API_URL="$API_URL" \
  -e RUN_ID="$RUN_ID" \
  -e K6_PROFILE="$PROFILE" \
  -e PEAK_VUS="$PEAK_VUS" \
  -e BASELINE_VUS="${BASELINE_VUS:-1}" \
  -e SPIKE_VUS="${SPIKE_VUS:-20}" \
  -e PROCESS_TIME_MS="${PROCESS_TIME_MS:-1000}" \
  -e BASELINE_DURATION="${BASELINE_DURATION:-30s}" \
  -e RAMP_UP_DURATION="${RAMP_UP_DURATION:-30s}" \
  -e HOLD_DURATION="${HOLD_DURATION:-60s}" \
  -e RAMP_DOWN_DURATION="${RAMP_DOWN_DURATION:-30s}" \
  -e SOAK_DURATION="${SOAK_DURATION:-3m}" \
  -e REQUEST_PAUSE_SECONDS="${REQUEST_PAUSE_SECONDS:-1.0}" \
  -e FAILURE_RATE="${FAILURE_RATE:-0.0}" \
  --out "csv=$CSV_PATH" \
  "$SCRIPT_PATH"

echo "=========================================================="
echo "✅ K6 execution finished. Evidence stored in $EVIDENCE_DIR"
echo "=========================================================="
