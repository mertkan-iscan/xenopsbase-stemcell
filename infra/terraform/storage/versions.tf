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
    use_lockfile                = true
  }
}

provider "aws" {
  region = var.region

  # Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in the
  # environment. Never from a file: this repository is public.
  skip_credentials_validation = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true

  endpoints {
    s3 = "https://${var.region}.your-objectstorage.com"
  }
}
