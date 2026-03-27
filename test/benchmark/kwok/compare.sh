#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${ROOT_DIR}"

K8S_IMAGE="${K8S_IMAGE:-m.daocloud.io/docker.io/kindest/node:v1.35.0}"
RUNTIME="${RUNTIME:-kind}"
CLUSTER_PREFIX="${CLUSTER_PREFIX:-kb-kwok-bench}"
KEEP_CLUSTERS="${KEEP_CLUSTERS:-false}"

BUILD_TARGET="${BUILD_TARGET:-badger}"
SKIP_BUILD="${SKIP_BUILD:-false}"
KUBEBRAIN_GOOS="${KUBEBRAIN_GOOS:-linux}"
KUBEBRAIN_GOARCH="${KUBEBRAIN_GOARCH:-}"
KUBEBRAIN_CGO_ENABLED="${KUBEBRAIN_CGO_ENABLED:-0}"
KUBEBRAIN_KEY_PREFIX="${KUBEBRAIN_KEY_PREFIX:-}"
KUBEBRAIN_PORT="${KUBEBRAIN_PORT:-3379}"
KUBEBRAIN_PEER_PORT="${KUBEBRAIN_PEER_PORT:-3380}"
KUBEBRAIN_INFO_PORT="${KUBEBRAIN_INFO_PORT:-3381}"

BENCH_NAMESPACE="${BENCH_NAMESPACE:-kwok-bench}"
BENCH_DEPLOYMENT="${BENCH_DEPLOYMENT:-kwok-bench-pods}"
FAKE_NODES="${FAKE_NODES:-100}"
PODS="${PODS:-10000}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"

RESULTS_DIR="${RESULTS_DIR:-test/benchmark/kwok/results}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_FILE="${RESULTS_DIR}/kwok-compare-${TIMESTAMP}.tsv"

CURRENT_CLUSTER=""
CURRENT_KIND_CLUSTER=""
CURRENT_MODE=""
CURRENT_NODE=""
declare -a CREATED_CLUSTERS=()

log() {
  printf '[kwok-bench] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

context_name() {
  local cluster="$1"
  echo "kwok-${cluster}"
}

kind_cluster_name() {
  local cluster="$1"
  echo "kwok-${cluster}"
}

cleanup_cluster() {
  local cluster="$1"
  if [[ "${KEEP_CLUSTERS}" == "true" ]]; then
    log "KEEP_CLUSTERS=true, skip deleting cluster ${cluster}"
    return
  fi
  kwokctl delete cluster --name "${cluster}" >/dev/null 2>&1 || true
}

dump_debug() {
  local cluster="$1"
  local mode="$2"
  log "debug for mode=${mode}, cluster=${cluster}"
  local context
  context="$(context_name "${cluster}")"
  kubectl --context "${context}" get nodes -o wide || true
  kubectl --context "${context}" get pods -A || true
  kwokctl logs kube-apiserver --name "${cluster}" --tail 200 || true
  kwokctl logs kube-scheduler --name "${cluster}" --tail 200 || true
  if [[ "${mode}" == "kubebrain" && -n "${CURRENT_NODE}" ]]; then
    docker exec "${CURRENT_NODE}" sh -lc "if [ -f /var/log/kubebrain.log ]; then tail -n 200 /var/log/kubebrain.log; else echo 'kubebrain log file not found'; fi" || true
  fi
}

cleanup_all() {
  local rc=$1
  if [[ $rc -ne 0 && -n "${CURRENT_CLUSTER}" ]]; then
    dump_debug "${CURRENT_CLUSTER}" "${CURRENT_MODE:-unknown}"
  fi
  for c in "${CREATED_CLUSTERS[@]:-}"; do
    cleanup_cluster "$c"
  done
  exit "$rc"
}

trap 'cleanup_all $?' EXIT

wait_apiserver_ready() {
  local context="$1"
  for _ in $(seq 1 120); do
    if kubectl --context "${context}" get --raw='/readyz' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  kubectl --context "${context}" get --raw='/readyz' >/dev/null
}

create_kwok_cluster() {
  local cluster="$1"
  log "creating kwok cluster ${cluster} runtime=${RUNTIME} image=${K8S_IMAGE}"
  local args=(create cluster --name "${cluster}" --runtime "${RUNTIME}")
  if [[ "${RUNTIME}" == "kind" && -n "${K8S_IMAGE}" ]]; then
    args+=(--kind-node-image "${K8S_IMAGE}")
  fi
  kwokctl "${args[@]}" >/dev/null
  CREATED_CLUSTERS+=("${cluster}")
  local context
  context="$(context_name "${cluster}")"
  wait_apiserver_ready "${context}"
}

detect_node_arch() {
  local node="$1"
  local raw
  raw="$(docker exec "${node}" uname -m | tr -d '\r\n')"
  case "${raw}" in
  aarch64 | arm64)
    echo "arm64"
    ;;
  x86_64 | amd64)
    echo "amd64"
    ;;
  *)
    echo "unsupported node architecture: ${raw}" >&2
    return 1
    ;;
  esac
}

build_kubebrain_binary() {
  local node="$1"
  if [[ "${SKIP_BUILD}" == "true" ]]; then
    return
  fi
  local goarch="${KUBEBRAIN_GOARCH}"
  if [[ -z "${goarch}" ]]; then
    goarch="$(detect_node_arch "${node}")"
  fi
  log "building kube-brain: GOOS=${KUBEBRAIN_GOOS} GOARCH=${goarch} CGO_ENABLED=${KUBEBRAIN_CGO_ENABLED}"
  GOOS="${KUBEBRAIN_GOOS}" GOARCH="${goarch}" CGO_ENABLED="${KUBEBRAIN_CGO_ENABLED}" make "${BUILD_TARGET}" >/dev/null
}

setup_kubebrain_proxy() {
  local cluster="$1"
  local context="$2"
  local kind_cluster
  kind_cluster="$(kind_cluster_name "${cluster}")"
  local node
  node="$(kind get nodes --name "${kind_cluster}" | grep control-plane | head -n1)"
  if [[ -z "${node}" ]]; then
    echo "failed to find control-plane node for kind cluster ${kind_cluster}" >&2
    return 1
  fi
  CURRENT_NODE="${node}"

  build_kubebrain_binary "${node}"
  if [[ ! -x "./bin/kube-brain" ]]; then
    echo "binary not found: ./bin/kube-brain" >&2
    return 1
  fi

  docker cp ./bin/kube-brain "${node}:/usr/local/bin/kube-brain"
  docker exec "${node}" sh -lc "
set -eu
mkdir -p /var/lib/kubebrain /var/log
if pgrep -x kube-brain >/dev/null 2>&1; then
  pkill -x kube-brain || true
fi
nohup /usr/local/bin/kube-brain \
  --data-dir=/var/lib/kubebrain \
  --key-prefix='${KUBEBRAIN_KEY_PREFIX}' \
  --compatible-with-etcd=true \
  --port=${KUBEBRAIN_PORT} \
  --peer-port=${KUBEBRAIN_PEER_PORT} \
  --info-port=${KUBEBRAIN_INFO_PORT} \
  >/var/log/kubebrain.log 2>&1 &
"

  docker exec "${node}" sh -lc "
set -eu
for _ in \$(seq 1 20); do
  if pgrep -x kube-brain >/dev/null 2>&1; then
    exit 0
  fi
  sleep 1
done
echo 'kube-brain process did not start' >&2
if [ -f /var/log/kubebrain.log ]; then
  tail -n 200 /var/log/kubebrain.log >&2
fi
exit 1
"

  docker exec "${node}" sh -lc "
set -eu
manifest=/etc/kubernetes/manifests/kube-apiserver.yaml
cp \"\$manifest\" \"\${manifest}.bak\"
sed -i -E 's#--etcd-servers=https://[^ ]+#--etcd-servers=http://127.0.0.1:${KUBEBRAIN_PORT}#' \"\$manifest\"
sed -i '/--etcd-cafile=/d;/--etcd-certfile=/d;/--etcd-keyfile=/d' \"\$manifest\"
"

  wait_apiserver_ready "${context}"
}

prepare_fake_nodes() {
  local cluster="$1"
  local context="$2"
  kwokctl scale node --name "${cluster}" --replicas "${FAKE_NODES}" >/dev/null
  local ready=0
  for _ in $(seq 1 120); do
    ready="$(kubectl --context "${context}" get nodes --no-headers 2>/dev/null | awk '$2 ~ /Ready/ {c++} END {print c+0}')"
    if (( ready >= FAKE_NODES )); then
      return 0
    fi
    sleep 2
  done
  echo "not enough ready nodes: expected >=${FAKE_NODES}, got ${ready}" >&2
  return 1
}

apply_benchmark_workload() {
  local context="$1"
  kubectl --context "${context}" create namespace "${BENCH_NAMESPACE}" --dry-run=client -o yaml | kubectl --context "${context}" apply -f - >/dev/null
  cat <<EOF | kubectl --context "${context}" apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${BENCH_DEPLOYMENT}
  namespace: ${BENCH_NAMESPACE}
spec:
  replicas: ${PODS}
  selector:
    matchLabels:
      app: ${BENCH_DEPLOYMENT}
  template:
    metadata:
      labels:
        app: ${BENCH_DEPLOYMENT}
    spec:
      tolerations:
      - key: "kwok.x-k8s.io/node"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: fake
        image: registry.k8s.io/pause:3.10
        resources:
          requests:
            cpu: "5m"
            memory: "8Mi"
EOF
}

wait_running_pods() {
  local context="$1"
  local expected="$2"
  local namespace="$3"
  local start_ms="$4"
  local timeout_ms=$((TIMEOUT_SECONDS * 1000))

  while true; do
    local now elapsed running
    now="$(now_ms)"
    elapsed=$((now - start_ms))
    running="$(kubectl --context "${context}" -n "${namespace}" get pods --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if (( running >= expected )); then
      echo "${running} ${elapsed}"
      return 0
    fi
    if (( elapsed > timeout_ms )); then
      echo "${running} ${elapsed}"
      return 1
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
  done
}

run_case() {
  local mode="$1"
  local cluster="$2"

  CURRENT_MODE="${mode}"
  CURRENT_CLUSTER="${cluster}"
  CURRENT_KIND_CLUSTER="$(kind_cluster_name "${cluster}")"

  create_kwok_cluster "${cluster}"
  local context
  context="$(context_name "${cluster}")"

  if [[ "${mode}" == "kubebrain" ]]; then
    setup_kubebrain_proxy "${cluster}" "${context}"
  fi

  prepare_fake_nodes "${cluster}" "${context}"
  apply_benchmark_workload "${context}"

  local start_ms
  start_ms="$(now_ms)"
  local running elapsed_ms status wait_out
  if wait_out="$(wait_running_pods "${context}" "${PODS}" "${BENCH_NAMESPACE}" "${start_ms}")"; then
    read -r running elapsed_ms <<<"${wait_out}"
    status="ok"
  else
    read -r running elapsed_ms <<<"${wait_out}"
    status="timeout"
  fi

  local throughput
  throughput="$(awk -v p="${running}" -v d="${elapsed_ms}" 'BEGIN {if (d<=0) print "0"; else printf "%.2f", p*1000/d}')"
  local nodes
  nodes="$(kubectl --context "${context}" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${mode}" "${FAKE_NODES}" "${PODS}" "${nodes}" "${running}" "${elapsed_ms}" "${throughput}" "${status}" "${context}" >>"${RESULT_FILE}"

  if [[ "${status}" != "ok" ]]; then
    echo "benchmark case ${mode} timed out after ${elapsed_ms}ms (running=${running}, target=${PODS})" >&2
    return 1
  fi

  cleanup_cluster "${cluster}"
}

print_results() {
  local file="$1"
  echo
  echo "Result file: ${file}"
  echo
  awk -F '\t' 'BEGIN {
    printf "| mode | fake_nodes_target | pods_target | nodes_seen | pods_running | time_ms | pods/s | status | context |\n";
    printf "|---|---:|---:|---:|---:|---:|---:|---|---|\n";
  }
  NR>1 {
    printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6,$7,$8,$9;
  }' "${file}"
}

main() {
  require_cmd kwokctl
  require_cmd kind
  require_cmd kubectl
  require_cmd docker
  require_cmd make
  require_cmd python3
  require_cmd awk
  require_cmd wc

  if [[ -n "${KUBEBRAIN_KEY_PREFIX}" && "${KUBEBRAIN_KEY_PREFIX}" == */ ]]; then
    echo "invalid KUBEBRAIN_KEY_PREFIX=${KUBEBRAIN_KEY_PREFIX}: trailing '/' is not allowed" >&2
    exit 1
  fi
  mkdir -p "${RESULTS_DIR}"
  printf "mode\tfake_nodes_target\tpods_target\tnodes_seen\tpods_running\ttime_ms\tpods_per_sec\tstatus\tcontext\n" >"${RESULT_FILE}"

  run_case "etcd" "${CLUSTER_PREFIX}-etcd"
  run_case "kubebrain" "${CLUSTER_PREFIX}-kubebrain"

  print_results "${RESULT_FILE}"
  log "kwok benchmark comparison completed"
}

main "$@"
