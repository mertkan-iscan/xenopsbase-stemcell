package com.xenopsoftware.core.platform;

import com.xenopsoftware.common.security.SecurityUtils;
import com.xenopsoftware.common.storage.ConditionalOnObjectStore;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;
import java.net.URI;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.web.PageableDefault;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.servlet.support.ServletUriComponentsBuilder;
import tech.jhipster.web.util.PaginationUtil;

/**
 * The platform probe: the template's self-test, as an HTTP path (T-9.2).
 *
 * <h2>Why a template that claims to have no business logic ships an endpoint</h2>
 *
 * Because the alternative is a stemcell whose smoke test, load tests and restore drill all pass
 * because there is nothing left for them to check. This path is deliberately named for what it is
 * — a probe, not a document, not an item — and it exists to be exercised, then deleted by a fork
 * whose own endpoints exercise the same seams.
 *
 * <p>One request through {@code POST} touches every one of them:
 *
 * <pre>
 *   Idempotency-Key header  -&gt; IdempotencyFilter, replay instead of a second row
 *   the row                 -&gt; audit columns, audit_log, tenant discriminator, soft delete
 *   the outbox              -&gt; a message committed with the change it announces
 *   the response            -&gt; a presigned PUT the client uses against real object storage
 * </pre>
 *
 * <h2>Bytes never touch this service</h2>
 *
 * There is no multipart endpoint here and no {@code StreamingResponseBody}. The client asks for a
 * URL, then talks to the object store directly:
 *
 * <pre>
 *   POST /api/platform/probe                 -&gt; { id, uploadUrl, ... }
 *   PUT  &lt;uploadUrl&gt;                         (client -&gt; object store, not through here)
 *   POST /api/platform/probe/{id}/complete   -&gt; the row becomes AVAILABLE
 *
 *   GET  /api/platform/probe/{id}/download   -&gt; 302 to a presigned GET
 * </pre>
 *
 * Proxying the bytes would put this service on the critical path for something the object store
 * does better, make a large upload a heap and socket cost per replica, and turn one slow client
 * into contention for every other request.
 *
 * <h2>Ownership</h2>
 *
 * Every lookup is scoped by the caller's {@code sub} in the repository query rather than filtered
 * after loading. A probe belonging to someone else is indistinguishable from one that does not
 * exist, which is the intended answer.
 */
@RestController
@RequestMapping("/api/platform/probe")
@ConditionalOnObjectStore
public class PlatformProbeResource {

    /** The largest page this API will serve, whatever the client asks for. */
    static final int MAX_PAGE_SIZE = 100;

    private final PlatformProbeService probeService;

    public PlatformProbeResource(PlatformProbeService probeService) {
        this.probeService = probeService;
    }

    /** Registers the intent to upload and returns the URL to PUT to. */
    @PostMapping
    public ResponseEntity<UploadTicket> initiate(@Valid @RequestBody InitiateRequest request) {
        PlatformProbeService.Upload upload = probeService.initiateUpload(
            request.label(),
            request.contentType(),
            request.sizeBytes(),
            currentOwner()
        );

        return ResponseEntity.status(HttpStatus.CREATED).body(
            new UploadTicket(
                upload.probe().getId(),
                upload.uploadUrl(),
                upload.expiresInSeconds(),
                upload.contentLength(),
                request.contentType()
            )
        );
    }

    /**
     * A declared size outside the configured range is a client error, not a server one.
     *
     * <p>Returned here rather than left to the generic handler so the message names the limit —
     * otherwise the client learns only that something was rejected, and the obvious next move is
     * to retry the same upload.
     */
    @ExceptionHandler(PlatformProbeService.UploadTooLargeException.class)
    public ResponseEntity<String> handleTooLarge(PlatformProbeService.UploadTooLargeException e) {
        return ResponseEntity.status(HttpStatus.PAYLOAD_TOO_LARGE).body(e.getMessage());
    }

    /**
     * Confirms the object arrived. Until this is called the probe is not downloadable, because
     * until this is called nothing has verified that any bytes exist.
     */
    @PostMapping("/{id}/complete")
    public ResponseEntity<ProbeView> complete(@PathVariable Long id) {
        return probeService
            .completeUpload(id, currentOwner())
            .map(ProbeView::of)
            .map(ResponseEntity::ok)
            .orElseGet(() -> ResponseEntity.notFound().build());
    }

    /**
     * Paged listing. The contract every collection endpoint in this template inherits (T-3.8):
     *
     * <pre>
     *   ?page=0&amp;size=20&amp;sort=createdAt,desc
     *
     *   X-Total-Count: 137
     *   Link: &lt;...page=1&gt;; rel="next", &lt;...page=6&gt;; rel="last", ...
     * </pre>
     *
     * <p>The total goes in a header rather than wrapping the body in an envelope, so the body
     * stays a plain JSON array. An envelope forces every client to unwrap before it can read
     * anything, including clients that never paginate.
     *
     * <p>{@code @PageableDefault} caps the page size. Without a cap, {@code ?size=1000000} is an
     * unauthenticated-shaped denial of service against the database: one request, one enormous
     * result set, and nothing in the code path that objects.
     */
    @GetMapping
    public ResponseEntity<List<ProbeView>> list(
        @PageableDefault(size = 20, sort = "createdAt", direction = Sort.Direction.DESC) Pageable pageable
    ) {
        // Cache-aside through Valkey (T-3.22, #264). A miss, an unreachable cache or an entry that
        // will not deserialise all fall through to Postgres inside the service, so this method has
        // no cache-specific branch and no way to behave differently when Valkey is gone.
        Pageable requested = capped(pageable);
        CachedProbePage cached = probeService.listAvailableCached(currentOwner(), requested);

        // Rebuilt rather than cached: PageImpl carries the Pageable that produced it and has no
        // stable JSON contract, so only the content and the total are stored (ADR-0011). The
        // pagination headers need a Page, and this is the cheapest honest way to give them one.
        Page<CachedProbePage.CachedProbe> page = new PageImpl<>(cached.content(), requested, cached.totalElements());
        HttpHeaders headers = PaginationUtil.generatePaginationHttpHeaders(ServletUriComponentsBuilder.fromCurrentRequest(), page);
        return ResponseEntity.ok().headers(headers).body(cached.content().stream().map(ProbeView::of).toList());
    }

    /**
     * {@code @PageableDefault} sets the default size, not a maximum — a client asking for
     * {@code size=100000} still gets it. This is the enforced ceiling.
     */
    private static Pageable capped(Pageable pageable) {
        return pageable.getPageSize() > MAX_PAGE_SIZE
            ? PageRequest.of(pageable.getPageNumber(), MAX_PAGE_SIZE, pageable.getSort())
            : pageable;
    }

    /**
     * Redirects to a short-lived presigned GET.
     *
     * <p>302 rather than returning the URL in a body so that an ordinary anchor or {@code <img>}
     * tag works without client-side code. The redirect target is a bearer credential with a TTL,
     * so it must not be cached: {@code no-store} is set explicitly, since a proxy caching a 302
     * would hand the same URL to the next caller.
     */
    @GetMapping("/{id}/download")
    public ResponseEntity<Void> download(@PathVariable Long id) {
        Optional<URI> url = probeService.presignDownload(id, currentOwner());
        return url
            .map(uri -> ResponseEntity.status(HttpStatus.FOUND).header("Cache-Control", "no-store").location(uri).<Void>build())
            .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable Long id) {
        return probeService.delete(id, currentOwner()) ? ResponseEntity.noContent().build() : ResponseEntity.notFound().build();
    }

    /**
     * The stable identifier for a Keycloak user.
     *
     * <p>{@code sub}, not {@code preferred_username}: a username can be changed in Keycloak, and
     * every probe owned under the old one would become unreachable.
     */
    private String currentOwner() {
        return SecurityUtils.getCurrentUserId().orElseThrow(() ->
            new IllegalStateException("No authenticated principal on a secured endpoint")
        );
    }

    /**
     * @param sizeBytes exact size of the upload. Required, because the presigned PUT signs this
     *                  value and S3 treats it as exact — there is no way to presign a range.
     */
    public record InitiateRequest(
        @NotBlank @Size(max = 255) String label,
        @NotBlank @Size(max = 255) String contentType,
        @Positive long sizeBytes
    ) {}

    /**
     * @param contentLength the client must PUT exactly this many bytes; the object store rejects
     *                      anything else, because the length is part of the signature
     */
    public record UploadTicket(Long id, URI uploadUrl, long expiresInSeconds, long contentLength, String contentType) {}

    public record ProbeView(Long id, String label, String contentType, Long sizeBytes, String status, Instant createdAt) {
        /**
         * From the cached DTO. Kept as a separate type from {@code CachedProbe} on purpose: the
         * wire format is this repository's public contract and the cached shape is an internal one,
         * and letting them be the same type means a wire change silently reinterprets entries
         * already sitting in Valkey under the current schema version.
         */
        static ProbeView of(CachedProbePage.CachedProbe d) {
            return new ProbeView(d.id(), d.label(), d.contentType(), d.sizeBytes(), d.status(), d.createdAt());
        }

        static ProbeView of(PlatformProbe d) {
            return new ProbeView(d.getId(), d.getLabel(), d.getContentType(), d.getSizeBytes(), d.getStatus().name(), d.getCreatedAt());
        }
    }
}
