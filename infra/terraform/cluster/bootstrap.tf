# ==============================================================================
# THE PLATFORM BOOTSTRAP, AFTER THE NODES THAT WILL CARRY IT (ADR-0014, T-1.27)
#
# This is the same work `user_kustomizations` did inside the module -- install
# Argo CD, then apply the root Application -- moved out so it happens at a point
# in the graph where an agent exists.
#
# WHY IT MOVED
#
# The module runs its kustomizations at the end of its own apply. That was
# correct while the module also created the agents, because they existed by
# then. Since T-1.23 terraform creates them, and terraform cannot create one
# until the module returns -- so the bootstrap ran against a cluster whose only
# node was the control plane, and the entire platform scheduled onto a cx23.
#
# Three builds, three outcomes, one cause:
#
#   build 1  platform on the control plane, load average 16.87 on two vCPU,
#            argocd-repo-server restarting, one agent never registered
#   build 2  a `bootstrap: true` workaround stopped k3s applying its own
#            manifests; three applies died waiting for a CRD
#   build 3  reached 12/14 applications Healthy, held ~400s, collapsed to 0/0,
#            and `make up` timed out
#
# Build 3 is the useful one: the platform is not broken, it does not fit. So the
# fix is not a toleration or a flag, it is arriving after there is somewhere to
# land.
#
# WHAT DID NOT MOVE
#
# Everything the module writes into /var/lib/rancher/k3s/server/manifests --
# CCM, CSI, CoreDNS, metrics-server. Those are cluster components rather than
# platform, they carry the tolerations to run on a bare control plane, and the
# node stays `uninitialized` until the CCM among them runs. Build 2 is what
# happens when something delays them.
# ==============================================================================

locals {
  # The tailnet is the only route to the API (ADR-0006), so the bootstrap talks
  # to a control plane by MagicDNS name rather than by address. The module
  # publishes them; taking the first is the same choice it makes internally.
  bootstrap_host = one(values(module.kube_hetzner.tailscale_control_plane_magicdns_hosts))

  # Rendered here, uploaded below. Same templates the module used, with the same
  # parameters -- this changes WHEN they are applied and nothing about WHAT.
  bootstrap_stages = {
    "1" = {
      folder = "${path.module}/manifests/10-argocd"
      params = {
        argocd_chart_version = var.argocd_chart_version
        argocd_domain        = var.argocd_domain
        ksops_version        = var.ksops_version
        sops_age_key         = indent(4, var.sops_age_key)
      }
    }
    "2" = {
      folder = "${path.module}/manifests/20-root-app"
      params = {
        platform_repo_url      = var.platform_repo_url
        platform_repo_revision = var.platform_repo_revision
        platform_path          = "platform/envs/${var.environment}"
      }
    }

    # ------------------------------------------------------------------------
    # The autoscaler's node definition (T-1.19, #251), moved out of the module
    # for the firewall (T-1.28).
    #
    # It is here rather than in Argo CD because every value in it -- the golden
    # image id, the network, the join token, the Tailscale key -- is a fact
    # about this cluster build that cannot be committed to git. That is the one
    # place ADR-0004's rule bends.
    #
    # It is here rather than inside the module because of HCLOUD_FIREWALL. The
    # firewall is created by the module, so a stage inside it cannot be handed
    # the id without a cycle; out here `data.hcloud_firewalls.after_cluster`
    # reads it after the module has finished.
    # ------------------------------------------------------------------------
    "3" = {
      folder = "${path.module}/manifests/30-cluster-autoscaler"
      params = {
        golden_image_id    = data.hcloud_image.golden.id
        node_group         = local.autoscaler_node_group
        min_nodes          = local.autoscaler_pool.min_nodes
        max_nodes          = local.autoscaler_pool.max_nodes
        server_type        = local.autoscaler_pool.server_type
        location           = local.autoscaler_pool.location
        ssh_key_id         = module.kube_hetzner.ssh_key_id
        network_id         = module.kube_hetzner.network_id
        firewall_id        = local.static_agent_firewall_id
        ca_image           = var.cluster_autoscaler_image
        ca_version         = var.cluster_autoscaler_version
        node_bootstrap_b64 = local.node_bootstrap_b64[local.autoscaler_node_group]
        config_sha256      = sha256(local.node_bootstrap_b64[local.autoscaler_node_group])
      }
    }
  }

  bootstrap_files = merge([
    for stage, cfg in local.bootstrap_stages : {
      for f in fileset(cfg.folder, "**/*.tpl") :
      "${stage}/${f}" => {
        stage       = stage
        source      = "${cfg.folder}/${f}"
        destination = "/var/platform-bootstrap/${stage}/${replace(f, ".tpl", "")}"
        content     = templatefile("${cfg.folder}/${f}", cfg.params)
      }
    }
  ]...)
}

resource "terraform_data" "platform_bootstrap" {
  # THE EDGE THIS FILE EXISTS FOR. Not timing, not a retry, not a toleration --
  # a dependency. The agents are attached to the network before anything here
  # runs, so `kubectl apply` cannot happen on a cluster with nowhere to schedule.
  depends_on = [hcloud_server.static_agent]

  triggers_replace = {
    content = sha256(jsonencode({ for k, v in local.bootstrap_files : k => v.content }))
  }

  connection {
    type        = "ssh"
    user        = "root"
    host        = local.bootstrap_host
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      # OUR OWN DIRECTORY, and the reason is a build that failed on it.
      #
      # This used the module's path. Stage 3 still lives there, and the module
      # keeps its apply-options beside it. The `rm -rf` below then deleted the
      # module's own scaffolding mid-apply and its deploy step died on
      # `.kube-hetzner-apply-options/3.sh: Not a directory`.
      #
      # Two owners, one path. Moving is cheaper than coordinating.
      "rm -rf /var/platform-bootstrap",
      "mkdir -p /var/platform-bootstrap/1 /var/platform-bootstrap/2 /var/platform-bootstrap/3",
    ]
  }

  # ---------------------------------------------------------------------------
  # The precondition, checked rather than assumed (ADR-0014).
  #
  # `depends_on` guarantees the agents were CREATED, not that they joined. A
  # golden-image node reaches Ready in about 30 seconds, so this is normally a
  # short wait -- but if it is not, the failure names the missing precondition
  # instead of surfacing three minutes later as a CRD that never appeared,
  # which is how the same condition presented in builds 1 and 3.
  # ---------------------------------------------------------------------------
  provisioner "remote-exec" {
    inline = [<<-EOT
      set -e
      want=${sum([for p in var.agent_nodepools : p.count])}
      for i in $(seq 1 60); do
        have=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' 2>/dev/null | grep -c ' Ready ' || true)
        [ "$have" -ge "$want" ] && exit 0
        echo "waiting for agents to join ($have/$want) [$i/60]"
        sleep 5
      done
      echo "ERROR: only $have of $want agents joined in 300s." >&2
      echo "  The platform is not applied, deliberately: on a cluster with no agent it" >&2
      echo "  schedules onto the control plane and takes it down. That is #282." >&2
      exit 1
    EOT
    ]
  }
}

resource "terraform_data" "platform_bootstrap_files" {
  for_each = local.bootstrap_files

  triggers_replace = { content = sha256(each.value.content) }

  connection {
    type        = "ssh"
    user        = "root"
    host        = local.bootstrap_host
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "file" {
    content     = each.value.content
    destination = each.value.destination
  }

  depends_on = [terraform_data.platform_bootstrap]
}

resource "terraform_data" "platform_apply" {
  triggers_replace = {
    content = sha256(jsonencode({ for k, v in local.bootstrap_files : k => v.content }))
  }

  connection {
    type        = "ssh"
    user        = "root"
    host        = local.bootstrap_host
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      set -e
      kubectl apply -k /var/platform-bootstrap/1

      # The rendered Secret holds the age private key in cleartext. Once applied
      # it is in etcd, where it has to be; the copy on disk outlives the apply
      # and is gratuitous.
      shred -u /var/platform-bootstrap/1/sops-age-secret.yaml 2>/dev/null || rm -f /var/platform-bootstrap/1/sops-age-secret.yaml

      # k3s installs the chart asynchronously, so the CRD appears some time
      # after set 1 is applied. `kubectl wait` alone is not enough: it errors
      # immediately when the object does not exist rather than waiting for it
      # to appear.
      for i in $(seq 1 60); do
        kubectl get crd applications.argoproj.io >/dev/null 2>&1 && break
        echo "waiting for the Argo CD CRDs to appear ($i/60)"
        sleep 5
      done
      kubectl wait --for=condition=established --timeout=120s crd/applications.argoproj.io

      kubectl apply -k /var/platform-bootstrap/2
      kubectl apply -k /var/platform-bootstrap/3
    EOT
    ]
  }

  depends_on = [terraform_data.platform_bootstrap_files]
}
