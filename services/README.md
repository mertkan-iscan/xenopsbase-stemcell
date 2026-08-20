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
