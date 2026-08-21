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

        // The same story one layer up, and the frame that actually parks.
        //
        // ReactiveRedisSessionRepository.saveDelta writes through
        // ReactiveRedisTemplate.doInConnection, which blocks while Lettuce
        // establishes the connection. Lettuce connects LAZILY, so this lands on
        // whichever request first writes a session -- during the response commit,
        // which is why it surfaced as a 500 from the logout endpoint and an error
        // from a redirect rather than as anything mentioning Redis.
        //
        // The real fix is eager initialisation, so the connection is built at
        // startup instead of inside a request. LettuceConnectionFactory supports
        // it and Spring Boot exposes no property for it, so it needs a bean here
        // rather than a line of YAML. Worth doing if this ever shows up as
        // first-request latency in production; until then this entry keeps the
        // detector honest about what it is permitting.
        builder.allowBlockingCallsInside("org.springframework.data.redis.core.ReactiveRedisTemplate", "doInConnection");
    }
}
