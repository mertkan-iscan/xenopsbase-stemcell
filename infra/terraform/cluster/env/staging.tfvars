# staging — production's shape at the smallest size that still proves it.
#
# 3 control plane nodes, because the point of staging is to exercise the same
# failure modes as prod. A single-node control plane cannot lose etcd quorum, so
# a 1-node staging would never catch a class of bug prod can hit.
environment = "staging"

cluster_name   = "xenopsbase"
network_region = "eu-central"

ssh_public_key_path  = "~/.ssh/xenopsbase_ed25519.pub"
ssh_private_key_path = "~/.ssh/xenopsbase_ed25519"

control_plane_nodepools = [
  {
    name        = "control-plane"
    server_type = "cx23"
    location    = "fsn1"
    count       = 3
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
node_transport_mode       = "tailscale"
tailscale_magicdns_domain = "tail894b71.ts.net"

# Only consulted under the hetzner_private escape hatch.
firewall_source_cidrs = []
