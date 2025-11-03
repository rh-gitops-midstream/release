from ruamel.yaml import YAML
from pathlib import Path
import subprocess
import json
import sys
import argparse
import re

parser = argparse.ArgumentParser()
parser.add_argument("--argocd-sha", type=str, help="Specify the Argo CD Image SHA to use in the CSV.")
parser.add_argument("--argocd-version", type=str, help="Argo CD version (e.g., v2.14.0)",
)
args = parser.parse_args()
if bool(args.argocd_sha) != bool(args.argocd_version):
    print("[error] --argocd-sha and --argocd-version must be set together")
    sys.exit(1)
if args.argocd_sha:
    if not re.fullmatch(r"sha256:[0-9a-f]+", args.argocd_sha):
        print(f"[error] Invalid SHA format: {args.argocd_sha} (should be @sha256:...)")
        sys.exit(1)


# --- Skopeo check ---
try:
    subprocess.run(["skopeo", "--version"], check=True, capture_output=False)
except FileNotFoundError:
    print("[error] 'skopeo' is not installed. Please install skopeo >= 1.18.0.")
    sys.exit(1)

# --- Helpers ---

def get_digest(image: str) -> str:
    print(f"Fetching sha256 digest for {image}...")
    output = subprocess.run(
        ["skopeo", "inspect", "--override-os", "linux", "--override-arch", "amd64", f"docker://{image}"],
        capture_output=True, text=True, check=True
    )
    digest = json.loads(output.stdout)["Digest"]
    return digest

def merge_env(existing, new):
    """Merge two env lists, dedup by name (last-wins)."""
    merged = {e['name']: e for e in existing}
    for e in new:
        merged[e['name']] = e
    return list(merged.values())

# --- YAML setup ---

yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 100000
yaml.indent(mapping=2, sequence=4, offset=2)

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
CONFIG_FILE = REPO_ROOT / "config.yaml"
CSV_FILE = REPO_ROOT / "containers/gitops-operator-bundle/bundle/manifests/gitops-operator.clusterserviceversion.yaml"
METADATA_FILE = REPO_ROOT / "containers/gitops-operator-bundle/bundle/metadata/annotations.yaml"
DOCKERFILE = REPO_ROOT / "containers/gitops-operator-bundle/Dockerfile"

# --- Load config ---

with CONFIG_FILE.open() as file:
    config = yaml.load(file)

images = {}
replacements = {}

# --- Load images ---

for img in config.get('externalImages', []):
    images[img['name']] = f"{img['image']}:{img['version']}"

tag = config.get('release', {}).get('konflux', {}).get('branch', 'latest')
for img in config.get('konfluxImages', []):
    images[img['name']] = f"{img['buildRef']}:{tag}"
    replacements[img['buildRef']] = img['releaseRef']

# --- Convert to digests ---

for id, img in list(images.items()):
    base = img.split(":")[0]
    if "gitops-operator-bundle" in base:
        print(f">>> Skipping digest conversion for {base} as it is a bundle image.")
        continue
    digest = get_digest(img)
    if id == 'argocd' and args.argocd_sha:
        print(f">>> Using provided Argo CD SHA: {args.argocd_sha}")
        digest = args.argocd_sha
    image_ref = replacements.get(base, base)
    images[id] = f"{image_ref}@{digest}"
    print(f">>> Final Image: {images[id]}")

# --- relatedImages and env ---

relatedImages = [
    {'name': 'manager', 'image': images['gitops-operator']},
    {'name': 'kube-rbac-proxy', 'image': images['kube-rbac-proxy']},
    {'name': 'kube_rbac_proxy_image', 'image': images['kube-rbac-proxy']},
    {'name': 'argocd_dex_image', 'image': images['dex']},
    {'name': 'argocd_keycloak_image', 'image': images['keycloak']},
    {'name': 'backend_image', 'image': images['gitops']},
    {'name': 'argocd_image', 'image': images['argocd']},
    {'name': 'argocd_redis_image', 'image': images['redis']},
    {'name': 'argocd_redis_ha_proxy_image', 'image': images['haproxy']},
    {'name': 'gitops_console_plugin_image', 'image': images['console-plugin']},
    {'name': 'argocd_extension_image', 'image': images['argocd-extenstions']},
    {'name': 'argo_rollouts_image', 'image': images['argo-rollouts']},
    {'name': 'must_gather_image', 'image': images['must-gather']},
]

new_env = [
    {'name': 'ARGOCD_CLUSTER_CONFIG_NAMESPACES', 'value': 'openshift-gitops'},
    {'name': 'CLUSTER_SCOPED_ARGO_ROLLOUTS_NAMESPACES', 'value': 'openshift-gitops'},
    {'name': 'ENABLE_CONVERSION_WEBHOOK', 'value': 'true'},
    {'name': 'RELATED_IMAGE_ARGOCD_DEX_IMAGE', 'value': images['dex']},
    {'name': 'ARGOCD_DEX_IMAGE', 'value': images['dex']},
    {'name': 'RELATED_IMAGE_ARGOCD_KEYCLOAK_IMAGE', 'value': images['keycloak']},
    {'name': 'ARGOCD_KEYCLOAK_IMAGE', 'value': images['keycloak']},
    {'name': 'RELATED_IMAGE_BACKEND_IMAGE', 'value': images['gitops']},
    {'name': 'BACKEND_IMAGE', 'value': images['gitops']},
    {'name': 'RELATED_IMAGE_ARGOCD_IMAGE', 'value': images['argocd']},
    {'name': 'ARGOCD_IMAGE', 'value': images['argocd']},
    {'name': 'ARGOCD_REPOSERVER_IMAGE', 'value': images['argocd']},
    {'name': 'RELATED_IMAGE_ARGOCD_REDIS_IMAGE', 'value': images['redis']},
    {'name': 'ARGOCD_REDIS_IMAGE', 'value': images['redis']},
    {'name': 'ARGOCD_REDIS_HA_IMAGE', 'value': images['redis']},
    {'name': 'RELATED_IMAGE_ARGOCD_REDIS_HA_PROXY_IMAGE', 'value': images['haproxy']},
    {'name': 'ARGOCD_REDIS_HA_PROXY_IMAGE', 'value': images['haproxy']},
    {'name': 'RELATED_IMAGE_GITOPS_CONSOLE_PLUGIN_IMAGE', 'value': images['console-plugin']},
    {'name': 'GITOPS_CONSOLE_PLUGIN_IMAGE', 'value': images['console-plugin']},
    {'name': 'RELATED_IMAGE_ARGOCD_EXTENSION_IMAGE', 'value': images['argocd-extenstions']},
    {'name': 'ARGOCD_EXTENSION_IMAGE', 'value': images['argocd-extenstions']},
    {'name': 'RELATED_IMAGE_ARGO_ROLLOUTS_IMAGE', 'value': images['argo-rollouts']},
    {'name': 'ARGO_ROLLOUTS_IMAGE', 'value': images['argo-rollouts']},
    {'name': 'RELATED_IMAGE_MUST_GATHER_IMAGE', 'value': images['must-gather']},
    {'name': 'RELATED_IMAGE_KUBE_RBAC_PROXY_IMAGE', 'value': images['kube-rbac-proxy']},
]

# --- OLM fields ---

package = "openshift-gitops-operator"
version = config.get('release', {}).get('version', '').removeprefix('v')
olm = config.get('release', {}).get('olm', {})
channel = olm.get('channel', '')
skip_range = olm.get('skip-range', '')
replaces = olm.get('replaces', '')

argocd_version = None
for source in config.get("sources", []):
    if source.get("path") == "sources/argo-cd":
        argocd_version = source.get("ref")
        break
# Use provided Argo CD version if specified using --argocd-version cli argument
if args.argocd_version:
    argocd_version = args.argocd_version

# --- Patch Dockerfile ---

print(f"Patching Dockerfile: {DOCKERFILE}")
with DOCKERFILE.open() as file:
    dockerfile = file.readlines()

with DOCKERFILE.open("w") as file:
    for line in dockerfile:
        if line.startswith("LABEL operators.operatorframework.io.bundle.channels.v1="):
            file.write(f"LABEL operators.operatorframework.io.bundle.channels.v1={channel}\n")
        else:
            file.write(line)

# --- Patch Metadata ---

print(f"Patching metadata file: {METADATA_FILE}")
with METADATA_FILE.open() as file:
    metadata = yaml.load(file)
metadata['annotations']['operators.operatorframework.io.bundle.package.v1'] = package
metadata['annotations']['operators.operatorframework.io.bundle.channels.v1'] = channel
with METADATA_FILE.open("w") as file:
    yaml.dump(metadata, file)
print(">>> Metadata file patched successfully.")

# --- Patch CSV ---

print(f"Patching CSV file: {CSV_FILE}")
with CSV_FILE.open() as file:
    csv = yaml.load(file)
csv['metadata'].setdefault('labels', {})

csv['metadata']['annotations']['operators.openshift.io/valid-subscription'] = '["OpenShift Container Platform", "OpenShift Platform Plus"]'
csv['metadata']['annotations']['operators.operatorframework.io/internal-objects'] = '["gitopsservices.pipelines.openshift.io"]'
csv['metadata']['annotations']['operators.openshift.io/must-gather-image'] = images['must-gather']
csv['metadata']['annotations']['features.operators.openshift.io/fips-compliant'] = 'true'
csv['metadata']['annotations']['features.operators.openshift.io/cnf'] = 'false'
csv['metadata']['annotations']['features.operators.openshift.io/cni'] = 'false'
csv['metadata']['annotations']['features.operators.openshift.io/csi'] = 'false'
csv['metadata']['labels']['operatorframework.io/os.linux'] = 'supported'
csv['metadata']['labels']['operatorframework.io/arch.amd64'] = 'supported'
csv['metadata']['labels']['operatorframework.io/arch.arm64'] = 'supported'
csv['metadata']['labels']['operatorframework.io/arch.ppc64le'] = 'supported'
csv['metadata']['labels']['operatorframework.io/arch.s390x'] = 'supported'
csv['spec']['maturity'] = 'GA'
csv['spec']['maintainers'] = [{'email': 'team-gitops@redhat.com', 'name': 'OpenShift GitOps Team'}]

csv['metadata']['name'] = f"{package}.v{version}"
csv['metadata']['annotations']['olm.skipRange'] = skip_range
csv['spec']['version'] = version
csv['spec']['replaces'] = replaces

csv['spec']['description'] = (
    f"Red Hat OpenShift GitOps is a declarative continuous delivery platform based on [Argo CD]"
    f"(https://argoproj.github.io/argo-cd/). It enables teams to adopt GitOps principles for managing "
    f"cluster configurations and automating secure and repeatable application delivery across hybrid multi-cluster "
    f"Kubernetes environments. Following GitOps and infrastructure as code principles, you can store the configuration "
    f"of clusters and applications in Git repositories and use Git workflows to roll them out to the target clusters.\n\n"
    f"## Features\n"
    f"* Automated install and upgrades of Argo CD\n"
    f"* Manual and automated configuration sync from Git repositories to target OpenShift and Kubernetes clusters\n"
    f"* Support for the Helm and Kustomize templating tools\n"
    f"* Configuration drift detection and visualization on live clusters\n"
    f"* Audit trails of rollouts to the clusters\n"
    f"* Monitoring and logging integration with OpenShift\n"
    f"##Components\n"
    f"* Argo CD {argocd_version}\n\n"
    f"## How to Install \n"
    f"After installing the OpenShift GitOps operator, an instance  of Argo CD is installed in the `openshift-gitops` namespace which has sufficient privileges for managing cluster configurations. "
    f"You can create additional Argo CD instances using the `ArgoCD` custom resource within the desired namespaces.\n"
    f"```yaml\n"
    f"apiVersion: argoproj.io/v1beta1\nkind: ArgoCD\nmetadata:\n  name: argocd\nspec:\n  server:\n    route:\n      enabled: true\n```\n\n"
    f"OpenShift GitOps is a layered product on top of OpenShift that enables teams to adopt GitOps principles for managing cluster configurations and automating secure and repeatable application delivery across hybrid multi-cluster Kubernetes environments. OpenShift GitOps is built around Argo CD as the core upstream project and assists customers to establish an end-to-end application delivery workflow on GitOps principles.\n"
)

csv['metadata']['annotations']['containerImage'] = images['gitops-operator']
csv['spec']['install']['spec']['deployments'][0]['spec']['template']['spec']['containers'][0]['image'] = images['gitops-operator']
csv['spec']['install']['spec']['deployments'][0]['spec']['template']['spec']['containers'][1]['image'] = images['kube-rbac-proxy']
csv['spec']['relatedImages'] = relatedImages

# Merge env with deduplication
container0 = csv['spec']['install']['spec']['deployments'][0]['spec']['template']['spec']['containers'][0]
existing_env = container0.get('env', [])
container0['env'] = merge_env(existing_env, new_env)

with CSV_FILE.open("w") as file:
    yaml.dump(csv, file)
print(">>> CSV file patched successfully.")
