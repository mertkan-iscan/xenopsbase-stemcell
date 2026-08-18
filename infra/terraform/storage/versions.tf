# ==============================================================================
# DURABLE ROOT MODULE
#
# This module owns the buckets that hold everything in the left-hand column of
# ADR-0002: documents, database backups, log chunks and Terraform state itself.
#
# It is deliberately a SEPARATE root module with its own state, because
# `make down` runs `terraform destroy` on the cluster as a routine, everyday
# operation. If these buckets shared that state, the ordinary teardown would
# delete the entire durable side of the boundary the whole design rests on.
#
# Rules for this module:
#   - It is applied rarely and destroyed effectively never.
#   - Every bucket carries prevent_destroy as a second line of defence.
#   - `make down` must never reach it. It is not wired into that target.
# ==============================================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    # The hcloud provider does not manage Object Storage buckets, so these are
    # managed through the S3-compatible API using the aws provider pointed at
    # Hetzner. No AWS account is involved anywhere.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
    use_path_style              = true

    # State locking via conditional PutObject (If-None-Match).
    #
    # This is the reason state lives in R2 rather than Hetzner (ADR-0005).
    # Hetzner silently ignores the header, so the lock degraded to an ordinary
    # overwrite and protected nothing. R2 implements it.
    #
    # Verify with verify-state-locking.sh after any backend change. Documented
    # support is not evidence — that assumption is what ADR-0005 exists to
    # correct.
    use_lockfile = true
  }
}

# This provider talks to HETZNER, not to R2 and not to AWS.
#
# The backend above writes state to R2 while this provider manages buckets on
# Hetzner, so two different S3 services are in play at once. Both would default
# to AWS_ACCESS_KEY_ID, so they are separated explicitly: the standard AWS names
# belong to R2 (the backend cannot read a TF_VAR), and Hetzner takes these.
provider "aws" {
  region     = var.region
  access_key = var.hetzner_s3_access_key
  secret_key = var.hetzner_s3_secret_key

  skip_credentials_validation = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true

  endpoints {
    s3 = "https://${var.region}.your-objectstorage.com"
  }
}
