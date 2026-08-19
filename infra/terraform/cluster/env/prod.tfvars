# prod — 3 control plane nodes, larger workers.
#
# 3 is the smallest genuinely HA number. Never 2: etcd needs a quorum of more
# than half, so two nodes tolerate zero failures while costing twice as much,
# which is strictly worse than one. The variable validation rejects even totals.
environment = "prod"

cluster_name   = "xenopsbase"
network_region = "eu-central"

ssh_public_key_path  = "~/.ssh/xenopsbase_ed25519.pub"
ssh_private_key_path = "~/.ssh/xenopsbase_ed25519"

control_plane_nodepools = [
  {
    name        = "control-plane"
    server_type = "cx33"
    location    = "fsn1"
    count       = 3
  }
]

agent_nodepools = [
  {
    name        = "worker"
    server_type = "cx43"
    location    = "fsn1"
    count       = 3
  }
]

# Sized by T-2.8 against the load profile from T-5.6, not by guesswork here.
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
