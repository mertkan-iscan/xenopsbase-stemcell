.DEFAULT_GOAL := help
SHELL := /bin/bash

# Two root modules, deliberately separated by durability (ADR-0002).
#   storage/ - buckets holding everything durable. Applied rarely, destroyed never.
#   cluster/ - the K3s cluster. Built and destroyed as a routine operation.
# A cluster destroy must never be able to reach storage/.
STORAGE_DIR := infra/terraform/storage
EDGE_DIR    := infra/terraform/edge
MAIL_DIR    := infra/terraform/mail-dns
CLUSTER_DIR := infra/terraform/cluster
SCRIPTS     := infra/scripts

# Git for Windows sets core.autocrlf=true at SYSTEM level. Terraform fetches
# registry modules with `git clone`, so that setting rewrites every module file
# to CRLF, including the shell heredocs kube-hetzner uploads to nodes. Those
# then fail on Linux with a carriage-return syntax error.
#
# Scoped to the terraform invocation rather than changing the user's global git
# config, which would affect every other repository on the machine to fix a
# problem in one. Harmless on Linux and macOS, where autocrlf is already off.
TF_GIT := GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false

# Terraform state lives in Cloudflare R2, not Hetzner (ADR-0005).
BUCKET      ?= xenopsbase-tfstate
R2_ENDPOINT ?=
R2_REGION   ?= auto

# Every environment-scoped target takes ENV (T-1.4).
#
# State keys are DERIVED from ENV rather than written into backend.hcl, and
# every init passes -reconfigure. That is the safety property: the backend is
# re-pointed by the same command that selects the var file, so ENV=prod vars
# cannot be applied onto dev state. That mismatch is the classic failure of this
# layout, and it is silent.
ENV         ?= dev

# Apply and destroy prompt for confirmation by default, which is correct for a
# human at a terminal and essential for prod. Automation passes AUTO=1.
#
# Note -input=false must NOT be combined with an interactive approval: it
# disables the prompt rather than answering it, so the command fails with "error
# asking for approval: EOF" instead of asking. It is used on plan and init only.
AUTO        ?= 0

# Pass EXPECT_WEB=expect-web to verify-exposure once an ingress controller
# exists (T-2.2), to require 80/443 to answer rather than merely tolerate them.
EXPECT_WEB  ?=
ifeq ($(AUTO),1)
APPROVE := -auto-approve -input=false
else
APPROVE :=
endif
TFVARS       = env/$(ENV).tfvars
SECRETS      = env/$(ENV).secrets.tfvars
STORAGE_KEY  = storage/$(ENV)/terraform.tfstate
CLUSTER_KEY  = $(ENV)/cluster.tfstate
EDGE_KEY     = edge/$(ENV)/terraform.tfstate

# Not derived from ENV: there is one mail zone, not one per environment.
MAIL_KEY     = mail-dns/terraform.tfstate

# Fails loudly if the environment does not exist, or if its tfvars disagrees
# with ENV. Without the second check, a copy-paste while adding an environment
# applies the wrong sizing under the right name.
define check_env
	$(call check_creds)
	@test -f $(1)/$(TFVARS) || { \
		echo "error: no such environment '$(ENV)' - $(1)/$(TFVARS) is missing"; \
		echo -n "       available: "; \
		ls $(1)/env/*.tfvars 2>/dev/null | xargs -n1 basename | sed 's/\.tfvars$$//' | grep -v secrets | tr '\n' ' '; \
		echo; exit 1; }
	@grep -qE '^environment[[:space:]]*=[[:space:]]*"$(ENV)"' $(1)/$(TFVARS) || { \
		echo "error: $(1)/$(TFVARS) does not declare environment = \"$(ENV)\""; \
		echo "       refusing to apply one environment's settings under another's name"; \
		exit 1; }
endef

# Verifies the token can actually REACH every API a module will use, before
# Terraform starts changing anything. check_creds catches a missing or swapped
# credential; this catches one whose SCOPE is too narrow -- which has stopped
# four applies in this project, always mid-flight and always as a generic
# "Authentication error" with no indication of the missing permission.
define preflight
	@bash $(SCRIPTS)/preflight.sh $(1) $(ENV)
endef

# Credentials must come from the environment, never from ~/.aws/credentials.
#
# The AWS SDK falls back to that file when the env vars are unset, so forgetting
# to `source ~/.xenopsbase.env` does not fail — it silently operates with
# whatever account another project left there. The specific mistake this catches
# is a Hetzner key (20 chars) sitting in the R2 slot, which produces
# "Credential access key has length 20, should be 32" from somewhere deep in a
# backend operation rather than at the point of the mistake.
define check_creds
	@test -n "$$AWS_ACCESS_KEY_ID" || { \
		echo "error: AWS_ACCESS_KEY_ID is not set."; \
		echo "       run: source ~/.xenopsbase.env"; \
		echo "       without it Terraform silently falls back to ~/.aws/credentials,"; \
		echo "       which belongs to a different account entirely."; \
		exit 1; }
	@test $${#AWS_ACCESS_KEY_ID} -ne 20 || { \
		echo "error: AWS_ACCESS_KEY_ID looks like a Hetzner key (20 chars)."; \
		echo "       these names belong to R2 (Terraform state, 32 chars) - ADR-0005."; \
		echo "       Hetzner's go in TF_VAR_hetzner_s3_access_key / _secret_key."; \
		exit 1; }
endef

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Every environment target takes ENV (default: $(ENV))"
	@echo "    make cluster-apply ENV=staging"
	@echo
	@echo "  First time in a new project:"
	@echo "    1. source ~/.xenopsbase.env"
	@echo "    2. make bootstrap-state R2_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com"
	@echo "    3. cp $(STORAGE_DIR)/backend.hcl.example $(STORAGE_DIR)/backend.hcl   # edit"
	@echo "    4. cp $(STORAGE_DIR)/env/secrets.tfvars.example $(STORAGE_DIR)/env/$(ENV).secrets.tfvars   # edit"
	@echo "    5. make verify-locking      <- do not skip"
	@echo "    6. make storage-init storage-apply storage-lifecycle"
	@echo "    7. make snapshot            <- once per Hetzner project"
	@echo "    8. make cluster-init cluster-apply kubeconfig"

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
# Durable storage (per environment)
# ------------------------------------------------------------------------------

.PHONY: storage-init
storage-init: ## terraform init for the storage module
	$(call check_env,$(STORAGE_DIR))
	@cd $(STORAGE_DIR) && $(TF_GIT) terraform init -input=false -reconfigure -backend-config=backend.hcl -backend-config="key=$(STORAGE_KEY)"

.PHONY: storage-plan
storage-plan: ## Plan changes to the durable buckets
	$(call check_env,$(STORAGE_DIR))
	@cd $(STORAGE_DIR) && terraform plan -input=false -var-file=$(TFVARS) $$(test -f $(SECRETS) && echo -var-file=$(SECRETS))

.PHONY: storage-apply
storage-apply: ## Apply changes to the durable buckets
	$(call check_env,$(STORAGE_DIR))
	@cd $(STORAGE_DIR) && terraform apply $(APPROVE) -var-file=$(TFVARS) $$(test -f $(SECRETS) && echo -var-file=$(SECRETS))

.PHONY: storage-lifecycle
storage-lifecycle: ## Apply and verify bucket lifecycle rules from infra/lifecycle/*.json
	@bash $(SCRIPTS)/apply-lifecycle-rules.sh $(ENV)

# Deliberately absent: storage-destroy.
# Every bucket carries prevent_destroy, and there is no convenience target for
# deleting the durable column of ADR-0002. Removing these buckets should require
# editing Terraform by hand and meaning it.

# ------------------------------------------------------------------------------
# Edge — Cloudflare DNS and tunnel (durable, per environment)
#
# Survives every cluster rebuild: the DNS record points at a tunnel UUID, not at
# an IP, so there is nothing to update when the cluster is replaced.
# ------------------------------------------------------------------------------

.PHONY: edge-init
edge-init: ## terraform init for the Cloudflare edge module
	$(call check_env,$(EDGE_DIR))
	@cd $(EDGE_DIR) && $(TF_GIT) terraform init -input=false -reconfigure -backend-config=backend.hcl -backend-config="key=$(EDGE_KEY)"

.PHONY: edge-plan
edge-plan: ## Plan Cloudflare DNS, tunnel and optional zone settings
	$(call check_env,$(EDGE_DIR))
	$(call preflight,edge)
	@cd $(EDGE_DIR) && terraform plan -input=false -var-file=$(TFVARS) $$(test -f $(SECRETS) && echo -var-file=$(SECRETS))

.PHONY: edge-apply
edge-apply: ## Apply Cloudflare edge configuration
	$(call check_env,$(EDGE_DIR))
	$(call preflight,edge)
	@cd $(EDGE_DIR) && terraform apply $(APPROVE) -var-file=$(TFVARS) $$(test -f $(SECRETS) && echo -var-file=$(SECRETS))

# ------------------------------------------------------------------------------
# Mail DNS — deliverability records (durable, NOT per environment)
#
# One zone, one state file. Alert delivery fails silently without these: Brevo
# returns "250 OK: queued" and discards the message, and Alertmanager logs
# "Notify success" either way.
#
# Needs TF_VAR_cloudflare_api_token scoped to Zone / DNS / Edit on the mail zone.
# That is a DIFFERENT token from the edge one, on a different account.
# ------------------------------------------------------------------------------

MAIL_VARS = -var-file=mail.tfvars $$(test -f mail.secrets.tfvars && echo -var-file=mail.secrets.tfvars)

.PHONY: mail-dns-init
mail-dns-init: ## terraform init for the mail DNS module
	@cd $(MAIL_DIR) && $(TF_GIT) terraform init -input=false -reconfigure -backend-config=backend.hcl -backend-config="key=$(MAIL_KEY)"

.PHONY: mail-dns-plan
mail-dns-plan: ## Plan the mail deliverability records
	$(call preflight,mail-dns)
	@cd $(MAIL_DIR) && terraform plan -input=false $(MAIL_VARS)

.PHONY: mail-dns-apply
mail-dns-apply: ## Apply the mail deliverability records
	$(call preflight,mail-dns)
	@cd $(MAIL_DIR) && terraform apply $(APPROVE) $(MAIL_VARS)

.PHONY: mail-dns-verify
mail-dns-verify: ## Resolve every mail record and report what is actually published
	@bash $(SCRIPTS)/verify-mail-dns.sh $(MAIL_DIR)

# Deliberately absent: mail-dns-destroy. Destroying this module takes the
# personal site at the apex down with it, and nothing in the monitoring would
# notice. The apex record carries prevent_destroy for the same reason.

# ------------------------------------------------------------------------------
# Cluster (ephemeral, per environment)
# ------------------------------------------------------------------------------

.PHONY: snapshot
snapshot: ## Build the OS snapshot kube-hetzner provisions nodes from (once per project)
	@bash $(SCRIPTS)/build-snapshot.sh

.PHONY: cluster-init
cluster-init: ## terraform init for the cluster module
	$(call check_env,$(CLUSTER_DIR))
	@cd $(CLUSTER_DIR) && $(TF_GIT) terraform init -input=false -reconfigure -backend-config=backend.hcl -backend-config="key=$(CLUSTER_KEY)"

.PHONY: cluster-plan
cluster-plan: ## Plan cluster changes
	$(call check_env,$(CLUSTER_DIR))
	$(call preflight,cluster)
	@cd $(CLUSTER_DIR) && terraform plan -input=false -var-file=$(TFVARS)

.PHONY: cluster-apply
cluster-apply: ## Build or update the cluster
	$(call check_env,$(CLUSTER_DIR))
	$(call preflight,cluster)
	@cd $(CLUSTER_DIR) && terraform apply $(APPROVE) -var-file=$(TFVARS)

.PHONY: cluster-destroy
cluster-destroy: ## Destroy the cluster. Does NOT touch the durable buckets or the OS snapshot
	$(call check_env,$(CLUSTER_DIR))
	@# PVC-backed volumes are created by the CSI driver, not by Terraform, so
	@# `terraform destroy` neither tracks nor removes them. It reports success and
	@# leaves them billing forever. The CSI driver runs INSIDE the cluster, so this
	@# has to happen while the nodes are still alive -- afterwards there is nothing
	@# left to do it. Set KEEP_VOLUMES=1 to skip.
	@bash $(SCRIPTS)/release-cluster-volumes.sh $(ENV)
	@cd $(CLUSTER_DIR) && terraform destroy $(APPROVE) -var-file=$(TFVARS)
	@# Assert the boundary held rather than trusting it. A leak here is invisible
	@# and permanent, so it fails the target instead of waiting to be noticed.
	@bash $(SCRIPTS)/verify-teardown.sh $(ENV)

.PHONY: verify-teardown
verify-teardown: ## Assert a destroy left durable state intact and nothing orphaned
	@bash $(SCRIPTS)/verify-teardown.sh $(ENV)

.PHONY: verify-exposure
verify-exposure: ## Probe every public address and assert only intended ports answer
	@bash $(SCRIPTS)/verify-exposure.sh $(EXPECT_WEB)

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

.PHONY: check-secrets
check-secrets: ## Refuse unencrypted secrets anywhere in the repository
	@bash $(SCRIPTS)/check-secrets.sh

.PHONY: validate
validate: ## Validate every Terraform root module without touching remote state
	@set -e; for d in $(STORAGE_DIR) $(EDGE_DIR) $(CLUSTER_DIR); do \
		echo "==> $$d"; \
		( cd $$d && { test -d .terraform/providers || $(TF_GIT) terraform init -backend=false -input=false >/dev/null; } && terraform validate ); \
	done

# make up / make down arrive with T-1.7, and will drive $(CLUSTER_DIR) only.
