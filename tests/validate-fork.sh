#!/usr/bin/env bash
# The side-by-side fork (fork/): the same TinySearch as overlays/, in its own
# namespace, running dvystrcil/TinySearch built to Harbor (remember hosts that
# refused automated access, dvystrcil/tinysearch-mcp#32). Checks the render,
# then asks the fork image itself whether it carries the feature: the stock
# image has no scrape_refused_host_ttl_seconds setting.
# Run from the repo root: tests/validate-fork.sh  (SKIP_IMAGE=1 skips the image check)
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
kubectl kustomize fork > "$tmp/rendered.yaml"

python3 - "$tmp" <<'PY'
import sys, re, json, yaml, pathlib
tmp = pathlib.Path(sys.argv[1])
NS = "tinysearch-fork"
docs = [d for d in yaml.safe_load_all((tmp / "rendered.yaml").read_text()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
fail = []
def check(cond, msg):
    if not cond: fail.append(msg)

check(("Namespace", NS) in by, f"Namespace {NS} missing")
check(("Namespace", "tinysearch") not in by, "must not also render the stock tinysearch Namespace")
for d in docs:
    if d["kind"] != "Namespace":
        check(d["metadata"].get("namespace") == NS, f"{d['kind']}/{d['metadata']['name']} not in {NS}")

dep = by.get(("Deployment", "tinysearch"))
check(dep is not None, "Deployment tinysearch missing")
if dep:
    pod = dep["spec"]["template"]["spec"]; c = pod["containers"][0]
    # A release of dvystrcil/tinysearch-fork-docker (#35, D-049): X.Y.Z plus
    # the declared suffix, which is what its release-action deploy compares.
    check(re.fullmatch(r"harbor\.sirddail\.net/ai/tinysearch-fork:\d+\.\d+\.\d+-refused-hosts", c["image"]) is not None,
          f"image must be a fork release, X.Y.Z-refused-hosts, got {c['image']}")
    check({"name": "tinysearch-harbor-pull"} in pod.get("imagePullSecrets", []),
          "needs imagePullSecrets tinysearch-harbor-pull (Harbor ai/ is private)")
    # homelab#289: a workload that consumes an Infisical-managed Secret
    # restarts when it changes. Also restarts the pod on a config change.
    check(dep["metadata"].get("annotations", {}).get("reloader.stakater.com/auto") == "true",
          "Deployment needs reloader.stakater.com/auto: \"true\" (homelab#289)")
    (tmp / "image").write_text(c["image"])

pull = by.get(("InfisicalSecret", "tinysearch-harbor-pull"))
ref = (pull or {}).get("spec", {}).get("managedSecretReference", {})
check(ref.get("secretNamespace") == NS and ref.get("secretType") == "kubernetes.io/dockerconfigjson",
      f"InfisicalSecret tinysearch-harbor-pull must create a dockerconfigjson Secret in {NS}")

cm = by.get(("ConfigMap", "tinysearch-config"))
cfg = json.loads(cm["data"]["tinysearch_config.json"]) if cm else {}
check(cfg.get("scrape_refused_host_ttl_seconds") == 600,
      "fork config must set scrape_refused_host_ttl_seconds: 600 (ten minutes, #32)")
check(cfg.get("search_backend") == "searxng", "fork must search the same SearXNG as stock")
# Brave's key-based API is opt-in in SearXNG (off by default, ~1,000 free
# requests a month); the fork asks for it by name, with yahoo, the one free
# engine still answering from the home IP (homelab#1934, searxng#23).
check(cfg.get("search_engines") == ["braveapi", "yahoo"],
      f"fork must ask SearXNG for braveapi + yahoo, got {cfg.get('search_engines')}")

# The deploy bumps the newTag under `- name: harbor.sirddail.net/ai/tinysearch-fork`.
# Only fork/ may name it, so a fork release can never reach overlays/.
for root, want in (("fork", True), ("overlays", False)):
    text = pathlib.Path(root, "kustomization.yaml").read_text()
    named = re.search(r"^\s*-\s*name:\s*harbor\.sirddail\.net/ai/tinysearch-fork\s*\n\s*newTag:", text, re.M)
    check(bool(named) == want,
          f"{root}/kustomization.yaml " + ("must" if want else "must not")
          + " have an images entry named harbor.sirddail.net/ai/tinysearch-fork with newTag")

if fail:
    print("FAIL:\n  " + "\n  ".join(fail)); sys.exit(1)
print(f"render OK: {len(docs)} objects in {NS}")
PY

if [ "${SKIP_IMAGE:-0}" != 1 ]; then
  image=$(cat "$tmp/image")
  docker run --rm --entrypoint python "$image" -c \
    "from tinysearch.config import normalize_config; print('image OK: ttl', normalize_config({})['scrape_refused_host_ttl_seconds'])"
fi
