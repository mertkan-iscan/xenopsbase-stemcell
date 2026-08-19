.DEFAULT_GOAL := help
SHELL := /bin/bash

# Two root modules, deliberately separated by durability (ADR-0002).
#   storage/ - buckets holding everything durable. Applied rarely, destroyed never.
#   cluster/ - the K3s cluster. Built and destroyed as a routine operation.
# `make down` must never be able to reach storage/.
STORAGE_DIR := infra/terraform/storage
CLUSTER_DIR := infra/terraform/cluster
SCRIPTS     := infra/scripts

# State lives in Cloudflare R2, not Hetzner (ADR-0005). Set R2_ENDPOINT to
# https://<account_id>.r2.cloudflarestorage.com
BUCKET      ?= xenopsbase-tfstate
R2_ENDPOINT ?=
R2_REGION   ?= auto

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  First time through, in order:"
	@echo "    1. export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=..."
	@echo "    2. make bootstrap-state R2_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com"
	@echo "    3. cp $(STORAGE_DIR)/backend.hcl.example $(STORAGE_DIR)/backend.hcl   # edit"
	@echo "    4. cp $(STORAGE_DIR)/terraform.tfvars.example $(STORAGE_DIR)/terraform.tfvars   # edit"
	@echo "    5. make storage-init && make storage-adopt-state && make storage-apply"
	@echo "    5b. make storage-lifecycle"
	@echo "    6. make verify-locking      <- do not skip"
	@echo "    7. verify key IDs, set enable_bucket_policies = true, make storage-apply"

# ------------------------------------------------------------------------------
# Bootstrap
# ------------------------------------------------------------------------------

.PHONY: bootstrap-state
bootstrap-state: ## Create the Terraform state bucket in R2 (idempotent, runs before Terraform exists)
	@test -n "$(R2_ENDPOINT)" || { echo "error: set R2_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com"; exit 1; }
	@bash $(SCRIPTS)/bootstrap-state-bucket.sh $(BUCKET) $(R2_ENDPOINT) $(R2_REGION)

.PHONY: verify-locking
verify-locking: ## Prove state locking actually refuses a concurrent operation
	@bash $(SCRIPTS)/verify-state-locking.sh $(STORAGE_DIR)/backend.hcl

# ------------------------------------------------------------------------------
# Durable storage
# ------------------------------------------------------------------------------

.PHONY: storage-init
storage-init: ## terraform init for the storage module
	@cd $(STORAGE_DIR) && terraform init -input=false -backend-config=backend.hcl

.PHONY: storage-adopt-state
storage-adopt-state: ## Import the bootstrap-created state bucket into Terraform (run once)
	@cd $(STORAGE_DIR) && terraform import 'aws_s3_bucket.this["tfstate"]' $(BUCKET) || \
		echo "  already imported, nothing to do"

.PHONY: storage-lifecycle
storage-lifecycle: ## Apply and verify bucket lifecycle rules from infra/lifecycle/*.json
	@bash $(SCRIPTS)/apply-lifecycle-rules.sh

.PHONY: storage-plan
storage-plan: ## Plan changes to the durable buckets
	@cd $(STORAGE_DIR) && terraform plan -input=false

.PHONY: storage-apply
storage-apply: ## Apply changes to the durable buckets
	@cd $(STORAGE_DIR) && terraform apply -input=false

# Deliberately absent: storage-destroy.
# Every bucket carries prevent_destroy, and there is no convenience target for
# deleting the durable column of ADR-0002. Removing these buckets should require
# editing Terraform by hand and meaning it.

# ------------------------------------------------------------------------------
# Cluster (ephemeral)
# ------------------------------------------------------------------------------

.PHONY: snapshot
snapshot: ## Build the OS snapshot kube-hetzner provisions nodes from (once per project)
	@bash $(SCRIPTS)/build-snapshot.sh

.PHONY: cluster-init
cluster-init: ## terraform init for the cluster module
	@cd $(CLUSTER_DIR) && terraform init -input=false -backend-config=backend.hcl

.PHONY: cluster-plan
cluster-plan: ## Plan cluster changes
	@cd $(CLUSTER_DIR) && terraform plan -input=false

.PHONY: cluster-apply
cluster-apply: ## Build or update the cluster
	@cd $(CLUSTER_DIR) && terraform apply -input=false

.PHONY: cluster-destroy
cluster-destroy: ## Destroy the cluster. Does NOT touch the durable buckets or the OS snapshot
	@cd $(CLUSTER_DIR) && terraform destroy -input=false

.PHONY: kubeconfig
kubeconfig: ## Write the kubeconfig out of Terraform state (gitignored)
	@cd $(CLUSTER_DIR) && terraform output -raw kubeconfig > kubeconfig
	@echo "wrote $(CLUSTER_DIR)/kubeconfig"
	@echo "  export KUBECONFIG=\$$PWD/$(CLUSTER_DIR)/kubeconfig"

# ------------------------------------------------------------------------------
# Quality
# ------------------------------------------------------------------------------

.PHONY: fmt
fmt: ## Rewrite Terraform files into canonical format
	@terraform fmt -recursive infra/terraform

.PHONY: validate
validate: ## Validate every Terraform root module without touching remote state
	@set -e; for d in $(STORAGE_DIR) $(CLUSTER_DIR); do \
		echo "==> $$d"; \
		( cd $$d && terraform init -backend=false -input=false >/dev/null && terraform validate ); \
	done

# make up / make down arrive with T-1.7, and will drive $(CLUSTER_DIR) only.
