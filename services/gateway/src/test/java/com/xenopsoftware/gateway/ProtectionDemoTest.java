package com.xenopsoftware.gateway;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

/**
 * Throwaway. Exists only to make the `gateway` job red on a branch, so T-0.7 can show that branch
 * protection refuses the merge rather than assuming it would. Deleted with the branch.
 */
class ProtectionDemoTest {

    @Test
    void deliberatelyFails() {
        assertThat(1).isEqualTo(2);
    }
}
