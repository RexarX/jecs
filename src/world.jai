World :: struct {
    entities: Entities;
}

// Not thread-safe.
clear :: inline (using world: *World) {
    clear(*entities);
}

// Not thread-safe.
reset :: inline (using world: *World) {
    reset(*entities);
}

// Not thread-safe.
reserve_entities_memory :: inline (using world: *World, count: s64) {
    reserve(*entities, count);
}

// Thread-safe.
reserve_entity :: inline (using world: *World) -> Entity {
    return reserve_entity(*entities);
}

// Not thread-safe.
create_entity :: inline (using world: *World) -> Entity {
    return create_entity(*entities);
}

// Not thread-safe.
destroy_entity :: inline (using world: *World, entity: Entity) {
    destroy_entity(*entities, entity);
}

// Thread-safe.
validate_entity :: inline (using world: *World, entity: Entity) -> bool #must {
    return validate_entity(*entities, entity);
}

// Not thread-safe.
flush_reserved_entities :: inline (using world: *World) {
    flush_reserved_entities(*entities);
}

// Thread-safe.
needs_flush :: inline (using world: *World) -> bool #must {
    return needs_flush(*entities);
}
