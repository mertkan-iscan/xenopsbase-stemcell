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
