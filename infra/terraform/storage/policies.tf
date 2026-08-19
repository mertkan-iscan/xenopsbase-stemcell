# ==============================================================================
# LEAST-PRIVILEGE BUCKET POLICIES
#
# Hetzner S3 credentials are PROJECT-WIDE by default: every key pair has read
# and write access to every bucket in the project, existing and future. Without
# a policy, a leaked Loki key can read every uploaded document and delete every
# database backup.
#
# Bucket policies are the only mechanism Hetzner offers to narrow that. The
# principal ARN format is:
#
#   arn:aws:iam:::user/p<project_id>:<access_key>
#
# Hetzner documents two patterns. This uses the same-project one: a Deny on
# everything, with NotPrincipal listing the keys that keep access.
#
# ------------------------------------------------------------------------------
# READ THIS BEFORE APPLYING
#
# NotPrincipal denies every principal NOT in the list. If the list is wrong --
# a typo'd key ID, a rotated key, a wrong project ID -- then NOBODY can access
# the bucket, INCLUDING the key that would be needed to remove the policy.
#
# There is no self-service recovery. It is a support ticket.
#
# Two guards are in place:
#   1. The infra key is appended to every allowlist, unconditionally, so
#      Terraform always retains the ability to change or remove the policy.
#   2. enable_bucket_policies defaults to false. Apply once to create the
#      buckets, verify the key IDs, then turn it on.
# ==============================================================================

locals {
  # The infra key is on every bucket. Without it, a wrong key ID elsewhere in
  # the list is unrecoverable rather than merely inconvenient.
  bucket_principals = {
    for k, v in local.buckets : k => distinct([
      "arn:aws:iam:::user/p${var.project_id}:${v.owner}",
      "arn:aws:iam:::user/p${var.project_id}:${var.access_keys.infra}",
    ])
  }
}

resource "aws_s3_bucket_policy" "least_privilege" {
  for_each = var.enable_bucket_policies ? local.buckets : {}

  bucket = aws_s3_bucket.this[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyEveryPrincipalExceptOwnerAndInfra"
        Effect = "Deny"
        Action = "s3:*"
        Resource = [
          "arn:aws:s3:::${each.value.name}",
          "arn:aws:s3:::${each.value.name}/*",
        ]
        NotPrincipal = {
          AWS = local.bucket_principals[each.key]
        }
      },
    ]
  })

  # These fire only when policies are being applied, which is why the variables
  # themselves are optional: a first apply with policies off must not demand
  # values whose correctness cannot yet be checked against real buckets.
  lifecycle {
    precondition {
      condition     = length(trimspace(var.project_id)) > 0
      error_message = "project_id is required before bucket policies can be applied. It forms the principal ARN, and a wrong one denies everybody."
    }

    precondition {
      condition     = length(trimspace(var.access_keys.infra)) > 0
      error_message = "access_keys.infra is required before bucket policies can be applied. It is allowlisted on every bucket; without it, applying a policy locks Terraform out permanently."
    }

    precondition {
      condition     = length(trimspace(each.value.owner)) > 0
      error_message = "This bucket has no owner key set in access_keys. Applying a policy now would leave only the infra key with access, silently cutting off the component that needs the bucket."
    }

    precondition {
      condition     = contains(local.bucket_principals[each.key], "arn:aws:iam:::user/p${var.project_id}:${var.access_keys.infra}")
      error_message = "The infra key is missing from the allowlist for this bucket. Applying would lock Terraform out permanently."
    }
  }
}
