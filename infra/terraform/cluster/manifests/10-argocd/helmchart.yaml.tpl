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
    repoServer:
      resources:
        requests: {cpu: 50m, memory: 128Mi}
    controller:
      resources:
        requests: {cpu: 100m, memory: 256Mi}
    redis:
      resources:
        requests: {cpu: 25m, memory: 64Mi}
