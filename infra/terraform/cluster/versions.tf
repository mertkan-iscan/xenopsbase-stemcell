# ==============================================================================
# EPHEMERAL ROOT MODULE
#
# The K3s cluster. This is the cattle side of ADR-0002: built by `make up`,
# destroyed by `make down`, and rebuilt from nothing as a routine operation.
#
# Nothing here is durable. Anything that must survive a destroy belongs in
# infra/terraform/storage/, which has its own state and is deliberately out of
# reach of this module's destroy.
# ==============================================================================

terraform {
  # use_lockfile (S3-native state locking, no DynamoDB) landed in 1.10.
  required_version = ">= 1.10.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.51.0"
    }
  }

  # The backend is deliberately partial. Bucket, region and endpoint come from
  # backend.hcl so that the same code initializes against any environment:
  #
  #   terraform init -backend-config=backend.hcl
  #
  # See docs/runbooks/terraform-state.md for why each skip_* flag is here.
  backend "s3" {
    # Hetzner Object Storage is S3-compatible but is not AWS. These disable the
    # AWS-specific behaviours the backend would otherwise attempt.
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true

    # Hetzner does not implement the additional checksum headers Terraform sends
    # by default. The lock object is written with the same settings as the state
    # object, so this applies to both.
    skip_s3_checksum = true

    use_path_style = true

    # ⚠️ THIS PROVIDES NO PROTECTION ON HETZNER. Verified 2026-08-19.
    # Hetzner Object Storage silently ignores If-None-Match, so the conditional
    # PutObject that implements this lock degrades to an ordinary overwrite.
    # Concurrent applies WILL corrupt state, with no error at the time.
    # Full evidence in infra/terraform/storage/versions.tf and
    # docs/runbooks/terraform-state.md.
    use_lockfile = true
  }
}

provider "hcloud" {
  token = var.hcloud_token
}
