# sops-age-secret.yaml is DELIBERATELY NOT LISTED (T-1.22, #281).
#
# It is applied on its own, immediately before this kustomization, and shredded
# straight afterwards -- see terraform_data.platform_apply in bootstrap.tf.
#
# Listing it here made the directory and the kustomization disagree about
# whether the file exists. It is rendered, applied, then deleted because it
# carries the age private key in cleartext; kustomize then re-read a `resources`
# entry pointing at a file the apply itself had removed:
#
#   accumulating resources from 'sops-age-secret.yaml':
#   evalsymlink failure ... no such file or directory
#
# A resource kustomize never needs cannot be a resource kustomize cannot find.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmchart.yaml
