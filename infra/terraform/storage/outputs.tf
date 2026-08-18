output "bucket_names" {
  description = "Bucket name per logical role, for consumption by the cluster module and platform components."
  value       = { for k, v in local.buckets : k => v.name }
}

output "endpoint" {
  description = "S3 endpoint these buckets live behind."
  value       = "https://${var.region}.your-objectstorage.com"
}

output "region" {
  description = "Hetzner location, used as the S3 region name."
  value       = var.region
}

output "policies_enabled" {
  description = "Whether least-privilege bucket policies are applied. False means every project key can read and write every bucket."
  value       = var.enable_bucket_policies
}
