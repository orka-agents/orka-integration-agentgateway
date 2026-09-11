# Orka integration: agentgateway

Versioned manifests and a live conformance test for routing Orka HTTP Tools through agentgateway with `OutboundAccessPolicy` gateway mode. The test builds the selected Orka source revision and installs its current chart.

## Run the conformance test

Install Docker, Git, Kind, kubectl, Helm with OCI support, Go 1.27.1, curl, OpenSSL, and jq. Docker must be running. The first run builds Orka's controller and workspace publisher images, including the UI.

```bash
ORKA_REF=main ./scripts/kind-ci.sh
```

To test a local Orka branch or commit, supply an absolute repository path. The script fetches it into a temporary checkout and leaves the source checkout untouched.

```bash
ORKA_REPOSITORY="$HOME/projects/orka" ORKA_REF=main ./scripts/kind-ci.sh
```

The script creates a disposable Kind cluster with a private kubeconfig, installs agentgateway and Orka, applies the manifests, and runs the probe. It removes its cluster, image registry, and temporary files on exit. It refuses to replace an existing cluster with the same name.

For a dedicated cluster managed by another tool, set `KIND_EXISTING_CLUSTER=true`, `KIND_CLUSTER_NAME`, and an explicit `KUBECONFIG` whose current context is `kind-$KIND_CLUSTER_NAME`. That cluster is retained, but the script still removes its temporary image registry. Do not use a shared or production cluster.

## What the test verifies

- Current Orka CRDs admit the example Tool and policy, and Orka resolves the gateway Service.
- Orka's real HTTP Tool executor sends the original method, authority, path, query, body, and idempotency key through agentgateway.
- Orka forwards `Authorization` and `Txn-Token` to the gateway. The gateway replaces `Authorization` using a Kubernetes Secret and strips `Txn-Token` before the downstream request.
- The ingress route accepts the synthetic token, rejects missing or incorrect tokens, and denies access when the external authorization service stops while Orka remains healthy.
- An unconfigured authority has no matching route.

The fixture compares synthetic tokens. It does not verify transaction-token signatures or claims. This suite does not exercise MCP, OAuth token exchange, Entra OBO, or a complete agent Task lifecycle. The [OBO example](examples/entra-obo-mock.yaml) records request fields only.

See the [compatibility requirements](docs/compatibility.md), [flows](docs/flows.md), and [Orka policy example](examples/outbound-access-policy.yaml).
