# What a new node is made of (T-1.19, #251).
#
# WHY THIS IS OURS AND NOT THE MODULE'S
#
# kube-hetzner builds this Secret itself when `autoscaler_nodepools` is set, and
# fills `cloudInit` with the same heavy bootstrap it gives static nodes: a
# verified installer that downloads k3s, base64 inside base64 inside gzip. It
# measured 35,332 bytes against Hetzner's 32,768 limit, so every scale-up failed
# at the API with `invalid input in field 'user_data'` and no node was ever
# created (#22).
#
# Shaving 2KB off that payload would have worked until the next thing was added
# to it. So the module is passed `autoscaler_nodepools = []` -- it builds none
# of this -- and the whole node definition is here, where it can be read.
#
# The value of `cloudInit` is rendered from templates/node-bootstrap.yaml.tpl,
# which is the same file static nodes will use. That sameness is the rule this
# card exists to enforce: two bootstrap paths must stay equivalent, and nothing
# would enforce it.
#
# THE DOUBLE ENCODING IS NOT A MISTAKE
#
# `cloudInit` is base64, and the hcloud autoscaler passes the field to the
# Hetzner API AS STORED, without decoding it. That was established by
# measurement, not assumption: the module's value decoded to 26,499 bytes --
# comfortably inside the limit -- and was still rejected, because what actually
# went over the wire was the 35,332-character encoded form.
#
# So the size that matters is the ENCODED length, and that is what
# check-user-data-size.sh asserts. Getting this backwards would give a check
# that passes while the thing it measures fails.
apiVersion: v1
kind: Secret
metadata:
  name: cluster-autoscaler-config
  namespace: kube-system
type: Opaque
stringData:
  config.json: |
    {
      "imagesForArch": {
        "arm64": "${golden_image_id}",
        "amd64": "${golden_image_id}"
      },
      "nodeConfigs": {
        "${node_group}": {
          "cloudInit": "${node_bootstrap_b64}",
          "labels": {},
          "taints": [],
          "serverLabels": {
            "hcloud/node-group": "${node_group}"
          }
        }
      }
    }
