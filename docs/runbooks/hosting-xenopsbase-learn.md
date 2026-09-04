# Runbook: hosting xenopsbase-learn on this cluster

**Task:** xenopsbase-learn T-9.3 (its #11)

`xenopsbase-learn` is a second product sharing this cluster's Postgres, Keycloak, Valkey and
ingress. It is not a second platform: it runs three Spring Boot services in a `learn` namespace
and operates none of the infrastructure underneath them.

## The split, and why it is where it is

| Lives here (the stemcell) | Lives in xenopsbase-learn |
|---|---|
| The `learn` namespace, and its image-policy enrolment | The three Deployments and Services |
| Three databases and three roles in the shared cluster | Their image digests (`kustomization.yaml`) |
| The `xenopslearn` realm bootstrap | The realm's contents, and `realm-apply` |
| The ClusterImagePolicy that admits learn's images | The workflow that signs them |
| The Argo `Application` that points at learn's repo | — |

The rule: **decisions about this cluster belong to whoever operates it**; decisions about a
service belong beside its code. A learn developer changing a resource request should not need a
pull request here, and an operator changing the backup policy should not need one there.

## The secrets, and what had to be done by hand

**Eight files, and they exist now — for `dev`.** They were written by someone holding the age
private key, which is deliberately not in this repository (ADR-0003, `docs/runbooks/secrets.md`),
and that is why they could not arrive with the manifests that reference them. The tables below are
what a *new* environment needs, and the record of what these hold.

The count is eight rather than the six this file first said: the three role passwords and the
three application-side copies, plus `learn-service-clients` and the `valkey-client` copy, both of
which are just as necessary and neither of which is optional.

Three role passwords, in the `database` namespace — CNPG reads these to create the roles named in
`platform/envs/dev/database/cluster.yaml`:

| File | Secret | Keys |
|---|---|---|
| `secrets/learn-identity-db.yaml` | `learn-identity-db` (ns `database`) | `username`, `password` |
| `secrets/learn-streaming-db.yaml` | `learn-streaming-db` (ns `database`) | `username`, `password` |
| `secrets/learn-reporting-db.yaml` | `learn-reporting-db` (ns `database`) | `username`, `password` |

The `username` must match the role name exactly — `learn_identity`, `learn_streaming`,
`learn_reporting`.

Three application-side secrets, in the `learn` namespace — the same credentials, plus the
service-to-service client secrets:

| File | Secret | Keys |
|---|---|---|
| `secrets/learn-identity-db-app.yaml` | `learn-identity-db` (ns `learn`) | `username`, `password` |
| `secrets/learn-streaming-db-app.yaml` | `learn-streaming-db` (ns `learn`) | `username`, `password` |
| `secrets/learn-reporting-db-app.yaml` | `learn-reporting-db` (ns `learn`) | `username`, `password` |
| `secrets/learn-service-clients.yaml` | `learn-service-clients` (ns `learn`) | `identity`, `streaming`, `reporting` |

The `learn` namespace also needs the existing **`valkey-client`** secret copied into it
(`secrets/learn-valkey-client.yaml`, the same password and deliberately not the server's conf
fragment) — all three services read the cache and this cluster's Valkey requires a password.

That copy is not a nicety. Without it every cache read returns NOAUTH, and learn's permission
cache fails *permissive* when the cache is unreachable — correct for an outage, and exactly wrong
here, because a missing password becomes a permission system that quietly stops consulting
anything while every pod reports Ready.

The three database passwords were generated at creation and exist only inside these files; the
service-client values are learn's development ones, carried verbatim from its realm file so both
sides agree on a first sync.

Two secrets per database rather than one, because they live in different namespaces and a
Kubernetes Secret does not cross one. That is the same shape `core-db.yaml` and `core-db-app.yaml`
already have.

To create one:

```bash
cat > platform/envs/dev/secrets/learn-identity-db.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: learn-identity-db
  namespace: database
type: Opaque
stringData:
  username: learn_identity
  password: <generate one>
YAML
sops -e -i platform/envs/dev/secrets/learn-identity-db.yaml
```

Then add each filename to `platform/envs/dev/secrets/secret-generator.yaml`, which is the list
ksops decrypts at render time inside `argocd-repo-server`.

## The service client secrets have to match the realm

`svc-identity`, `svc-streaming` and `svc-reporting` are confidential clients declared in learn's
realm file, and their secrets appear in two places that must agree: the realm (imported here) and
`learn-service-clients` (read by the Deployments). If they disagree, every inter-service call is
refused with "the service credential did not verify" and nothing else looks wrong.

The realm import carries learn's development values. **Change both together or neither.**

## Order of operations

1. Create and encrypt the eight secrets, and copy `valkey-client` into `learn`. **Done for dev**;
   this is the step a new environment starts at.
2. Merge this change. Argo creates the namespace, the roles, the databases, the realm and the
   policy.
3. Confirm the roles and databases exist before expecting a pod to start — the services validate
   their schema at startup and will sit in CrashLoopBackOff against a database that is not there:
   ```bash
   kubectl -n database get databases.postgresql.cnpg.io
   kubectl -n keycloak get keycloakrealmimports
   ```
4. The learn Application syncs its three Deployments. Each waits on OIDC discovery in an
   initContainer, so `Init:0/1` while Keycloak imports the realm is expected rather than a fault.

## What to expect, and what not to

**Nothing plays a video.** `streaming` runs the fake media provider: uploads, encode state and
playback tokens are simulated and it warns loudly at startup. Real delivery needs a Cloudflare
Stream account, which is learn's T-9.14.

**There is no gateway and no frontend.** Learn's three services are cluster-internal with no
Ingress; its T-10.2 is what puts a session and a public entry point in front of them. Reaching
them today means `kubectl port-forward`.

**The headroom question is open.** ADR-0109 measured a Spring Boot process idling at ~600Mi and
about six fitting on the dev workers. This adds three to the two already running. `make
verify-headroom` is the check that matters after the first sync, and it is the one that caught
worker-0 dropping to 87Mi schedulable after a routine rollout (T-2.29).
