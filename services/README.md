# services

The gateway and the core service. **This code is ours.** It was scaffolded by
JHipster ([T-3.1 spike](../docs/spikes/t-3.1-jhipster.md)) and detached in T-3.4.

## The generator is gone, and cannot come back

`.yo-rc.json`, the `@GeneratedByJHipster` annotations and every `jhipster-needle`
marker have been deleted. That is deliberate and load-bearing: re-running the generator over this
tree would restore the things that were removed on purpose —

- the gateway's local user model, which duplicated Keycloak,
- 13 docker-compose files shipping a second Grafana, Prometheus and Keycloak,
- Liquibase, which this project replaced with Flyway.

Every one of those would come back silently, as an "update". There is no supported path back to the
generator, and there should not be.

`services/xenopsbase.jdl` is kept as a **record of what was generated**, not as an input to
regenerate from.

## `tech.jhipster` is a library, not the generator

The runtime dependency `tech.jhipster:jhipster-framework` remains. It is a pinned Maven artifact
like any other, and keeping it is a deliberate decision rather than leftover coupling: rewriting
working, tested utility code buys purity and risk in equal measure.

**Ten classes are used**, so the exit is scoped rather than open-ended:

| Import | What it does | If it has to go |
|---|---|---|
| `config.JHipsterProperties` | binds the `jhipster.*` config tree | replace with `@ConfigurationProperties` of our own |
| `config.JHipsterConstants` | profile name constants | three string constants |
| `config.DefaultProfileUtil` | sets the default profile at startup | a few lines in `main` |
| `config.apidoc.customizer.JHipsterOpenApiCustomizer` | springdoc metadata | springdoc config directly |
| `async.ExceptionHandlingAsyncTaskExecutor` | logs exceptions from `@Async` | a `TaskDecorator` |
| `web.rest.errors.ProblemDetailWithCause` (+ builder) | RFC 7807 bodies | Spring's own `ProblemDetail` |
| `web.rest.errors.ExceptionTranslation` | the translator contract | our own interface |
| `web.rest.errors.ReactiveWebExceptionHandler` | gateway error handling | a `WebExceptionHandler` |
| `web.filter.reactive.CookieCsrfFilter` | writes the CSRF cookie | ~20 lines |
| `web.util.HeaderUtil` | builds alert headers | ~20 lines |

The largest of these is the error handling, and [T-3.8](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/31)
already owns the HTTP contract — which is the natural moment to decide whether to keep it.

## Package convention

```
com.xenopsoftware.<service>
├── config/       Spring configuration and @ConfigurationProperties
├── domain/       JPA entities. Core only; the gateway is stateless
├── repository/   Spring Data repositories. Core only
├── security/     authorities, token handling
│   └── oauth2/   audience validation and OIDC specifics
└── web/
    └── rest/     controllers
        └── errors/  RFC 7807 translation
```

Rules that are not obvious from the tree:

- **The gateway has no `domain` or `repository` package, and must not grow one.** It is stateless by
  design (T-3.2); the moment it stores something, it stops being a proxy and becomes a service with
  a database that nothing backs up.
- **Controllers live under `web/rest`, never at the package root.** Everything under `/api/**` is
  authenticated by default (see each service's `SecurityConfiguration`), so a controller placed
  outside that tree is easy to expose accidentally.
- **Entities are only created alongside a Flyway migration**, and the migration is written first.
  `ddl-auto: validate` enforces this: an entity that disagrees with its migration refuses to start.
  Naming, review conventions and the forward-only rollback strategy are in
  [docs/runbooks/schema-migrations.md](../docs/runbooks/schema-migrations.md).
- **Errors, pagination, idempotency and correlation are decided once**, not per endpoint. See
  [docs/runbooks/http-contract.md](../docs/runbooks/http-contract.md) before adding an endpoint --
  it is what every new one inherits for free, and re-deciding any of it per controller is how a
  consistent API stops being one.
- **Audit, soft delete, tenancy and the outbox already have seams.** Do not invent a second way to
  do any of them. See [docs/runbooks/extension-seams.md](../docs/runbooks/extension-seams.md) --
  it also explains why `Document` is audited but deliberately NOT soft-deleted, which is the kind
  of per-entity decision the seams exist to make cheap.
- **No outbound call may wait forever.** Timeouts, circuit breakers, retries and bulkheads are a
  default posture rather than a per-call decision. See
  [docs/runbooks/resilience.md](../docs/runbooks/resilience.md) -- particularly before adding a
  call to anything over the network, and before assuming an unset timeout means a sensible one.
- **File bytes never pass through a service.** Uploads and downloads go straight between the client
  and object storage over presigned URLs; the API only issues them and tracks metadata. See
  [docs/runbooks/document-storage.md](../docs/runbooks/document-storage.md), which also covers why
  ownership is keyed on the OIDC `sub` and never on `preferred_username`.

## Building

Java 25 (current LTS). `JAVA_HOME` must point at a JDK 25.

```bash
cd services/core && ./mvnw test-compile
```

The Maven wrapper is committed on purpose, so a clone builds without Maven installed.

### If it will not compile

The likely cause is that `JAVA_HOME` points at a different JDK than you think. A machine can
easily carry three: this one had a Java 8 JRE first on `PATH`, `JAVA_HOME` on 21, and the 25 the
build needs installed but unreferenced.

```bash
make java-home
```

```
required:  Java 25  (services/*/pom.xml)
JAVA_HOME: C:\Users\you\scoop\apps\corretto21-jdk\current
selected:  /c/Users/you/scoop/apps/corretto25-jdk/current
```

Targets that run Maven (`make api-spec`, `make api-client`) resolve the JDK themselves and do not
depend on `JAVA_HOME` being right. Running `./mvnw` directly does, and will now stop at `validate`
naming the version it needs, rather than failing later in the compiler.

That distinction used to be the bug. The generated enforcer rule accepted `[21,22),[25,26)` while
`java.version` was `25`, so a JDK 21 **passed** the guard and then failed three phases later with:

```
error: release version 25 not supported
```

which names neither the JDK in use nor where it came from. The rule is now derived from
`${java.version}`, so the guard and what the build targets cannot drift apart again.
