# The root of the app-of-apps tree.
#
# This is the ONLY thing Terraform tells Argo CD about. Everything else in the
# platform is a child Application discovered from git, so adding a component is
# a commit rather than an infrastructure change. That is what makes a rebuild
# cheap: Terraform's job ends here.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    # Ensures deleting the root cascades to its children rather than orphaning
    # them in the cluster with nothing managing them.
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${platform_repo_url}
    targetRevision: ${platform_repo_revision}
    path: ${platform_path}
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      # prune removes what git no longer declares; selfHeal reverts changes
      # made in the cluster. Together they are what turns "no state created by
      # a human" (ADR-0002) from a rule people must remember into one the
      # system enforces.
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      # Server-side apply, so large CRDs from later components do not hit the
      # client-side annotation size limit.
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m
