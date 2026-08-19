# Hetzner Object Storage credentials for the aws provider.
#
# These are NOT the credentials the backend uses. The backend writes state to
# R2 and reads AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY; Hetzner takes these
# explicit ones so the two cannot collide. See ADR-0005.
variable "hetzner_s3_access_key" {
  description = "Hetzner Object Storage access key. Supply via TF_VAR_hetzner_s3_access_key; never in a file."
  type        = string
  sensitive   = true
}

variable "hetzner_s3_secret_key" {
  description = "Hetzner Object Storage secret key. Supply via TF_VAR_hetzner_s3_secret_key; never in a file."
  type        = string
  sensitive   = true
}

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
  default     = ""

  # Only needed when bucket policies are enabled, so it is not required for the
  # first apply. policies.tf enforces its presence at the point of use.
  validation {
    condition     = var.project_id == "" || can(regex("^[0-9]+$", var.project_id))
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
    infra         = optional(string, "")
    app           = optional(string, "")
    db            = optional(string, "")
    observability = optional(string, "")
  })
  default = {}

  # Deliberately not required. The first apply runs with
  # enable_bucket_policies = false and creates buckets only, so the key IDs can
  # be checked against real buckets before a wrong one can lock anyone out.
  # policies.tf enforces what it needs at the point of use.
  #
  # What IS checked here: no two consumers may share a key, since that silently
  # defeats the isolation the policies exist to provide. Empty entries are
  # ignored, because "not supplied yet" is not "shared".
  validation {
    condition = length(compact([
      var.access_keys.infra,
      var.access_keys.app,
      var.access_keys.db,
      var.access_keys.observability,
      ])) == length(distinct(compact([
        var.access_keys.infra,
        var.access_keys.app,
        var.access_keys.db,
        var.access_keys.observability,
    ])))
    error_message = "Two consumers share an access key. That defeats the isolation these policies exist to provide."
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
