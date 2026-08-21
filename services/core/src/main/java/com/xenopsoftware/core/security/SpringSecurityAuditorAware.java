package com.xenopsoftware.core.security;

import com.xenopsoftware.core.config.Constants;
import java.util.Optional;
import org.springframework.data.domain.AuditorAware;
import org.springframework.stereotype.Component;

/**
 * Supplies the value written into {@code created_by} and {@code last_modified_by}.
 *
 * <h2>The OIDC {@code sub}, not the username</h2>
 *
 * The generated version of this class returned {@code preferred_username}. That is mutable in
 * Keycloak, and an audit column holding a mutable value is not an audit column: rename a user and
 * every row they touched is attributed to a name that no longer exists — or, if the name is reused,
 * to a different person entirely. Neither failure produces an error, and neither is detectable
 * afterwards from the data.
 *
 * <p>{@code sub} never changes for the life of an account, so attribution survives any profile
 * edit. It is unreadable to a human, which is a real cost and is paid deliberately: {@code
 * audit_log.actor_name} carries a point-in-time snapshot of the display name for people to read,
 * and that snapshot is correct precisely because it makes no claim to still be current.
 *
 * <p>See {@code docs/runbooks/extension-seams.md}.
 */
@Component
public class SpringSecurityAuditorAware implements AuditorAware<String> {

    @Override
    public Optional<String> getCurrentAuditor() {
        // SYSTEM covers writes with no authenticated principal: migrations, scheduled jobs, and
        // the relay. Seeing it on a row created by a request means the security context did not
        // reach the write, which is worth noticing rather than papering over with a blank.
        return Optional.of(SecurityUtils.getCurrentUserId().orElse(Constants.SYSTEM));
    }
}
