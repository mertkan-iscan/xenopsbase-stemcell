output "tunnel_id" {
  description = "Tunnel UUID. Stable across cluster rebuilds, which is why the DNS record never changes."
  value       = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

output "tunnel_name" {
  description = "Tunnel name as it appears in the Cloudflare Zero Trust dashboard."
  value       = local.tunnel_name
}

output "tunnel_token" {
  description = <<-EOT
    Credential cloudflared uses to connect. Consumed by the in-cluster
    deployment in T-2.2, and encrypted with SOPS per ADR-0003 rather than
    passed around.
  EOT
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.this.token
  sensitive   = true
}

output "hostname" {
  description = "The hostname this environment serves on."
  value       = var.hostname
}

output "dns_target" {
  description = "Where the record points right now. The first thing to check if the site is down."
  value       = cloudflare_dns_record.app.content
}

output "zone_settings_managed" {
  description = "Whether Terraform owns the zone-wide TLS settings. False means they are whatever the console says."
  value       = var.manage_zone_settings
}

output "waf_managed" {
  description = "Whether the baseline WAF ruleset is applied."
  value       = var.manage_waf
}

output "access_enabled" {
  description = "Whether Cloudflare Access fronts the application hostname."
  value       = var.manage_access
}

output "access_service_token_client_id" {
  description = <<-EOT
    Client id for the Access service token, for automated callers (T-5.5).

    Sent as CF-Access-Client-Id alongside CF-Access-Client-Secret. Not
    sensitive on its own; the secret is the other half.
  EOT
  value       = var.manage_access ? cloudflare_zero_trust_access_service_token.automation[0].client_id : null
}

output "access_service_token_client_secret" {
  description = <<-EOT
    Secret half of the Access service token.

    Cloudflare returns this once, at creation, and never again -- so Terraform
    state is the only copy. Read it with `terraform output -raw`, put it
    wherever CI keeps secrets, and do not expect to recover it from the
    dashboard later.
  EOT
  value       = var.manage_access ? cloudflare_zero_trust_access_service_token.automation[0].client_secret : null
  sensitive   = true
}
