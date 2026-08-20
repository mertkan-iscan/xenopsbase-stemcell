# dev — Cloudflare edge. Committed: nothing here is sensitive.
#
# account_id and zone_id are identifiers, not credentials, but they are still
# kept out of a public repository. They live in dev.secrets.tfvars, which is
# gitignored. The API token never appears in a file at all.
environment = "dev"

# One label below the apex, so Cloudflare's Universal SSL certificate covers it.
# app-dev.xenopsoftware.com is covered; dev.app.xenopsoftware.com is not.
hostname = "app-dev.xenopsoftware.com"

# Zone-wide, and this zone hosts a live company site. Both stay false until
# someone has checked what else is in the zone. See variables.tf.
manage_zone_settings = false
manage_waf           = false

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
  },
]
