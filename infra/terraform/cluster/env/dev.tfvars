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
    name        = "worker"
    server_type = "cx23"
    location    = "fsn1"
    count       = 2
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
node_transport_mode       = "hetzner_private"
tailscale_magicdns_domain = "tail894b71.ts.net"

# firewall_source_cidrs is deliberately NOT set here. It is a home IP address
# and this repository is public, so it comes from TF_VAR_firewall_source_cidrs.
#
# It must be absent rather than empty: a -var-file value overrides a TF_VAR_
# environment variable, so "firewall_source_cidrs = []" here would silently beat
# the environment and trip the validation.
