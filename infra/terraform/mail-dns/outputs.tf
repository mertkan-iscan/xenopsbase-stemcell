output "sending_host" {
  description = "The branded sending subdomain. The envelope sender for every alert lives here."
  value       = cloudflare_dns_record.brevo_sending.name
}

output "dkim_selectors" {
  description = "The DKIM selector hostnames, for checking a signature failure against what is actually published."
  value       = [for r in cloudflare_dns_record.brevo_dkim : r.name]
}

output "dmarc_policy" {
  description = "The DMARC policy currently published. p=none reports without enforcing."
  value       = var.dmarc_policy
}

output "verify_commands" {
  description = <<-EOT
    Copy-pasteable checks. Alert delivery can fail with every record present but
    one of them proxied or flattened, and none of that shows up in a plan.
  EOT
  value       = <<-EOT
    dig +short ${cloudflare_dns_record.brevo_sending.name} CNAME
    dig +short brevo1._domainkey.${var.zone_name} CNAME
    dig +short brevo2._domainkey.${var.zone_name} CNAME
    dig +short _dmarc.${var.zone_name} TXT
    dig +short ${var.zone_name} TXT
  EOT
}
