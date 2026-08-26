variable "hcloud_token" {
  description = "Hetzner Cloud API token with read/write. Supply via TF_VAR_hcloud_token; never in a file."
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  type    = string
  default = "xenopsbase"
}

variable "environment" {
  description = "Environment this cluster belongs to. Determines the state key and node sizing."
  type        = string
  default     = "dev"
}

variable "network_region" {
  type    = string
  default = "eu-central"
}

# The same values the module used, read off the live cluster rather than copied
# from its defaults: network 10.0.0.0/8 with a 10.255.0.0/16 subnet. Kept
# identical so a node moving between the two roots needs no reconfiguration.
variable "network_ipv4_cidr" {
  type    = string
  default = "10.0.0.0/8"
}

variable "node_ipv4_cidr" {
  type    = string
  default = "10.255.0.0/16"
}

variable "kubernetes_api_port" {
  type    = number
  default = 6443
}

variable "control_plane_count" {
  description = "1 means no high availability. dev is deliberately 1; staging and prod are 3."
  type        = number
  default     = 1

  validation {
    condition     = var.control_plane_count % 2 == 1
    error_message = "An etcd quorum needs an odd number of control plane nodes."
  }
}

variable "control_plane_server_type" {
  type    = string
  default = "cx23"
}

variable "agent_count" {
  type    = number
  default = 2
}

variable "agent_server_type" {
  type    = string
  default = "cx33"
}

variable "location" {
  type    = string
  default = "fsn1"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/xenopsbase_ed25519.pub"
}

variable "ssh_private_key_path" {
  type    = string
  default = "~/.ssh/xenopsbase_ed25519"
}

variable "tailscale_auth_key" {
  description = <<-EOT
    Tailscale auth key. Supply via TF_VAR_tailscale_auth_key; never in a file.

    Must be REUSABLE: a single-use key registers only the first node and the
    rest hang waiting to join.
  EOT
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.tailscale_auth_key == null || trimspace(coalesce(var.tailscale_auth_key, " ")) != ""
    error_message = "tailscale_auth_key must be null or a non-empty key."
  }
}

variable "tailscale_magicdns_domain" {
  type    = string
  default = ""
}

variable "extra_firewall_rules" {
  description = "Layered on top of the base set. Hetzner denies unlisted outbound traffic once any outbound rule exists, so an addition elsewhere without one here fails as a timeout."
  type = list(object({
    description = string
    direction   = string
    protocol    = string
    port        = optional(string)
    ips         = list(string)
  }))
  default = []
}
