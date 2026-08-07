#import "Basic";
#import "Hash_Table";

Sparse_Set_Storage :: struct {
    storages:  Table(*Type_Info, Sparse_Storage_Entry);
    metadata:  *Table(*Type_Info, Component_Metadata);

    allocator: Allocator;
}

init :: inline (storage: *Sparse_Set_Storage, allocator: Allocator = .{}) {
    storage.allocator = resolve_allocator(storage, allocator);

    init(*storage.storages,, storage.allocator);
    storage.storages.allocator = storage.allocator;
}

deinit :: (using storage: *Sparse_Set_Storage) {
    for entry, type_info_ptr: storages {
        entry_ptr := table_find_pointer(*storages, type_info_ptr);
        if entry_ptr free_entry(entry_ptr, allocator);
    }
    deinit(*storages);
}

reset :: (using storage: *Sparse_Set_Storage) {
    for entry, type_info_ptr: storages {
        entry_ptr := table_find_pointer(*storages, type_info_ptr);
        if entry_ptr && entry_ptr.storage reset(entry_ptr.storage);
    }
}

clear :: (using storage: *Sparse_Set_Storage) {
    for entry, type_info_ptr: storages {
        entry_ptr := table_find_pointer(*storages, type_info_ptr);
        if entry_ptr clear_entry(entry_ptr);
    }
}

try_find_set :: inline (using storage: *Sparse_Set_Storage,
                        type_info_ptr: *Type_Info) -> *Sparse_Set #must {
    entry := table_find_pointer(*storages, type_info_ptr);
    if !entry return null;
    return as_sparse_set(entry);
}

try_find_set :: inline (using storage: *Sparse_Set_Storage,
                        $T: Type) -> *Sparse_Set #must {
    return try_find_set(storage, type_info(T));
}

assign_component :: inline (using storage: *Sparse_Set_Storage,
                            entity: Entity, value: $T) {
    set := ensure_set(storage, T);
    assign_component(set, entity, value);
}

try_assign_component :: inline (using storage: *Sparse_Set_Storage,
                                entity: Entity, value: $T) -> bool {
    set := ensure_set(storage, T);
    return try_assign_component(set, entity, value);
}

assign_component_bytes :: inline (using storage: *Sparse_Set_Storage,
                                  entity: Entity, type_info_ptr: *Type_Info,
                                  data: *void) {
    set := ensure_set(storage, type_info_ptr);
    assign_component_bytes(set, entity, data);
}

try_assign_component_bytes :: inline (using storage: *Sparse_Set_Storage,
                                      entity: Entity, type_info_ptr: *Type_Info,
                                      data: *void) -> bool {
    set := ensure_set(storage, type_info_ptr);
    return try_assign_component_bytes(set, entity, data);
}

remove_component :: inline (using storage: *Sparse_Set_Storage,
                            entity: Entity, $T: Type) {
    remove_component(storage, entity, type_info(T));
}

remove_component :: inline (using storage: *Sparse_Set_Storage,
                            entity: Entity, type_info_ptr: *Type_Info) {
    entry := table_find_pointer(*storages, type_info_ptr);
    if !entry return;
    erase_entity(as_sparse_set(entry), entity);
}

try_remove_component :: inline (using storage: *Sparse_Set_Storage,
                                entity: Entity, $T: Type) -> bool {
    return try_remove_component(storage, entity, type_info(T));
}

try_remove_component :: inline (using storage: *Sparse_Set_Storage,
                                entity: Entity,
                                type_info_ptr: *Type_Info) -> bool {
    entry := table_find_pointer(*storages, type_info_ptr);
    if !entry return false;
    return try_erase_entity(as_sparse_set(entry), entity);
}

get_component :: inline (using storage: *Sparse_Set_Storage,
                         entity: Entity, $T: Type) -> *T #must {
    #assert #run !is_tag(T) "Use has_component() for tag components; get_component() requires a value type!";
    set := try_find_set(storage, T);
    assert(set != null, "Sparse storage does not exist for % component type!",
           #run get_component_name(T));
    return get_component(set, entity, T);
}

try_get_component :: inline (using storage: *Sparse_Set_Storage,
                             entity: Entity, $T: Type) -> *T #must {
    #assert #run !is_tag(T) "Use has_component() for tag components; try_get_component() requires a value type!";
    entry := table_find_pointer(*storages, type_info(T));
    if !entry return null;
    return try_get_component(as_sparse_set(entry), entity, T);
}

has_component :: inline (using storage: *Sparse_Set_Storage,
                         entity: Entity, $T: Type) -> bool #must {
    return has_component(storage, entity, type_info(T));
}

has_component :: inline (using storage: *Sparse_Set_Storage, entity: Entity,
                         type_info_ptr: *Type_Info) -> bool #must {
    entry := table_find_pointer(*storages, type_info_ptr);
    if !entry return false;
    return contains_entity(as_sparse_set(entry), entity);
}

try_remove_entity :: (using storage: *Sparse_Set_Storage,
                      entity: Entity) -> bool {
    removed := false;
    for entry, type_info_ptr: storages {
        entry_ptr := table_find_pointer(*storages, type_info_ptr);
        if entry_ptr && try_remove_entry(entry_ptr, entity) {
            removed = true;
        }
    }
    return removed;
}

ensure_set :: inline (using storage: *Sparse_Set_Storage,
               $T: Type) -> *Sparse_Set #must {
    return ensure_set(storage, type_info(T));
}

ensure_set :: (using storage: *Sparse_Set_Storage,
               type_info_ptr: *Type_Info) -> *Sparse_Set #must {
    entry := table_find_pointer(*storages, type_info_ptr);
    if entry return as_sparse_set(entry);

    new_entry := make_sparse_storage_entry(storage, type_info_ptr, allocator);
    table_add(*storages, type_info_ptr, new_entry);
    entry_ptr := table_find_pointer(*storages, type_info_ptr);
    assert(entry_ptr != null, "Failed to create sparse storage for type %!",
           type_info_ptr);
    return as_sparse_set(entry_ptr);
}

Sparse_Storage_Entry :: struct {
    storage:    *Sparse_Set;
    generation: u64; // bumps when storage pointer created/replaced or reset/clear
}

get_sparse_generation :: (using storage: *Sparse_Set_Storage,
                          type_info_ptr: *Type_Info) -> u64 #must {
    entry := table_find_pointer(*storages, type_info_ptr);
    if !entry return 0;
    return entry.generation;
}

lookup_on_remove :: inline (using storage: *Sparse_Set_Storage,
                            type_info_ptr: *Type_Info) -> Component_Cleanup_Proc #must {
    if !metadata return null;
    meta, found := table_find(metadata, type_info_ptr);
    if !found return null;
    return meta.on_remove;
}

make_sparse_storage_entry :: inline (storage: *Sparse_Set_Storage,
                              type_info_ptr: *Type_Info,
                              allocator: Allocator) -> Sparse_Storage_Entry #must {
    set := New(Sparse_Set,, allocator);
    init(set, type_info_ptr, allocator, lookup_on_remove(storage, type_info_ptr));
    return .{storage = set, generation = 1};
}

free_entry :: (entry: *Sparse_Storage_Entry, allocator: Allocator) {
    if entry.storage {
        deinit(entry.storage);
        free(entry.storage,, allocator);
        entry.* = .{};
    }
}

clear_entry :: inline (entry: *Sparse_Storage_Entry) {
    if entry.storage clear(entry.storage);
}

try_remove_entry :: inline (entry: *Sparse_Storage_Entry,
                            entity: Entity) -> bool {
    if !entry.storage return false;
    return try_erase_entity(entry.storage, entity);
}

as_sparse_set :: inline (entry: *Sparse_Storage_Entry) -> *Sparse_Set #must {
    return entry.storage;
}
