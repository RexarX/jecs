#import "Hash";

Entity :: struct {
    // Storage indices (Dense_Index, Row_Index, etc.) derive from Index — change it here to widen them all.
    Index :: #type,isa u32;
    Generation :: #type,isa u32;
    INVALID_INDEX :: cast(Index) 0xFFFFFFFF;
    INVALID_GENERATION :: cast(Generation) 0xFFFFFFFF;

    index := INVALID_INDEX;
    generation := INVALID_GENERATION;
}

INVALID_ENTITY :: Entity.{};

operator == :: inline (lhs: Entity, rhs: Entity) -> bool {
    return lhs.index == rhs.index && lhs.generation == rhs.generation;
}

is_valid :: inline (entity: Entity) -> bool {
    return entity != INVALID_ENTITY;
}

get_hash :: inline (entity: Entity) -> u32 {
    if !is_valid(entity) return 0;
    return get_hash(entity.generation, get_hash(entity.index));
}
