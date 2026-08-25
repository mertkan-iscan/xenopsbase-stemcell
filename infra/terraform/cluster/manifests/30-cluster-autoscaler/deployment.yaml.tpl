# cluster-autoscaler, hcloud provider (T-1.19, #251).
#
# Replaces the one kube-hetzner deployed. The module's version was correct in
# every respect except the one that mattered: the cloud-init it handed the
# Hetzner API exceeded the 32,768-byte user_data limit, so it decided to scale
# up, called the API, and was refused -- every time, for the life of the
# cluster (#22).
#
# Everything variable here is a fact about THIS cluster build, which is why it
# is rendered by Terraform rather than committed to git: the golden image id,
# the private network, the firewall, the SSH key. Argo CD owns everything above
# the cluster (ADR-0004); creating nodes is not above the cluster.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-autoscaler
  namespace: kube-system
  labels:
    app: cluster-autoscaler
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cluster-autoscaler
  template:
    metadata:
      labels:
        app: cluster-autoscaler
      annotations:
        # Restart when the node definition changes. Without this the autoscaler
        # keeps the config it read at startup, so a corrected bootstrap would
        # sit in the Secret being ignored -- and the next scale-up would fail
        # for a reason already fixed.
        checksum/config: "${config_sha256}"
    spec:
      serviceAccountName: cluster-autoscaler
      priorityClassName: system-cluster-critical
      # The control plane is where this belongs: it must keep running precisely
      # when worker capacity is exhausted, which is the moment a worker is the
      # worst place to be.
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
        - key: CriticalAddonsOnly
          operator: Exists
      nodeSelector:
        node-role.kubernetes.io/control-plane: "true"
      containers:
        - name: cluster-autoscaler
          image: ${ca_image}:${ca_version}
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 256Mi
          command:
            - ./cluster-autoscaler
            - --cloud-provider=hetzner
            - --stderrthreshold=info
            - --v=2
            # The hetzner provider's own five-field spec:
            #   <min>:<max>:<server-type>:<location>:<name>
            #
            # Not three fields. Getting it wrong is not a warning and not a
            # degraded mode -- the process calls klog.Fatal on startup:
            #
            #   F hetzner_cloud_provider.go:207] Failed to parse pool spec
            #     `0:2:xenopsbase-dev-autoscaled` provider: expected format
            #     `<min-servers>:<max-servers>:<machine-type>:<region>:<name>`
            #
            # which at least says so plainly, in a CrashLoopBackOff.
            - --nodes=${min_nodes}:${max_nodes}:${server_type}:${location}:${node_group}
            # Without this the autoscaler refuses to remove a node running any
            # pod it cannot prove is replicated -- which on this cluster means
            # DaemonSet-adjacent workloads keep an empty node alive for ever,
            # and scale-down never happens.
            - --skip-nodes-with-system-pods=false
            - --skip-nodes-with-local-storage=false
          env:
            - name: HCLOUD_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hcloud
                  key: token
            - name: HCLOUD_CLUSTER_CONFIG_FILE
              value: /etc/hetzner-autoscaler/config.json
            - name: HCLOUD_SSH_KEY
              value: "${ssh_key_id}"
            - name: HCLOUD_NETWORK
              value: "${network_id}"
            # A new node needs a route to the internet to reach the tailnet
            # coordination server and pull images. Closing this off is a
            # separate decision (a NAT router), not something to do by accident
            # while changing how nodes boot.
            - name: HCLOUD_PUBLIC_IPV4
              value: "true"
            - name: HCLOUD_PUBLIC_IPV6
              value: "true"
            # A node that installs nothing should be up in well under a minute.
            # The module used 15; leaving it there means a genuinely stuck
            # creation is not noticed for a quarter of an hour.
            - name: HCLOUD_SERVER_CREATION_TIMEOUT
              value: "10"
          volumeMounts:
            - name: cluster-config
              mountPath: /etc/hetzner-autoscaler
              readOnly: true
      volumes:
        - name: cluster-config
          secret:
            secretName: cluster-autoscaler-config
            items:
              - key: config.json
                path: config.json
