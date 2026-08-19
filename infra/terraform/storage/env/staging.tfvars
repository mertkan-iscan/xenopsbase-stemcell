# staging — durable buckets. Committed: nothing here is sensitive.
#
# Access key IDs and the project ID live in staging.secrets.tfvars, which is
# gitignored. They are identifiers rather than secrets, but they are half of a
# credential pair and this repository is public.
environment = "staging"

region = "fsn1"
prefix = "xenopsbase"

# Backstops only. Each component enforces its own, SHORTER retention; these must
# stay longer, or objects vanish underneath a component that still owns them.
retention_days = {
  documents_noncurrent = 90
  pg_backups           = 35
  loki_chunks          = 30
  abort_multipart      = 7
}

# Stays false until staging has its own four S3 credentials. Applying a policy
# built from blank or wrong key IDs denies everybody, permanently, and cannot be
# undone without a Hetzner support ticket.
enable_bucket_policies = false
