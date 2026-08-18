# ADR-0001: The stemcell ships an API gateway and one core service

- **Status:** Accepted
- **Date:** 2026-08-18
- **Task:** T-0.2

## Context

The stemcell is a starting point for several future projects of unknown shape. Its job is to
provide production-grade plumbing — identity, persistence, document storage, observability,
deployment, disaster recovery — with no business logic, so that domain code can be grown on top.

The topology decision is unusually consequential here because it is inherited by every fork and is
expensive to change once domain code exists. It is also the decision most likely to be made badly,
because "microservices" is a default that gets chosen for reasons of fashion rather than force.

Two constraints narrow the field before any option is considered:

1. **The budget target is near-zero cost when idle** (ADR-0002). Every additional always-on
   service is a JVM with a heap, and on small Hetzner nodes that is a real, not theoretical,
   constraint.
2. **There is no domain model yet.** Service boundaries drawn before the domain is understood are
   drawn along the wrong lines. This is the standard way microservice migrations fail: the
   boundaries encode an early guess and then resist correction.

## Decision criteria

- Cost of running the skeleton with no domain code in it
- Whether adding the *next* service is a routine operation or an architectural event
- Whether the boundaries force a guess about a domain that does not exist yet
- How much of the microservice tax (network calls, distributed tracing, contract testing,
  partial failure) is paid before any value is delivered

## Decision

The stemcell ships **two deployables**:

- an **API gateway** — the single entry point, terminating user authentication against Keycloak
  and relaying identity inward;
- one **core service** — Spring Boot, its own PostgreSQL database, carrying no domain entities.

This is a genuine microservice topology: separate deployables, a network boundary between them,
independent scaling, service-to-service authentication, and distributed tracing across the hop.
Everything needed to add service number three is present and exercised. What is absent is services
two through five, which would exist only to demonstrate a pattern already demonstrated by the
first hop.

### Criteria for adding a service

A third service is justified when at least one is true, and never merely because a new domain
concept appeared:

- it has a **materially different scaling profile** (a video encoder, a report generator);
- it has a **different availability requirement** and must fail independently;
- it is **owned by a different team** with an independent release cadence;
- it has a **conflicting technology requirement** that cannot live in the core service.

Absent one of these, new domain functionality is a module inside the core service. ADR-0002's
extension seams (T-3.10) exist so that such a module can be extracted later without a rewrite.

## Consequences

### What this makes easy

- The idle stemcell runs in a small footprint, which is what makes near-zero-when-idle achievable.
- The distributed-systems tax is paid once, on a hop that exists from day one and is covered by
  contract tests (T-5.4), so the fourth service inherits working patterns.
- No premature domain boundary is committed to.

### What this makes hard

- A fork that genuinely needs five services on day one must add them, though against working
  patterns rather than from nothing.
- Two deployables is more operational surface than a monolith: two images, two deployments, two
  sets of probes. This is the deliberate price of keeping the seam real.

### What it commits us to

The gateway/service split is load-bearing and would be expensive to remove once forks exist.
Collapsing to a monolith later is a larger change than adding a third service. The commitment is
therefore to the *seam*, not to any particular number of services.

## Alternatives considered

### Modular monolith — rejected

Cheapest to run and simplest to operate, and for most projects the correct choice. Rejected
because the stemcell's purpose is to be a reusable base for projects whose scaling requirements
are unknown, and retrofitting a network boundary into a monolith after domain code exists is
materially harder than starting with one. The modular structure is kept regardless: the core
service is internally modular, and ADR-0002's extension seams preserve the option.

### Full microservices, three or more services with sample domains — rejected

Would demonstrate inter-service calls, saga patterns and per-service databases from day one.
Rejected on two grounds. It contradicts the cost target by requiring several idle JVMs. More
importantly, the sample domains would be fictional, and fictional boundaries in a template become
real boundaries in a fork by inertia — the template would ship a guess about a domain that does
not exist.

## Revisit if

- A fork repeatedly needs the same third service, which suggests it belongs in the stemcell.
- The gateway hop proves to add no value over a load balancer, which would mean the seam is
  ceremonial and should either be strengthened or removed.
- Idle cost turns out to be dominated by the platform rather than the services, which would remove
  the main argument against shipping more of them.
