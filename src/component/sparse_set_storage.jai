#import "Basic";
#import "Hash_Table";

Sparse_Set_Storage :: struct {
    storages: Table(*Type_Info, Sparse_Storage_Entry);
    allocator: Allocator;
}

init :: inline (storage: *Sparse_Set_Storage, allocator: Allocator = .{}) {
    storage.allocator = resolve_allocator(storage, allocator);

    init(*storage.storages,, storage.allocator);
    storage.storages.allocator = storage.allocator;
}

reset :: (using storage: *Sparse_Set_Storage) {
    for entry, type_info_ptr: storages {
        entry_ptr := table_find_pointer(*storages, type_info_ptr);
        if entry_ptr free_entry(entry_ptr, allocator);
    }
    table_reset(*storages);
}

clear :: (using storage: *Sparse_Set_Storage) {
    for entry, type_info_ptr: storages {
        entry_ptr := table_find_pointer(*storages, type_info_ptr);
        if entry_ptr clear_entry(entry_ptr);
    }
}

try_find_set :: inline (using storage: *Sparse_Set_Storage, $T: Type) -> *Sparse_Set(T) #must {
    entry := table_find_pointer(*storages, type_info(T));
    if !entry return null;
    return as_sparse_set(T, entry);
}

assign :: inline (using storage: *Sparse_Set_Storage, entity: Entity, $T: Type, value: T) {
    set := ensure_set(storage, T);
    assign(set, entity, value);
}

try_assign :: inline (using storage: *Sparse_Set_Storage, entity: Entity, $T: Type, value: T) -> bool {
    set := ensure_set(storage, T);
    return try_assign(set, entity, value);
}

erase :: inline (using storage: *Sparse_Set_Storage, entity: Entity, $T: Type) {
    entry := table_find_pointer(*storages, type_info(T));
    if !entry return;
    erase(as_sparse_set(T, entry), entity);
}

try_erase :: inline (using storage: *Sparse_Set_Storage, entity: Entity, $T: Type) -> bool {
    entry := table_find_pointer(*storages, type_info(T));
    if !entry return false;
    return try_erase(as_sparse_set(T, entry), entity);
}

get :: inline (using storage: *Sparse_Set_Storage, entity: Entity, $T: Type) -> *T #must {
    set := try_find_set(storage, T);
    assert(set != null, "Sparse storage does not exist for % component type!", component_name(T));
    return get(set, entity);
}

try_get :: inline (using storage: *Sparse_Set_Storage, entity: Entity, $T: Type) -> *T #must {
    entry := table_find_pointer(*storages, type_info(T));
    if !entry return null;
    return try_get(as_sparse_set(T, entry), entity);
}

contains :: inline (using storage: *Sparse_Set_Storage, entity: Entity, $T: Type) -> bool #must {
    entry := table_find_pointer(*storages, type_info(T));
    if !entry return false;
    return contains(as_sparse_set(T, entry), entity);
}

try_remove_entity :: (using storage: *Sparse_Set_Storage, entity: Entity) -> bool {
    removed := false;
    for entry, type_info_ptr: storages {
        entry_ptr := table_find_pointer(*storages, type_info_ptr);
        if entry_ptr && try_remove_entry(entry_ptr, entity) {
            removed = true;
        }
    }
    return removed;
}

ensure_set :: (using storage: *Sparse_Set_Storage, $T: Type) -> *Sparse_Set(T) #must {
    type_info_ptr := type_info(T);
    entry := table_find_pointer(*storages, type_info_ptr);
    if entry return as_sparse_set(T, entry);

    new_entry := make_sparse_storage_entry(T, allocator);
    table_add(*storages, type_info_ptr, new_entry);
    entry_ptr := table_find_pointer(*storages, type_info_ptr);
    assert(entry_ptr != null, "Failed to create sparse storage for % component type!", component_name(T));
    return as_sparse_set(T, entry_ptr);
}

Sparse_Storage_Entry :: struct {
    storage: *void;
    clear_fn: Sparse_Storage_Clear_Fn;
    reset_fn: Sparse_Storage_Reset_Fn;
    try_remove_fn: Sparse_Storage_Try_Remove_Fn;
    contains_fn: Sparse_Storage_Contains_Fn;
    size_fn: Sparse_Storage_Size_Fn;
}

Sparse_Storage_Clear_Fn :: #type (ptr: *void);
Sparse_Storage_Reset_Fn :: #type (ptr: *void);
Sparse_Storage_Try_Remove_Fn :: #type (ptr: *void, entity: Entity) -> bool;
Sparse_Storage_Contains_Fn :: #type (ptr: *void, entity: Entity) -> bool;
Sparse_Storage_Size_Fn :: #type (ptr: *void) -> s64;

make_sparse_storage_entry :: ($T: Type, allocator: Allocator) -> Sparse_Storage_Entry #must {
    set := New(Sparse_Set(T),, allocator);
    init(set, allocator);

    clear_erased :: (ptr: *void) {
        clear(cast(*Sparse_Set(T)) ptr);
    }

    reset_erased :: (ptr: *void) {
        reset(cast(*Sparse_Set(T)) ptr);
    }

    entry: Sparse_Storage_Entry;
    entry.storage = set;
    entry.clear_fn = clear_erased;
    entry.reset_fn = reset_erased;
    entry.try_remove_fn = (ptr: *void, entity: Entity) -> bool {
        return try_erase(cast(*Sparse_Set(T)) ptr, entity);
    };
    entry.contains_fn = (ptr: *void, entity: Entity) -> bool {
        return contains(cast(*Sparse_Set(T)) ptr, entity);
    };
    entry.size_fn = (ptr: *void) -> s64 {
        return size(cast(*Sparse_Set(T)) ptr);
    };
    return entry;
}

free_entry :: (entry: *Sparse_Storage_Entry, allocator: Allocator) {
    if entry.storage {
        reset_entry(entry);
        free(entry.storage,, allocator);
        entry.* = .{};
    }
}

reset_entry :: inline (entry: *Sparse_Storage_Entry) {
    if entry.reset_fn entry.reset_fn(entry.storage);
}

clear_entry :: inline (entry: *Sparse_Storage_Entry) {
    if entry.clear_fn entry.clear_fn(entry.storage);
}

try_remove_entry :: inline (entry: *Sparse_Storage_Entry, entity: Entity) -> bool {
    if !entry.try_remove_fn return false;
    return entry.try_remove_fn(entry.storage, entity);
}

contains_entry :: inline (entry: *Sparse_Storage_Entry, entity: Entity) -> bool #must {
    if !entry.contains_fn return false;
    return entry.contains_fn(entry.storage, entity);
}

as_sparse_set :: inline ($T: Type, entry: *Sparse_Storage_Entry) -> *Sparse_Set(T) #must {
    return cast(*Sparse_Set(T)) entry.storage;
}
