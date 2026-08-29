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

    `access` puts Cloudflare Access in front of that hostname. It is off by
    default because the original member of this list is Keycloak, which must
    NOT be behind Access: the OIDC flow redirects the browser here to log in,
    and an Access interstitial in that path breaks the back-channel code
    exchange. Opting in per hostname keeps that a stated decision rather than
    something a later addition inherits by accident.
  EOT
  type = list(object({
    hostname = string
    service  = string
    access   = optional(bool, false)
  }))
  default = []

  validation {
    condition     = alltrue([for h in var.extra_hostnames : length(regexall("\\.", h.hostname)) == 2])
    error_message = "Every extra hostname must be exactly one label below the apex (two dots total); deeper names are not covered by Cloudflare's Universal SSL certificate."
  }

  # Moved from check "access_opt_in_needs_access_enabled" for the reason above:
  # it warned, and warnings do not stop applies. This one is worth more than a
  # warning because the failure is silent and public -- every Access resource in
  # this module is gated on manage_access, so with it off an `access = true`
  # flag is ignored rather than honoured, and the hostname is served to the
  # internet while reading as protected. Two of the dashboards behind it have no
  # login of their own.
  validation {
    condition     = var.manage_access || length([for h in var.extra_hostnames : h.hostname if h.access]) == 0
    error_message = "extra_hostnames opts a hostname into Access but manage_access is false, which would publish it with no Access in front of it. Set manage_access = true, or drop the access flag."
  }
}

variable "access_protect_app" {
  description = <<-EOT
    Keep Cloudflare Access in front of the APPLICATION hostname specifically
    (T-3.18, #175). Default true. Independent of manage_access on purpose.

    THIS EXISTS FOR ONE EXPERIMENT, AND SHOULD BE TRUE EVERYWHERE ELSE.

    #175 is an intermittent login dead-end that only a real browser reproduces.
    Everything reachable without one has been excluded -- 105 automated attempts
    through the authorization-code flow found their saved authorization request
    105 times, across both replicas. The remaining untested variable is the
    browser crossing cloudflareaccess.com mid-flow, and the only way to test it
    is to take Access out of that path and see whether the failures stop.

    WHY NOT JUST SET manage_access = false

    Because it removes far more than the application. `manage_access` also gates
    `local.access_dashboard_hostnames`, so turning it off destroys the Access
    applications for grafana-dev, prometheus-dev, alertmanager-dev and
    argocd-dev -- and as the comment above the dashboard resource says,
    Prometheus and Alertmanager have NO authentication of their own. Access is
    not defence in depth for those two, it is the only control, and
    Alertmanager's API can silence alerting.

    It would also destroy the service token that CI's smoke run drives the
    application with.

    So this variable removes Access from the application hostname and nothing
    else. The dashboards, the policies and the service token are untouched.

    WHAT IS EXPOSED WHILE IT IS FALSE

    app-dev answers without an Access challenge. It is not open: the gateway
    still requires a Keycloak login for anything authenticated, and the WAF
    ruleset still applies. What is lost is the outer layer, on one hostname, in
    a disposable environment.
  EOT

  type    = bool
  default = true
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

variable "access_group_id" {
  description = <<-EOT
    The Cloudflare Access group whose members are admitted (T-6.11, #335).

    A UUID, and deliberately in the TRACKED tfvars rather than the gitignored
    ones: a group id identifies a container, not a person, so it is publishable
    in a way the membership is not.

    WHY A GROUP RATHER THAN A LIST OF ADDRESSES

    This was `access_allowed_emails`, supplied from env/<env>.secrets.tfvars
    because the addresses are personal and this repository is public. That made
    the policy unreconcilable from CI: the runner rebuilt the gitignored file
    with only account_id and zone_id, so the variable fell back to [], and every
    CI run planned to rewrite the team policy with an empty include. Cloudflare
    refuses that -- after the apply had already destroyed the Access
    application, leaving the module half-applied.

    Moving membership into Cloudflare removes the problem rather than working
    around it. There is nothing secret left for CI to be missing, so no
    repository secret, no reconstruction step, and no value that differs between
    a local apply and a CI one.

    THE COST, STATED

    Membership is now console-managed state that Terraform does not describe --
    the thing ADR-0002 is otherwise against. It is accepted here because the
    alternative was worse: the addresses were already outside the repository,
    and the previous arrangement additionally meant nobody could reconcile the
    policy at all. Terraform cannot manage the group either, because managing it
    would need the member addresses and CI would then plan to empty it -- the
    same failure one resource sideways.

    THE RESIDUAL RISK, AND WHAT CHECKS IT

    A group deleted or emptied in the console is invisible to Terraform. The id
    stays a well-formed UUID, the plan is clean, the policy applies, and the
    result is a policy that admits nobody -- this card's failure arriving by
    another road.

    `make preflight edge` asks Cloudflare whether this id resolves, and fails on
    404. That probe needs Account / Access: Groups / Read on the edge token,
    which is a NARROWER permission than the module's others: read-only, because
    Terraform must never manage this group.

    The permission was missing when this was written -- the probe was refused on
    exactly this endpoint (403, "Authentication error") and held back until it
    was added. The 403 arm survives in preflight so that losing it again is
    caught there rather than by a policy that quietly admits nobody.
  EOT
  type        = string
  default     = ""

  # A VALIDATION, NOT A `check` BLOCK, AND THE DIFFERENCE IS THE WHOLE CARD.
  #
  # This assertion existed before T-6.11, as check "access_has_someone_to_admit"
  # in main.tf, described as refusing the combination that locks everyone out.
  # A check block CANNOT refuse anything: a failed assertion is a WARNING and
  # `terraform plan` still exits 0. Measured on Terraform 1.14.8 against that
  # exact condition -- "Warning: Check block assertion failed", exit code 0. So
  # the guard this repository believed it had let an empty include through to
  # Cloudflare, which rejected it partway into an apply.
  #
  # Variable validation is evaluated before any provider is configured, so this
  # fails with nothing contacted and nothing changed -- the acceptance criterion
  # "applies from CI without error, or fails before making any change", met by
  # the second half.
  #
  # An assertion that must STOP something belongs here. A check block is for
  # reporting a condition nobody is expected to act on immediately.
  validation {
    condition     = !var.manage_access || var.access_group_id != ""
    error_message = "manage_access = true needs access_group_id: a team policy with an empty include admits no human, and Cloudflare refuses it partway through an apply. Set it in env/<environment>.tfvars -- the group id is in the Cloudflare dashboard under Zero Trust / Access controls / Policies, on the Rule groups tab."
  }

  validation {
    condition     = var.access_group_id == "" || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.access_group_id))
    error_message = "access_group_id must be a UUID, as shown in the dashboard's Group ID field."
  }
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
