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
    tempo_traces = {
      name  = "${var.prefix}-${var.environment}-tempo-traces"
      owner = var.access_keys.observability
      # Same reasoning as loki_chunks: blocks are written once and never
      # rewritten, so versioning would double the cost and protect nothing.
      versioned = false
      # Seven days, against Loki's thirty. Traces are the highest-volume and
      # shortest-useful telemetry here -- they answer "what did this request do"
      # while someone is still asking, and a trace nobody looked at inside a week
      # is not going to be looked at. The bucket itself is free; Hetzner bills
      # stored volume and egress, so retention is the only cost lever and this is
      # it. See infra/lifecycle/tempo-traces.json.
      purpose = "Tempo trace blocks. Immutable once written, expired after 7 days."
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
# CORS on the documents bucket.
#
# T-3.7 hands the browser a presigned PUT and has it upload straight here, so
# the bytes never cross the gateway. That makes the upload a cross-origin
# request from https://app-*, and one that preflights: a presigned PUT carries
# Content-Type, which is not a CORS-safelisted value. Without this the browser
# never sends the PUT at all.
#
# Nothing before now could have caught it. The T-3.7 integration tests upload
# with an HttpClient, which has no origin and no same-origin policy, so they
# pass against a bucket that no browser can write to.
#
# Only the documents bucket. pg_backups and loki_chunks are written by
# CloudNativePG and Loki over server-side credentials; neither has an origin,
# and a CORS policy on them would widen reach for nothing.
#
# MAY NOT SURVIVE APPLY. aws_s3_bucket_lifecycle_configuration is unusable
# against Hetzner for reasons in the block below -- the provider's post-write
# stabilization polls until the response matches what it sent, and Hetzner
# answers in a shape it will not accept. The same polling exists for CORS. If
# this times out having actually written the rules, it moves to
# infra/scripts/ alongside the lifecycle rules rather than staying here half
# working.
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_cors_configuration" "documents" {
  count  = length(var.document_cors_origins) > 0 ? 1 : 0
  bucket = aws_s3_bucket.this["documents"].id

  cors_rule {
    allowed_origins = var.document_cors_origins
    allowed_methods = ["PUT", "GET", "HEAD"]

    # The browser asks permission for the exact headers it intends to send, and
    # a presigned PUT sends Content-Type plus whatever was signed into the
    # request. Listing them individually means a signature that includes one
    # more fails preflight for a reason the network tab reports as a bare CORS
    # error.
    #
    # This is not a wildcard ORIGIN and grants no reach: it only concerns which
    # headers an already-allowed origin may send.
    allowed_headers = ["*"]

    # So the caller can read the ETag off the response and confirm what landed.
    # Response headers are hidden from script unless named here, and the upload
    # otherwise succeeds with nothing to check it against.
    expose_headers = ["ETag"]

    max_age_seconds = 3600
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
