#import "Hash";

Entity :: struct {
    Index      :: #type,isa u32;
    Generation :: #type,isa u32;

    INVALID_INDEX          :: cast(Index) 0xFFFF_FFFF;
    INVALID_GENERATION     :: cast(Generation) 0xFFFF_FFFF; // COUNTER_MASK | ALIVE_BIT — unreachable
    ALIVE_BIT              :: 0x8000_0000;
    COUNTER_MASK           :: 0x7FFF_FFFF;
    FIRST_ALIVE_GENERATION :: cast(Generation)(1 | ALIVE_BIT); // next_generation(0)

    index      := INVALID_INDEX;
    generation := INVALID_GENERATION;
}

INVALID_ENTITY :: Entity.{};

operator == :: inline (lhs: Entity, rhs: Entity) -> bool #must {
    return lhs.index == rhs.index && lhs.generation == rhs.generation;
}

is_valid :: inline (using entity: Entity) -> bool #must {
    return entity.index != Entity.INVALID_INDEX
           && entity.generation != Entity.INVALID_GENERATION;
}

// Generation encoding: top bit = alive, low 31 bits = monotonic counter.
// Reserved handles carry the future alive generation; validate succeeds only once
// the slot has been materialized (create_entity or flush_reserved_entities).

is_alive_generation :: inline (generation: Entity.Generation) -> bool #must {
    return (generation & Entity.ALIVE_BIT) != 0
           && generation != Entity.INVALID_GENERATION;
}

next_generation :: inline (generation: Entity.Generation,
                           alive := true) -> Entity.Generation #must {
    counter: Entity.Generation = generation & Entity.COUNTER_MASK;
    if alive {
        return counter | Entity.ALIVE_BIT;
    }

    if counter == Entity.COUNTER_MASK {
        counter = 0;
    } else {
        counter = counter + 1;
    }
    return counter;
}

get_hash :: inline (using entity: Entity) -> u32 #must {
    if !is_valid(entity) return 0;
    return get_hash(generation, get_hash(index));
}
