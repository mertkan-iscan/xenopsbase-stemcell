package com.xenopsoftware.core.web.rest;

import com.xenopsoftware.core.config.ConditionalOnDocumentStorage;
import com.xenopsoftware.core.domain.Document;
import com.xenopsoftware.core.security.SecurityUtils;
import com.xenopsoftware.core.service.DocumentService;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;
import java.net.URI;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.springframework.data.domain.Page;
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
 * Document upload and download (T-3.7).
 *
 * <h2>Bytes never touch this service</h2>
 *
 * There is no multipart endpoint here and no {@code StreamingResponseBody}. The client asks for a
 * URL, then talks to the object store directly:
 *
 * <pre>
 *   POST /api/documents                 -&gt; { id, uploadUrl, ... }
 *   PUT  &lt;uploadUrl&gt;                    (client -&gt; object store, not through here)
 *   POST /api/documents/{id}/complete   -&gt; the row becomes AVAILABLE
 *
 *   GET  /api/documents/{id}/download   -&gt; 302 to a presigned GET
 * </pre>
 *
 * Proxying the bytes would put this service on the critical path for something the object store
 * does better, make a large upload a heap and socket cost per replica, and turn one slow client
 * into contention for every other request.
 *
 * <h2>Ownership</h2>
 *
 * Every lookup is scoped by the caller's {@code sub} in the repository query rather than filtered
 * after loading. A document belonging to someone else is indistinguishable from one that does not
 * exist, which is the intended answer.
 */
@RestController
@RequestMapping("/api/documents")
@ConditionalOnDocumentStorage
public class DocumentResource {

    /** The largest page this API will serve, whatever the client asks for. */
    static final int MAX_PAGE_SIZE = 100;

    private final DocumentService documentService;

    public DocumentResource(DocumentService documentService) {
        this.documentService = documentService;
    }

    /** Registers the intent to upload and returns the URL to PUT to. */
    @PostMapping
    public ResponseEntity<UploadTicket> initiate(@Valid @RequestBody InitiateRequest request) {
        DocumentService.Upload upload = documentService.initiateUpload(
            request.filename(),
            request.contentType(),
            request.sizeBytes(),
            currentOwner()
        );

        return ResponseEntity.status(HttpStatus.CREATED).body(
            new UploadTicket(
                upload.document().getId(),
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
    @ExceptionHandler(DocumentService.UploadTooLargeException.class)
    public ResponseEntity<String> handleTooLarge(DocumentService.UploadTooLargeException e) {
        return ResponseEntity.status(HttpStatus.PAYLOAD_TOO_LARGE).body(e.getMessage());
    }

    /**
     * Confirms the object arrived. Until this is called the document is not downloadable, because
     * until this is called nothing has verified that any bytes exist.
     */
    @PostMapping("/{id}/complete")
    public ResponseEntity<DocumentView> complete(@PathVariable Long id) {
        return documentService
            .completeUpload(id, currentOwner())
            .map(DocumentView::of)
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
    public ResponseEntity<List<DocumentView>> list(
        @PageableDefault(size = 20, sort = "createdAt", direction = Sort.Direction.DESC) Pageable pageable
    ) {
        Page<Document> page = documentService.listAvailable(currentOwner(), capped(pageable));
        HttpHeaders headers = PaginationUtil.generatePaginationHttpHeaders(ServletUriComponentsBuilder.fromCurrentRequest(), page);
        return ResponseEntity.ok().headers(headers).body(page.getContent().stream().map(DocumentView::of).toList());
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
        Optional<URI> url = documentService.presignDownload(id, currentOwner());
        return url
            .map(uri -> ResponseEntity.status(HttpStatus.FOUND).header("Cache-Control", "no-store").location(uri).<Void>build())
            .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable Long id) {
        return documentService.delete(id, currentOwner()) ? ResponseEntity.noContent().build() : ResponseEntity.notFound().build();
    }

    /**
     * The stable identifier for a Keycloak user.
     *
     * <p>{@code sub}, not {@code preferred_username}: a username can be changed in Keycloak, and
     * every document owned under the old one would become unreachable.
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
        @NotBlank @Size(max = 255) String filename,
        @NotBlank @Size(max = 255) String contentType,
        @Positive long sizeBytes
    ) {}

    /**
     * @param contentLength the client must PUT exactly this many bytes; the object store rejects
     *                      anything else, because the length is part of the signature
     */
    public record UploadTicket(Long id, URI uploadUrl, long expiresInSeconds, long contentLength, String contentType) {}

    public record DocumentView(Long id, String filename, String contentType, Long sizeBytes, String status, Instant createdAt) {
        static DocumentView of(Document d) {
            return new DocumentView(
                d.getId(),
                d.getFilename(),
                d.getContentType(),
                d.getSizeBytes(),
                d.getStatus().name(),
                d.getCreatedAt()
            );
        }
    }
}
