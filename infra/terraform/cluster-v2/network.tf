# ==============================================================================
# THE FOUNDATION, AND THE REASON THIS DIRECTORY EXISTS (T-1.26, #287)
#
# Everything here is created before any server, and every address in it is
# chosen rather than assigned. That is the whole difference from cluster/.
#
# In cluster/ the network belongs to kube-hetzner, `control_planes.tf:88` sets
# `private_ipv4 = null`, and the join endpoint resolves to whatever address
# Hetzner handed the first control plane (`locals.tf:121`). Nothing can know
# that value until the control plane exists, so every agent waits for the whole
# module -- including the platform bootstrap it runs at the end. Two builds died
# of that ordering and a third survived it on timing.
#
# Here the endpoint is a constant. Agents and control planes are created in the
# same wave because neither needs anything the other produces.
# ==============================================================================

resource "hcloud_network" "cluster" {
  name     = local.cluster
  ip_range = var.network_ipv4_cidr
  labels   = local.labels
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = var.network_region
  ip_range     = var.node_ipv4_cidr
}

locals {
  # EVERY NODE'S PRIVATE ADDRESS, DECIDED HERE.
  #
  # Reserved by role and spaced, so a pool can grow without renumbering its
  # neighbours -- renumbering a node means replacing it, and replacing a control
  # plane means replacing the endpoint every other node was told about.
  #
  #   .10 - .19   control plane
  #   .20 - .49   static agents
  #   .50 +       autoscaled, assigned by Hetzner from the top of the subnet
  #
  # Deliberately not starting at .1. That is what Hetzner hands out first, so
  # leaving it free keeps a hand-attached server from colliding with a node.
  control_plane_ips = [
    for i in range(var.control_plane_count) : cidrhost(var.node_ipv4_cidr, 10 + i)
  ]

  agent_ips = {
    for i, name in local.agent_names : name => cidrhost(var.node_ipv4_cidr, 20 + i)
  }

  # THE ENDPOINT. A literal, known before terraform creates anything, which is
  # the property ADR-0013 could not have in cluster/.
  #
  # The first control plane rather than a load balancer: under this project's
  # transport the agents reach it over the private network, and a Hetzner LB in
  # front of a single-node control plane would bill monthly to add a hop. When
  # the control plane becomes HA (staging, prod) this is where the LB goes, and
  # the value every node was given does not have to change -- which is the
  # reason it is a local rather than inlined.
  api_endpoint = "https://${local.control_plane_ips[0]}:${var.kubernetes_api_port}"
}

# ------------------------------------------------------------------------------
# One key, ours. In cluster/ this is module.kube_hetzner.ssh_key_id, which is
# one of the three references that keep agents behind the module.
# ------------------------------------------------------------------------------
resource "hcloud_ssh_key" "cluster" {
  name       = local.cluster
  public_key = file(pathexpand(var.ssh_public_key_path))
  labels     = local.labels
}

# ------------------------------------------------------------------------------
# Ported from what the module produced, read off the live cluster rather than
# reconstructed from its source -- the same rule templates/node-bootstrap.yaml.tpl
# follows, and the one that made the derived k3s.service come out byte-identical.
#
# NO INBOUND 22 AND NO INBOUND 6443. ADR-0006: the operator path is the tailnet
# and the public API is closed. Nodes reach each other on the private network,
# which a Hetzner firewall does not filter, so the API needs no public opening
# at all.
#
# Hetzner denies everything not listed once ANY outbound rule exists, which is
# why the outbound list is long and why adding a rule elsewhere without adding
# it here fails as a timeout rather than as a refusal.
# ------------------------------------------------------------------------------
resource "hcloud_firewall" "cluster" {
  name   = local.cluster
  labels = local.labels

  dynamic "rule" {
    for_each = concat(local.base_firewall_rules, var.extra_firewall_rules)
    content {
      description     = rule.value.description
      direction       = rule.value.direction
      protocol        = rule.value.protocol
      port            = rule.value.protocol == "icmp" ? null : rule.value.port
      source_ips      = rule.value.direction == "in" ? rule.value.ips : []
      destination_ips = rule.value.direction == "out" ? rule.value.ips : []
    }
  }
}

locals {
  any = ["0.0.0.0/0", "::/0"]

  base_firewall_rules = [
    { description = "Allow Incoming HTTP Connections", direction = "in", protocol = "tcp", port = "80", ips = local.any },
    { description = "Allow Incoming HTTPS Connections", direction = "in", protocol = "tcp", port = "443", ips = local.any },
    { description = "Allow Incoming Tailscale Direct WireGuard", direction = "in", protocol = "udp", port = "41641", ips = local.any },

    { description = "Allow Outbound HTTP Requests", direction = "out", protocol = "tcp", port = "80", ips = local.any },
    { description = "Allow Outbound HTTPS Requests", direction = "out", protocol = "tcp", port = "443", ips = local.any },
    { description = "Allow Outbound TCP DNS Requests", direction = "out", protocol = "tcp", port = "53", ips = local.any },
    { description = "Allow Outbound UDP DNS Requests", direction = "out", protocol = "udp", port = "53", ips = local.any },
    { description = "Allow Outbound UDP NTP Requests", direction = "out", protocol = "udp", port = "123", ips = local.any },
    { description = "Allow Outbound Tailscale STUN", direction = "out", protocol = "udp", port = "3478", ips = local.any },
    { description = "Allow Outbound Tailscale Direct WireGuard", direction = "out", protocol = "udp", port = "41641", ips = local.any },
    { description = "Allow Outbound ICMP Ping Requests", direction = "out", protocol = "icmp", port = null, ips = local.any },
  ]
}
