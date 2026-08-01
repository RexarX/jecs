#import "Basic";
#import "Hash_Table";

Components :: struct {
    metadata: Table(*Type_Info, Component_Metadata);
    archetype_storage: Archetype_Storage;
    sparse_set_storage: Sparse_Set_Storage;
    allocator: Allocator;
}

init :: (components: *Components, allocator: Allocator = .{}) {
    components.allocator = resolve_allocator(components, allocator);

    init(*components.metadata,, components.allocator);
    components.metadata.allocator = components.allocator;
    init(*components.archetype_storage, components.allocator);
    init(*components.sparse_set_storage, components.allocator);
}

reset :: inline (using components: *Components) {
    reset(*sparse_set_storage);
    reset(*archetype_storage);
    table_reset(*metadata);
}

clear :: inline (using components: *Components) {
    clear(*sparse_set_storage);
    clear(*archetype_storage);
    table_reset(*metadata);
}

register :: (components: *Components, $T: Type) {
    type_info_ptr := type_info(T);
    _, found := table_find(*components.metadata, type_info_ptr);
    if found return;

    meta := make_component_metadata(T);
    table_add(*components.metadata, type_info_ptr, meta);
}

add :: inline (using components: *Components, entity: Entity, $T: Type, value: T) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!", entity);
    register(components, T);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        assign(*sparse_set_storage, entity, T, value);
    } else {
        add_archetype_component(components, entity, T, value);
    }
}

try_add :: inline (using components: *Components, entity: Entity, $T: Type, value: T) -> bool {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!", entity);
    register(components, T);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        return try_assign(*sparse_set_storage, entity, T, value);
    } else {
        return try_add_archetype_component(components, entity, T, value);
    }
}

remove_component :: inline (using components: *Components, entity: Entity, $T: Type) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!", entity);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        assert(contains(*sparse_set_storage, entity, T), "Entity % does not have % component!", entity, component_name(T));
        erase(*sparse_set_storage, entity, T);
    } else {
        arch := entity_archetype(components, entity);
        assert(has_column(arch, T), "Entity % does not have % component!", entity, component_name(T));
        remove_archetype_component(components, entity, T);
    }
}

try_remove :: inline (using components: *Components, entity: Entity, $T: Type) -> bool {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!", entity);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        return try_erase(*sparse_set_storage, entity, T);
    } else {
        return try_remove_archetype_component(components, entity, T);
    }
}

get :: inline (using components: *Components, entity: Entity, $T: Type) -> *T #must {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    register(components, T);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        set := try_find_set(*sparse_set_storage, T);
        assert(set != null, "Sparse storage does not exist for % component type!", component_name(T));
        result := try_get(set, entity);
        assert(result != null, "Entity % does not have % component!", entity, component_name(T));
        return result;
    } else {
        assert(is_tracked_entity(components, entity), "Entity % must be tracked!", entity);
        arch := entity_archetype(components, entity);
        assert(has_column(arch, T), "Entity % does not have % component!", entity, component_name(T));
        result := try_get(arch, entity, T);
        assert(result != null, "Entity % does not have % component!", entity, component_name(T));
        return result;
    }
}

try_get :: inline (using components: *Components, entity: Entity, $T: Type) -> *T #must {
    assert(is_valid(entity), "Entity % must be valid!", entity);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        return try_get(*sparse_set_storage, entity, T);
    } else {
        if !is_tracked_entity(components, entity) return null;
        return try_get(entity_archetype(components, entity), entity, T);
    }
}

has :: (using components: *Components, entity: Entity, $T: Type) -> bool #must {
    assert(is_valid(entity), "Entity % must be valid!", entity);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        return contains(*sparse_set_storage, entity, T);
    } else {
        if !is_tracked_entity(components, entity) return false;
        arch := entity_archetype(components, entity);
        if !has_column(arch, T) return false;
        return try_get(arch, entity, T) != null;
    }
}

init_entity :: (using components: *Components, entity: Entity) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(!is_tracked_entity(components, entity), "Entity % is already tracked!", entity);

    empty_index := ensure_empty_archetype(*archetype_storage);
    empty := get_archetype(*archetype_storage, empty_index);
    allocate_row(empty, entity);
    assign_entity_archetype_index(*archetype_storage, entity.index, empty_index);
}

remove_entity :: (using components: *Components, entity: Entity) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    if !is_tracked_entity(components, entity) return;

    arch_index := get_archetype_index(components, entity);
    arch := get_archetype(*archetype_storage, arch_index);
    swapped := remove_entity(arch, entity);
    if is_valid(swapped) {
        assign_entity_archetype_index(*archetype_storage, swapped.index, arch_index);
    }
    clear_index(*archetype_storage.entity_archetype_map, entity.index);

    try_remove_entity(*sparse_set_storage, entity);
}

try_remove_entity :: inline (using components: *Components, entity: Entity) -> bool {
    if !is_tracked_entity(components, entity) return false;
    remove_entity(components, entity);
    return true;
}

clear_entity :: (using components: *Components, entity: Entity) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!", entity);

    arch_index := get_archetype_index(components, entity);
    empty_index := ensure_empty_archetype(*archetype_storage);

    if arch_index != empty_index {
        arch := get_archetype(*archetype_storage, arch_index);
        swapped := remove_entity(arch, entity);
        if is_valid(swapped) {
            assign_entity_archetype_index(*archetype_storage, swapped.index, arch_index);
        }

        empty := get_archetype(*archetype_storage, empty_index);
        allocate_row(empty, entity);
        assign_entity_archetype_index(*archetype_storage, entity.index, empty_index);
        archetype_storage.structural_version += 1;
    }

    try_remove_entity(*sparse_set_storage, entity);
}

is_tracked_entity :: inline (using components: *Components, entity: Entity) -> bool #must {
    return is_tracked_entity(*archetype_storage, entity);
}

get_archetype :: inline (using components: *Components, index: Archetype_Index) -> *Archetype #must {
    return get_archetype(*archetype_storage, index);
}

get_archetype_index :: inline (using components: *Components, entity: Entity) -> Archetype_Index #must {
    return get_entity_archetype_index(*archetype_storage, entity);
}

try_get_archetype_index :: (using components: *Components, entity: Entity) -> Archetype_Index, bool #must {
    index, ok := try_get_entity_archetype_index(*archetype_storage, entity);
    return index, ok;
}

entity_archetype :: inline (using components: *Components, entity: Entity) -> *Archetype #must {
    index := get_archetype_index(components, entity);
    return get_archetype(*archetype_storage, index);
}

sparse_set :: inline (using components: *Components, $T: Type) -> *Sparse_Set(T) #must {
    register(components, T);
    #assert #run get_storage_kind(T) == .SPARSE_SET "Type must be a sparse set component!";
    return ensure_set(*sparse_set_storage, T);
}

archetype_count :: inline (using components: *Components) -> s64 #must {
    return archetype_count(*archetype_storage);
}

structural_version :: inline (using components: *Components) -> u64 #must {
    return archetype_storage.structural_version;
}

#scope_module;

add_archetype_component :: (using components: *Components, entity: Entity, $T: Type, value: T) {
    src_index := get_archetype_index(components, entity);
    src := get_archetype(*archetype_storage, src_index);

    if has_column(src, T) {
        assign(src, entity, T, value);
        return;
    }

    target_id := duplicate(src.id);
    with(*target_id, T);
    dst_index := get_or_create_archetype(*archetype_storage, target_id);
    reset(*target_id);
    migrate_entity(*archetype_storage, entity, src_index, dst_index);
    dst := get_archetype(*archetype_storage, dst_index);
    assign(dst, entity, T, value);
}

try_add_archetype_component :: (using components: *Components, entity: Entity, $T: Type, value: T) -> bool {
    src := entity_archetype(components, entity);
    if has_column(src, T) return false;

    add_archetype_component(components, entity, T, value);
    return true;
}

remove_archetype_component :: (using components: *Components, entity: Entity, $T: Type) {
    src_index := get_archetype_index(components, entity);
    src := get_archetype(*archetype_storage, src_index);
    if !has_column(src, T) return;

    target_id := duplicate(src.id);
    without(*target_id, T);
    dst_index := get_or_create_archetype(*archetype_storage, target_id);
    reset(*target_id);
    migrate_entity(*archetype_storage, entity, src_index, dst_index);
}

try_remove_archetype_component :: (using components: *Components, entity: Entity, $T: Type) -> bool {
    src := entity_archetype(components, entity);
    if !has_column(src, T) return false;
    remove_archetype_component(components, entity, T);
    return true;
}
