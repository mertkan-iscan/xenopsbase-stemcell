#cloud-config
# The ENTIRE bootstrap for a node (T-1.19, #251).
#
# WHAT IS NOT HERE, AND WHY THAT IS THE POINT
#
# kube-hetzner's generated cloud-init carries a verified-installer script that
# downloads k3s, checks its signature, compiles the SELinux policy and installs
# a systemd unit. Base64-encoded inside a script, base64-encoded inside a
# payload, then gzipped -- and base64 defeats compression at each layer, so the
# result measured 35,332 bytes against Hetzner's 32,768 limit. Every autoscaled
# node creation failed with, verbatim:
#
#   could not create server type cx33 in region fsn1:
#   invalid input in field 'user_data' (invalid_input)
#
# All of that is now in the image (T-1.18): the k3s binary at its pinned
# version, Tailscale, the compiled SELinux policy, and the k3s-agent unit.
# What remains is what genuinely cannot be baked -- the secrets and the
# per-node facts -- and it fits in about a kilobyte.
#
# NO SECRETS IN THE IMAGE. A snapshot outlives the cluster it was built for and
# is readable by anything with project access (ADR-0008), so the join token and
# the Tailscale key arrive HERE, at boot, per node.
#
# EVERY VALUE BELOW MATCHES A RUNNING STATIC AGENT
#
# The config was read off a live conventionally-built node rather than
# reconstructed from the module's templates, because the two paths must produce
# the same node and a template is a description of what should happen. What
# differs between a static and an autoscaled node must be only the node's own
# name and address.
# ROOT MUST STAY REACHABLE (T-1.27, #288).
#
# cloud-init's default is disable_root: true, and it does not merely skip
# adding a key -- it rewrites root's authorized_keys with a forced command, so
# the connection is accepted and then answered with:
#
#   Please login as the user "root" rather than the user "root".
#
# which names no cause and is not obviously about cloud-init at all. The
# module's own nodes are unaffected because terraform provisions them over SSH
# and its cloud-init keeps root open; ours had no such line, so every node from
# this bootstrap has been unreachable since #251. Nobody noticed, because until
# T-1.23 the only nodes using it were autoscaled ones and nobody logs into
# those.
#
# It matters now for one reason: the node you need to open a shell on is the
# one that failed to join, and that is precisely the node no kubectl can reach.
# Both T-1.23 builds ended with a question that could only be answered on the
# node, and neither could be answered.
#
# About twenty bytes against a 2 KB budget. make user-data-size is the gate.
disable_root: false

# NODE LABELS AND TAINTS COME FROM THE POOL (T-1.23, #282).
#
# The extra_node_labels and node_taints parameters below are rendered from the
# pool's own `labels` and `taints` in main.tf. (Written without the template
# syntax on purpose: templatefile interpolates comments too, and a multi-line
# value would spill past the leading # and land in the cloud-config as
# top-level YAML.)
#
# The module used to apply them and stopped
# being given the pools, so between #282 and this they were declared in the
# tfvars, accepted by the variable, and silently dropped.
#
# Both keep the module's spelling, so a tfvars file does not change:
#
#   labels = ["workload=general"]
#   taints = ["dedicated=db:NoSchedule"]
#
# Both render to nothing when the pool declares none, which is every pool
# today -- so this costs no user_data bytes until someone uses it.
write_files:
  - path: /etc/rancher/k3s/config.yaml
    permissions: '0600'
    content: |
      "flannel-iface": "eth1"
      "kubelet-arg":
      - "cloud-provider=external"
      - "volume-plugin-dir=/var/lib/kubelet/volumeplugins"
      - "kube-reserved=cpu=50m,memory=300Mi,ephemeral-storage=1Gi"
      - "system-reserved=cpu=250m,memory=300Mi"
      "node-label":
      - "k3s_upgrade=true"
      - "hcloud/node-group=${node_group}"
${extra_node_labels}
      "node-taint":${node_taints}
      "selinux": true
      "server": "${server_url}"
      "token": "${cluster_token}"

runcmd:
  # ---------------------------------------------------------------------------
  # 1. Tailscale. The operator path to this cluster is the tailnet (ADR-0006),
  #    and a node that is not on it cannot be reached to debug when it fails to
  #    join -- which is exactly when you need to.
  #
  #    The key must be REUSABLE: a single-use key registers the first node and
  #    the rest hang waiting to join.
  #
  #    IT SHOULD ALSO BE EPHEMERAL AND IS NOT (T-1.29, #290). This comment used
  #    to assert it was, and the tailnet says otherwise -- eight offline devices
  #    for a cluster that has been rebuilt eight times, each still holding the
  #    name its successor wanted:
  #
  #      xenopsbase-dev-worker-0      offline, last seen 31m ago
  #      xenopsbase-dev-worker-0-1    offline, last seen 6m ago
  #      xenopsbase-dev-worker-0-2    the node actually running
  #
  #    Tailscale appends a suffix when a name is taken, so MagicDNS answers
  #    `xenopsbase-dev-worker-0` with a corpse and anything addressing a node by
  #    name reaches nothing. That is why verify-node-provenance resolves through
  #    `tailscale status` instead of trusting the name.
  #
  #    Ephemerality is a property of the key as issued, not of the `tailscale up`
  #    below, so this cannot be fixed here: the key has to be reissued as
  #    ephemeral in the Tailscale admin console and the existing devices removed.
  #    make verify-teardown reports the count after every destroy so the number
  #    is visible rather than discovered.
  #
  #    Run through `sh -c` rather than as an exec list, because cloud-init's
  #    list form does NOT go through a shell -- $(hostname) would be passed to
  #    tailscale as six literal characters, and the node would register under
  #    whatever default name it chose. Silent, and only visible much later as a
  #    tailnet full of wrongly-named devices.
  - ['sh', '-c', '/usr/local/bin/tailscale up --authkey="${tailscale_auth_key}" --hostname="$(hostname)" --accept-dns=false']

  # ---------------------------------------------------------------------------
  # 2. node-ip, discovered rather than templated.
  #
  #    An autoscaled node's private address is assigned by Hetzner when the
  #    server is created, so it is not knowable when this file is written. It is
  #    read from eth1 -- the private network interface, the same one
  #    flannel-iface names.
  #
  #    Appending rather than templating keeps the two facts that vary per node
  #    (its address and its name) in one place, and k3s reads config.yaml at
  #    start, after this has run.
  #    WAITED FOR, not read once. Attaching the network at server creation
  #    makes the interface present at boot, but its address still arrives over
  #    DHCP -- and reading a moment too early writes node-ip: "", which k3s
  #    rejects permanently rather than retrying. Nineteen restarts on one node
  #    of build 4, while the address it wanted was there the whole time.
  #
  #    Sixty seconds, then fail loudly: a node with no private address cannot
  #    join, and a silent one is the node nobody looks at.
  - ['sh', '-c', 'for i in $(seq 1 60); do ip=$(ip -4 -o addr show eth1 2>/dev/null | awk ''{print $4}'' | cut -d/ -f1); [ -n "$ip" ] && break; sleep 1; done; test -n "$ip" || { echo "eth1 has no address after 60s" >&2; exit 1; }; printf ''\"node-ip\": \"%s\"\n'' "$ip" >> /etc/rancher/k3s/config.yaml']
  - ['sh', '-c', 'printf ''"node-name": "%s"\n'' "$(hostname)" >> /etc/rancher/k3s/config.yaml']

  # ---------------------------------------------------------------------------
  # 3. Start the agent. The binary, the unit and the SELinux policy are all
  #    already on disk, so this is genuinely just `enable --now` -- no download,
  #    no compile, no package repository. A node joins in seconds instead of
  #    minutes, and an install that would have failed does so at image build
  #    time rather than at the moment capacity is needed.
  - ['systemctl', 'enable', '--now', 'k3s-agent']
