# Changelog

Notable changes to the stemcell. This is not a release log — nothing is released yet — it records
decisions that a fork inherits and would otherwise have to reverse-engineer.

## Unreleased

### Detached from the generator (T-3.4)

The services were scaffolded by JHipster 9.2.0 and are now owned outright.

**Removed, and not recoverable by regeneration:**

- `.yo-rc.json` in three places, the `@GeneratedByJHipster` annotation classes, and 13
  `jhipster-needle` markers. Re-running the generator would restore the deletions below as though
  they were an update.

**What moved away from the generated defaults, and why:**

| Generated default | What this project does | Why |
|---|---|---|
| Gateway mirrors Keycloak users into `jhi_user` | deleted, 20 classes | Keycloak is the only identity source; a second user store diverges silently |
| Gateway has a database | **stateless** | the user mirror was its only consumer |
| Liquibase | **Flyway**, `ddl-auto: validate` | plain SQL migrations, readable by anyone forking this |
| `src/main/docker/` — 13 files | deleted | shipped a second Grafana, Prometheus, Keycloak and Zipkin, duplicating the cluster |
| Eureka / Consul discovery | **Kubernetes DNS** | the platform already provides discovery |
| Java 21 | **Java 25** | current LTS; JHipster lists it compatible but cannot select it |
| Sample realm at `localhost:9080` | the deployed `xenopsbase` realm | the `dev` profile group silently overrode correct config |
| `.oauth2Client()` on the core service | removed | core is a resource server; it refused to start without client credentials it never uses |

**Kept deliberately:** `tech.jhipster:jhipster-framework`, a pinned runtime library used by ten
classes. It is not generator coupling, and the exit path is documented in
[services/README.md](services/README.md).

### Fixed along the way

- Gateway returned **500 for cryptographically valid tokens** whose shape it could not decorate —
  four faults in one enrichment path, including a null cache key and a `/userinfo` 403 for service
  accounts being treated as an authentication failure.
- Spring Boot 4 does not autoconfigure Flyway from `flyway-core` alone; without
  `spring-boot-flyway` the migrations **never ran and said nothing**.
- Keycloak issued tokens with **no `aud` claim at all** until an audience mapper was added, so every
  audience-validating service rejected them while the realm looked complete.
