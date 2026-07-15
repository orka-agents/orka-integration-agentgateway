# Orka integration: agentgateway

Versioned, out-of-tree manifests and conformance scaffolding for routing Orka HTTP and MCP Tools through agentgateway with `OutboundAccessPolicy` gateway mode.

## Supported

- Pinned agentgateway controller/data-plane and Gateway API overlays.
- Original Tool authority/path/query preservation while Orka dials a trusted Kubernetes Service.
- Existing `Authorization` and `Txn-Token` propagation to agentgateway.
- agentgateway OAuth token exchange for downstream resource credentials.
- Kontxt transaction-token ingress through agentgateway's ext-authz path without upstream agentgateway changes.
- Mock Entra OBO request shape and optional live-test hooks.

## Not supported

- Upstream agentgateway source changes.
- Provider-specific fields in Orka core.
- Wildcard cross-namespace Service trust.
- Sending Orka's transaction token to the final external downstream.

```bash
export ORKA_REF=main
./scripts/kind-ci.sh
```

See `docs/compatibility.md`, `examples/outbound-access-policy.yaml`, and the version-specific overlay under `manifests/overlays/`.
