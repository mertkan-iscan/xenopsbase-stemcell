variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflare API token for the mail zone. Supply via
    TF_VAR_cloudflare_api_token; never in a file.

    Needs exactly one permission, scoped to this zone:
      Zone / DNS / Edit

    Not the edge token, and not the R2 token. The edge token is scoped to a
    different Cloudflare account and cannot see this zone at all.
  EOT
  type        = string
  sensitive   = true
}

variable "zone_id" {
  description = "Zone ID for the mail domain. Shown on the zone's overview page."
  type        = string
}

variable "zone_name" {
  description = <<-EOT
    Apex domain, used to build record names and to assert that the zone_id
    points where this configuration thinks it does.

    Every record below is written as a fully qualified name derived from this,
    rather than as a bare label. Cloudflare accepts both, but a bare label that
    is silently expanded against the wrong zone is exactly the failure this
    module exists to prevent.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+[.][a-z]{2,}$", var.zone_name))
    error_message = "zone_name must be an apex domain, e.g. example.com -- not a subdomain and not a URL."
  }
}

variable "brevo_verification_code" {
  description = <<-EOT
    The brevo-code TXT value proving domain ownership to Brevo.

    Not a secret -- it is published in DNS and world-readable -- but it is
    account-specific, so it lives in the secrets tfvars alongside zone_id rather
    than being committed.
  EOT
  type        = string
}

variable "brevo_sending_subdomain" {
  description = <<-EOT
    The branded sending subdomain Brevo issued, without the apex. Brevo calls
    this the "branded subdomain"; the envelope sender lives here.

    The three CNAMEs under it are not interchangeable and not optional:
      <sub>          the sending host itself, and where SPF is resolved from
      r.<sub>        click and open tracking redirects
      img.<sub>      tracked image hosting

    Deleting r or img does not stop mail. It breaks tracking links inside mail
    that has already been sent, which is why their absence is easy to miss.
  EOT
  type        = string
  default     = "send"
}

variable "brevo_target_domain" {
  description = <<-EOT
    The Brevo-side hostname the branded subdomain points at, e.g.
    send-example-com.brand.brevosend.com. Brevo derives it from the domain with
    dots replaced by hyphens; it is given verbatim in their setup screen.
  EOT
  type        = string
}

variable "brevo_dkim_target_domain" {
  description = <<-EOT
    The Brevo-side hostname the DKIM selectors point at, e.g.
    example-com.dkim.brevo.com. The two selectors prepend b1. and b2.

    These are CNAMEs, not TXT records. Brevo issues either form depending on the
    account; this zone got CNAMEs. They must never be proxied -- an orange-cloud
    CNAME resolves to Cloudflare's edge IPs, and a DKIM lookup that returns an
    A record instead of a key fails the signature check.
  EOT
  type        = string
}

variable "dmarc_policy" {
  description = <<-EOT
    The full DMARC record value.

    Currently p=none, which reports without enforcing. Moving to quarantine or
    reject is a real decision and not a default: it requires confidence that
    every legitimate sender for this domain is aligned, and getting it wrong
    silently sends alerts to spam.
  EOT
  type        = string
  default     = "v=DMARC1; p=none; rua=mailto:rua@dmarc.brevo.com"
}

variable "site_target" {
  description = <<-EOT
    Where the apex serves the personal site from, e.g. <project>.pages.dev.

    Not mail, and not this project's concern -- but it is a record in this zone,
    and a module that manages a zone partially leaves the rest click-configured
    while implying otherwise. It carries prevent_destroy for that reason.
  EOT
  type        = string
}

variable "google_site_verification" {
  description = "The google-site-verification TXT value for the apex. Ownership proof for Search Console."
  type        = string
}

variable "import_record_ids" {
  description = <<-EOT
    Cloudflare record IDs for the one-time adoption of records created in the
    console. See imports.tf, which is deleted once the import has landed.

    Keys: brevo_verification, brevo_sending, brevo_tracking_redirect,
    brevo_tracking_image, brevo_dkim_1, brevo_dkim_2, dmarc, site,
    google_verification.
  EOT
  type        = map(string)
  default     = {}
}
