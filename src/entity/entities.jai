#import "Atomics";
#import "Basic";

Entities :: struct {
    generations:  [..] Entity.Generation;
    free_indices: [..] Entity.Index;
    count:        Entity.Index = 0;

    next_index:   Entity.Index = 0;
    // When flushed: free_cursor == free_indices.count (remaining freelist).
    // reserve_entity decrements it: freelist first, then negative for brand-new IDs.
    free_cursor:  s64 = 0;

    allocator:    Allocator;
}

init :: inline (entities: *Entities, allocator: Allocator = .{}) {
    entities.allocator = resolve_allocator(entities, allocator);

    entities.generations.allocator  = entities.allocator;
    entities.free_indices.allocator = entities.allocator;
}

deinit :: inline (using entities: *Entities) {
    array_free(generations);
    array_free(free_indices);
}

reset :: (using entities: *Entities) {
    if generations.data && generations.allocated {
        memset(generations.data, 0, generations.allocated * size_of(Entity.Generation));
    }
    if free_indices.data && free_indices.allocated {
        memset(free_indices.data, 0, free_indices.allocated * size_of(Entity.Index));
    }
    array_reset_keeping_memory(*generations);
    array_reset_keeping_memory(*free_indices);
    count = 0;
    next_index = 0;
    free_cursor = 0;
}

clear :: (using entities: *Entities) {
    array_reset_keeping_memory(*generations);
    array_reset_keeping_memory(*free_indices);
    count = 0;
    next_index = 0;
    free_cursor = 0;
}

reserve :: (entities: *Entities, count: s64) {
    if count > entities.generations.count {
        old_count := entities.generations.count;
        array_resize(*entities.generations, count);
        for i: old_count..count - 1 {
            entities.generations[i] = Entity.INVALID_GENERATION;
        }
    }

    array_reserve(*entities.free_indices, count);
}

// Thread-safe for concurrent reserve_entity / validate_entity / needs_flush only.
//
// Contract: do NOT call flush_reserved_entities, create_entity, destroy_entity,
// reserve (memory growth), or create_entity_with_id while any thread may be inside
// reserve_entity / validate_entity. Those paths can array_resize generations and
// move generations.data, racing with atomic_read(generations.data + index).
// Typical usage: workers only reserve_entity; main thread joins, then flush.
reserve_entity :: (using entities: *Entities) -> Entity #must {
    // Atomically claim one slot: freelist first, then brand-new indices.
    // Do NOT mutate generations / count here — concurrent callers only touch
    // free_cursor. Metadata is materialized in flush_reserved_entities.
    n := atomic_add(*free_cursor, -1);
    if n > 0 {
        index := free_indices[n - 1];
        // Destroy publishes the free generation before the index hits the freelist;
        // reserve hands out the future alive generation.
        // Safe only while generations.data is stable (see contract above).
        free_generation := atomic_read(generations.data + cast(s64) index);
        generation := next_generation(free_generation);
        return .{index = index, generation = generation};
    }

    // free_cursor is 0 or negative: hand out a fresh index at/after next_index.
    // As the cursor goes more negative, indices extend farther.
    index := cast(Entity.Index) (cast(s64) atomic_read(*next_index) - n);
    return .{index = index, generation = Entity.FIRST_ALIVE_GENERATION};
}

create_entity :: (using entities: *Entities) -> Entity #must {
    assert(!needs_flush(entities),
           "flush_reserved_entities must be called before create_entity!");

    if free_cursor > 0 {
        index := pop_free_index(entities);
        free_generation := generations[cast(s64) index];
        alive_generation := next_generation(free_generation);
        return create_entity_with_id(entities, index, alive_generation);
    }

    index := next_index;
    next_index += 1;
    return create_entity_with_id(entities, index, Entity.FIRST_ALIVE_GENERATION);
}

destroy_entity :: (using entities: *Entities, entity: Entity) {
    assert(is_valid(entity), "Cannot destroy invalid entity %!", entity);
    assert(!needs_flush(entities),
           "flush_reserved_entities must be called before destroy_entity!");
    if !validate_entity(entities, entity) return;

    next_gen := next_generation(entity.generation, alive = false);
    generations[cast(s64) entity.index] = next_gen;
    array_add(*free_indices, entity.index);
    sync_free_cursor_to_list(entities);
    count -= 1;
}

// Thread-safe — same concurrency contract as reserve_entity.
validate_entity :: (using entities: *Entities, entity: Entity) -> bool #must {
    if !is_valid(entity) return false;
    if entity.index >= cast(Entity.Index) generations.count return false;

    generation := atomic_read(generations.data + cast(s64) entity.index);
    if generation != entity.generation return false;
    if !is_alive_generation(generation) return false;
    return true;
}

// Not thread-safe w.r.t. reserve_entity — see reserve_entity contract.
flush_reserved_entities :: (using entities: *Entities) {
    current_free_cursor := free_cursor;
    new_free_cursor: s64;
    new_entities_count: Entity.Index = 0;

    if current_free_cursor >= 0 {
        new_free_cursor = current_free_cursor;
    } else {
        // Negative free_cursor: allocate brand-new indices beyond next_index.
        old_next := next_index;
        freshly_reserved := cast(Entity.Index) (-current_free_cursor);
        new_next := old_next + freshly_reserved;

        if cast(s64) new_next > generations.count {
            array_resize(*generations, cast(s64) new_next);
        }

        for i: cast(s64) old_next..cast(s64) new_next - 1 {
            generations[i] = Entity.FIRST_ALIVE_GENERATION;
        }

        new_entities_count += freshly_reserved;
        next_index = new_next;
        new_free_cursor = 0;
    }

    // Reserved freelist entries live in free_indices[new_free_cursor .. end).
    // Their generations were already bumped in destroy_entity.
    assert(new_free_cursor <= free_indices.count,
           "free_cursor is out of sync with free list!");
    recycled_reserved := free_indices.count - new_free_cursor;
    new_entities_count += cast(Entity.Index) recycled_reserved;

    for i: new_free_cursor..free_indices.count - 1 {
        index := free_indices[i];
        free_generation := generations[cast(s64) index];
        generations[cast(s64) index] = next_generation(free_generation);
    }

    free_indices.count = new_free_cursor;
    free_cursor = new_free_cursor;
    count += new_entities_count;
}

// Thread-safe.
needs_flush :: inline (using entities: *Entities) -> bool #must {
    return atomic_read(*free_cursor) != free_indices.count;
}

Reserved_Entities :: struct {
    entities: *Entities;
}

get_reserved_entities :: inline (entities: *Entities) -> Reserved_Entities #must {
    return .{entities = entities};
}

for_expansion :: (reserved: Reserved_Entities, body: Code,
                  flags: For_Flags) #expand {
    entities := reserved.entities;

    `it: Entity;
    `it_index: Entity.Index;

    cursor := entities.free_cursor;

    // Freelist-reserved pending slots: free_indices[max(cursor, 0) .. count).
    freelist_start := ifx cursor >= 0 then cursor else 0;
    if freelist_start < entities.free_indices.count {
        for i: freelist_start..entities.free_indices.count - 1 {
            index := entities.free_indices[i];
            it_index = index;
            free_generation := entities.generations[cast(s64) index];
            it = .{index = index,
                   generation = next_generation(free_generation)};
            #insert body;
        }
    }

    // Brand-new reserved indices: [next_index, next_index + (-cursor)).
    if cursor >= 0 return;

    old_next := cast(s64) entities.next_index;
    for i: 0..(-cursor) - 1 {
        index := cast(Entity.Index) (old_next + i);
        it_index = index;
        it = .{index = index, generation = Entity.FIRST_ALIVE_GENERATION};
        #insert body;
    }
}

#scope_module;

sync_free_cursor_to_list :: inline (using entities: *Entities) {
    free_cursor = free_indices.count;
}

pop_free_index :: inline (using entities: *Entities) -> Entity.Index {
    free_cursor -= 1;
    index := free_indices[free_cursor];
    free_indices.count = free_cursor;
    return index;
}

create_entity_with_id :: (using entities: *Entities, index: Entity.Index,
                          generation: Entity.Generation) -> Entity #must {
    while generations.count <= cast(s64) index {
        array_add(*generations, Entity.INVALID_GENERATION);
    }

    generations[cast(s64) index] = generation;
    count += 1;
    return .{index = index, generation = generation};
}
