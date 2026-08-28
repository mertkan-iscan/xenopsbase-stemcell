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
  # NOT `bootstrap: true`, and the reason is worth keeping (T-1.23, #282).
  #
  # It was set here to give the install Job the control-plane toleration, so it
  # could run before any worker existed. It does grant that -- measured, the Job
  # was scheduled onto the tainted control plane and started.
  #
  # It also stops the cluster building. k3s applies bootstrap charts first and
  # holds the rest of /var/lib/rancher/k3s/server/manifests until they are
  # ready. Argo CD is not a bootstrap chart: its install loops on failure, so
  # ccm.yaml sat on disk unapplied, the node kept
  # node.cloudprovider.kubernetes.io/uninitialized, CoreDNS could not tolerate
  # that taint and stayed Pending, and the whole apply failed three times on a
  # CRD that was never going to appear.
  #
  # The flag is for small infrastructure charts the cluster cannot start
  # without -- CCM, CSI. Putting an application chart in that queue makes k3s
  # wait for the application before it finishes becoming a cluster.
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
        # No TLS on the Argo API itself.
        #
        # This stayed correct when Argo CD gained an ingress. TLS terminates at
        # Cloudflare's edge; from there the tunnel, ingress-nginx and this
        # server are all in-cluster hops, so serving TLS here would protect a
        # connection that never leaves the cluster.
        #
        # It is also what the ingress depends on: with the default HTTP backend
        # protocol, an ingress in front of a TLS-serving Argo CD returns 502
        # with nothing in the Argo logs. See platform/envs/dev/argocd.
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

      # BUT IT MUST STILL DECLARE ITSELF (T-2.23, #306).
      #
      # Because the disable does not take effect, this controller runs with no
      # requests at all -- which makes it BestEffort. A BestEffort pod is
      # invisible to the scheduler when it places anything else, and it is the
      # first thing the kubelet evicts under node memory pressure. So the
      # component that reconciles ApplicationSets is the one most likely to be
      # killed exactly when the cluster is under strain.
      #
      # Measured at 35-51Mi and 1-2m on an idle cluster; 64Mi is the same 1.25x
      # factor used below, rounded up. Small numbers, but declared ones: the
      # scheduler can only work with what it is told.
      resources:
        requests: {cpu: 25m, memory: 64Mi}

    # ARGO CD'S REQUESTS COME FROM MEASUREMENT, NOT FROM THE CHART (T-2.23, #306).
    #
    # THE FACTOR: requests are 1.25x measured steady-state usage, rounded up to a
    # round number. Written down because a number nobody can re-derive is a
    # number nobody can check.
    #
    # Measured on dev, 2026-08-29, with core and gateway deployed and the
    # platform idle:
    #
    #   component     was      measured   now     note
    #   controller    256Mi    823Mi      1Gi     was 3.2x under
    #   repo-server   128Mi    193Mi      256Mi   was 1.5x under
    #   server        128Mi     73Mi      96Mi    was over-booked
    #   redis          64Mi     20Mi      32Mi    was over-booked
    #
    # WHY UNDER-REQUESTING IS A SCHEDULING DEFECT, not a tuning nit: the
    # scheduler places by REQUESTS. A controller declared at 256Mi that needs
    # 823Mi means every placement decision involving it is wrong by 567Mi -- the
    # node accepts it, then discovers the truth later under memory pressure, by
    # evicting something. dev.tfvars already records that exact failure as
    # settled history (T-1.12, #133); the mechanism underneath it was never
    # addressed.
    #
    # CPU IS DELIBERATELY LEFT ALONE. Measured draw is 1-6m per pod, far under
    # the requests here, but that is an IDLE cluster: the controller bursts
    # while reconciling and the repo-server while rendering manifests. Sizing
    # CPU down from a quiet measurement would book capacity correctly for the
    # only moment it does not matter. Memory is the axis that gets pods evicted,
    # and memory is what this changes.
    server:
      resources:
        requests: {cpu: 50m, memory: 96Mi}

    # KSOPS: the cost ADR-0004 knowingly accepted when choosing Argo CD over
    # Flux, which decrypts SOPS natively. Argo needs the binary injected into
    # repo-server and the age key mounted, so decryption happens at manifest
    # render time rather than anything decrypted being stored in the cluster.
    repoServer:
      resources:
        requests: {cpu: 50m, memory: 256Mi}

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
        # The one that matters: 823Mi measured against a 256Mi request.
        requests: {cpu: 100m, memory: 1Gi}
    redis:
      resources:
        requests: {cpu: 25m, memory: 32Mi}
