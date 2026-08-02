#import "Basic";
#import "Hash";

Archetype_Id :: struct {
    types:     [..] *Type_Info;
    hash:      u64;

    allocator: Allocator;
}

make_archetype_id :: (values: .. Any,
                      allocator: Allocator = .{}) -> Archetype_Id #must {
    assert(values.count > 0, "Requires at least one component value!");

    push_allocator(temp);

    types: [..] *Type_Info;
    types.allocator = temp;
    for values array_add(*types, it.type);
    return build_archetype_id(types, allocator);
}

init :: inline (id: *Archetype_Id, allocator: Allocator = .{}) {
    id.allocator = resolve_allocator(id, allocator);
    id.types.allocator = id.allocator;
}

reset :: inline (using id: *Archetype_Id) {
    array_reset(*types);
    hash = 0;
}

clear :: inline (using id: *Archetype_Id) {
    array_reset_keeping_memory(*types);
    hash = 0;
}

clone :: (id: Archetype_Id) -> Archetype_Id #must {
    result: Archetype_Id;
    init(*result, id.allocator);
    for id.types array_add(*result.types, it);
    result.hash = id.hash;
    return result;
}

with :: inline (id: *Archetype_Id, $T: Type) {
    with_type(id, type_info(T));
}

with_type :: inline (id: *Archetype_Id, type_info_ptr: *Type_Info) {
    if contains_component(id, type_info_ptr) return;

    array_add(*id.types, type_info_ptr);
    sort_and_deduplicate(id);
}

without :: inline (id: *Archetype_Id, $T: Type) {
    without_type(id, type_info(T));
}

without_type :: (id: *Archetype_Id, type_info_ptr: *Type_Info) {
    if !contains_component(id, type_info_ptr) return;

    new_count: s64 = 0;
    for id.types {
        if it != type_info_ptr {
            id.types[new_count] = it;
            new_count += 1;
        }
    }
    id.types.count = new_count;
    get_hash(id);
}

contains_component :: inline (using id: *Archetype_Id, $T: Type) -> bool #must {
    return contains_component(id, type_info(T));
}

contains_component :: (using id: *Archetype_Id,
                       type_info_ptr: *Type_Info) -> bool #must {
    for types {
        if it == type_info_ptr return true;
    }
    return false;
}

is_empty :: inline (using id: *Archetype_Id) -> bool #must {
    return types.count == 0;
}

get_hash :: (using id: *Archetype_Id) {
    seed := FNV_64_OFFSET_BIAS;
    for types {
        seed = fnv1a_hash(cast(u64) it, seed);
    }
    hash = seed;
}

#scope_module;

build_archetype_id :: (types: [] *Type_Info,
                       allocator: Allocator = .{}) -> Archetype_Id #must {
    id: Archetype_Id;
    init(*id, allocator);
    for types array_add(*id.types, it);
    sort_and_deduplicate(*id);
    return id;
}

sort_and_deduplicate :: (using id: *Archetype_Id) {
    if types.count <= 1 {
        get_hash(id);
        return;
    }

    for i: 1..types.count - 1 {
        key := types[i];
        j := i - 1;
        while j >= 0 && cast(u64) types[j] > cast(u64) key {
            types[j + 1] = types[j];
            j -= 1;
        }
        types[j + 1] = key;
    }

    write := 1;
    for i: 1..types.count - 1 {
        if types[i] != types[write - 1] {
            types[write] = types[i];
            write += 1;
        }
    }

    types.count = write;
    get_hash(id);
}
