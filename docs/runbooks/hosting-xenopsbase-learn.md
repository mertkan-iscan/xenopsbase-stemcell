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

## What is NOT wired, and cannot be from a pull request

**Six secrets.** SOPS decrypts with an age private key that is deliberately not in this
repository (ADR-0003, `docs/runbooks/secrets.md`), so these have to be created by someone holding
it. Everything else in this change references them and will sit unready until they exist.

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

The `learn` namespace also needs the existing **`valkey-client`** secret copied into it — all three
services read the cache and this cluster's Valkey requires a password.

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

1. Create and encrypt the six secrets, and copy `valkey-client` into `learn`.
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
