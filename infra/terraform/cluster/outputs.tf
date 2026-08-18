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
