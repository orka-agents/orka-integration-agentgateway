# Compatibility

| Component | Selected version |
|---|---|
| Orka | `main`, with `ORKA_REF` accepting a branch, tag, or exact commit |
| Orka baseline | [`55cb3d5232b4`](https://github.com/orka-agents/orka/commit/55cb3d5232b4a9b697e72471e346c0a6493d4c21) |
| Orka chart | `manifest_staging/charts/orka` from the selected revision |
| agentgateway | v1.3.1, using published OCI charts pinned by digest |
| Gateway API | v1.6.0, experimental channel |
| CI Kubernetes | v1.33.7, Kind node image pinned by digest |

Defaults are in [versions.env](../versions.env). Caller values take precedence. Changing agentgateway requires a matching versioned overlay and both chart digests.

## Orka main requirements

Orka's release chart under `charts/orka` still uses the released schemas and image. It lacks `OutboundAccessPolicy` and the Tool policy reference needed here. Use the staging chart with controller and workspace publisher images built from the same source revision. The installer applies its CRDs explicitly because Helm does not upgrade files under `crds/`.

Current Orka requires `controller.watchNamespace` to match the Helm release namespace. Static trusted Service references must also stay in that namespace. This integration puts Orka, the gateway data plane, the policies, Tools, and fixtures in `orka-system`. The agentgateway controller runs in `agentgateway-system`. The same-namespace gateway reference needs no cross-namespace trust override.

The installer supplies immutable controller and publisher image references, a snapshot encryption Secret, webhook TLS, and `providerProxy.enabled=true` for the default harness-v2 mode. It creates an empty `vekil-system` namespace for the chart's provider ingress NetworkPolicy; this test needs no Vekil workload. Generated credentials and the self-signed webhook certificate are for the disposable test cluster.

## agentgateway requirements

Use the published OCI charts. The source-tree chart contains development image versions. The v1.3.1 controller watches `TCPRoute` v1alpha2, which Gateway API v1.6.0 serves in its experimental bundle. The standard bundle serves only `TCPRoute` v1 and leaves this controller unable to sync. Agentgateway's [tagged installation target](https://github.com/agentgateway/agentgateway/blob/v1.3.1/controller/Makefile#L596-L607) also selects the experimental channel.

Install the Gateway API CRDs before starting the controller. Use a fresh test cluster if it already has the standard channel; Gateway API's admission policy blocks switching to experimental by default.

The overlay uses v1.3.1's `failureMode: FailClosed` and `backend.auth.secretRef`. The downstream credential Secret must be named `downstream-resource-token` in `orka-system`, with the credential under its `Authorization` key. The test installer provisions it with synthetic data.
