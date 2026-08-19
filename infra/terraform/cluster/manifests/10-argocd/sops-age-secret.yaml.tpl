# The age private key, placed by Terraform.
#
# This is the ONE secret that cannot arrive through GitOps, because it is the
# key that makes GitOps able to carry secrets at all (ADR-0003). Everything
# downstream of it is encrypted in git.
#
# It is templated from TF_VAR_sops_age_key, which comes from the environment and
# never from a file in this repository. The rendered manifest is removed from
# the node after it is applied -- see the post_commands on this kustomization
# set. Leaving it there would put the bootstrap key in cleartext on a disk that
# outlives the apply.
apiVersion: v1
kind: Secret
metadata:
  name: sops-age
  namespace: argocd
type: Opaque
stringData:
  keys.txt: |
    ${sops_age_key}
