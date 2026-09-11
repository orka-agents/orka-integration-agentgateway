# Contributing

Keep upstream versions pinned and put agentgateway CRD changes in a versioned overlay. Use synthetic credentials in CI, keep them in Kubernetes Secrets, and never print them in diagnostics.

Run the focused checks before the cluster test:

```bash
for script in scripts/*.sh; do bash -n "$script"; done
shellcheck scripts/*.sh
python3 -m unittest discover -s tests -v
scripts/check-redaction.sh
kubectl kustomize manifests/base > /dev/null
actionlint .github/workflows/ci.yml .github/workflows/kind.yml
git diff --check
```

Run `ORKA_REF=main ./scripts/kind-ci.sh` to build the current Orka images, validate the manifests against live CRDs, and exercise HTTP egress and ingress enforcement. Set `ORKA_REF` to an exact commit when reproducing a failure. The workflow's `orka_ref` input selects the same source revision.

Update the compatibility document when the required Orka chart fields, namespace rules, or tested gateway versions change. Keep coverage claims limited to checks the suite actually runs.
