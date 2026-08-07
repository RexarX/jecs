#import "Basic";
#import "Hash_Table";

Archetype_Index         :: #type,isa Entity.Index;
Sparse_Index            :: #type,isa Entity.Index;
INVALID_ARCHETYPE_INDEX :: cast(Archetype_Index) Entity.INVALID_INDEX;
INVALID_SPARSE_VALUE    :: cast(Sparse_Index) Entity.INVALID_INDEX;

Entity_Index_Map :: Paged_Sparse_Array;

Column :: struct {
    type:      *Type_Info;
    stride:    s64;
    bytes:     [..] u8;
    on_remove: Component_Cleanup_Proc;

    allocator: Allocator;
}

init :: (column: *Column, type_info_ptr: *Type_Info, allocator: Allocator,
         on_remove: Component_Cleanup_Proc = null) {
    column.type = type_info_ptr;
    column.stride = type_info_ptr.runtime_size;
    if column.stride < 0 column.stride = 0;
    column.on_remove = on_remove;
    column.allocator = allocator;
    column.bytes.allocator = allocator;
}

deinit :: inline (using column: *Column) {
    array_free(bytes);
}

reset :: inline (using column: *Column) {
    if bytes.data && bytes.allocated {
        memset(bytes.data, 0, bytes.allocated);
    }
    array_reset_keeping_memory(*bytes);
}

clear :: inline (using column: *Column) {
    array_reset_keeping_memory(*bytes);
}

// Grow like array_add (double, min 8 elements), not exact array_resize capacity.
ensure_byte_capacity :: (using column: *Column, needed: s64) {
    if needed <= bytes.allocated return;

    element := ifx stride > 0 then stride else 1;
    capacity := bytes.allocated;
    min_capacity := 8 * element;
    if capacity < min_capacity capacity = min_capacity;
    while capacity < needed {
        capacity *= 2;
    }
    array_reserve(*bytes, capacity);
}

push_back :: (using column: *Column, data: *void) {
    old_count := bytes.count;
    new_count := old_count + stride;
    if stride > 0 {
        ensure_byte_capacity(column, new_count);
        bytes.count = new_count;
        if data {
            memcpy(bytes.data + old_count, data, stride);
        } else {
            memset(bytes.data + old_count, 0, stride);
        }
    }
}

push_back_default :: inline (using column: *Column) {
    push_back(column, null);
}

pop_back :: inline (using column: *Column) {
    if stride == 0 return;
    if bytes.count >= stride bytes.count -= stride;
}

get_component :: inline (using column: *Column,
                         row: Row_Index, $T: Type) -> *T #must {
    assert(column.type == type_info(T), "Column type mismatch for % component!",
           #run get_component_name(T));
    return cast(*T) get_component(column, row);
}

get_component :: inline (using column: *Column, row: Row_Index) -> *void #must {
    row_count := ifx stride > 0 then bytes.count / stride else bytes.count;
    assert(cast(s64) row * stride < bytes.count
           || (stride == 0 && cast(s64) row <= bytes.count),
           "Column row % is out of bounds (row count %)!", row, row_count);
    if stride == 0 return null;
    return bytes.data + cast(s64) row * stride;
}

move_row_from_last :: (using column: *Column,
                       dst_row: Row_Index, last_row: Row_Index) {
    if dst_row == last_row return;
    if stride == 0 return;

    dst_offset := cast(s64) dst_row * stride;
    last_offset := cast(s64) last_row * stride;
    assert(dst_offset + stride <= bytes.count && last_offset + stride <= bytes.count,
           "Cannot move row % from %: column has % bytes!",
           dst_row, last_row, bytes.count);
    memcpy(bytes.data + dst_offset, bytes.data + last_offset, stride);
}

swap_rows :: (using column: *Column, a: Row_Index, b: Row_Index) {
    if a == b return;
    if stride == 0 return;

    a_offset := cast(s64) a * stride;
    b_offset := cast(s64) b * stride;
    assert(a_offset + stride <= bytes.count && b_offset + stride <= bytes.count,
           "Cannot swap rows % and %: column has % bytes!", a, b, bytes.count);

    temp := alloc(stride,, allocator);
    defer free(temp,, allocator);
    memcpy(temp, bytes.data + a_offset, stride);
    memcpy(bytes.data + a_offset, bytes.data + b_offset, stride);
    memcpy(bytes.data + b_offset, temp, stride);
}

Archetype_Edge_Cache :: struct {
    add_edges:    Table(*Type_Info, Archetype_Index);
    remove_edges: Table(*Type_Info, Archetype_Index);

    allocator:    Allocator;
}

init :: (cache: *Archetype_Edge_Cache, allocator: Allocator) {
    cache.allocator = allocator;
    init(*cache.add_edges,, allocator);
    init(*cache.remove_edges,, allocator);
    cache.add_edges.allocator = allocator;
    cache.remove_edges.allocator = allocator;
}

deinit :: inline (using cache: *Archetype_Edge_Cache) {
    deinit(*add_edges);
    deinit(*remove_edges);
}

reset :: inline (using cache: *Archetype_Edge_Cache) {
    table_reset(*add_edges);
    table_reset(*remove_edges);
}

clear :: inline (using cache: *Archetype_Edge_Cache) {
    table_reset(*add_edges);
    table_reset(*remove_edges);
}

Component_Archetype_Index :: struct {
    archetypes: [..] Archetype_Index;
    allocator:  Allocator;
}

Archetype_Storage :: struct {
    archetypes:            [..] *Archetype;
    archetype_map:         Table(u64, Archetype_Index);
    edge_caches:           [..] Archetype_Edge_Cache;
    entity_archetype_map:  Entity_Index_Map;
    component_archetypes:  Table(*Type_Info, Component_Archetype_Index);
    empty_archetype_index: Archetype_Index = INVALID_ARCHETYPE_INDEX;
    // Bumps only when a new archetype is created (catalog growth).
    catalog_version:       u64;
    metadata:              *Table(*Type_Info, Component_Metadata);

    allocator:             Allocator;
}

init :: (storage: *Archetype_Storage, allocator: Allocator = .{}) {
    storage.allocator = resolve_allocator(storage, allocator);

    storage.archetypes.allocator = storage.allocator;
    init(*storage.archetype_map,, storage.allocator);
    storage.archetype_map.allocator = storage.allocator;
    storage.edge_caches.allocator = storage.allocator;
    init(*storage.component_archetypes,, storage.allocator);
    storage.component_archetypes.allocator = storage.allocator;
    init(*storage.entity_archetype_map, storage.allocator);
}

deinit :: (using storage: *Archetype_Storage) {
    for archetypes {
        deinit(it);
        free(it,, allocator);
    }
    array_free(archetypes);

    for * edge_caches deinit(it);
    array_free(edge_caches);

    for index, type_info_ptr: component_archetypes {
        index_ptr := table_find_pointer(*component_archetypes, type_info_ptr);
        if index_ptr array_free(index_ptr.archetypes);
    }
    deinit(*component_archetypes);
    deinit(*archetype_map);
    deinit(*entity_archetype_map);
}

reset :: (using storage: *Archetype_Storage) {
    for archetypes {
        for entity: it.entities {
            clear_index(*entity_archetype_map, entity.index);
        }
        reset(it);
    }
    for * edge_caches reset(it);
    table_reset(*archetype_map);
    // Re-register surviving archetypes in the emptied map.
    // Catalog unchanged — component indexes and catalog_version stay valid.
    for arch, i: archetypes {
        table_add(*archetype_map, arch.id.hash, cast(Archetype_Index) i);
    }
    reset(*entity_archetype_map);
}

clear :: (using storage: *Archetype_Storage) {
    for archetypes {
        for entity: it.entities {
            clear_index(*entity_archetype_map, entity.index);
        }
        clear(it);
    }
}

ensure_empty_archetype :: (using storage: *Archetype_Storage) -> Archetype_Index {
    if empty_archetype_index != INVALID_ARCHETYPE_INDEX {
        return empty_archetype_index;
    }

    id: Archetype_Id;
    init(*id, allocator);
    empty_archetype_index = get_or_create_archetype(storage, id);
    reset(*id);
    return empty_archetype_index;
}

get_archetype :: inline (using storage: *Archetype_Storage,
                         index: Archetype_Index) -> *Archetype #must {
    assert(index != INVALID_ARCHETYPE_INDEX && cast(s64) index < archetypes.count,
           "Invalid archetype index % (count %)!", index, archetypes.count);
    return archetypes[index];
}

get_or_create_archetype :: (using storage: *Archetype_Storage,
                            id: Archetype_Id) -> Archetype_Index {
    arch_index, found := table_find(*archetype_map, id.hash);
    if found {
        arch := get_archetype(storage, arch_index);
        if archetype_ids_equal(arch.id, id) return arch_index;
    }

    arch := New(Archetype,, allocator);
    init(arch, id, allocator);
    apply_column_cleanup_procs(storage, arch);
    arch_index = cast(Archetype_Index) archetypes.count;
    array_add(*archetypes, arch);

    cache: Archetype_Edge_Cache;
    init(*cache, allocator);
    array_add(*edge_caches, cache);

    table_add(*archetype_map, id.hash, arch_index);
    register_archetype_in_component_index(storage, arch, arch_index);
    catalog_version += 1;
    return arch_index;
}

get_or_create_archetype_add_edge :: (using storage: *Archetype_Storage,
                                     src_index: Archetype_Index,
                                     type_info_ptr: *Type_Info) -> Archetype_Index {
    cache := *edge_caches[src_index];
    dst_index, found := table_find(*cache.add_edges, type_info_ptr);
    if found return dst_index;

    src := get_archetype(storage, src_index);
    target_id := clone(src.id);
    with_type(*target_id, type_info_ptr);
    dst_index = get_or_create_archetype(storage, target_id);
    reset(*target_id);
    table_add(*cache.add_edges, type_info_ptr, dst_index);
    return dst_index;
}

get_or_create_archetype_remove_edge :: (using storage: *Archetype_Storage,
                                        src_index: Archetype_Index,
                                        type_info_ptr: *Type_Info) -> Archetype_Index {
    cache := *edge_caches[src_index];
    dst_index, found := table_find(*cache.remove_edges, type_info_ptr);
    if found return dst_index;

    src := get_archetype(storage, src_index);
    target_id := clone(src.id);
    without_type(*target_id, type_info_ptr);
    dst_index = get_or_create_archetype(storage, target_id);
    reset(*target_id);
    table_add(*cache.remove_edges, type_info_ptr, dst_index);
    return dst_index;
}

get_archetype_index_by_id :: inline (using storage: *Archetype_Storage,
                                     id: Archetype_Id) -> Archetype_Index, bool #must {
    index, found := table_find(*archetype_map, id.hash);
    return index, found;
}

assign_entity_archetype_index :: inline (using storage: *Archetype_Storage,
                                         entity_index: Entity.Index,
                                         arch_index: Archetype_Index) {
    assign(*entity_archetype_map, entity_index, cast(Sparse_Index) arch_index);
}

// src/dst columns follow sorted Archetype_Id.types — merge-walk instead of hash lookups.
// Surviving columns are moved (no cleanup); src-only columns are discarded (cleanup fires).
migrate_entity :: (using storage: *Archetype_Storage, entity: Entity,
                   src_index: Archetype_Index, dst_index: Archetype_Index) {
    if src_index == dst_index return;

    src := get_archetype(storage, src_index);
    dst := get_archetype(storage, dst_index);
    src_row := cast(Row_Index) get(*src.entity_to_row, entity.index);

    allocate_row(dst, entity);
    dst_row := cast(Row_Index) get(*dst.entity_to_row, entity.index);

    src_i: s64 = 0;
    dst_i: s64 = 0;
    while src_i < src.columns.count && dst_i < dst.columns.count {
        src_type := cast(u64) src.columns[src_i].type;
        dst_type := cast(u64) dst.columns[dst_i].type;
        if src_type == dst_type {
            src_col := *src.columns[src_i];
            dst_col := *dst.columns[dst_i];
            if dst_col.stride > 0 {
                memcpy(get_component(dst_col, dst_row),
                       get_component(src_col, src_row), dst_col.stride);
            }
            src_i += 1;
            dst_i += 1;
        } else if src_type < dst_type {
            cleanup_column_row(*src.columns[src_i], src_row);
            src_i += 1;
        } else {
            dst_i += 1;
        }
    }

    while src_i < src.columns.count {
        cleanup_column_row(*src.columns[src_i], src_row);
        src_i += 1;
    }

    swapped := remove_entity_raw(src, entity);
    assign_entity_archetype_index(storage, entity.index, dst_index);
    if is_valid(swapped) {
        assign_entity_archetype_index(storage, swapped.index, src_index);
    }
}

lookup_on_remove :: inline (using storage: *Archetype_Storage,
                            type_info_ptr: *Type_Info) -> Component_Cleanup_Proc #must {
    if !metadata return null;
    meta, found := table_find(metadata, type_info_ptr);
    if !found return null;
    return meta.on_remove;
}

apply_column_cleanup_procs :: (using storage: *Archetype_Storage,
                               archetype: *Archetype) {
    for * col: archetype.columns {
        col.on_remove = lookup_on_remove(storage, col.type);
    }
}

is_tracked_entity :: inline (using storage: *Archetype_Storage,
                             entity: Entity) -> bool #must {
    if !is_valid(entity) return false;
    return contains(*entity_archetype_map, entity.index);
}

try_get_entity_archetype_index :: inline (using storage: *Archetype_Storage,
                                          entity: Entity) -> Archetype_Index, bool #must {
    value, ok := try_get(*entity_archetype_map, entity.index);
    if !ok return INVALID_ARCHETYPE_INDEX, false;
    return cast(Archetype_Index) value, true;
}

get_entity_archetype_index :: inline (using storage: *Archetype_Storage,
                                      entity: Entity) -> Archetype_Index #must {
    index, ok := try_get_entity_archetype_index(storage, entity);
    assert(ok, "Entity % is not tracked by archetype storage!", entity);
    return index;
}

get_archetype_count :: inline (using storage: *Archetype_Storage) -> s64 #must {
    return archetypes.count;
}

get_catalog_version :: inline (using storage: *Archetype_Storage) -> u64 #must {
    return catalog_version;
}

get_component_archetypes :: inline (using storage: *Archetype_Storage,
                                    type_info_ptr: *Type_Info) -> [] Archetype_Index #must {
    index := table_find_pointer(*component_archetypes, type_info_ptr);
    if !index return .{};
    return index.archetypes;
}

#scope_module;

register_archetype_in_component_index :: (using storage: *Archetype_Storage,
                                          arch: *Archetype,
                                          arch_index: Archetype_Index) {
    for type_info_ptr: arch.id.types {
        index := table_find_pointer(*component_archetypes, type_info_ptr);
        if !index {
            created: Component_Archetype_Index;
            created.allocator = allocator;
            created.archetypes.allocator = allocator;
            table_add(*component_archetypes, type_info_ptr, created);
            index = table_find_pointer(*component_archetypes, type_info_ptr);
            assert(index != null);
        }
        array_add(*index.archetypes, arch_index);
    }
}

archetype_ids_equal :: (a: Archetype_Id, b: Archetype_Id) -> bool #must {
    if a.types.count != b.types.count return false;
    for i: 0..a.types.count - 1 {
        if a.types[i] != b.types[i] return false;
    }
    return true;
}
