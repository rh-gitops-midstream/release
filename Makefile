OS := $(shell uname | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

# Sync & verify source code repositories from config.yaml
.PHONY: sources
sources:
	@./hack/sync-sources.sh
	@./hack/verify-sources.sh

# Update bundle manifests with latest images
.PHONY: bundle
bundle: deps
	cp -rf sources/gitops-operator/bundle containers/gitops-operator-bundle/
	python3 containers/gitops-operator-bundle/patch-bundle.py

# Install required deps in ./bin directory
.PHONY: deps
deps:
	@. ./hack/deps.sh

# Build container images locally
.PHONY: container
# Default to podman if available, fallback to docker
CONTAINER_RUNTIME := $(shell command -v podman 2>/dev/null || command -v docker)
TAG ?= local
container:
	@if [ -z "$(name)" ]; then \
		echo "Error: Container name not specified."; \
		echo "Usage:    make container name=<name>"; \
		echo "Available container names:"; \
		ls containers/; \
		exit 1; \
	fi
	$(CONTAINER_RUNTIME) build -t $(name):$(TAG) -f containers/$(name)/Dockerfile .

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