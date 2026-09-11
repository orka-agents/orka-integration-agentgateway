# Integration flows

## HTTP Tool egress

The example Tool targets `https://example.com/v1/resource?version=1` and references the `agentgateway` OutboundAccessPolicy. Orka preserves that authority, path, and query while dialing `orka-egress.orka-system.svc:8080` over HTTP. The public hostname satisfies Orka's destination validation; the gateway routes the request to a local fixture and never connects to example.com.

The `downstream-api` HTTPRoute accepts only that authority and path. Its policy reads the downstream credential from `downstream-resource-token`, replaces `Authorization`, and removes `Txn-Token` before forwarding to `downstream-api:8080`. This is Secret-backed credential injection. No OAuth exchange runs in this flow.

The probe compiles inside the selected Orka module and uses its real Kubernetes policy resolver and HTTP Tool executor. A loopback port-forward carries the request to the live gateway. The fixture returns credential comparison results and request digests without echoing credentials or request bodies.

## Transaction-token ingress

The `orka` HTTPRoute forwards `orka.example.test` to Orka's Service. `ext-authz-transaction-token.yaml` sends the incoming `Txn-Token` to `transaction-token-ext-authz:9000/authorize`. The fixed authorization path prevents the requested `/healthz` path from selecting the fixture's health endpoint instead of its authorization handler.

The fixture accepts only the generated synthetic token and returns a fixed correlation identifier. Missing and incorrect tokens receive HTTP 403. `failureMode: FailClosed` denies access if the fixture is unavailable. The test scales the fixture to zero and confirms that access is denied while Orka's own health endpoint remains available.

This checks header forwarding and enforcement by agentgateway. A real deployment needs an external authorization service that verifies transaction-token signatures, issuer, audience, expiry, and applicable scopes. The fixture performs none of those checks, and the test reaches Orka's health endpoint rather than a protected Task API.

## Entra OBO request fields

`examples/entra-obo-mock.yaml` records request fields only. There is no OBO endpoint, exchange test, or live-test switch in this repository. Provider credential exchange and asynchronous user-token lifecycle management need separate implementation and validation.
