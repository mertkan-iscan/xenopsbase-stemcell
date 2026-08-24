/*
 * The golden image every node boots from (T-1.18, #250).
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
  snapshot_labels = {
    "xenopsbase-golden" = "yes"
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

  snapshot_name   = "xenopsbase-golden-${var.k3s_version}"
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
      "install -m 0644 /tmp/tailscale_${var.tailscale_version}_amd64/systemd/tailscaled.service /etc/systemd/system/tailscaled.service",
      "install -m 0644 /tmp/tailscale_${var.tailscale_version}_amd64/systemd/tailscaled.defaults /etc/default/tailscaled",
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
      "checkmodule -M -m -o kube-hetzner-selinux.mod kube-hetzner-selinux.te",
      "semodule_package -o kube-hetzner-selinux.pp -m kube-hetzner-selinux.mod",
      "semodule -i kube-hetzner-selinux.pp",
      "checkmodule -M -m -o k8s-custom-policies.mod k8s-custom-policies.te",
      "semodule_package -o k8s-custom-policies.pp -m k8s-custom-policies.mod",
      "semodule -i k8s-custom-policies.pp",
      "semodule -l | grep -E 'kube-hetzner-selinux|k8s-custom-policies'",
      "rm -f /root/kube-hetzner-selinux.te /root/k8s-custom-policies.te /root/*.mod /root/*.pp",
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

      # Infrastructure layer only.
      "test ! -e /app",
      "! ls /opt/*.jar >/dev/null 2>&1",
    ]
  }

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
}
