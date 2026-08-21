package com.xenopsoftware.core.web.rest;

import com.xenopsoftware.core.service.infra.InfraUsageService;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Infrastructure usage, for the operations view in the frontend (T-3.16).
 *
 * <h2>Why the path starts with /api/admin</h2>
 *
 * {@code SecurityConfiguration} already restricts {@code /api/admin/**} to
 * {@code AuthoritiesConstants.ADMIN}. Putting this endpoint under that prefix means the
 * authorization rule for it lives in exactly one place. A dedicated rule here would be a second
 * place for it to drift from, and the drift would be silent: the endpoint would keep answering,
 * just to more people than intended.
 *
 * <p>It is admin-only because a list of every container, its limits and its volumes is a map of the
 * infrastructure. That is reconnaissance, and it is not something an ordinary application user has
 * any reason to read.
 *
 * <h2>Unconfigured and unavailable are different answers</h2>
 *
 * Both are reported as problem documents (T-3.8) with distinct statuses, rather than as an empty
 * payload. An empty dashboard is indistinguishable from an idle cluster, and the whole point of
 * this view is to tell the difference.
 */
@RestController
@RequestMapping("/api/admin/infra")
public class InfraUsageResource {

    private final InfraUsageService infraUsageService;

    public InfraUsageResource(InfraUsageService infraUsageService) {
        this.infraUsageService = infraUsageService;
    }

    /**
     * A point-in-time reading of what the cluster is consuming.
     *
     * <p>Deliberately not cached. The numbers are a few seconds old by the time they arrive
     * regardless, and a cache here would mean the dashboard disagreeing with Prometheus for reasons
     * nobody could see from the page.
     */
    @GetMapping("/usage")
    public InfraUsageService.Usage usage() {
        return infraUsageService.usage();
    }

    /**
     * 501, not 503. The service is working exactly as configured; the feature was simply never
     * turned on, and telling an operator to retry would be a lie.
     */
    @ExceptionHandler(InfraUsageService.NotConfiguredException.class)
    ProblemDetail notConfigured(InfraUsageService.NotConfiguredException e) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(HttpStatus.NOT_IMPLEMENTED, e.getMessage());
        problem.setTitle("Infrastructure usage is not configured");
        return problem;
    }

    /** 503, because this one is worth retrying. */
    @ExceptionHandler(InfraUsageService.UnavailableException.class)
    ProblemDetail unavailable(InfraUsageService.UnavailableException e) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(HttpStatus.SERVICE_UNAVAILABLE, e.getMessage());
        problem.setTitle("Prometheus is unavailable");
        return problem;
    }
}
