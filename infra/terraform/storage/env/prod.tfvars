# prod — durable buckets. Committed: nothing here is sensitive.
#
# Access key IDs and the project ID live in prod.secrets.tfvars, which is
# gitignored. They are identifiers rather than secrets, but they are half of a
# credential pair and this repository is public.
environment = "prod"

region = "fsn1"
prefix = "xenopsbase"


# Stays false until prod has its own four S3 credentials. Applying a policy
# built from blank or wrong key IDs denies everybody, permanently, and cannot be
# undone without a Hetzner support ticket.
enable_bucket_policies = false

# Retention is NOT set here. Lifecycle rules live in infra/lifecycle/*.json and
# are applied by `make storage-lifecycle`, because Terraform cannot manage them
# against Hetzner. One definition, one place.
