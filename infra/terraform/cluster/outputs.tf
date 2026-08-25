output "kubeconfig" {
  description = "Cluster kubeconfig. Write it out with: terraform output -raw kubeconfig > kubeconfig"
  value       = module.kube_hetzner.kubeconfig
  sensitive   = true
}

output "cluster_name" {
  description = "Full cluster name, including environment suffix."
  value       = "${var.cluster_name}-${var.environment}"
}

output "control_plane_count" {
  description = "Total control plane nodes. 1 means no high availability."
  value       = sum([for p in var.control_plane_nodepools : p.count])
}

output "is_highly_available" {
  description = "Whether the control plane can lose a node and keep serving."
  value       = sum([for p in var.control_plane_nodepools : p.count]) >= 3
}

# ------------------------------------------------------------------------------
# How big the node bootstrap is (T-1.19, #251).
#
# The SIZE, not the payload: the bootstrap carries the cluster join token and a
# Tailscale auth key, and an output is written to state and printed by anyone
# running `terraform output`. The number is what needs checking and the number
# is not a secret.
#
# This is the ENCODED length, because that is what the hcloud autoscaler sends
# to the API -- it passes `cloudInit` through without decoding it. Measuring the
# decoded form would give a check that passes while the thing it measures
# fails, which is how #22 stayed invisible: the module's payload decoded to
# 26,499 bytes, comfortably inside the limit, and was rejected anyway.
# ------------------------------------------------------------------------------
output "node_bootstrap_bytes" {
  description = "Size in bytes of the node bootstrap as sent to Hetzner as user_data."
  # nonsensitive() because terraform propagates sensitivity through length():
  # the bootstrap carries a join token, so its LENGTH inherits the taint even
  # though a byte count reveals nothing. Marking the output sensitive instead
  # would hide the one number this exists to show.
  value = nonsensitive(length(local.node_bootstrap_b64))
}
