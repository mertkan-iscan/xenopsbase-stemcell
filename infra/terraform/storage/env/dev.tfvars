# dev — durable buckets. Committed: nothing here is sensitive.
#
# Access key IDs and the project ID live in dev.secrets.tfvars, which is
# gitignored. They are identifiers rather than secrets, but they are half of a
# credential pair and this repository is public.
environment = "dev"

region = "fsn1"
prefix = "xenopsbase"


# Verified working against real buckets on 2026-08-19.
enable_bucket_policies = true

# Retention is NOT set here. Lifecycle rules live in infra/lifecycle/*.json and
# are applied by `make storage-lifecycle`, because Terraform cannot manage them
# against Hetzner. One definition, one place.

# The gateway origin, so a browser can PUT straight to the documents bucket
# (T-3.7, exercised for the first time by T-3.13). Exactly the one origin --
# see the variable for why this is not a wildcard.
document_cors_origins = ["https://app-dev.xenopsoftware.com"]

# xenopsbase-learn's application origin, so its console can PUT a course ZIP
# straight to the package-uploads bucket (learn T-4.1). learn-dev, not app-dev:
# the two applications may not write into each other's upload buckets.
package_upload_cors_origins = ["https://learn-dev.xenopsoftware.com"]
