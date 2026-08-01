World :: struct {
    entities: Entities;
    components: Components;
    allocator: Allocator;
}

init :: (world: *World, allocator: Allocator = .{}) {
    world.allocator = resolve_allocator(world, allocator);

    init(*world.entities, world.allocator);
    init(*world.components, world.allocator);
}

reset :: inline (using world: *World) {
    reset(*components);
    reset(*entities);
}

clear :: inline (using world: *World) {
    clear(*components);
    clear(*entities);
}

reserve_entities_memory :: inline (using world: *World, count: s64) {
    reserve(*entities, count);
}

// Thread-safe — same concurrency contract as Entities.reserve_entity.
reserve_entity :: inline (using world: *World) -> Entity {
    return reserve_entity(*entities);
}

create_entity :: inline (using world: *World) -> Entity {
    entity := create_entity(*entities);
    init_entity(*components, entity);
    return entity;
}

destroy_entity :: inline (using world: *World, entity: Entity) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    if validate_entity(*entities, entity) {
        remove_entity(*components, entity);
    }
    destroy_entity(*entities, entity);
}

// Thread-safe — same concurrency contract as Entities.validate_entity.
validate_entity :: inline (using world: *World, entity: Entity) -> bool #must {
    return validate_entity(*entities, entity);
}

// Thread-safe.
entity_exists :: inline (using world: *World, entity: Entity) -> bool #must {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    return validate_entity(*entities, entity);
}

flush_reserved_entities :: (using world: *World) {
    flush_reserved_entities(*entities);

    reserved := get_reserved_entities(*entities);
    for entity, index: reserved {
        if !is_tracked_entity(*components, entity) {
            init_entity(*components, entity);
        }
    }
}

// Thread-safe.
needs_flush :: inline (using world: *World) -> bool #must {
    return needs_flush(*entities);
}

assert_entity_in_world :: inline (using world: *World, entity: Entity) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(validate_entity(*entities, entity), "Entity % must exist in the world!", entity);
}

// Components API passthrough.

add_component :: inline (using world: *World, entity: Entity, $T: Type, value: T) {
    assert_entity_in_world(world, entity);
    add(*components, entity, T, value);
}

try_add_component :: inline (using world: *World, entity: Entity, $T: Type, value: T) -> bool {
    assert_entity_in_world(world, entity);
    return try_add(*components, entity, T, value);
}

remove_component :: inline (using world: *World, entity: Entity, $T: Type) {
    assert_entity_in_world(world, entity);
    remove_component(*components, entity, T);
}

try_remove :: inline (using world: *World, entity: Entity, $T: Type) -> bool {
    assert_entity_in_world(world, entity);
    return try_remove(*components, entity, T);
}

get_component :: inline (using world: *World, entity: Entity, $T: Type) -> *T #must {
    assert_entity_in_world(world, entity);
    return get(*components, entity, T);
}

try_get_component :: inline (using world: *World, entity: Entity, $T: Type) -> *T #must {
    assert_entity_in_world(world, entity);
    return try_get(*components, entity, T);
}

has_component :: inline (using world: *World, entity: Entity, $T: Type) -> bool #must {
    assert_entity_in_world(world, entity);
    return has(*components, entity, T);
}

is_tracked_entity :: inline (using world: *World, entity: Entity) -> bool #must {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    return is_tracked_entity(*components, entity);
}
