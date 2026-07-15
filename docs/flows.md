# Integration flows

## Transaction-token ingress

`ext-authz-transaction-token.yaml` uses the agentgateway v1.3.1 `AgentgatewayPolicy.spec.traffic.extAuth` shape. The external authorization service verifies the incoming transaction token, enforces ingress policy, and forwards only safe correlation metadata to Orka. No upstream agentgateway source change is required.

## Resource-token egress

Orka gateway mode sends the original authority/path/query and current governance headers to agentgateway. The gateway exchanges or resolves the downstream resource credential, overwrites `Authorization`, and removes `Txn-Token` before contacting the external API. `backend-resource-auth.yaml` captures the pinned v1.3.1 backend header-auth shape; provider-specific OAuth exchange configuration belongs beside this overlay and is validated with mock infrastructure before live use.

## Entra OBO

`examples/entra-obo-mock.yaml` records the request shape only. Live OBO is opt-in and must source client credentials from Kubernetes Secrets. This integration does not solve asynchronous user-token lifecycle management.
