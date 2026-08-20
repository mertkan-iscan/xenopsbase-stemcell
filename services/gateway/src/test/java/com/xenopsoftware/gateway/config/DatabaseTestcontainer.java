package com.xenopsoftware.gateway.config;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.DisposableBean;
import org.springframework.beans.factory.InitializingBean;
import org.testcontainers.containers.JdbcDatabaseContainer;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.containers.output.Slf4jLogConsumer;

public class DatabaseTestcontainer implements SqlTestContainer, InitializingBean, DisposableBean {

    private static final Logger LOG = LoggerFactory.getLogger(DatabaseTestcontainer.class);

    private PostgreSQLContainer<?> databaseContainer;

    @Override
    public void destroy() {
        if (null != databaseContainer && databaseContainer.isRunning()) {
            databaseContainer.stop();
        }
    }

    @Override
    public void afterPropertiesSet() {
        if (null == databaseContainer) {
            databaseContainer = (PostgreSQLContainer) new PostgreSQLContainer<>("postgres:18.4")
                .withDatabaseName("gateway")

                .withLogConsumer(new Slf4jLogConsumer(LOG))
                .withReuse(true);
        }
        if (!databaseContainer.isRunning()) {
            databaseContainer.start();
        }
    }

    @Override
    public JdbcDatabaseContainer<?> getTestContainer() {
        return databaseContainer;
    }
}
