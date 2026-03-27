#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${ROOT_DIR}"

K8S_IMAGE="${K8S_IMAGE:-m.daocloud.io/docker.io/kindest/node:v1.35.0}"
CLUSTER_PREFIX="${CLUSTER_PREFIX:-kb-bench}"
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

BENCH_NAMESPACE="${BENCH_NAMESPACE:-kb-bench}"
BENCH_OPS="${BENCH_OPS:-200}"
BENCH_CONCURRENCY="${BENCH_CONCURRENCY:-8}"
BENCH_WARMUP="${BENCH_WARMUP:-20}"

RESULTS_DIR="${RESULTS_DIR:-test/benchmark/kind/results}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_FILE="${RESULTS_DIR}/kind-compare-${TIMESTAMP}.tsv"

CURRENT_NODE=""
declare -a CREATED_CLUSTERS=()

log() {
  printf '[kind-bench] %s\n' "$*"
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

cleanup_cluster() {
  local cluster="$1"
  if [[ "${KEEP_CLUSTERS}" == "true" ]]; then
    log "KEEP_CLUSTERS=true, skip deleting ${cluster}"
    return
  fi
  kind delete cluster --name "${cluster}" >/dev/null 2>&1 || true
}

cleanup_all() {
  local rc=$1
  if [[ $rc -ne 0 ]]; then
    log "benchmark failed, collecting simple debug info"
    if [[ -n "${CURRENT_NODE}" ]]; then
      docker exec "${CURRENT_NODE}" sh -lc "if [ -f /var/log/kubebrain.log ]; then tail -n 200 /var/log/kubebrain.log; fi" || true
    fi
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

create_cluster() {
  local cluster="$1"
  if kind get clusters | grep -qx "${cluster}"; then
    kind delete cluster --name "${cluster}" >/dev/null 2>&1 || true
  fi
  kind create cluster --name "${cluster}" --image "${K8S_IMAGE}" >/dev/null
  CREATED_CLUSTERS+=("${cluster}")
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

setup_kubebrain() {
  local cluster="$1"
  local context="$2"

  local node
  node="$(kind get nodes --name "${cluster}" | grep control-plane | head -n1)"
  if [[ -z "${node}" ]]; then
    echo "failed to find control-plane node for ${cluster}" >&2
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

run_single_op() {
  local context="$1"
  local ns="$2"
  local name="$3"

  kubectl --context "${context}" -n "${ns}" create configmap "${name}" --from-literal=v=1 >/dev/null 2>&1
  kubectl --context "${context}" -n "${ns}" patch configmap "${name}" -p '{"data":{"v":"2"}}' >/dev/null 2>&1
  kubectl --context "${context}" -n "${ns}" delete configmap "${name}" --wait=true >/dev/null 2>&1
}

run_worker() {
  local context="$1"
  local ns="$2"
  local run_id="$3"
  local worker="$4"
  local total_ops="$5"
  local step="$6"
  local latency_file="$7"
  local stat_file="$8"

  local ok=0
  local fail=0
  local i
  for ((i=worker; i<=total_ops; i+=step)); do
    local name="cm-${run_id}-${worker}-${i}"
    local begin end
    begin="$(now_ms)"
    if run_single_op "${context}" "${ns}" "${name}"; then
      end="$(now_ms)"
      echo $((end - begin)) >>"${latency_file}"
      ok=$((ok + 1))
    else
      kubectl --context "${context}" -n "${ns}" delete configmap "${name}" --ignore-not-found=true >/dev/null 2>&1 || true
      fail=$((fail + 1))
    fi
  done
  echo "${ok} ${fail}" >"${stat_file}"
}

summarize_latency() {
  local lat_file="$1"
  local sorted="${lat_file}.sorted"
  sort -n "${lat_file}" >"${sorted}"
  local n
  n="$(wc -l <"${sorted}" | tr -d ' ')"
  if [[ "${n}" == "0" ]]; then
    echo "0 0 0 0"
    return
  fi
  local p50_idx=$(( (50 * n + 99) / 100 ))
  local p90_idx=$(( (90 * n + 99) / 100 ))
  local p99_idx=$(( (99 * n + 99) / 100 ))
  local p50 p90 p99 avg
  p50="$(awk -v i="${p50_idx}" 'NR==i {print; exit}' "${sorted}")"
  p90="$(awk -v i="${p90_idx}" 'NR==i {print; exit}' "${sorted}")"
  p99="$(awk -v i="${p99_idx}" 'NR==i {print; exit}' "${sorted}")"
  avg="$(awk '{s+=$1} END {if (NR==0) print 0; else printf "%.2f", s/NR}' "${sorted}")"
  echo "${p50} ${p90} ${p99} ${avg}"
}

run_benchmark_case() {
  local mode="$1"
  local context="$2"

  kubectl --context "${context}" create namespace "${BENCH_NAMESPACE}" --dry-run=client -o yaml | kubectl --context "${context}" apply -f - >/dev/null

  if (( BENCH_WARMUP > 0 )); then
    log "${mode}: warmup ${BENCH_WARMUP} ops"
    local i
    for ((i=1; i<=BENCH_WARMUP; i++)); do
      run_single_op "${context}" "${BENCH_NAMESPACE}" "warmup-${mode}-${i}" || true
    done
  fi

  log "${mode}: running benchmark ops=${BENCH_OPS} concurrency=${BENCH_CONCURRENCY}"
  local run_id="${mode}-${TIMESTAMP}"
  local workdir
  workdir="$(mktemp -d)"
  local start_ms end_ms
  start_ms="$(now_ms)"

  local w
  for ((w=1; w<=BENCH_CONCURRENCY; w++)); do
    run_worker "${context}" "${BENCH_NAMESPACE}" "${run_id}" "${w}" "${BENCH_OPS}" "${BENCH_CONCURRENCY}" "${workdir}/lat-${w}.txt" "${workdir}/stat-${w}.txt" &
  done
  wait

  end_ms="$(now_ms)"
  local duration_ms=$((end_ms - start_ms))

  cat "${workdir}"/lat-*.txt 2>/dev/null >"${workdir}/all.lat" || true
  local ok_total=0
  local fail_total=0
  for f in "${workdir}"/stat-*.txt; do
    [[ -f "${f}" ]] || continue
    local ok fail
    ok="$(awk '{print $1}' "${f}")"
    fail="$(awk '{print $2}' "${f}")"
    ok_total=$((ok_total + ok))
    fail_total=$((fail_total + fail))
  done

  local p50 p90 p99 avg
  read -r p50 p90 p99 avg < <(summarize_latency "${workdir}/all.lat")
  local ops_per_sec
  ops_per_sec="$(awk -v n="${ok_total}" -v d="${duration_ms}" 'BEGIN {if (d<=0) print "0"; else printf "%.2f", n*1000/d}')"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${mode}" "${BENCH_OPS}" "${BENCH_CONCURRENCY}" "${ok_total}" "${fail_total}" "${duration_ms}" "${ops_per_sec}" "${avg}" "${p50}" "${p90}" "${p99}" >>"${RESULT_FILE}"

  rm -rf "${workdir}"
}

print_result_table() {
  local file="$1"
  echo
  echo "Result file: ${file}"
  echo
  awk -F '\t' 'BEGIN {
    printf "| mode | ops | concurrency | success | fail | duration_ms | ops/s | avg_ms | p50_ms | p90_ms | p99_ms |\n";
    printf "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n";
  }
  NR>1 {
    printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11;
  }' "${file}"
}

main() {
  require_cmd kind
  require_cmd kubectl
  require_cmd docker
  require_cmd make
  require_cmd python3
  require_cmd awk
  require_cmd sort

  if [[ -n "${KUBEBRAIN_KEY_PREFIX}" && "${KUBEBRAIN_KEY_PREFIX}" == */ ]]; then
    echo "invalid KUBEBRAIN_KEY_PREFIX=${KUBEBRAIN_KEY_PREFIX}: trailing '/' is not allowed" >&2
    exit 1
  fi

  mkdir -p "${RESULTS_DIR}"
  printf "mode\tops\tconcurrency\tsuccess\tfail\tduration_ms\tops_per_sec\tavg_ms\tp50_ms\tp90_ms\tp99_ms\n" >"${RESULT_FILE}"

  local etcd_cluster="${CLUSTER_PREFIX}-etcd"
  local kb_cluster="${CLUSTER_PREFIX}-kubebrain"

  log "case etcd: creating cluster ${etcd_cluster}"
  create_cluster "${etcd_cluster}"
  CURRENT_NODE=""
  run_benchmark_case "etcd" "kind-${etcd_cluster}"
  cleanup_cluster "${etcd_cluster}"

  log "case kubebrain: creating cluster ${kb_cluster}"
  create_cluster "${kb_cluster}"
  setup_kubebrain "${kb_cluster}" "kind-${kb_cluster}"
  run_benchmark_case "kubebrain" "kind-${kb_cluster}"
  cleanup_cluster "${kb_cluster}"

  print_result_table "${RESULT_FILE}"
  log "benchmark completed"
}

main "$@"
