.PHONY: update-shas
BRANCH_NAME := $(shell git rev-parse --abbrev-ref HEAD)
update-shas:
	BRANCH_NAME=$(BRANCH_NAME) ./hack/update-image-shas.sh

.PHONY: bundle

CSV_FILE := gitops-operator-bundle/bundle/manifests/gitops-operator.clusterserviceversion.yaml
CSV_PATCH := gitops-operator-bundle/patches/csv.yaml
CSV_ENV_PATCH := gitops-operator-bundle/patches/csv-env.yaml
IMAGES_PATCH := gitops-operator-bundle/patches/images.yaml
METADATA_FILE := gitops-operator-bundle/bundle/metadata/annotations.yaml
METADATA_PATCH := gitops-operator-bundle/patches/metadata.yaml

bundle: 
	cp -rf gitops-operator-bundle/gitops-operator/bundle gitops-operator-bundle/
	@echo "Patching $(CSV_FILE)"
	yq ea '. as $$item ireduce ({}; . * $$item )' $(CSV_FILE) $(CSV_PATCH) -i
	yq eval-all '\
		select(fileIndex == 0) as $$csv | \
		select(fileIndex == 1) as $$newEnv | \
		$$csv | \
		(.spec.install.spec.deployments[].spec.template.spec.containers[] | select(.name == "manager")).env = $$newEnv.env' \
		$(CSV_FILE) $(CSV_ENV_PATCH) -i
	@echo "✅ CSV Patch complete"
	@echo "Patching $(METADATA_FILE)"
	yq ea '. as $$item ireduce ({}; . * $$item )' $(METADATA_FILE) $(METADATA_PATCH) -i
	@echo "✅ Metadata Patch complete"

PHONY: trigger-builds
trigger-builds: 
	kubectl annotate components/argo-cd-1-16 build.appstudio.openshift.io/request=trigger-pac-build
	kubectl annotate components/argo-rollouts-1-16 build.appstudio.openshift.io/request=trigger-pac-build
	kubectl annotate components/dex-1-16 build.appstudio.openshift.io/request=trigger-pac-build
	kubectl annotate components/gitops-backend-1-16 build.appstudio.openshift.io/request=trigger-pac-build
	kubectl annotate components/gitops-console-plugin-1-16 build.appstudio.openshift.io/request=trigger-pac-build
	kubectl annotate components/gitops-must-gather-1-16 build.appstudio.openshift.io/request=trigger-pac-build
	kubectl annotate components/gitops-operator-1-16 build.appstudio.openshift.io/request=trigger-pac-build