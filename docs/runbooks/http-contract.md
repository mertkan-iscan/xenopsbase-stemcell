# Runbook: the HTTP contract

The conventions every endpoint in a fork of this template inherits without asking for them.

Four things, all cross-cutting, all implemented once so no endpoint has to reimplement them:
errors, pagination, idempotency, and correlation.

## Errors: RFC 9457 problem details

Every error response is `application/problem+json`:

```json
{
  "type": "about:blank",
  "title": "Forbidden",
  "status": 403,
  "detail": "Authenticated, but not permitted to perform this operation.",
  "instance": "/api/documents/42"
}
```

| Source | Handler |
|---|---|
| Anything a controller throws | `ExceptionTranslator` (`@RestControllerAdvice`) |
| 401 / 403 in core | `SecurityProblemSupport` |
| 401 at the gateway | `ProblemDetailAuthenticationEntryPoint` |

**Three handlers, not one, and that is not duplication.** A `@RestControllerAdvice` only sees
exceptions raised by a controller. Security runs as a filter, *before any controller exists*, so
authentication and authorisation failures never reach the advice — Spring's defaults answer them
with a status line and an empty body. Wiring only the advice produces an API where every error
carries a problem document except the two most common ones.

The gateway needs its own because it is reactive and the servlet handler does not apply there.

**403 deliberately does not say which authority was missing.** Naming it hands an unauthorised
caller the shape of the permission model for free.

### The 401-versus-302 decision

An unauthenticated API request returns **401**, not a redirect to the login page.

This was a real defect, recorded during T-3.2. `oauth2Login` installs a redirecting entry point,
so an API client received `302`, followed it, was served the Keycloak login page, and got
**`200 OK` with a body of HTML**. Nothing in that exchange looks like a failure — no error status,
no error body. A client checking the status code concludes the call succeeded, then fails
somewhere else entirely trying to parse HTML as JSON.

Browsers still get the redirect. The discriminator is `Accept: text/html`, which a browser
navigating to a page sends and an API client does not.

**Not the path.** Matching `/api/**` would be wrong in both directions here: the SPA is served
from the same origin as the API, and a user typing an `/api` URL into the address bar is a browser
that deserves a login page. What matters is what the *caller* can use, and the `Accept` header is
the caller saying so.

## Pagination and sorting

```
GET /api/documents?page=0&size=20&sort=createdAt,desc

X-Total-Count: 137
Link: <...page=1&size=20>; rel="next", <...page=6&size=20>; rel="last"
```

The body stays a plain JSON array. The total goes in a header rather than wrapping the body in an
envelope, so a client that never paginates does not have to unwrap anything to read the payload.

**`@PageableDefault` sets a default size, not a maximum.** A client asking for `size=1000000` still
gets it — which is a denial of service against the database dressed as a normal request. Endpoints
cap the value explicitly; see `DocumentResource.capped`.

Sorting is by entity field name. Anything sortable is also indexed, or it is a sequential scan the
client can trigger at will.

## Idempotency keys

```
POST /api/documents
Idempotency-Key: 9f2c1b7e...
```

A client that sends a POST and never sees the response cannot know whether it happened. Retrying
risks doing it twice; not retrying risks not doing it at all. With a key, the server recognises the
retry and **replays the original response**.

| Situation | Answer |
|---|---|
| Same key, same request, finished | the stored response, plus `Idempotency-Replayed: true` |
| Same key, same request, still running | `409` — a concurrent retry, not something to replay |
| Same key, **different** request | `422` — a client bug; replaying would hide it |
| No key | no idempotency handling; behaves exactly as before |

Replaying the *original* response is the point. Answering a retry with a fresh `200` would tell the
client it worked without ever telling it the id of what was created the first time — success it
cannot use.

**Opt-in, deliberately.** Making the header mandatory would break every existing client the day it
shipped, and a template should not make that call for the projects forked from it.

### Details that are load-bearing

- **Keys are scoped to the authenticated caller.** A globally unique key would let one client read
  another's stored response by guessing a value — a reliability feature turned into a data leak.
- **A unique constraint does the concurrency arbitration**, not a `SELECT` then `INSERT`. Two
  simultaneous retries both pass a check-then-act; exactly one wins an `INSERT`.
- **Only successful outcomes are stored.** Storing a `500` would make a transient failure
  permanent: every retry answered with the same error, the server never trying again.
- **A failed attempt deletes its own claim.** Otherwise a request that never succeeded leaves an
  `IN_PROGRESS` row and every later retry gets `409` forever.
- **Spring's `ContentCachingRequestWrapper` does not do what the name suggests.** It records what
  was read so it can be inspected afterwards; it does **not** replay. Hashing the body consumes the
  stream, so the filter uses its own replayable wrapper — without it the controller receives an
  empty body and fails validation, pointing nowhere near the filter. `IdempotencyFilterIT` guards
  exactly this.

Records are only useful while a client might still retry. Nothing reaps them yet — see the gaps
below.

## Correlation IDs

One request gets one id at the edge, and every log line it causes in any service carries it.

```
X-Request-Id: 3f9a2c...      request and response, both services
%X{requestId}                the log pattern in logback-spring.xml
```

The gateway generates one if the caller did not supply it, echoes it on the response, and writes it
onto the proxied request so core adopts the same value. Core generates a `direct-` prefixed id if
none arrived — which is a signal, not a fallback: everything routed through the gateway has an id,
so a `direct-` id means something bypassed it.

### Why the two services do this so differently

Core is servlet-based: one request, one thread, and MDC works exactly as it appears to.

The gateway is reactive, and MDC is a thread-local while WebFlux moves a request between threads
whenever it pleases. Setting MDC there gives the id on *some* log lines depending on which
scheduler ran the operator — worse than having none, because the gaps are invisible and look like
missing requests rather than missing ids.

So the gateway puts the id in the Reactor context, which travels with the request, and a
`ThreadLocalAccessor` restores it into MDC around each operator. `spring.reactor.context-propagation: auto`
is what applies that without every operator opting in.

This asymmetry is the clearest argument for keeping the reactive footprint in the gateway alone.

**Both services validate the inbound header.** It is attacker-controlled and lands in every log
line, so an unvalidated value is a log-forging vector — a newline in it writes fabricated entries.

**`%X{requestId}` renders empty rather than failing when the MDC key is missing.** The key is a
string in XML and a constant in Java; renaming one without the other produces logs that look
completely normal and are missing the id. That is the failure to watch for.

### Reaching traces as well as logs

A log line carries `requestId`, `traceId` and `spanId` together, so getting from a log line to its
trace is one hop. The other direction needs the id on the span itself, and it is there:

```
request.id                   a high-cardinality span attribute, both services
```

`CorrelationIdObservationFilter` tags the server observation. It does not call
`Span.current().setAttribute()`, and the reason matters: the correlation id is assigned at
`HIGHEST_PRECEDENCE` so that every log line is correlated, which places it *ahead* of the
observation that creates the server span. An attribute set there lands on an invalid span and is
discarded without an error.

The value is read from the **response** header, not the request. The response header is set on
every path, including the two that matter most — a request that arrived with no id, and one whose
id failed validation and was replaced. The inbound header is absent or wrong in exactly those
cases, and it is the response value the caller actually receives and would quote.

**High cardinality is not a detail here.** Micrometer sends low-cardinality key values to metrics
as well as spans. A unique-per-request value as a metric tag mints a Prometheus time series for
every request the system serves — not a degradation but an outage of the metrics stack, arriving
hours later and looking like a Prometheus fault. A test asserts the key value is not
low-cardinality, because nothing else would notice in time.

`request.id` and the W3C `traceparent` both survive rather than one replacing the other. They
answer different questions and have different lifetimes, and a sampled-out trace still needs a
correlation id in its logs.

## Known gaps

**Nothing reaps `idempotency_record`.** Rows accumulate. As with the abandoned-upload reaper in
document storage, scheduling is a deployment decision: a `@Scheduled` baked into the template runs
on every replica at once. Wire it to a CronJob or a `ShedLock`-guarded task.

**Idempotency is core-only.** The gateway does not participate, so a retry that fails between
client and gateway is not covered. Moving the check to the edge would mean the gateway storing
response bodies for every service behind it, which is a larger decision than this card.
