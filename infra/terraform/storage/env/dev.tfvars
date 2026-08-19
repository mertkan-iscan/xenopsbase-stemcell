# dev — durable buckets. Committed: nothing here is sensitive.
#
# Access key IDs and the project ID live in dev.secrets.tfvars, which is
# gitignored. They are identifiers rather than secrets, but they are half of a
# credential pair and this repository is public.
environment = "dev"

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

# Verified working against real buckets on 2026-08-19.
enable_bucket_policies = true
