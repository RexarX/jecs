#import "Basic";
#import "Hash_Table";

Row_Index    :: #type,isa Entity.Index;
Column_Index :: #type,isa Entity.Index;
INVALID_ROW  :: cast(Row_Index) Entity.INVALID_INDEX;

Archetype :: struct {
    id:            Archetype_Id;

    entities:      [..] Entity;
    entity_to_row: Entity_Index_Map;

    columns:       [..]  Column;
    column_map:    Table(*Type_Info, Column_Index);

    allocator:     Allocator;
}

init :: (archetype: *Archetype, id: Archetype_Id, allocator: Allocator = .{}) {
    archetype.allocator = resolve_allocator(archetype, allocator);

    archetype.id = clone(id);
    archetype.entities.allocator = archetype.allocator;
    init(*archetype.entity_to_row, archetype.allocator);
    archetype.columns.allocator = archetype.allocator;
    init(*archetype.column_map,, archetype.allocator);
    archetype.column_map.allocator = archetype.allocator;

    for type_info_ptr: archetype.id.types {
        column_index := cast(Column_Index) archetype.columns.count;
        col: Column;
        init(*col, type_info_ptr, archetype.allocator);
        array_add(*archetype.columns, col);
        table_add(*archetype.column_map, type_info_ptr, column_index);
    }
}

deinit :: (using archetype: *Archetype) {
    for * columns reset(it);
    array_reset(*columns);
    reset(*entity_to_row);
    array_reset(*entities);
    deinit(*column_map);
    reset(*id);
}

reset :: (using archetype: *Archetype) {
    for * columns reset(it);
    reset(*entity_to_row);
    array_reset(*entities);
    deinit(*column_map);
    init(*column_map,, allocator);
    column_map.allocator = allocator;
}

clear :: (using archetype: *Archetype) {
    for * columns clear(it);
    clear(*entity_to_row);
    array_reset_keeping_memory(*entities);
}

allocate_row :: (using archetype: *Archetype, entity: Entity) -> Row_Index {
    assert(!contains_entity(archetype, entity), "Entity % is already in archetype!",
           entity);

    row := cast(Row_Index) entities.count;
    array_add(*entities, entity);
    assign(*entity_to_row, entity.index, cast(Sparse_Index) row);

    for * columns push_back_default(it);
    return row;
}

remove_entity :: (using archetype: *Archetype, entity: Entity) -> Entity {
    assert(contains_entity(archetype, entity), "Entity % is not in archetype!",
           entity);

    row := cast(Row_Index) get(*entity_to_row, entity.index);
    last_row := cast(Row_Index) (entities.count - 1);
    swapped_entity := Entity.{};

    if row != last_row {
        swapped_entity = entities[last_row];
        entities[row] = swapped_entity;
        assign(*entity_to_row, swapped_entity.index, cast(Sparse_Index) row);

        for * columns move_row_from_last(it, row, last_row);
    }

    entities.count -= 1;
    for * columns pop_back(it);
    clear_index(*entity_to_row, entity.index);
    return swapped_entity;
}

contains_entity :: inline (using archetype: *Archetype,
                           entity: Entity) -> bool #must {
    return contains(*entity_to_row, entity.index);
}

assign_component :: inline (using archetype: *Archetype,
                            entity: Entity, value: $T) {
    try_assign_component(archetype, entity, value);
}

try_assign_component :: inline (using archetype: *Archetype,
                         entity: Entity, value: $T) -> bool {
    return try_assign_component_bytes(archetype, entity,
                                      type_info(T), xx *value);
}

assign_component_bytes :: inline (using archetype: *Archetype, entity: Entity,
                                  type_info_ptr: *Type_Info, data: *void) {
    try_assign_component_bytes(archetype, entity, type_info_ptr, data);
}

try_assign_component_bytes :: (using archetype: *Archetype, entity: Entity,
                               type_info_ptr: *Type_Info, data: *void) -> bool {
    col := try_get_column(archetype, type_info_ptr);
    if col == null return false;

    row := cast(Row_Index) get(*entity_to_row, entity.index);
    if col.stride == 0 return true;
    if data {
        memcpy(get_component(col, row), data, col.stride);
    } else {
        memset(get_component(col, row), 0, col.stride);
    }
    return true;
}

get_component :: inline (using archetype: *Archetype,
                         entity: Entity, $T: Type) -> *T #must {
    result := try_get_component(archetype, entity, T);
    assert(result != null, "Entity % does not have % component in archetype!",
           entity, #run get_component_name(T));
    return result;
}

try_get_component :: (using archetype: *Archetype,
                      entity: Entity, $T: Type) -> *T #must {
    if !contains_entity(archetype, entity) return null;

    col := try_get_column(archetype, type_info(T));
    if !col return null;

    row := cast(Row_Index) get(*entity_to_row, entity.index);
    return get_component(col, row, T);
}

get_component_column :: (using archetype: *Archetype, $T: Type) -> [] T #must {
    col := try_get_column(archetype, type_info(T));
    if !col return .[];

    if col.stride == 0 return .[];
    count := entities.count;
    if count == 0 return .[];

    result: [] T;
    result.data = cast(*T) col.bytes.data;
    result.count = count;
    return result;
}

try_get_column :: inline (using archetype: *Archetype,
                   type_info_ptr: *Type_Info) -> *Column #must {
    col_index, found := table_find(*column_map, type_info_ptr);
    if !found return null;
    return *columns[col_index];
}

has_column :: inline (using archetype: *Archetype, $T: Type) -> bool #must {
    return has_column(archetype, type_info(T));
}

has_column :: inline (using archetype: *Archetype,
                      type_info_ptr: *Type_Info) -> bool #must {
    _, found := table_find(*column_map, type_info_ptr);
    return found;
}

get_entity_count :: inline (using archetype: *Archetype) -> s64 #must {
    return entities.count;
}
