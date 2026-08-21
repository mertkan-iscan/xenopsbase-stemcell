package com.xenopsoftware.gateway.config;

import reactor.blockhound.BlockHound;
import reactor.blockhound.integration.BlockHoundIntegration;

public class JHipsterBlockHoundIntegration implements BlockHoundIntegration {

    @Override
    public void applyTo(BlockHound.Builder builder) {
        builder.allowBlockingCallsInside("java.util.UUID", "randomUUID");
        builder.allowBlockingCallsInside("org.springframework.validation.beanvalidation.SpringValidatorAdapter", "validate");
        builder.allowBlockingCallsInside("com.xenopsoftware.gateway.service.MailService", "sendEmailFromTemplate");
        builder.allowBlockingCallsInside("com.xenopsoftware.gateway.security.DomainUserDetailsService", "createSpringSecurityUser");
        builder.allowBlockingCallsInside("org.springframework.web.reactive.result.method.InvocableHandlerMethod", "invoke");
        builder.allowBlockingCallsInside("org.springdoc.core.service.OpenAPIService", "build");
        builder.allowBlockingCallsInside("org.springdoc.core.service.OpenAPIService", "getWebhooksClasses");
        builder.allowBlockingCallsInside("org.springdoc.core.service.AbstractRequestService", "build");

        // Netty's DNS resolver, reached when Lettuce opens its first connection to
        // Valkey (T-2.11).
        //
        // The blocking part is a lock inside Netty's own query-id bookkeeping
        // (DnsQueryIdSpace.pushId parks), not I/O. It happens during CONNECTION
        // ESTABLISHMENT, which is lazy and therefore lands on whichever request
        // touches a session first; afterwards the connection is pooled and this is
        // not on the path again.
        //
        // Allowed rather than avoided. The alternative was to hand the tests an IP
        // instead of a hostname, which would have removed the symptom from CI while
        // leaving it in production -- where the host genuinely is a DNS name
        // (valkey.cache.svc.cluster.local) and BlockHound is not running to notice.
        // An allowlist entry that says so is more honest than a green test that
        // proves less than it appears to.
        builder.allowBlockingCallsInside("io.netty.resolver.dns.DnsNameResolver", "doResolveAllNow");
    }
}
