#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${ROOT_DIR}"

CLUSTER_NAME="${CLUSTER_NAME:-kb-e2e}"
K8S_IMAGE="${K8S_IMAGE:-m.daocloud.io/docker.io/kindest/node:v1.35.0}"
KIND_CONTEXT="kind-${CLUSTER_NAME}"
BUILD_TARGET="${BUILD_TARGET:-badger}"
KUBEBRAIN_GOOS="${KUBEBRAIN_GOOS:-linux}"
KUBEBRAIN_GOARCH="${KUBEBRAIN_GOARCH:-}"
KUBEBRAIN_CGO_ENABLED="${KUBEBRAIN_CGO_ENABLED:-0}"

KUBEBRAIN_PORT="${KUBEBRAIN_PORT:-3379}"
KUBEBRAIN_PEER_PORT="${KUBEBRAIN_PEER_PORT:-3380}"
KUBEBRAIN_INFO_PORT="${KUBEBRAIN_INFO_PORT:-3381}"

E2E_NAMESPACE="${E2E_NAMESPACE:-kb-e2e}"
E2E_POD_NAME="${E2E_POD_NAME:-pod-e2e}"
E2E_POD_IMAGE="${E2E_POD_IMAGE:-registry.k8s.io/pause:3.10}"
KEEP_CLUSTER="${KEEP_CLUSTER:-false}"
SKIP_BUILD="${SKIP_BUILD:-false}"
KUBEBRAIN_KEY_PREFIX="${KUBEBRAIN_KEY_PREFIX:-}"

TIKV_PD_ADDRS="${TIKV_PD_ADDRS:-}"
TIKV_PD_IMAGE="${TIKV_PD_IMAGE:-pingcap/pd:v6.5.7}"
TIKV_KV_IMAGE="${TIKV_KV_IMAGE:-pingcap/tikv:v6.5.7}"
TIKV_PD_CONTAINER="${TIKV_PD_CONTAINER:-${CLUSTER_NAME}-pd}"
TIKV_KV_CONTAINER="${TIKV_KV_CONTAINER:-${CLUSTER_NAME}-tikv}"
TIKV_BOOTSTRAP_WAIT_SECONDS="${TIKV_BOOTSTRAP_WAIT_SECONDS:-25}"
TIKV_CHECK_TIMEOUT_SECONDS="${TIKV_CHECK_TIMEOUT_SECONDS:-90}"

CONTROL_PLANE_NODE=""
KIND_NETWORK=""
STARTED_LOCAL_TIKV="false"

log() {
  printf '[kind-e2e] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

detect_node_arch() {
  local node="$1"
  local node_arch_raw
  node_arch_raw="$(docker exec "${node}" uname -m | tr -d '\r\n')"
  case "${node_arch_raw}" in
  aarch64 | arm64)
    echo "arm64"
    ;;
  x86_64 | amd64)
    echo "amd64"
    ;;
  *)
    echo "unsupported node architecture: ${node_arch_raw}" >&2
    return 1
    ;;
  esac
}

dump_debug() {
  log "dumping debug info"
  kubectl --context "${KIND_CONTEXT}" get nodes -o wide || true
  kubectl --context "${KIND_CONTEXT}" get pods -A || true
  if [[ -n "${CONTROL_PLANE_NODE}" ]]; then
    docker exec "${CONTROL_PLANE_NODE}" sh -lc "if [ -f /var/log/kubebrain.log ]; then tail -n 200 /var/log/kubebrain.log; else echo 'kubebrain log file not found'; fi" || true
  fi
  if [[ "${BUILD_TARGET}" == "tikv" ]]; then
    if docker inspect "${TIKV_PD_CONTAINER}" >/dev/null 2>&1; then
      docker logs --tail 200 "${TIKV_PD_CONTAINER}" || true
    fi
    if docker inspect "${TIKV_KV_CONTAINER}" >/dev/null 2>&1; then
      docker logs --tail 200 "${TIKV_KV_CONTAINER}" || true
    fi
  fi
}

cleanup_local_tikv() {
  if [[ "${STARTED_LOCAL_TIKV}" != "true" ]]; then
    return
  fi
  log "deleting local TiKV containers"
  docker rm -f "${TIKV_KV_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${TIKV_PD_CONTAINER}" >/dev/null 2>&1 || true
}

cleanup() {
  cleanup_local_tikv
  if [[ "${KEEP_CLUSTER}" == "true" ]]; then
    log "KEEP_CLUSTER=true, skip deleting kind cluster ${CLUSTER_NAME}"
    return
  fi
  log "deleting kind cluster ${CLUSTER_NAME}"
  kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
}

start_local_tikv() {
  if [[ -n "${TIKV_PD_ADDRS}" ]]; then
    log "using external TiKV PD addresses: ${TIKV_PD_ADDRS}"
    return
  fi
  if [[ -z "${KIND_NETWORK}" ]]; then
    echo "failed to detect docker network for kind cluster ${CLUSTER_NAME}" >&2
    exit 1
  fi

  log "starting local TiKV (pd + tikv) on docker network ${KIND_NETWORK}"
  docker rm -f "${TIKV_KV_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${TIKV_PD_CONTAINER}" >/dev/null 2>&1 || true

  docker run -d \
    --name "${TIKV_PD_CONTAINER}" \
    --network "${KIND_NETWORK}" \
    "${TIKV_PD_IMAGE}" \
    /pd-server \
    --name=pd-e2e \
    --data-dir=/var/lib/pd \
    --client-urls=http://0.0.0.0:2379 \
    --advertise-client-urls="http://${TIKV_PD_CONTAINER}:2379" \
    --peer-urls=http://0.0.0.0:2380 \
    --advertise-peer-urls="http://${TIKV_PD_CONTAINER}:2380" \
    --initial-cluster="pd-e2e=http://${TIKV_PD_CONTAINER}:2380" \
    --initial-cluster-state=new >/dev/null

  docker run -d \
    --name "${TIKV_KV_CONTAINER}" \
    --network "${KIND_NETWORK}" \
    "${TIKV_KV_IMAGE}" \
    /tikv-server \
    --pd="http://${TIKV_PD_CONTAINER}:2379" \
    --addr="0.0.0.0:20160" \
    --advertise-addr="${TIKV_KV_CONTAINER}:20160" \
    --status-addr="0.0.0.0:20180" \
    --data-dir=/var/lib/tikv >/dev/null

  STARTED_LOCAL_TIKV="true"
  TIKV_PD_ADDRS="${TIKV_PD_CONTAINER}:2379"
  log "waiting ${TIKV_BOOTSTRAP_WAIT_SECONDS}s for TiKV bootstrap"
  sleep "${TIKV_BOOTSTRAP_WAIT_SECONDS}"
}

run_tikv_pod_spec_check() {
  local checker_bin
  checker_bin="$(mktemp "${TMPDIR:-/tmp}/kb-tikv-check.XXXXXX")"

  log "building TiKV verification helper"
  GOOS=linux GOARCH="${KUBEBRAIN_GOARCH}" CGO_ENABLED=0 go build -tags tikv -o "${checker_bin}" ./test/e2e/kind/tikvcheck
  docker cp "${checker_bin}" "${CONTROL_PLANE_NODE}:/usr/local/bin/kb-tikv-check"
  rm -f "${checker_bin}"

  log "verifying pod spec directly from TiKV"
  docker exec "${CONTROL_PLANE_NODE}" /usr/local/bin/kb-tikv-check \
    --pd-addrs="${TIKV_PD_ADDRS}" \
    --namespace="${E2E_NAMESPACE}" \
    --pod-name="${E2E_POD_NAME}" \
    --expected-image="${E2E_POD_IMAGE}" \
    --key-prefix="${KUBEBRAIN_KEY_PREFIX}" \
    --timeout="${TIKV_CHECK_TIMEOUT_SECONDS}s"
}

trap 'rc=$?; if [[ $rc -ne 0 ]]; then dump_debug; fi; cleanup; exit $rc' EXIT

require_cmd kind
require_cmd kubectl
require_cmd docker
require_cmd make
if [[ "${BUILD_TARGET}" == "tikv" ]]; then
  require_cmd go
fi

case "${BUILD_TARGET}" in
badger | tikv) ;;
*)
  echo "unsupported BUILD_TARGET=${BUILD_TARGET}; expected badger or tikv" >&2
  exit 1
  ;;
esac

if [[ -n "${KUBEBRAIN_KEY_PREFIX}" && "${KUBEBRAIN_KEY_PREFIX}" == */ ]]; then
  echo "invalid KUBEBRAIN_KEY_PREFIX=${KUBEBRAIN_KEY_PREFIX}: trailing '/' is not allowed" >&2
  exit 1
fi

if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  log "cluster ${CLUSTER_NAME} already exists, recreating"
  kind delete cluster --name "${CLUSTER_NAME}"
fi

log "creating kind cluster ${CLUSTER_NAME} (${K8S_IMAGE})"
kind_create_args=(create cluster --name "${CLUSTER_NAME}")
if [[ -n "${K8S_IMAGE}" ]]; then
  kind_create_args+=(--image "${K8S_IMAGE}")
fi
log "running: kind ${kind_create_args[*]}"
kind "${kind_create_args[@]}"

CONTROL_PLANE_NODE="$(kind get nodes --name "${CLUSTER_NAME}" | grep 'control-plane' | head -n1)"
if [[ -z "${CONTROL_PLANE_NODE}" ]]; then
  echo "failed to find kind control-plane node" >&2
  exit 1
fi

KIND_NETWORK="$(docker inspect "${CONTROL_PLANE_NODE}" --format '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | head -n1 | tr -d '\r\n')"
if [[ -z "${KIND_NETWORK}" ]]; then
  echo "failed to detect kind docker network" >&2
  exit 1
fi

if [[ -z "${KUBEBRAIN_GOARCH}" ]]; then
  KUBEBRAIN_GOARCH="$(detect_node_arch "${CONTROL_PLANE_NODE}")"
fi

if [[ "${BUILD_TARGET}" == "tikv" ]]; then
  start_local_tikv
fi

if [[ "${SKIP_BUILD}" != "true" ]]; then
  log "building kube-brain binary using make ${BUILD_TARGET}"
  log "build target platform: GOOS=${KUBEBRAIN_GOOS} GOARCH=${KUBEBRAIN_GOARCH} CGO_ENABLED=${KUBEBRAIN_CGO_ENABLED}"
  GOOS="${KUBEBRAIN_GOOS}" GOARCH="${KUBEBRAIN_GOARCH}" CGO_ENABLED="${KUBEBRAIN_CGO_ENABLED}" make "${BUILD_TARGET}"
fi

if [[ ! -x "./bin/kube-brain" ]]; then
  echo "binary not found or not executable: ./bin/kube-brain" >&2
  exit 1
fi

log "copying kube-brain binary to ${CONTROL_PLANE_NODE}"
docker cp ./bin/kube-brain "${CONTROL_PLANE_NODE}:/usr/local/bin/kube-brain"

kubebrain_storage_flags="--data-dir=/var/lib/kubebrain"
if [[ "${BUILD_TARGET}" == "tikv" ]]; then
  if [[ -z "${TIKV_PD_ADDRS}" ]]; then
    echo "TiKV backend selected but TIKV_PD_ADDRS is empty" >&2
    exit 1
  fi
  kubebrain_storage_flags="--pd-addrs=${TIKV_PD_ADDRS}"
fi

log "starting kube-brain inside kind node"
docker exec "${CONTROL_PLANE_NODE}" sh -lc "
set -eu
mkdir -p /var/lib/kubebrain /var/log
if pgrep -x kube-brain >/dev/null 2>&1; then
  pkill -x kube-brain || true
fi
nohup /usr/local/bin/kube-brain \
  ${kubebrain_storage_flags} \
  --key-prefix='${KUBEBRAIN_KEY_PREFIX}' \
  --compatible-with-etcd=true \
  --port=${KUBEBRAIN_PORT} \
  --peer-port=${KUBEBRAIN_PEER_PORT} \
  --info-port=${KUBEBRAIN_INFO_PORT} \
  >/var/log/kubebrain.log 2>&1 &
"

docker exec "${CONTROL_PLANE_NODE}" sh -lc "
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

log "patching kube-apiserver manifest to use kube-brain"
docker exec "${CONTROL_PLANE_NODE}" sh -lc "
set -eu
manifest=/etc/kubernetes/manifests/kube-apiserver.yaml
cp \"\$manifest\" \"\${manifest}.bak\"
sed -i -E 's#--etcd-servers=https://[^ ]+#--etcd-servers=http://127.0.0.1:${KUBEBRAIN_PORT}#' \"\$manifest\"
sed -i '/--etcd-cafile=/d;/--etcd-certfile=/d;/--etcd-keyfile=/d' \"\$manifest\"
"

log "waiting for kube-apiserver to become ready"
for _ in $(seq 1 120); do
  if kubectl --context "${KIND_CONTEXT}" get --raw='/readyz' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl --context "${KIND_CONTEXT}" get --raw='/readyz' >/dev/null

log "running CRUD smoke tests"
kubectl --context "${KIND_CONTEXT}" create namespace "${E2E_NAMESPACE}" --dry-run=client -o yaml | kubectl --context "${KIND_CONTEXT}" apply -f -
kubectl --context "${KIND_CONTEXT}" -n "${E2E_NAMESPACE}" create configmap cm-e2e --from-literal=a=1
kubectl --context "${KIND_CONTEXT}" -n "${E2E_NAMESPACE}" patch configmap cm-e2e -p '{"data":{"a":"2"}}'
actual="$(kubectl --context "${KIND_CONTEXT}" -n "${E2E_NAMESPACE}" get configmap cm-e2e -o jsonpath='{.data.a}')"
if [[ "${actual}" != "2" ]]; then
  echo "configmap value mismatch, expected 2, got ${actual}" >&2
  exit 1
fi
kubectl --context "${KIND_CONTEXT}" -n "${E2E_NAMESPACE}" delete configmap cm-e2e --wait=true

log "running watch smoke test"
watch_log="$(mktemp)"
kubectl --context "${KIND_CONTEXT}" -n "${E2E_NAMESPACE}" get configmaps -w --request-timeout=20s >"${watch_log}" 2>&1 &
watch_pid=$!
sleep 2
kubectl --context "${KIND_CONTEXT}" -n "${E2E_NAMESPACE}" create configmap cm-watch --from-literal=x=1
kubectl --context "${KIND_CONTEXT}" -n "${E2E_NAMESPACE}" delete configmap cm-watch --wait=true
wait "${watch_pid}" || true
if ! grep -q 'cm-watch' "${watch_log}"; then
  echo "watch output does not contain cm-watch" >&2
  cat "${watch_log}" >&2 || true
  rm -f "${watch_log}"
  exit 1
fi
rm -f "${watch_log}"

log "running Pod create/running smoke test"
kubectl --context "${KIND_CONTEXT}" -n "${E2E_NAMESPACE}" delete pod "${E2E_POD_NAME}" --ignore-not-found=true --wait=true
cat <<EOF | kubectl --context "${KIND_CONTEXT}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${E2E_POD_NAME}
  namespace: ${E2E_NAMESPACE}
spec:
  tolerations:
  - key: "node-role.kubernetes.io/control-plane"
    operator: "Exists"
    effect: "NoSchedule"
  - key: "node-role.kubernetes.io/master"
    operator: "Exists"
    effect: "NoSchedule"
  containers:
  - name: pause
    image: ${E2E_POD_IMAGE}
EOF

pod_phase=""
for _ in $(seq 1 120); do
  pod_phase="$(kubectl --context "${KIND_CONTEXT}" -n "${E2E_NAMESPACE}" get pod "${E2E_POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${pod_phase}" == "Running" ]]; then
    break
  fi
  if [[ "${pod_phase}" == "Failed" ]]; then
    break
  fi
  sleep 2
done
if [[ "${pod_phase}" != "Running" ]]; then
  echo "pod ${E2E_POD_NAME} did not reach Running, current phase=${pod_phase}" >&2
  kubectl --context "${KIND_CONTEXT}" -n "${E2E_NAMESPACE}" describe pod "${E2E_POD_NAME}" >&2 || true
  exit 1
fi

if [[ "${BUILD_TARGET}" == "tikv" ]]; then
  run_tikv_pod_spec_check
fi

log "validating kube-brain log for severe errors"
docker exec "${CONTROL_PLANE_NODE}" sh -lc "grep -E 'panic|fatal' /var/log/kubebrain.log && exit 1 || true"

log "e2e passed"
