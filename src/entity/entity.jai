#import "Hash";

Entity :: struct {
    Index :: u32;
    Generation :: u32;
    INVALID_INDEX: Index : 0xFFFFFFFF;
    INVALID_GENERATION: Generation : 0xFFFFFFFF;

    index: Index = INVALID_INDEX;
    generation: Generation = INVALID_GENERATION;
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
