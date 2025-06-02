.PHONY: bundle
bundle: 
	cp -rf sources/gitops-operator/bundle gitops-operator-bundle/
	python3 gitops-operator-bundle/patch-bundle.py

PHONY: trigger-builds
trigger-builds: 
	kubectl annotate components/argo-cd-1-16 build.appstudio.openshift.io/request=trigger-pac-build
	kubectl annotate components/argo-rollouts-1-16 build.appstudio.openshift.io/request=trigger-pac-build
	kubectl annotate components/dex-1-16 build.appstudio.openshift.io/request=trigger-pac-build
	kubectl annotate components/gitops-backend-1-16 build.appstudio.openshift.io/request=trigger-pac-build
	kubectl annotate components/gitops-console-plugin-1-16 build.appstudio.openshift.io/request=trigger-pac-build
	kubectl annotate components/gitops-must-gather-1-16 build.appstudio.openshift.io/request=trigger-pac-build
	kubectl annotate components/gitops-operator-1-16 build.appstudio.openshift.io/request=trigger-pac-build

.PHONY: deps
deps:
	pip install -r requirements.txt