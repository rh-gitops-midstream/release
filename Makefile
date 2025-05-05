.PHONY: images
BRANCH_NAME := $(shell git rev-parse --abbrev-ref HEAD)
image:
	BRANCH_NAME=$(BRANCH_NAME) ./hack/update-image-shas.sh

.PHONY: bundle

CSV_FILE := gitops-operator-bundle/bundle/manifests/gitops-operator.clusterserviceversion.yaml
CSV_PATCH := gitops-operator-bundle/patches/csv.yaml
IMAGES_PATCH := gitops-operator-bundle/patches/images.yaml
METADATA_FILE := gitops-operator-bundle/bundle/metadata/annotations.yaml
METADATA_PATCH := gitops-operator-bundle/patches/metadata.yaml

bundle:
	cp -rf gitops-operator-bundle/gitops-operator/bundle gitops-operator-bundle/
	@echo "Patching $(CSV_FILE)"
	yq ea '. as $$item ireduce ({}; . * $$item )' $(CSV_FILE) $(CSV_PATCH) -i
	yq ea '. as $$item ireduce ({}; . * $$item )' $(CSV_FILE) $(IMAGES_PATCH) -i
	@echo "✅ CSV Patch complete"
	@echo "Patching $(METADATA_FILE)"
	yq ea '. as $$item ireduce ({}; . * $$item )' $(METADATA_FILE) $(METADATA_PATCH) -i
	@echo "✅ Metadata Patch complete"