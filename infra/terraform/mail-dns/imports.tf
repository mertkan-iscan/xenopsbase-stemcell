# ------------------------------------------------------------------------------
# One-time adoption of records that already exist.
#
# Every record here predates this module -- they were created in the Cloudflare
# console, which is the problem #141 exists to fix. They are IMPORTED rather
# than recreated because recreating a DKIM CNAME opens a window in which signed
# mail fails verification, and recreating the apex CNAME takes the site down for
# the length of a propagation.
#
# The IDs come from the zone itself:
#
#   curl -s -H "Authorization: Bearer $TF_VAR_cloudflare_api_token" \
#     "https://api.cloudflare.com/client/v4/zones/<zone>/dns_records?per_page=100" \
#     | jq -r '.result[] | "\(.name)\t\(.type)\t\(.id)"'
#
# They are Cloudflare-internal identifiers, not credentials, but they are
# zone-specific, so they live in the gitignored secrets tfvars beside zone_id
# rather than being committed.
#
# DELETE THIS FILE once `terraform plan` reports no changes. Import blocks are
# no-ops after the first apply, so leaving them is harmless but misleading: it
# implies the records are still unmanaged.
# ------------------------------------------------------------------------------

import {
  to = cloudflare_dns_record.brevo_verification
  id = "${var.zone_id}/${var.import_record_ids["brevo_verification"]}"
}

import {
  to = cloudflare_dns_record.brevo_sending
  id = "${var.zone_id}/${var.import_record_ids["brevo_sending"]}"
}

import {
  to = cloudflare_dns_record.brevo_tracking_redirect
  id = "${var.zone_id}/${var.import_record_ids["brevo_tracking_redirect"]}"
}

import {
  to = cloudflare_dns_record.brevo_tracking_image
  id = "${var.zone_id}/${var.import_record_ids["brevo_tracking_image"]}"
}

import {
  to = cloudflare_dns_record.brevo_dkim["brevo1"]
  id = "${var.zone_id}/${var.import_record_ids["brevo_dkim_1"]}"
}

import {
  to = cloudflare_dns_record.brevo_dkim["brevo2"]
  id = "${var.zone_id}/${var.import_record_ids["brevo_dkim_2"]}"
}

import {
  to = cloudflare_dns_record.dmarc
  id = "${var.zone_id}/${var.import_record_ids["dmarc"]}"
}

import {
  to = cloudflare_dns_record.site
  id = "${var.zone_id}/${var.import_record_ids["site"]}"
}

import {
  to = cloudflare_dns_record.google_verification
  id = "${var.zone_id}/${var.import_record_ids["google_verification"]}"
}
