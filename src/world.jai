World :: struct {
    entities:   Entities;
    components: Components;

    allocator:  Allocator;
}

init :: inline (world: *World, allocator: Allocator = .{}) {
    world.allocator = resolve_allocator(world, allocator);

    init(*world.entities, world.allocator);
    init(*world.components, world.allocator);
}

deinit :: inline (using world: *World) {
    deinit(*components);
    deinit(*entities);
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
    push_allocator(temp);

    pending: [..] Entity;
    pending.allocator = temp;
    for entity: get_reserved_entities(*entities) {
        array_add(*pending, entity);
    }

    flush_reserved_entities(*entities);

    for entity: pending {
        if !is_tracked_entity(*components, entity) {
            init_entity(*components, entity);
        }
    }
}

// Thread-safe.
needs_flush :: inline (using world: *World) -> bool #must {
    return needs_flush(*entities);
}

assert_entity_in_world :: inline (using world: *World, entity: Entity,
                                  loc := #caller_location) {
    assert(is_valid(entity), "Entity % must be valid!", entity, loc = loc);
    assert(validate_entity(*entities, entity), "Entity % must exist in the world!",
           entity, loc = loc);
}

// Components API passthrough.

add_component :: inline (using world: *World, entity: Entity, value: $T) {
    assert_entity_in_world(world, entity);
    add_component(*components, entity, value);
}

try_add_component :: inline (using world: *World,
                             entity: Entity, value: $T) -> bool #must {
    assert_entity_in_world(world, entity);
    return try_add_component(*components, entity, value);
}

remove_component :: inline (using world: *World, entity: Entity, $T: Type) {
    assert_entity_in_world(world, entity);
    remove_component(*components, entity, T);
}

try_remove_component :: inline (using world: *World,
                                entity: Entity, $T: Type) -> bool #must {
    assert_entity_in_world(world, entity);
    return try_remove_component(*components, entity, T);
}

add_components :: inline (using world: *World, entity: Entity, values: .. Any) {
    assert_entity_in_world(world, entity);
    add_components(*components, entity, ..values);
}

try_add_components :: inline (using world: *World,
                              entity: Entity, values: .. Any) -> [] bool #must {
    assert_entity_in_world(world, entity);
    return try_add_components(*components, entity, ..values);
}

remove_components :: inline (using world: *World,
                             entity: Entity, types: .. Type) {
    assert_entity_in_world(world, entity);
    remove_components(*components, entity, ..types);
}

try_remove_components :: inline (using world: *World, entity: Entity,
                                 types: .. Type) -> [] bool #must {
    assert_entity_in_world(world, entity);
    return try_remove_components(*components, entity, ..types);
}

get_component :: inline (using world: *World,
                         entity: Entity, $T: Type) -> *T #must {
    assert_entity_in_world(world, entity);
    return get_component(*components, entity, T);
}

try_get_component :: inline (using world: *World,
                             entity: Entity, $T: Type) -> *T #must {
    assert_entity_in_world(world, entity);
    return try_get_component(*components, entity, T);
}

has_component :: inline (using world: *World,
                         entity: Entity, $T: Type) -> bool #must {
    assert_entity_in_world(world, entity);
    return has_component(*components, entity, T);
}

has_components :: inline (using world: *World,
                          entity: Entity, values: .. Any) -> bool #must {
    assert_entity_in_world(world, entity);
    return has_components(*components, entity, ..values);
}

is_tracked_entity :: inline (using world: *World,
                             entity: Entity) -> bool #must {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    return is_tracked_entity(*components, entity);
}
