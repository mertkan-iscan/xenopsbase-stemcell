package com.xenopsoftware.gateway.cucumber;

import com.xenopsoftware.common.security.AuthoritiesConstants;
import com.xenopsoftware.gateway.IntegrationTest;
import io.cucumber.spring.CucumberContextConfiguration;
import org.springframework.boot.webtestclient.autoconfigure.AutoConfigureWebTestClient;
import org.springframework.security.test.context.support.WithMockUser;

@CucumberContextConfiguration
@IntegrationTest
@AutoConfigureWebTestClient(timeout = IntegrationTest.DEFAULT_TIMEOUT)
@WithMockUser(authorities = AuthoritiesConstants.ADMIN)
public class CucumberTestContextConfiguration {}
