#import "Basic";

Dense_Index         :: #type,isa Entity.Index;
INVALID_DENSE_INDEX :: cast(Dense_Index) Entity.INVALID_INDEX;

Sparse_Set :: struct {
    pages:     Paged_Sparse_Array;
    dense:     [..] Entity.Index;
    bytes:     [..] u8;
    stride:    s64;
    type:      *Type_Info;
    on_remove: Component_Cleanup_Proc;

    allocator: Allocator;
}

init :: (set: *Sparse_Set, type_info_ptr: *Type_Info,
         allocator: Allocator = .{},
         on_remove: Component_Cleanup_Proc = null) {
    set.allocator = resolve_allocator(set, allocator);
    set.type = type_info_ptr;
    set.stride = type_info_ptr.runtime_size;
    if set.stride < 0 set.stride = 0;
    set.on_remove = on_remove;

    init(*set.pages, set.allocator);
    set.dense.allocator = set.allocator;
    set.bytes.allocator = set.allocator;
}

deinit :: (using set: *Sparse_Set) {
    cleanup_all_entries(set);
    deinit(*pages);
    array_free(dense);
    array_free(bytes);
}

reset :: inline (using set: *Sparse_Set) {
    cleanup_all_entries(set);
    reset(*pages);
    if dense.data && dense.allocated {
        memset(dense.data, 0, dense.allocated * size_of(Entity.Index));
    }
    if bytes.data && bytes.allocated {
        memset(bytes.data, 0, bytes.allocated);
    }
    array_reset_keeping_memory(*dense);
    array_reset_keeping_memory(*bytes);
}

clear :: inline (using set: *Sparse_Set) {
    cleanup_all_entries(set);
    for entity_index: dense clear_index(*pages, entity_index);
    array_reset_keeping_memory(*dense);
    array_reset_keeping_memory(*bytes);
}

cleanup_all_entries :: (using set: *Sparse_Set) {
    if !on_remove || stride <= 0 || dense.count <= 0 return;
    for i: 0..dense.count - 1 {
        invoke_cleanup(on_remove, bytes.data + i * stride);
    }
}

reserve :: (using set: *Sparse_Set, count: s64) {
    array_reserve(*dense, count);
    if stride > 0 array_reserve(*bytes, count * stride);

    if count > 0 {
        last_index := cast(Entity.Index) (count - 1);
        page_i := cast(s64) last_index >> DEFAULT_PAGED_SPARSE_PAGE_BITS;
        ensure_page_capacity(*pages, page_i);
    }
}

assign_component :: inline (using set: *Sparse_Set, entity: Entity, value: $T) {
    assert(type == type_info(T), "Sparse set type mismatch for %!",
           #run get_component_name(T));
    insert_bytes(set, entity.index, xx *value);
}

assign_component_bytes :: inline (using set: *Sparse_Set,
                                  entity: Entity, data: *void) {
    insert_bytes(set, entity.index, data);
}

try_assign_component :: inline (using set: *Sparse_Set,
                               entity: Entity, value: $T) -> bool {
    assert(type == type_info(T), "Sparse set type mismatch for %!",
           #run get_component_name(T));
    return try_insert_bytes(set, entity.index, xx *value);
}

try_assign_component_bytes :: inline (using set: *Sparse_Set,
                                      entity: Entity, data: *void) -> bool {
    return try_insert_bytes(set, entity.index, data);
}

erase_entity :: inline (using set: *Sparse_Set, entity: Entity) {
    remove_index(set, entity.index);
}

try_erase_entity :: inline (using set: *Sparse_Set, entity: Entity) -> bool {
    return remove_index(set, entity.index);
}

get_component :: inline (using set: *Sparse_Set,
                         entity: Entity, $T: Type) -> *T #must {
    return get_component(set, entity.index, T);
}

try_get_component :: inline (using set: *Sparse_Set,
                             entity: Entity, $T: Type) -> *T #must {
    return try_get_component(set, entity.index, T);
}

contains_entity :: inline (using set: *Sparse_Set,
                           entity: Entity) -> bool #must {
    return contains_entity(set, entity.index);
}

insert_bytes :: (using set: *Sparse_Set,
                 entity_index: Entity.Index, data: *void) -> Dense_Index {
    dense_index, ok := try_get_dense_index(set, entity_index);
    if ok {
        if stride > 0 && data {
            dst := bytes.data + cast(s64) dense_index * stride;
            invoke_cleanup(on_remove, dst);
            memcpy(dst, data, stride);
        }
        return dense_index;
    }

    dense_index = cast(Dense_Index) dense.count;
    array_add(*dense, entity_index);
    if stride > 0 {
        old_count := bytes.count;
        new_count := old_count + stride;
        array_reserve(*bytes, new_count);
        bytes.count = new_count;
        if data {
            memcpy(bytes.data + old_count, data, stride);
        } else {
            memset(bytes.data + old_count, 0, stride);
        }
    }

    assign(*pages, entity_index, cast(Entity.Index) dense_index);
    return dense_index;
}

try_insert_bytes :: inline (using set: *Sparse_Set,
                            entity_index: Entity.Index, data: *void) -> bool {
    if contains_entity(set, entity_index) return false;
    insert_bytes(set, entity_index, data);
    return true;
}

remove_index :: (using set: *Sparse_Set, entity_index: Entity.Index) -> bool {
    dense_index, ok := try_get_dense_index(set, entity_index);
    if !ok return false;

    if stride > 0 {
        invoke_cleanup(on_remove, bytes.data + cast(s64) dense_index * stride);
    }

    last := dense.count - 1;
    if dense_index != cast(Dense_Index) last {
        swapped_index := dense[last];
        dense[dense_index] = swapped_index;
        assign(*pages, swapped_index, cast(Entity.Index) dense_index);

        if stride > 0 {
            memcpy(bytes.data + cast(s64) dense_index * stride,
                   bytes.data + last * stride,
                   stride);
        }
    }

    dense.count = last;
    if stride > 0 bytes.count = last * stride;

    clear_index(*pages, entity_index);
    return true;
}

get_component :: inline (using set: *Sparse_Set,
                         entity_index: Entity.Index, $T: Type) -> *T #must {
    result := try_get_component(set, entity_index, T);
    assert(result != null, "Entity index % does not have sparse component!",
           entity_index);
    return result;
}

try_get_component :: inline (using set: *Sparse_Set,
                             entity_index: Entity.Index, $T: Type) -> *T #must {
    #assert size_of(T) > 0 "Use contains_entity() for tag components; try_get_component requires a value type!";
    assert(type == type_info(T), "Sparse set type mismatch for %!",
           #run get_component_name(T));

    dense_index, ok := try_get_dense_index(set, entity_index);
    if !ok return null;
    return cast(*T) (bytes.data + cast(s64) dense_index * stride);
}

try_get_bytes :: inline (using set: *Sparse_Set,
                         entity_index: Entity.Index) -> *void #must {
    dense_index, ok := try_get_dense_index(set, entity_index);
    if !ok return null;
    if stride == 0 return null;
    return bytes.data + cast(s64) dense_index * stride;
}

try_get_dense_index :: inline (using set: *Sparse_Set,
                               entity_index: Entity.Index) -> Dense_Index, bool #must {
    value, ok := try_get(*pages, entity_index);
    if !ok return INVALID_DENSE_INDEX, false;
    return cast(Dense_Index) value, true;
}

contains_entity :: inline (using set: *Sparse_Set,
                           entity_index: Entity.Index) -> bool #must {
    return contains(*pages, entity_index);
}

get_data :: inline (using set: *Sparse_Set, $T: Type) -> [] T #must {
    #assert size_of(T) > 0;
    assert(type == type_info(T), "Sparse set type mismatch for %!",
           #run get_component_name(T));
    if dense.count == 0 return .[];
    result: [] T;
    result.data = cast(*T) bytes.data;
    result.count = dense.count;
    return result;
}

get_size :: inline (using set: *Sparse_Set) -> s64 #must {
    return dense.count;
}

get_dense_entities :: inline (using set: *Sparse_Set) -> [] Entity.Index #must {
    return dense;
}

for_expansion :: (set: *Sparse_Set, body: Code, flags: For_Flags) #expand {
    `it_index: s64;
    `it_entity_index: Entity.Index;
    `it: *void;

    for i: 0..set.dense.count - 1 {
        it_index = i;
        it_entity_index = set.dense[i];
        if set.stride > 0 {
            it = set.bytes.data + i * set.stride;
        } else {
            it = null;
        }
        #insert body;
    }
}
