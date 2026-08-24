package com.xenopsoftware.core.web.filter;

import com.xenopsoftware.core.domain.IdempotencyRecord;
import com.xenopsoftware.core.repository.IdempotencyRecordRepository;
import com.xenopsoftware.core.security.SecurityUtils;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Set;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.annotation.Order;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.util.ContentCachingResponseWrapper;

/**
 * Makes unsafe requests safe to retry, when the client asks for it (T-3.8).
 *
 * <pre>
 *   POST /api/documents
 *   Idempotency-Key: 9f2c1b...
 * </pre>
 *
 * <p>A client that sends a POST and never sees the response cannot know whether it happened.
 * Retrying risks doing it twice; not retrying risks not doing it at all. With a key, the server
 * recognises the retry and <b>replays the original response</b> rather than acting again.
 *
 * <p>Replaying the original response, not a fresh success, is the part that matters. Returning a
 * new 200 to a retry would tell the client it worked without ever telling it the id of what was
 * created the first time — success that is unusable.
 *
 * <h2>Opt-in, deliberately</h2>
 *
 * No key means no idempotency handling, and the request behaves exactly as it did before. Making
 * the header mandatory would break every existing client the day it shipped, and a template cannot
 * make that choice on behalf of the projects forked from it. A fork that wants it enforced adds
 * the check here.
 *
 * <h2>The three answers</h2>
 *
 * <table>
 *   <tr><td>Same key, same request, finished</td><td>the stored response, plus {@code Idempotency-Replayed: true}</td></tr>
 *   <tr><td>Same key, same request, still running</td><td>409 — a concurrent retry, not a duplicate to replay</td></tr>
 *   <tr><td>Same key, <b>different</b> request</td><td>422 — a client bug, and answering it with the old response would hide it</td></tr>
 * </table>
 */
@Component
// AFTER Spring Security, not before. Idempotency keys are scoped to the authenticated caller, and
// nothing is authenticated until the security chain has run -- ordered ahead of it, every request
// scopes to "anonymous" and one caller can read another's stored response by guessing a key.
//
// That is not a theoretical ordering nit. This filter was written at HIGHEST_PRECEDENCE + 10 and
// the scoping test caught it: two different users sending the same key collided, and the second
// got 422 instead of a request of their own.
@Order(IdempotencyFilter.ORDER)
public class IdempotencyFilter extends OncePerRequestFilter {

    private static final Logger LOG = LoggerFactory.getLogger(IdempotencyFilter.class);

    /**
     * Runs after Spring Security, whose filter chain is registered at -100.
     *
     * <p>A literal rather than {@code SecurityProperties.DEFAULT_FILTER_ORDER}: Boot 4 moved that
     * class and dropped the constant, so referencing it ties this file to a package that has
     * already been relocated once.
     */
    static final int ORDER = -90;

    /** The name from the IETF draft, so clients and gateways that already know it interoperate. */
    public static final String HEADER = "Idempotency-Key";

    public static final String REPLAYED_HEADER = "Idempotency-Replayed";

    /** GET and HEAD are already idempotent by definition; a key on them means nothing. */
    private static final Set<String> UNSAFE = Set.of("POST", "PUT", "PATCH", "DELETE");

    private static final int MAX_KEY_LENGTH = 255;

    /**
     * Responses larger than this are executed but not stored, and a retry re-executes.
     * The alternative is letting a client turn this table into unbounded storage by sending
     * large keyed requests.
     */
    private static final int MAX_STORED_BODY = 64 * 1024;

    /** Request bodies larger than this are not buffered, and so not made idempotent. */
    private static final int MAX_BUFFERED_BODY = 1024 * 1024;

    private final IdempotencyRecordRepository repository;

    public IdempotencyFilter(IdempotencyRecordRepository repository) {
        this.repository = repository;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String key = request.getHeader(HEADER);
        return key == null || key.isBlank() || key.length() > MAX_KEY_LENGTH || !UNSAFE.contains(request.getMethod());
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
        throws ServletException, IOException {
        String key = request.getHeader(HEADER);

        // Scoped to the caller. A globally unique key would let one client observe another's
        // response simply by guessing a value, which turns a reliability feature into a data leak.
        String scope = SecurityUtils.getCurrentUserId().orElse("anonymous");

        // A request body is a one-shot stream. Hashing it here consumes it, so the request has to
        // be wrapped in something that can serve it again -- otherwise the controller downstream
        // receives an empty body and the endpoint fails in a way that looks nothing like this
        // filter.
        //
        // Spring's ContentCachingRequestWrapper does NOT do this. It records what was read so it
        // can be inspected afterwards; it does not replay. Using it here leaves the controller
        // with an exhausted stream, which is a quiet and confusing failure.
        if (request.getContentLengthLong() > MAX_BUFFERED_BODY) {
            // Too large to buffer. Executed normally, without idempotency handling, rather than
            // rejected -- the client asked for a guarantee this filter cannot give, and failing
            // the request outright would be a worse answer than performing it.
            LOG.debug("Body exceeds {} bytes; proceeding without idempotency handling", MAX_BUFFERED_BODY);
            chain.doFilter(request, response);
            return;
        }

        ReplayableBodyRequest cachedRequest = new ReplayableBodyRequest(request);
        byte[] body = cachedRequest.body();
        String hash = sha256(request.getMethod() + '\n' + request.getRequestURI() + '\n' + new String(body, StandardCharsets.UTF_8));

        IdempotencyRecord existing = repository.findByIdempotencyKeyAndScope(key, scope).orElse(null);
        if (existing != null) {
            replayOrReject(existing, hash, response);
            return;
        }

        IdempotencyRecord claim = new IdempotencyRecord();
        claim.setIdempotencyKey(key);
        claim.setScope(scope);
        claim.setRequestHash(hash);
        claim.setState(IdempotencyRecord.State.IN_PROGRESS);
        try {
            repository.saveAndFlush(claim);
        } catch (DataIntegrityViolationException e) {
            // Lost the race against a concurrent retry. The unique constraint is doing the
            // arbitration; a SELECT-then-INSERT would have let both requests through, which is
            // exactly the double-execution this feature exists to prevent.
            IdempotencyRecord winner = repository.findByIdempotencyKeyAndScope(key, scope).orElse(null);
            if (winner == null) {
                throw e;
            }
            replayOrReject(winner, hash, response);
            return;
        }

        ContentCachingResponseWrapper cachedResponse = new ContentCachingResponseWrapper(response);
        try {
            chain.doFilter(cachedRequest, cachedResponse);
            record(claim, cachedResponse);
        } catch (Exception e) {
            // The claim must not outlive a failed attempt. Leaving it IN_PROGRESS would make
            // every later retry of a request that never succeeded return 409 forever.
            repository.delete(claim);
            throw e;
        } finally {
            cachedResponse.copyBodyToResponse();
        }
    }

    private void replayOrReject(IdempotencyRecord record, String hash, HttpServletResponse response) throws IOException {
        if (!record.getRequestHash().equals(hash)) {
            LOG.warn("Idempotency key {} reused for a different request", record.getIdempotencyKey());
            problem(
                response,
                HttpStatus.UNPROCESSABLE_ENTITY,
                "Idempotency key reused",
                "This Idempotency-Key was already used for a different request. Use a new key."
            );
            return;
        }

        if (record.getState() == IdempotencyRecord.State.IN_PROGRESS) {
            problem(
                response,
                HttpStatus.CONFLICT,
                "Request in progress",
                "A request with this Idempotency-Key is still being processed. Retry shortly."
            );
            return;
        }

        response.setStatus(record.getResponseStatus());
        if (record.getResponseType() != null) {
            response.setContentType(record.getResponseType());
        }
        response.setHeader(REPLAYED_HEADER, "true");
        if (record.getResponseBody() != null) {
            response.getWriter().write(record.getResponseBody());
        }
    }

    private void record(IdempotencyRecord claim, ContentCachingResponseWrapper response) {
        byte[] body = response.getContentAsByteArray();

        // Only successful outcomes are replayable. Storing a 500 would make a transient failure
        // permanent: every retry would be answered with the same error without the server ever
        // trying again, which is the opposite of what a retry is for.
        boolean replayable = response.getStatus() < 400 && body.length <= MAX_STORED_BODY;
        if (!replayable) {
            repository.delete(claim);
            return;
        }

        claim.setState(IdempotencyRecord.State.COMPLETED);
        claim.setResponseStatus(response.getStatus());
        claim.setResponseBody(new String(body, StandardCharsets.UTF_8));
        claim.setResponseType(response.getContentType());
        claim.setCompletedAt(Instant.now());
        repository.save(claim);
    }

    private static void problem(HttpServletResponse response, HttpStatus status, String title, String detail) throws IOException {
        response.setStatus(status.value());
        response.setContentType(MediaType.APPLICATION_PROBLEM_JSON_VALUE);
        response.getWriter().write(
            """
            {"type":"about:blank","title":"%s","status":%d,"detail":"%s"}""".formatted(title, status.value(), detail)
        );
    }

    /**
     * Buffers the body once and serves it as many times as asked.
     *
     * <p>Written out rather than reusing a Spring class because none of them do this: the
     * caching wrappers record what was read for later inspection, which is a different job.
     */
    private static final class ReplayableBodyRequest extends jakarta.servlet.http.HttpServletRequestWrapper {

        private final byte[] body;

        ReplayableBodyRequest(HttpServletRequest request) throws IOException {
            super(request);
            this.body = request.getInputStream().readAllBytes();
        }

        byte[] body() {
            return body;
        }

        @Override
        public jakarta.servlet.ServletInputStream getInputStream() {
            java.io.ByteArrayInputStream source = new java.io.ByteArrayInputStream(body);
            return new jakarta.servlet.ServletInputStream() {
                @Override
                public int read() {
                    return source.read();
                }

                @Override
                public boolean isFinished() {
                    return source.available() == 0;
                }

                @Override
                public boolean isReady() {
                    return true;
                }

                @Override
                public void setReadListener(jakarta.servlet.ReadListener listener) {
                    throw new UnsupportedOperationException("This request is buffered; async reads do not apply");
                }
            };
        }

        @Override
        public java.io.BufferedReader getReader() {
            return new java.io.BufferedReader(
                new java.io.InputStreamReader(new java.io.ByteArrayInputStream(body), StandardCharsets.UTF_8)
            );
        }
    }

    private static String sha256(String value) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 is required by every JVM", e);
        }
    }
}
