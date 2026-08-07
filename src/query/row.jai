Query_Row :: struct {
    pointers: [] *void;
    fetches:  [] Query_Fetch_Slot;
}

find_required_fetch_slot :: (fetches: [] Query_Fetch_Slot,
                             $T: Type) -> s64 #must {
    #assert #run !is_tag(T) "Requires a value component; tags are filters only!";
    target :: type_info(T);
    for fetch, i: fetches {
        if !fetch.optional && fetch.type == target return i;
    }
    return -1;
}

find_optional_fetch_slot :: (fetches: [] Query_Fetch_Slot,
                             $T: Type) -> s64 #must {
    #assert #run !is_tag(T) "Requires a value component; tags are filters only!";
    target :: type_info(T);
    for fetch, i: fetches {
        if fetch.optional && fetch.type == target return i;
    }
    return -1;
}

get :: inline (using row: Query_Row, $T: Type) -> *T #must {
    slot := find_required_fetch_slot(fetches, T);
    assert(slot >= 0, "Component % is not a required fetch in this query!",
           get_component_name(T));
    ptr := pointers[slot];
    assert(ptr != null, "Required component % pointer is null!",
           get_component_name(T));
    return cast(*T) ptr;
}

get :: inline (using row: *Query_Row, $T: Type) -> *T #must {
    return get(<<row, T);
}

try_get :: inline  (using row: Query_Row, $T: Type) -> *T #must {
    slot := find_optional_fetch_slot(fetches, T);
    assert(slot >= 0, "Component % is not optional fetch in this query!",
           get_component_name(T));
    return cast(*T) pointers[slot];
}

try_get :: inline (using row: *Query_Row, $T: Type) -> *T #must {
    return try_get(<<row, T);
}
