# prod — Cloudflare edge. Committed: nothing here is sensitive.
#
# account_id and zone_id are identifiers, not credentials, but they are still
# kept out of a public repository. They live in prod.secrets.tfvars, which is
# gitignored. The API token never appears in a file at all.
environment = "prod"

# One label below the apex, so Cloudflare's Universal SSL certificate covers it.
# app-prod.xenopsoftware.com is covered; prod.app.xenopsoftware.com is not.
hostname = "app.xenopsoftware.com"

# Zone-wide, and this zone hosts a live company site. Both stay false until
# someone has checked what else is in the zone. See variables.tf.
manage_zone_settings = false
manage_waf           = false
