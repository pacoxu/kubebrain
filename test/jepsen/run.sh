#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

ENDPOINTS="${ENDPOINTS:-127.0.0.1:2379}"
DURATION="${DURATION:-2m}"
WORKERS="${WORKERS:-16}"
KEYS="${KEYS:-64}"
KEY_PREFIX="${KEY_PREFIX:-/jepsen/kubebrain/}"
TIMEOUT="${TIMEOUT:-3s}"
SEED="${SEED:-0}"
OPS_PER_WORKER="${OPS_PER_WORKER:-0}"
COMPACT_INTERVAL="${COMPACT_INTERVAL:-30s}"
COMPACT_REVISION_LAG="${COMPACT_REVISION_LAG:-100}"

OUT_DIR="${OUT_DIR:-test/jepsen/artifacts}"
HISTORY_FILE="${HISTORY_FILE:-${OUT_DIR}/history.jsonl}"
REPORT_FILE="${REPORT_FILE:-${OUT_DIR}/report.json}"

FAULT_CMD="${FAULT_CMD:-}"
FAULT_INTERVAL_SEC="${FAULT_INTERVAL_SEC:-45}"

mkdir -p "${OUT_DIR}"

fault_pid=""
cleanup() {
  if [[ -n "${fault_pid}" ]] && kill -0 "${fault_pid}" 2>/dev/null; then
    kill "${fault_pid}" || true
    wait "${fault_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ -n "${FAULT_CMD}" ]]; then
  (
    while true; do
      sleep "${FAULT_INTERVAL_SEC}"
      echo "[fault] $(date -u +%FT%TZ) running: ${FAULT_CMD}"
      bash -lc "${FAULT_CMD}" || true
    done
  ) &
  fault_pid="$!"
fi

go run ./test/jepsen/harness \
  -endpoints "${ENDPOINTS}" \
  -duration "${DURATION}" \
  -workers "${WORKERS}" \
  -keys "${KEYS}" \
  -key-prefix "${KEY_PREFIX}" \
  -timeout "${TIMEOUT}" \
  -seed "${SEED}" \
  -ops-per-worker "${OPS_PER_WORKER}" \
  -compact-interval "${COMPACT_INTERVAL}" \
  -compact-revision-lag "${COMPACT_REVISION_LAG}" \
  -out "${HISTORY_FILE}"

go run ./test/jepsen/checker \
  -history "${HISTORY_FILE}" \
  -report "${REPORT_FILE}"

echo "Jepsen run completed"
echo "  history: ${HISTORY_FILE}"
echo "  report : ${REPORT_FILE}"

