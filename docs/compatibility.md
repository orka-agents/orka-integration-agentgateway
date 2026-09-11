# Compatibility

| Component | Selected version |
|---|---|
| Orka | `main`, with `ORKA_REF` accepting a branch, tag, or exact commit |
| Orka baseline | [`ef4dd50aab8e`](https://github.com/orka-agents/orka/commit/ef4dd50aab8e9b46e283f631860719721655b76a) |
| Orka chart | `manifest_staging/charts/orka` from the selected revision |
| agentgateway | [v1.5.0](https://github.com/agentgateway/agentgateway/releases/tag/v1.5.0), using published OCI charts pinned by digest |
| Gateway API | v1.6.1, experimental channel |
| CI Kubernetes | v1.33.7, Kind node image pinned by digest |

Defaults are in [versions.env](../versions.env). Caller values take precedence. Changing agentgateway requires a matching versioned overlay and both chart digests.

## Orka main requirements

Orka's release chart under `charts/orka` still uses the released schemas and image. It lacks `OutboundAccessPolicy` and the Tool policy reference needed here. Use the staging chart with controller and workspace publisher images built from the same source revision. The installer applies its CRDs explicitly because Helm does not upgrade files under `crds/`.

Current Orka requires `controller.watchNamespace` to match the Helm release namespace. Static trusted Service references must also stay in that namespace. This integration puts Orka, the gateway data plane, the policies, Tools, and fixtures in `orka-system`. The agentgateway controller runs in `agentgateway-system`. The same-namespace gateway reference needs no cross-namespace trust override.

The installer supplies immutable controller and publisher image references, a snapshot encryption Secret, webhook TLS, and `providerProxy.enabled=true` for the default harness-v2 mode. It creates an empty `vekil-system` namespace for the chart's provider ingress NetworkPolicy; this test needs no Vekil workload. Generated credentials and the self-signed webhook certificate are for the disposable test cluster.

## agentgateway requirements

Use the published OCI charts. The source-tree chart contains development image versions. The v1.5.0 controller uses `TCPRoute` v1. This integration matches agentgateway's [Gateway API v1.6.1 dependency](https://github.com/agentgateway/agentgateway/blob/v1.5.0/go.mod) and the experimental channel selected by its [tagged installation target](https://github.com/agentgateway/agentgateway/blob/v1.5.0/controller/Makefile#L609-L621).

Install the Gateway API CRDs before starting the controller. Use a fresh test cluster if it already has the standard channel; Gateway API's admission policy blocks switching to experimental by default.

The v1.5.0 overlay uses `failureMode: FailClosed` and `backend.auth.secretRef`. The downstream credential Secret must be named `downstream-resource-token` in `orka-system`, with the credential under its `Authorization` key. The test installer provisions it with synthetic data.
