#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${ROOT_DIR}"

CLUSTER_NAME="${CLUSTER_NAME:-kb-e2e}"
K8S_IMAGE="${K8S_IMAGE:-kindest/node:v1.35.0}"
KIND_CONTEXT="kind-${CLUSTER_NAME}"
BUILD_TARGET="${BUILD_TARGET:-badger}"

KUBEBRAIN_PORT="${KUBEBRAIN_PORT:-3379}"
KUBEBRAIN_PEER_PORT="${KUBEBRAIN_PEER_PORT:-3380}"
KUBEBRAIN_INFO_PORT="${KUBEBRAIN_INFO_PORT:-3381}"

E2E_NAMESPACE="${E2E_NAMESPACE:-kb-e2e}"
KEEP_CLUSTER="${KEEP_CLUSTER:-false}"
SKIP_BUILD="${SKIP_BUILD:-false}"

CONTROL_PLANE_NODE=""

log() {
  printf '[kind-e2e] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

dump_debug() {
  log "dumping debug info"
  kubectl --context "${KIND_CONTEXT}" get nodes -o wide || true
  kubectl --context "${KIND_CONTEXT}" get pods -A || true
  if [[ -n "${CONTROL_PLANE_NODE}" ]]; then
    docker exec "${CONTROL_PLANE_NODE}" sh -lc "tail -n 200 /var/log/kubebrain.log" || true
  fi
}

cleanup() {
  if [[ "${KEEP_CLUSTER}" == "true" ]]; then
    log "KEEP_CLUSTER=true, skip deleting kind cluster ${CLUSTER_NAME}"
    return
  fi
  log "deleting kind cluster ${CLUSTER_NAME}"
  kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
}

trap 'rc=$?; if [[ $rc -ne 0 ]]; then dump_debug; fi; cleanup; exit $rc' EXIT

require_cmd kind
require_cmd kubectl
require_cmd docker
require_cmd make

if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  log "cluster ${CLUSTER_NAME} already exists, recreating"
  kind delete cluster --name "${CLUSTER_NAME}"
fi

log "creating kind cluster ${CLUSTER_NAME} (${K8S_IMAGE})"
kind create cluster --name "${CLUSTER_NAME}" --image "${K8S_IMAGE}"

if [[ "${SKIP_BUILD}" != "true" ]]; then
  log "building kube-brain binary using make ${BUILD_TARGET}"
  make "${BUILD_TARGET}"
fi

if [[ ! -x "./bin/kube-brain" ]]; then
  echo "binary not found or not executable: ./bin/kube-brain" >&2
  exit 1
fi

CONTROL_PLANE_NODE="$(kind get nodes --name "${CLUSTER_NAME}" | grep 'control-plane' | head -n1)"
if [[ -z "${CONTROL_PLANE_NODE}" ]]; then
  echo "failed to find kind control-plane node" >&2
  exit 1
fi

log "copying kube-brain binary to ${CONTROL_PLANE_NODE}"
docker cp ./bin/kube-brain "${CONTROL_PLANE_NODE}:/usr/local/bin/kube-brain"

log "starting kube-brain inside kind node"
docker exec "${CONTROL_PLANE_NODE}" sh -lc "
set -eu
mkdir -p /var/lib/kubebrain /var/log
pkill -f '/usr/local/bin/kube-brain' >/dev/null 2>&1 || true
nohup /usr/local/bin/kube-brain \
  --data-dir=/var/lib/kubebrain \
  --key-prefix='/' \
  --compatible-with-etcd=true \
  --port=${KUBEBRAIN_PORT} \
  --peer-port=${KUBEBRAIN_PEER_PORT} \
  --info-port=${KUBEBRAIN_INFO_PORT} \
  >/var/log/kubebrain.log 2>&1 &
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

log "validating kube-brain log for severe errors"
docker exec "${CONTROL_PLANE_NODE}" sh -lc "grep -E 'panic|fatal' /var/log/kubebrain.log && exit 1 || true"

log "e2e passed"
