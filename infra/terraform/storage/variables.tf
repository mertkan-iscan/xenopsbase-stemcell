variable "region" {
  description = "Hetzner Object Storage location. One of fsn1, nbg1, hel1."
  type        = string
  default     = "fsn1"

  validation {
    condition     = contains(["fsn1", "nbg1", "hel1"], var.region)
    error_message = "region must be one of fsn1, nbg1, hel1."
  }
}

variable "prefix" {
  description = "Bucket name prefix. Bucket names are global to the project, so this keeps forks of the stemcell from colliding."
  type        = string
  default     = "xenopsbase"
}

variable "project_id" {
  description = <<-EOT
    Hetzner Cloud project ID, the numeric part of the console URL. Used to build
    the principal ARNs in bucket policies:
    arn:aws:iam:::user/p<project_id>:<access_key>
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.project_id))
    error_message = "project_id must be the numeric Hetzner project ID, digits only."
  }
}

variable "access_keys" {
  description = <<-EOT
    Access key IDs per consumer, used to build least-privilege bucket policies.

    These are identifiers, not secrets. The corresponding secret keys never
    appear here and never appear in this repository.

    Hetzner has no API for creating S3 credentials, so these key pairs are
    generated once in the Cloud Console and are bootstrap inputs, in the same
    category as the age key in ADR-0003.

      infra         - Terraform and CI. Retains access to every bucket.
      app           - The core service. Documents only.
      db            - CloudNativePG. Database backups only.
      observability - Loki. Log chunks only.
  EOT
  type = object({
    infra         = string
    app           = string
    db            = string
    observability = string
  })

  validation {
    condition     = length(trimspace(var.access_keys.infra)) > 0
    error_message = "access_keys.infra must be set. It is allowlisted on every bucket; without it, applying a policy locks Terraform out of the bucket permanently."
  }

  validation {
    condition = length(distinct([
      var.access_keys.infra,
      var.access_keys.app,
      var.access_keys.db,
      var.access_keys.observability,
    ])) == 4
    error_message = "Each consumer needs its own key. Sharing one key between consumers defeats the point of per-bucket policies."
  }
}

variable "enable_bucket_policies" {
  description = <<-EOT
    Apply the least-privilege bucket policies.

    Leave this false on the very first apply. Confirm the buckets exist and the
    key IDs in access_keys are correct, then set it true and apply again.

    A policy built from a wrong key ID denies everyone, including Terraform, and
    the policy cannot then be removed without Hetzner support. Verifying first
    costs one extra apply; getting it wrong costs a support ticket.
  EOT
  type        = bool
  default     = false
}

variable "retention_days" {
  description = <<-EOT
    Lifecycle retention, in days.

    These are backstops, not the primary retention policy. CloudNativePG (T-2.4)
    and Loki (T-2.7) each enforce their own, shorter retention. These values must
    stay LONGER than those, or objects vanish underneath a component that still
    believes it owns them.

      documents_noncurrent - old versions of overwritten or deleted documents
      pg_backups           - base backups and WAL. Sets the ceiling on the PITR window
      loki_chunks          - log chunks
      tfstate_noncurrent   - superseded Terraform state versions
      abort_multipart      - cleanup of failed uploads
  EOT
  type = object({
    documents_noncurrent = number
    pg_backups           = number
    loki_chunks          = number
    tfstate_noncurrent   = number
    abort_multipart      = number
  })
  default = {
    documents_noncurrent = 90
    pg_backups           = 35
    loki_chunks          = 30
    tfstate_noncurrent   = 365
    abort_multipart      = 7
  }

  validation {
    condition     = var.retention_days.pg_backups >= 8
    error_message = "pg_backups retention below 8 days leaves no meaningful PITR window and would breach the recovery objectives in ADR-0002."
  }
}
