OS := $(shell uname | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

# Sync & verify source code repositories from config.yaml
.PHONY: sources
sources:
	@./hack/sync-sources.sh
	@./hack/verify-sources.sh

# Install required deps in ./bin directory
.PHONY: deps
deps:
	@./hack/deps.sh


