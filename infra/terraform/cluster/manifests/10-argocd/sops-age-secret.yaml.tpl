# The age private key, placed by Terraform.
#
# This is the ONE secret that cannot arrive through GitOps, because it is the
# key that makes GitOps able to carry secrets at all (ADR-0003). Everything
# downstream of it is encrypted in git.
#
# It is templated from TF_VAR_sops_age_key, which comes from the environment and
# never from a file in this repository. The rendered manifest is removed from
# the node the moment it has been applied -- see terraform_data.platform_apply
# in bootstrap.tf. Leaving it there would put the bootstrap key in cleartext on
# a disk that outlives the apply.
#
# It is applied with `kubectl apply -f`, on its own, and is NOT listed in
# kustomization.yaml (T-1.22, #281). Being both a kustomize resource and a file
# the apply deletes is a contradiction, and kustomize is the one that discovers
# it -- on the next apply, not this one.
apiVersion: v1
kind: Secret
metadata:
  name: sops-age
  namespace: argocd
type: Opaque
stringData:
  keys.txt: |
    ${sops_age_key}
