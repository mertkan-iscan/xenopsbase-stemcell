locals {
  # Buckets are named per environment.
  #
  # This is not cosmetic. Bucket policies are the ONLY isolation mechanism
  # Hetzner offers (project-wide keys otherwise read everything), and a policy
  # applies to a whole bucket. Sharing one documents bucket across environments
  # would mean allowlisting the dev app key and the prod app key on the same
  # bucket -- so a leaked dev credential reads production documents. Separate
  # buckets are what make the least-privilege claim survive a second
  # environment.
  #
  # The state-backup bucket is deliberately absent. It is cross-environment by
  # nature, so it does not belong in a per-environment module; T-1.9 owns it.
  buckets = {
    documents = {
      name      = "${var.prefix}-${var.environment}-documents"
      owner     = var.access_keys.app
      versioned = true
      purpose   = "Uploaded documents. User data: never expired by lifecycle."
    }
    pg_backups = {
      name  = "${var.prefix}-${var.environment}-pg-backups"
      owner = var.access_keys.db
      # Base backups and WAL segments are written once and never rewritten, so
      # versioning would double the cost and protect nothing.
      versioned = false
      purpose   = "CloudNativePG base backups and WAL archive. Sets the PITR ceiling."
    }
    loki_chunks = {
      name      = "${var.prefix}-${var.environment}-loki-chunks"
      owner     = var.access_keys.observability
      versioned = false
      purpose   = "Loki log chunks. Immutable once written."
    }
  }
}

# ------------------------------------------------------------------------------
# Buckets
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "this" {
  for_each = local.buckets
  bucket   = each.value.name

  # This is the durable column of ADR-0002. Losing any of these buckets means
  # losing documents, the ability to restore the database, or the record of what
  # infrastructure exists. Deletion must require deliberately editing this file.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = each.value.versioned ? "Enabled" : "Suspended"
  }
}

# ------------------------------------------------------------------------------
# Lifecycle rules are NOT managed here.
#
# aws_s3_bucket_lifecycle_configuration cannot be used against Hetzner. The PUT
# succeeds; the provider's post-write stabilization is what fails. It polls
# GetBucketLifecycleConfiguration until the response matches what it sent, and
# both HCL forms -- `filter {}` and the deprecated `prefix = ""` -- normalize
# internally to a V2 Filter. Hetzner always returns the V1 form instead, with a
# bare <Prefix></Prefix> and no Filter element, so the comparison never
# converges. Every lifecycle resource burns its full 3 minute timeout and fails
# having actually applied the rules correctly.
#
# Verified 2026-08-19 against aws provider v6.60.0: 21 polls, a correct
# response every time, never accepted.
#
# The rules therefore live in infra/lifecycle/*.json and are applied by
# infra/scripts/apply-lifecycle-rules.sh, which reads them back to confirm they
# stuck. Still reviewable code under version control -- ADR-0002 forbids state
# created BY HAND, and nothing there is.
#
#   make storage-lifecycle
#
# See docs/runbooks/object-storage.md.
# ------------------------------------------------------------------------------
