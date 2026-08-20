#!/usr/bin/env bash
#
# Resolves every record the mail-dns module manages and reports what is actually
# published. Acceptance check for T-1.13.
#
# WHY THIS EXISTS
#
# `terraform plan` proves the zone matches the configuration. It does not prove
# mail can be delivered, and the gap between those two is where this project
# already lost an hour:
#
#   - Brevo accepts a message it cannot authenticate, returns "250 OK: queued",
#     and discards it. Alertmanager logs "Notify success".
#   - A DKIM CNAME that gets proxied resolves to Cloudflare's edge IPs. The
#     record still exists, Terraform still reports no drift, and every signature
#     fails.
#
# So this asks the DNS system what a receiving mail server would see, rather
# than asking Terraform what it intended.
#
# Read-only. Resolves names; sends nothing.

set -euo pipefail

MAIL_DIR="${1:-infra/terraform/mail-dns}"
VARS="$MAIL_DIR/mail.tfvars"

[ -f "$VARS" ] || { echo "error: $VARS not found"; exit 1; }

hcl() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$VARS" | head -1; }

ZONE=$(hcl zone_name)
SUB=$(hcl brevo_sending_subdomain)
SEND_TARGET=$(hcl brevo_target_domain)
DKIM_TARGET=$(hcl brevo_dkim_target_domain)

[ -n "$ZONE" ] || { echo "error: could not read zone_name from $VARS"; exit 1; }

fail=0

# Resolve without depending on dig, which is not installed by default on Windows
# or in slim CI images. Cloudflare's DoH endpoint answers from the public view,
# which is the view that matters here.
resolve() {
  curl -sf -H 'accept: application/dns-json' \
    "https://cloudflare-dns.com/dns-query?name=$1&type=$2" |
    python -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('Answer', []):
    print('%d\t%s' % (a['type'], a['data'].rstrip('.')))
" 2>/dev/null || true
}

# type 5 = CNAME, 1 = A, 16 = TXT
check_cname() {
  local name="$1" want="$2" label="$3"
  local answer types
  answer=$(resolve "$name" CNAME)
  types=$(echo "$answer" | cut -f1 | sort -u | tr '\n' ' ')

  if echo "$answer" | grep -qi -- "$want"; then
    printf '  %-46s OK      -> %s\n' "$label" "$want"
  elif echo "$types" | grep -q '\b1\b'; then
    printf '  %-46s PROXIED resolves to an address, not %s\n' "$label" "$want"
    printf '  %-46s         orange-cloud this record and mail authentication fails\n' ""
    fail=1
  elif [ -z "$answer" ]; then
    printf '  %-46s MISSING no CNAME published\n' "$label"
    fail=1
  else
    printf '  %-46s WRONG   %s\n' "$label" "$(echo "$answer" | cut -f2 | tr '\n' ' ')"
    fail=1
  fi
}

check_txt() {
  local name="$1" want="$2" label="$3"
  local answer
  answer=$(resolve "$name" TXT | cut -f2)

  if echo "$answer" | grep -qi -- "$want"; then
    printf '  %-46s OK\n' "$label"
  elif [ -z "$answer" ]; then
    printf '  %-46s MISSING no TXT published\n' "$label"
    fail=1
  else
    printf '  %-46s WRONG   %s\n' "$label" "$(echo "$answer" | tr '\n' ' ')"
    fail=1
  fi
}

echo
echo "Mail deliverability records for $ZONE, as the public internet sees them"
echo

echo "Sending path"
check_cname "$SUB.$ZONE"       "$SEND_TARGET"  "$SUB.$ZONE"
check_cname "r.$SUB.$ZONE"     "r.brand"       "r.$SUB.$ZONE (click tracking)"
check_cname "img.$SUB.$ZONE"   "img.brand"     "img.$SUB.$ZONE (image tracking)"

echo
echo "Authentication"
check_cname "brevo1._domainkey.$ZONE" "b1.$DKIM_TARGET" "brevo1._domainkey (DKIM)"
check_cname "brevo2._domainkey.$ZONE" "b2.$DKIM_TARGET" "brevo2._domainkey (DKIM)"
check_txt   "_dmarc.$ZONE"            "v=DMARC1"        "_dmarc"

echo
echo "Ownership"
check_txt "$ZONE" "brevo-code:" "$ZONE (Brevo verification)"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAIL — at least one record would break delivery. Alerts will still report success."
  exit 1
fi

echo "PASS — every record resolves as intended."
echo
echo "Not covered here: whether Brevo's transactional log shows the message"
echo "DELIVERED rather than merely queued. DNS being right is necessary, not"
echo "sufficient. Send a test alert and read that log before trusting delivery."
