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
# max_nodes = 2, and WHAT THE POOL IS ACTUALLY FOR (T-2.23, #306).
#
# This said "max_nodes = 2 is headroom for the platform growing underneath --
# Loki and Prometheus are the ones that move -- and NOT for application
# replicas". The number was right and the sentence was wrong.
#
# gateway.yaml requires one replica per node and maxReplicas is 4, so at ceiling
# the gateway needs four untainted nodes -- two static plus two from this pool.
# Its own comment says exactly that: "four replicas have four nodes available --
# exactly enough". So the pool IS for application replicas, and the claim that
# it was reserved for platform growth was never true of the running system.
#
# RAISING IT TO 3 WAS TRIED, AND REVERTED. The reasoning was that a spare node
# would restore the platform headroom the sentence promised. A load test on
# 2026-08-29 disproved it: with max_nodes = 3 the cluster went to SIX nodes and
# the third autoscaled node ended up carrying one core replica, while the four
# gateway replicas sat on the two static workers and only two autoscaled nodes.
#
#   max_nodes = 2   core=3 gateway=4   0 Pending   5 nodes   full ceiling placed
#   max_nodes = 3   core=2 gateway=4   0 Pending   6 nodes   less load, more nodes
#
# The autoscaler adds a node whenever a pod is Pending, and during a ramp a core
# replica is briefly Pending on CPU. Given a slot it will take one; given none it
# waits, and the pods land anyway -- which is what the max_nodes = 2 run shows.
# Spare capacity next to a scaling workload is not headroom, it is a node that
# gets used and billed.
#
# So the honest position: this pool is sized to exactly seat the application at
# its HPA ceiling, and there is NO headroom for platform growth on top of that.
# If Loki or Prometheus grows while the gateway is at ceiling, something will be
# Pending. That is a real limitation of a two-worker dev cluster rather than a
# thing to fix by raising a number, and it is written here so the next person
# reads it before repeating the experiment.

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
# THE MEMORY AXIS, MEASURED (T-2.23, #306). Everything above is CPU. The memory
# arithmetic had never been done, so here it is -- with the caveat that it is
# NOT what binds first.
#
# RE-DERIVED (T-2.26, #340). The first version of this block said 97% booked at
# HPA ceiling. It was wrong by two measurement errors, both in the same
# direction, and the corrected figure is 86%. What the errors were and why they
# are easy to make is in infra/scripts/resource-audit.py, which now produces
# these numbers instead of anybody producing them by hand:
#
#   - 1700Mi of the 10744Mi was keycloak's realm-import Job, which had already
#     SUCCEEDED. A finished pod reserves nothing.
#   - core and gateway were each counted with their wait-for-oidc initContainer
#     ADDED to their containers. A pod's request is
#     max(sum(containers), max(initContainers)); init containers overlap, they
#     do not add.
#
# Measured 2026-08-29 with `make resource-audit`, apps at floor, and reconciled
# against the kubelet's own Allocated resources on all three nodes:
#
#   all-namespace requests, Running pods only      9878Mi
#     with the apps at their HPA ceiling          12822Mi   core 1->3, gateway 2->4
#     with keycloak's correction (#340)           12950Mi   768 -> 896Mi
#   less what the tainted control plane carries      532Mi
#   to seat on the two fixed workers              12418Mi
#   two cx33 allocatable                          14306Mi
#                                                 => 87% booked, 1888Mi spare
#
# Still tight, and now tight for reasons that are real. Cluster-wide, requests
# exceed usage by about 3GB (0.70x). The three largest gaps are all somebody
# else's card: observability (0.72, T-2.27 #341), argocd (0.49 at idle -- #306
# sized it from a controller reconciling at 823Mi, which is the right basis and
# not the idle one), and kube-system, which declares 318Mi and uses more than
# that because eleven pods there declare nothing at all (T-2.25, #339).
#
# WHAT ACTUALLY BINDS IS NODE COUNT, NOT MEMORY. The gateway's one-replica-per-
# node rule means four replicas need four nodes regardless of how much memory
# each node has; a bigger node type would not help. The load test confirmed it:
# every FailedScheduling event named `Insufficient cpu` and anti-affinity, and
# none named memory.
#
# This block is here so the next person to raise an HPA ceiling knows the memory
# numbers are recorded, that node count is the constraint to check first, and
# that the way to refresh these figures is to run the script rather than to read
# `kubectl get pods` and add up.

# THAT LAST CLAUSE WAS WRONG, AND A LOAD TEST SHOWED IT (T-2.23, #306).
#
# This used to say the fixed workers "are sized for peak application load, so
# the application never waits for a node to appear before it can serve", and
# above it that "a k6 load will never produce a scale-up". `make load` on
# 2026-08-29 produced one:
#
#   01:33:37  core=1 gateway=2   2 Pending   3 nodes
#   01:34:20  core=1 gateway=4   0 Pending   5 nodes
#   01:36:29  core=3 gateway=4   0 Pending   5 nodes   <- ceiling, all placed
#   01:57:31  core=1 gateway=2   0 Pending   3 nodes   <- drained
#
# The SLOs held throughout -- 472,105 checks, zero failures, p95 11.93ms.
#
# It waits for a node BY DESIGN, and the design is right. gateway.yaml requires
# one replica per node because T-5.12 measured two on one node costing 1.7x the
# CPU for the same work, and it says plainly that "the fourth replica goes
# Pending, and Pending is the one signal the cluster-autoscaler listens to".
# Pending is the mechanism, not a fault.
#
# So the correct statement is the opposite of the old one: the fixed workers
# seat the application at its FLOOR, and reaching the HPA ceiling requires the
# autoscaled pool by design. What the scheduler actually reported when it
# blocked was `Insufficient cpu` and `didn't match pod anti-affinity rules` --
# memory was never mentioned.
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

# The key's own expiry, copied from the admin console on 2026-08-29 (T-1.30).
#
# 90 days is the maximum Tailscale allows and this key takes it, so this date
# moves roughly quarterly and its being wrong is the expected failure. It fails
# closed: `make preflight` compares it against the clock, warns inside 30 days
# and refuses an apply past it, so a date left stale by a rotation stops a build
# rather than waving one through.
#
# Nothing recomputes this. The console is the source of truth and the project
# holds no Tailscale API key to ask it (#290), which is the whole reason the
# date is written down here at all.
tailscale_auth_key_expires_at = "2026-11-17"

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
