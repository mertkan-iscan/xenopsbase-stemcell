package com.xenopsoftware.core;

import static com.tngtech.archunit.base.DescribedPredicate.alwaysTrue;
import static com.tngtech.archunit.core.domain.JavaClass.Predicates.belongToAnyOf;
import static com.tngtech.archunit.library.Architectures.layeredArchitecture;

import com.tngtech.archunit.core.importer.ImportOption.DoNotIncludeTests;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

@AnalyzeClasses(packagesOf = CoreApp.class, importOptions = DoNotIncludeTests.class)
class TechnicalStructureTest {

    // prettier-ignore
    @ArchTest
    static final ArchRule respectsTechnicalArchitectureLayers = layeredArchitecture()
        .consideringAllDependencies()
        .layer("Config").definedBy("..config..")
        .layer("Web").definedBy("..web..")
        .optionalLayer("Service").definedBy("..service..")
        // OPTIONAL since the shared-module split (ADR-0017): this service no longer has a
        // security package of its own. SecurityUtils, AuthoritiesConstants and the audience
        // validator moved to platform-common / platform-common-web, and a required layer with no
        // members here fails with "Layer 'Security' is empty" -- which says nothing about the
        // architecture and everything about where the classes now live. The RULES below still
        // apply, and still apply to the shared classes: `..security..` matches their packages
        // too, and consideringAllDependencies() means a call from core into them is checked.
        .optionalLayer("Security").definedBy("..security..")
        .optionalLayer("Persistence").definedBy("..repository..")
        .layer("Domain").definedBy("..domain..")

        .whereLayer("Config").mayNotBeAccessedByAnyLayer()
        .whereLayer("Web").mayOnlyBeAccessedByLayers("Config")
        .whereLayer("Service").mayOnlyBeAccessedByLayers("Web", "Config")
        .whereLayer("Security").mayOnlyBeAccessedByLayers("Config", "Service", "Web")
        .whereLayer("Persistence").mayOnlyBeAccessedByLayers("Service", "Security", "Web", "Config")
        .whereLayer("Domain").mayOnlyBeAccessedByLayers("Persistence", "Service", "Security", "Web", "Config")

        .ignoreDependency(belongToAnyOf(CoreApp.class), alwaysTrue())
        // Types in `config` that every layer is allowed to reference. The rule says the Config
        // layer may not be accessed by any layer, which is right for configuration CLASSES --
        // a service reaching into a @Configuration is the coupling worth preventing. These three
        // are not that: two are settings holders and one is an annotation, and referencing an
        // annotation is not a dependency on the layer that declares it.
        .ignoreDependency(alwaysTrue(), belongToAnyOf(
            com.xenopsoftware.common.config.Constants.class,
            com.xenopsoftware.core.config.ApplicationProperties.class,
            com.xenopsoftware.common.storage.ConditionalOnObjectStore.class
        ));
}
