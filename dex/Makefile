# Tool to build the container image. It can be either docker or podman
CONTAINER_RUNTIME ?= docker

IMAGE ?= registry.redhat.io/openshift-gitops-1/dex-rhel8:dev

build-plugin:
	$(CONTAINER_RUNTIME) build -t $(IMAGE) -f ./Containerfile .

# Update the dex submodule to a specific commit or tag
update-dex:
	@if [ -z "$(ref)" ]; then \
		echo "Usage: make update-dex ref=<commit-or-tag>"; \
		exit 1; \
	fi
	@if [ ! -d "./dex/.git" ]; then \
		echo "Error: 'dex' submodule is not initialized or not a valid submodule."; \
		echo "To initialize the submodule, run:"; \
		echo "    git submodule update --init --recursive"; \
		exit 1; \
	fi
	cd dex && \
	git fetch origin || { echo "Error: Failed to fetch updates for dex submodule"; exit 1; } && \
	git checkout $(ref) || { echo "Error: Failed to checkout $(ref) in dex submodule"; exit 1; } && \
	cd .. && \
	git add dex || { echo "Error: Failed to stage updated submodule"; exit 1; } && \
	echo "Successfully updated dex submodule to $(ref)"

# Generate rpms.lock.yaml file
# Use upstream container image for rpm-lockfile-prototype tool when available
# Ref: https://github.com/konflux-ci/rpm-lockfile-prototype/pull/34
generate-rpms-lock:
	$(CONTAINER_RUNTIME) run \
		-v $$PWD/deps/rpms:/tmp \
		-w /tmp \
		--rm -t \
		quay.io/svghadi/rpm-lockfile-prototype:latest \
		--image registry.access.redhat.com/ubi8/ubi-minimal \
		--arch x86_64 --arch aarch64 --arch ppc64le --arch s390x \
		rpms.in.yaml