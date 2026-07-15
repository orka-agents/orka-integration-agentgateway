#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/versions.env"
workdir="${1:-$(mktemp -d)}"
cleanup=false
if [[ $# -eq 0 ]]; then cleanup=true; fi
trap 'if [[ "${cleanup}" == true ]]; then rm -rf "${workdir}"; fi' EXIT
git clone --depth 1 --branch "${AGENTGATEWAY_VERSION}" https://github.com/agentgateway/agentgateway.git "${workdir}/agentgateway"
helm upgrade --install agentgateway-crds "${workdir}/agentgateway/controller/install/helm/agentgateway-crds" \
  --namespace agentgateway-system --create-namespace --wait --timeout 5m
helm upgrade --install agentgateway "${workdir}/agentgateway/controller/install/helm/agentgateway" \
  --namespace agentgateway-system --wait --timeout 5m
