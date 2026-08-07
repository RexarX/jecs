for_expansion :: (using query: *Query, body: Code, flags: For_Flags) #expand {
    #assert !(flags & .REVERSE) "Query iteration does not support #reverse!";

    assert(entities != null, "Query.entities must not be null!");
    assert(components != null, "Query.components must not be null!");

    active := acquire_snapshot(*plan, components);
    defer release_snapshot(active);
    driver := pick_driver(*plan, active);

    pointers: [..] *void;
    pointers.allocator = temp;
    array_resize(*pointers, plan.fetches.count);

    columns: [..] *Column;
    columns.allocator = temp;
    array_resize(*columns, plan.fetches.count);

    `it: Query_Row;
    it.pointers = pointers;
    it.fetches = plan.fetches;
    `it_index: Entity;

    has_sparse_filters := plan.has_sparse_filters;
    needs_arch_match := plan.needs_arch_match;

    if driver.use_sparse_driver {
        driver_set := active.sparse_sets[driver.driver_sparse_slot];
        if driver_set {
            dense := get_dense_entities(driver_set);
            for dense_i: 0..dense.count - 1 {
                matched, alive := try_get_entity(entities, dense[dense_i]);
                if !alive continue;
                if has_sparse_filters {
                    if !matches_sparse(*plan, active, matched.index,
                                       skip_slot = driver.driver_sparse_slot) {
                        continue;
                    }
                }

                matched_row: Row_Index = INVALID_ROW;
                arch: *Archetype = null;
                match_slot: s32 = -1;

                if needs_arch_match {
                    arch_index, tracked := try_get_archetype_index(components,
                                                                   matched);
                    if !tracked continue;
                    match_slot = arch_match_slot(active, arch_index);
                    if match_slot < 0 continue;
                    arch = get_archetype(components, arch_index);
                    matched_row = cast(Row_Index) get(*arch.entity_to_row,
                                                      matched.index);
                    bind_matched_columns(*plan, active, arch,
                                         cast(s64) match_slot, columns);
                } else {
                    for i: 0..columns.count - 1 columns[i] = null;
                }

                fill_pointers(*plan, active, columns, it.pointers,
                              matched.index, matched_row);
                it_index = matched;

                #insert (break = break dense_i, remove = #assert(false, "remove is not supported on Query iteration!")) body;
            }
        }
    } else {
        for match_i: 0..matched_arch_count(active) - 1 {
            arch_index := matched_arch_at(active, match_i);
            arch := get_archetype(components, arch_index);
            bind_matched_columns(*plan, active, arch, match_i, columns);

            for matched_i: 0..arch.entities.count - 1 {
                matched := arch.entities[matched_i];
                if has_sparse_filters {
                    if !matches_sparse(*plan, active, matched.index,
                                       skip_slot = -1) {
                        continue;
                    }
                }

                fill_pointers(*plan, active, columns, it.pointers, matched.index,
                              cast(Row_Index) matched_i);
                it_index = matched;

                #insert (break = break match_i, remove = #assert(false, "remove is not supported on Query iteration!")) body;
            }
        }
    }
}

for_expansion :: (using query: *Query_Entities,
                  body: Code, flags: For_Flags) #expand {
    #assert !(flags & .REVERSE) "Query_Entities iteration does not support #reverse!";

    assert(entities != null, "Query_Entities.entities must not be null!");
    assert(components != null, "Query_Entities.components must not be null!");

    active := acquire_snapshot(*plan, components);
    defer release_snapshot(active);
    driver := pick_driver(*plan, active);

    `it: Entity;
    `it_index: Entity.Index;

    has_sparse_filters := plan.has_sparse_filters;
    needs_arch_match := plan.needs_arch_match;

    if driver.use_sparse_driver {
        driver_set := active.sparse_sets[driver.driver_sparse_slot];
        if driver_set {
            dense := get_dense_entities(driver_set);
            for dense_i: 0..dense.count - 1 {
                matched, alive := try_get_entity(entities, dense[dense_i]);
                if !alive continue;
                if has_sparse_filters {
                    if !matches_sparse(*plan, active, matched.index,
                                       skip_slot = driver.driver_sparse_slot) {
                        continue;
                    }
                }

                if needs_arch_match {
                    arch_index, tracked := try_get_archetype_index(components,
                                                                   matched);
                    if !tracked continue;
                    if arch_match_slot(active, arch_index) < 0 continue;
                }

                it = matched;
                it_index = matched.index;

                #insert (break = break dense_i, remove = #assert(false, "remove is not supported on Query_Entities iteration!")) body;
            }
        }
    } else {
        for match_i: 0..matched_arch_count(active) - 1 {
            arch_index := matched_arch_at(active, match_i);
            arch := get_archetype(components, arch_index);

            for matched_i: 0..arch.entities.count - 1 {
                matched := arch.entities[matched_i];
                if has_sparse_filters {
                    if !matches_sparse(*plan, active, matched.index,
                                       skip_slot = -1) {
                        continue;
                    }
                }

                it = matched;
                it_index = matched.index;

                #insert (break = break match_i, remove = #assert(false, "remove is not supported on Query_Entities iteration!")) body;
            }
        }
    }
}
