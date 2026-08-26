# ==============================================================================
# THE CLUSTER, WITHOUT KUBE-HETZNER (T-1.26, #287)
#
# A second root module, deliberately, rather than an edit to cluster/.
#
# Removing the module cannot be done in pieces: `existing_network_id` was
# dropped in module v3, so the moment this repository owns the network the
# module can no longer place a server in it. Doing that in cluster/ would
# replace the one path that works with one that has never been applied -- which
# is what the last two builds cost, and the reason for the separation.
#
# So this is built and destroyed on its own state key, next to a cluster/ that
# keeps working. `make up` moves over when this can produce a cluster that
# `make verify-node-provenance` passes with no gaps.
# ==============================================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.51.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }

  backend "s3" {
    region                      = "auto"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
    use_lockfile                = true
  }
}

provider "hcloud" {
  token = var.hcloud_token
}
