variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflare API token. Supply via TF_VAR_cloudflare_api_token; never in a file.

    NOT the R2 token — that one is object-storage scoped and cannot touch DNS.
    Needs, scoped to this zone only:
      Zone / DNS / Edit
      Zone / Zone Settings / Edit   (only if manage_zone_settings = true)
      Zone / Zone WAF / Edit        (only if manage_waf = true)
      Zone / Transform Rules / Edit
      Account / Cloudflare Tunnel / Edit

    Zone Settings, Zone WAF and Transform Rules are SEPARATE permissions, and
    the last two are separate despite both being rulesets on the same zone:
    Zone WAF covers http_request_firewall_custom, while the X-Forwarded-Port
    rewrite lives in http_request_late_transform. Holding one does not imply
    another, and the apply that discovers this has already created whatever
    came before the ruleset. `make edge-plan` runs a preflight that
    names any missing one up front — see infra/scripts/preflight.sh.
  EOT
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "Cloudflare account ID. Shown in the dashboard sidebar."
  type        = string
}

variable "zone_id" {
  description = "Zone ID for the domain. Shown on the zone's overview page."
  type        = string
}

variable "environment" {
  description = "Environment this tunnel and hostname belong to."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.environment))
    error_message = "environment must be lower-case alphanumeric with hyphens, 2-16 chars."
  }
}

variable "hostname" {
  description = <<-EOT
    The fully-qualified hostname this environment serves on.

    Keep it ONE label below the apex — app.example.com, not dev.app.example.com.
    Cloudflare's Universal SSL certificate covers the apex and *.example.com
    only; a second level needs Advanced Certificate Manager, which is paid. So
    environments are distinguished by hyphen rather than by depth:

      prod     app.xenopsoftware.com
      staging  app-staging.xenopsoftware.com
      dev      app-dev.xenopsoftware.com
  EOT
  type        = string

  validation {
    condition     = length(regexall("\\.", var.hostname)) == 2
    error_message = "hostname must be exactly one label below the apex (two dots total). A deeper name is not covered by Cloudflare's Universal SSL certificate."
  }
}

variable "tunnel_service" {
  description = <<-EOT
    Where cloudflared forwards traffic once inside the cluster.

    The in-cluster ingress controller service, which T-2.2 installs. Until then
    this points at a service that does not exist yet — harmless, because an
    ingress rule is inert until DNS sends traffic to the tunnel and cloudflared
    is actually running.
  EOT
  type        = string
  default     = "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80"
}

# ------------------------------------------------------------------------------
# Zone-wide settings
#
# xenopsoftware.com is a COMPANY domain with a live site on it. Everything below
# applies to the WHOLE ZONE, not just this project's hostnames -- Cloudflare has
# no per-hostname TLS mode.
#
# So both default to false. Turning them on is a deliberate, reviewed act by
# someone who has checked what else lives in the zone.
# ------------------------------------------------------------------------------

variable "manage_zone_settings" {
  description = <<-EOT
    Let Terraform manage ZONE-WIDE TLS settings.

    Default false, deliberately. Setting the zone to Full (strict) requires
    EVERY origin in the zone to present a valid, publicly-trusted certificate.
    If the existing company site is on Flexible or Full (not strict), flipping
    this breaks it — immediately, and for everyone, not just for this project.

    Traffic through the tunnel does not need it: cloudflared makes an outbound
    mTLS connection to Cloudflare's edge, so the origin leg is already
    authenticated and encrypted regardless of the zone's TLS mode. The strict
    setting protects origins reached over the public internet, which a tunnelled
    origin is not.

    In other words, for this project it is optional. For the rest of the zone it
    may be breaking. That asymmetry is why it is off.
  EOT
  type        = bool
  default     = false
}

variable "zone_tls_mode" {
  description = "Zone TLS mode, applied only when manage_zone_settings is true."
  type        = string
  default     = "strict"

  validation {
    condition     = contains(["off", "flexible", "full", "strict"], var.zone_tls_mode)
    error_message = "zone_tls_mode must be one of off, flexible, full, strict. \"strict\" is Cloudflare's Full (strict)."
  }
}

variable "manage_waf" {
  description = <<-EOT
    Let Terraform manage a baseline WAF ruleset.

    Default false, for the same reason as zone settings: WAF rules are
    zone-scoped, so a rule written for this project's hostname still evaluates
    against every request to the company site. A badly-scoped rule blocks real
    customers.

    When enabled, every rule created here is explicitly constrained to
    var.hostname so it cannot affect anything else in the zone.
  EOT
  type        = bool
  default     = false
}

variable "extra_hostnames" {
  description = <<-EOT
    Additional hostnames this tunnel serves, each mapped to an in-cluster
    service.

    Exists because identity cannot live behind the application's hostname.
    The OIDC login flow redirects the user's BROWSER to Keycloak, so Keycloak
    has to be publicly resolvable in its own right -- an in-cluster Service name
    is not something a browser can reach.

    It also has to match Keycloak's configured hostname exactly. Keycloak
    advertises that value as the token issuer regardless of which host the
    request arrived on (hostname.strict only relaxes which Host headers are
    ACCEPTED). A mismatch rejects every token with an issuer error while
    Keycloak, the realm and the network all look healthy.

    Same one-label-below-apex rule as `hostname`: Universal SSL covers the apex
    and *.example.com only.
  EOT
  type = list(object({
    hostname = string
    service  = string
  }))
  default = []

  validation {
    condition     = alltrue([for h in var.extra_hostnames : length(regexall("\\.", h.hostname)) == 2])
    error_message = "Every extra hostname must be exactly one label below the apex (two dots total); deeper names are not covered by Cloudflare's Universal SSL certificate."
  }
}

variable "manage_access" {
  description = <<-EOT
    Put Cloudflare Access in front of the application hostname (T-8.6, #149).

    Default false. Access requires a Zero Trust organisation on the account,
    which is a one-time dashboard step, and an application created against an
    account that has not been onboarded fails at apply rather than at plan.

    dev turns it on because dev is internet-reachable and the credentials that
    get past its login are published in this repository. Access closes that by
    requiring the team before the login is reachable at all, and it does so
    without touching the realm -- which matters, because a realm edit forces a
    delete-and-re-import that gives every user a new `sub` and orphans every
    document owned under the old one (#147).
  EOT
  type        = bool
  default     = false
}

variable "access_allowed_emails" {
  description = <<-EOT
    Email addresses permitted through Cloudflare Access.

    Supplied from env/<environment>.secrets.tfvars, which is gitignored: this
    is a personal identifier and this repository is public, the same reasoning
    that keeps firewall_source_cidrs out of it.

    Access authenticates these with Cloudflare's built-in one-time PIN, so no
    identity provider has to be configured to make it work.
  EOT
  type        = list(string)
  default     = []
}

variable "access_service_token_name" {
  description = <<-EOT
    Name of the Access service token issued for automated callers.

    Exists so the smoke suite (T-5.5) can still reach dev once a human login is
    required -- which is the acceptance criterion that stops this control from
    quietly breaking CI. The token's client secret is written to Terraform
    state and never to this repository.
  EOT
  type        = string
  default     = "smoke-tests"
}
