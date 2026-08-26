# ==============================================================================
# STATIC AGENTS, PROVISIONED HERE RATHER THAN BY THE MODULE (T-1.23, #282)
#
# #251 put autoscaled nodes on the golden image with a 1,444-byte bootstrap and
# left static agents on kube-hetzner's cloud-init, which downloads and installs
# k3s at every boot. Two bootstrap paths that must stay equivalent, with nothing
# structural keeping them so -- `make node-equivalence` compares them, but a
# check that only runs when someone runs it is not a guarantee.
#
# WHY THE POOL COULD NOT SIMPLY BE POINTED AT THE IMAGE
#
# The module installs k3s unconditionally. `install-verified-kubernetes.sh`
# downloads the release payload and then:
#
#   install -o root -g root -m 0755 "$payload" /usr/local/bin/k3s
#
# with no check for a binary that is already there. So an agent nodepool given
# the golden image via a snapshot id downloads k3s and installs it OVER the
# pinned copy the image carries -- slower than before, and no longer the version
# the image was tested with. There is no module variable that skips it.
#
# Converting static agents therefore means not using the module for them.
# ==============================================================================

locals {
  # Every static agent as its own server, flattened out of the pools.
  #
  # The key is stable across a rebuild and does not contain the index alone:
  # `for_each` on a map means removing pool A does not renumber pool B's
  # servers, which a `count` over a flattened list would.
  static_agents = merge([
    for pool in var.agent_nodepools : {
      for i in range(pool.count) :
      "${pool.name}-${i}" => {
        name        = "${var.cluster_name}-${var.environment}-${pool.name}-${i}"
        server_type = pool.server_type
        location    = pool.location
        node_group  = "${var.cluster_name}-${var.environment}-${pool.name}"
      }
    }
  ]...)
}

# ------------------------------------------------------------------------------
# The firewall, read a SECOND time and deliberately so.
#
# `data.hcloud_firewalls.all` in main.tf is read at plan time with no
# depends_on, because `hcloud_firewall_attachment.autoscaled` needs its id
# during plan for a count. On a COLD build the firewall does not exist yet, so
# that read returns nothing -- correct there, because the autoscaled pool starts
# at zero nodes and there is nothing unprotected in the window.
#
# That reasoning does not transfer here. A static agent is created BY the cold
# build, with a public IPv4, and one that comes up outside the firewall is
# exposed from the moment it boots. So this read is ordered after the module
# that creates the firewall. The id is then unknown at plan time, which is fine
# for a server argument and would not have been for a count.
# ------------------------------------------------------------------------------
data "hcloud_firewalls" "after_cluster" {
  depends_on = [module.kube_hetzner]
}

locals {
  static_agent_firewall_id = one([
    for f in data.hcloud_firewalls.after_cluster.firewalls :
    f.id if f.name == "${var.cluster_name}-${var.environment}"
  ])
}

# ------------------------------------------------------------------------------
# Spread, so the pool survives a single Hetzner host failing. This is what the
# module created per nodepool and it does not stop being necessary because the
# servers moved.
#
# Hetzner caps a placement group at 10 servers. dev has 2 and prod has 3, so the
# ceiling is distant, but a pool that silently exceeded it would fail at server
# creation rather than here.
# ------------------------------------------------------------------------------
resource "hcloud_placement_group" "static_agents" {
  count = length(local.static_agents) > 0 ? 1 : 0

  name   = "${var.cluster_name}-${var.environment}-agents"
  type   = "spread"
  labels = { cluster = "${var.cluster_name}-${var.environment}" }

  lifecycle {
    precondition {
      condition     = length(local.static_agents) <= 10
      error_message = "Hetzner allows at most 10 servers in a placement group; agent_nodepools declare ${length(local.static_agents)}."
    }
  }
}

resource "hcloud_server" "static_agent" {
  for_each = local.static_agents

  name        = each.value.name
  server_type = each.value.server_type
  location    = each.value.location

  # The same image the autoscaled nodes boot, selected by the same validated
  # label. One image, one k3s, one SELinux policy -- which is the point of the
  # card. `data.hcloud_image.golden` also carries the k3s-version label that
  # pins the module's own install, so the two cannot drift apart silently.
  image = data.hcloud_image.golden.id

  ssh_keys           = [module.kube_hetzner.ssh_key_id]
  placement_group_id = hcloud_placement_group.static_agents[0].id

  # Never null in practice -- the module creates the firewall in the same apply
  # and the data source above is ordered behind it -- but an empty list is a
  # node on a public address with nothing in front of it, so it fails instead.
  firewall_ids = [local.static_agent_firewall_id]

  # Matches how the autoscaler labels its nodes (`serverLabels` in
  # manifests/30-cluster-autoscaler/config.yaml.tpl) and how the bootstrap
  # labels the Kubernetes node. The three spellings agree on purpose: it is how
  # a server, a node and a scaling group can be told to be the same thing.
  labels = {
    "cluster"           = "${var.cluster_name}-${var.environment}"
    "hcloud/node-group" = each.value.node_group
  }

  # The decoded form. `user_data` is base64-encoded by the provider on the way
  # out, unlike the autoscaler's `cloudInit`, which is stored already-encoded
  # and passed through untouched -- the asymmetry that made #22 invisible.
  user_data = local.node_bootstrap[each.value.node_group]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  # ATTACHED HERE, NOT BY A SEPARATE RESOURCE (T-1.23, #282).
  #
  # It was an `hcloud_server_network`, which attaches AFTER the server boots.
  # The bootstrap reads node-ip off eth1, so a node that boots before the
  # attachment lands writes:
  #
  #   "node-ip": ""
  #   Error: failed to get node name and addresses: invalid node-ip: invalid ip format ''
  #
  # and k3s then refuses that config forever -- 19 restarts, no join, while the
  # interface it was waiting for is present the whole time you are looking at it.
  #
  # A race, so it presents as one node joining and the other not, differently
  # each build. It cost build 1 its second worker, was misread there as API
  # overload, and cost build 4 the same way before the cause was found.
  #
  # The module attaches at creation and the autoscaler is handed HCLOUD_NETWORK
  # at creation. This is the same, and it is why neither of them has this bug.
  network {
    network_id = module.kube_hetzner.network_id
  }

  lifecycle {
    # The image moves on every `make golden-image`, and a new snapshot id would
    # otherwise replace every running agent on the next apply -- an unplanned
    # rolling reboot of the whole worker pool, triggered by an unrelated build.
    # Rolling onto a new image is T-7.9 (#254) and is a deliberate operation.
    ignore_changes = [image]
  }
}

# The separate hcloud_server_network is gone: it is what created the race above,
# and the provider treats an inline `network` block and a standalone attachment
# for the same pair as conflicting owners anyway.
