#import "Atomics";
#import "Basic";

Entities :: struct {
    generations: [..] Entity.Generation;
    free_indices: [..] Entity.Index;
    count: Entity.Index = 0;

    next_index: Entity.Index = 0;
    // Freelist size when flushed (free_cursor == free_indices.count).
    // reserve_entity may lower it (pending freelist reserves) without going negative.
    free_cursor: s64 = 0;
}

// Not thread-safe.
clear :: (using entities: *Entities) {
    array_reset_keeping_memory(*generations);
    array_reset_keeping_memory(*free_indices);
    count = 0;
    next_index = 0;
    free_cursor = 0;
}

// Not thread-safe.
reset :: (using entities: *Entities) {
    array_reset(*generations);
    array_reset(*free_indices);
    count = 0;
    next_index = 0;
    free_cursor = 0;
}

// Not thread-safe.
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

// Thread-safe.
reserve_entity :: (using entities: *Entities) -> Entity {
    // Lock-free freelist claim. free_cursor stays >= 0 so next_index allocation
    // can be used for brand-new IDs without negative-cursor bookkeeping.
    while true {
        cursor := atomic_read(*free_cursor);
        if cursor <= 0 break;

        success, _ := compare_and_swap(*free_cursor, cursor, cursor - 1);
        if !success continue;

        index := free_indices[cursor - 1];
        // Destroy publishes the next generation before the index hits the
        // freelist; reading it here is wait-free and does not mutate metadata.
        generation := atomic_read(generations.data + index);
        return .{index = index, generation = generation};
    }

    index := atomic_add(*next_index, 1);
    return .{index = index, generation = 1};
}

// Not thread-safe.
create_entity_with_id :: (using entities: *Entities, index: Entity.Index, generation: Entity.Generation) -> Entity {
    while generations.count <= index {
        array_add(*generations, Entity.INVALID_GENERATION);
    }

    generations[index] = generation;
    count += 1;
    return .{index = index, generation = generation};
}

// Not thread-safe.
create_entity :: (using entities: *Entities) -> Entity {
    assert(!needs_flush(entities), "flush_reserved_entities must be called before create_entity");

    if free_cursor > 0 {
        free_cursor -= 1;
        index := free_indices[free_cursor];
        return create_entity_with_id(entities, index, generations[index]);
    }

    index := next_index;
    next_index += 1;
    return create_entity_with_id(entities, index, 1);
}

// Not thread-safe.
destroy_entity :: (using entities: *Entities, entity: Entity) {
    assert(is_valid(entity), "Cannot destroy an invalid entity!");
    assert(!needs_flush(entities), "flush_reserved_entities must be called before destroy_entity");
    if !validate_entity(entities, entity) return;

    generations[entity.index] += 1;
    array_add(*free_indices, entity.index);
    free_cursor = free_indices.count;
    count -= 1;
}

// Thread-safe.
validate_entity :: (using entities: *Entities, entity: Entity) -> bool #must {
    if !is_valid(entity) return false;
    if entity.index >= generations.count return false;

    generation := atomic_read(generations.data + entity.index);
    if generation != entity.generation return false;
    if generation == Entity.INVALID_GENERATION return false;
    return true;
}

// Not thread-safe.
flush_reserved_entities :: (using entities: *Entities) {
    // Freelist-reserved: generations already hold the correct value; just
    // drop them from pending and account for living entities.
    if free_cursor >= 0 && free_cursor < free_indices.count {
        reserved_from_freelist := free_indices.count - free_cursor;
        count += cast(Entity.Index) reserved_from_freelist;
        free_indices.count = free_cursor;
    }

    // Brand-new reserved indices: [0, next_index) still marked INVALID.
    if next_index > 0 {
        while generations.count < next_index {
            array_add(*generations, Entity.INVALID_GENERATION);
        }

        new_entities: Entity.Index = 0;
        for i: 0..cast(s64) next_index - 1 {
            if generations[i] == Entity.INVALID_GENERATION {
                generations[i] = 1;
                new_entities += 1;
            }
        }
        count += new_entities;
    }

    free_cursor = free_indices.count;
}

// Thread-safe.
needs_flush :: (using entities: *Entities) -> bool #must {
    cursor := atomic_read(*free_cursor);
    if cursor != free_indices.count return true;

    next := atomic_read(*next_index);
    if next > cast(Entity.Index) generations.count return true;
    if next == 0 return false;

    // Use s64 so next == 0 cannot underflow a u32 range to 0..max.
    for i: 0..cast(s64) next - 1 {
        if generations[i] == Entity.INVALID_GENERATION return true;
    }
    return false;
}

Reserved_Entities :: struct {
    entities: *Entities;
}

get_reserved_entities :: (entities: *Entities) -> Reserved_Entities #must {
    return .{entities = entities};
}

// Not thread-safe.
for_expansion :: (reserved: Reserved_Entities, body: Code, flags: For_Flags) #expand {
    entities := reserved.entities;

    `it: Entity;
    `it_index: Entity.Index;

    // Freelist-reserved pending slots.
    cursor := entities.free_cursor;
    if cursor >= 0 && cursor < entities.free_indices.count {
        for i: cursor..entities.free_indices.count - 1 {
            index := entities.free_indices[i];
            it_index = index;
            it = .{index = index, generation = entities.generations[index]};
            #insert body;
        }
    }

    // Brand-new reserved indices not yet in generations / still INVALID.
    if entities.next_index == 0 return;

    for i: 0..cast(s64) entities.next_index - 1 {
        index := cast(Entity.Index) i;
        if index < entities.generations.count {
            if entities.generations[index] != Entity.INVALID_GENERATION continue;
        }

        it_index = index;
        it = .{index = index, generation = 1};
        #insert body;
    }
}
