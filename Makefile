#
# Every command this project needs, in the order you need them.
#
# `make` on its own prints this list.
#
SHELL := /bin/bash
.DEFAULT_GOAL := help

ENV_DIR    ?= terraform/envs/dev
BOOTSTRAP  ?= terraform/bootstrap
TOOLS_DIR  := $(CURDIR)/.tools
export PATH := $(TOOLS_DIR):$(PATH)

TF := terraform -chdir=$(ENV_DIR)

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "  AWS EKS GitOps portfolio project"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  First time through, in order:"
	@echo "    make tools          install terraform, tflint, trivy, kubectl, helm, kubeconform into .tools/"
	@echo "    make validate       prove the repo is consistent, costs nothing"
	@echo "    make bootstrap      create the S3 state bucket"
	@echo "    make init           point this environment at that bucket"
	@echo "    make plan           see what would be created"
	@echo "    make apply          create it           <- the bill starts here"
	@echo "    make render         fill placeholders from the outputs, then commit and push"
	@echo "    make deploy         install Argo CD and hand over to git"
	@echo "    make destroy        take it all down    <- the bill stops here"
	@echo ""

# ---------------------------------------------------------------------------
# Tooling
# ---------------------------------------------------------------------------
.PHONY: tools
tools: ## Download pinned tool binaries into .tools/
	@./scripts/install-tools.sh

# ---------------------------------------------------------------------------
# Checks (no AWS account needed)
# ---------------------------------------------------------------------------
.PHONY: validate
validate: ## Run every offline check: terraform, manifests, helm values, container image
	@./scripts/validate.sh

.PHONY: validate-terraform validate-kubernetes validate-helm validate-docker
validate-terraform: ## Only the terraform checks
	@./scripts/validate.sh terraform
validate-kubernetes: ## Only the Kubernetes manifest checks
	@./scripts/validate.sh kubernetes
validate-helm: ## Only the Helm chart rendering checks
	@./scripts/validate.sh helm
validate-docker: ## Only the container image build and run checks
	@./scripts/validate.sh docker

.PHONY: fmt
fmt: ## Rewrite the terraform files into canonical format
	@terraform fmt -recursive

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------
.PHONY: bootstrap
bootstrap: ## Create the S3 state bucket (runs with local state, once per account)
	@terraform -chdir=$(BOOTSTRAP) init -input=false
	@terraform -chdir=$(BOOTSTRAP) apply
	@echo ""
	@echo "State bucket: $$(terraform -chdir=$(BOOTSTRAP) output -raw state_bucket_name)"
	@echo "Put that in $(ENV_DIR)/backend.hcl and in terraform.tfvars, then: make init"

.PHONY: init
init: ## terraform init against the remote backend (needs backend.hcl)
	@test -f $(ENV_DIR)/backend.hcl || { \
	  echo "Missing $(ENV_DIR)/backend.hcl."; \
	  echo "  cp $(ENV_DIR)/backend.hcl.example $(ENV_DIR)/backend.hcl"; \
	  echo "  then fill in the bucket from: terraform -chdir=$(BOOTSTRAP) output -raw state_bucket_name"; \
	  exit 1; }
	@$(TF) init -input=false -backend-config=backend.hcl

.PHONY: plan
plan: ## Show what would change
	@$(TF) plan -input=false

.PHONY: apply
apply: ## Create or update the infrastructure
	@$(TF) apply -input=false

.PHONY: output
output: ## Print the terraform outputs
	@$(TF) output

.PHONY: cost
cost: ## Print the rough monthly cost of what is currently deployed
	@$(TF) output -raw cost_note 2>/dev/null || echo "Nothing deployed."
	@echo ""

# ---------------------------------------------------------------------------
# Kubernetes
# ---------------------------------------------------------------------------
.PHONY: render
render: ## Substitute the manifest placeholders from the terraform outputs
	@./scripts/render-manifests.sh

.PHONY: deploy
deploy: ## Install Argo CD and point it at this repo
	@./scripts/deploy.sh

.PHONY: kubeconfig
kubeconfig: ## Point kubectl at the cluster
	@$$($(TF) output -raw update_kubeconfig_command)

.PHONY: status
status: ## One screen showing what the cluster is actually doing
	@echo "--- nodes ---";        kubectl get nodes -o wide 2>/dev/null || echo "not connected"
	@echo ""; echo "--- argocd applications ---"; kubectl -n argocd get applications 2>/dev/null || true
	@echo ""; echo "--- demo app ---";  kubectl -n demo get pods,svc,ingress,hpa 2>/dev/null || true
	@echo ""; echo "--- monitoring ---"; kubectl -n monitoring get pods,pvc 2>/dev/null || true

.PHONY: url
url: ## Print the demo app URL once the ALB is ready
	@addr=$$(kubectl -n demo get ingress demo-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
	if [ -n "$$addr" ]; then echo "http://$$addr"; \
	else echo "The Ingress has no address yet. An ALB takes 2 to 3 minutes; after that, check:"; \
	     echo "  kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50"; fi

.PHONY: grafana
grafana: ## Port-forward Grafana and print the generated password
	@echo "user: admin"
	@echo "pass: $$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
	@echo "open http://localhost:3000"
	@kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

.PHONY: argocd
argocd: ## Port-forward the Argo CD UI and print the generated password
	@echo "user: admin"
	@echo "pass: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	@echo "open https://localhost:8080  (self-signed certificate, that is expected)"
	@kubectl -n argocd port-forward svc/argocd-server 8080:443

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
.PHONY: destroy
destroy: ## Delete the load balancers first, then the infrastructure
	@./scripts/teardown.sh

.PHONY: clean
clean: ## Remove local caches: .terraform, .helm, rendered files
	@find . -type d -name '.terraform' -prune -exec rm -rf {} + 2>/dev/null || true
	@rm -rf .helm
	@echo "Removed .terraform directories and the helm cache. .tools/ kept; 'rm -rf .tools' to drop it too."
