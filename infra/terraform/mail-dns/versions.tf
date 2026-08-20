# ==============================================================================
# MAIL-DNS — the DNS records that alert delivery depends on.
#
# A fourth root module, and deliberately not part of edge/.
#
#   storage/   buckets. Applied rarely, destroyed never.
#   edge/      tunnel + DNS for the app. Per environment.
#   cluster/   the K3s cluster. Built and destroyed routinely.
#   mail-dns/  deliverability records. One zone, no environments.  <-- this one
#
# Two reasons it is separate rather than a second zone inside edge/:
#
#   1. edge/ is per-environment. Its state key is edge/$(ENV)/terraform.tfstate,
#      so dev, staging and prod each hold their own copy. These records are a
#      singleton -- there is one mertkaniscan.com -- and three environments all
#      claiming the same records would fight over them.
#
#   2. Different token. This zone is on a separate Cloudflare account from
#      xenopsoftware.com, so one provider block cannot reach both. Keeping them
#      apart also keeps the app edge from having to hold a mail credential.
#
# Why it exists at all: Brevo accepts a message, returns "250 OK: queued", and
# discards it if these records are wrong. Alertmanager logs "Notify success"
# either way. The monitoring that catches everything else cannot catch its own
# delivery path failing, so the delivery path gets version control instead.
# ==============================================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
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
  # Supplied via TF_VAR_cloudflare_mail_api_token. Scoped to this zone only:
  #   Zone / DNS / Edit   on mertkaniscan.com
  # It needs nothing else. In particular it must NOT be the edge token -- that
  # one is scoped to a different account and cannot see this zone.
  api_token = var.cloudflare_api_token
}
