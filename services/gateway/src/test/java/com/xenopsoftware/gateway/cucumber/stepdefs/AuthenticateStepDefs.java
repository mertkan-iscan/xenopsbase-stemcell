package com.xenopsoftware.gateway.cucumber.stepdefs;

import io.cucumber.java.en.Then;
import io.cucumber.java.en.When;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.web.reactive.server.WebTestClient;

public class AuthenticateStepDefs extends StepDefs {

    @Autowired
    private WebTestClient webTestClient;

    @When("I get authenticate")
    public void i_get_authenticate() throws Throwable {
        actions = webTestClient.get().uri("/api/authenticate").exchange();
    }

    @Then("authenticate returns response with status No Content")
    public void authenticate_returns_response_with_status_no_content() throws Throwable {
        actions.expectStatus().isNoContent();
    }
}
