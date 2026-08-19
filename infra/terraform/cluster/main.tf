# ==============================================================================
# K3s on Hetzner, via kube-hetzner.
#
# PREREQUISITE: an OS snapshot must already exist in the Hetzner project.
#
# kube-hetzner 3.1.0 defaults new node pools to Leap Micro, so the snapshot must
# carry leapmicro-snapshot=yes, NOT the microos-snapshot=yes that most tutorials
# still reference. A MicroOS snapshot is simply never looked for, and the
# resulting failure does not say which OS was expected. Build it with:
#
#   bash infra/scripts/build-snapshot.sh
#
# The snapshot is NOT created by Terraform and is NOT destroyed by `make down`.
# It is durable state in the sense of ADR-0002 — the same category as container
# images — and rebuilding it is the slowest part of a genuinely cold start.
# See docs/runbooks/cluster.md.
# ==============================================================================

locals {
  # Kept in a local because HCL does not allow a heredoc inside a conditional
  # expression.
  ccm_disable_attached_check_values = <<-EOT
    env:
      HCLOUD_NETWORK_DISABLE_ATTACHED_CHECK:
        value: "true"
  EOT

  hetzner_ccm_values = var.ccm_disable_network_attached_check ? local.ccm_disable_attached_check_values : ""
}

module "kube_hetzner" {
  source = "kube-hetzner/kube-hetzner/hcloud"

  # Pinned exactly. This module provisions the entire cluster, and a floating
  # version means a rebuild can differ from the last one for reasons nobody
  # chose — which would break the central promise of ADR-0002, that a rebuild
  # reproduces what was there before. Upgrade procedure: docs/runbooks/cluster.md.
  version = "3.1.0"

  providers = {
    hcloud = hcloud
  }

  hcloud_token = var.hcloud_token

  cluster_name   = "${var.cluster_name}-${var.environment}"
  network_region = var.network_region

  ssh_public_key  = file(pathexpand(var.ssh_public_key_path))
  ssh_private_key = file(pathexpand(var.ssh_private_key_path))

  control_plane_nodepools = var.control_plane_nodepools
  agent_nodepools         = var.agent_nodepools
  autoscaler_nodepools    = var.autoscaler_nodepools

  cni_plugin = var.cni_plugin

  # hcloud CCM and CSI are installed by the module. CSI is what makes a PVC
  # provision a real Hetzner volume, which the platform needs for Postgres
  # (T-2.4) even though that data is continuously archived out to object
  # storage — the volume is a working disk, not the durable copy.
  enable_hetzner_csi = true

  # Both deliberately off. ADR-0004 makes Argo CD the single owner of everything
  # above the cluster; letting kube-hetzner also install these produces drift
  # with two owners and no clear winner. T-2.2 installs them through GitOps.
  ingress_controller  = var.ingress_controller
  enable_cert_manager = var.enable_cert_manager

  load_balancer_type = var.load_balancer_type

  extra_firewall_rules = var.extra_firewall_rules

  # MERGE, not replace. The module offers both:
  #
  #   hetzner_ccm_values        replaces the default values outright
  #   hetzner_ccm_merge_values  merges with them, ours winning on conflict
  #
  # Using the first one silently dropped every env var the module sets --
  # including HCLOUD_NETWORK, without which the CCM cannot match the private
  # address the kubelet reports and refuses to initialise the node. The symptom
  # was identical to the bug this is meant to fix, which made the regression
  # look like the fix not working.
  hetzner_ccm_merge_values = local.hetzner_ccm_values

  # ----------------------------------------------------------------------------
  # Network exposure (ADR-0006)
  #
  # Under tailscale, the public Kubernetes API and SSH are closed outright:
  # null, not a narrow allowlist. Nodes keep public IPs -- the module needs them
  # for Tailscale bootstrap and direct WireGuard paths -- but the firewall
  # answers nothing on them. A public IP is not a public API.
  #
  # Under the hetzner_private escape hatch, both are restricted to
  # firewall_source_cidrs instead. A validation below refuses to leave them open.
  # ----------------------------------------------------------------------------
  node_transport_mode = var.node_transport_mode

  firewall_kube_api_source = var.node_transport_mode == "tailscale" ? null : var.firewall_source_cidrs
  firewall_ssh_source      = var.node_transport_mode == "tailscale" ? null : var.firewall_source_cidrs

  tailscale_auth_key = var.node_transport_mode == "tailscale" ? var.tailscale_auth_key : null

  # Passed unconditionally: the module ignores it unless node_transport_mode is
  # "tailscale". A conditional here would need both branches to have identical
  # object shapes, which buys nothing.
  tailscale_node_transport = {
    # cloud_init, NOT remote_exec. remote_exec has Terraform SSH in over the
    # public IP to install Tailscale, which would require public SSH open during
    # provisioning and defeat the entire point. cloud_init installs it at first
    # boot, so the node is already on the tailnet before Terraform needs it.
    bootstrap_mode  = "cloud_init"
    magicdns_domain = var.tailscale_magicdns_domain

    auth = {
      mode = "auth_key"
    }

    routing = {
      # MUST stay true, which is also the module default. Do not "optimise" this
      # to false for a single-network cluster, however tempting the comment in
      # kube.tf.example makes it sound.
      #
      # Setting it false does more than skip Tailnet route approvals: it also
      # turns off the Hetzner network routing the cloud controller manager
      # depends on. The CCM deployment then comes up with
      # HCLOUD_NETWORK_ROUTES_ENABLED=false and no HCLOUD_NETWORK at all, so it
      # cannot match the private address the kubelet reports and refuses to
      # initialise the node:
      #
      #   failed to get node address from cloud provider that matches ip: 10.255.0.1
      #
      # The node then keeps its node.cloudprovider.kubernetes.io/uninitialized
      # taint forever, nothing can schedule, system-upgrade-controller never
      # becomes available, the kustomization step times out after 15 minutes,
      # and the agents' k3s install never runs -- so the workers sit on the
      # tailnet having never joined Kubernetes.
      #
      # Four steps between cause and symptom, none of which mention routing.
      # Verified the hard way on 2026-08-19.
      advertise_node_private_routes = true
    }
  }

  # Do not write a kubeconfig to disk automatically. It is a credential with
  # cluster-admin, and a file that appears next to the Terraform code is a file
  # that eventually gets committed. Retrieved explicitly instead:
  #
  #   terraform output -raw kubeconfig > kubeconfig   # gitignored
  create_kubeconfig = false

  # Also deliberately off: kube-hetzner can back etcd up to S3. In this design
  # the cluster is disposable and holds nothing worth restoring — Postgres
  # archives itself to object storage (T-2.4) and every manifest lives in git.
  # An etcd backup would restore a cluster we would rather rebuild, and would
  # quietly become durable state that ADR-0002 does not account for.
}
