# dev — the cheapest cluster that works.
#
# One control plane node, no HA. That is the correct trade here, not a
# compromise: dev is destroyed between working sessions, so an hour of downtime
# has no consumer to inconvenience. Paying for HA on something torn down nightly
# buys availability nobody uses.
environment = "dev"

cluster_name   = "xenopsbase"
network_region = "eu-central"

ssh_public_key_path  = "~/.ssh/xenopsbase_ed25519.pub"
ssh_private_key_path = "~/.ssh/xenopsbase_ed25519"

control_plane_nodepools = [
  {
    name        = "control-plane"
    server_type = "cx23"
    location    = "fsn1"
    count       = 1
  }
]

agent_nodepools = [
  {
    name = "worker"
    # cx33 (8Gi) rather than cx23 (4Gi). Two cx23 workers could not carry the
    # platform: memory hit 93% on one node and Argo's repo-server began failing
    # its probes, so committed changes silently stopped arriving (T-1.12, #133).
    #
    # That is the failure worth paying to avoid. It does not present as "out of
    # memory" -- it presents as a fix not working, three layers from the cause.
    #
    # The cost is about a cent an hour more for the pair, and the cluster is
    # destroyed between sessions, so the monthly figure is not what is paid.
    server_type = "cx33"
    location    = "fsn1"
    count       = 2

    # Required once node_transport_mode is "tailscale", and rejected at plan time
    # if absent. "primary" means this pool sits on the cluster's own Hetzner
    # network rather than an external one -- which is also what makes restoring
    # the CCM's network awareness sound (see main.tf).
    #
    # Harmless under the hetzner_private escape hatch: the module ignores it.
    network_scope = "primary"
  }
]

autoscaler_nodepools = []

cni_plugin          = "flannel"
ingress_controller  = "none"
enable_cert_manager = false
load_balancer_type  = "lb11"

# Network exposure (ADR-0006). Public Kubernetes API and SSH are closed;
# Terraform and kubectl reach the cluster over the tailnet.
#
# TF_VAR_tailscale_auth_key must be set, and must be a REUSABLE key.
#
# This was pinned to "hetzner_private" as an escape hatch while the CCM failure
# under tailscale was unexplained (#11). The cause is now identified and the fix
# is in main.tf, so the hatch is closed.
#
# It can only be changed on a cluster that is being built from nothing. Flipping
# it on a RUNNING cluster does not work and is not recoverable in place: the
# firewall rules are replaced immediately -- closing 22 and 6443 -- while the
# servers are not, so no node ever joins the tailnet and there is no longer any
# path to the ones that are running.
node_transport_mode       = "tailscale"
tailscale_magicdns_domain = "tail894b71.ts.net"

# firewall_source_cidrs is deliberately NOT set here. It is a home IP address
# and this repository is public, so it comes from TF_VAR_firewall_source_cidrs.
#
# It must be absent rather than empty: a -var-file value overrides a TF_VAR_
# environment variable, so "firewall_source_cidrs = []" here would silently beat
# the environment and trip the validation.

# cloudflared reaches Cloudflare's edge over QUIC on UDP 7844.
#
# The module's default outbound rules allow 80, 443, DNS, NTP and ICMP -- and on
# Hetzner, defining ANY outbound rule denies everything not listed. So QUIC is
# blocked, and the failure is not obviously a firewall one:
#
#   Failed to dial a quic connection: timeout: no recent network activity
#
# cloudflared retries forever with backoff, so the pods sit Running but never
# Ready and the site simply never comes up.
#
# TCP 7844 is the documented fallback path; allowing both means a QUIC problem
# degrades to http2 rather than to an outage.
extra_firewall_rules = [
  {
    description     = "cloudflared tunnel (QUIC)"
    direction       = "out"
    protocol        = "udp"
    port            = "7844"
    destination_ips = ["0.0.0.0/0", "::/0"]
  },
  {
    description     = "cloudflared tunnel (http2 fallback)"
    direction       = "out"
    protocol        = "tcp"
    port            = "7844"
    destination_ips = ["0.0.0.0/0", "::/0"]
  },

  # SMTP submission, so Alertmanager can actually deliver.
  #
  # Same trap as the QUIC rules above. Alerts were generated, grouped and routed
  # correctly, then failed at the final hop:
  #
  #   dial tcp 172.246.243.66:587: connect: connection timed out
  #
  # Alertmanager records that in its own log and nowhere else, so the pipeline
  # looked healthy end to end while delivering nothing -- which is precisely the
  # class of failure the pipeline exists to catch.
  #
  # 587 (submission with STARTTLS), not 25: Hetzner blocks outbound 25 outright
  # as an anti-spam measure, and transactional relays expect 587 regardless.
  {
    description     = "SMTP submission for alert delivery"
    direction       = "out"
    protocol        = "tcp"
    port            = "587"
    destination_ips = ["0.0.0.0/0", "::/0"]
  },
]
