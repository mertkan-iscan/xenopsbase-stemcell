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

variable "environment" {
  description = "Environment this set of durable buckets belongs to. Forms part of every bucket name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.environment))
    error_message = "environment must be lower-case alphanumeric with hyphens, 2-16 chars. It becomes part of a bucket name, which is not freely renameable."
  }
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

variable "document_cors_origins" {
  description = <<-EOT
    Browser origins allowed to upload straight to the documents bucket.

    Empty by default, which manages no CORS configuration at all. A bucket that
    only ever sees server-side traffic needs none, and a wildcard here would let
    any page on the internet drive a presigned URL a user has been issued.

    Set it to the application origin, scheme included, and nothing else:
    ["https://app-dev.example.com"]. It has to match Origin byte for byte -- no
    trailing slash, no path.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for o in var.document_cors_origins : can(regex("^https?://[^/]+$", o))])
    error_message = "each origin must be scheme://host[:port] with no trailing slash and no path."
  }

  validation {
    condition     = !contains(var.document_cors_origins, "*")
    error_message = "a wildcard origin would expose presigned uploads to any site. Name the application origin explicitly."
  }
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

# retention_days used to live here. It was removed when lifecycle rules moved
# out of Terraform: aws_s3_bucket_lifecycle_configuration cannot be applied
# against Hetzner (see infra/scripts/apply-lifecycle-rules.sh), so the retention
# numbers are now in infra/lifecycle/*.json, which is the single place they are
# defined.
#
# Leaving the variable behind would have been dead config inherited by every
# fork. tflint caught it on the first CI run.
