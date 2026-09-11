"""Exercise installation and cluster ownership without touching a cluster."""

import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.log = self.directory / "calls.jsonl"
        self.env = os.environ.copy()
        for name in tuple(self.env):
            if name.startswith(("ORKA_", "KIND_", "AGENTGATEWAY_", "GATEWAY_API_")):
                self.env.pop(name)
        self.env.update(
            PATH=f"{self.bin}{os.pathsep}{self.env['PATH']}",
            TEST_CALLS=str(self.log),
            KIND_CLUSTER_NAME="integration-test",
            KUBECONFIG=str(self.directory / "caller-kubeconfig"),
        )
        Path(self.env["KUBECONFIG"]).write_text("caller configuration must stay untouched\n")
        for name in ("docker", "git", "kind", "kubectl", "helm", "go", "curl", "openssl", "jq"):
            executable = self.bin / name
            executable.write_text(
                f"#!{sys.executable}\n"
                "import base64, json, os, pathlib, sys\n"
                "name = pathlib.Path(sys.argv[0]).name\n"
                "args = sys.argv[1:]\n"
                "with open(os.environ['TEST_CALLS'], 'a') as log:\n"
                "    log.write(json.dumps([name, *args]) + '\\n')\n"
                "if name == 'kind' and args == ['get', 'clusters']:\n"
                "    print(os.environ.get('TEST_EXISTING_CLUSTER', ''))\n"
                "elif name == 'kind' and args[:2] == ['create', 'cluster']:\n"
                "    sys.exit(42)\n"
                "elif name == 'kubectl' and args == ['config', 'current-context']:\n"
                "    print(os.environ.get('TEST_CONTEXT', 'kind-integration-test'))\n"
                "elif name == 'kubectl' and args[:6] == ['-n', 'orka-system', 'create', 'secret', 'tls', 'orka-webhook-tls']:\n"
                "    data = {}\n"
                "    for flag, key in [('--cert=', 'tls.crt'), ('--key=', 'tls.key')]:\n"
                "        path = next(arg[len(flag):] for arg in args if arg.startswith(flag))\n"
                "        data[key] = base64.b64encode(pathlib.Path(path).read_bytes()).decode()\n"
                "    print(json.dumps({'kind': 'Secret', 'metadata': {'name': 'orka-webhook-tls'}, 'data': data}))\n"
                "elif name == 'kubectl' and args == ['apply', '-f', '-'] and 'TEST_TLS_SECRET' in os.environ:\n"
                "    manifest = sys.stdin.read()\n"
                "    if manifest:\n"
                "        pathlib.Path(os.environ['TEST_TLS_SECRET']).write_text(manifest)\n"
                "elif name == 'kubectl' and args[:5] == ['-n', 'orka-system', 'get', 'secret', 'orka-webhook-tls']:\n"
                "    if '-o' in args:\n"
                "        print(json.loads(pathlib.Path(os.environ['TEST_TLS_SECRET']).read_text())['data']['tls.crt'])\n"
                "elif name == 'git' and 'fetch' in args:\n"
                "    sys.exit(43)\n"
            )
            executable.chmod(0o755)

    def run_script(self, name, *args):
        return subprocess.run(
            ["bash", str(ROOT / "scripts" / name), *args],
            env=self.env,
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=15,
        )

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_caller_revision_and_repository_survive_defaults(self):
        self.env.update(ORKA_REF="exact-commit", ORKA_REPOSITORY="/local/orka")
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; printf "%s\\n" "$ORKA_REF" "$ORKA_REPOSITORY"', "bash", str(ROOT / "versions.env")],
            env=self.env, text=True, capture_output=True, check=True,
        )
        self.assertEqual(result.stdout.splitlines(), ["exact-commit", "/local/orka"])

    def test_existing_cluster_is_never_replaced_or_deleted(self):
        self.env["TEST_EXISTING_CLUSTER"] = "integration-test"
        result = self.run_script("kind-ci.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace existing cluster", result.stderr)
        self.assertEqual(self.calls(), [["kind", "get", "clusters"]])

    def test_existing_cluster_requires_matching_context(self):
        self.env.update(KIND_EXISTING_CLUSTER="true", TEST_CONTEXT="some-other-cluster")
        result = self.run_script("kind-ci.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("KUBECONFIG must select kind-integration-test", result.stderr)
        self.assertEqual(self.calls(), [["kubectl", "config", "current-context"]])

    def test_fetch_uses_requested_ref_and_does_not_delete_borrowed_cluster(self):
        self.env.update(KIND_EXISTING_CLUSTER="true", ORKA_REF="test-revision", ORKA_REPOSITORY="/local/orka")
        result = self.run_script("kind-ci.sh")
        self.assertEqual(result.returncode, 43)
        fetches = [call for call in self.calls() if call[0] == "git" and "fetch" in call]
        self.assertEqual(len(fetches), 1)
        self.assertEqual(fetches[0][-2:], ["/local/orka", "test-revision"])
        self.assertFalse(any(call[:3] == ["kind", "delete", "cluster"] for call in self.calls()))

    def test_new_cluster_does_not_use_callers_kubeconfig(self):
        original = Path(self.env["KUBECONFIG"]).read_text()
        result = self.run_script("kind-ci.sh")
        self.assertEqual(result.returncode, 42)
        create = next(call for call in self.calls() if call[:3] == ["kind", "create", "cluster"])
        scoped_config = create[create.index("--kubeconfig") + 1]
        self.assertNotEqual(scoped_config, self.env["KUBECONFIG"])
        self.assertEqual(Path(self.env["KUBECONFIG"]).read_text(), original)
        self.assertFalse(any(call[0] == "kubectl" for call in self.calls()))

    def test_failed_cluster_creation_is_cleaned_up(self):
        result = self.run_script("kind-ci.sh")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(self.calls()[-1], ["kind", "delete", "cluster", "--name", "integration-test"])

    def test_reinstall_refreshes_webhook_certificate_and_rollout_annotation(self):
        real_openssl = shutil.which("openssl")
        (self.bin / "openssl").unlink()
        (self.bin / "openssl").symlink_to(real_openssl)
        source = self.directory / "orka"
        crds = source / "manifest_staging/charts/orka/crds"
        crds.mkdir(parents=True)
        (crds / "outboundaccesspolicy-customresourcedefinition.yaml").touch()
        library = source / "scripts/lib"
        library.mkdir(parents=True)
        (library / "kind-local-registry.sh").write_text(
            'orka_kind_registry_push() { printf "%s@sha256:%064d\\n" "$2" 0; }\n'
        )
        namespace_script = library / "ensure-static-mode-namespace.sh"
        namespace_script.write_text("#!/usr/bin/env bash\nexit 0\n")
        namespace_script.chmod(0o755)
        secret = self.directory / "tls-secret.json"
        old_cert = base64.b64encode(b"stale test certificate").decode()
        secret.write_text(json.dumps({"data": {"tls.crt": old_cert}}))
        self.env.update(ORKA_KIND_REGISTRY_ADDR="127.0.0.1:5000", TEST_TLS_SECRET=str(secret))

        for _ in range(2):
            result = self.run_script("install-orka.sh", str(source), str(self.directory))
            self.assertEqual(result.returncode, 0, result.stderr)
            cert = json.loads(secret.read_text())["data"]["tls.crt"]
            self.assertNotEqual(cert, old_cert)
            certificate = self.directory / "installed.crt"
            certificate.write_bytes(base64.b64decode(cert))
            subprocess.run(
                [real_openssl, "x509", "-in", str(certificate), "-noout", "-checkend", "3600"],
                text=True, capture_output=True, check=True,
            )
            for hostname in ("orka-webhook.orka-system.svc", "orka-webhook.orka-system.svc.cluster.local"):
                identity = subprocess.run(
                    [real_openssl, "x509", "-in", str(certificate), "-noout", "-checkhost", hostname],
                    text=True, capture_output=True, check=True,
                )
                self.assertIn("does match certificate", identity.stdout)
            values = (self.directory / "orka-values.yaml").read_text()
            self.assertIn(f"  caBundle: {cert}\n", values)
            checksum = hashlib.sha256(certificate.read_bytes()).hexdigest()
            self.assertIn(f'  orka.ai/webhook-certificate-sha256: "{checksum}"\n', values)
            old_cert = cert

    def test_release_chart_is_rejected_before_build_or_install(self):
        self.env.update(ORKA_CHART_PATH=str(self.directory / "old-chart"), ORKA_KIND_REGISTRY_ADDR="127.0.0.1:5000")
        result = self.run_script("install-orka.sh", str(self.directory), str(self.directory))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("chart must include OutboundAccessPolicy", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_gateway_installs_gateway_api_before_published_charts(self):
        result = self.run_script("install-agentgateway.sh", str(self.directory))
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        download = next(call for call in calls if call[0] == "curl")
        self.assertIn("https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/experimental-install.yaml", download)
        gateway_api = next(i for i, call in enumerate(calls) if call[:3] == ["kubectl", "apply", "--server-side"])
        installs = [i for i, call in enumerate(calls) if call[:4] == ["helm", "upgrade", "--install", "agentgateway-crds"] or call[:4] == ["helm", "upgrade", "--install", "agentgateway"]]
        self.assertEqual(len(installs), 2)
        self.assertLess(gateway_api, installs[0])
        for index in installs:
            self.assertIn("oci://cr.agentgateway.dev/charts/", calls[index][4])
            self.assertIn("@sha256:", calls[index][4])
        self.assertFalse(any(call[0] == "git" for call in calls))


if __name__ == "__main__":
    unittest.main()
