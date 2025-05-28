from ruamel.yaml import YAML
import os
import re
from pathlib import Path
import subprocess
import json
from git import Repo

yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 100000
yaml.indent(mapping=2, sequence=4, offset=2)

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_FILE = f"{REPO_ROOT}/config.yaml"
CSV_FILE = f"{REPO_ROOT}/gitops-operator-bundle/bundle/manifests/gitops-operator.clusterserviceversion.yaml"
METADATA_FILE = f"{REPO_ROOT}/gitops-operator-bundle/bundle/metadata/annotations.yaml"
BRANCH = Repo(REPO_ROOT).active_branch.name

images = {}

# Load config file
with open(CONFIG_FILE, 'r') as file:
    config = yaml.load(file)

# Load dependencies images from config.yaml
with open(CONFIG_FILE, 'r') as file:
    config = yaml.load(file)
    deps = config['dependencies']
    for dep in deps:
        if dep['type'] == 'image':
            images[dep['id']] = dep['ref']

# Fetch & load latest artifact images from config.yaml
with open(CONFIG_FILE, 'r') as file:
    config = yaml.load(file)
    artifacts = config['artifacts']
    for artifact in artifacts:
        if artifact['type'] != 'image':
            continue
        releaseRef = artifact['releaseRef'].split('@')[0].strip() 

        # fetch latest sha for the image from CI buildRefs using skopeo
        buildRef = artifact['konflux-ci']['buildRef'].split('@')[0].strip() 
        print(f"Fetching latest image for {releaseRef} from {buildRef}...")
        output = subprocess.run(
            ["skopeo", "inspect", "--override-os", "linux", "--override-arch", "amd64", f"docker://{buildRef}:{BRANCH}"],
            capture_output=True, text=True, check=True
        )
        digest = json.loads(output.stdout)["Digest"]

        images[artifact['id']] = f"{releaseRef}@{digest}"

# Patch Data
# TODO: Compute these values dynamically based on the config file and other sources
package = "openshift-gitops-operator"
version = config['release']['version'] 
channel = "gitops-1.16"
skip_range = ">=1.0.0 <1.16.0"
replaces = "openshift-gitops-operator.v1.16.1"

relatedImages = [
    {'name': 'manager', 'image': images['operator']},
    {'name': 'kube-rbac-proxy', 'image': images['kube-proxy']},
    {'name': 'kube_rbac_proxy_image', 'image': images['kube-proxy']},
    {'name': 'argocd_dex_image', 'image': images['dex']},
    {'name': 'argocd_keycloak_image', 'image': images['keycloak']},
    {'name': 'backend_image', 'image': images['backend']},
    {'name': 'argocd_image', 'image': images['argocd']},
    {'name': 'argocd_redis_image', 'image': images['redis']},
    {'name': 'argocd_redis_ha_proxy_image', 'image': images['haproxy']},
    {'name': 'gitops_console_plugin_image', 'image': images['console-plugin']},
    {'name': 'argocd_extension_image', 'image': images['extensions']},
    {'name': 'argo_rollouts_image', 'image': images['rollouts']},
    {'name': 'must_gather_image', 'image': images['must-gather']},
]

env = [
    {'name': 'ARGOCD_CLUSTER_CONFIG_NAMESPACES', 'value': 'openshift-gitops'},
    {'name': 'CLUSTER_SCOPED_ARGO_ROLLOUTS_NAMESPACES', 'value': 'openshift-gitops'},
    {'name': 'ENABLE_CONVERSION_WEBHOOK', 'value': 'true'},
    {'name': 'RELATED_IMAGE_ARGOCD_DEX_IMAGE', 'value': images['dex']},
    {'name': 'ARGOCD_DEX_IMAGE', 'value': images['dex']},
    {'name': 'RELATED_IMAGE_ARGOCD_KEYCLOAK_IMAGE', 'value': images['keycloak']},
    {'name': 'ARGOCD_KEYCLOAK_IMAGE', 'value': images['keycloak']},
    {'name': 'RELATED_IMAGE_BACKEND_IMAGE', 'value': images['backend']},
    {'name': 'BACKEND_IMAGE', 'value': images['backend']},
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
    {'name': 'RELATED_IMAGE_ARGOCD_EXTENSION_IMAGE', 'value': images['extensions']},
    {'name': 'ARGOCD_EXTENSION_IMAGE', 'value': images['extensions']},
    {'name': 'RELATED_IMAGE_ARGO_ROLLOUTS_IMAGE', 'value': images['rollouts']},
    {'name': 'ARGO_ROLLOUTS_IMAGE', 'value': images['rollouts']},
    {'name': 'RELATED_IMAGE_MUST_GATHER_IMAGE', 'value': images['must-gather']},
    {'name': 'RELATED_IMAGE_KUBE_RBAC_PROXY_IMAGE', 'value': images['kube-proxy']},
]

# Patch Metadata file
with open(METADATA_FILE, 'r') as file:
    metadata = yaml.load(file)
metadata['annotations']['operators.operatorframework.io.bundle.package.v1'] = package
metadata['annotations']['operators.operatorframework.io.bundle.channels.v1'] = channel
with open(METADATA_FILE, 'w') as file:
    yaml.dump(metadata, file)

# Patch CSV file
with open(CSV_FILE, 'r') as file:
    csv = yaml.load(file)
if 'labels' not in csv['metadata']:
    csv['metadata']['labels'] = {}

csv['metadata']['annotations']['operators.openshift.io/valid-subscription'] = '["OpenShift Container Platform", "OpenShift Platform Plus"]'
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

# image replacements
csv['metadata']['annotations']['containerImage'] = images['operator']
csv['spec']['install']['spec']['deployments'][0]['spec']['template']['spec']['containers'][0]['image'] = images['operator']
csv['spec']['install']['spec']['deployments'][0]['spec']['template']['spec']['containers'][1]['image'] = images['kube-proxy']
csv['spec']['relatedImages'] = relatedImages
csv['spec']['install']['spec']['deployments'][0]['spec']['template']['spec']['containers'][0]['env'] = env

with open(CSV_FILE, 'w') as file:
    yaml.dump(csv, file)
