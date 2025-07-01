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
.PHONY: build
# Default to podman if available, fallback to docker
CONTAINER_RUNTIME := $(shell command -v podman 2>/dev/null || command -v docker)
TAG ?= local
build:
	@if [ -z "$(container)" ]; then \
		echo "Error: Please provide a container name to build using 'make build container=<name>'"; \
		exit 1; \
	fi
	$(CONTAINER_RUNTIME) build -t $(container):$(TAG) -f containers/$(container)/Dockerfile .