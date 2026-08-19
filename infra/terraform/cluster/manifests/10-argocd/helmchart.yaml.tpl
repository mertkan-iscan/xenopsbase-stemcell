# Argo CD, installed through k3s's own helm-controller rather than the Terraform
# helm provider.
#
# The provider would need a kubeconfig that is an output of the same apply,
# which means configuring a provider from a value Terraform does not know at
# plan time. That is the classic two-stage-apply trap, and it would turn "one
# bootstrap step" into two. k3s picks up this HelmChart resource and installs
# the release itself, inside the same terraform apply.
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: argo-cd
  namespace: kube-system
spec:
  chart: argo-cd
  repo: https://argoproj.github.io/argo-helm
  # Pinned. A floating chart means a rebuild can install a different Argo CD
  # than the last one for reasons nobody chose, which breaks the promise of
  # ADR-0002 that a rebuild reproduces what was there before.
  version: "${argocd_chart_version}"
  targetNamespace: argocd
  createNamespace: false
  valuesContent: |-
    global:
      domain: ${argocd_domain}

    configs:
      cm:
        # Required for KSOPS. Kustomize refuses to run an exec plugin without
        # both flags, and the failure is a bare "plugin not found" rather than
        # anything about flags.
        kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"

      params:
        # No TLS on the Argo API itself. Nothing reaches it from outside the
        # cluster: there is no ingress for it, and the public surface is one
        # tunnel (T-1.6). Access is by port-forward over the existing admin
        # path, so terminating TLS here would protect a hop that is already
        # inside the cluster.
        server.insecure: true

    # Deliberately trimmed for a small dev cluster. ADR-0004 accepted Argo CD's
    # footprint as the cost of its diagnosability, and that is a fair trade only
    # if the parts that are not used are not paid for.
    dex:
      enabled: false
    notifications:
      enabled: false
    applicationSet:
      # NOTE: verified NOT to take effect on chart 10.4.0 -- the
      # applicationset-controller runs regardless. dex and notifications are
      # genuinely gone; this one is not. Left in place because it is the
      # documented key and costs nothing, but do not read it as a statement
      # about what is running. ApplicationSet is useful later anyway (T-6.3
      # promotion between environments), so this is a footprint annoyance
      # rather than a problem to solve now.
      enabled: false

    server:
      resources:
        requests: {cpu: 50m, memory: 128Mi}

    # KSOPS: the cost ADR-0004 knowingly accepted when choosing Argo CD over
    # Flux, which decrypts SOPS natively. Argo needs the binary injected into
    # repo-server and the age key mounted, so decryption happens at manifest
    # render time rather than anything decrypted being stored in the cluster.
    repoServer:
      resources:
        requests: {cpu: 50m, memory: 128Mi}

      initContainers:
        # NOT the viaductoss/ksops image, despite that being the recipe in most
        # guides. Since v4.5 it is built on gcr.io/distroless/base, which has no
        # shell and no cp -- so `command: ["/bin/sh","-c"]` fails at container
        # creation with:
        #
        #   exec: "/bin/sh": stat /bin/sh: no such file or directory
        #
        # and the pod sits in Init:CrashLoopBackOff while the OLD repo-server
        # keeps serving, so Argo looks healthy while silently not picking up the
        # change.
        #
        # Downloading the release binary into a shared volume needs no shell in
        # the ksops image at all, and pins the exact version.
        - name: install-ksops
          image: alpine:3.22
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              wget -qO- "https://github.com/viaduct-ai/kustomize-sops/releases/download/v${ksops_version}/ksops_${ksops_version}_Linux_x86_64.tar.gz"                 | tar -xz -C /custom-tools ksops
              chmod +x /custom-tools/ksops
              /custom-tools/ksops --version || true
          volumeMounts:
            - mountPath: /custom-tools
              name: custom-tools

      volumes:
        - name: custom-tools
          emptyDir: {}
        - name: sops-age
          secret:
            # Created by Terraform, not by Argo. This is the one link in the
            # chain that cannot be reconciled from git, because it is the key
            # that makes reconciling from git possible (ADR-0003).
            secretName: sops-age

      volumeMounts:
        # kustomize is already present in the repo-server image, so only ksops
        # is injected. Overwriting the shipped kustomize would risk a version
        # skew against the Argo CD release for no benefit.
        - mountPath: /usr/local/bin/ksops
          name: custom-tools
          subPath: ksops
        - mountPath: /home/argocd/.config/sops/age
          name: sops-age
          readOnly: true

      env:
        - name: SOPS_AGE_KEY_FILE
          value: /home/argocd/.config/sops/age/keys.txt
    controller:
      resources:
        requests: {cpu: 100m, memory: 256Mi}
    redis:
      resources:
        requests: {cpu: 25m, memory: 64Mi}
