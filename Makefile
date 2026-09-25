SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
OS := $(shell uname | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

# Default to podman if available, fallback to docker
CONTAINER_RUNTIME := $(shell command -v podman 2>/dev/null || command -v docker)
TAG ?= local
CHART_REGISTRY ?=

# Sync & verify source code repositories from config.yaml
.PHONY: sources
sources:
	@./hack/sync-sources.sh
	@./hack/verify-sources.sh
	@./hack/pin-pnpm-deps.sh

.PHONY: update-sources
update-sources: deps
	@bash ./hack/update-sources.sh $(UPDATE_SOURCES_ARGS)
	@$(MAKE) sources

# Update bundle manifests with latest images
.PHONY: bundle
bundle: deps
	cp -rf sources/gitops-operator/bundle containers/gitops-operator-bundle/
	python3 containers/gitops-operator-bundle/patch-bundle.py

# Install required deps in ./bin directory
.PHONY: deps
deps:
	. ./hack/deps.sh

# Build container images locally
.PHONY: container
container:
	@if [ -z "$(name)" ]; then \
		echo "Error: Container name not specified."; \
		echo "Usage:    make container name=<name>"; \
		echo "Available container names:"; \
		ls containers/; \
		exit 1; \
	fi
	$(CONTAINER_RUNTIME) build -t $(name):$(TAG) -f containers/$(name)/Dockerfile .

# Build container images locally
.PHONY: cli
cli:
	@if [ -z "$(name)" ]; then \
		echo "Error: CLI name not specified."; \
		echo "Usage:    make cli name=<name>"; \
		echo "Available cli names:"; \
		ls clis/; \
		exit 1; \
	fi
	$(CONTAINER_RUNTIME) build -t $(name):$(TAG) -f clis/$(name)/Dockerfile .

.PHONY: update-build
# Increment the build version in the BUILD file
# The BUILD file should be in the format: <base-version>-<build-number>
# Example: v1.0.0-1 → v1.0.0-2
update-build:
	@BUILD_VAL=$$(cat BUILD); \
	BASE_VERSION=$${BUILD_VAL%-*}; \
	BUILD_NUM=$${BUILD_VAL##*-}; \
	NEW_BUILD=$$((BUILD_NUM + 1)); \
	NEW_VAL=$${BASE_VERSION}-$$NEW_BUILD; \
	echo "Updating BUILD: $$BUILD_VAL → $$NEW_VAL"; \
	echo "$$NEW_VAL" > BUILD

.PHONY: setup-release
setup-release:
	python3 hack/setup-release.py

.PHONY: update-tekton-task-bundles
update-tekton-task-bundles: deps
	@echo "Updating Tekton Task Bundles..."
	@./hack/update-tekton-task-bundles.sh .tekton/*.yaml

.PHONY: catalog
catalog: deps
	@echo "Generating Operator Catalog..."
	rm -rf catalog
	git clone --branch main --depth 1 https://github.com/rh-gitops-midstream/catalog.git catalog
	python3 hack/generate-catalog.py
	cd catalog && make catalog-template && git status

.PHONY: nightly-catalog
nightly-catalog: deps
	@echo "Generating Nightly Catalog..."
	rm -rf catalog
	@NIGHTLY_BRANCH="build/nightly-catalog"; \
	REPO="https://github.com/rh-gitops-midstream/catalog.git"; \
	if git ls-remote --heads "$$REPO" "$$NIGHTLY_BRANCH" | grep -q "$$NIGHTLY_BRANCH"; then \
		echo "Nightly branch exists. Cloning and rebasing onto main..."; \
		git clone "$$REPO" catalog; \
		cd catalog && git checkout "$$NIGHTLY_BRANCH"; \
		if ! git rebase origin/main; then \
			echo "Rebase conflict. Starting fresh from main."; \
			git rebase --abort; \
			git checkout main; \
			git branch -D "$$NIGHTLY_BRANCH"; \
			git checkout -b "$$NIGHTLY_BRANCH"; \
		fi; \
	else \
		echo "Nightly branch does not exist. Creating from main..."; \
		git clone "$$REPO" catalog; \
		cd catalog && git checkout -b "$$NIGHTLY_BRANCH"; \
	fi
	python3 hack/generate-catalog.py
	cd catalog && make catalog-template && git status

# Update bundle manifests with latest images
.PHONY: agent-helm-chart
agent-helm-chart: deps
	@echo "Generating Agent Helm Chart..."
	python3 hack/generate-agent-helm-chart.py

.PHONY: agent-helm-chart-package
agent-helm-chart-package: agent-helm-chart
	@echo "Packaging Agent Helm Chart..."
	@CHART_DIR=$$(find helm-charts/redhat-argocd-agent -mindepth 2 -maxdepth 2 -type d -name src | head -n1); \
	if [ -z "$$CHART_DIR" ]; then \
		echo "Could not find generated chart src directory"; \
		exit 1; \
	fi; \
	rm -rf dist; \
	mkdir -p dist; \
	helm package "$$CHART_DIR" --destination dist; \
	echo "Packaged chart archive:"; \
	ls -1 dist/*.tgz

.PHONY: agent-helm-chart-push
agent-helm-chart-push: agent-helm-chart-package
	@if [ -z "$(CHART_REGISTRY)" ]; then \
		echo "Error: CHART_REGISTRY not set"; \
		echo "Usage: make agent-helm-chart-push CHART_REGISTRY=oci://ghcr.io/<owner>/charts"; \
		exit 1; \
	fi
	@echo "Pushing Agent Helm Chart to $(CHART_REGISTRY)..."
	@CHART_ARCHIVE=$$(ls -1 dist/*.tgz | head -n1); \
	if [ -z "$$CHART_ARCHIVE" ]; then \
		echo "Could not find packaged chart archive in dist/"; \
		exit 1; \
	fi; \
	helm push "$$CHART_ARCHIVE" "$(CHART_REGISTRY)"
	
