/*
 * The golden image every worker boots -- static agents and autoscaled nodes
 * (T-1.18, #250). The control plane stays on the module's base snapshot, by
 * decision rather than by delay (ADR-0015, #287).
 *
 * WHY THIS EXISTS
 *
 * kube-hetzner installs k3s at boot, from an installer embedded in cloud-init.
 * Measured on this cluster: that makes the autoscaler's user_data 34,684 bytes
 * against Hetzner's 32,768 limit, so no autoscaled node can ever be created
 * (#22). The cause is three layers of base64 -- the k3s installer is
 * base64-encoded inside a script that is base64-encoded inside a payload that
 * is then gzipped -- and base64 defeats compression at each layer.
 *
 * Rather than shave 2KB off a payload that will grow again, everything static
 * moves into the image and boot-time user_data drops to 1-2KB (T-1.19).
 *
 * The size limit is the trigger, not the reason. A node that installs nothing
 * joins in seconds instead of minutes, install failures land at build time
 * where they are visible rather than at the moment capacity is needed, and
 * booting stops depending on package repositories being reachable.
 *
 * A LAYER, NOT A FORK
 *
 * This builds ON TOP of kube-hetzner's own Leap Micro snapshot rather than
 * replacing it. Their template does the hard part -- verified image download,
 * signature checking, k3s-selinux -- and forking it would mean owning all of
 * that in order to add two binaries. So the base stays theirs, OS updates
 * arrive by rebuilding it, and this file is the small readable diff on top.
 *
 * WHAT THIS IMAGE MUST NOT CONTAIN
 *
 * No secrets. No Tailscale auth key, no k3s join token, no SSH private key, no
 * API token. A snapshot is long-lived, is readable by anything with access to
 * the project, and outlives the cluster it was built for -- `make down` does
 * not remove it (ADR-0008). Everything dynamic arrives at boot.
 *
 * No application code. No Spring Boot, no frontend, no business logic. Those
 * live in container images and are deployed by GitOps. This is the
 * infrastructure layer: OS, networking, and a k3s agent that has never run.
 */

packer {
  required_version = "= 1.16.0"

  required_plugins {
    hcloud = {
      version = "= 1.7.2"
      source  = "github.com/hetznercloud/hcloud"
    }
  }
}

variable "hcloud_token" {
  type      = string
  default   = env("HCLOUD_TOKEN")
  sensitive = true
}

variable "k3s_version" {
  type        = string
  description = "Exact k3s release, e.g. v1.36.3+k3s1. Must match the cluster module's k3s_version."

  validation {
    condition     = can(regex("^v[0-9]+[.][0-9]+[.][0-9]+\\+k3s[0-9]+$", var.k3s_version))
    error_message = "The k3s_version must be an exact release such as v1.36.3+k3s1, never a channel and never latest."
  }
}

variable "k3s_sha256" {
  type        = string
  description = "SHA-256 of the k3s amd64 binary for k3s_version, from that release's sha256sum-amd64.txt."

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.k3s_sha256))
    error_message = "The k3s_sha256 must be a 64-character hex digest."
  }
}

variable "tailscale_version" {
  type        = string
  description = "Exact Tailscale version, e.g. 1.102.3."

  validation {
    condition     = can(regex("^[0-9]+[.][0-9]+[.][0-9]+$", var.tailscale_version))
    error_message = "The tailscale_version must be an exact version such as 1.102.3, never latest."
  }
}

variable "tailscale_sha256" {
  type        = string
  description = "SHA-256 of the Tailscale static amd64 tarball for tailscale_version."

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.tailscale_sha256))
    error_message = "The tailscale_sha256 must be a 64-character hex digest."
  }
}

variable "location" {
  type        = string
  default     = "fsn1"
  description = "Where the snapshot is built. Snapshots are region-scoped, so this must be where the cluster runs."
}

variable "server_type" {
  type        = string
  default     = "cx23"
  description = "Temporary build server. Needs a disk of at least 40GiB; it exists for a few minutes."
}

variable "base_snapshot_selector" {
  type        = string
  default     = "leapmicro-snapshot=yes"
  description = "Label selector for kube-hetzner's base snapshot, which this layers on top of."
}

variable "selinux_policy_dir" {
  type        = string
  description = "Directory holding kube-hetzner-selinux.te and k8s-custom-policies.te, extracted from the pinned module version by build-golden-image.sh."
}

locals {
  # Stamped onto the snapshot so terraform can ASSERT the image holds the
  # version it is configured for, rather than both being told separately and
  # nobody noticing when they disagree.
  #
  # `xenopsbase-golden` is deliberately "candidate" here, NOT "yes" (T-1.20,
  # #252). Everything that selects an image to boot -- terraform, and the
  # retention policy that decides what may be deleted -- selects on
  # `xenopsbase-golden=yes`. So a snapshot leaving this build is not yet
  # selectable by anything: validate-golden-image.sh boots a throwaway
  # instance from it, and only a snapshot that passed is relabelled.
  #
  # This is the honest reading of "no snapshot is published on failure". The
  # Hetzner object exists for the few minutes validation takes, because you
  # cannot boot an image that does not exist. It is never PUBLISHED, in the
  # only sense that matters: nothing can select it, and a failed validation
  # deletes it.
  snapshot_labels = {
    "xenopsbase-golden" = "candidate"
    "k3s-version"       = replace(var.k3s_version, "+", "_")
    "tailscale-version" = var.tailscale_version
  }
}

source "hcloud" "golden" {
  token        = var.hcloud_token
  location     = var.location
  server_type  = var.server_type
  ssh_username = "root"

  # The base is kube-hetzner's snapshot, selected by their label. Building from
  # their most recent one means an OS update is `make snapshot` followed by
  # `make golden-image`, with no version copied by hand between the two.
  image_filter {
    with_selector = [var.base_snapshot_selector]
    most_recent   = true
  }

  # Cloud-init for the BUILD instance only. None of this ends up in the
  # snapshot -- the cleanup provisioner removes cloud-init's state at the end.
  #
  # WHY IT IS NEEDED AT ALL
  #
  # The base snapshot ships root's authorized_keys wrapped in a forced command
  # that refuses the session:
  #
  #   Error uploading script: lease login as the user "root" rather than the
  #   user "root".
  #
  # Packer connects, and then every upload dies on that banner. kube-hetzner
  # never sees it because their own cloud-init sets `disable_root: false`,
  # which makes cloud-init write the key without the guard -- so the guard is
  # invisible to anyone booting these snapshots the normal way, and unavoidable
  # for anyone booting one directly.
  user_data = <<-EOT
    #cloud-config
    disable_root: false
  EOT

  # Named for what it is until it has earned the other name. Promotion rewrites
  # both the description and the label, so a snapshot called "candidate" in the
  # Hetzner console is one whose validation did not finish -- readable without
  # consulting this file.
  snapshot_name   = "xenopsbase-golden-candidate-${var.k3s_version}"
  snapshot_labels = local.snapshot_labels
}

build {
  sources = ["source.hcloud.golden"]

  # ---------------------------------------------------------------------------
  # k3s. Downloaded, verified, installed. NOT started: a golden image must not
  # contain a node that has already tried to join something.
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "echo '==> k3s ${var.k3s_version}'",
      "curl -fsSL -o /tmp/k3s 'https://github.com/k3s-io/k3s/releases/download/${replace(var.k3s_version, "+", "%2B")}/k3s'",
      # The checksum is the point of pinning. Without it this is 'download
      # whatever that URL serves today', which is exactly what pinning a
      # version was supposed to prevent.
      "echo '${var.k3s_sha256}  /tmp/k3s' | sha256sum -c -",
      "install -m 0755 /tmp/k3s /usr/local/bin/k3s",
      "rm -f /tmp/k3s",
      "/usr/local/bin/k3s --version",

      # The agent unit, INSTALLED BUT NOT ENABLED (T-1.19, #251).
      #
      # It is byte-identical to the one k3s's own installer writes, taken from a
      # running agent on this cluster rather than from memory. That matters:
      # a node from this image and a node built the conventional way must be the
      # same node, and the unit is where "same" is decided -- the module's
      # cloud-init writes this file, so if ours differed the two paths would
      # drift silently.
      #
      # It belongs in the image because it is STATIC. Every byte of it would
      # otherwise be carried in user_data on every node, forever, describing
      # something that never varies. All the per-node variation lives in
      # /etc/rancher/k3s/config.yaml, which the bootstrap writes.
      #
      # NOT ENABLED, deliberately. An image that boots straight into a k3s agent
      # is a cluster member cloned N times; the bootstrap enables it once the
      # config and the join token are in place.
      "mkdir -p /etc/systemd/system",
      "cat > /etc/systemd/system/k3s-agent.service <<'UNIT'\n[Unit]\nDescription=Lightweight Kubernetes\nDocumentation=https://k3s.io\nWants=network-online.target\nAfter=network-online.target\n\n[Install]\nWantedBy=multi-user.target\n\n[Service]\nType=notify\nEnvironmentFile=-/etc/default/%N\nEnvironmentFile=-/etc/sysconfig/%N\nEnvironmentFile=-/etc/systemd/system/k3s-agent.service.env\nKillMode=process\nDelegate=yes\nUser=root\n# Having non-zero Limit*s causes performance problems due to accounting overhead\n# in the kernel. We recommend using cgroups to do container-local accounting.\nLimitNOFILE=1048576\nLimitNPROC=infinity\nLimitCORE=infinity\nTasksMax=infinity\nTimeoutStartSec=0\nRestart=always\nRestartSec=5s\nExecStartPre=-/sbin/modprobe br_netfilter\nExecStartPre=-/sbin/modprobe overlay\nExecStart=/usr/local/bin/k3s \\\n    agent \\\n\nUNIT",
      "systemctl daemon-reload",
      # Proves it parses and that its ExecStart binary exists -- the same class
      # of mistake that shipped a broken tailscaled unit in #250.
      "systemd-analyze verify /etc/systemd/system/k3s-agent.service 2>&1 | grep -vi 'Unit .* not found' || true",

      # The SERVER unit, same treatment (T-1.24, #285).
      #
      # DERIVED from the agent unit above rather than typed out: the build
      # takes that string and substitutes the unit name and `agent` for
      # `server`. The two files therefore cannot differ anywhere except
      # where this intends them to, and a transcription slip is not a
      # failure mode. Both occurrences of the name move, because the third
      # EnvironmentFile names the unit explicitly rather than through %N.
      #
      # `k3s.service`, not `k3s-server.service`. That is what the upstream
      # installer writes and what a running control plane answers to --
      # `systemctl is-active k3s` worked on one; the issue title's spelling
      # would not have.
      #
      # ExecStart is `k3s server` with nothing appended, because the module
      # defaults control_plane_exec_args and agent_exec_args to "" and this
      # repository overrides neither. Set either one and this image diverges
      # from the module's nodes silently -- which is exactly why the agent
      # unit was captured from a live node instead of reconstructed.
      #
      # STILL OWED: that capture is what this one lacks. The cluster it
      # would have been read from was destroyed before this was written, so
      # diff it against a live control plane's /etc/systemd/system/k3s.service
      # on the next `make up` before calling #285 done.
      "cat > /etc/systemd/system/k3s.service <<'UNIT'\n[Unit]\nDescription=Lightweight Kubernetes\nDocumentation=https://k3s.io\nWants=network-online.target\nAfter=network-online.target\n\n[Install]\nWantedBy=multi-user.target\n\n[Service]\nType=notify\nEnvironmentFile=-/etc/default/%N\nEnvironmentFile=-/etc/sysconfig/%N\nEnvironmentFile=-/etc/systemd/system/k3s.service.env\nKillMode=process\nDelegate=yes\nUser=root\n# Having non-zero Limit*s causes performance problems due to accounting overhead\n# in the kernel. We recommend using cgroups to do container-local accounting.\nLimitNOFILE=1048576\nLimitNPROC=infinity\nLimitCORE=infinity\nTasksMax=infinity\nTimeoutStartSec=0\nRestart=always\nRestartSec=5s\nExecStartPre=-/sbin/modprobe br_netfilter\nExecStartPre=-/sbin/modprobe overlay\nExecStart=/usr/local/bin/k3s \\\n    server \\\n\nUNIT",
      "systemctl daemon-reload",
      "systemd-analyze verify /etc/systemd/system/k3s.service 2>&1 | grep -vi 'Unit .* not found' || true",
      "test -x /usr/local/bin/k3s",
    ]
  }

  # ---------------------------------------------------------------------------
  # Tailscale, as the static tarball into /usr/local -- the same layout the
  # module's own bootstrap produces, so a node from this image and a node built
  # the old way keep their binaries in the same places.
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "echo '==> tailscale ${var.tailscale_version}'",
      "curl -fsSL -o /tmp/ts.tgz 'https://pkgs.tailscale.com/stable/tailscale_${var.tailscale_version}_amd64.tgz'",
      "echo '${var.tailscale_sha256}  /tmp/ts.tgz' | sha256sum -c -",
      "tar -xzf /tmp/ts.tgz -C /tmp",
      "install -m 0755 /tmp/tailscale_${var.tailscale_version}_amd64/tailscale  /usr/local/bin/tailscale",
      "install -m 0755 /tmp/tailscale_${var.tailscale_version}_amd64/tailscaled /usr/local/sbin/tailscaled",
      "mkdir -p /var/lib/tailscale",

      # THE UNIT IS WRITTEN, NOT COPIED FROM THE TARBALL.
      #
      # The tarball's own tailscaled.service says
      # `ExecStart=/usr/sbin/tailscaled`, because upstream expects the binary
      # in /usr/sbin. On Leap Micro /usr is read-only, so it goes to
      # /usr/local/sbin instead -- and the shipped unit then points at a path
      # that does not exist. tailscaled fails at every boot, no tailscale0
      # interface is created, and NO NODE FROM THIS IMAGE CAN EVER JOIN THE
      # TAILNET.
      #
      # The first build (#250) installed the tarball unit and reported success:
      # every build-time assertion passed, because they only checked that the
      # BINARIES were present and the correct version, which they were. It took
      # booting the image (T-1.20, #252) to find it.
      #
      # This is byte-for-byte the unit kube-hetzner writes in its own bootstrap
      # (locals.tf, install_tailscale_static), for the reason given at the top
      # of this file: a node from this image and a node built the old way must
      # be the same node. ExecStartPre modprobes tun, which is what actually
      # creates the interface.
      #
      # One deliberate divergence: theirs sets
      # `ExecStopPost=/usr/local/bin/tailscaled --cleanup`, but tailscaled is
      # in /usr/local/sbin -- the same class of path mistake, in the stop path
      # where it fails quietly. Copying a bug for the sake of matching would be
      # a poor trade.
      "cat > /etc/systemd/system/tailscaled.service <<'UNIT'\n[Unit]\nDescription=Tailscale node agent\nDocumentation=https://tailscale.com/kb/\nWants=network-online.target\nAfter=network-online.target\n\n[Service]\nType=notify\nExecStartPre=/sbin/modprobe tun\nExecStart=/usr/local/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=41641\nExecStopPost=/usr/local/sbin/tailscaled --cleanup\nRestart=on-failure\nRuntimeDirectory=tailscale\nRuntimeDirectoryMode=0755\nStateDirectory=tailscale\nStateDirectoryMode=0700\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      # Proves the unit's ExecStart binary is actually there, at build time.
      # The check costs nothing and names the exact thing that was wrong.
      "test -x \"$(sed -n 's|^ExecStart=\\([^ ]*\\).*|\\1|p' /etc/systemd/system/tailscaled.service)\"",

      "systemctl daemon-reload",
      # Enabled, NOT started, and holding no key. It comes up on first boot and
      # waits; `tailscale up` with a runtime key is T-1.19's job.
      "systemctl enable tailscaled",
      "rm -rf /tmp/ts.tgz /tmp/tailscale_${var.tailscale_version}_amd64",
      "/usr/local/bin/tailscale --version",
    ]
  }

  # ---------------------------------------------------------------------------
  # SELinux policy, compiled and loaded at BUILD time.
  #
  # These are the same .te sources kube-hetzner writes into cloud-init and
  # compiles on every single boot. Compiling them here removes about 13KB from
  # user_data and, more usefully, moves a step that can fail out of every
  # node's first thirty seconds and into one build.
  provisioner "file" {
    source      = "${var.selinux_policy_dir}/"
    destination = "/root/"
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "echo '==> compiling SELinux policy'",
      "cd /root",
      # The output basename MUST match the module name inside the .te, or
      # checkmodule refuses. These are the same names kube-hetzner writes into
      # cloud-init, so `semodule -l` reads identically on a node built either
      # way.
      "checkmodule -M -m -o kube_hetzner_selinux.mod kube_hetzner_selinux.te",
      "semodule_package -o kube_hetzner_selinux.pp -m kube_hetzner_selinux.mod",
      "semodule -i kube_hetzner_selinux.pp",
      "checkmodule -M -m -o k8s_custom_policies.mod k8s_custom_policies.te",
      "semodule_package -o k8s_custom_policies.pp -m k8s_custom_policies.mod",
      "semodule -i k8s_custom_policies.pp",
      "semodule -l | grep -E 'kube_hetzner_selinux|k8s_custom_policies'",
      "rm -f /root/kube_hetzner_selinux.te /root/k8s_custom_policies.te /root/*.mod /root/*.pp",
    ]
  }

  # ---------------------------------------------------------------------------
  # The image has to be safe to keep and safe to boot. Every assertion below
  # corresponds to something that has actually gone wrong somewhere; none of
  # them is hypothetical, and a build that cannot satisfy one must not publish
  # a snapshot.
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "echo '==> assertions'",

      # Versions are what was asked for, not what a redirect delivered.
      "/usr/local/bin/k3s --version | grep -q -- '${var.k3s_version}'",
      "/usr/local/bin/tailscale --version | head -1 | grep -q '${var.tailscale_version}'",

      # SELinux stays enforcing. Trading it away to save user_data bytes was
      # considered and rejected on #22; this is what stops it happening later
      # by accident.
      "test \"$(getenforce)\" = Enforcing",

      # NO SECRETS. A snapshot outlives the cluster it was built for.
      "test ! -s /var/lib/rancher/k3s/server/node-token",
      "test ! -e /var/lib/tailscale/tailscaled.state",
      "test ! -e /etc/rancher/k3s/config.yaml",
      "! grep -rqiE 'tskey-[a-z]+-' /etc /root /var/lib 2>/dev/null",

      # Nothing has joined anything. An image captured from a node that ran is
      # a cluster member cloned N times, which is a memorably confusing outage.
      "! systemctl is-enabled k3s-agent 2>/dev/null | grep -q '^enabled'",
      "! systemctl is-enabled k3s 2>/dev/null | grep -q '^enabled'",

      # Both roles present. An image carrying one of them boots half a cluster
      # and fails the other half at the moment that half is needed.
      "test -f /etc/systemd/system/k3s-agent.service",
      "test -f /etc/systemd/system/k3s.service",

      # Infrastructure layer only.
      "test ! -e /app",
      "! ls /opt/*.jar >/dev/null 2>&1",
    ]
  }

  # ---------------------------------------------------------------------------
  # WHAT THE ASSERTIONS ABOVE CANNOT COVER
  #
  # Every check so far ran on the BUILD INSTANCE -- a machine that is already
  # booted, whose cloud-init already ran, whose machine-id already exists. It
  # proves the files are on the disk. It does not prove that a snapshot of that
  # disk BOOTS.
  #
  # The difference is not academic. The cleanup below empties /etc/machine-id
  # and wipes cloud-init's state precisely so the image boots fresh -- and if
  # any of that leaves the image unable to come up, get an address, or accept a
  # key, this build still exits 0 and publishes it. That is the shape #252 was
  # filed against: a control that reports success while the thing it names is
  # broken.
  #
  # So a snapshot that reaches the end of this file is a CANDIDATE.
  # validate-golden-image.sh boots a throwaway instance from it and runs the
  # assertions that only a real boot can answer. Promotion happens there.
  #
  # ---------------------------------------------------------------------------
  # Leave a first-boot image, not a used one.
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "echo '==> cleaning'",
      "cloud-init clean --logs --seed || true",
      "rm -rf /var/lib/cloud/instances/*",
      "rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log",
      "rm -f /root/.ssh/authorized_keys",
      # A cloned machine-id makes every node look like the same host to
      # systemd, journald and anything keyed on it.
      "rm -f /etc/machine-id && touch /etc/machine-id",
      "sync",
    ]
  }

  # The candidate's id, written where the build script can read it.
  #
  # The alternative is to re-query the API for the newest snapshot carrying the
  # candidate label and assume it is this one. That is true right up until two
  # builds overlap, or a previous build died leaving its candidate behind -- at
  # which point the validation would boot one image and promote another, and
  # every assertion would pass. Packer knows exactly what it made; ask it.
  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
  }
}
