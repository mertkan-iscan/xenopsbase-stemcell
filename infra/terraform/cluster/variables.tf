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
  description = "Additional firewall rules. T-1.5 owns hardening; this is the seam it will use."
  type        = list(any)
  default     = []
}
