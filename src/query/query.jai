Query :: struct {
    entities:   *Entities;
    components: *Components;
    plan:       Query_Plan;
}

make_term_infos_from_types :: (terms: [] Type) -> [] *Type_Info #must {
    if terms.count == 0 return .{};

    result: [..] *Type_Info;
    result.allocator = temp;
    for term: terms {
        array_add(*result, cast(*Type_Info) term);
    }
    return result;
}

make_term_infos_from_any :: (values: [] Any) -> [] *Type_Info #must {
    if values.count == 0 return .{};

    result: [..] *Type_Info;
    result.allocator = temp;
    for value: values {
        array_add(*result, value.type);
    }
    return result;
}

make_query :: (entities: *Entities, components: *Components,
               terms: [] *Type_Info, enable_fetch: bool,
               allocator: Allocator = .{}) -> Query #must {
    query: Query;
    query.entities = entities;
    query.components = components;
    resolved := resolve_query_allocator(allocator);
    init_query_plan(*query.plan, terms, enable_fetch, resolved);
    return query;
}


deinit :: inline (using query: *Query) {
    deinit(*plan);
}

query :: inline (entities: *Entities, components: *Components,
                 allocator: Allocator = .{}) -> Query #must {
    return make_query(entities, components, .{}, enable_fetch = true,
                      allocator = allocator);
}

query :: inline (entities: *Entities, components: *Components,
                 terms: .. Type, allocator: Allocator = .{}) -> Query #must {
    infos := make_term_infos_from_types(terms);
    validate_terms(infos, allow_optional = true);
    return make_query(entities, components, infos, enable_fetch = true,
                      allocator = allocator);
}

query :: inline (entities: *Entities, components: *Components,
                 values: .. Any, allocator: Allocator = .{}) -> Query #must {
    infos := make_term_infos_from_any(values);
    validate_terms(infos, allow_optional = true);
    return make_query(entities, components, infos, enable_fetch = true,
                      allocator = allocator);
}

Query_Entities :: struct {
    entities:   *Entities;
    components: *Components;
    plan:       Query_Plan;
}

make_query_entities :: (entities: *Entities, components: *Components,
                        terms: [] *Type_Info,
                        allocator: Allocator = .{}) -> Query_Entities #must {
    query: Query_Entities;
    query.entities = entities;
    query.components = components;
    resolved := resolve_query_allocator(allocator);
    init_query_plan(*query.plan, terms, enable_fetch = false, resolved);
    return query;
}

deinit :: inline (using query: *Query_Entities) {
    deinit(*plan);
}

query_entities :: inline (entities: *Entities, components: *Components,
                          allocator: Allocator = .{}) -> Query_Entities #must {
    return make_query_entities(entities, components, .{}, allocator = allocator);
}

query_entities :: inline (entities: *Entities, components: *Components,
                          terms: .. Type,
                          allocator: Allocator = .{}) -> Query_Entities #must {
    infos := make_term_infos_from_types(terms);
    validate_terms(infos, allow_optional = false);
    return make_query_entities(entities, components, infos, allocator = allocator);
}

query_entities :: inline (entities: *Entities, components: *Components,
                          values: .. Any,
                          allocator: Allocator = .{}) -> Query_Entities #must {
    infos := make_term_infos_from_any(values);
    validate_terms(infos, allow_optional = false);
    return make_query_entities(entities, components, infos, allocator = allocator);
}
