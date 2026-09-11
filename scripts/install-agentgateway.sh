#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/versions.env"
: "${KUBECONFIG:?Set KUBECONFIG to the intended cluster before installing}"
workdir="${1:-$(mktemp -d)}"
cleanup=false
if [[ $# -eq 0 ]]; then cleanup=true; fi
trap 'if [[ "${cleanup}" == true ]]; then rm -rf "${workdir}"; fi' EXIT
# agentgateway v1.3.1 watches TCPRoute v1alpha2, which v1.6.0 serves only in
# the experimental bundle. Install it before starting the controller.
curl --fail --silent --show-error --location \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml" \
  --output "${workdir}/gateway-api.yaml"
kubectl apply --server-side -f "${workdir}/gateway-api.yaml"
kubectl wait --for=condition=Established --timeout=120s \
  crd/gatewayclasses.gateway.networking.k8s.io \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io \
  crd/tcproutes.gateway.networking.k8s.io \
  crd/tlsroutes.gateway.networking.k8s.io
# Source-tree charts contain development image tags. Published charts select
# the released controller through appVersion.
helm upgrade --install agentgateway-crds \
  "oci://cr.agentgateway.dev/charts/agentgateway-crds@${AGENTGATEWAY_CRDS_CHART_DIGEST}" \
  --namespace agentgateway-system --create-namespace --wait --timeout 5m
helm upgrade --install agentgateway \
  "oci://cr.agentgateway.dev/charts/agentgateway@${AGENTGATEWAY_CHART_DIGEST}" \
  --namespace agentgateway-system --wait --timeout 5m
