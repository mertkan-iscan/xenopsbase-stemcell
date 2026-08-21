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

        // NOTHING is allowlisted for Valkey, deliberately.
        //
        // Two entries were tried here first -- Netty's DNS resolver and
        // ReactiveRedisTemplate.doInConnection -- to permit the block Lettuce
        // performs while connecting lazily inside a request. That is the wrong
        // shape: BlockHound runs only in tests, so an allowlist entry turns the
        // test green and leaves the same event-loop stall in production, where
        // nothing is watching for it.
        //
        // RedisEagerConnectionConfiguration moves the connection to startup
        // instead, so there is no blocking call on the request path to permit.
    }
}
