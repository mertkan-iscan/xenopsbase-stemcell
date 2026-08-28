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
# access_allowed_emails is deliberately NOT here. It is a personal identifier
# and this file is public; it lives in dev.secrets.tfvars.
manage_access = true

