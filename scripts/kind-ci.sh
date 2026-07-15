#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/versions.env"
cluster="${KIND_CLUSTER_NAME:-orka-agentgateway-integration}"
workdir="$(mktemp -d)"
trap 'kind delete cluster --name "${cluster}" >/dev/null 2>&1 || true; rm -rf "${workdir}"' EXIT
kind create cluster --name "${cluster}" --wait 120s
"${root}/scripts/install-agentgateway.sh" "${workdir}"
kubectl apply -k "${root}/manifests/overlays/${AGENTGATEWAY_VERSION}"
if [[ -n "${ORKA_CHART_PATH:-}" ]]; then
  chart="${ORKA_CHART_PATH}"
else
  git clone --filter=blob:none "${ORKA_REPOSITORY}" "${workdir}/orka"
  git -C "${workdir}/orka" checkout --detach "${ORKA_REF}"
  chart="${workdir}/orka/charts/orka"
fi
helm upgrade --install orka "${chart}" --namespace orka-system --create-namespace \
  --set controller.outboundAccess.trustedGatewayServices[0]="agentgateway-system/agentgateway:8080" \
  --wait --timeout 5m
kubectl apply --server-side --dry-run=server -f "${root}/examples/outbound-access-policy.yaml"
