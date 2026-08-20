# ------------------------------------------------------------------------------
# Every record in the mail zone, with what breaks in its absence.
#
# All of them existed as console edits before this file. They were imported
# rather than recreated -- see imports.tf -- because recreating a DKIM CNAME
# means a window in which signatures fail.
#
# The comment field is set on each record so the reason survives in the console
# too, where the next person to look is more likely to be.
# ------------------------------------------------------------------------------

locals {
  managed = "Managed by xenopsbase-stemcell (mail-dns). Do not edit in the console."

  sending_host = "${var.brevo_sending_subdomain}.${var.zone_name}"
}

# ------------------------------------------------------------------------------
# Ownership
# ------------------------------------------------------------------------------

# Without it: Brevo marks the domain unverified and refuses to send as it at
# all. This is the record that gates everything else.
resource "cloudflare_dns_record" "brevo_verification" {
  zone_id = var.zone_id
  name    = var.zone_name
  type    = "TXT"
  content = "\"brevo-code:${var.brevo_verification_code}\""
  ttl     = 3600
  proxied = false
  comment = local.managed
}

# ------------------------------------------------------------------------------
# Sending path
# ------------------------------------------------------------------------------

# The branded sending subdomain. Without it: the envelope sender has no home,
# SPF cannot be resolved for it, and receiving servers fall back to Brevo's
# shared reputation instead of this domain's.
#
# Note there is deliberately no SPF TXT record at this name. It is a CNAME, and
# RFC 1034 forbids any other record type coexisting with a CNAME -- Cloudflare
# rejects the attempt. SPF resolves by following this CNAME to Brevo, which
# publishes it on the target. A hand-added "v=spf1 include:spf.brevo.com -all"
# here does not harden anything; it fails to save, or worse, breaks the CNAME.
resource "cloudflare_dns_record" "brevo_sending" {
  zone_id = var.zone_id
  name    = local.sending_host
  type    = "CNAME"
  content = var.brevo_target_domain
  ttl     = 3600

  # Never proxied. Proxying rewrites the answer to Cloudflare's edge IPs, which
  # breaks every mail-path lookup that expects to reach Brevo.
  proxied = false
  comment = local.managed
}

# Click and open tracking. Without it: mail still arrives, but every tracked
# link inside mail already sent stops resolving. Failure is delayed and looks
# unrelated to DNS, which is why it is declared here rather than left implicit.
resource "cloudflare_dns_record" "brevo_tracking_redirect" {
  zone_id = var.zone_id
  name    = "r.${local.sending_host}"
  type    = "CNAME"
  content = "${var.brevo_sending_subdomain}-${replace(var.zone_name, ".", "-")}.r.brand.brevosend.com"
  ttl     = 3600
  proxied = false
  comment = local.managed
}

# Tracked image hosting. Same delayed failure mode as the redirect host.
resource "cloudflare_dns_record" "brevo_tracking_image" {
  zone_id = var.zone_id
  name    = "img.${local.sending_host}"
  type    = "CNAME"
  content = "${var.brevo_sending_subdomain}-${replace(var.zone_name, ".", "-")}.img.brand.brevosend.com"
  ttl     = 3600
  proxied = false
  comment = local.managed
}

# ------------------------------------------------------------------------------
# Authentication
# ------------------------------------------------------------------------------

# DKIM. Without these: messages arrive unsigned, DMARC alignment fails, and
# Gmail files alerts as spam or drops them outright.
#
# Two selectors so Brevo can rotate one while the other stays valid. Losing one
# is survivable and invisible until the rotation lands on the missing half.
#
# CNAMEs, not TXT. Brevo issues either form; this account got CNAMEs. Flattening
# them to TXT by hand publishes a stale copy of a key Brevo intends to rotate.
resource "cloudflare_dns_record" "brevo_dkim" {
  for_each = {
    "brevo1" = "b1"
    "brevo2" = "b2"
  }

  zone_id = var.zone_id
  name    = "${each.key}._domainkey.${var.zone_name}"
  type    = "CNAME"
  content = "${each.value}.${var.brevo_dkim_target_domain}"
  ttl     = 3600
  proxied = false
  comment = local.managed
}

# DMARC. Without it: receiving servers apply their own defaults, and there is no
# reporting address, so a delivery failure produces no signal anywhere.
resource "cloudflare_dns_record" "dmarc" {
  zone_id = var.zone_id
  name    = "_dmarc.${var.zone_name}"
  type    = "TXT"
  content = "\"${var.dmarc_policy}\""
  ttl     = 3600
  proxied = false
  comment = local.managed
}

# ------------------------------------------------------------------------------
# Not mail
# ------------------------------------------------------------------------------

# The personal site at the apex. Unrelated to alerting, and included only so the
# zone is fully described rather than half-managed.
resource "cloudflare_dns_record" "site" {
  zone_id = var.zone_id
  name    = var.zone_name
  type    = "CNAME"
  content = var.site_target
  proxied = true

  # ttl must be 1 (automatic) whenever proxied is true; Cloudflare rejects
  # anything else.
  ttl     = 1
  comment = local.managed

  # This is the only record here whose loss has consequences outside this
  # project, and nothing in the monitoring would notice. A destroy of this
  # module must not be able to take the site down as a side effect.
  lifecycle {
    prevent_destroy = true
  }
}

# Search Console ownership. Without it: verification lapses and Search Console
# access is lost, which is recoverable but silently.
resource "cloudflare_dns_record" "google_verification" {
  zone_id = var.zone_id
  name    = var.zone_name
  type    = "TXT"
  content = "\"google-site-verification=${var.google_site_verification}\""
  ttl     = 3600
  proxied = false
  comment = local.managed
}
