#!/usr/bin/env bash
# Install the selected source revision into the integration's disposable cluster.
set -euo pipefail
source_dir="${1:?usage: install-orka.sh ORKA_SOURCE WORKDIR}"
workdir="${2:?usage: install-orka.sh ORKA_SOURCE WORKDIR}"
: "${KUBECONFIG:?Set KUBECONFIG to the integration cluster}"
: "${ORKA_KIND_REGISTRY_ADDR:?Start the integration cluster registry first}"
chart="${ORKA_CHART_PATH:-${source_dir}/manifest_staging/charts/orka}"

if [[ ! -f "${chart}/crds/outboundaccesspolicy-customresourcedefinition.yaml" ]]; then
  echo 'The Orka chart must include OutboundAccessPolicy; use manifest_staging/charts/orka for main.' >&2
  exit 1
fi

# Reuse Orka's own immutable-image registry helper and image build definitions.
# shellcheck disable=SC1091
source "${source_dir}/scripts/lib/kind-local-registry.sh"
revision="$(git -C "${source_dir}" rev-parse HEAD)"
controller_image="orka-agentgateway-controller:${revision}"
publisher_image="orka-agentgateway-publisher:${revision}"
docker build --label "org.opencontainers.image.revision=${revision}" \
  -t "${controller_image}" -f "${source_dir}/Dockerfile" "${source_dir}"
docker build --label "org.opencontainers.image.revision=${revision}" \
  -t "${publisher_image}" -f "${source_dir}/workers/publisher/Dockerfile" "${source_dir}"
controller_ref="$(orka_kind_registry_push "${controller_image}" orka/controller)"
publisher_ref="$(orka_kind_registry_push "${publisher_image}" orka/workspace-publisher)"

"${source_dir}/scripts/lib/ensure-static-mode-namespace.sh" kubectl orka-system harness-v2
# The harness-v2 chart creates a Vekil ingress NetworkPolicy in this namespace.
# HTTP Tool conformance does not need a provider workload there.
kubectl create namespace vekil-system --dry-run=client -o yaml | kubectl apply -f -
umask 077
if ! kubectl -n orka-system get secret agent-execution-snapshot-key >/dev/null 2>&1; then
  openssl rand 32 >"${workdir}/snapshot-key"
  kubectl -n orka-system create secret generic agent-execution-snapshot-key \
    --from-file="key=${workdir}/snapshot-key"
fi
if ! kubectl -n orka-system get secret orka-webhook-tls >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj /CN=orka-webhook.orka-system.svc \
    -addext 'subjectAltName=DNS:orka-webhook.orka-system.svc,DNS:orka-webhook.orka-system.svc.cluster.local' \
    -keyout "${workdir}/webhook.key" -out "${workdir}/webhook.crt" >/dev/null 2>&1
  kubectl -n orka-system create secret tls orka-webhook-tls \
    --cert="${workdir}/webhook.crt" --key="${workdir}/webhook.key"
fi
ca_bundle="$(kubectl -n orka-system get secret orka-webhook-tls -o jsonpath='{.data.tls\.crt}')"

cat >"${workdir}/orka-values.yaml" <<EOF
controller:
  watchNamespace: orka-system
  image:
    repository: ${controller_ref%@*}
    digest: ${controller_ref##*@}
  agentExecutionSnapshot:
    existingSecret: agent-execution-snapshot-key
    key: key
publisher:
  image:
    repository: ${publisher_ref%@*}
    digest: ${publisher_ref##*@}
providerProxy:
  enabled: true
webhooks:
  tls:
    existingSecret: orka-webhook-tls
  caBundle: ${ca_bundle}
EOF
# Helm does not update crds/ on upgrades, so apply the selected schemas first.
kubectl apply --server-side -f "${chart}/crds"
kubectl wait --for=condition=Established --timeout=120s crd/outboundaccesspolicies.core.orka.ai
helm upgrade --install orka "${chart}" --namespace orka-system --skip-crds \
  -f "${workdir}/orka-values.yaml" --wait --timeout 10m
