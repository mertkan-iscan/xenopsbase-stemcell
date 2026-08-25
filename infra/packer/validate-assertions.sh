#!/usr/bin/env bash
#
# What a golden image must be true of AFTER IT BOOTS (T-1.20, #252).
#
# Runs on a throwaway instance created from the candidate snapshot, over SSH,
# by validate-golden-image.sh. It never runs on the build instance -- that is
# the entire point. The build instance was already booted, already had a
# machine-id, already had cloud-init state. A snapshot of it might not boot at
# all, and until something boots one, nothing here is known.
#
# THIS FILE IS A LIST ON PURPOSE
#
# What is and is not covered should be readable in one pass, without
# reconstructing it from control flow, so that the next person to ask "does the
# image check X?" gets an answer by reading rather than by testing.
#
# Every assertion runs, passes or fails independently, and the run reports ALL
# failures rather than stopping at the first. One boot costs several minutes
# and a billable server, so finding three problems in one boot is worth a good
# deal more than finding the first one slightly sooner.
#
# Usage (from validate-golden-image.sh):
#   ssh root@host 'bash -s' -- "$K3S_VERSION" "$TAILSCALE_VERSION" < this
#
set -uo pipefail

K3S_WANT="${1:?expected k3s version}"
TS_WANT="${2:?expected tailscale version}"

PASS=0
FAIL=0

# assert <name> <shell snippet> -- runs it, records it, and keeps going.
assert() {
  name="$1"
  shift
  if out="$(bash -c "$*" 2>&1)"; then
    printf '  ok    %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/          /'; fi
    FAIL=$((FAIL + 1))
  fi
}

echo "=================================================================="
echo " Golden image, booted:  $(hostname)"
echo "=================================================================="

# ---------------------------------------------------------------------------
echo ""
echo "IT BOOTS  (only a real boot can answer these)"

# cloud-init 'degraded done' is still done: it means an optional module
# complained. 'error' is not.
assert "cloud-init finished without error" \
  'cloud-init status --wait | grep -qE "status: (done|degraded done)"'

# The build empties /etc/machine-id so systemd generates a fresh one per node.
# If that regeneration does not happen, every node from this image is the same
# host to systemd, journald and anything keyed on it -- and the symptom appears
# a very long way from the cause.
assert "machine-id regenerated on first boot" \
  'test -s /etc/machine-id && test $(wc -c < /etc/machine-id) -ge 32'

# Networking came up unaided. A node that cannot route cannot join.
assert "has a default route" 'ip route | grep -q "^default"'
assert "can resolve and reach the internet" \
  'curl -fsS --max-time 20 -o /dev/null https://github.com'

# ---------------------------------------------------------------------------
echo ""
echo "VERSIONS ARE THE PINNED ONES"

assert "k3s is $K3S_WANT" \
  "/usr/local/bin/k3s --version | grep -q -- '$K3S_WANT'"
assert "tailscale is $TS_WANT" \
  "/usr/local/bin/tailscale --version | head -1 | grep -q '$TS_WANT'"

# ---------------------------------------------------------------------------
echo ""
echo "THE BINARIES ACTUALLY RUN HERE"

# WHY `k3s check-config` IS NOT THE GATE HERE
#
# It was, for two builds, and it was the wrong tool. It reports on the KERNEL,
# and this build cannot change the kernel: the golden image adds binaries and
# an SELinux policy on top of kube-hetzner's base snapshot, and every finding
# check-config produces belongs to that base. Gating on it means failing for
# something this layer has no way to fix.
#
# It also carries known-stale entries. On kernel 6.12 it reports
# CONFIG_INET_XFRM_MODE_TRANSPORT missing -- an option deleted from Linux in
# 4.19 when transport mode moved into the xfrm core -- along with the cgroup v1
# controllers, on a host that is cgroup v2 only. Neither is a defect.
#
# The decisive evidence is not that reasoning. It is that this cluster is
# running k3s v1.36.3+k3s1, Ready, on this exact base image and kernel:
#
#   xenopsbase-dev-worker-pud  Ready  v1.36.3+k3s1  openSUSE Leap Micro 6.2
#                                                   6.12.0-160000.37-default
#
# So instead of relaying another tool's opinion, the specific prerequisites are
# asserted directly. Each one is something a kubelet genuinely cannot start
# without, and something a bad image or a bad base bump would actually break --
# which keeps the early warning without inheriting a gate that can never pass.

# The commonest single reason a kubelet refuses to start. systemd mounts this
# at boot, so it is also a real check that the image booted properly rather
# than into something degraded.
assert "cgroup v2 unified hierarchy is mounted" \
  'test -f /sys/fs/cgroup/cgroup.controllers'
assert "cgroup v2 exposes cpu, memory and pids" \
  'for c in cpu memory pids; do grep -qw "$c" /sys/fs/cgroup/cgroup.controllers || { echo "have: $(cat /sys/fs/cgroup/cgroup.controllers)"; exit 1; }; done'

# AVAILABLE TO LOAD, not loaded. k3s loads these when an agent starts, and this
# image has never run one -- asserting they were loaded would only pass on a
# node that had already done the thing this image is supposed to do later.
# overlay backs the container filesystem, vxlan is flannel's default backend,
# br_netfilter is what makes iptables see bridged traffic.
assert "overlay, br_netfilter and vxlan are available to load" \
  'for m in overlay br_netfilter vxlan; do modprobe -n "$m" || { echo "cannot load: $m"; exit 1; }; done'

# tailscaled is ENABLED but holds no key, so it should come up on boot and sit
# logged out. Running matters more than it sounds: it is what modprobes tun and
# creates the interface, and it is what caught the unit file in the first image
# pointing at /usr/sbin/tailscaled on an OS whose /usr is read-only.
assert "tailscaled is running" \
  'systemctl is-active --quiet tailscaled || { systemctl status tailscaled --no-pager -l 2>&1 | tail -20; false; }'
assert "the tailscale0 interface exists" \
  'ip link show tailscale0 || { ip -br link; false; }'
assert "tailscale holds no identity" \
  'tailscale status 2>&1 | grep -qiE "logged out|log in at|needslogin"'

# ---------------------------------------------------------------------------
echo ""
echo "SELINUX IS ENFORCING, WITH THE POLICY LOADED"

# Read from the kernel, not from `getenforce` and not from the config file.
# /etc/selinux/config says what was requested; /sys says what the kernel is
# doing now. Trading enforcement away to save user_data bytes was considered
# and rejected on #22 -- this is what stops it happening later by accident.
assert "kernel reports enforcing" 'test "$(cat /sys/fs/selinux/enforce)" = 1'

# LOADED, not merely present on disk. Compiling the policy at build time is the
# whole saving; a .pp sitting unloaded in the image would be all of the cost
# and none of the effect.
assert "kube_hetzner_selinux policy is loaded" \
  'semodule -l | grep -qx kube_hetzner_selinux'
assert "k8s_custom_policies policy is loaded" \
  'semodule -l | grep -qx k8s_custom_policies'

# ---------------------------------------------------------------------------
echo ""
echo "IT CARRIES NO SECRETS"
#
# A snapshot outlives the cluster it was built for, is readable by anything
# with project access, and `make down` does not remove it (ADR-0008). These
# repeat the build-time checks deliberately: the build could remove a file that
# a first-boot unit puts back, and only a boot shows that.

assert "no tailscale auth key anywhere" \
  '! grep -rqiE "tskey-[a-z]+-" /etc /root /var/lib 2>/dev/null'
assert "no k3s node token" 'test ! -s /var/lib/rancher/k3s/server/node-token'
assert "no k3s config" 'test ! -e /etc/rancher/k3s/config.yaml'

# NOT "the state file does not exist". tailscaled is enabled, so it starts on
# boot and generates a machine key -- which is correct and is what every real
# node does. What must not happen is the IMAGE carrying one, because then every
# node cloned from it shares an identity.
#
# The distinguishing fact is when the file was written: after this boot means
# generated here, before it means baked in. Asserting mere absence would have
# been a check that only passed while tailscaled was broken, and would have
# started failing the moment it was fixed.
assert "any tailscale identity was generated at boot, not baked in" \
  'test ! -e /var/lib/tailscale/tailscaled.state || test "$(stat -c %Y /var/lib/tailscale/tailscaled.state)" -ge "$(date -d "$(uptime -s)" +%s)"'

# The image must ship no key of its own. After boot, root's authorized_keys
# holds exactly the throwaway key this validation injected -- so "one key, and
# it is ours" is the assertion, and a second line means the image baked one.
assert "root authorized_keys holds only this run's throwaway key" \
  'test "$(grep -c . /root/.ssh/authorized_keys)" -eq 1'

# ---------------------------------------------------------------------------
echo ""
echo "IT HAS NEVER JOINED ANYTHING"
#
# An image captured from a node that ran is a cluster member cloned N times,
# which is a memorably confusing outage.

# PRESENT but NOT ENABLED (T-1.19, #251). The unit is baked so that user_data
# does not carry a kilobyte of unchanging systemd on every node; enabling it is
# the bootstrap's job, once a config and a join token exist. An image that boots
# straight into an agent is a cluster member cloned N times.
assert "the k3s-agent unit is present" \
  'test -f /etc/systemd/system/k3s-agent.service'
assert "the k3s-agent unit points at the baked binary" \
  'grep -q "ExecStart=/usr/local/bin/k3s" /etc/systemd/system/k3s-agent.service'
assert "no k3s unit is enabled" \
  '! systemctl list-unit-files "k3s*" --state=enabled 2>/dev/null | grep -q k3s'
assert "no k3s agent state" 'test ! -d /var/lib/rancher/k3s/agent'
assert "no kubelet identity" 'test ! -d /var/lib/kubelet/pki'

# ---------------------------------------------------------------------------
echo ""
echo "IT IS THE INFRASTRUCTURE LAYER ONLY"
#
# Application code belongs in container images, deployed by GitOps. Baking it
# here would make an application release an OS release.

assert "no application directory" 'test ! -e /app'
assert "no jars" '! ls /opt/*.jar >/dev/null 2>&1'

# ---------------------------------------------------------------------------
echo ""
echo "=================================================================="
if [ "$FAIL" -gt 0 ]; then
  echo " $FAIL FAILED, $PASS passed - this image must not be promoted"
  echo "=================================================================="
  exit 1
fi
echo " all $PASS assertions passed"
echo "=================================================================="
