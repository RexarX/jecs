#import "Atomics";
#import "Basic";

Entities :: struct {
    generations: [..] Entity.Generation;
    free_indices: [..] Entity.Index;
    count: Entity.Index = 0;

    next_index: Entity.Index = 0;
    // When flushed: free_cursor == free_indices.count (remaining freelist).
    // reserve_entity decrements it: freelist first, then negative for brand-new IDs.
    free_cursor: s64 = 0;

    allocator: Allocator;
}

init :: (entities: *Entities, allocator: Allocator = .{}) {
    entities.allocator = resolve_allocator(entities, allocator);

    entities.generations.allocator  = entities.allocator;
    entities.free_indices.allocator = entities.allocator;
}

clear :: (using entities: *Entities) {
    array_reset_keeping_memory(*generations);
    array_reset_keeping_memory(*free_indices);
    count = 0;
    next_index = 0;
    free_cursor = 0;
}

reset :: (using entities: *Entities) {
    array_reset(*generations);
    array_reset(*free_indices);
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
reserve_entity :: (using entities: *Entities) -> Entity {
    // Atomically claim one slot: freelist first, then brand-new indices.
    // Do NOT mutate generations / count here — concurrent callers only touch
    // free_cursor. Metadata is materialized in flush_reserved_entities.
    n := atomic_add(*free_cursor, -1);
    if n > 0 {
        index := free_indices[n - 1];
        // Destroy publishes the next generation before the index hits the
        // freelist; reading it here is wait-free and does not mutate metadata.
        // Safe only while generations.data is stable (see contract above).
        generation := atomic_read(generations.data + cast(s64) index);
        return .{index = index, generation = generation};
    }

    // free_cursor is 0 or negative: hand out a fresh index at/after next_index.
    // As the cursor goes more negative, indices extend farther.
    index := cast(Entity.Index) (cast(s64) atomic_read(*next_index) - n);
    return .{index = index, generation = 1};
}

create_entity :: (using entities: *Entities) -> Entity {
    assert(!needs_flush(entities), "flush_reserved_entities must be called before create_entity");

    if free_cursor > 0 {
        index := pop_free_index(entities);
        return create_entity_with_id(entities, index, generations[cast(s64) index]);
    }

    index := next_index;
    next_index += 1;
    return create_entity_with_id(entities, index, 1);
}

destroy_entity :: (using entities: *Entities, entity: Entity) {
    assert(is_valid(entity), "Cannot destroy invalid entity %!", entity);
    assert(!needs_flush(entities), "flush_reserved_entities must be called before destroy_entity");
    if !validate_entity(entities, entity) return;

    generations[cast(s64) entity.index] += 1;
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
    if generation == Entity.INVALID_GENERATION return false;
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
            generations[i] = 1;
        }

        new_entities_count += freshly_reserved;
        next_index = new_next;
        new_free_cursor = 0;
    }

    // Reserved freelist entries live in free_indices[new_free_cursor .. end).
    // Their generations were already bumped in destroy_entity.
    assert(new_free_cursor <= free_indices.count, "free_cursor is out of sync with free list!");
    recycled_reserved := free_indices.count - new_free_cursor;
    new_entities_count += cast(Entity.Index) recycled_reserved;

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

for_expansion :: (reserved: Reserved_Entities, body: Code, flags: For_Flags) #expand {
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
            it = .{index = index, generation = entities.generations[cast(s64) index]};
            #insert body;
        }
    }

    // Brand-new reserved indices: [next_index, next_index + (-cursor)).
    if cursor >= 0 return;

    old_next := cast(s64) entities.next_index;
    for i: 0..(-cursor) - 1 {
        index := cast(Entity.Index) (old_next + i);
        it_index = index;
        it = .{index = index, generation = 1};
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

create_entity_with_id :: (using entities: *Entities, index: Entity.Index, generation: Entity.Generation) -> Entity {
    while generations.count <= cast(s64) index {
        array_add(*generations, Entity.INVALID_GENERATION);
    }

    generations[cast(s64) index] = generation;
    count += 1;
    return .{index = index, generation = generation};
}
