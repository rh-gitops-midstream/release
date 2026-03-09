#!/usr/bin/env python3

import re
import shutil
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "config.yaml"
SOURCE_CHART_DIR = ROOT / "sources/argocd-agent/install/helm-repo/argocd-agent-agent"
TARGET_BASE_DIR = ROOT / "helm-charts/redhat-argocd-agent"


def read_agent_ref(config_path: Path) -> str:
	with config_path.open("r", encoding="utf-8") as file:
		config = yaml.safe_load(file)

	for source in config.get("sources", []):
		if source.get("path") == "sources/argocd-agent":
			ref = source.get("ref")
			if not ref:
				raise ValueError("Missing ref for sources/argocd-agent in config.yaml")
			return ref

	raise ValueError("Could not find sources/argocd-agent in config.yaml")


def read_agent_image_repository(config_path: Path) -> str:
	with config_path.open("r", encoding="utf-8") as file:
		config = yaml.safe_load(file)

	for image in config.get("konfluxImages", []):
		if image.get("name") == "argocd-agent":
			release_ref = image.get("releaseRef")
			if not release_ref:
				raise ValueError("Missing releaseRef for konfluxImages.argocd-agent in config.yaml")
			return release_ref

	raise ValueError("Could not find konfluxImages.argocd-agent in config.yaml")


def read_release_image_tag(config_path: Path) -> str:
	with config_path.open("r", encoding="utf-8") as file:
		config = yaml.safe_load(file)

	release = config.get("release") or {}
	release_version = release.get("version")
	if not release_version:
		raise ValueError("Missing release.version in config.yaml")

	return release_version if str(release_version).startswith("v") else f"v{release_version}"


def normalize_version(ref: str) -> str:
	version = re.sub(r"^v", "", ref)
	version = re.sub(r"[-+].*$", "", version)
	return version


def update_copied_chart_files(version: str, image_repository: str, image_tag: str) -> None:
	chart_path = TARGET_BASE_DIR / version / "src" / "Chart.yaml"
	values_path = TARGET_BASE_DIR / version / "src" / "values.yaml"

	if not chart_path.exists():
		raise FileNotFoundError(f"Chart file not found: {chart_path}")
	if not values_path.exists():
		raise FileNotFoundError(f"Values file not found: {values_path}")

	with chart_path.open("r", encoding="utf-8") as file:
		chart = yaml.safe_load(file) or {}

	chart["name"] = "redhat-argocd-agent"
	chart["description"] = "RedHat Argo CD Agent for connecting managed clusters to a Principal"
	chart["version"] = version
	chart["appVersion"] = version
	chart["icon"] = "https://raw.githubusercontent.com/redhat-developer/gitops-operator/refs/heads/master/docs/Red_Hat-OpenShift_GitOps-Standard-RGB.svg"
	annotations = chart.get("annotations") or {}
	annotations["charts.openshift.io/name"] = "RedHat Argo CD Agent - Agent Component"
	chart["annotations"] = annotations

	with chart_path.open("w", encoding="utf-8") as file:
		yaml.safe_dump(chart, file, sort_keys=False)

	with values_path.open("r", encoding="utf-8") as file:
		values = yaml.safe_load(file) or {}

	image = values.get("image") or {}
	image["repository"] = image_repository
	image["tag"] = image_tag
	values["image"] = image

	with values_path.open("w", encoding="utf-8") as file:
		yaml.safe_dump(values, file, sort_keys=False)


def regenerate_chart_layout(version: str, image_repository: str, image_tag: str) -> None:
	if not SOURCE_CHART_DIR.exists():
		raise FileNotFoundError(f"Source chart directory not found: {SOURCE_CHART_DIR}")

	if TARGET_BASE_DIR.exists():
		for child in TARGET_BASE_DIR.iterdir():
			if child.is_dir():
				shutil.rmtree(child)
			else:
				child.unlink()
	else:
		TARGET_BASE_DIR.mkdir(parents=True, exist_ok=True)

	target_src_dir = TARGET_BASE_DIR / version / "src"
	target_src_dir.mkdir(parents=True, exist_ok=True)

	shutil.copytree(SOURCE_CHART_DIR, target_src_dir, dirs_exist_ok=True)
	update_copied_chart_files(version, image_repository, image_tag)


def main() -> None:
	agent_ref = read_agent_ref(CONFIG_PATH)
	version = normalize_version(agent_ref)
	image_repository = read_agent_image_repository(CONFIG_PATH)
	image_tag = read_release_image_tag(CONFIG_PATH)
	regenerate_chart_layout(version, image_repository, image_tag)
	print(f"Generated helm chart at: {TARGET_BASE_DIR / version / 'src'}")


if __name__ == "__main__":
	main()
