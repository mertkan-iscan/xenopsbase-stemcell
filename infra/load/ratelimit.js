// Does the rate limit exist, and is it PER CLIENT? (T-8.3, #61)
//
// WHAT THIS PROVES, AND WHY THE SECOND HALF IS THE POINT
//
// A limiter that returns 429 under load proves only that something is counting.
// The failure worth ruling out is that it counts everybody into one bucket --
// which is what you get from keying on the remote address behind a proxy, or on
// an authentication that treats anonymous as a user. Both look configured, both
// return 429s under load, and both mean the first busy client rate-limits
// everyone else.
//
// So two identities run at once:
//
//   flood      `smoke`        far above the limit, and must be limited
//   bystander  `smoke-admin`  one request a second, and must NOT be
//
// The bystander threshold is the assertion that matters. If the buckets were
// shared it would see 429s it did nothing to earn, and this run would fail with
// the reason named rather than with a number nobody can interpret.
//
// WHY IT RUNS AGAINST A ROUTED PATH
//
// RequestRateLimiter is a GATEWAY FILTER, so it applies to what the gateway
// proxies -- `/services/core/**` -- and not to endpoints the gateway serves
// itself (`/api/auth-info`, actuator, the OIDC login endpoints). It also sits
// AFTER Spring Security in the chain, so an unauthenticated request is 401'd
// before it reaches the limiter and never counts.
//
// Neither is an oversight. The application hostname is behind Cloudflare Access,
// so unauthenticated traffic does not reach the origin at all, and identity is a
// different hostname that never passes through the gateway. That surface is
// covered by the Cloudflare rate limiting rule in infra/terraform/edge, and the
// two together are what T-8.3 asks for.
//
// ONE PASSWORD GRANT PER IDENTITY, for the reason write.js gives at length: the
// realm is bruteForceProtected, and repeated logins inside a second read as an
// attack even when every credential is correct.
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const GATEWAY = __ENV.GATEWAY_URL || 'http://gateway.apps.svc.cluster.local:8080';
const KEYCLOAK = __ENV.KEYCLOAK_URL || 'http://keycloak-service.keycloak.svc.cluster.local:8080';
const REALM = __ENV.REALM || 'xenopsbase';
const PASSWORD = __ENV.SMOKE_PASSWORD || 'smoke-dev-only';

// Well above the configured ceiling (20/s sustained, 60 burst). The point is to
// empty the bucket quickly and keep it empty, not to measure anything.
const FLOOD_RPS = parseInt(__ENV.FLOOD_RPS || '120', 10);
const DURATION = __ENV.DURATION || '20s';

// A path the gateway ROUTES rather than serves. The response body is irrelevant
// -- this counts status codes.
const PATH = __ENV.RATE_LIMIT_PATH || '/services/core/api/documents?page=0&size=1';

const flooded = new Counter('rate_limited_flood');
const bystanderLimited = new Counter('rate_limited_bystander');
const served = new Counter('served');

export const options = {
  scenarios: {
    flood: {
      executor: 'constant-arrival-rate',
      rate: FLOOD_RPS,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 20,
      maxVUs: 60,
      exec: 'flood',
    },
    bystander: {
      executor: 'constant-arrival-rate',
      rate: 1,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 2,
      maxVUs: 4,
      exec: 'bystander',
    },
  },
  thresholds: {
    // The limiter exists and bites.
    rate_limited_flood: ['count>0'],
    // ...and it is per client. A shared bucket fails here.
    rate_limited_bystander: ['count==0'],
    // ...and it is a limit rather than an outage: the flood's first requests,
    // and every one of the bystander's, are served.
    served: ['count>0'],
  },
};

function passwordGrant(username) {
  const res = http.post(
    KEYCLOAK + '/realms/' + REALM + '/protocol/openid-connect/token',
    {
      grant_type: 'password',
      client_id: 'smoke-tests',
      username: username,
      password: PASSWORD,
      scope: 'openid profile email',
    },
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, tags: { scenario: 'token' } },
  );
  if (res.status !== 200) {
    throw new Error('could not get a token for ' + username + ' (' + res.status + '): ' + res.body);
  }
  const access = res.json('access_token');
  if (!access) {
    throw new Error('Keycloak returned 200 with no access_token for ' + username);
  }
  return access;
}

export function setup() {
  return {
    flood: passwordGrant(__ENV.FLOOD_USER || 'smoke'),
    bystander: passwordGrant(__ENV.BYSTANDER_USER || 'smoke-admin'),
  };
}

function call(token, tag) {
  return http.get(GATEWAY + PATH, {
    headers: { Authorization: 'Bearer ' + token },
    tags: { scenario: tag },
  });
}

export function flood(data) {
  const res = call(data.flood, 'flood');
  if (res.status === 429) {
    flooded.add(1);
  } else if (res.status < 400) {
    served.add(1);
  }
}

export function bystander(data) {
  const res = call(data.bystander, 'bystander');
  if (res.status === 429) {
    // Counted rather than thrown so the run reports HOW MANY, which is the
    // difference between "the buckets are shared" and "one unlucky overlap".
    bystanderLimited.add(1);
  } else if (res.status < 400) {
    served.add(1);
  }
}
