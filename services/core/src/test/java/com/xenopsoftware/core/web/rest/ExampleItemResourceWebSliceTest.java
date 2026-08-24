package com.xenopsoftware.core.web.rest;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.xenopsoftware.core.domain.ExampleItem;
import com.xenopsoftware.core.repository.ExampleItemRepository;
import com.xenopsoftware.core.repository.IdempotencyRecordRepository;
import java.util.List;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

/**
 * The WEB slice: this controller's HTTP behaviour with nothing behind it (T-5.2).
 *
 * <p>Before T-5.2 this project had no slice layer at all — no {@code @WebMvcTest},
 * {@code @WebFluxTest}, {@code @DataJpaTest} or {@code @JsonTest} anywhere in either service. Every
 * test was either a plain unit test or a full-context integration test with containers, so anything
 * needing a Spring context paid for the whole one. That is most of the reason core's unit-only
 * coverage was 10.6%.
 *
 * <p><b>Security filters are off here deliberately.</b> This asserts serialization, status codes and
 * binding — what the web layer does. Whether the endpoint is reachable by a given caller is a
 * different question with a different answer, and it has its own slice in
 * {@link SecurityRulesSliceTest}. Mixing them produces a test that fails for two unrelated reasons
 * and tells you neither.
 */
@WebMvcTest(controllers = ExampleItemResource.class)
@AutoConfigureMockMvc(addFilters = false)
class ExampleItemResourceWebSliceTest {

    @Autowired
    private MockMvc mvc;

    @MockitoBean
    private ExampleItemRepository repository;

    // @WebMvcTest includes Filter beans, and IdempotencyFilter (T-3.8) needs its repository. Not
    // part of what this slice asserts -- it is here so the slice can start at all.
    @MockitoBean
    private IdempotencyRecordRepository idempotencyRecordRepository;

    private static ExampleItem item(long id, String name) {
        ExampleItem e = new ExampleItem();
        e.setId(id);
        e.setName(name);
        return e;
    }

    @Test
    @DisplayName("the list endpoint serialises what the repository returns")
    void listReturnsRepositoryContents() throws Exception {
        when(repository.findAll()).thenReturn(List.of(item(1L, "first"), item(2L, "second")));

        mvc.perform(get("/api/example-items"))
            .andExpect(status().isOk())
            .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
            .andExpect(jsonPath("$", org.hamcrest.Matchers.hasSize(2)))
            .andExpect(jsonPath("$[0].name").value("first"))
            .andExpect(jsonPath("$[1].name").value("second"));
    }

    @Test
    @DisplayName("an empty repository is an empty array, not a 404 and not a null body")
    void emptyListIsAnEmptyArray() throws Exception {
        when(repository.findAll()).thenReturn(List.of());

        mvc.perform(get("/api/example-items")).andExpect(status().isOk()).andExpect(content().json("[]"));
    }

    @Test
    @DisplayName("the admin listing is the same shape, so only authorization separates them")
    void adminListingHasTheSameShape() throws Exception {
        when(repository.findAll()).thenReturn(List.of(item(1L, "first")));

        mvc.perform(get("/api/admin/example-items")).andExpect(status().isOk()).andExpect(jsonPath("$[0].name").value("first"));
    }

    @Test
    @DisplayName("a rejected body is a 4xx, not a 500 — validation belongs to the web layer")
    void invalidBodyIsAClientError() throws Exception {
        when(repository.save(any())).thenReturn(item(1L, "x"));

        mvc.perform(
            org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/example-items")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"name\":\"\"}")
        ).andExpect(status().is4xxClientError());
    }
}
