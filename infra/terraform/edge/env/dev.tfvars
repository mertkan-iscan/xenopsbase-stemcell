# dev — Cloudflare edge. Committed: nothing here is sensitive.
#
# account_id and zone_id are identifiers, not credentials, but they are still
# kept out of a public repository. They live in dev.secrets.tfvars, which is
# gitignored. The API token never appears in a file at all.
environment = "dev"

# One label below the apex, so Cloudflare's Universal SSL certificate covers it.
# app-dev.xenopsoftware.com is covered; dev.app.xenopsoftware.com is not.
hostname = "app-dev.xenopsoftware.com"

# Zone-wide. Enabled 2026-08-20 on an explicit decision: the safepass demo that
# these were held back for is finished and no longer needs to keep working, so
# there is no origin left in the zone that Full (strict) can break.
#
# Full (strict) requires every origin reached over the public internet to present
# a valid, publicly-trusted certificate. Tunnelled traffic does not depend on it
# -- cloudflared makes an outbound mTLS connection, so that leg is authenticated
# whatever the zone says -- but anything else in the zone does.
manage_zone_settings = true
zone_tls_mode        = "strict"
manage_waf           = true

# Keycloak needs its own publicly-resolvable hostname.
#
# The OIDC login flow redirects the user's BROWSER to Keycloak, which cannot
# reach an in-cluster Service name. It also has to match Keycloak's configured
# hostname exactly, because Keycloak advertises that value as the token issuer
# no matter which host the request arrived on -- a mismatch rejects every token
# with an issuer error while everything else looks healthy.
#
# Points at the same ingress controller as the app: the tunnel delivers by
# hostname and ingress-nginx routes by Host header, so identity does not need a
# second entry point.
extra_hostnames = [
  {
    hostname = "auth-dev.xenopsoftware.com"
    service  = "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80"

    # NOT behind Access, and this is the one entry here where that is load
    # bearing rather than a default. See the variable's description.
    access = false
  },

  # The operator dashboards. Every one of them goes to the same ingress
  # controller as the application does -- the tunnel delivers by hostname and
  # ingress-nginx routes by Host header, so four dashboards cost four Ingress
  # objects and no new entry point.
  #
  # All four are behind Access. Two of them have no login of their own.
  {
    hostname = "grafana-dev.xenopsoftware.com"
    service  = "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80"
    access   = true
  },
  {
    hostname = "prometheus-dev.xenopsoftware.com"
    service  = "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80"
    access   = true
  },
  {
    hostname = "alertmanager-dev.xenopsoftware.com"
    service  = "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80"
    access   = true
  },
  {
    hostname = "argocd-dev.xenopsoftware.com"
    service  = "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80"
    access   = true
  },
]

# Cloudflare Access in front of app-dev (T-8.6, #149).
#
# dev is internet-reachable and the credentials that get past its login are
# published in this public repository. Access makes the login unreachable
# without the team, and does it without editing the realm, which matters: a
# realm edit forces a re-import that orphans every existing document (#147).
#
manage_access = true

# The Access group whose members are admitted. This IS here, where the addresses
# it used to be were not: a group id names a container rather than a person, so
# it is publishable and CI can read it like any other variable (T-6.11, #335).
#
# That is the whole fix. `access_allowed_emails` lived in dev.secrets.tfvars
# because the addresses are personal, and the runner rebuilt that file with only
# account_id and zone_id -- so CI planned to rewrite the team policy with an
# empty include on every run, and Cloudflare refused it halfway through an
# apply. There is now nothing secret for CI to be missing.
#
# Membership is managed in the Cloudflare console and Terraform does not
# describe it. Nothing here can tell whether the group still exists or still has
# anyone in it -- the edge token is refused on the Access Groups endpoint, which
# is a separate permission from the Apps and Service Tokens it holds. That is
# the accepted cost of this arrangement, recorded rather than checked.
access_group_id = "90b02bef-7a1d-475e-823a-c5bc872549bc" # xenopsbase-admins

