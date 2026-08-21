package com.xenopsoftware.core.config;

import io.swagger.v3.oas.annotations.Hidden;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Hidden from the OpenAPI document.
 *
 * <p>This controller exists only in the test source set, but the spec is captured from a running
 * test context (see OpenApiSpecIT) -- so without this it appears in the published contract, and a
 * generated client gets typed methods for endpoints that do not exist in any deployment.
 *
 * <p>{@code @Hidden} rather than a path exclusion in springdoc configuration: the production config
 * should not have to know the names of test fixtures, and a list of excluded paths is one more
 * thing to keep in step with the tests.
 */
@Hidden
@RestController
public class WebConfigurerTestController {

    @GetMapping("/api/test-cors")
    public void testCorsOnApiPath() {
        // empty method
    }

    @GetMapping("/test/test-cors")
    public void testCorsOnOtherPath() {
        // empty method
    }
}
