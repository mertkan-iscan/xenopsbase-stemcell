package com.xenopsoftware.gateway;

import com.xenopsoftware.gateway.config.AsyncSyncConfiguration;
import com.xenopsoftware.gateway.config.EmbeddedSQL;
import com.xenopsoftware.gateway.config.JacksonConfiguration;
import com.xenopsoftware.gateway.config.TestSecurityConfiguration;
import com.xenopsoftware.gateway.config.ValkeyTestcontainer;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;
import org.springframework.boot.test.context.SpringBootTest;

/**
 * Base composite annotation for integration tests.
 */
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@SpringBootTest(classes = { GatewayApp.class, JacksonConfiguration.class, AsyncSyncConfiguration.class, TestSecurityConfiguration.class })
@EmbeddedSQL
// Every integration test gets a real Valkey. Not optional: Boot 4 chooses the
// session store by classpath, so with spring-session-data-redis present there is
// no in-memory fallback to fall back to (T-2.11).
@ImportTestcontainers(ValkeyTestcontainer.class)
public @interface IntegrationTest {
    // 5s is Spring's default https://github.com/spring-projects/spring-framework/blob/main/spring-test/src/main/java/org/springframework/test/web/reactive/server/DefaultWebTestClient.java#L106
    String DEFAULT_TIMEOUT = "PT5S";
    String DEFAULT_ENTITY_TIMEOUT = "PT5S";
}
