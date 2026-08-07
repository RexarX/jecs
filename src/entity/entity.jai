#import "Hash";

#run {
    entity_validate_id_type(INDEX_TYPE);
    entity_validate_id_type(GENERATION_TYPE);
}

#if size_of(INDEX_TYPE) == 2 {
    ENTITY_INVALID_INDEX :: cast(INDEX_TYPE) 0xFFFF;
} else #if size_of(INDEX_TYPE) == 4 {
    ENTITY_INVALID_INDEX :: cast(INDEX_TYPE) 0xFFFF_FFFF;
} else {
    ENTITY_INVALID_INDEX :: cast(INDEX_TYPE) 0xFFFF_FFFF_FFFF_FFFF;
}

#if size_of(GENERATION_TYPE) == 2 {
    ENTITY_INVALID_GENERATION :: cast(GENERATION_TYPE) 0xFFFF;
    ENTITY_ALIVE_BIT          :: cast(GENERATION_TYPE) 0x8000;
    ENTITY_COUNTER_MASK       :: cast(GENERATION_TYPE) 0x7FFF;
    ENTITY_FIRST_ALIVE_GEN    :: cast(GENERATION_TYPE) 0x8001;
} else #if size_of(GENERATION_TYPE) == 4 {
    ENTITY_INVALID_GENERATION :: cast(GENERATION_TYPE) 0xFFFF_FFFF;
    ENTITY_ALIVE_BIT          :: cast(GENERATION_TYPE) 0x8000_0000;
    ENTITY_COUNTER_MASK       :: cast(GENERATION_TYPE) 0x7FFF_FFFF;
    ENTITY_FIRST_ALIVE_GEN    :: cast(GENERATION_TYPE) 0x8000_0001;
} else {
    ENTITY_INVALID_GENERATION :: cast(GENERATION_TYPE) 0xFFFF_FFFF_FFFF_FFFF;
    ENTITY_ALIVE_BIT          :: cast(GENERATION_TYPE) 0x8000_0000_0000_0000;
    ENTITY_COUNTER_MASK       :: cast(GENERATION_TYPE) 0x7FFF_FFFF_FFFF_FFFF;
    ENTITY_FIRST_ALIVE_GEN    :: cast(GENERATION_TYPE) 0x8000_0000_0000_0001;
}

Entity :: struct {
    Index      :: #type,isa INDEX_TYPE;
    Generation :: #type,isa GENERATION_TYPE;

    INVALID_INDEX          :: cast(Index) ENTITY_INVALID_INDEX;
    INVALID_GENERATION     :: cast(Generation) ENTITY_INVALID_GENERATION;
    ALIVE_BIT              :: cast(Generation) ENTITY_ALIVE_BIT;
    COUNTER_MASK           :: cast(Generation) ENTITY_COUNTER_MASK;
    FIRST_ALIVE_GENERATION :: cast(Generation) ENTITY_FIRST_ALIVE_GEN;

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

// Generation encoding: top bit = alive, remaining bits = monotonic counter.
// Reserved handles carry the future alive generation; validate succeeds only once
// the slot has been materialized (create_entity or flush_reserved_entities).

is_alive_generation :: inline (generation: Entity.Generation) -> bool #must {
    return (generation & Entity.ALIVE_BIT) != 0
           && generation != Entity.INVALID_GENERATION;
}

next_generation :: (generation: Entity.Generation,
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
    return get_hash(cast(u32) generation, get_hash(cast(u32) index));
}

#scope_file;

entity_validate_id_type :: ($T: Type) #compile_time {
    info :: type_info(T);
    #assert info.type == .INTEGER
        "Entity index/generation types must be unsigned integers (u16, u32, or u64)!";
    integer_info :: cast(*Type_Info_Integer) info;
    #assert !integer_info.signed
        "Entity index/generation types must be unsigned integers (u16, u32, or u64)!";
    #assert size_of(T) == 2 || size_of(T) == 4 || size_of(T) == 8
        "Entity index/generation types must be u16, u32, or u64!";
}
