locals {
  # Which consumer key owns which bucket. The infra key is added to every
  # allowlist in policies.tf so that Terraform can always still manage them.
  buckets = {
    documents = {
      name      = "${var.prefix}-documents"
      owner     = var.access_keys.app
      versioned = true
      purpose   = "Uploaded documents. User data: never expired by lifecycle."
    }
    pg_backups = {
      name  = "${var.prefix}-pg-backups"
      owner = var.access_keys.db
      # Base backups and WAL segments are written once and never rewritten, so
      # versioning would double the cost and protect nothing.
      versioned = false
      purpose   = "CloudNativePG base backups and WAL archive. Sets the PITR ceiling."
    }
    loki_chunks = {
      name      = "${var.prefix}-loki-chunks"
      owner     = var.access_keys.observability
      versioned = false
      purpose   = "Loki log chunks. Immutable once written."
    }
    tfstate = {
      name  = "${var.prefix}-tfstate"
      owner = var.access_keys.infra
      # Versioning is what makes a corrupted state write recoverable. See
      # docs/runbooks/terraform-state.md.
      versioned = true
      purpose   = "Terraform state. Created by the bootstrap script, adopted here."
    }
  }
}

# ------------------------------------------------------------------------------
# Buckets
#
# The state bucket already exists: bootstrap-state-bucket.sh created it, because
# Terraform cannot create the bucket holding its own state. It is imported here
# rather than left unmanaged, so that versioning and lifecycle are enforced in
# one place instead of living half in a script and half in HCL:
#
#   terraform import aws_s3_bucket.this[\"tfstate\"] xenopsbase-tfstate
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
# Lifecycle rules
#
# Hetzner supports Expiration, NoncurrentVersionExpiration (NoncurrentDays only)
# and AbortIncompleteMultipartUpload. Transitions between storage classes are
# not supported, since there is only one class.
#
# Every rule here is a BACKSTOP. The owning component enforces its own, shorter
# retention. These exist so that a component which stops cleaning up after
# itself cannot grow the bill without bound.
# ------------------------------------------------------------------------------

# Documents are user data. Current versions are never expired: only superseded
# versions are, and only after a long grace period, so that an accidental
# overwrite or delete stays recoverable.
resource "aws_s3_bucket_lifecycle_configuration" "documents" {
  bucket = aws_s3_bucket.this["documents"].id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.retention_days.documents_noncurrent
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.retention_days.abort_multipart
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# The PITR ceiling. CloudNativePG's own retention policy (T-2.4) must be shorter
# than this value, or it will still be referencing WAL segments that lifecycle
# has already deleted, and the failure only surfaces during a restore.
resource "aws_s3_bucket_lifecycle_configuration" "pg_backups" {
  bucket = aws_s3_bucket.this["pg_backups"].id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}

    expiration {
      days = var.retention_days.pg_backups
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Must stay longer than Loki's own retention_period (T-2.7). If chunks disappear
# while Loki's index still references them, queries fail rather than returning
# fewer results.
resource "aws_s3_bucket_lifecycle_configuration" "loki_chunks" {
  bucket = aws_s3_bucket.this["loki_chunks"].id

  rule {
    id     = "expire-old-chunks"
    status = "Enabled"
    filter {}

    expiration {
      days = var.retention_days.loki_chunks
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# State history is small and occasionally priceless. Keep it for a year.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.this["tfstate"].id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.retention_days.tfstate_noncurrent
    }
  }

  # Stale .tflock objects from crashed runs. Short, because a lock older than a
  # day is never legitimate.
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}
