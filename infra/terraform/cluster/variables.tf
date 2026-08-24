variable "hcloud_token" {
  description = "Hetzner Cloud API token with read/write. Supply via TF_VAR_hcloud_token; never in a file."
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Cluster name. Also prefixes every Hetzner resource created."
  type        = string
  default     = "xenopsbase"
}

variable "environment" {
  description = "Environment this cluster belongs to. Determines the state key and node sizing defaults."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "network_region" {
  description = "Hetzner network region. eu-central covers fsn1, nbg1 and hel1."
  type        = string
  default     = "eu-central"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key used for node access."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Path to the matching private key. Terraform uses it to provision nodes over SSH."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

# ------------------------------------------------------------------------------
# Node pools
#
# Sizes are variables rather than literals so that a fork can resize without
# editing module wiring, and so dev and prod differ by tfvars alone (T-1.4).
#
# The defaults below are the CHEAPEST WORKING cluster, not a production one:
# a single control-plane node, no high availability. That matches the near-zero
# budget target, where the cluster is destroyed between working sessions and an
# hour of downtime costs nothing because nobody is using it.
#
# For prod, set control plane count to 3. Anything else is not HA: etcd needs a
# quorum, and with one node there is nothing to lose quorum to.
#
# Keep every pool's `location` in the same city as the object storage region.
# Otherwise every database backup and document read crosses datacentres, which
# adds latency to normal operation and, more importantly, to the cold rebuild
# ADR-0002 puts a 60 minute target on.
# ------------------------------------------------------------------------------

variable "control_plane_nodepools" {
  description = "Control plane node pools. Count must be odd. Use 1 for dev, 3 for anything real."
  type = list(object({
    name        = string
    server_type = string
    location    = string
    labels      = optional(list(string), [])
    taints      = optional(list(string), [])
    count       = number
  }))
  default = [
    {
      name        = "control-plane"
      server_type = "cx23"
      location    = "fsn1"
      count       = 1
    }
  ]

  validation {
    condition     = sum([for p in var.control_plane_nodepools : p.count]) % 2 == 1
    error_message = "Total control plane count must be odd. etcd needs a quorum, and an even number gives worse availability than the odd number below it."
  }
}

variable "agent_nodepools" {
  description = "Agent (worker) node pools."
  type = list(object({
    name        = string
    server_type = string
    location    = string
    labels      = optional(list(string), [])
    taints      = optional(list(string), [])
    count       = number
    # Left null, matching the module default. Tailscale transport requires an
    # explicit value, but that path is blocked (see #84) and defaulting to
    # "primary" here was a deviation from upstream for no benefit -- both
    # resolve to network_id 0.
    network_scope = optional(string, null)
  }))
  default = [
    {
      name        = "worker"
      server_type = "cx23"
      location    = "fsn1"
      count       = 2
    }
  ]
}

variable "autoscaler_nodepools" {
  description = <<-EOT
    Autoscaling node pools. Empty by default; T-2.8 turns these on once there
    are real workloads and a load profile from T-5.6 to size against.
  EOT
  type = list(object({
    name        = string
    server_type = string
    location    = string
    min_nodes   = number
    max_nodes   = number
    # REQUIRED under node_transport_mode = "tailscale", and the module rejects
    # the plan without it: it keeps primary/external network intent known at
    # plan time even though network_id comes from a resource in the same root.
    # Same reason agent_nodepools carries it. Discovered by planning against a
    # live cluster (T-2.8) -- the type was written before any autoscaler pool
    # existed, so nothing had ever exercised this path.
    network_scope = optional(string, "primary")
  }))
  default = []
}

# ------------------------------------------------------------------------------
# Cluster components
# ------------------------------------------------------------------------------

variable "cni_plugin" {
  description = <<-EOT
    CNI. Defaults to flannel, which is lighter and adequate for now.

    T-8.2 requires default-deny network policies. K3s enforces NetworkPolicy via
    its bundled controller, so flannel may suffice; if it does not, this becomes
    "cilium", which costs noticeably more memory per node. Deliberately left as
    a variable so T-8.2 can decide against evidence rather than this task
    guessing ahead of it.
  EOT
  type        = string
  default     = "flannel"

  validation {
    condition     = contains(["flannel", "cilium"], var.cni_plugin)
    error_message = "cni_plugin must be flannel or cilium."
  }
}

variable "ingress_controller" {
  description = <<-EOT
    Deliberately "none".

    kube-hetzner can install an ingress controller, but ADR-0004 makes Argo CD
    the single owner of everything above the cluster. Two systems installing
    ingress means drift with no clear owner, and Argo reverting a change
    kube-hetzner just made. T-2.2 installs ingress through GitOps instead.
  EOT
  type        = string
  default     = "none"
}

variable "enable_cert_manager" {
  description = "Deliberately false. cert-manager is installed by GitOps in T-2.2, for the same single-owner reason as ingress."
  type        = bool
  default     = false
}

variable "load_balancer_type" {
  description = "Hetzner load balancer type fronting the ingress. lb11 is the smallest."
  type        = string
  default     = "lb11"
}

variable "extra_firewall_rules" {
  description = "Additional firewall rules layered on top of the module's default-deny set."
  type        = list(any)
  default     = []
}

variable "ccm_disable_network_attached_check" {
  description = <<-EOT
    Disable the cloud controller manager's "is this server attached to the
    configured network" check.

    That check queries the Hetzner metadata service at 169.254.169.254. On this
    setup the metadata route is installed by DHCP over the PRIVATE interface,
    where it black-holes:

      ip route get 169.254.169.254
        169.254.169.254 via 10.0.0.1 dev eth1 proto dhcp src 10.255.0.1

      curl --interface eth0 ...  ->  200
      curl (default route)  ...  ->  timeout

    So the CCM crash-loops at startup before doing anything:

      Cloud provider could not be initialized: hcloud/newCloud:
      checking if server is in Network not possible: serverIsAttachedToNetwork:
      ... context deadline exceeded

    Everything downstream then fails in ways that never mention metadata: the
    node keeps its uninitialized taint, nothing schedules,
    system-upgrade-controller times out, and the agents never install k3s.

    WHAT THIS GIVES UP. The check exists to catch a genuine misconfiguration --
    a control plane running on a server that is not on the configured network.
    Here that has been verified directly instead:

      hcloud server list -o columns=name,private_net

    shows all three nodes on xenopsbase-dev. The check is not wrong, it is
    merely unreachable, and skipping it does not make an unattached server work.

    Set false once the metadata routing is fixed (#84), so the safety check
    comes back rather than being permanently disabled.
  EOT
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# GitOps (ADR-0004, T-2.1)
# ------------------------------------------------------------------------------

variable "argocd_chart_version" {
  description = <<-EOT
    Argo CD helm chart version, pinned.

    A floating version means a rebuild can install a different Argo CD than the
    last one for reasons nobody chose, which breaks the promise of ADR-0002 that
    a rebuild reproduces what was there before.
  EOT
  type        = string
  default     = "10.4.0"
}

variable "ksops_version" {
  description = "ksops release version injected into argocd-repo-server. Pinned, like every other component."
  type        = string
  default     = "4.5.1"
}

variable "sops_age_key" {
  description = <<-EOT
    The age PRIVATE key that decrypts every secret in git (ADR-0003).

    Supply via TF_VAR_sops_age_key; never in a file, never in a tfvars. The
    public half lives in .sops.yaml and is committed.

    This is the one bootstrap secret. Everything else the platform needs is
    encrypted in the repository and unreachable without it -- which is exactly
    why the set is kept to one, and why losing it means reissuing every
    credential at its source rather than restoring a backup.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

variable "argocd_domain" {
  description = "Hostname Argo CD believes it serves on. No ingress exists for it; access is by port-forward."
  type        = string
  default     = "argocd.internal"
}

variable "platform_repo_url" {
  description = <<-EOT
    Git repository the root Application reconciles from.

    Public, so Argo CD needs no credentials to read it. That is a real
    simplification of the bootstrap: one fewer secret that must exist before
    the cluster does.
  EOT
  type        = string
  default     = "https://github.com/mertkan-iscan/xenopsbase-stemcell.git"
}

variable "platform_repo_revision" {
  description = "Branch or tag the root Application tracks."
  type        = string
  default     = "main"
}

# ------------------------------------------------------------------------------
# Network exposure (ADR-0006)
# ------------------------------------------------------------------------------

variable "node_transport_mode" {
  description = <<-EOT
    How Terraform and operators reach the nodes.

    "tailscale"       nodes join a tailnet at first boot; the public Kubernetes
                      API and SSH are closed entirely. This is the intended mode.

    "hetzner_private" the escape hatch. Restores public API and SSH, restricted
                      by firewall_source_cidrs below. It exists because closing
                      the front door introduces a dependency: if Tailscale is
                      unreachable and the cluster must be rebuilt, the
                      alternative to this hatch is waiting out someone else's
                      outage. Using it is a deliberate, reviewable change.
  EOT
  type        = string
  default     = "tailscale"

  validation {
    condition     = contains(["tailscale", "hetzner_private"], var.node_transport_mode)
    error_message = "node_transport_mode must be tailscale or hetzner_private."
  }

  # These fail at plan time on purpose. Every one of them, left unchecked,
  # produces a provisioning HANG rather than an error: nodes boot, never join,
  # and Terraform waits on SSH that will never answer.
  validation {
    condition     = var.node_transport_mode != "tailscale" || (var.tailscale_auth_key != null && var.tailscale_auth_key != "")
    error_message = "node_transport_mode = tailscale needs TF_VAR_tailscale_auth_key. It must be a REUSABLE key: a single-use key registers only the first node and the rest hang waiting to join."
  }

  validation {
    condition     = var.node_transport_mode != "tailscale" || (var.tailscale_magicdns_domain != null && var.tailscale_magicdns_domain != "")
    error_message = "node_transport_mode = tailscale needs tailscale_magicdns_domain, e.g. \"tail1a2b3c.ts.net\". The module requires it at plan time; find it in the Tailscale admin console under DNS."
  }

  validation {
    condition     = var.node_transport_mode != "hetzner_private" || length(var.firewall_source_cidrs) > 0
    error_message = "node_transport_mode = hetzner_private needs firewall_source_cidrs. Leaving it empty would expose the Kubernetes API and SSH to the internet."
  }

  validation {
    condition     = var.node_transport_mode != "hetzner_private" || !contains(var.firewall_source_cidrs, "0.0.0.0/0")
    error_message = "firewall_source_cidrs contains 0.0.0.0/0, which exposes the Kubernetes API and SSH to the entire internet. The escape hatch is meant to be narrower than the front door, not identical to having none."
  }
}

variable "tailscale_auth_key" {
  description = <<-EOT
    Tailscale auth key. Supply via TF_VAR_tailscale_auth_key; never in a file.

    Must be REUSABLE: a single-use key registers only the first node and the
    rest hang waiting to join. Second bootstrap secret alongside the age key of
    ADR-0003 -- something that must exist before the cluster does.
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "tailscale_magicdns_domain" {
  description = <<-EOT
    The tailnet's MagicDNS domain, e.g. "tail1a2b3c.ts.net".

    Required by the module at plan time when node_transport_mode = "tailscale".
    Found in the Tailscale admin console under DNS.
  EOT
  type        = string
  default     = null
}

variable "firewall_source_cidrs" {
  description = <<-EOT
    Source CIDRs permitted to reach the Kubernetes API and SSH.

    Used ONLY when node_transport_mode = "hetzner_private". Under tailscale
    both sources are closed outright, so this is ignored.

    Never leave this as 0.0.0.0/0. The module warns that a stale allowlist makes
    provisioning hang rather than fail, so a wrong value here is worse than an
    obviously broken one.
  EOT
  type        = list(string)
  default     = []
}

variable "pin_metadata_route_to_public_nic" {
  description = <<-EOT
    Install a systemd unit pinning the route to the Hetzner metadata service
    (169.254.169.254) onto the PUBLIC interface.

    Without it, DHCP on the private interface installs that route over eth1,
    where it black-holes:

      ip route get 169.254.169.254
        169.254.169.254 via 10.0.0.1 dev eth1 src 10.255.0.1

      curl --interface eth0 ...  ->  fsn1-dc8
      curl --interface eth1 ...  ->  no answer

    This is the same root cause as #84, which was worked around for the cloud
    controller manager by disabling its attached-network check. The CSI driver
    has the same dependency and NO equivalent escape hatch -- it needs the
    availability zone to choose where to create a volume, so it exits:

      failed to setup CSI driver: could not determine default volume location:
      failed to get location from metadata service

    The node driver then crash-loops, every PersistentVolumeClaim stays Pending,
    and Postgres never starts. Nothing in that chain mentions metadata or
    routing.

    Worth knowing: this is a RACE, not a constant. The bad route is installed by
    DHCP, so whether the CSI driver starts before or after it decides whether
    the cluster works. The same configuration built a working cluster earlier
    the same day and a broken one on rebuild, which is the worst kind of
    reproducibility bug for something ADR-0002 asks to be rebuilt routinely.

    Set false only on a cluster whose nodes have no public interface, where
    pinning to eth0 would be wrong.
  EOT
  type        = bool
  default     = true
}

variable "cluster_ipv4_cidr" {
  description = <<-EOT
    Pod CIDR. Must match what the module passes to k3s -- it is the module's own
    default, restated here only because the CCM values need it by name when
    networking is re-enabled under tailscale.
  EOT
  type        = string
  default     = "10.42.0.0/16"
}

variable "ccm_restore_networking_under_tailscale" {
  description = <<-EOT
    Re-enable the Hetzner CCM's network awareness when node_transport_mode is
    "tailscale".

    kube-hetzner v3.1.0 turns it off for any cross-network transport, but only
    switches node-ip to the public address for the multinetwork overlay. Under
    tailscale alone the node keeps advertising its private address while the CCM
    is given no network to resolve it against, so the node is never initialised
    and the cluster does not converge. See the reasoning in main.tf.

    Safe only for a single-primary-network cluster with no external-network
    nodepools, which is the case the module disabled this to protect. The
    validation below refuses the combination it is not safe for.

    UNVERIFIED against a live cluster.
  EOT
  type        = bool
  default     = true
}

# The escape hatch this fix depends on: it is only sound while every node is on
# the one primary network. An external-network autoscaler pool breaks that, and
# the module's own reason for disabling CCM networking becomes real.
check "ccm_networking_override_is_safe" {
  assert {
    condition = !(
      var.node_transport_mode == "tailscale" &&
      var.ccm_restore_networking_under_tailscale &&
      length([for p in var.autoscaler_nodepools : p if try(p.network_id, null) != null]) > 0
    )
    error_message = "ccm_restore_networking_under_tailscale is unsafe with external-network autoscaler nodepools: nodes outside the primary network cannot be resolved against a single HCLOUD_NETWORK. Set it to false and expect the uninitialized-taint failure instead."
  }
}
