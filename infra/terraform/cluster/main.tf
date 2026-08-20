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
  # Pins the metadata route onto the public NIC at every boot, as a unit rather
  # than a one-off command: the bad route is reinstalled by DHCP, so a route
  # added once does not survive a reboot or a lease renewal.
  metadata_route_unit = <<-EOT
    cat > /etc/systemd/system/hcloud-metadata-route.service <<'UNIT'
    [Unit]
    Description=Pin the Hetzner metadata route to the public interface
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    # Guarded: on a node with no public interface this is a no-op rather than a
    # boot failure.
    ExecStart=/bin/sh -c 'ip link show eth0 >/dev/null 2>&1 && ip route replace 169.254.169.254/32 dev eth0 || true'

    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now hcloud-metadata-route.service
  EOT

  # Kept in a local because HCL does not allow a heredoc inside a conditional
  # expression.
  ccm_disable_attached_check_values = <<-EOT
    env:
      HCLOUD_NETWORK_DISABLE_ATTACHED_CHECK:
        value: "true"
  EOT

  # ----------------------------------------------------------------------------
  # Restores the CCM's network awareness under tailscale (T-1.5, ADR-0006).
  #
  # UNVERIFIED against a live cluster. Reasoning and evidence below; the apply
  # that would settle it has not been run. Treat as a hypothesis with a citation,
  # not as a fix.
  #
  # kube-hetzner v3.1.0 gates two things on two DIFFERENT conditions:
  #
  #   node-ip           multinetwork_overlay_enabled      agents.tf:146, 172
  #                                                       control_planes.tf:382, 441
  #                                                       init.tf:112, 281
  #   CCM networking    cross_network_transport_enabled   locals.tf:2220
  #
  # and cross_network_transport_enabled = multinetwork_overlay_enabled
  #                                       || node_transport_tailscale_enabled.
  #
  # With tailscale alone the two disagree. k3s keeps advertising the PRIVATE
  # address, because the overlay flag is false -- while the CCM is rendered with
  # networking.enabled: false, so the chart omits HCLOUD_NETWORK entirely and the
  # CCM knows only public addresses for that server. It cannot match the node,
  # so it never removes the uninitialized taint. Nothing schedules, and the
  # agents' k3s install never runs.
  #
  # In the multinetwork case the module is consistent: node-ip switches to the
  # public address, which a network-less CCM can match. Tailscale gets the
  # networking half of that change without the addressing half.
  #
  # Re-enabling networking is safe HERE specifically because this cluster has one
  # primary network and no external nodepools -- autoscaler_nodepools is empty --
  # which is the case the module disabled it to protect. The `network` key the
  # chart reads is written to the hcloud secret unconditionally, regardless of
  # transport (locals.tf:252), so HCLOUD_NETWORK resolves.
  #
  # Routes stay off: the module sets HCLOUD_NETWORK_ROUTES_ENABLED=false under
  # cross-network transport and that is correct here. flannel's vxlan backend
  # carries pod traffic itself, so Hetzner network routes are redundant. The aim
  # is "know the network, do not manage routes" -- knowing it is what clears the
  # taint.
  # ----------------------------------------------------------------------------
  ccm_tailscale_networking_values = <<-EOT
    networking:
      enabled: true
      clusterCIDR: "${var.cluster_ipv4_cidr}"
  EOT

  hetzner_ccm_values = format(
    "%s%s",
    var.ccm_disable_network_attached_check ? local.ccm_disable_attached_check_values : "",
    var.node_transport_mode == "tailscale" && var.ccm_restore_networking_under_tailscale ? local.ccm_tailscale_networking_values : "",
  )

  # Pre-creates the directory the module uploads its per-set apply options into.
  #
  # The module runs its user_kustomization_set instances in PARALLEL (for_each),
  # and each one does `mkdir -p` then uploads a file into that directory. When
  # the upload wins the race, scp creates the PARENT PATH AS A FILE, and the
  # deploy step then dies with:
  #
  #   /var/user_kustomize/.kube-hetzner-apply-options/1.sh: Not a directory
  #
  # Hit on both rebuilds so far, so it is frequent rather than unlucky. It is
  # also unrecoverable in place: the file has to be removed and the uploads
  # re-run with -replace, because Terraform believes it already sent them.
  #
  # Creating the directory before any upload happens removes the race entirely.
  # Harmless if the module gets fixed upstream -- mkdir -p on an existing
  # directory is a no-op.
  kustomize_options_dir = "mkdir -p /var/user_kustomize/.kube-hetzner-apply-options"
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

  # Runs on every node before k3s installs, so the metadata service is reachable
  # by the time the CCM and CSI driver start. See the variable for why this is
  # not optional in practice.
  preinstall_exec = concat(
    [local.kustomize_options_dir],
    var.pin_metadata_route_to_public_nic ? [local.metadata_route_unit] : [],
  )

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

  # ----------------------------------------------------------------------------
  # GitOps bootstrap (ADR-0004, T-2.1)
  #
  # Applied by the module during this same terraform apply, so the cluster goes
  # from nothing to reconciling in one step. Two sets, because ordering matters:
  # the root Application is an argoproj.io CRD, which does not exist until Argo
  # CD has installed. Applying both at once fails on a missing resource type.
  # ----------------------------------------------------------------------------
  user_kustomizations = {
    "1" = {
      source_folder = "${path.module}/manifests/10-argocd"
      kustomize_parameters = {
        argocd_chart_version = var.argocd_chart_version
        argocd_domain        = var.argocd_domain
        ksops_version        = var.ksops_version
        # Indented to sit under the YAML block scalar in the Secret template.
        sops_age_key = indent(4, var.sops_age_key)
      }
      # The rendered Secret contains the age private key in cleartext. Once
      # applied it is in etcd, where it has to be; leaving a copy on the node's
      # filesystem as well is gratuitous, and that copy outlives the apply.
      post_commands = "shred -u /var/user_kustomize/1/sops-age-secret.yaml 2>/dev/null || rm -f /var/user_kustomize/1/sops-age-secret.yaml"
    }
    "2" = {
      source_folder = "${path.module}/manifests/20-root-app"
      kustomize_parameters = {
        platform_repo_url      = var.platform_repo_url
        platform_repo_revision = var.platform_repo_revision
        platform_path          = "platform/envs/${var.environment}"
      }
      # k3s installs the chart asynchronously, so the CRD appears some time
      # after set 1 is applied.
      #
      # `kubectl wait` alone is NOT enough: it errors immediately when the
      # object does not exist yet, rather than waiting for it to appear. So the
      # first loop waits for existence, and only then does wait block on the
      # condition. Getting this wrong fails with
      #
      #   Error from server (NotFound): customresourcedefinitions ...
      #     "applications.argoproj.io" not found
      #
      # which reads like the chart is broken rather than like a race.
      pre_commands = <<-EOT
        for i in $(seq 1 60); do
          kubectl get crd applications.argoproj.io >/dev/null 2>&1 && break
          echo "waiting for the Argo CD CRDs to appear ($i/60)"
          sleep 5
        done
        kubectl wait --for=condition=established --timeout=120s crd/applications.argoproj.io
      EOT
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
