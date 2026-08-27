// Database write load, and reads competing with writes (T-5.15).
//
// WHY THIS IS A SEPARATE FILE AND NOT MORE SCENARIOS IN baseline.js
//
// baseline.js is a gate. Its thresholds were measured on 2026-08-23 and `make
// load` fails when one moves, so anything added to it changes what that gate
// means and lengthens the run every deploy waits on. This asks a different
// question and gets its own file and its own target.
//
// It keeps baseline.js's shape otherwise -- closed model, ramping-vus, 10 VUs,
// scenarios run one at a time -- because the point is to compare a write
// against a read, and two different load models cannot be compared.
//
// WHAT IS ACTUALLY IN THE WRITE PATH, AND WHAT IS DELIBERATELY NOT
//
// POST /api/documents is DocumentService.initiateUpload: validate the declared
// size, generate an object key, INSERT one row, commit, then presign a PUT.
//
// The presign is LOCAL. S3Presigner computes a SigV4 signature over a request
// it never sends -- no socket is opened to Hetzner, and no object is created.
// The PUT that would talk to object storage is issued by the CLIENT, and this
// test does not issue it.
//
// That distinction is the whole reason this file can exist. docs/slos.md ruled
// a write benchmark out on the grounds that the upload path ends in a presigned
// PUT straight to Hetzner object storage, so a write benchmark would mostly
// measure Hetzner's latency from a Hetzner node and attribute it to this
// application. Correct -- for a benchmark that includes the PUT. Stopping at
// initiate() measures the row: gateway route, bearer validation, core,
// Hibernate, INSERT, commit, and a few hundred microseconds of HMAC. Whatever
// the object store costs stays out, because it is never called.
//
// WHY THE document TABLE AND NOT example_item
//
// POST /api/example-items is the purer INSERT -- one table, no service layer,
// no signing. It is still the wrong choice here, for three reasons:
//
//   - The mixed scenario is about reads and writes CONTENDING. Writing to a
//     table nobody reads measures contention for the connection pool and the
//     JVM and nothing else. The same table means the same indexes, the same
//     pages, the same autovacuum.
//   - GET /api/example-items is repository.findAll() with no pagination. A
//     write test that grows that table turns its own read side into an
//     unbounded result set, and the read latency that follows would look like
//     write contention while actually being row count.
//   - example_item is the throwaway entity the stemcell ships to be deleted. A
//     load test anchored to it dies with the first real fork.
//
// WHAT THE PENDING ROWS DO TO THE READ, CORRECTED AFTER THE FIRST RUN
//
// listAvailable() queries status = AVAILABLE. Every row this test writes is
// PENDING, because nothing here calls /complete, so the read's RESULT SET stays
// the same size however many rows the write scenario adds.
//
// This file originally concluded from that that any read latency which moved
// had to be contention. That was wrong, and the 2026-08-27 run is what showed
// it. The result set is constant; the WORK is not.
// ix_document_owner_created_at is (owner, created_at DESC) and does not carry
// status, so a listing walks that index newest-first and heap-checks each row
// for status. Every row this test writes has the current timestamp and the
// smoke user's sub, so they all sort to the FRONT of that scan and the query
// skips every one of them before reaching an AVAILABLE row. Page's count query
// pays the same cost.
//
// So a grown table makes the read slower on its own, with no writes in flight
// at all. read_after was added to measure exactly that, and it did: at p95,
// read_control 37.5ms, mixed_read 77.7ms, read_after 87.9ms. Taking the writes
// away made the read SLOWER, because by then the table was bigger still.
//
// The consequence is worth stating plainly, because the scenario's name invites
// the opposite reading: `mixed` does not measure read/write contention. It
// measures row count. Nothing it reports should be quoted as a contention
// number until read_after and read_control converge.
//
// THE COST: rows accumulate. reapAbandonedUploads() exists but is deliberately
// not scheduled, so nothing removes them on its own. write-load-test.sh counts
// them before and after and deletes them; running this script by hand leaves
// them behind, and the next run's numbers will include the table they grew.
//
// WHY THE READ CONTROL IS IN THIS RUN RATHER THAN BORROWED FROM baseline.js
//
// The number that matters is a RATIO -- what a read costs while writes are in
// flight, over what the same read costs alone. Taking the denominator from
// baseline.js's numbers compares two runs on two days on a cluster that may
// have been carrying different traffic, a different replica count and a
// different table size. read_control pays 105 seconds to make the comparison
// mean something.
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';

const GATEWAY = __ENV.GATEWAY_URL || 'http://gateway.apps.svc.cluster.local:8080';
const KEYCLOAK = __ENV.KEYCLOAK_URL || 'http://keycloak-service.keycloak.svc.cluster.local:8080';
const REALM = __ENV.REALM || 'xenopsbase';
const USERNAME = __ENV.SMOKE_USER || 'smoke';
// Not a secret: committed in the public realm file, for a user that exists only
// to be logged in as. The same account baseline.js, scalability.js and smoke.sh
// use.
const PASSWORD = __ENV.SMOKE_PASSWORD || 'smoke-dev-only';

// 10, matching baseline.js, so read_control is directly comparable to the
// through_core number already on record rather than merely similar to it.
const VUS = parseInt(__ENV.VUS || '10', 10);

// One write in every WRITE_EVERY iterations of the mixed scenario. 5 is 20%
// writes, which is a guess at a shape rather than a measurement of one -- no
// production traffic exists to derive it from (#194). It is an env var so a
// fork with real numbers can use them without editing this file.
const WRITE_EVERY = parseInt(__ENV.WRITE_EVERY || '5', 10);

// Signed but never uploaded, so this number costs nothing in storage. It still
// has to be inside application.storage.max-upload-bytes (50 MiB) or initiate()
// answers 413 and the scenario measures a validation failure.
const SIZE_BYTES = parseInt(__ENV.SIZE_BYTES || '1024', 10);

const readControl = new Trend('latency_read_control', true);
const readAfter = new Trend('latency_read_after', true);
const writeOnly = new Trend('latency_write_only', true);
const mixedRead = new Trend('latency_mixed_read', true);
const mixedWrite = new Trend('latency_mixed_write', true);

// Rows this run believes it committed, to be checked against what Postgres
// actually holds. The wrapper prints both. A 201 is the gateway's word for it;
// the row count is Postgres's, and this project's recurring defect is a
// component reporting success while doing nothing (docs/testing.md).
const written = new Counter('rows_written');

// The circuit breaker is configured with slowCallDurationThreshold: 1s and
// slowCallRateThreshold: 50 over a 10s window. If more than half the calls in
// any window exceed a second it OPENS, and the route forwards to
// /fallback/core, which answers 503 in about a millisecond. Latency then
// IMPROVES while nothing is being served -- the exact shape that gets misread
// as recovery. Counted separately so the log says which one happened.
const breakerFallbacks = new Counter('fallback_503');

const RAMP = __ENV.RAMP || '30s';
const HOLD = __ENV.HOLD || '60s';
const DOWN = __ENV.DOWN || '15s';

// Each scenario is 105s; the next starts at 110. Overlapping them would measure
// a mixture and attribute it to neither -- and in this file the mixture IS the
// third scenario, so overlapping the first two would produce it by accident and
// call it something else.
const stages = [
  { duration: RAMP, target: VUS },
  { duration: HOLD, target: VUS },
  { duration: DOWN, target: 0 },
];

export const options = {
  scenarios: {
    read_control: {
      executor: 'ramping-vus',
      exec: 'readPath',
      startVUs: 1,
      stages: stages,
      gracefulRampDown: '10s',
    },
    write_only: {
      executor: 'ramping-vus',
      exec: 'writePath',
      startVUs: 1,
      startTime: '110s',
      stages: stages,
      gracefulRampDown: '10s',
    },
    mixed: {
      executor: 'ramping-vus',
      exec: 'mixedPath',
      startVUs: 1,
      startTime: '220s',
      stages: stages,
      gracefulRampDown: '10s',
    },
    // THE SAME READ AGAIN, LAST, ON THE TABLE THE OTHER TWO SCENARIOS GREW.
    //
    // Added after the first run (2026-08-27), which could not answer the
    // question it was built to ask. mixed_read came out 2.7x slower than
    // read_control -- but by then write_only had inserted ~30,000 PENDING rows
    // owned by the same user, and mixed was offering only 38 writes/s against
    // write_only's 287. Reads tripling under an eighth of the write pressure is
    // not what contention looks like; a bigger table is.
    //
    // The claim in this file's header -- that a constant result set makes read
    // latency a clean contention signal -- was wrong. The result SET is
    // constant; the WORK is not. ix_document_owner_created_at is (owner,
    // created_at DESC) and does not carry status, so a listing walks the index
    // newest-first and heap-checks each row. Every PENDING row this test writes
    // has the current timestamp and the smoke user's sub, so they all land at
    // the FRONT of that scan: the query skips 30,000 of them before it reaches
    // the first AVAILABLE row. The count query behind Page does the same.
    //
    // With this scenario the three reads separate the two causes:
    //
    //   read_control  small table, no writes        the floor
    //   read_after    grown table, no writes        the cost of the ROWS
    //   mixed_read    grown table, writes in flight the cost of CONTENTION
    //                                               on top of the rows
    //
    // If read_after lands near mixed_read, the slowdown is row count and this
    // test says nothing about contention. If it lands near read_control, the
    // header was right after all. Either answer is worth the 105 seconds.
    //
    // ANSWERED, 2026-08-27, and not ambiguously. p95:
    //
    //   read_control   37.5ms   ~18 rows,    no writes
    //   mixed_read     77.7ms   ~35k rows,   36 writes/s in flight
    //   read_after     87.9ms   37k rows,    NO writes in flight
    //
    // read_after is SLOWER than mixed_read. Taking the writes away entirely did
    // not make the read faster; it made it slower, because by then the table was
    // bigger. Read latency here tracks row count and nothing else, and whatever
    // contention this write rate produces is too small to find underneath it.
    //
    // So `mixed` does not currently measure read/write contention, and no number
    // it produces should be quoted as though it does. Finding that out is what
    // this scenario is for, and it keeps running: the day an index makes the
    // read flat in row count, read_after minus read_control goes to zero and
    // mixed_read minus read_after becomes the contention number this file
    // originally claimed to have.
    read_after: {
      executor: 'ramping-vus',
      exec: 'readAfterPath',
      startVUs: 1,
      startTime: '330s',
      stages: stages,
      gracefulRampDown: '10s',
    },
  },

  // THE SLOs, AS CODE.
  //
  // Set from the measured run of 2026-08-27, at roughly 2.5x the observed p95
  // and 3x the observed p99 -- baseline.js's arithmetic, so the two files fail
  // for comparable reasons. Measured / threshold:
  //
  //                   run 1 p95 / run 2 p95   threshold p95 / p99
  //   read_control    28.0 / 37.5ms           75ms / 150ms
  //   write_only      56.1 / 45.5ms           150ms / 250ms
  //   mixed_read      74.5 / 77.7ms           200ms / 300ms
  //   mixed_write     36.2 / 37.8ms           100ms / 175ms
  //   read_after       n/a / 87.9ms           225ms / 350ms
  //
  // BOTH RUNS ARE SHOWN BECAUSE THEY DISAGREE, AND THE DISAGREEMENT IS THE
  // TEST'S OWN FAULT. read_control moved 28.0 -> 37.5ms between two runs of the
  // same query over the same ~18 rows. What changed was the INDEX: the first
  // run's 34,000 deleted rows left ix_document_owner_created_at at 806 pages
  // and uk_document_object_key at 575, because VACUUM frees a B-tree's entries
  // and not its pages. The second run's control was measured scanning the first
  // run's tombstones. write-load-test.sh now REINDEXes after cleanup; the
  // thresholds below stay where run 1 put them, and read_control should settle
  // back near 28ms once a run starts from unbloated indexes.
  //
  // A WRITE COSTS ABOUT TWICE A READ. 56.1ms against 28.0ms at p95, 22.1ms
  // against 10.8ms at the median. That is the headline number this file was
  // built to produce, and it is unremarkable in the good sense: an INSERT and a
  // commit through the whole stack, with no write amplification hiding in it.
  //
  // TWO OF THESE ARE COUPLED TO THROUGHPUT, AND THAT IS A REAL FRAGILITY.
  // mixed_read's latency depends on how many rows write_only managed to insert
  // before it -- see the header. A faster cluster writes more rows in the same
  // 105 seconds and makes this read slower, so a machine upgrade can fail this
  // threshold while improving everything it measures. It is set anyway, because
  // an unstable gate that is read is better than no gate, but do not tighten it
  // without reading the read_after comment first.
  //
  // mixed_write's 100ms is TIGHTER than write_only's 150ms, which looks
  // backwards until you notice the rates: write_only sustained 287 writes/s and
  // mixed only 38, because four in five of its iterations are reads. These
  // numbers are valid for WRITE_EVERY=5 and meaningless if it is overridden.
  //
  // THE CORRECTNESS THRESHOLDS BELOW NEED NO BASELINE. A write that 500s is
  // wrong at any latency, and a run whose writes are quietly being answered by
  // the circuit breaker is not a write test at all.
  thresholds: {
    'http_req_failed': ['rate<0.01'],
    'checks': ['rate>0.99'],
    // Not "rare". None. A single fallback means the breaker opened, and every
    // number in the run after that point is about the breaker.
    'fallback_503': ['count==0'],

    'latency_read_control': ['p(95)<75', 'p(99)<150'],
    'latency_write_only': ['p(95)<150', 'p(99)<250'],
    'latency_mixed_read': ['p(95)<200', 'p(99)<300'],
    'latency_mixed_write': ['p(95)<100', 'p(99)<175'],
    // Same throughput coupling as mixed_read, and worse: this one is a pure
    // function of how many rows the two write scenarios managed to insert.
    'latency_read_after': ['p(95)<225', 'p(99)<350'],
  },

  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
};

// ---------------------------------------------------------------------------
// TOKENS
// ---------------------------------------------------------------------------
//
// Three scenarios 110s apart run for about 5m30s, and the realm's
// accessTokenLifespan is 300s. baseline.js fetches one token in setup() and can
// afford to because it finishes in 3m30s; this file cannot. A token that
// expires mid-run turns the last scenario into 401s, and 401s look exactly like
// a system that stopped coping -- throughput to zero, latency to nothing, the
// database idle -- because rejections are cheap. scalability.js lost a working
// session to that misreading; the machinery below is its answer, ported.
//
// EXACTLY ONE PASSWORD GRANT PER RUN. The realm sets bruteForceProtected: true,
// and Keycloak's quick-login check treats repeated logins for one user inside a
// second as an attack even when every credential is correct -- so VUs logging
// in on their own would disable the account and answer with invalid_grant.
// Refresh grants carry no password and are not subject to it, and the realm
// leaves revokeRefreshToken false, so one refresh token serves every VU.
const REFRESH_SEC = parseInt(__ENV.TOKEN_REFRESH_SEC || '120', 10);

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
    // Tagged out of the scenarios: this is the harness authenticating, not the
    // application serving.
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, tags: { scenario: 'token' } },
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
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, tags: { scenario: 'token' } },
  );
  return res.status === 200 ? res.json('access_token') : null;
}

// Module scope is per-VU in k6 -- each VU gets its own runtime -- so these are
// per-VU, not shared.
let vuToken = null;
let vuTokenAt = 0;

// Spread the refreshes so they do not all land in the same second. A
// synchronised stampede would put a Keycloak spike inside a measurement window
// and attribute it to the database.
const JITTER_SEC = (__VU || 0) % 30;

function currentToken(data) {
  const now = Date.now();
  if (vuToken === null) {
    // Start from setup()'s token rather than fetching one. Every VU in the
    // third scenario is cold, and a cold VU that logs in on its first iteration
    // is the stampede this design exists to avoid.
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
      // Keep serving with the old token and retry shortly. Throwing would turn
      // a transient Keycloak blip into a hole in the measurement.
      vuTokenAt = now - (REFRESH_SEC - 10) * 1000;
    }
  }
  return vuToken;
}

export function setup() {
  const grant = passwordGrant();
  const startMs = Date.now();

  console.log('WRITE LOAD: ' + VUS + ' VUs, ' + RAMP + ' ramp / ' + HOLD + ' hold / ' + DOWN + ' down per scenario');
  console.log('WRITE LOAD: read_control 0s, write_only 110s, mixed 220s (1 write in ' + WRITE_EVERY + '), read_after 330s');
  console.log('WRITE LOAD: every row written is PENDING and is left for the wrapper to delete');

  return { token: grant.access, refresh: grant.refresh, startMs: startMs };
}

// The same read baseline.js measures, deliberately unchanged: page 0, size 20,
// sorted by createdAt desc. A different page size here would produce a number
// that cannot be compared with the one already on record.
function read(data, trend, scenario) {
  const res = http.get(GATEWAY + '/services/core/api/documents?page=0&size=20', {
    headers: { Authorization: 'Bearer ' + currentToken(data) },
    // k6's default is no request timeout at all. A request still open after 30s
    // is not latency data, it is a stuck connection holding a VU.
    timeout: '30s',
    tags: { scenario: scenario, op: 'read' },
  });
  trend.add(res.timings.duration);
  // Always a sample, zero or one, rather than only on a 503. A k6 threshold
  // over a metric that never received a sample is not evaluated, so a counter
  // that only appears when the bad thing happens has a threshold that only
  // exists when it is already too late to be useful.
  breakerFallbacks.add(res.status === 503 ? 1 : 0);
  check(res, { [scenario + ': documents list is 200']: (r) => r.status === 200 });
}

// 201, not "not an error". The check is written against the exact status on
// purpose: an open circuit answers this route with a 503 problem document, and
// a looser check would pass on it. A write test that cannot tell a committed
// row from a fallback is worse than no write test.
//
// NO Idempotency-Key HEADER, DELIBERATELY. IdempotencyFilter is opt-in --
// shouldNotFilter() returns true when the header is absent -- so these writes
// bypass it entirely. Sending one would add a second table's INSERT plus a
// lookup to every iteration and measure the filter alongside the document
// insert. What the filter costs is a real question and a separate scenario.
function write(data, trend, scenario) {
  const body = JSON.stringify({
    // Unique per iteration, and prefixed so the wrapper's cleanup can delete
    // exactly the rows this test made and nothing a human uploaded.
    filename: 'k6-write-' + __VU + '-' + __ITER + '-' + Date.now() + '.bin',
    contentType: 'application/octet-stream',
    sizeBytes: SIZE_BYTES,
  });

  const res = http.post(GATEWAY + '/services/core/api/documents', body, {
    headers: {
      Authorization: 'Bearer ' + currentToken(data),
      'Content-Type': 'application/json',
    },
    timeout: '30s',
    tags: { scenario: scenario, op: 'write' },
  });

  trend.add(res.timings.duration);
  breakerFallbacks.add(res.status === 503 ? 1 : 0);
  const ok = check(res, { [scenario + ': initiate upload is 201']: (r) => r.status === 201 });
  // Zero as well as one, so the counter is always present in the summary for
  // the wrapper to read against Postgres's own count.
  written.add(ok ? 1 : 0);
}

export function readPath(data) {
  read(data, readControl, 'read_control');
}

export function writePath(data) {
  write(data, writeOnly, 'write_only');
}

export function readAfterPath(data) {
  read(data, readAfter, 'read_after');
}

// A deterministic stride rather than Math.random(). Over a 60s hold the two
// converge on the same ratio, but a stride also holds it inside every 10-second
// slice -- which matters because the circuit breaker's window is 10s, so a
// random run can put a burst of writes in one window and open the breaker on an
// arrangement the next run will not reproduce.
//
// Offset by __VU so the VUs do not all write on the same iteration index.
export function mixedPath(data) {
  if ((__ITER + __VU) % WRITE_EVERY === 0) {
    write(data, mixedWrite, 'mixed');
  } else {
    read(data, mixedRead, 'mixed');
  }
}
