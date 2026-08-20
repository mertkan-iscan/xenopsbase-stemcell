package com.xenopsoftware.core.repository;

import com.xenopsoftware.core.domain.ExampleItem;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

/** DELETE THIS along with {@link ExampleItem}. */
@Repository
public interface ExampleItemRepository extends JpaRepository<ExampleItem, Long> {}
