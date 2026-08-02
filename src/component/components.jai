#import "Basic";
Basic :: #import "Basic"; // for ENABLE_ASSERT
#import "Hash_Table";

Components :: struct {
    metadata:           Table(*Type_Info, Component_Metadata);
    archetype_storage:  Archetype_Storage;
    sparse_set_storage: Sparse_Set_Storage;

    allocator:          Allocator;
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
    deinit(*metadata);
}

clear :: inline (using components: *Components) {
    clear(*sparse_set_storage);
    clear(*archetype_storage);
    table_reset(*metadata);
}

register :: inline (components: *Components, $T: Type) {
    register(components, type_info(T), make_component_metadata(T));
}

register :: inline (components: *Components, info: *Type_Info) {
    _, found := table_find(*components.metadata, info);
    if found return;
    table_add(*components.metadata, info, make_component_metadata(info));
}

register :: inline (components: *Components, info: *Type_Info,
                    meta: Component_Metadata) {
    _, found := table_find(*components.metadata, info);
    if found return;
    table_add(*components.metadata, info, meta);
}

get_or_register_metadata :: (components: *Components,
                             info: *Type_Info) -> Component_Metadata #must {
    meta, found := table_find(*components.metadata, info);
    if found return meta;
    meta = make_component_metadata(info);
    table_add(*components.metadata, info, meta);
    return meta;
}

// Compile-time typed single-component API ($T — no Any boxing).
add_component :: (using components: *Components, entity: Entity, value: $T) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!",
           entity);
    register(components, T);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        assign_component(*sparse_set_storage, entity, value);
    } else {
        src_index := get_archetype_index(components, entity);
        src := get_archetype(*archetype_storage, src_index);
        if !has_column(src, T) {
            dst_index := get_or_create_archetype_add_edge(
                *archetype_storage, src_index, type_info(T));
            migrate_entity(*archetype_storage, entity, src_index, dst_index);
        }
        assign_component(get_entity_archetype(components, entity),
                         entity, value);
    }
}

// true = newly added, false = already present (value not overwritten).
try_add_component :: (using components: *Components,
                      entity: Entity, value: $T) -> bool #must {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!",
           entity);
    register(components, T);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        return try_assign_component(*sparse_set_storage, entity, value);
    } else {
        src_index := get_archetype_index(components, entity);
        src := get_archetype(*archetype_storage, src_index);
        if has_column(src, T) return false;

        dst_index := get_or_create_archetype_add_edge(
            *archetype_storage, src_index, type_info(T));
        migrate_entity(*archetype_storage, entity, src_index, dst_index);
        assign_component(get_entity_archetype(components, entity),
                         entity, value);
        return true;
    }
}

remove_component :: (using components: *Components, entity: Entity, $T: Type) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!",
           entity);

    component_name :: #run get_component_name(T);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        assert(has_component(*sparse_set_storage, entity, T),
               "Entity % does not have % component!", entity, component_name);
        remove_component(*sparse_set_storage, entity, T);
    } else {
        src_index := get_archetype_index(components, entity);
        src := get_archetype(*archetype_storage, src_index);
        assert(has_column(src, T), "Entity % does not have % component!",
               entity, component_name);
        dst_index := get_or_create_archetype_remove_edge(
            *archetype_storage, src_index, type_info(T));
        migrate_entity(*archetype_storage, entity, src_index, dst_index);
    }
}

// true = removed, false = was not present.
try_remove_component :: (using components: *Components,
                         entity: Entity, $T: Type) -> bool #must {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!",
           entity);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        return try_remove_component(*sparse_set_storage, entity, T);
    } else {
        src_index := get_archetype_index(components, entity);
        src := get_archetype(*archetype_storage, src_index);
        if !has_column(src, T) return false;

        dst_index := get_or_create_archetype_remove_edge(
            *archetype_storage, src_index, type_info(T));
        migrate_entity(*archetype_storage, entity, src_index, dst_index);
        return true;
    }
}

add_components :: inline (using components: *Components,
                          entity: Entity, values: .. Any) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!",
           entity);
    assert(values.count > 0, "Requires at least one component value!");
    add_components_internal(components, entity, values);
}

// Per-component success (temp-allocated). true = newly added, false = already present.
try_add_components :: inline (using components: *Components,
                       entity: Entity, values: .. Any) -> [] bool #must {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!",
           entity);
    assert(values.count > 0, "Requires at least one component value!");
    return try_add_components_internal(components, entity, values);
}

remove_components :: inline (using components: *Components,
                      entity: Entity, types: .. Type) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!",
           entity);
    assert(types.count > 0, "Requires at least one component type!");
    remove_components_internal(components, entity, types);
}

// Per-component success (temp-allocated). true = removed, false = was not present.
try_remove_components :: inline (using components: *Components,
                          entity: Entity, types: .. Type) -> [] bool #must {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!",
           entity);
    assert(types.count > 0, "Requires at least one component type!");
    return try_remove_components_internal(components, entity, types);
}

get_component :: inline (using components: *Components,
                         entity: Entity, $T: Type) -> *T #must {
    #assert #run !is_tag(T) "Use has_component() for tag components; get_component() requires a value type!";
    assert(is_valid(entity), "Entity % must be valid!", entity);
    register(components, T);

    component_name :: #run get_component_name(T);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        set := try_find_set(*sparse_set_storage, T);
        assert(set != null, "Sparse storage does not exist for % component type!",
               component_name);
        result := try_get_component(set, entity, T);
        assert(result != null, "Entity % does not have % component!",
               entity, component_name);
        return result;
    } else {
        assert(is_tracked_entity(components, entity), "Entity % must be tracked!",
               entity);
        arch := get_entity_archetype(components, entity);
        assert(has_column(arch, T), "Entity % does not have % component!",
               entity, component_name);
        result := try_get_component(arch, entity, T);
        assert(result != null, "Entity % does not have % component!",
               entity, component_name);
        return result;
    }
}

try_get_component :: inline (using components: *Components,
                             entity: Entity, $T: Type) -> *T #must {
    #assert #run !is_tag(T) "Use has_component() for tag components; try_get_component() requires a value type!";
    assert(is_valid(entity), "Entity % must be valid!", entity);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        return try_get_component(*sparse_set_storage, entity, T);
    } else {
        if !is_tracked_entity(components, entity) return null;
        return try_get_component(get_entity_archetype(components, entity),
                                 entity, T);
    }
}

has_component :: (using components: *Components,
                  entity: Entity, $T: Type) -> bool #must {
    assert(is_valid(entity), "Entity % must be valid!", entity);

    #if #run get_storage_kind(T) == .SPARSE_SET {
        return has_component(*sparse_set_storage, entity, T);
    } else {
        if !is_tracked_entity(components, entity) return false;
        arch := get_entity_archetype(components, entity);
        if !has_column(arch, T) return false;
        return try_get_component(arch, entity, T) != null;
    }
}

// true if the entity has every component type in values (Any boxing, like add_components).
has_components :: inline (using components: *Components,
                   entity: Entity, values: .. Any) -> bool #must {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(values.count > 0, "Requires at least one component value!");
    return has_components_internal(components, entity, values);
}

init_entity :: (using components: *Components, entity: Entity) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(!is_tracked_entity(components, entity), "Entity % is already tracked!",
           entity);

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
        assign_entity_archetype_index(*archetype_storage, swapped.index,
                                      arch_index);
    }
    clear_index(*archetype_storage.entity_archetype_map, entity.index);

    try_remove_entity(*sparse_set_storage, entity);
}

try_remove_entity :: inline (using components: *Components,
                             entity: Entity) -> bool {
    if !is_tracked_entity(components, entity) return false;
    remove_entity(components, entity);
    return true;
}

clear_entity :: (using components: *Components, entity: Entity) {
    assert(is_valid(entity), "Entity % must be valid!", entity);
    assert(is_tracked_entity(components, entity), "Entity % must be tracked!",
           entity);

    arch_index := get_archetype_index(components, entity);
    empty_index := ensure_empty_archetype(*archetype_storage);

    if arch_index != empty_index {
        arch := get_archetype(*archetype_storage, arch_index);
        swapped := remove_entity(arch, entity);
        if is_valid(swapped) {
            assign_entity_archetype_index(*archetype_storage, swapped.index,
                                          arch_index);
        }

        empty := get_archetype(*archetype_storage, empty_index);
        allocate_row(empty, entity);
        assign_entity_archetype_index(*archetype_storage, entity.index,
                                      empty_index);
        archetype_storage.structural_version += 1;
    }

    try_remove_entity(*sparse_set_storage, entity);
}

is_tracked_entity :: inline (using components: *Components,
                             entity: Entity) -> bool #must {
    return is_tracked_entity(*archetype_storage, entity);
}

get_archetype :: inline (using components: *Components, index:
                         Archetype_Index) -> *Archetype #must {
    return get_archetype(*archetype_storage, index);
}

get_archetype_index :: inline (using components: *Components,
                               entity: Entity) -> Archetype_Index #must {
    return get_entity_archetype_index(*archetype_storage, entity);
}

try_get_archetype_index :: inline (using components: *Components,
                            entity: Entity) -> Archetype_Index, bool #must {
    index, ok := try_get_entity_archetype_index(*archetype_storage, entity);
    return index, ok;
}

get_entity_archetype :: inline (using components: *Components,
                                entity: Entity) -> *Archetype #must {
    index := get_archetype_index(components, entity);
    return get_archetype(*archetype_storage, index);
}

get_sparse_set :: inline (using components: *Components,
                          $T: Type) -> *Sparse_Set #must {
    register(components, T);
    #assert #run get_storage_kind(T) == .SPARSE_SET "Type must be a sparse set component!";
    return ensure_set(*sparse_set_storage, T);
}

get_archetype_count :: inline (using components: *Components) -> s64 #must {
    return get_archetype_count(*archetype_storage);
}

get_structural_version :: inline (using components: *Components) -> u64 #must {
    return archetype_storage.structural_version;
}

#scope_module;

has_components_internal :: (using components: *Components,
                            entity: Entity, values: [] Any) -> bool #must {
    for value: values {
        meta := get_or_register_metadata(components, value.type);
        if meta.storage_kind == .SPARSE_SET {
            if !has_component(*sparse_set_storage, entity, value.type) {
                return false;
            }
        } else {
            if !is_tracked_entity(components, entity) return false;
            arch := get_entity_archetype(components, entity);
            if !has_column(arch, value.type) return false;
        }
    }
    return true;
}

add_components_internal :: (using components: *Components,
                            entity: Entity, values: [] Any) {
    push_allocator(temp);

    archetype_values: [..] Any;
    archetype_values.allocator = temp;
    sparse_values: [..] Any;
    sparse_values.allocator = temp;

    src := get_entity_archetype(components, entity);

    for value: values {
        meta := get_or_register_metadata(components, value.type);
        if meta.storage_kind == .SPARSE_SET {
            array_add(*sparse_values, value);
        } else {
            array_add(*archetype_values, value);
        }
    }

    if archetype_values.count > 0 {
        add_archetype_components(components, entity, archetype_values);
    }

    for value: sparse_values {
        assign_component_bytes(*sparse_set_storage, entity, value.type,
                               value.value_pointer);
    }
}

try_add_components_internal :: (using components: *Components, entity: Entity,
                                values: [] Any) -> [] bool #must {
    push_allocator(temp);

    results, _ := NewArray(values.count, bool);
    archetype_values: [..] Any;
    archetype_values.allocator = temp;
    sparse_values: [..] Any;
    sparse_values.allocator = temp;

    src := get_entity_archetype(components, entity);

    for value, i: values {
        meta := get_or_register_metadata(components, value.type);
        if meta.storage_kind == .SPARSE_SET {
            if has_component(*sparse_set_storage, entity, value.type) {
                results[i] = false;
            } else {
                results[i] = true;
                array_add(*sparse_values, value);
            }
        } else {
            if has_column(src, value.type) {
                results[i] = false;
            } else {
                results[i] = true;
                array_add(*archetype_values, value);
            }
        }
    }

    if archetype_values.count > 0 {
        add_archetype_components(components, entity, archetype_values);
    }

    for value: sparse_values {
        assign_component_bytes(*sparse_set_storage, entity, value.type,
                               value.value_pointer);
    }

    return results;
}

remove_components_internal :: (using components: *Components,
                               entity: Entity, types: [] Type) {
    push_allocator(temp);

    archetype_types: [..] *Type_Info;
    archetype_types.allocator = temp;
    sparse_types: [..] *Type_Info;
    sparse_types.allocator = temp;

    #if Basic.ENABLE_ASSERT {
        missing_names: [..] string;
        missing_names.allocator = temp;
        src := get_entity_archetype(components, entity);

        for component_type: types {
            info := cast(*Type_Info) component_type;
            meta := get_or_register_metadata(components, info);

            if meta.storage_kind == .SPARSE_SET {
                if has_component(*sparse_set_storage, entity, info) {
                    array_add(*sparse_types, info);
                } else {
                    array_add(*missing_names, meta.name);
                }
            } else {
                if has_column(src, info) {
                    array_add(*archetype_types, info);
                } else {
                    array_add(*missing_names, meta.name);
                }
            }
        }

        if missing_names.count > 0 {
            assert(false, "Entity % does not have component(s): %!",
                   entity, format_component_names(missing_names));
        }
    } else {
        src := get_entity_archetype(components, entity);

        for component_type: types {
            info := cast(*Type_Info) component_type;
            meta := get_or_register_metadata(components, info);

            if meta.storage_kind == .SPARSE_SET {
                array_add(*sparse_types, info);
            } else {
                array_add(*archetype_types, info);
            }
        }
    }

    if archetype_types.count > 0 {
        remove_archetype_components(components, entity, archetype_types);
    }

    for info: sparse_types {
        remove_component(*sparse_set_storage, entity, info);
    }
}

try_remove_components_internal :: (using components: *Components,
                                   entity: Entity,
                                   types: [] Type) -> [] bool #must {
    push_allocator(temp);

    results, _ := NewArray(types.count, bool);
    archetype_types: [..] *Type_Info;
    archetype_types.allocator = temp;
    sparse_types: [..] *Type_Info;
    sparse_types.allocator = temp;

    src := get_entity_archetype(components, entity);

    for component_type, i: types {
        info := cast(*Type_Info) component_type;
        meta := get_or_register_metadata(components, info);

        if meta.storage_kind == .SPARSE_SET {
            if has_component(*sparse_set_storage, entity, info) {
                results[i] = true;
                array_add(*sparse_types, info);
            } else {
                results[i] = false;
            }
        } else {
            if has_column(src, info) {
                results[i] = true;
                array_add(*archetype_types, info);
            } else {
                results[i] = false;
            }
        }
    }

    if archetype_types.count > 0 {
        remove_archetype_components(components, entity, archetype_types);
    }

    for info: sparse_types {
        remove_component(*sparse_set_storage, entity, info);
    }

    return results;
}

add_archetype_components :: (using components: *Components,
                             entity: Entity, values: [] Any) {
    src_index := get_archetype_index(components, entity);
    src := get_archetype(*archetype_storage, src_index);

    needs_migrate := false;
    for value: values {
        if !has_column(src, value.type) {
            needs_migrate = true;
            break;
        }
    }

    if needs_migrate {
        if values.count == 1 {
            dst_index := get_or_create_archetype_add_edge(
                *archetype_storage, src_index, values[0].type);
            migrate_entity(*archetype_storage, entity, src_index, dst_index);
        } else {
            target_id := clone(src.id);
            for value: values {
                with_type(*target_id, value.type);
            }
            dst_index := get_or_create_archetype(*archetype_storage, target_id);
            reset(*target_id);
            migrate_entity(*archetype_storage, entity, src_index, dst_index);
        }
    }

    dst := get_entity_archetype(components, entity);
    for value: values {
        assign_component_bytes(dst, entity, value.type, value.value_pointer);
    }
}

remove_archetype_components :: (using components: *Components,
                                entity: Entity, types: [] *Type_Info) {
    src_index := get_archetype_index(components, entity);
    src := get_archetype(*archetype_storage, src_index);

    if types.count == 1 {
        if !has_column(src, types[0]) return;
        dst_index := get_or_create_archetype_remove_edge(
            *archetype_storage, src_index, types[0]);
        migrate_entity(*archetype_storage, entity, src_index, dst_index);
        return;
    }

    target_id := clone(src.id);
    for info: types {
        without_type(*target_id, info);
    }
    dst_index := get_or_create_archetype(*archetype_storage, target_id);
    reset(*target_id);
    migrate_entity(*archetype_storage, entity, src_index, dst_index);
}

format_component_names :: (names: [] string) -> string #must {
    if names.count == 0 return "";
    if names.count == 1 return names[0];

    builder: String_Builder;
    builder.allocator = temp;
    for name, i: names {
        if i > 0 print_to_builder(*builder, ", ");
        print_to_builder(*builder, "%", name);
    }
    return builder_to_string(*builder,, temp);
}
