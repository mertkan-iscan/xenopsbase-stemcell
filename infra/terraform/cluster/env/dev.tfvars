# dev — the cheapest cluster that works.
#
# One control plane node, no HA. That is the correct trade here, not a
# compromise: dev is destroyed between working sessions, so an hour of downtime
# has no consumer to inconvenience. Paying for HA on something torn down nightly
# buys availability nobody uses.
environment = "dev"

cluster_name   = "xenopsbase"
network_region = "eu-central"

ssh_public_key_path  = "~/.ssh/xenopsbase_ed25519.pub"
ssh_private_key_path = "~/.ssh/xenopsbase_ed25519"

control_plane_nodepools = [
  {
    name        = "control-plane"
    server_type = "cx23"
    location    = "fsn1"
    count       = 1
  }
]

agent_nodepools = [
  {
    name = "worker"
    # cx33 (8Gi) rather than cx23 (4Gi). Two cx23 workers could not carry the
    # platform: memory hit 93% on one node and Argo's repo-server began failing
    # its probes, so committed changes silently stopped arriving (T-1.12, #133).
    #
    # That is the failure worth paying to avoid. It does not present as "out of
    # memory" -- it presents as a fix not working, three layers from the cause.
    #
    # The cost is about a cent an hour more for the pair, and the cluster is
    # destroyed between sessions, so the monthly figure is not what is paid.
    server_type = "cx33"
    location    = "fsn1"
    count       = 2

    # No network_scope. It was required while the module created these servers;
    # agents.tf does now (T-1.23, #282), and the variable no longer accepts it.
    # A static agent joins the cluster network through the inline `network`
    # block on its hcloud_server, at creation.
  }
]

# Cluster autoscaler (T-2.8, #22).
#
# min_nodes = 0 is the whole point. The two fixed cx33 workers above carry the
# platform and the services at their floor; this pool is empty and costs
# nothing until the HPAs ask for replicas that will not fit, and it drains back
# to empty afterwards. A pool with min_nodes = 1 would be a third worker billed
# continuously to be ready for a load that arrives during working sessions --
# which is the cost model ADR-0002 exists to avoid.
#
# max_nodes = 2 is headroom for the platform growing underneath -- Loki and
# Prometheus are the ones that move -- and NOT for application replicas.
#
# This used to say the HPA ceilings were "3.5 cores of NEW demand beyond the
# current floor, and one extra cx33 (4 vCPU) absorbs it". The arithmetic counted
# the ceiling TOTAL instead of the delta: 4 gateway and 3 core at 500m is 3,500m
# altogether, and the floor of 2 gateway and 1 core is already 1,500m, so the
# new demand is 2,000m.
#
# Measured at ceiling on 2026-08-26, with the control plane tainted (#298) so
# nothing else could absorb it:
#
#   worker-0  2510m / 3700m      worker-1  2335m / 3700m      free 2555m
#   [90s - 345s]  hpa: core=3 gateway=4   pending=0   autoscaled=0
#
# Seven pods placed and room for five more. No extra cx33 is absorbed by
# anything, and a k6 load will never produce a scale-up -- which is what the
# last clause always said, and what the corrected arithmetic now agrees with.
#
# THE MEMORY AXIS, RE-DERIVED (T-2.23, #306). Everything above is CPU. The
# memory arithmetic had never been done, and it does not come out the same way.
#
# With Argo CD's requests corrected from measurement (#306 -- the controller was
# declared at 256Mi and using 823Mi), and the apps at their HPA ceiling of
# 3 core and 4 gateway:
#
#   all-namespace requests, measured 2026-08-29   10744Mi
#     after the Argo CD correction                11576Mi
#     with the apps at their ceiling              14584Mi
#   less what the tainted control plane carries      672Mi
#   to seat on the two fixed cx33 workers         13912Mi
#   two cx33 allocatable                          14306Mi
#                                                 => 97% booked
#
# So on CPU the ceiling leaves 2555m free and five pods of room; on MEMORY it
# leaves 394Mi across both workers, under 3%. The fourth criterion below --
# "the fixed workers are sized for peak application load, so the application
# never waits for a node to appear" -- holds on CPU and is marginal on memory.
#
# It is marginal rather than broken, and the distinction matters: 2918Mi of that
# total is booked by keycloak against 869Mi actually used, so most of the
# pressure is other namespaces over-declaring rather than real consumption.
# Cluster-wide the ratio is 0.69x -- requests exceed usage by 3.3GB. The
# scheduler cannot know that, which is exactly why it is a problem: it places by
# requests, and by requests these workers are nearly full at ceiling.
#
# Not fixed here, deliberately. Correcting keycloak's over-declaration is its
# own measurement and its own card; this comment exists so the next person to
# raise an HPA ceiling or a memory request knows which axis binds first, and
# that it is no longer CPU.

# That property is worth keeping and is T-2.8's fourth criterion now: the fixed
# workers are sized for peak application load, so the application never waits
# for a node to appear before it can serve. It stops being true the moment
# someone raises an HPA ceiling or a request past what two cx33s can seat.
#
# cx33 to match the fixed workers. A smaller type would schedule pods that then
# cannot get the CPU the HPA sized them against, and the autoscaler would keep
# adding nodes that do not fix it.
#
# DEMONSTRATED 2026-08-26 (T-2.8, #22). Criterion 1 asked for nodes added and
# removed under load, and that is what happened -- a pod requesting 3000m that
# the two fixed workers could not seat:
#
#   Final scale-up plan: [{xenopsbase-dev-autoscaled 0->1 (max: 2)}]
#   node created in Hetzner in 15s, Ready in 30s, boot 20.8s
#   image 424553376, installed nothing, k3s v1.36.3+k3s1
#   firewall 11523859 applied at creation
#   scale-probe pod Running on it
#   make node-equivalence: static vs autoscaled, 5 properties match
#
# The number that killed #22 the first time was the cloudInit payload at 35,332
# bytes against a 32,768 limit. It is 1,684 now, because everything static went
# into the golden image (T-1.18).
#
# And removed, by the autoscaler itself, when the load went away:
#
#   was unneeded for 10m2.378s
#   Considering node ... for standard scale down
#   Scale-down: removing empty node
#   drain.go:140] All pods removed from ...
#
# 989s from deleting the workload to both the node object and the Hetzner
# server being gone -- the 10-minute unneeded window plus the scan interval.
# It DRAINED rather than dropped, which is the half of "removed under load"
# that a disappearing server would not have proved.
#
# The two --skip-nodes-with-* flags in manifests/30-cluster-autoscaler are what
# make this possible, and this is the run that shows it: an emptied node still
# carries alloy and node-exporter, and without those flags the autoscaler would
# refuse to remove it and the node would stay for ever.
#
# The order is worth knowing: the Hetzner server goes first and the node object
# lingers a few seconds. The reverse -- object gone, server billing -- is the
# failure #294 is about, and it is not what happens here.
# ---------------------------------------------------------------------------
# SCALE-DOWN TIMERS: DEV ONLY (T-5.18)
# ---------------------------------------------------------------------------
#
# Both default to the upstream 10m in variables.tf, and staging and prod keep
# that. Ten minutes is the right number where real traffic is served: a node
# removed the moment it looks idle is re-provisioned by the next burst, and a
# Hetzner server takes minutes to boot, join and pull images, so an eager timer
# buys thrash and users pay the cold start.
#
# Dev's workload is load tests, where the cost of waiting is different in kind.
# With the defaults, a finished run plus the HPAs' own windows left ~25 minutes
# before the cluster was back on its floor -- and T-5.15 is the record of six
# runs being compared against each other when three had started on 3 nodes and
# two on 4, because the next run got launched on the previous one's leftovers.
# The throughput numbers in docs/slos.md had to be re-measured and re-labelled.
#
# 2m, not 0: long enough to ride out the quiet gap between steps of a ramp,
# short enough that a finished run does not hold a server for a coffee break.
cluster_autoscaler_scale_down_unneeded_time   = "2m"
cluster_autoscaler_scale_down_delay_after_add = "2m"

autoscaler_nodepools = [
  {
    name        = "autoscaled"
    server_type = "cx33"
    location    = "fsn1"
    min_nodes   = 0
    max_nodes   = 2
    # No network_scope, same as the static pool above. The module is handed
    # `autoscaler_nodepools = []`, and the network a scaled node joins comes
    # from network_id in manifests/30-cluster-autoscaler.
  }
]

cni_plugin          = "flannel"
ingress_controller  = "none"
enable_cert_manager = false
load_balancer_type  = "lb11"

# Network exposure (ADR-0006). Public Kubernetes API and SSH are closed;
# Terraform and kubectl reach the cluster over the tailnet.
#
# TF_VAR_tailscale_auth_key must be set, and must be a REUSABLE key.
#
# This was pinned to "hetzner_private" as an escape hatch while the CCM failure
# under tailscale was unexplained (#11). The cause is now identified and the fix
# is in main.tf, so the hatch is closed.
#
# It can only be changed on a cluster that is being built from nothing. Flipping
# it on a RUNNING cluster does not work and is not recoverable in place: the
# firewall rules are replaced immediately -- closing 22 and 6443 -- while the
# servers are not, so no node ever joins the tailnet and there is no longer any
# path to the ones that are running.
node_transport_mode       = "tailscale"
tailscale_magicdns_domain = "tail894b71.ts.net"

# firewall_source_cidrs is deliberately NOT set here. It is a home IP address
# and this repository is public, so it comes from TF_VAR_firewall_source_cidrs.
#
# It must be absent rather than empty: a -var-file value overrides a TF_VAR_
# environment variable, so "firewall_source_cidrs = []" here would silently beat
# the environment and trip the validation.

# cloudflared reaches Cloudflare's edge over QUIC on UDP 7844.
#
# The module's default outbound rules allow 80, 443, DNS, NTP and ICMP -- and on
# Hetzner, defining ANY outbound rule denies everything not listed. So QUIC is
# blocked, and the failure is not obviously a firewall one:
#
#   Failed to dial a quic connection: timeout: no recent network activity
#
# cloudflared retries forever with backoff, so the pods sit Running but never
# Ready and the site simply never comes up.
#
# TCP 7844 is the documented fallback path; allowing both means a QUIC problem
# degrades to http2 rather than to an outage.
extra_firewall_rules = [
  {
    description     = "cloudflared tunnel (QUIC)"
    direction       = "out"
    protocol        = "udp"
    port            = "7844"
    destination_ips = ["0.0.0.0/0", "::/0"]
  },
  {
    description     = "cloudflared tunnel (http2 fallback)"
    direction       = "out"
    protocol        = "tcp"
    port            = "7844"
    destination_ips = ["0.0.0.0/0", "::/0"]
  },

  # SMTP submission, so Alertmanager can actually deliver.
  #
  # Same trap as the QUIC rules above. Alerts were generated, grouped and routed
  # correctly, then failed at the final hop:
  #
  #   dial tcp 172.246.243.66:587: connect: connection timed out
  #
  # Alertmanager records that in its own log and nowhere else, so the pipeline
  # looked healthy end to end while delivering nothing -- which is precisely the
  # class of failure the pipeline exists to catch.
  #
  # 587 (submission with STARTTLS), not 25: Hetzner blocks outbound 25 outright
  # as an anti-spam measure, and transactional relays expect 587 regardless.
  {
    description     = "SMTP submission for alert delivery"
    direction       = "out"
    protocol        = "tcp"
    port            = "587"
    destination_ips = ["0.0.0.0/0", "::/0"]
  },
]

# Argo CD now has an ingress and a hostname, so it should stop believing it is
# argocd.internal. This is the value the server puts in redirects and in the
# links it generates; a wrong one is not fatal but sends people to a host that
# does not resolve. Behind Cloudflare Access, like the other dashboards -- see
# infra/terraform/edge/env/dev.tfvars.
#
# NOTE: this is read at bootstrap render time, so changing it needs a
# `make cluster-apply ENV=dev`, not just an Argo sync.
argocd_domain = "argocd-dev.xenopsoftware.com"
