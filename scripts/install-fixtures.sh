#!/usr/bin/env bash
# Synthetic credentials and services for the disposable integration cluster.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="${1:?usage: install-fixtures.sh WORKDIR}"
: "${KUBECONFIG:?Set KUBECONFIG to the integration cluster}"
umask 077
openssl rand -hex 32 >"${workdir}/txn-token"
printf 'Bearer %s' "$(openssl rand -hex 32)" >"${workdir}/upstream-authorization"
printf 'Bearer %s' "$(openssl rand -hex 32)" >"${workdir}/downstream-authorization"
kubectl -n orka-system create secret generic agentgateway-fixture \
  --from-file="txn-token=${workdir}/txn-token" \
  --from-file="upstream-authorization=${workdir}/upstream-authorization" \
  --from-file="downstream-authorization=${workdir}/downstream-authorization" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n orka-system create secret generic downstream-resource-token \
  --from-file="Authorization=${workdir}/downstream-authorization" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n orka-system create configmap agentgateway-fixture \
  --from-file="server.py=${root}/tests/fixtures/server.py" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${root}/tests/fixtures/resources.yaml"
kubectl -n orka-system rollout restart deployment/agentgateway-fixture
kubectl -n orka-system rollout status deployment/agentgateway-fixture --timeout=180s
