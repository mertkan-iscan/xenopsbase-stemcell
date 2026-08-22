# Local development

**Task:** T-4.1 (#35)

Everything runs on the machine. No Hetzner resources, no cluster, no credentials, and nothing to
request from anyone before starting.

## Prerequisites

Two, and the second is found for you.

- **Docker.** The only thing that has to be installed and running.
- **A JDK 25.** `infra/scripts/java-home.sh` locates one; if it cannot, it says which JDKs it found
  and why none qualified.

## One command

```bash
make dev-up
```

```
STACK UP in 94s

  application     http://localhost:8080
  core (direct)   http://localhost:8081
  keycloak        http://localhost:9080   admin / admin
  minio console   http://localhost:9001   localdevkey / localdevsecret

  sign in as      smoke / smoke-dev-only        (app-user)
                  smoke-admin / smoke-dev-only  (app-user, app-admin)
```

`make dev-down` stops it and removes the volumes. `make dev-logs` follows both services.

## What runs where, and why the split matters

| | |
|---|---|
| Postgres, Keycloak, MinIO, Valkey | containers, `infra/dev/compose.yml` |
| gateway, core | Maven, `spring-boot:run` with devtools |

The services are deliberately **not** in the compose file. A code change has to be running in
seconds, and a container rebuild is not that. Measured on 2026-08-22:

```
edit a class -> mvn compile   12s
devtools restart               7s
                              19s to serving   (the card's limit is 30s)
```

Run `mvn compile` in a second terminal, or let an IDE compile on save — devtools watches
`target/classes`, not the source.

## The realm is the deployed one

`make dev-realm` (run automatically by `dev-up`) reads `spec.realm` out of
`platform/envs/dev/keycloak/realm-import.yaml` — **the file Argo CD applies to the cluster** — and
hands it to the local Keycloak. Same clients, same roles, same users, same protocol mappers.

A committed local copy would drift, and silently: local login would keep working against a realm
nobody deploys, and the first sign would be a change that works on a laptop and fails in dev. That
is the failure a local stack is meant to remove, not introduce. T-4.2's Testcontainers harness reads
the same file for the same reason.

Exactly two things are changed on the way through, both documented at the point they happen in
`infra/scripts/dev-realm.sh`:

1. `${GATEWAY_CLIENT_SECRET}` becomes a literal. It is a SOPS placeholder with no value outside the
   cluster.
2. `http://localhost:8080` is **appended** to the gateway client's redirect URIs, web origins and
   post-logout URIs. The committed realm trusts exactly one callback, deliberately — a wildcard
   redirect URI turns the authorization code flow into an open redirect — so Keycloak correctly
   answers a local login with `Invalid parameter: redirect_uri` until localhost is added. Appending
   rather than replacing means this script can only ever loosen a copy that never leaves the
   machine.

## Things that will look like your fault and are not

**`role "core" does not exist`.** The deployed database gets that role from CloudNativePG's managed
roles; a plain `postgres` image does not. `infra/dev/initdb/` creates it, so this only appears if
that volume was populated before the file existed — `make dev-down` and start again.

**A config change that appears to do nothing.** `make dev-up` skips a service whose port already
answers, so if a previous stack is still running you get the old process with the old environment.
`make dev-down` now reports loudly when something still holds 8080 or 8081; if it does, stop that
process before continuing. This cost an hour during T-4.1 itself, on Windows, because the first
version of the cleanup used `lsof`, which does not exist there, and failed silently.

**Tracing is off locally.** `management.tracing.enabled` defaults to `false` in the `dev` profile
and no OTLP endpoint is set. Setting an empty endpoint is not the same as setting none: Boot builds
the exporter and rejects the empty string with `Invalid endpoint, must start with http:// or
https://`, which used to stop the `dev` profile from starting at all. To trace locally, run a
collector and export `MANAGEMENT_OPENTELEMETRY_TRACING_EXPORT_OTLP_ENDPOINT` and
`TRACING_ENABLED=true`.

## Dependencies only

To run the services from an IDE instead:

```bash
make dev-deps
```

It prints the environment the services need. The values are also in the `DEV_ENV` block of the
Makefile, which is what `dev-up` uses, so the two cannot disagree.

## What this is verified against

A full `make dev-down` — containers and volumes removed — followed by `make dev-up`, then a real
login through the local Keycloak as `smoke-admin`, `GET /` returning 200, and a request through the
gateway to core returning 200 with an `X-Total-Count` header.

**Not verified on a genuinely clean machine.** It has been verified from a clean *stack* on a
machine that already had Docker, a JDK and a warm Maven repository. A first run on a new machine
additionally downloads the container images and the Maven dependencies, which dominates the time and
is not represented in the 94s above.
