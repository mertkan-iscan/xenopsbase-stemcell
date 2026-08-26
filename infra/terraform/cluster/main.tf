# ==============================================================================
# K3s on Hetzner, via kube-hetzner.
#
# PREREQUISITES: TWO snapshots must already exist in the Hetzner project.
#
#   leapmicro-snapshot=yes   the base OS. bash infra/scripts/build-snapshot.sh
#   xenopsbase-golden=yes    the image autoscaled nodes boot. make golden-image
#
# The second is newer (T-1.19) and is easy to miss: `data.hcloud_image.golden`
# selects on that label, so without it `terraform plan` fails with
#
#   Resource (image) was not found using label selector: xenopsbase-golden=yes
#
# which names the selector but not the command that produces one. preflight.sh
# checks for both before any apply starts, because `make up` retries
# cluster-apply three times before giving up and a missing image is not a
# transient fault.
#
# Both survive `make down` — they are snapshots, which ADR-0008 counts as
# durable state — so on a normal rebuild they are simply already there. They
# are absent on a fresh fork, a new Hetzner project, or an account whose
# snapshots have been pruned.
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

# ------------------------------------------------------------------------------
# The image every autoscaled node boots (T-1.18, T-1.19).
#
# Selected by LABEL, not by a pinned id, and the label is the one T-1.20 only
# applies after booting a candidate and proving it works. So terraform cannot
# select an image that has not been validated -- a build that failed its boot
# test never gets `xenopsbase-golden=yes` and is deleted.
#
# most_recent because `make golden-image` produces a new one on every k3s bump
# or policy change, and pinning the id here would mean a second place to update
# and a silent divergence when it is forgotten.
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# The cluster join token (ADR-0013).
#
# A node proves it belongs by presenting this, so it is a credential and it is
# treated like one: `sensitive`, never written to a file, never a terraform
# output, and never baked into a snapshot -- the golden image asserts its own
# absence at build time (`test ! -s /var/lib/rancher/k3s/server/node-token`).
# It reaches a node once, in cloud-init, at first boot.
#
# `keepers` is deliberately empty. Rotating the token invalidates every node's
# membership at once, so it must happen when someone decides to, not because an
# unrelated attribute changed and dragged this along with it.
#
# ADR-0002 rebuilds clusters routinely and ADR-0007 restores databases into the
# rebuilt one. A token that changed per build would make the second impossible.
# ------------------------------------------------------------------------------
resource "random_password" "cluster_token" {
  length = 48

  # k3s splits the token on ':' to read the optional CA hash prefix, and the
  # bootstrap embeds it in a YAML scalar. Alphanumeric sidesteps both without
  # meaningfully costing entropy at this length.
  special = false
}

data "hcloud_image" "golden" {
  with_selector = "xenopsbase-golden=yes"
  most_recent   = true

  # Snapshots are region-scoped, and a node cannot boot an image that is not
  # where it is. Without this, a stray snapshot built elsewhere would be
  # selectable and the failure would appear at scale-up as a Hetzner error
  # about the image rather than about the region.
  with_architecture = "x86"

  # The k3s version is read off this image (see k3s_version in the module call
  # below), so an image without the label is not merely unlabelled -- it silently
  # returns the module to channel-following. Fail here, where the fix is obvious,
  # rather than at the version mismatch it would cause weeks later.
  lifecycle {
    postcondition {
      condition     = can(regex("^v[0-9]+[.][0-9]+[.][0-9]+_k3s[0-9]+$", lookup(self.labels, "k3s-version", "")))
      error_message = "golden image ${self.id} carries no usable k3s-version label. Rebuild it: make golden-image"
    }
  }
}

# ------------------------------------------------------------------------------
# The firewall an autoscaled node ends up behind (T-1.19, #251).
#
# WHY THIS IS AN ATTACHMENT AND NOT AN AUTOSCALER SETTING
#
# The obvious approach is to hand the autoscaler HCLOUD_FIREWALL, which is what
# kube-hetzner does. It cannot work here. The autoscaler's config is rendered by
# the module's own kustomization mechanism, so anything the config needs is an
# INPUT to the module -- and the firewall is created BY the module. Terraform
# rejects that outright:
#
#   Error: Cycle: ... module.kube_hetzner (close), data.hcloud_firewall.cluster,
#          module.kube_hetzner.var.user_kustomizations (expand) ...
#
# A firewall ATTACHMENT is consumed by nothing, so it may depend on the module
# freely. The cycle disappears.
#
# It is also the better design. An attachment driven by a label selector covers
# every node that ever carries the label, including ones that do not exist yet
# -- which is precisely the population an autoscaler creates. Passing an id to
# the autoscaler protects only the nodes it happens to create while that id is
# current; this protects the group.
#
# The label is set on the SERVER (Hetzner side) by the autoscaler's
# `serverLabels`, not the Kubernetes node label of the same name. They are
# deliberately spelled the same so the two views of a node agree.
# ------------------------------------------------------------------------------
# GONE: data.hcloud_firewalls.all, hcloud_firewall_attachment.autoscaled, and
# the check block that watched over them (T-1.28).
#
# The attachment existed to put autoscaled nodes behind the cluster firewall,
# because the autoscaler creates them outside terraform. It was a second owner
# of a relation every hcloud_server already declares through its own
# firewall_ids, and the last write won. Observed on a live cluster: three
# servers attached and ZERO label selectors -- the selector the attachment was
# there to apply, silently absent -- and then the destroy failed on it:
#
#   Error: firewall with ID 11522374 cannot be removed from label_selector:
#   resource not found
#
# `make down` could not get past that. It took a `terraform state rm` by hand,
# which is not a thing a teardown path should ever need.
#
# The autoscaler takes HCLOUD_FIREWALL and creates its nodes WITH the firewall
# already attached -- what the module's own autoscaler template does. That is
# one owner per relation, and it also closes the window the check block could
# only warn about: a node created before the attachment existed came up on a
# public address with nothing in front of it.
#
# The env var is set in manifests/30-cluster-autoscaler, which moved to
# bootstrap.tf so it can be handed the firewall id without a cycle.
# ------------------------------------------------------------------------------

locals {
  # The autoscaled pool. Declared in dev.tfvars like any other nodepool, but
  # handed to our own autoscaler rather than to the module -- see the
  # `autoscaler_nodepools = []` note on the module block for why.
  #
  # One pool. The Hetzner autoscaler supports several, and supporting several
  # here would mean templating a list into the config JSON for a case that does
  # not exist; `element(...)` on an empty list fails loudly at plan time, which
  # is the right moment to find out.
  autoscaler_pool       = length(var.autoscaler_nodepools) > 0 ? var.autoscaler_nodepools[0] : null
  autoscaler_node_group = local.autoscaler_pool == null ? "" : "${var.cluster_name}-${var.environment}-${local.autoscaler_pool.name}"

  # THE ENTIRE BOOTSTRAP, rendered once and used everywhere.
  #
  # base64, because the hcloud autoscaler passes `cloudInit` to the Hetzner API
  # exactly as stored, without decoding it. Established by measurement: the
  # module's value decoded to 26,499 bytes, inside the limit, and was still
  # refused -- because what went over the wire was the 35,332-character encoded
  # form. So the encoded length is the one that must fit, and it is the one
  # check-user-data-size.sh measures.
  # RENDERED PER NODE GROUP, not once (T-1.23, #282).
  #
  # It was a single string while the autoscaled pool was the only thing that
  # used it. Static agents now boot the same file, and the one value that
  # differs is `node_group` -- which the autoscaler matches on to decide whether
  # a node is one of its own. Rendering once and reusing the string would label
  # every static agent as a member of the autoscaled pool, and the autoscaler
  # would then consider deleting them when it scaled down.
  #
  # A MAP, not a list of names, since the pools carry more than a name.
  # `labels` and `taints` were declared on agent_nodepools, honoured by the
  # module, and then silently dropped when #282 stopped handing it the pools --
  # no error, no plan diff, the node simply came up without them. They are
  # Kubernetes-level facts, so the bootstrap is where they belong now: they go
  # into /etc/rancher/k3s/config.yaml, which is the same place the module put
  # them.
  #
  # The autoscaled pool has neither, and its variable never offered them. It is
  # given empty lists rather than a special case in the template.
  node_groups = merge(
    local.autoscaler_pool == null ? {} : {
      (local.autoscaler_node_group) = { labels = [], taints = [] }
    },
    {
      for p in var.agent_nodepools :
      "${var.cluster_name}-${var.environment}-${p.name}" => {
        labels = p.labels
        taints = p.taints
      }
    },
  )

  node_bootstrap_documented = {
    for g, cfg in local.node_groups : g => templatefile("${path.module}/templates/node-bootstrap.yaml.tpl", {
      server_url         = module.kube_hetzner.effective_node_join_endpoint
      cluster_token      = random_password.cluster_token.result
      tailscale_auth_key = var.tailscale_auth_key
      node_group         = g

      # Rendered here rather than with a template directive, because the
      # comment stripper below works line by line and a `%{ for }` block would
      # have to survive it. Pre-joined YAML is one interpolation and cannot be
      # broken by stripping.
      #
      # Empty renders as an empty string, which the stripper then removes along
      # with the blank lines -- so a pool with no labels costs zero bytes
      # against the 2 KB budget, and `make user-data-size` stays the gate.
      extra_node_labels = join("\n", [for l in cfg.labels : "      - \"${l}\""])

      # `[]` inline when there are none, a block list when there are. k3s
      # accepts both; the inline form is what a node without taints has always
      # had, and keeping it means this change is a no-op in every existing
      # environment.
      node_taints = length(cfg.taints) == 0 ? " []" : "\n${join("\n", [for t in cfg.taints : "      - \"${t}\""])}"
    })
  }

  # COMMENTS AND BLANK LINES ARE STRIPPED BEFORE THIS GOES ON THE WIRE.
  #
  # The template is heavily commented, because a boot path nobody can read is
  # how #22 stayed invisible for months. But every one of those bytes would
  # otherwise be shipped to every node, on every scale-up, for ever -- measured
  # at 6,028 bytes encoded, against a 2,048-byte budget. The documentation was
  # three quarters of the payload.
  #
  # So the comments live in the repository, where they are read, and not in
  # user_data, where they are merely carried. `#cloud-config` is kept: it is not
  # a comment, it is the header cloud-init dispatches on, and dropping it turns
  # the whole file into an inert blob that boots a node doing nothing at all.
  node_bootstrap = {
    for g, documented in local.node_bootstrap_documented : g => join("\n", concat(
      ["#cloud-config"],
      [
        for line in split("\n", documented) :
        line
        if trimspace(line) != "" && !startswith(trimspace(line), "#")
      ]
    ))
  }

  node_bootstrap_b64 = { for g, stripped in local.node_bootstrap : g => base64encode(stripped) }
}

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
  # VERIFIED on a live cluster, 2026-08-21, by building dev from nothing with
  # node_transport_mode = "tailscale". The control plane cleared
  # node.cloudprovider.kubernetes.io/uninitialized within ~90s of the CCM
  # starting, and the CCM assigned providerID hcloud://163008021 and an
  # ExternalIP -- which it can only do for a node it has matched. Confirmed the
  # mechanism rather than the outcome: HCLOUD_NETWORK was present on the
  # deployment, sourced from the hcloud secret's `network` key, and
  # HCLOUD_NETWORK_ROUTES_ENABLED stayed false.
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

  # OURS, not the module's (ADR-0013).
  #
  # Left unset, the module derives a token and every node that needs it reads
  # it back as `module.kube_hetzner.cluster_token` -- which places anything
  # holding that reference behind the whole module, including the platform
  # bootstrap it runs at the end. That ordering is what both T-1.23 builds
  # died of.
  #
  # Generating it here removes one of the two module references in agents.tf.
  # The other is the join endpoint, which cannot move yet: under tailscale
  # transport the module resolves it to the first control plane's private
  # address and offers no way to supply one (locals.tf:121, and the ADR's
  # deferral note). So this does not make agents concurrent on its own, and
  # is not claimed to.
  #
  # It also makes a restore possible. The module's token exists only inside a
  # cluster; recreating one to match, which is what "must match when restoring
  # a cluster" in its own variable description requires, meant reading it out
  # of the cluster being replaced. Now it is state, and it survives the thing
  # it unlocks.
  cluster_token = random_password.cluster_token.result

  cluster_name   = "${var.cluster_name}-${var.environment}"
  network_region = var.network_region

  ssh_public_key  = file(pathexpand(var.ssh_public_key_path))
  ssh_private_key = file(pathexpand(var.ssh_private_key_path))

  control_plane_nodepools = var.control_plane_nodepools

  # DELIBERATELY EMPTY, like autoscaler_nodepools below and for the same reason
  # (T-1.23, #282). The pool is still declared in the tfvars and is still read
  # -- by agents.tf, which creates the servers directly from the golden image.
  #
  # Given a pool, the module generates cloud-init that downloads and installs
  # k3s at boot, over the pinned copy the image already carries. No variable
  # skips it, so the only way to have one bootstrap path is for the module not
  # to build the other one.
  agent_nodepools = []

  # DELIBERATELY EMPTY, even though var.autoscaler_nodepools is not (T-1.19).
  #
  # Given a pool, the module deploys its own cluster-autoscaler and generates
  # the cloud-init it hands to Hetzner: a verified installer that downloads k3s,
  # base64 inside base64 inside gzip. Measured on this cluster, 35,332 bytes
  # against a 32,768-byte user_data limit -- so every scale-up got as far as the
  # API call and was refused (#22):
  #
  #   could not create server type cx33 in region fsn1:
  #   invalid input in field 'user_data' (invalid_input)
  #
  # Passing [] stops the module building any of that. The autoscaler, its RBAC
  # and the node definition are ours, in manifests/30-cluster-autoscaler, where
  # the bootstrap is ~1KB because everything static now lives in the golden
  # image (T-1.18).
  #
  # The pool is still DECLARED in dev.tfvars and still read below -- this is
  # not "autoscaling off", it is "the module does not get to define a node".
  autoscaler_nodepools = []

  # The exact k3s the fixed nodes install, taken from the golden image rather
  # than written here (T-1.18).
  #
  # Unset, the module follows k3s_channel, which defaults to "stable". At module
  # 3.1.0 that resolves to v1.36.3+k3s1 -- the same release the image carries --
  # so the two agree today by coincidence and not by anything holding them
  # together. A module bump changes what "stable" means, and the cluster then
  # runs one k3s on its fixed nodes and another on its autoscaled ones, split by
  # node class. That is the mismatch infra/packer/versions.pkrvars.hcl warns
  # about, and until now nothing enforced it: that file says terraform reads the
  # versions back from the snapshot labels, and terraform did not.
  #
  # READ, not repeated. versions.pkrvars.hcl is the single place the version is
  # chosen; a literal here would be a second place to update and a silent
  # divergence the first time someone bumps one and not the other. Hetzner label
  # values reject "+", so the build stores v1.36.3_k3s1 and it converts back.
  #
  # k3s_version supersedes k3s_channel, so the channel default is now moot.
  k3s_version = replace(data.hcloud_image.golden.labels["k3s-version"], "_", "+")

  # DELIBERATELY NOT SET: allow_scheduling_on_control_plane (T-1.23, #282).
  #
  # Setting it false looks like the fix for the control plane carrying the
  # whole platform. It is not, and it reads as though it were, which is worse
  # than leaving it out. The module resolves it as
  #
  #   is_single_node_cluster ? true : var.allow_scheduling_on_control_plane
  #
  # and is_single_node_cluster sums the control-plane, agent and autoscaler
  # counts. Both other pools are [] here, so on dev the sum is 1, the first arm
  # always wins, and the variable is never read. Confirmed on a live build:
  # `node-taint: []` in the control plane's config with the value set to false.
  #
  # The module's own default is false as well, so the line changed nothing in
  # any environment.
  #
  # The real problem is ordering, not this flag: the module deploys the
  # platform before terraform can create an agent for it to land on. That is
  # #287, and nothing in this file fixes it.

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
  # EMPTY (ADR-0014, T-1.28). The module provisions machines and nothing above
  # them; every kustomization now lives in bootstrap.tf.
  #
  # Stages 1 and 2 -- Argo CD and the root Application -- moved because they ran
  # before terraform could create an agent, so the whole platform scheduled onto
  # a cx23. Build 3: 12/14 applications Healthy, held ~400s, collapsed to 0/0.
  #
  # Stage 3, the autoscaler's node definition, followed for a different reason.
  # It needs the cluster firewall's id, so that autoscaled nodes are created
  # WITH the firewall rather than attached to it afterwards -- and the firewall
  # is created by this module, so a stage inside the module cannot be given it
  # without a cycle. Outside, `data.hcloud_firewalls.after_cluster` reads it
  # cleanly.
  user_kustomizations = {}

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
