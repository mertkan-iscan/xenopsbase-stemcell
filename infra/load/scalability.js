// Scalability test for the application (T-5.10).
//
// HOW THIS DIFFERS FROM baseline.js, AND WHY BOTH EXIST
//
// baseline.js holds 10 VUs and asks "what does a request cost". It is a closed
// model: a slow response slows the load generator down with it, so the offered
// rate falls to whatever the system happens to be able to serve. That is the
// right shape for a latency gate and the wrong shape for every question below,
// because a closed model can never overload anything -- it politely waits.
//
// This file uses `ramping-arrival-rate`: an OPEN model that offers a fixed
// number of requests per second regardless of how long they take. Real traffic
// does not wait either. That is what makes saturation visible -- when the system
// stops keeping up, the queue grows, latency departs from flat, and k6 reports
// `dropped_iterations` because it could not start work on schedule.
//
// THE THREE QUESTIONS
//
//   1. Where is the knee?   Throughput rises with offered rate until it does
//                           not. The last step that still holds latency flat is
//                           the honest capacity number; past it is a queue.
//   2. Does the HPA fire?   The 200% target in platform/envs/dev/services/hpa.yaml
//                           was derived arithmetically from a T-5.6 measurement
//                           and rehearsed on a local k3s. It has never been
//                           observed governing this cluster under real traffic.
//   3. Does it come back?   Scale-DOWN under falling load. #22's evidence used a
//                           synthetic 3000m pod for the NODE autoscaler; the pod
//                           autoscaler's scaleDown behaviour is still unobserved.
//
// Replica and node counts are NOT collected here -- k6 has no business holding
// cluster credentials. scalability-test.sh samples them from outside and joins
// the two timelines in its report.
//
// WHY THERE ARE NO THRESHOLDS
//
// baseline.js is a gate and exits non-zero on a breach. This one deliberately is
// not. Its job is to find the ceiling, so a run that reaches the ceiling has
// succeeded -- failing the run for arriving at its own answer would train
// everyone to ignore the exit code. The output is a curve, and the wrapper
// script prints it.
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';

const GATEWAY = __ENV.GATEWAY_URL || 'http://gateway.apps.svc.cluster.local:8080';
const KEYCLOAK = __ENV.KEYCLOAK_URL || 'http://keycloak-service.keycloak.svc.cluster.local:8080';
const REALM = __ENV.REALM || 'xenopsbase';
const USERNAME = __ENV.SMOKE_USER || 'smoke';
// Not a secret: committed in the public realm file, for a user that exists only
// to be logged in as. The same account baseline.js and smoke.sh use.
const PASSWORD = __ENV.SMOKE_PASSWORD || 'smoke-dev-only';

// ---------------------------------------------------------------------------
// THE SCHEDULE
// ---------------------------------------------------------------------------
//
// STEP_SEC is 120 for a reason that is not comfort. An HPA re-evaluates every
// 15s against metrics-server, which is itself averaging over a ~15-30s window,
// and a gateway replica it decides to add needs roughly 15s of JVM start before
// it is worth having. A 30s step would ramp past the decision before the
// decision could take effect, and would then report "the HPA did not scale"
// about a test too short to let it.
const parseList = (s, fallback) =>
  (s ? s.split(',').map((n) => parseInt(n.trim(), 10)) : fallback);

const CORE_STEPS = parseList(__ENV.CORE_STEPS, [200, 400, 800, 1200, 1600]);
const GW_STEPS = parseList(__ENV.GW_STEPS, [500, 1500, 3000, 4500]);
const STEP_SEC = parseInt(__ENV.STEP_SEC || '120', 10);
const GW_STEP_SEC = parseInt(__ENV.GW_STEP_SEC || '90', 10);
const RAMP_SEC = parseInt(__ENV.RAMP_SEC || '10', 10);

// The quiet gap is the scale-down observation, not padding. The gateway HPA has
// stabilizationWindowSeconds: 300 and removes one pod per 120s, so 420s is the
// window plus one policy period -- the minimum that can show a removal at all.
// core's window is 600s and will NOT complete inside this gap; the report says
// so rather than letting a reader conclude core never scales down.
const GAP_SEC = parseInt(__ENV.GAP_SEC || '420', 10);

function buildSchedule(steps, stepSec, offsetSec, prefix) {
  const stages = [];
  const windows = [];
  let t = offsetSec;
  for (const rate of steps) {
    // Two stages per step: a short linear ramp to the new rate, then a flat
    // hold. Only the hold is measured -- averaging the ramp into the step
    // reports a rate the system was never actually offered.
    stages.push({ target: rate, duration: RAMP_SEC + 's' });
    t += RAMP_SEC;
    const holdSec = stepSec - RAMP_SEC;
    stages.push({ target: rate, duration: holdSec + 's' });
    windows.push({ from: t, to: t + holdSec, label: prefix + '_' + rate, rate: rate });
    t += holdSec;
  }
  return { stages: stages, windows: windows, end: t };
}

const core = buildSchedule(CORE_STEPS, STEP_SEC, 0, 'core');
const gwStart = core.end + GAP_SEC;
const gw = buildSchedule(GW_STEPS, GW_STEP_SEC, gwStart, 'gw');

// One flat lookup spanning the whole run, so an iteration can find its own step
// from absolute elapsed time without knowing which scenario it is in.
const WINDOWS = core.windows.concat(gw.windows);

// A Trend and a set of Counters per step. k6's standard end-of-test summary
// breaks these out on its own, which means the curve is readable in the raw log
// without anything having to parse it.
//
// The request Counter is the one that matters most and is the easiest to leave
// out. Latency alone cannot distinguish a system serving 1600 req/s in 40ms from
// one serving 900 req/s in 40ms and quietly dropping the rest -- both report the
// same flat p95. SERVED divided by OFFERED is the actual scalability curve; the
// trend is only how it felt for the requests that got through.
//
// WHY FAILURES ARE COUNTED BY CLASS AND NOT JUST COUNTED
//
// The first version of this file counted a failure and stopped there, and the
// first run it produced was misread as a capacity collapse for a whole working
// session. It was not. The run held ONE token for 26 minutes against a realm
// whose accessTokenLifespan is 300s, so from t+360s every request was a 401 --
// and a 401 looks exactly like saturation through a metrics lens: throughput to
// zero, latency to nothing, downstream CPU to idle, because rejections are cheap
// and the gateway never forwarded anything.
//
// A load test that cannot tell "the system stopped coping" from "my credentials
// expired" is worse than no load test, because it produces a confident number.
// So: 401 and 403 are counted separately from 5xx, and the report refuses to
// call a step saturated when the errors are authentication.
const latency = {};
const requests = {};
const failures = {};
const authErrors = {};
const serverErrors = {};
const otherErrors = {};
for (const w of WINDOWS) {
  latency[w.label] = new Trend('lat_' + w.label, true);
  requests[w.label] = new Counter('req_' + w.label);
  failures[w.label] = new Counter('fail_' + w.label);
  authErrors[w.label] = new Counter('auth_' + w.label);
  serverErrors[w.label] = new Counter('svr_' + w.label);
  otherErrors[w.label] = new Counter('oth_' + w.label);
}

export const options = {
  scenarios: {
    // The real read path: gateway route, bearer validation, core, Hibernate,
    // Postgres. This is the one the HPA question is about, because it is the
    // only path that puts CPU on both deployments at once.
    through_core: {
      executor: 'ramping-arrival-rate',
      exec: 'throughCorePath',
      startRate: 0,
      timeUnit: '1s',
      stages: core.stages,
      // preAllocatedVUs must cover peak_rate x latency. 1600/s at 60ms needs
      // ~96; maxVUs is headroom for the case this test exists to find, where
      // latency climbs and each VU is occupied far longer. If k6 exhausts maxVUs
      // it reports dropped_iterations -- a real finding about the system, so
      // long as the generator itself is not the thing that ran out. The report
      // prints k6's own CPU so the two can be told apart.
      preAllocatedVUs: parseInt(__ENV.CORE_VUS || '120', 10),
      maxVUs: parseInt(__ENV.CORE_MAX_VUS || '600', 10),
      gracefulStop: '15s',
    },
    // Isolates the gateway: permitAll, no downstream call, no database. Runs
    // AFTER the gap rather than alongside, because two scenarios sharing the
    // pods measure a mixture and attribute it to neither.
    gateway_only: {
      executor: 'ramping-arrival-rate',
      exec: 'gatewayOnlyPath',
      startRate: 0,
      timeUnit: '1s',
      startTime: gwStart + 's',
      stages: gw.stages,
      preAllocatedVUs: parseInt(__ENV.GW_VUS || '80', 10),
      maxVUs: parseInt(__ENV.GW_MAX_VUS || '400', 10),
      gracefulStop: '15s',
    },
  },

  // ---------------------------------------------------------------------------
  // NO_CONN_REUSE=true TURNS OFF HTTP KEEP-ALIVE, AND IT EXISTS TO TEST ONE
  // SPECIFIC HYPOTHESIS (T-5.14)
  // ---------------------------------------------------------------------------
  //
  // A Kubernetes Service load-balances PER CONNECTION, not per request. With
  // keep-alive on, a VU's connection is assigned a backend pod at setup and
  // stays there for the whole run, so a replica the HPA adds later receives
  // traffic only from connections created after it appeared.
  //
  // T-5.13 measured what looks exactly like that: two replicas became Ready at
  // t+67s and served ~0 req/s until t+340s, while k6 sat on its 120
  // preAllocatedVUs and created no new connections. The moment the pool grew
  // past 120 -- at t+320s -- they started serving, and their share then climbed
  // as the pool grew to 127, 154, 231, 303.
  //
  // That is a correlation. Setting this makes every request its own connection,
  // which converts the Service's per-connection balancing into per-request
  // balancing and removes the mechanism entirely. If the imbalance disappears,
  // the hypothesis holds; if it survives, the cause is something else and the
  // reasoning above is wrong.
  //
  // NOT A DEFAULT, and it must not become one. A handshake per request is not
  // how any real client behaves, and it moves absolute throughput -- which is
  // what every other number in this file is for. Use it to answer the
  // distribution question and then turn it off.
  noConnectionReuse: __ENV.NO_CONN_REUSE === 'true',

  // No thresholds. See the header -- reaching the ceiling is the result, not a
  // failure. `dropped_iterations` and the per-step trends are the output.
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

// ---------------------------------------------------------------------------
// TOKENS
// ---------------------------------------------------------------------------
//
// The realm's accessTokenLifespan is 300s and this test runs for twenty-odd
// minutes, so a token fetched once in setup() is invalid for most of the run.
// baseline.js can fetch once because it runs for 3m30s; this file cannot, and
// inheriting that pattern from it is precisely the mistake that produced a
// fabricated capacity cliff.
//
// REFRESH_SEC is deliberately well inside the lifespan rather than close to it.
// Spring's JwtTimestampValidator allows 60s of clock skew, so the real deadline
// is fuzzy, and a refresh timed against the nominal expiry would put the first
// failures exactly where they are hardest to recognise -- gradually, under load.
const REFRESH_SEC = parseInt(__ENV.TOKEN_REFRESH_SEC || '120', 10);

// EXACTLY ONE PASSWORD GRANT PER RUN, AND IT HAPPENS IN setup().
//
// The obvious implementation -- each VU logs in when its token ages out -- fails,
// and fails in a way that looks like the application's fault. The realm sets
// bruteForceProtected: true, and Keycloak's quick-login check (default 1000ms)
// treats repeated logins for ONE user inside one second as an attack even when
// every credential is correct. Hundreds of VUs refreshing together trip it, the
// user is temporarily disabled, and Keycloak then answers correct credentials
// with `invalid_grant: Invalid user credentials` -- which arrives at the test as
// a wave of 401s indistinguishable from the expiry problem it was meant to fix.
//
// Refresh grants carry no password, so brute-force protection does not apply,
// and the realm leaves revokeRefreshToken at its default of false -- so one
// refresh token can be redeemed concurrently by every VU for the life of the SSO
// session (ssoSessionMaxLifespan: 36000s, far longer than any run).
function passwordGrant() {
  const res = http.post(
    KEYCLOAK + '/realms/' + REALM + '/protocol/openid-connect/token',
    {
      grant_type: 'password',
      client_id: 'smoke-tests',
      username: USERNAME,
      password: PASSWORD,
      scope: 'openid profile email',
    },
    // Tagged out of every step: this is the harness authenticating, not the
    // application serving, and folding it into a step would measure Keycloak
    // and label it the gateway.
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, tags: { step: 'token' } },
  );

  if (res.status !== 200) {
    throw new Error('could not get a token from Keycloak (' + res.status + '): ' + res.body);
  }
  const access = res.json('access_token');
  const refresh = res.json('refresh_token');
  if (!access) {
    throw new Error('Keycloak returned 200 with no access_token');
  }
  if (!refresh) {
    throw new Error('Keycloak returned 200 with no refresh_token; this run cannot outlive 300s');
  }
  return { access: access, refresh: refresh };
}

function refreshGrant(refreshToken) {
  const res = http.post(
    KEYCLOAK + '/realms/' + REALM + '/protocol/openid-connect/token',
    { grant_type: 'refresh_token', client_id: 'smoke-tests', refresh_token: refreshToken },
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, tags: { step: 'token' } },
  );
  return res.status === 200 ? res.json('access_token') : null;
}

// Module scope is per-VU in k6 -- each VU gets its own runtime -- so these are
// per-VU, not shared.
let vuToken = null;
let vuTokenAt = 0;

// Spread the refreshes so they do not all land in the same second. Even without
// brute-force protection, a synchronised stampede would put a Keycloak spike
// inside a measurement window and attribute it to the step.
const JITTER_SEC = (__VU || 0) % 60;

function currentToken(data) {
  const now = Date.now();
  if (vuToken === null) {
    // Start from setup()'s token rather than fetching one. A cold VU that logs
    // in on its first iteration is the stampede this design exists to avoid.
    vuToken = data.token;
    vuTokenAt = data.startMs;
    return vuToken;
  }
  if (now - vuTokenAt > (REFRESH_SEC + JITTER_SEC) * 1000) {
    const fresh = refreshGrant(data.refresh);
    if (fresh) {
      vuToken = fresh;
      vuTokenAt = now;
    } else {
      // Keep serving with the old token and try again shortly. Throwing here
      // would turn a transient Keycloak blip into a hole in the curve; if the
      // token really is dead the auth counters make it visible as auth, which
      // the report refuses to read as saturation.
      vuTokenAt = now - (REFRESH_SEC - 10) * 1000;
    }
  }
  return vuToken;
}

export function setup() {
  // The only password grant in the run. It also fails fast on a broken Keycloak,
  // rather than at the first iteration of every VU at once.
  const grant = passwordGrant();
  const token = grant.access;

  // Absolute wall-clock start, so every VU in every scenario resolves its step
  // against the same origin. k6's own elapsed time is per-scenario.
  const startMs = Date.now();

  console.log('SCHEDULE core steps: ' + CORE_STEPS.join(', ') + ' req/s, ' + STEP_SEC + 's each');
  console.log('SCHEDULE quiet gap: ' + GAP_SEC + 's (gateway scale-down window is 300s)');
  console.log('SCHEDULE gateway steps: ' + GW_STEPS.join(', ') + ' req/s, ' + GW_STEP_SEC + 's each');
  console.log('SCHEDULE total: ' + gw.end + 's');

  // The same schedule again, for the reporter rather than for a human. Emitted
  // rather than duplicated in the shell, because a report that hardcodes the
  // step boundaries silently misattributes every run that overrides them
  // through CORE_STEPS or STEP_SEC. No spaces: the log line has k6's own
  // `source=console` suffix appended and the parser splits on whitespace.
  console.log('SCHEDULE_JSON ' + JSON.stringify({ gap: GAP_SEC, windows: WINDOWS }));

  return { token: token, refresh: grant.refresh, startMs: startMs };
}

// The step an iteration belongs to, or null while inside a ramp or the gap.
// Returning null rather than the nearest step is deliberate: attributing ramp
// samples to a step reports a latency the step never produced.
function stepFor(startMs) {
  const elapsed = (Date.now() - startMs) / 1000;
  for (const w of WINDOWS) {
    if (elapsed >= w.from && elapsed < w.to) return w.label;
  }
  return null;
}

function record(label, res, ok) {
  if (!label) return;
  latency[label].add(res.timings.duration);
  requests[label].add(1);
  if (ok) return;

  failures[label].add(1);
  // The class matters more than the count. A 401 means the HARNESS is broken;
  // a 5xx means the SYSTEM is. Reporting them in one number invites the reader
  // to assume the second when it is the first.
  if (res.status === 401 || res.status === 403) authErrors[label].add(1);
  else if (res.status >= 500 || res.status === 0) serverErrors[label].add(1);
  else otherErrors[label].add(1);
}

export function throughCorePath(data) {
  const label = stepFor(data.startMs);
  // Saturation means slow responses, and k6's default is no request timeout at
  // all. A request still open after 30s is not latency data, it is a stuck
  // connection holding a VU the arrival rate needs back.
  const res = http.get(GATEWAY + '/services/core/api/documents?page=0&size=20', {
    headers: { Authorization: 'Bearer ' + currentToken(data) },
    timeout: '30s',
    tags: { scenario: 'through_core', step: label || 'ramp' },
  });
  const ok = check(res, { 'documents is 200': (r) => r.status === 200 });
  record(label, res, ok);
}

export function gatewayOnlyPath(data) {
  const label = stepFor(data.startMs);
  const res = http.get(GATEWAY + '/api/auth-info', {
    timeout: '30s',
    tags: { scenario: 'gateway_only', step: label || 'ramp' },
  });
  const ok = check(res, { 'auth-info is 200': (r) => r.status === 200 });
  record(label, res, ok);
}
