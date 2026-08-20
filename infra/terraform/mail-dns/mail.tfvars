# mail-dns — committed. Nothing here is sensitive.
#
# zone_id, the Brevo verification code, the Pages target and the Google
# verification string are identifiers rather than credentials, but they are
# still account-specific, so they live in secrets.tfvars, which is gitignored.
# The API token never appears in a file at all.

zone_name = "mertkaniscan.com"

# Brevo's branded subdomain for this account. The envelope sender lives here,
# which is what makes SPF and DMARC align against this domain rather than
# against Brevo's shared sending reputation.
brevo_sending_subdomain = "send"
brevo_target_domain     = "send-mertkaniscan-com.brand.brevosend.com"

# DKIM selectors are CNAMEs on this account, not TXT records. b1. and b2. are
# prepended to this.
brevo_dkim_target_domain = "mertkaniscan-com.dkim.brevo.com"

# Report-only. Moving to quarantine or reject needs confidence that every
# legitimate sender for this domain is aligned; getting it wrong sends the
# alerts themselves to spam.
dmarc_policy = "v=DMARC1; p=none; rua=mailto:rua@dmarc.brevo.com"
