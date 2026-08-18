.DEFAULT_GOAL := help
SHELL := /bin/bash

TF_DIR     := infra/terraform
SCRIPTS    := infra/scripts
BACKEND    := $(TF_DIR)/backend.hcl
BUCKET     ?= xenopsbase-tfstate
REGION     ?= fsn1

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  First time through, in order:"
	@echo "    1. export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=..."
	@echo "    2. make bootstrap-state BUCKET=$(BUCKET) REGION=$(REGION)"
	@echo "    3. cp $(TF_DIR)/backend.hcl.example $(BACKEND) and edit it"
	@echo "    4. make init"
	@echo "    5. make verify-locking      <- do not skip this one"

.PHONY: bootstrap-state
bootstrap-state: ## Create the Terraform state bucket (idempotent)
	@bash $(SCRIPTS)/bootstrap-state-bucket.sh $(BUCKET) $(REGION)

.PHONY: init
init: $(BACKEND) ## terraform init against the remote backend
	@cd $(TF_DIR) && terraform init -input=false -backend-config=backend.hcl

.PHONY: verify-locking
verify-locking: $(BACKEND) ## Prove state locking actually refuses a concurrent operation
	@bash $(SCRIPTS)/verify-state-locking.sh $(BACKEND)

.PHONY: fmt
fmt: ## Rewrite Terraform files into canonical format
	@terraform fmt -recursive $(TF_DIR)

.PHONY: validate
validate: ## Validate the Terraform configuration
	@cd $(TF_DIR) && terraform validate

$(BACKEND):
	@echo "error: $(BACKEND) is missing." >&2
	@echo "  cp $(TF_DIR)/backend.hcl.example $(BACKEND) and fill it in." >&2
	@exit 1

# make up / make down arrive with T-1.7, once there is a cluster to build.
