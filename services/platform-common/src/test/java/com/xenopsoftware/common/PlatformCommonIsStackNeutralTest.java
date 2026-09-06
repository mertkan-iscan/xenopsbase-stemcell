package com.xenopsoftware.common;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

/**
 * This module is what the gateway and every servlet service agree on, so it may not know which one
 * it is running inside (ADR-0017).
 *
 * <p>Paired with the {@code enforce-no-web-stack} enforcer rule in this module's pom, and neither
 * is redundant. The enforcer guards the CLASSPATH, which is what a deployment actually trips over.
 * This guards the SOURCE, which is what breaks first and reads clearly when it does: somebody
 * moves a filter down here because "every service has one", and finds out from a rule that says
 * why rather than from a compiler error about a missing symbol.
 *
 * <p>Both directions are worth having because they fail at different times, and only one of them
 * can fail during the change that caused it.
 */
@AnalyzeClasses(packages = "com.xenopsoftware.common", importOptions = ImportOption.DoNotIncludeTests.class)
class PlatformCommonIsStackNeutralTest {

    @ArchTest
    static final ArchRule nothingHereNamesAServletRequest = noClasses()
        .should()
        .dependOnClassesThat()
        .resideInAnyPackage("jakarta.servlet..", "org.springframework.web.servlet..")
        .because("the gateway depends on this module and has no servlet request to give it (ADR-0017)");

    /**
     * The mirror of the rule above. A reactive type here would be just as wrong and for the
     * symmetrical reason: it would make every servlet service carry Reactor in order to share a
     * constant.
     */
    @ArchTest
    static final ArchRule nothingHereNamesAReactiveExchange = noClasses()
        .should()
        .dependOnClassesThat()
        .resideInAnyPackage("org.springframework.web.reactive..", "reactor.core..")
        .because("this module is what both stacks share, so it may not be written in either one");

    /**
     * "Who is calling" is the question the two stacks answer differently — {@code
     * SecurityContextHolder} on a servlet, {@code ReactiveSecurityContextHolder} on the gateway.
     * Code down here that reads one of them works in every servlet process and silently returns
     * nothing in the gateway.
     *
     * <p>Narrower than banning {@code org.springframework.security..} wholesale, deliberately.
     * {@code AudienceValidator} is an {@code OAuth2TokenValidator<Jwt>} and belongs here precisely
     * because token validation is identical on both stacks; a blanket ban would have exiled it and
     * left the audience rule written twice, which is the duplication this module exists to remove.
     */
    @ArchTest
    static final ArchRule nothingHereReadsTheSecurityContext = noClasses()
        .should()
        .dependOnClassesThat()
        .haveFullyQualifiedName("org.springframework.security.core.context.SecurityContextHolder")
        .orShould()
        .dependOnClassesThat()
        .haveFullyQualifiedName("org.springframework.security.core.context.ReactiveSecurityContextHolder")
        .because("who is calling is a question each stack answers differently (ADR-0017)");
}
