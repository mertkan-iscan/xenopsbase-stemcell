# ==============================================================================
# EDGE — Cloudflare DNS and the tunnel that fronts the cluster.
#
# A third root module, separated by durability like the others (ADR-0002):
#
#   storage/  buckets. Applied rarely, destroyed never.
#   edge/     tunnel + DNS. Survives every cluster rebuild.  <-- this one
#   cluster/  the K3s cluster. Built and destroyed routinely.
#
# The tunnel is the reason DNS does not churn. A record points at
# <tunnel-id>.cfargotunnel.com, which is stable, so destroying and rebuilding
# the cluster changes nothing at the edge. Pointing DNS at a load balancer IP
# instead would mean rewriting records on every rebuild -- and a propagation
# window on every one of them.
# ==============================================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
      # Pinned to v5 deliberately: the v5 provider renamed most resources from v4.
      version = "~> 5.23"
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

provider "cloudflare" {
  # Supplied via TF_VAR_cloudflare_api_token. This is a DIFFERENT token from the
  # R2 one: R2 tokens are object-storage scoped and cannot touch DNS or zone
  # settings.
  api_token = var.cloudflare_api_token
}
