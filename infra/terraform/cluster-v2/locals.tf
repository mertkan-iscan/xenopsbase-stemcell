locals {
  cluster = "${var.cluster_name}-${var.environment}"

  labels = {
    cluster     = local.cluster
    environment = var.environment
    managed-by  = "terraform"
  }

  control_plane_names = [
    for i in range(var.control_plane_count) : "${local.cluster}-control-plane-${i}"
  ]

  # Named by index, not by a random suffix. The module appends three random
  # characters, which is why the control plane's MagicDNS name could never be
  # known in advance and why the endpoint had to come from a module output.
  # A stable name is half of what makes the address stable.
  agent_names = [
    for i in range(var.agent_count) : "${local.cluster}-worker-${i}"
  ]
}
