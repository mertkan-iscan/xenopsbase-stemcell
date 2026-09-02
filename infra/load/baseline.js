// Load baseline for the application (T-5.6).
//
// WHAT THIS MEASURES, AND WHAT IT DELIBERATELY DOES NOT
//
// It runs INSIDE the cluster, against the gateway Service. That excludes
// Cloudflare, the tunnel and ingress-nginx, and the exclusion is the point:
//
//   - The number this exists to produce is an autoscaling threshold (T-2.8).
//     An HPA scales on pod CPU, so the question is what the pods can serve, not
//     what the edge can deliver. Measuring through Cloudflare answers a
//     different question and answers it worse, because the edge's variance
//     swamps the application's.
//   - Sending sustained load through Cloudflare's free tier to benchmark our
//     own pods is rude and would eventually be treated as such.
//
// The edge path is covered by smoke.sh, which asserts it works. Nobody has
// measured what it costs, and that is a separate question worth its own card
// rather than a number smuggled into this one.
//
// SCENARIOS
//
// Two, separated so a regression names its own cause:
//
//   gateway_only   /api/auth-info — permitAll, no downstream call, no database.
//                  Isolates the gateway: TLS termination, the filter chain, the
//                  session lookup in Valkey.
//   through_core   /services/core/api/documents — the real read path. Gateway
//                  route, bearer validation, core, Hibernate, Postgres.
//
// The difference between them is the cost of everything behind the gateway. One
// number alone cannot tell you whether a slowdown is the gateway or the
// database, and that is the first question anyone asks.
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const GATEWAY = __ENV.GATEWAY_URL || 'http://gateway.apps.svc.cluster.local:8080';
const KEYCLOAK = __ENV.KEYCLOAK_URL || 'http://keycloak-service.keycloak.svc.cluster.local:8080';
const REALM = __ENV.REALM || 'xenopsbase';
// `loadtest`, not `smoke`, and this is load-bearing (T-5.13, #371).
//
// T-8.3 put a per-client rate limit on every proxied route, keyed on the
// authenticated subject. This file fetches ONE token in setup() and every VU
// reuses it, so the entire run is a single client: 20/s x 105s admitted ~2100
// requests of the ~180,000 sent, and this gate measured the limiter rather than
// the pods.
//
// `loadtest` holds the app-loadtest realm role, which the gateway exempts. The
// role exists only in the dev realm and the gateway only honours it where
// RATE_LIMIT_UNLIMITED_ROLE is set -- see the RequestRateLimiter block in
// services/gateway/.../application.yml.
//
// If this run ever comes back capped at ~20 req/s through core again, that is
// the first thing to check.
const USERNAME = __ENV.SMOKE_USER || 'loadtest';
// Not a secret: it is committed in the public realm file for a user that exists
// only to be logged in as.
const PASSWORD = __ENV.SMOKE_PASSWORD || 'loadtest-dev-only';

const gatewayOnly = new Trend('latency_gateway_only', true);
const throughCore = new Trend('latency_through_core', true);

export const options = {
  scenarios: {
    gateway_only: {
      executor: 'ramping-vus',
      exec: 'gatewayOnlyPath',
      startVUs: 1,
      stages: [
        { duration: '30s', target: 10 },
        { duration: '60s', target: 10 },
        { duration: '15s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
    through_core: {
      executor: 'ramping-vus',
      exec: 'throughCorePath',
      startVUs: 1,
      // Offset so the two scenarios do not contend for the same pods while
      // each is being measured. Overlapping them measures a mixture and
      // attributes it to neither.
      startTime: '110s',
      stages: [
        { duration: '30s', target: 10 },
        { duration: '60s', target: 10 },
        { duration: '15s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
  },

  // THE SLOs, AS CODE.
  //
  // k6 exits non-zero when a threshold is breached, so these are the regression
  // gate rather than a line in a document nobody re-reads. docs/slos.md carries
  // the reasoning and the full measured numbers.
  //
  // Set from the measured baseline of 2026-08-23, at roughly 2.5x the observed
  // p95 and 3x the observed p99. Measured / threshold:
  //
  //   gateway_only    p95  19.8ms -> 50ms     p99  34.3ms -> 100ms
  //   through_core    p95  92.2ms -> 200ms    p99 129.6ms -> 400ms
  //
  // Tight enough that a doubling fails, loose enough to survive a noisy
  // afternoon. A threshold set at the measured value fails on a quiet Tuesday
  // and then gets deleted, which is worse than not having one.
  thresholds: {
    'http_req_failed': ['rate<0.01'],
    'latency_gateway_only': ['p(95)<50', 'p(99)<100'],
    'latency_through_core': ['p(95)<200', 'p(99)<400'],
    // A run can meet every latency target while returning 500s quickly, which
    // is faster and worthless.
    'checks': ['rate>0.99'],
  },

  // The summary this prints is what the runner parses, so keep the percentiles
  // explicit rather than relying on the default set changing between versions.
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
};

// One token for the whole run, fetched once. Logging in per iteration would
// measure Keycloak's token endpoint rather than the application, and would be
// the dominant cost.
export function setup() {
  const res = http.post(
    `${KEYCLOAK}/realms/${REALM}/protocol/openid-connect/token`,
    {
      grant_type: 'password',
      client_id: 'smoke-tests',
      username: USERNAME,
      password: PASSWORD,
      scope: 'openid profile email',
    },
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } },
  );

  if (res.status !== 200) {
    throw new Error(`could not get a token from Keycloak (${res.status}): ${res.body}`);
  }
  const token = res.json('access_token');
  if (!token) {
    throw new Error('Keycloak returned 200 with no access_token');
  }
  return { token };
}

export function gatewayOnlyPath() {
  const res = http.get(`${GATEWAY}/api/auth-info`, { tags: { scenario: 'gateway_only' } });
  gatewayOnly.add(res.timings.duration);
  check(res, { 'auth-info is 200': (r) => r.status === 200 });
}

export function throughCorePath(data) {
  const res = http.get(`${GATEWAY}/services/core/api/documents?page=0&size=20`, {
    headers: { Authorization: `Bearer ${data.token}` },
    tags: { scenario: 'through_core' },
  });
  throughCore.add(res.timings.duration);
  check(res, { 'documents is 200': (r) => r.status === 200 });
}
