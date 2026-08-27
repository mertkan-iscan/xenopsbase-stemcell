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
            # SCALE-DOWN TIMERS, SHORTENED FOR A CLUSTER WHOSE JOB IS TESTING
            # (T-5.16).
            #
            # Both default to ten minutes, and both were being paid in full
            # after every load run: a node stayed for ten minutes of being
            # unneeded, and no scale-down could start within ten minutes of the
            # scale-up that the run itself had caused. Combined with the HPAs'
            # own windows that is roughly twenty-five minutes before the cluster
            # is back on its floor -- long enough that the next run gets
            # launched on the previous one's hardware and its numbers are
            # quietly wrong. T-5.15 is the record of that happening.
            #
            # Two minutes, not zero. The reason ten minutes is the upstream
            # default is that a node removed the instant it looks idle gets
            # re-provisioned by the next burst, and a Hetzner server takes
            # minutes to boot, join and pull images -- so an over-eager timer
            # buys thrash and pays a cold start for it. Two minutes is long
            # enough to ride out the gap between steps of a ramp and short
            # enough that a finished run does not hold a server for the length
            # of a coffee break.
            #
            # This is a DEV posture. A production cluster serving real traffic
            # should be nearer the default, because there the cost of thrash is
            # paid by users rather than by a test.
            - --scale-down-unneeded-time=2m
            - --scale-down-delay-after-add=2m
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
            # ATTACHED AT CREATION, not afterwards (T-1.28).
            #
            # This was an hcloud_firewall_attachment in terraform, which meant
            # two owners of one relation: every hcloud_server also declares its
            # own firewall_ids, and the last write won. The live firewall ended
            # up with three servers and zero label selectors -- the selector
            # this was supposed to apply, silently gone -- and the destroy then
            # failed trying to remove something that was not there:
            #
            #   firewall with ID 11522374 cannot be removed from
            #   label_selector: resource not found
            #
            # which blocked `make down` entirely and had to be cleared by hand.
            #
            # The env var is what the module's own autoscaler template uses. It
            # also closes a window the attachment could not: a node created
            # before the attachment existed came up on a public address with
            # nothing in front of it, which the `check` block in main.tf warned
            # about and could only warn about.
            - name: HCLOUD_FIREWALL
              value: "${firewall_id}"
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
