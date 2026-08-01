#import "Basic";

Dense_Index :: #type,isa Entity.Index;
INVALID_DENSE_INDEX :: cast(Dense_Index) Entity.INVALID_INDEX;

Sparse_Set :: struct (T: Type) {
    pages: Paged_Sparse_Array;
    dense: [..] Entity.Index;
    #if size_of(T) > 0 {
        values: [..] T;
    }
    allocator: Allocator;
}

init :: inline (set: *Sparse_Set($T), allocator: Allocator = .{}) {
    set.allocator = resolve_allocator(set, allocator);

    init(*set.pages, set.allocator);
    set.dense.allocator = set.allocator;
    #if size_of(T) > 0 {
        set.values.allocator = set.allocator;
    }
}

reset :: inline (using set: *Sparse_Set($T)) {
    reset(*pages);
    array_reset(*dense);
    #if size_of(T) > 0 {
        array_reset(*values);
    }
}

clear :: inline (using set: *Sparse_Set($T)) {
    clear(*pages);
    array_reset_keeping_memory(*dense);
    #if size_of(T) > 0 {
        array_reset_keeping_memory(*values);
    }
}

reserve :: (using set: *Sparse_Set($T), count: s64) {
    array_reserve(*dense, count);
    #if size_of(T) > 0 {
        array_reserve(*values, count);
    }

    if count > 0 {
        last_index := cast(Entity.Index) (count - 1);
        page_i := cast(s64) last_index >> DEFAULT_PAGED_SPARSE_PAGE_BITS;
        ensure_page_capacity(*pages, page_i);
    }
}

assign :: inline (using set: *Sparse_Set($T), entity: Entity, value: T) {
    insert(set, entity.index, value);
}

try_assign :: inline (using set: *Sparse_Set($T), entity: Entity, value: T) -> bool {
    return try_insert(set, entity.index, value);
}

erase :: inline (using set: *Sparse_Set($T), entity: Entity) {
    remove_index(set, entity.index);
}

try_erase :: inline (using set: *Sparse_Set($T), entity: Entity) -> bool {
    return remove_index(set, entity.index);
}

get :: inline (using set: *Sparse_Set($T), entity: Entity) -> *T #must {
    return get(set, entity.index);
}

try_get :: inline (using set: *Sparse_Set($T), entity: Entity) -> *T #must {
    return try_get(set, entity.index);
}

contains :: inline (using set: *Sparse_Set($T), entity: Entity) -> bool #must {
    return contains(set, entity.index);
}

insert :: (using set: *Sparse_Set($T), entity_index: Entity.Index, value: T) -> Dense_Index {
    dense_index, ok := try_get_dense_index(set, entity_index);
    if ok {
        #if size_of(T) > 0 {
            values[dense_index] = value;
        }
        return dense_index;
    }

    dense_index = cast(Dense_Index) dense.count;
    array_add(*dense, entity_index);
    #if size_of(T) > 0 {
        array_add(*values, value);
    }

    assign(*pages, entity_index, cast(Entity.Index) dense_index);
    return dense_index;
}

try_insert :: inline (using set: *Sparse_Set($T), entity_index: Entity.Index, value: T) -> bool {
    if contains(set, entity_index) return false;
    insert(set, entity_index, value);
    return true;
}

remove_index :: (using set: *Sparse_Set($T), entity_index: Entity.Index) -> bool {
    dense_index, ok := try_get_dense_index(set, entity_index);
    if !ok return false;

    last := dense.count - 1;
    if dense_index != cast(Dense_Index) last {
        swapped_index := dense[last];
        dense[dense_index] = swapped_index;
        assign(*pages, swapped_index, cast(Entity.Index) dense_index);

        #if size_of(T) > 0 {
            // Large T: memcpy avoids a full struct assignment temporary.
            #if size_of(T) > 16 {
                memcpy(*values[dense_index], *values[last], size_of(T));
            } else {
                values[dense_index] = values[last];
            }
        }
    }

    dense.count = last;
    #if size_of(T) > 0 {
        values.count = last;
    }

    clear_index(*pages, entity_index);
    return true;
}

get :: inline (using set: *Sparse_Set($T), entity_index: Entity.Index) -> *T #must {
    result := try_get(set, entity_index);
    assert(result != null, "Entity index % does not have sparse component!", entity_index);
    return result;
}

try_get :: inline (using set: *Sparse_Set($T), entity_index: Entity.Index) -> *T #must {
    dense_index, ok := try_get_dense_index(set, entity_index);
    if !ok return null;
    #if size_of(T) == 0 {
        return null;
    } else {
        return *values[dense_index];
    }
}

try_get_dense_index :: inline (using set: *Sparse_Set($T), entity_index: Entity.Index) -> Dense_Index, bool #must {
    value, ok := try_get(*pages, entity_index);
    if !ok return INVALID_DENSE_INDEX, false;
    return cast(Dense_Index) value, true;
}

contains :: inline (using set: *Sparse_Set($T), entity_index: Entity.Index) -> bool #must {
    return contains(*pages, entity_index);
}

data :: inline (using set: *Sparse_Set($T)) -> [] T #must {
    #if size_of(T) > 0 {
        return values;
    } else {
        return .[];
    }
}

size :: inline (using set: *Sparse_Set($T)) -> s64 #must {
    return dense.count;
}

get_dense_entities :: inline (using set: *Sparse_Set($T)) -> [] Entity.Index #must {
    return dense;
}

for_expansion :: (set: *Sparse_Set($T), body: Code, flags: For_Flags) #expand {
    `it_index: s64;
    `it_entity_index: Entity.Index;
    #if size_of(T) > 0 {
        `it: T;
    }

    #if size_of(T) > 0 {
        for i: 0..set.dense.count - 1 {
            it_index = i;
            it_entity_index = set.dense[i];
            it = set.values[i];
            #insert body;
        }
    } else {
        for i: 0..set.dense.count - 1 {
            it_index = i;
            it_entity_index = set.dense[i];
            #insert body;
        }
    }
}
