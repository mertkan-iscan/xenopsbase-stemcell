package com.xenopsoftware.core.config;

import com.xenopsoftware.common.idempotency.IdempotencyRecord;
import com.xenopsoftware.common.outbox.OutboxMessage;
import org.springframework.boot.persistence.autoconfigure.EntityScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;
import org.springframework.transaction.annotation.EnableTransactionManagement;

/**
 * Where this service's persistence looks for entities and repositories.
 *
 * <h2>Both lists name the shared modules explicitly, and that is deliberate</h2>
 *
 * {@link OutboxMessage} and {@link IdempotencyRecord} live in {@code platform-common} and
 * {@code platform-common-web}, outside this application's own package. Neither the entity scan nor
 * the repository scan would find them by default.
 *
 * <p>The shared modules do NOT declare this on the service's behalf, tempting as it looks.
 * {@code @EntityScan} anywhere in the context <em>replaces</em> the application's default entity
 * packages rather than adding to them, so a library that declared one would silently stop
 * {@code com.xenopsoftware.core.domain} from being scanned — an entity quietly becoming "not a
 * managed type" in a service that never touched its own configuration.
 *
 * <p>Stated here, forgetting it fails at startup with a message that names the class. That is the
 * failure worth having, and it is the one line a new service copies. See
 * docs/runbooks/adding-a-service.md.
 *
 * <h2>The first argument is the whole application package, not just {@code .domain}</h2>
 *
 * Because declaring an {@code @EntityScan} at all replaces the default, and the default was every
 * entity under {@code com.xenopsoftware.core} — including {@code repository.timezone.DateTimeWrapper},
 * which exists only in test sources. Narrowing to {@code .domain} while adding the shared packages
 * looked tidier and broke the Cucumber context with "Not a managed type" for a class nobody had
 * touched. Widen this list; never narrow it.
 */
@Configuration
@EntityScan({ "com.xenopsoftware.core", "com.xenopsoftware.common" })
@EnableJpaRepositories({ "com.xenopsoftware.core.repository", "com.xenopsoftware.common" })
@EnableJpaAuditing(auditorAwareRef = "springSecurityAuditorAware")
@EnableTransactionManagement
public class DatabaseConfiguration {}
