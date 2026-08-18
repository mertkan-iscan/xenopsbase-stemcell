terraform {
  # use_lockfile (S3-native state locking, no DynamoDB) landed in 1.10.
  required_version = ">= 1.10.0"

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

    # Locking via conditional PutObject (If-None-Match). Hetzner does not
    # document conditional-request support, so this is UNPROVEN until
    # `make verify-locking` passes. It fails open: if the header is ignored,
    # concurrent applies both succeed and corrupt state silently.
    use_lockfile = true
  }
}
