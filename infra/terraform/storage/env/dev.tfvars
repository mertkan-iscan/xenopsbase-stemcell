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
