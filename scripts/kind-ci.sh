#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/versions.env"
for command in docker git kind kubectl helm go curl openssl jq; do
  command -v "${command}" >/dev/null || { echo "Missing command: ${command}" >&2; exit 1; }
done
[[ -f "${root}/manifests/overlays/${AGENTGATEWAY_VERSION}/kustomization.yaml" ]] || {
  echo "No overlay for agentgateway ${AGENTGATEWAY_VERSION}" >&2
  exit 1
}
workdir="$(mktemp -d)"
cluster="${KIND_CLUSTER_NAME:-orka-agentgateway-${workdir##*.}}"
cluster="$(printf '%s' "${cluster}" | tr '[:upper:]' '[:lower:]')"
created_cluster=false
cluster_verified=false
registry_owner="agentgateway-${workdir##*/}"
registry_started=false
forward_pid=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "${forward_pid}" ]]; then
    kill "${forward_pid}" 2>/dev/null || true
    wait "${forward_pid}" 2>/dev/null || true
  fi
  if (( status != 0 )) && [[ "${cluster_verified}" == true ]]; then
    kubectl -n orka-system get pods,events --request-timeout=10s >&2 || true
  fi
  if [[ "${registry_started}" == true ]]; then
    orka_kind_registry_stop "${cluster}" "${registry_owner}" || status=1
  fi
  if [[ "${created_cluster}" == true ]]; then
    kind delete cluster --name "${cluster}" || status=1
  fi
  rm -rf -- "${workdir}"
  exit "${status}"
}
trap cleanup EXIT

# Existing clusters are opt-in and never deleted. kindctl exec supplies their
# dedicated kubeconfig. CI creates a fresh cluster with a private file.
if [[ "${KIND_EXISTING_CLUSTER:-false}" == true ]]; then
  : "${KUBECONFIG:?An existing cluster requires an explicit KUBECONFIG}"
  if [[ "$(kubectl config current-context)" != "kind-${cluster}" ]]; then
    echo "KUBECONFIG must select kind-${cluster}" >&2
    exit 1
  fi
else
  if kind get clusters | grep -Fxq "${cluster}"; then
    echo "Refusing to replace existing cluster ${cluster}" >&2
    exit 1
  fi
  export KUBECONFIG="${workdir}/kubeconfig"
  # Own partial resources too, so a failed readiness wait still triggers cleanup.
  created_cluster=true
  kind create cluster --name "${cluster}" --image "${KIND_NODE_IMAGE}" \
    --kubeconfig "${KUBECONFIG}" --wait 120s
fi
cluster_verified=true

git init --quiet "${workdir}/orka"
git -C "${workdir}/orka" fetch --depth=1 "${ORKA_REPOSITORY}" "${ORKA_REF}"
git -C "${workdir}/orka" checkout --quiet --detach FETCH_HEAD
printf 'Testing Orka %s\n' "$(git -C "${workdir}/orka" rev-parse HEAD)"
# shellcheck disable=SC1091
source "${workdir}/orka/scripts/lib/kind-local-registry.sh"
registry_started=true
orka_kind_registry_start "${cluster}" "${registry_owner}"

"${root}/scripts/install-agentgateway.sh" "${workdir}"
"${root}/scripts/install-orka.sh" "${workdir}/orka" "${workdir}"
"${root}/scripts/install-fixtures.sh" "${workdir}"
kubectl apply --server-side --dry-run=server -k "${root}/manifests/overlays/${AGENTGATEWAY_VERSION}"
kubectl apply -k "${root}/manifests/overlays/${AGENTGATEWAY_VERSION}"
kubectl wait --for=condition=Accepted --timeout=120s gatewayclass/agentgateway
kubectl wait -n orka-system --for=condition=Programmed --timeout=180s gateway/orka-egress
kubectl -n orka-system rollout status deployment/orka-egress --timeout=180s
kubectl apply --server-side --dry-run=server -f "${root}/examples/outbound-access-policy.yaml"
kubectl apply -f "${root}/examples/outbound-access-policy.yaml"
kubectl wait -n orka-system --for=condition=Accepted --timeout=120s outboundaccesspolicy/agentgateway
kubectl wait -n orka-system --for=condition=ResolvedRefs --timeout=120s outboundaccesspolicy/agentgateway

kubectl -n orka-system port-forward service/orka-egress :8080 >"${workdir}/gateway-forward.log" 2>&1 &
forward_pid=$!
for ((attempt=0; attempt<60; attempt++)); do
  if grep -q 'Forwarding from 127.0.0.1:' "${workdir}/gateway-forward.log"; then break; fi
  kill -0 "${forward_pid}" 2>/dev/null || { cat "${workdir}/gateway-forward.log" >&2; exit 1; }
  sleep 1
done
gateway_port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "${workdir}/gateway-forward.log" | head -1)"
: "${gateway_port:?Gateway port-forward did not become ready}"

# Compile against the exact Orka checkout without changing the caller's source.
# The probe uses Orka's real KubernetesResolver and ToolExecutor.
mkdir -p "${workdir}/orka/cmd/agentgateway-conformance"
cp "${root}/tests/conformance/main.go" "${workdir}/orka/cmd/agentgateway-conformance/main.go"
(
  cd "${workdir}/orka"
  go build -mod=readonly -o "${workdir}/conformance" ./cmd/agentgateway-conformance
)
"${workdir}/conformance" --gateway "127.0.0.1:${gateway_port}"
kubectl -n orka-system scale deployment/agentgateway-fixture --replicas=0
kubectl -n orka-system rollout status deployment/agentgateway-fixture --timeout=120s
kubectl -n orka-system wait --for=delete pods -l app.kubernetes.io/name=agentgateway-fixture --timeout=120s
"${workdir}/conformance" --gateway "127.0.0.1:${gateway_port}" --auth-unavailable
echo 'Orka main and agentgateway conformance passed.'
