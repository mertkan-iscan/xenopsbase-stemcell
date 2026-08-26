.DEFAULT_GOAL := help
SHELL := /bin/bash

# WHY THE SHELL IS RE-RESOLVED ON WINDOWS
#
# Every recipe in this file is POSIX shell — 47 of them use $$(...), `for`,
# `if [`, or `&&`. `SHELL := /bin/bash` above is correct and, on Windows,
# ineffective: /bin/bash is not a path the OS can resolve, so GNU Make silently
# falls back to cmd.exe and the first recipe line fails with
#
#     The system cannot find the file $(date.
#
# which names neither make, nor the shell, nor the real problem. `make down`
# is documented in the runbooks as the way to stop paying for a cluster, so it
# failing in the shell people actually have open is not a papercut.
#
# NOT plain `bash.exe`. On a default Windows install that resolves to
# C:\Windows\System32ash.exe, which is WSL — a different filesystem, with a
# different terraform, hcloud and gh than the ones this repository is
# configured against. That is a worse failure than cmd.exe, because it would
# sometimes appear to work.
#
# If Git Bash is not found, SHELL is left as-is: running make FROM Git Bash
# already works, and guessing further would be less predictable than the
# documented fallback.
ifeq ($(OS),Windows_NT)
  GIT_BASH := $(firstword $(wildcard C:/PROGRA~1/Git/bin/bash.exe C:/PROGRA~2/Git/bin/bash.exe))
  ifneq ($(GIT_BASH),)
    SHELL := $(GIT_BASH)
  endif
endif

# Two root modules, deliberately separated by durability (ADR-0002).
#   storage/ - buckets holding everything durable. Applied rarely, destroyed never.
#   cluster/ - the K3s cluster. Built and destroyed as a routine operation.
# A cluster destroy must never be able to reach storage/.
STORAGE_DIR := infra/terraform/storage
EDGE_DIR    := infra/terraform/edge
MAIL_DIR    := infra/terraform/mail-dns
CLUSTER_DIR := infra/terraform/cluster
SCRIPTS     := infra/scripts

# python3 on Linux and macOS, python on Windows.
#
# Resolved by RUNNING each candidate, not by `command -v`. Windows ships a
# `python3` App Execution Alias that exists on PATH, satisfies `command -v`,
# and then exits 49 printing an advert for the Microsoft Store. Testing for
# presence finds it; testing that it executes does not.
PYTHON      := $(shell python3 -c '' >/dev/null 2>&1 && echo python3 || { python -c '' >/dev/null 2>&1 && echo python; })

# Git for Windows sets core.autocrlf=true at SYSTEM level. Terraform fetches
# registry modules with `git clone`, so that setting rewrites every module file
# to CRLF, including the shell heredocs kube-hetzner uploads to nodes. Those
# then fail on Linux with a carriage-return syntax error.
#
# Scoped to the terraform invocation rather than changing the user's global git
# config, which would affect every other repository on the machine to fix a
# problem in one. Harmless on Linux and macOS, where autocrlf is already off.
TF_GIT := GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false

# Selects a JDK the build can actually use, for the same reason and in the same
# way TF_GIT scopes a git setting: JAVA_HOME is global and other projects on the
# machine depend on it, so this repository fixes its own invocation rather than
# rewriting the developer's environment.
#
# The failure without it is not obvious. A machine can have several JDKs and none
# of them selected -- this one had Java 8 first on PATH, JAVA_HOME on 21, and the
# 25 the build needs installed but unreferenced -- and the compiler reports only:
#
#   error: release version 25 not supported
#
# naming neither the JDK it used nor the correct one sitting on the same disk.
#
# Invoked as `JH="$(bash .../java-home.sh)" && ... JAVA_HOME="$JH" ./mvnw`,
# deliberately, rather than as a reusable prefix macro. A prefix of the form
# JAVA_HOME="$(bash ...)" cannot fail the target: when the script exits non-zero
# the substitution yields an EMPTY string, JAVA_HOME is set to nothing, and the
# wrapper falls back to whatever `java` is first on PATH -- which on the machine
# this was written on is a Java 8 JRE. The `&&` is what turns a missing JDK into
# a stopped build with the script's diagnostic, instead of the compiler message
# above arriving from an even older JDK than the one that caused it.

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

# How long `make up` waits for the stack to become SERVING, not merely applied.
# Generous: a cold build provisions three nodes, converges thirteen Argo
# applications and recovers Postgres from object storage.
UP_TIMEOUT  ?= 1200
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

# ------------------------------------------------------------------------------
# Local inner loop (T-4.1)
#
# Everything a developer needs, with no Hetzner resources and no credentials.
# Docker is the only prerequisite; the JDK is found by java-home.sh.
#
# The DEPENDENCIES run in containers and the SERVICES run from Maven. That split
# is the whole point: spring-boot-devtools restarts a changed class in seconds,
# and a container rebuild does not.
# ------------------------------------------------------------------------------

DEV_DIR      := infra/dev
DEV_COMPOSE  := docker compose -f $(DEV_DIR)/compose.yml
DEV_LOGS     := $(DEV_DIR)/.logs

# Points every service at localhost instead of the cluster. AWS_* is set
# explicitly rather than inherited: a developer who has run `source
# ~/.xenopsbase.env` has R2 credentials in those names, and MinIO would reject
# them with a signature error that names neither MinIO nor R2.
DEV_ENV = 	OIDC_ISSUER_URI=http://localhost:9080/realms/xenopsbase 	OIDC_CLIENT_SECRET=local-dev-gateway-secret 	CORE_URI=http://localhost:8081	VALKEY_HOST=localhost 	VALKEY_PASSWORD=localdev 	DOCUMENTS_ENDPOINT=http://localhost:9000 	DOCUMENTS_BUCKET=xenopsbase-dev-documents 	AWS_ACCESS_KEY_ID=localdevkey 	AWS_SECRET_ACCESS_KEY=localdevsecret 	AWS_REGION=us-east-1

.PHONY: dev-realm
dev-realm: ## Render the local Keycloak realm from the one the cluster uses
	@bash $(SCRIPTS)/dev-realm.sh

.PHONY: dev-up
dev-up: ## Everything: dependencies in containers, both services from Maven
	@bash $(SCRIPTS)/dev-up.sh

.PHONY: dev-down
dev-down: ## Stop the services and remove the containers and their volumes
	@bash $(SCRIPTS)/dev-down.sh

.PHONY: dev-logs
dev-logs: ## Follow both service logs
	@tail -f $(DEV_LOGS)/gateway.log $(DEV_LOGS)/core.log

.PHONY: dev-deps
dev-deps: dev-realm ## Dependencies only, for running the services from an IDE
	@# Two calls, deliberately. `--wait` treats the one-shot bucket creator's
	@# clean exit(0) as a failed service, so the wait names only the four
	@# long-running dependencies while the first call still runs the one-shot.
	@$(DEV_COMPOSE) up -d
	@$(DEV_COMPOSE) up -d --wait postgres keycloak minio valkey
	@echo
	@echo "Dependencies are up. To run the services from an IDE, set:"
	@for v in $(DEV_ENV); do echo "    $$v"; done

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
# API contract (T-3.11)
#
# The spec is GENERATED from the running services, never hand-edited. Editing
# docs/api/*.json directly makes it disagree with what the services serve, and CI
# fails the next build rather than the discrepancy being noticed by a consumer.
# ------------------------------------------------------------------------------

.PHONY: java-home
java-home: ## Report which JDK the build will use, and why
	@echo "required:  Java $$(grep -oE '<java\.version>[0-9]+' services/core/pom.xml | head -1 | grep -oE '[0-9]+')  (services/*/pom.xml)"
	@echo "JAVA_HOME: $${JAVA_HOME:-<unset>}"
	@printf "selected:  "; bash $(SCRIPTS)/java-home.sh

.PHONY: golden-image
golden-image: ## Build, boot-test and publish the image agents and autoscaled nodes boot (T-1.18, T-1.20)
	@bash $(SCRIPTS)/build-golden-image.sh

.PHONY: validate-golden-image
validate-golden-image: ## Boot a candidate image and promote it only if it passes (T-1.20)
	@bash $(SCRIPTS)/validate-golden-image.sh $(SNAPSHOT)

.PHONY: user-data-size
user-data-size: ## Assert the node bootstrap still fits in Hetzner user_data (T-1.19)
	@bash $(SCRIPTS)/check-user-data-size.sh $(ENV)

.PHONY: node-equivalence
node-equivalence: ## Prove a static node and an autoscaled node are the same node (T-1.19)
	@# REPORTS SKIPPED IN THE NORMAL CASE, and that is the problem with it.
	@# It needs one static node AND one autoscaled node; min_nodes = 0, so a
	@# healthy dev cluster has none of the latter. It has never compared
	@# anything except when someone forced a scale-up by hand. Since T-1.23
	@# both node classes are built the same way anyway, so what it was
	@# guarding is now structural. Rewrite or retire: T-1.27 (#288).
	@bash $(SCRIPTS)/check-node-equivalence.sh $(ENV)

.PHONY: verify-node-provenance
verify-node-provenance: ## Did each node boot its image, or build itself? Asks the node, not the cluster (T-1.27)
	@# Deliberately does not use kubectl. The node worth checking is the one
	@# that failed to join, and no in-cluster tool can reach it -- which is why
	@# two T-1.23 builds ended without an answer.
	@bash $(SCRIPTS)/verify-node-provenance.sh $(ENV)

.PHONY: api-spec
api-spec: ## Regenerate docs/api/*.json from the services
	@JH="$$(bash $(SCRIPTS)/java-home.sh)" && cd services/core && JAVA_HOME="$$JH" ./mvnw --batch-mode verify -DskipITs=false -Dit.test=OpenApiSpecIT -DfailIfNoTests=false -Dtest=SchemaOwnershipTest
	@JH="$$(bash $(SCRIPTS)/java-home.sh)" && cd services/gateway && JAVA_HOME="$$JH" ./mvnw --batch-mode verify -DskipITs=false -Dit.test=OpenApiSpecIT -DfailIfNoTests=false -Dtest=SecurityUtilsUnitTest
	@mkdir -p docs/api
	@cp services/core/target/openapi/core.json docs/api/core.json
	@cp services/gateway/target/openapi/gateway.json docs/api/gateway.json
	@echo "docs/api updated. Commit the diff -- an API change should be visible in review."

.PHONY: api-spec-check
api-spec-check: ## Fail if docs/api/*.json no longer describes what the services serve
	@set -e; for m in core gateway; do 		bash $(SCRIPTS)/check-api-drift.sh "services/$$m/target/openapi/$$m.json" "docs/api/$$m.json"; 	done

.PHONY: api-compat
api-compat: ## Classify this branch's API changes against main as breaking or not
	@set -e; 	base=$$(git merge-base HEAD origin/main 2>/dev/null || git rev-parse origin/main); 	for m in core gateway; do 		echo "==> $$m"; 		if git cat-file -e "$$base:docs/api/$$m.json" 2>/dev/null; then 			git show "$$base:docs/api/$$m.json" > "$${TMPDIR:-/tmp}/$$m-base.json"; 			$(PYTHON) $(SCRIPTS)/check-api-breaking.py "$${TMPDIR:-/tmp}/$$m-base.json" "docs/api/$$m.json"; 		else 			echo "  no docs/api/$$m.json on the base — nothing to compare"; 		fi; 	done

.PHONY: api-client
api-client: ## Generate the typed Java client from the committed spec and compile it
	@JH="$$(bash $(SCRIPTS)/java-home.sh)" && cd clients/java && JAVA_HOME="$$JH" mvn --batch-mode clean compile
	@echo "client compiled from docs/api/core.json"

# ------------------------------------------------------------------------------
# Cluster (ephemeral, per environment)
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# One-command lifecycle (T-1.7)
#
# The near-zero-when-idle promise in ADR-0002 only holds if tearing down and
# rebuilding are each one command. Anything longer is a thing people stop doing,
# and a cluster nobody destroys is a cluster that bills all month.
# ------------------------------------------------------------------------------

.PHONY: up
up: ## Nothing to a serving stack, one command (T-1.7)
	@start=$$(date +%s); \
	set -e; \
	$(MAKE) --no-print-directory cluster-init ENV=$(ENV); \
	attempt=1; \
	until $(MAKE) --no-print-directory cluster-apply ENV=$(ENV) AUTO=1; do \
	  if [ $$attempt -ge 3 ]; then \
	    echo ""; \
	    echo "cluster-apply failed $$attempt times. Not a transient fault; read the error above."; \
	    exit 1; \
	  fi; \
	  echo ""; \
	  echo "cluster-apply failed (attempt $$attempt). Retrying."; \
	  echo "  A build reaches Hetzner, Tailscale and (for the control plane,"; \
	  echo "  which kube-hetzner still provisions) the k3s installer. All three"; \
	  echo "  have returned 5xx mid-build. Terraform apply is idempotent, so a"; \
	  echo "  retry continues rather than restarting. A REAL error fails again"; \
	  echo "  the same way and stops after three."; \
	  attempt=$$((attempt + 1)); \
	  sleep 20; \
	done; \
	$(MAKE) --no-print-directory kubeconfig ENV=$(ENV); \
	bash $(SCRIPTS)/wait-for-stack.sh $(ENV) $(UP_TIMEOUT); \
	echo ""; \
	echo "make up ENV=$(ENV) completed in $$(( $$(date +%s) - start ))s"

.PHONY: down
down: ## Destroy every billable resource, one command, and prove it
	@start=$$(date +%s); \
	set -e; \
	$(MAKE) --no-print-directory cluster-destroy ENV=$(ENV) AUTO=1; \
	echo ""; \
	echo "make down ENV=$(ENV) completed in $$(( $$(date +%s) - start ))s"
.PHONY: snapshot
snapshot: ## Build the base OS snapshot the control plane boots (once per project)
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
	@# The pre-destroy question is "is the data recoverable", and until now
	@# nothing could answer it. The Cluster's LastBackupSucceeded condition reads
	@# True whether the last backup was an hour ago or never happened, and
	@# status.lastSuccessfulBackup does not exist at all under the plugin backup
	@# method (#145). So this reads the BUCKET, which is the fact rather than a
	@# claim about it.
	@#
	@# SKIP_BACKUP_CHECK=1 to destroy anyway -- a cluster whose backups are
	@# broken is exactly one you may still need to tear down.
	@test "$(SKIP_BACKUP_CHECK)" = "1" || bash $(SCRIPTS)/verify-backup.sh $(ENV)
	@# Force the current WAL segment into the archive while the database is
	@# still running (T-7.2). archive_timeout is 300s, so a transaction
	@# committed inside that window is durable in Postgres and absent from the
	@# archive -- and a destroy loses it. Measured: a document created 19
	@# seconds after a segment shipped did not survive the rebuild, because the
	@# next segment was due five minutes later and the cluster was gone by
	@# then. The 301s RPO in the DR runbook is the number for a DISASTER; this
	@# is a planned teardown, and losing five minutes to one is avoidable.
	@bash $(SCRIPTS)/flush-wal.sh $(ENV)
	@# PVC-backed volumes are created by the CSI driver, not by Terraform, so
	@# `terraform destroy` neither tracks nor removes them. It reports success and
	@# leaves them billing forever. The CSI driver runs INSIDE the cluster, so this
	@# has to happen while the nodes are still alive -- afterwards there is nothing
	@# left to do it. Set KEEP_VOLUMES=1 to skip.
	@bash $(SCRIPTS)/release-cluster-volumes.sh $(ENV)
	@# The autoscaler's nodes are not terraform's, so `terraform destroy` leaves
	@# them -- and they hold the private network, so the SUBNET will not delete
	@# and the destroy hangs rather than fails (#294):
	@#
	@#   hcloud_network_subnet.control_plane[0]: Still destroying... [08m50s elapsed]
	@#
	@# Same gap as #159 one level up: the teardown reaps volumes it did not
	@# create and did not reap servers it did not create. Before the destroy,
	@# because after it there is no cluster left to stop the autoscaler with.
	@bash $(SCRIPTS)/reap-autoscaled-nodes.sh $(ENV)
	@cd $(CLUSTER_DIR) && terraform destroy $(APPROVE) -var-file=$(TFVARS)
	@# Reap what the in-cluster release could not (#159). The CSI driver has a
	@# 300s budget and the Prometheus volume routinely outlives it, so destroy
	@# succeeds and leaves a volume Terraform no longer tracks. Until this step
	@# existed, `make down` exited non-zero and a human ran two hcloud commands
	@# -- fine when someone is watching, and fatal to T-7.2's claim that a cold
	@# rebuild is fully automated. The drill stopped dead on exactly this.
	@bash $(SCRIPTS)/reap-orphaned-volumes.sh $(ENV)
	@# Assert the boundary held rather than trusting it. A leak here is invisible
	@# and permanent, so it fails the target instead of waiting to be noticed.
	@# Still the gate: the sweep above deletes only detached, PVC-named volumes,
	@# so anything else it left alone still fails here.
	@bash $(SCRIPTS)/verify-teardown.sh $(ENV)

.PHONY: backup-status
backup-status: ## Is the database actually recoverable? Reads the bucket, not the Cluster status
	@bash $(SCRIPTS)/verify-backup.sh $(ENV)

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

.PHONY: promote
promote: ## Move a build between environments: make promote SERVICE=all FROM=dev TO=staging
	@bash $(SCRIPTS)/promote.sh "$(or $(SERVICE),all)" "$(or $(FROM),dev)" "$(or $(TO),staging)"

.PHONY: hpa-local
hpa-local: ## Rehearse the gateway HPA on a throwaway local k3s cluster (T-2.8)
	@bash $(SCRIPTS)/hpa-local.sh

.PHONY: load
load: ## Load baseline: k6 in-cluster against the gateway, thresholds are the SLOs (T-5.6)
	@bash $(SCRIPTS)/load-test.sh "$(ENV)"

.PHONY: cold-rebuild
cold-rebuild: ## THE DRILL: destroy, rebuild, and prove a document survived it (T-7.2)
	@bash $(SCRIPTS)/cold-rebuild.sh "$(ENV)"

.PHONY: smoke
smoke: ## Does the DEPLOYED environment actually work? Login, an API call, upload and download
	@bash $(SCRIPTS)/smoke.sh "$(ENV)"

.PHONY: rollback
rollback: ## Back to the digest this environment ran before: make rollback ENV=dev SERVICE=gateway
	@bash $(SCRIPTS)/rollback.sh "$(ENV)" "$(or $(SERVICE),all)"

.PHONY: rollout-status
rollout-status: ## Did the deploy land? Every Argo CD app Synced and Healthy, on the expected commit
	@# Not a CI job, and that is a limitation rather than a preference: the
	@# Kubernetes API is a tailnet address with 6443 closed publicly (T-1.5), so
	@# no GitHub-hosted runner can ask. Tracked as T-6.7 (#195).
	@bash $(SCRIPTS)/rollout-status.sh "$(ENV)" "$(SHA)"

.PHONY: connection-budget
connection-budget: ## Do the HPA ceiling, the pools and max_connections add up? (T-2.18)
	@bash $(SCRIPTS)/check-connection-budget.sh $(ENV)

.PHONY: verify-resources
verify-resources: ## Every workload we own declares CPU and memory requests (T-2.15)
	@bash $(SCRIPTS)/verify-resources.sh

.PHONY: secrets-verify
secrets-verify: ## Assert every encrypted file carries every recipient .sops.yaml names
	@bash $(SCRIPTS)/verify-secret-recipients.sh

.PHONY: secrets-rekey
secrets-rekey: ## Re-encrypt every secret to the CURRENT recipient list in .sops.yaml
	@# Adding a recipient to .sops.yaml changes what NEW files get. It does
	@# nothing to files that already exist, and sops reports no error -- so the
	@# escrow key can be in the config and in none of the secrets it is meant to
	@# rescue. This is the step that closes that gap; secrets-verify is what
	@# notices when it has not been run.
	@set -e; \
	for f in platform/envs/*/secrets/*.yaml; do \
	  grep -q '^sops:' "$$f" || continue; \
	  echo "  rekey $$f"; \
	  sops updatekeys --yes "$$f" >/dev/null; \
	done; \
	bash $(SCRIPTS)/verify-secret-recipients.sh

.PHONY: format
format: ## Reformat every Java source file in the repository
	@set -e; for m in core gateway; do 		echo "==> services/$$m"; 		( cd services/$$m && ./mvnw -q --batch-mode spotless:apply ); 	done; 	echo "formatted. `git diff --stat -- services/*/src | tail -1`"

.PHONY: format-check
format-check: ## Fail if any Java source file is not formatted (what CI runs)
	@set -e; for m in core gateway; do 		echo "==> services/$$m"; 		( cd services/$$m && ./mvnw -q --batch-mode spotless:check ); 	done; 	echo "every Java file is formatted."

.PHONY: hooks
hooks: ## Install the git pre-commit hook (formatting + secret scanning)
	@git config core.hooksPath .githooks
	@echo "core.hooksPath = .githooks"
	@echo "pre-commit will now run formatting and the secret scan."
	@echo "To disable for one commit: git commit --no-verify"

.PHONY: prune-snapshots
prune-snapshots: ## Show which golden images could be deleted (add ARGS=--delete to do it)
	@bash $(SCRIPTS)/prune-snapshots.sh $(ARGS)

.PHONY: cost
cost: ## What the Hetzner project is costing right now, priced from the API (T-8.4)
	@bash $(SCRIPTS)/cost-report.sh

.PHONY: validate
validate: ## Validate every Terraform root module without touching remote state
	@set -e; for d in $(STORAGE_DIR) $(EDGE_DIR) $(CLUSTER_DIR); do \
		echo "==> $$d"; \
		( cd $$d && { test -d .terraform/providers || $(TF_GIT) terraform init -backend=false -input=false >/dev/null; } && terraform validate ); \
	done

# make up / make down arrive with T-1.7, and will drive $(CLUSTER_DIR) only.
