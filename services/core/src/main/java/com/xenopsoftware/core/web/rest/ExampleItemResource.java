package com.xenopsoftware.core.web.rest;

import com.xenopsoftware.core.domain.ExampleItem;
import com.xenopsoftware.core.repository.ExampleItemRepository;
import jakarta.validation.Valid;
import java.util.List;
import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

/**
 * DELETE THIS along with {@link ExampleItem}.
 *
 * Two endpoints, each proving something the next real controller depends on.
 */
@RestController
@RequestMapping("/api")
public class ExampleItemResource {

    private final ExampleItemRepository repository;

    public ExampleItemResource(ExampleItemRepository repository) {
        this.repository = repository;
    }

    /**
     * Proves the identity actually arrived. The gateway relays the access token
     * inward, so this reports what the CORE service sees -- not what the gateway
     * saw. Those differ whenever the relay is misconfigured, and without an
     * endpoint like this the difference is invisible: requests still succeed,
     * they are just anonymous by the time they land here.
     */
    @GetMapping("/whoami")
    public Map<String, Object> whoami(Authentication authentication) {
        if (authentication == null) {
            return Map.of("authenticated", false);
        }
        return Map.of(
            "authenticated", authentication.isAuthenticated(),
            "name", authentication.getName(),
            "authorities", authentication.getAuthorities().stream().map(Object::toString).toList()
        );
    }

    /** Proves JPA, Flyway and ddl-auto=validate agree about the schema. */
    @GetMapping("/example-items")
    public List<ExampleItem> list() {
        return repository.findAll();
    }

    @PostMapping("/example-items")
    public ResponseEntity<ExampleItem> create(@Valid @RequestBody ExampleItem item) {
        item.setId(null);
        return ResponseEntity.ok(repository.save(item));
    }
}
