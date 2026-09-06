# ADR-0017: Services share a parent pom and two libraries, split by web stack rather than by topic

- **Status:** Accepted
- **Date:** 2026-09-06
- **Task:** T-9.1

## Context

This repository is a stemcell: it exists to be forked and grown into. Its infrastructure half is
mature. Its application half was two hand-maintained JHipster applications with independent poms,
and adding a third service meant copying a skeleton and duplicating the security, logging and error
handling a third time.

The duplication was not hypothetical. Before this change, `AudienceValidator`, `SecurityUtils`,
`AuthoritiesConstants`, `Constants`, `CRLFLogConverter`, `LoggingConfiguration`,
`JacksonConfiguration`, `DateTimeFormatConfiguration`, `AsyncConfiguration`, `LoggingAspect`,
`ExceptionTranslator` and the correlation-id contract all existed twice, verbatim, in `core` and
`gateway`. The two poms were 1464 and 1370 lines and — comments stripped — differed in the artifact
name, the web stack, and about forty lines of genuinely per-service configuration.

Two services can carry that. One duplicated block is cheaper than a layer of indirection, and this
repository said so in writing. What changes the arithmetic is the third service, and making the
third service cheap is the thing the template exists for.

**The evidence that the duplication was already costing something, rather than merely looking
untidy:** the two poms had silently drifted to different versions of the same two libraries —
jhipster-framework 9.1.0 against 8.12.0, spring-cloud-dependencies 2025.1.2 against 2025.1.3.
Nobody chose either difference. And the two copies of `AuthoritiesConstants` carried different
comments because one had been fixed for a defect (#186) and the other had not.

### Why this could not be one shared library

`gateway` is Spring Cloud Gateway, which runs on WebFlux and cannot run on anything else. Every
other service in this template is Spring MVC. A single shared library would have to declare a web
stack, and whichever one it declared would be wrong for somebody:

- declare `spring-boot-starter-web` and the servlet stack reaches the gateway's classpath;
- declare `spring-boot-starter-webflux` and every servlet service carries Reactor to share a
  constant;
- declare neither and the library cannot hold a filter, an error handler or an auditing
  superclass — which is most of what is actually duplicated.

So the choice was not "one library or two". It was "two libraries, or the gateway shares nothing
and re-declares the correlation header, the authority names and the audience validator itself".

## Decision criteria

1. **Adding a service must not require editing a list of services.** Every such list is a list
   that will be missed.
2. **A rule that protects the gateway's ability to start must fail the build, not a review.**
3. **A bean that moves out of a service's scan root must not be able to disappear silently.**
   Absence is the failure mode that tests are worst at noticing.
4. **No behaviour change in the same change as the move**, so a bisect has something to find.
5. The result must be recognisably the same repository. Where configuration moved, what it says
   should not have.

## Decision

`services/` becomes a Maven reactor with a parent pom and four modules:

| Module | What it is | Depends on |
|---|---|---|
| `platform-common` | Web-stack-neutral: the correlation contract, authority names, the audience validator, logging, the outbox, object storage | `spring-boot-starter` only |
| `platform-common-web` | The servlet half: filters, error handling, auditing, tenancy, idempotency | `platform-common` + `spring-boot-starter-web` |
| `gateway` | The reactive edge | `platform-common` — **never** `platform-common-web` |
| `core` | The servlet service | `platform-common-web` |

**The line between the two libraries is the web stack, not the topic.** Not "is it shared" — both
are shared. The question is whether a class can be written without naming a servlet request.
`CorrelationId` can, so it is stack-neutral and both stacks read the header name from it.
`CorrelationIdFilter` cannot, so it is servlet-side, and the gateway keeps a WebFilter that binds
the same value from the same header. That leaves exactly one duplicated concept — two filters, one
per stack — agreeing on one constant in one place.

### The shared modules ship auto-configuration, not component-scanned beans

`com.xenopsoftware.common` is not under any service's `@ComponentScan` root, so scanning will not
find these classes **and will not report an error**. The beans simply would not exist, and every
`@ConditionalOnBean` downstream of them would silently evaluate false.

Both modules therefore register their configuration through
`META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`. Widening each
service's scan to `com.xenopsoftware` would also have worked, and was rejected: it re-couples the
modules and puts the servlet classes back inside the gateway's reach.

This is a correction to the shape being copied rather than a port of it — see below.

### The correlation header is renamed to `X-Correlation-Id`

Moving the contract cements its spelling, so the spelling was settled first. This repository used
`X-Request-Id` / MDC `requestId`; xenopsbase-learn, the product forked from this template and
already running on this cluster, used `X-Correlation-Id` / `correlationId`. A request crossing the
two products got two ids and no way to join them.

The template moved, because the fork is deployed and the template is not. The span attribute
follows: `request.id` becomes `correlation.id`, in both stacks.

The cost is real and accepted: proxies and Cloudflare understand `X-Request-Id` and not this, so an
id set further out by infrastructure is no longer adopted. The gateway is the edge for these
services and mints the id itself; a deployment that terminates elsewhere maps the header at that
hop.

## Consequences

### What this makes easy

- A version, a plugin, a coverage floor or the JDK is stated once.
- A new service is a `<module>` line. `infra/scripts/service-modules.sh` derives every other list
  in the repository — two GitHub workflow matrices, CodeQL, the security scan and four Makefile
  loops — from `services/pom.xml`, which cannot go stale without the build breaking.
- A shared fix reaches every service. The `AuthoritiesConstants` divergence that half-caused #186
  is not expressible any more.

### What this makes hard

- **A module can no longer be built alone.** `cd services/core && ./mvnw verify` fails to resolve
  `platform-common`. Everything builds from `services/` with `-pl <module> -am`. The Makefile and
  the workflows do this; a developer who types the old command gets a resolution error, which is at
  least loud.
- **Two enforcer rules now guard the dependency tree**, and a legitimate new dependency may trip
  them. That is the intent; the messages name the fix.
- **Three packages are split across the two jars** — `com.xenopsoftware.common.security`,
  `...common.config` and `...common.web`. That is a consequence of splitting by web stack rather
  than by topic: `AuthoritiesConstants` is stack-neutral and `SecurityUtils` is not, and they are
  the same idea. Harmless on a classpath, and it is what the shape being copied does. It would stop
  being harmless under JPMS or a native image, where a package may come from only one module; the
  fix then is a package rename, not a different split.
- **The service must declare where its entities live.** `@EntityScan` anywhere *replaces* the
  application's default entity packages rather than adding to them, so the shared modules cannot
  declare it on the service's behalf without silently un-scanning the service's own entities.
  Each service names both in its `DatabaseConfiguration`. Forgetting it fails at startup with the
  class named.

### What it commits us to

The two-module split, for as long as the gateway is Spring Cloud Gateway. Reversing it means either
giving the gateway a servlet stack or giving up sharing with it. Cost of reversal: low in code —
the modules would merge — and high in consequence, which is the wrong shape of cheap.

## The guards, and what they each catch

Two rules that look redundant and are not. They fail at different times, and only one of them can
fail during the change that caused it.

- **`PlatformCommonIsStackNeutralTest`** (ArchUnit) catches servlet or reactive code being
  *written* in `platform-common`.
- **`enforce-no-web-stack`** (maven-enforcer, `bannedDependencies`) catches a web stack arriving on
  the classpath *with no code referencing it* — which ArchUnit cannot see, and which is the case
  that reaches a deployment.

**Two artifacts read as servlet and must not be banned.** Both were found by writing the rule and
watching it fail:

| Artifact | Why it looks bannable | Why banning it breaks the build |
|---|---|---|
| `org.apache.tomcat.embed:tomcat-embed-el` | "tomcat" | It is Jakarta *Expression Language*, pulled in by bean validation. A `tomcat-embed:*` glob bans it and takes `@Valid` with it. |
| `org.springframework.security:spring-security-web` | "web" | `org.springframework.security.web.server` is where **reactive** security lives. Banning it bans the gateway's own `SecurityWebFilterChain`. |

The gateway carries the mirror rule, banning `platform-common-web` and the servlet stack. **It found
a live defect on its first run:** the gateway declared `spring-boot-starter-tomcat` as a direct
dependency and had done for as long as the pom existed. It was inert — `spring-webmvc` is what
decides the application type, and the gateway has none — but it was shipped in the image, and the
cost of it is on the record two screens up in that same pom: a `tomcat.version` override carried for
three CRITICAL advisories in a component the process never starts. The dependency is removed.

## Alternatives considered

### One shared library — rejected

Covered above: it has to declare a web stack, and every choice is wrong for somebody.

### Widen each service's `@ComponentScan` to `com.xenopsoftware` — rejected

The obvious way to make shared beans appear, and what xenopsbase-learn does. It re-couples the
modules, puts `platform-common-web`'s classes inside the gateway's reach, and makes the dependency
rules a matter of discipline rather than a build failure.

**Learn also supplies the evidence for why the alternative matters.** Its
`PublishedStatusLookup` carried `@ConditionalOnBean(StringRedisTemplate.class)` on a
component-scanned bean, where the condition is evaluated before `RedisAutoConfiguration` has
contributed the template. The condition was therefore always false, the bean never existed, and
every service except one ran with no tenant status gate at all — a suspension stopped writes in one
service and nowhere else. It was found much later, by an unrelated task.

`@ConditionalOnBean` on an *auto-configuration* is evaluated after the beans it asks about exist,
which is what makes it correct in `OutboxAutoConfiguration` and would not have made it correct on a
`@Service`.

### Keep the two independent poms and copy a third — rejected

The status quo. It is what the plan for this work was written to end, and the version drift above
is what it costs before anyone adds a service.

## Notes on the shape this was modelled on

`xenopsbase-learn/services/pom.xml` and its `platform-common` / `platform-common-web` split, at
commit **9868c85** on branch `servlet-and-a-reactive-edge` ("T-9.16 — the servlet stack was
inherited, not chosen, so name it and cut the reactive edge out"). Pinned here deliberately: that
branch may be rebased, squashed or abandoned, and this repository must not need another
repository's branch to explain itself.

What was taken: the module split, the reasoning for where the line falls, the optional persistence
dependencies, and the ArchUnit rule.

What was **not** taken, and why:

- **Learn's banned-dependencies exclude list.** It bans `org.apache.tomcat.embed:*` and
  `spring-security-web`, which learn's `platform-common` can afford because it holds neither bean
  validation nor a token validator. Ours holds both. See the table above.
- **Learn's `@ComponentScan` widening.** Replaced with auto-configuration, for the reason given
  above.
- **Learn's third ArchUnit rule**, which bans `org.springframework.security..` wholesale. Our
  `AudienceValidator` is an `OAuth2TokenValidator<Jwt>` and belongs in the stack-neutral module
  precisely because token validation is identical on both stacks. The rule is narrowed to the two
  security-context holders, which are the classes that genuinely differ per stack.

## Revisit if

- The gateway stops being Spring Cloud Gateway, or Spring Cloud Gateway gains a servlet
  implementation. The whole split exists because it cannot be one.
- A third stack appears (a native image, a batch process with no web layer). The two-module shape
  assumes exactly two answers to "what is a request here".
- The libraries grow a topic split of their own — if `platform-common` reaches the point where
  "stack-neutral" stops being the most useful thing to say about a class, the line is in the wrong
  place.
