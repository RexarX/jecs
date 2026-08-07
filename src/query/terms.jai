Optional :: struct (T: Type) {}
With     :: struct (T: Type) {}
Without  :: struct (T: Type) {}

Query_Term_Role :: enum u8 {
    REQUIRED_FETCH;
    OPTIONAL_FETCH;
    WITH;
    WITHOUT;
}

Query_Sparse_Kind :: enum u8 {
    REQUIRED;     // entity must have this sparse component
    EXCLUDED;     // entity must not have this sparse component
    LOOKUP_ONLY;  // optional sparse fetch; presence does not filter
}

get_wrapper_inner_type :: inline (using struct_info: *Type_Info_Struct) -> Type #must {
    assert(specified_parameters.count >= 1,
           "Wrapper type is missing T parameter!");
    param := specified_parameters[0];
    assert(param.offset_into_constant_storage >= 0,
           "Wrapper T is not in constant storage!");
    type_ptr := constant_storage.data + param.offset_into_constant_storage;
    return << cast(*Type) type_ptr;
}

get_wrapper_inner_type_info :: inline (using struct_info: *Type_Info_Struct) -> *Type_Info #must {
    return cast(*Type_Info) get_wrapper_inner_type(struct_info);
}

classify_term :: (info: *Type_Info) -> Query_Term_Role, *Type_Info #must {
    if info.type == .STRUCT {
        struct_info := cast(*Type_Info_Struct) info;
        if struct_info.polymorph_source_struct {
            name := struct_info.polymorph_source_struct.name;
            inner := get_wrapper_inner_type_info(struct_info);
            if name == "Optional" return .OPTIONAL_FETCH, inner;
            if name == "With"     return .WITH, inner;
            if name == "Without"  return .WITHOUT, inner;
        }
    }

    if is_tag(info) return .WITH, info;
    return .REQUIRED_FETCH, info;
}

validate_terms :: (terms: [] *Type_Info, allow_optional: bool) {
    push_allocator(temp);

    seen: [..] *Type_Info;
    seen.allocator = temp;
    without_types: [..] *Type_Info;
    without_types.allocator = temp;
    positive_types: [..] *Type_Info;
    positive_types.allocator = temp;

    for info: terms {
        role, component := classify_term(info);

        if role == .OPTIONAL_FETCH {
            assert(allow_optional, "Optional is not allowed here!");
            assert(!is_tag(component), "Optional cannot wrap a tag component %!",
                   component);
        }
        if role == .REQUIRED_FETCH {
            assert(!is_tag(component), "Cannot fetch a tag component %; use it as a filter!",
                   component);
        }

        for seen_info: seen {
            assert(seen_info != component, "Duplicate query term for component type %!",
                   component);
        }
        array_add(*seen, component);

        if role == .WITHOUT {
            array_add(*without_types, component);
        } else {
            array_add(*positive_types, component);
        }
    }

    for w: without_types {
        for p: positive_types {
            assert(w != p, "Component % cannot be both required/optional/with and without!",
                   w);
        }
    }
}
