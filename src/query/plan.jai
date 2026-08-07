#import "Atomics";

Query_Fetch_Slot :: struct {
    type:        *Type_Info;
    optional:    bool;
    is_sparse:   bool;
    sparse_slot: s64;
}

Query_Driver_State :: struct {
    use_sparse_driver:  bool = false;
    driver_sparse_slot: s64  = -1;
}

Query_Filter_Match :: struct {
    matched_arch:    [..] Archetype_Index;
    arch_to_slot:    [..] s32;
    catalog_version: u64 = 0xFFFF_FFFF_FFFF_FFFF;

    refcount:        s64; // atomic
    retired:         s64; // atomic 0/1

    allocator:       Allocator;
}

Query_Plan :: struct {
    terms:              [] *Type_Info;

    req_arch:           [] *Type_Info; // sorted
    excl_arch:          [] *Type_Info; // sorted

    sparse_types:       [] *Type_Info;
    sparse_kinds:       [] Query_Sparse_Kind;
    fetches:            [] Query_Fetch_Slot;
    enable_fetch:       bool;
    has_sparse_filters: bool;
    needs_arch_match:   bool;

    filter_match:       *Query_Filter_Match; // null when needs_arch_match == false
    snapshot:           *Query_Snapshot;     // atomic pointer; never null after init
    rebuild_lock:       s64;
    retired_snapshots:  [..] *Query_Snapshot;
    retired_matches:    [..] *Query_Filter_Match;

    allocator:          Allocator;
}

Query_Snapshot :: struct {
    filter_match:    *Query_Filter_Match;
    matched_cols:    [..] Column_Index;
    sparse_sets:     [] *Sparse_Set;
    sparse_gens:     [] u64;

    catalog_version: u64 = 0xFFFF_FFFF_FFFF_FFFF;

    refcount:        s64; // atomic
    retired:         s64; // atomic 0/1

    allocator:       Allocator;
}

resolve_query_allocator :: inline (allocator: Allocator) -> Allocator #must {
    if allocator.proc return allocator;
    return temp;
}

init_query_plan :: (plan: *Query_Plan, terms: [] *Type_Info,
                   enable_fetch: bool, allocator: Allocator) {
    plan.* = .{};
    plan.allocator = allocator;
    plan.rebuild_lock = 0;
    plan.retired_snapshots.allocator = allocator;
    plan.retired_matches.allocator = allocator;

    if terms.count > 0 {
        owned, _ := NewArray(terms.count, *Type_Info,, allocator);
        for i: 0..terms.count - 1 {
            owned[i] = terms[i];
        }
        plan.terms = owned;
    }

    build_static(plan, plan.terms, enable_fetch);

    if plan.needs_arch_match {
        plan.filter_match = make_empty_filter_match(allocator);
    }

    plan.snapshot = make_empty_snapshot(plan);
}

deinit :: inline (using match: *Query_Filter_Match) {
    array_free(matched_arch);
    array_free(arch_to_slot);
    free(match,, allocator);
}

free_snapshot :: (using snap: *Query_Snapshot) {
    if !snap return;
    if filter_match {
        release_filter_match(filter_match);
        filter_match = null;
    }
    if sparse_sets.data free(sparse_sets.data,, allocator);
    if snap.sparse_gens.data free(sparse_gens.data,, allocator);
    array_free(matched_cols);
    free(snap,, allocator);
}

deinit :: (using plan: *Query_Plan) {
    if !allocator_supports_free(allocator) {
        plan.* = .{};
        return;
    }

    if terms.data free(terms.data,, allocator);
    if req_arch.data free(req_arch.data,, allocator);
    if excl_arch.data free(excl_arch.data,, allocator);
    if sparse_types.data free(sparse_types.data,, allocator);
    if sparse_kinds.data free(sparse_kinds.data,, allocator);
    if fetches.data free(fetches.data,, allocator);

    if filter_match {
        atomic_write(*filter_match.retired, cast(s64) 1);
        release_filter_match(filter_match);
        deinit(filter_match);
        filter_match = null;
    }
    for old: retired_matches {
        deinit(old);
    }
    array_free(retired_matches);

    if snapshot {
        atomic_write(*snapshot.retired, cast(s64) 1);
        release_snapshot(snapshot);
        free_snapshot(snapshot);
        snapshot = null;
    }
    for old: retired_snapshots {
        free_snapshot(old);
    }
    array_free(retired_snapshots);
}

release_filter_match :: inline (using match: *Query_Filter_Match) {
    if !match return;
    atomic_add(*refcount, -1);
}

acquire_filter_match_ref :: inline (using match: *Query_Filter_Match) {
    if match atomic_add(*refcount, 1);
}

build_static :: (plan: *Query_Plan, terms: [] *Type_Info, enable_fetch: bool) {
    plan.enable_fetch = enable_fetch;
    plan.has_sparse_filters = false;
    plan.needs_arch_match = false;

    push_allocator(temp);

    buffers: Build_Buffers;
    buffers.req_arch.allocator = temp;
    buffers.excl_arch.allocator = temp;
    buffers.sparse_types.allocator = temp;
    buffers.sparse_kinds.allocator = temp;
    buffers.fetches.allocator = temp;

    for term: terms {
        add_term(*buffers, term, enable_fetch);
    }

    for kind: buffers.sparse_kinds {
        if kind != .LOOKUP_ONLY {
            plan.has_sparse_filters = true;
            break;
        }
    }

    sort_type_infos(*buffers.req_arch);
    sort_type_infos(*buffers.excl_arch);

    plan.req_arch = copy_type_info_slice(buffers.req_arch, plan.allocator);
    plan.excl_arch = copy_type_info_slice(buffers.excl_arch, plan.allocator);
    plan.sparse_types = copy_type_info_slice(buffers.sparse_types, plan.allocator);
    plan.sparse_kinds = copy_sparse_kind_slice(buffers.sparse_kinds, plan.allocator);
    plan.fetches = copy_fetch_slice(buffers.fetches, plan.allocator);

    has_arch_fetch := false;
    for fetch: plan.fetches {
        if !fetch.is_sparse {
            has_arch_fetch = true;
            break;
        }
    }
    has_required_sparse := false;
    for kind: plan.sparse_kinds {
        if kind == .REQUIRED {
            has_required_sparse = true;
            break;
        }
    }

    if buffers.req_arch.count > 0 || buffers.excl_arch.count > 0 || has_arch_fetch {
        plan.needs_arch_match = true;
    } else if !has_required_sparse {
        plan.needs_arch_match = true;
    } else {
        plan.needs_arch_match = false;
    }
}

make_empty_filter_match :: (allocator: Allocator) -> *Query_Filter_Match #must {
    match := New(Query_Filter_Match,, allocator);
    match.allocator = allocator;
    match.matched_arch.allocator = allocator;
    match.arch_to_slot.allocator = allocator;
    match.catalog_version = 0xFFFF_FFFF_FFFF_FFFF;
    match.refcount = 1;
    match.retired = 0;
    return match;
}

make_empty_snapshot :: (plan: *Query_Plan) -> *Query_Snapshot #must {
    snap := New(Query_Snapshot,, plan.allocator);
    snap.allocator = plan.allocator;
    snap.matched_cols.allocator = plan.allocator;
    snap.filter_match = null;
    snap.catalog_version = 0xFFFF_FFFF_FFFF_FFFF;
    snap.refcount = 1;
    snap.retired = 0;

    if plan.sparse_types.count > 0 {
        sets, _ := NewArray(plan.sparse_types.count, *Sparse_Set,, plan.allocator);
        gens, _ := NewArray(plan.sparse_types.count, u64,, plan.allocator);
        snap.sparse_sets = sets;
        snap.sparse_gens = gens;
        for i: 0..plan.sparse_types.count - 1 {
            snap.sparse_gens[i] = 0xFFFF_FFFF_FFFF_FFFF;
        }
    }
    return snap;
}

release_snapshot :: inline (using snap: *Query_Snapshot) {
    if !snap return;
    atomic_add(*refcount, -1);
}

snapshot_is_current :: (plan: *Query_Plan, snap: *Query_Snapshot,
                        components: *Components) -> bool #must {
    if plan.needs_arch_match {
        cur_catalog := get_catalog_version(components);
        if !snap.filter_match return false;
        if snap.filter_match.catalog_version != cur_catalog return false;
        if snap.catalog_version != cur_catalog return false;
    }

    for i: 0..plan.sparse_types.count - 1 {
        cur := get_sparse_generation(components, plan.sparse_types[i]);
        if snap.sparse_gens[i] != cur return false;
    }
    return true;
}

acquire_snapshot :: (plan: *Query_Plan,
                     components: *Components) -> *Query_Snapshot #must {
    while true {
        snap := atomic_read(*plan.snapshot);
        atomic_add(*snap.refcount, 1);

        if atomic_read(*plan.snapshot) != snap {
            release_snapshot(snap);
            continue;
        }

        if snapshot_is_current(plan, snap, components) {
            return snap;
        }

        release_snapshot(snap);
        try_rebuild(plan, components);
    }

    assert(false, "acquire_snapshot: unreachable");
    return null;
}

try_rebuild :: (using plan: *Query_Plan, components: *Components) {
    acquire_rebuild_lock(plan);
    defer release_rebuild_lock(plan);

    old := atomic_read(*snapshot);
    if snapshot_is_current(plan, old, components) return;

    new_snap := build_snapshot(plan, components);
    atomic_write(*snapshot, new_snap);

    atomic_write(*old.retired, cast(s64) 1);
    array_add(*retired_snapshots, old);
    release_snapshot(old);
}

build_filter_match :: inline (plan: *Query_Plan, components: *Components,
                       catalog_version: u64) -> *Query_Filter_Match #must {
    match := make_empty_filter_match(plan.allocator);
    rebuild_matched_archetypes(plan, match, components);
    match.catalog_version = catalog_version;
    return match;
}

build_snapshot :: (plan: *Query_Plan,
                   components: *Components) -> *Query_Snapshot #must {
    snap := make_empty_snapshot(plan);

    if plan.needs_arch_match {
        cur_catalog := get_catalog_version(components);
        match := atomic_read(*plan.filter_match);
        if !match || match.catalog_version != cur_catalog {
            new_match := build_filter_match(plan, components, cur_catalog);
            atomic_write(*plan.filter_match, new_match);
            if match {
                atomic_write(*match.retired, cast(s64) 1);
                array_add(*plan.retired_matches, match);
                release_filter_match(match);
            }
            match = new_match;
        }
        acquire_filter_match_ref(match);
        snap.filter_match = match;
        snap.catalog_version = match.catalog_version;
        bind_projection_columns(plan, snap, components);
    } else {
        snap.catalog_version = 0;
    }

    for i: 0..plan.sparse_types.count - 1 {
        info := plan.sparse_types[i];
        snap.sparse_sets[i] = try_find_set(*components.sparse_set_storage, info);
        snap.sparse_gens[i] = get_sparse_generation(components, info);
    }
    return snap;
}

pick_driver :: (plan: *Query_Plan,
                snap: *Query_Snapshot) -> Query_Driver_State #must {
    result: Query_Driver_State;

    best_slot: s64 = -1;
    best_size: s64 = -1;
    for i: 0..plan.sparse_kinds.count - 1 {
        if plan.sparse_kinds[i] != .REQUIRED continue;
        set := snap.sparse_sets[i];
        size := ifx set then get_size(set) else 0;
        if best_slot < 0 || size < best_size {
            best_slot = i;
            best_size = size;
        }
    }
    if best_slot >= 0 {
        result.use_sparse_driver = true;
        result.driver_sparse_slot = best_slot;
    }
    return result;
}

matches_sparse :: (plan: *Query_Plan, snap: *Query_Snapshot,
                   entity_index: Entity.Index, skip_slot: s64) -> bool #must {
    for i: 0..plan.sparse_kinds.count - 1 {
        if i == skip_slot continue;
        kind := plan.sparse_kinds[i];
        if kind == .LOOKUP_ONLY continue;

        set := snap.sparse_sets[i];
        has := set != null && contains_entity(set, entity_index);
        if kind == .REQUIRED {
            if !has return false;
        } else {
            if has return false;
        }
    }
    return true;
}

bind_matched_columns :: (plan: *Query_Plan, snap: *Query_Snapshot,
                         arch: *Archetype, match_slot: s64,
                         columns: [] *Column) {
    assert(columns.count >= plan.fetches.count);
    if !snap.filter_match {
        for i: 0..plan.fetches.count - 1 columns[i] = null;
        return;
    }
    base := match_slot * plan.fetches.count;
    for i: 0..plan.fetches.count - 1 {
        fetch := plan.fetches[i];
        if fetch.is_sparse {
            columns[i] = null;
            continue;
        }
        col_idx := snap.matched_cols[base + i];
        if col_idx == INVALID_COLUMN_INDEX {
            columns[i] = null;
        } else {
            columns[i] = *arch.columns[col_idx];
        }
    }
}

fill_pointers :: (plan: *Query_Plan, snap: *Query_Snapshot,
                  columns: [] *Column, pointers: [] *void,
                  entity_index: Entity.Index, row_index: Row_Index) {
    assert(pointers.count >= plan.fetches.count);
    for i: 0..plan.fetches.count - 1 {
        fetch := plan.fetches[i];
        if fetch.is_sparse {
            set := snap.sparse_sets[fetch.sparse_slot];
            if set {
                pointers[i] = try_get_bytes(set, entity_index);
            } else {
                pointers[i] = null;
            }
        } else {
            col := columns[i];
            if col && col.stride > 0 {
                pointers[i] = get_component(col, row_index);
            } else {
                pointers[i] = null;
            }
        }
    }
}

matched_arch_count :: inline (snap: *Query_Snapshot) -> s64 #must {
    if !snap.filter_match return 0;
    return snap.filter_match.matched_arch.count;
}

matched_arch_at :: inline (snap: *Query_Snapshot,
                           i: s64) -> Archetype_Index #must {
    return snap.filter_match.matched_arch[i];
}

arch_match_slot :: inline (snap: *Query_Snapshot,
                           arch_index: Archetype_Index) -> s32 #must {
    if !snap.filter_match return -1;
    if cast(s64) arch_index >= snap.filter_match.arch_to_slot.count return -1;
    return snap.filter_match.arch_to_slot[arch_index];
}

#scope_file;

allocator_supports_free :: inline (allocator: Allocator) -> bool #must {
    caps := cast(Allocator_Caps) allocator.proc(.CAPS, 0, 0, null,
                                                allocator.data);
    return (caps & .FREE) != 0;
}

Build_Buffers :: struct {
    req_arch:     [..] *Type_Info;
    excl_arch:    [..] *Type_Info;
    sparse_types: [..] *Type_Info;
    sparse_kinds: [..] Query_Sparse_Kind;
    fetches:      [..] Query_Fetch_Slot;
}

copy_type_info_slice :: (src: [] *Type_Info,
                         allocator: Allocator) -> [] *Type_Info {
    if src.count == 0 return .{};
    dst, _ := NewArray(src.count, *Type_Info,, allocator);
    for i: 0..src.count - 1 dst[i] = src[i];
    return dst;
}

copy_sparse_kind_slice :: (src: [] Query_Sparse_Kind,
                           allocator: Allocator) -> [] Query_Sparse_Kind {
    if src.count == 0 return .{};
    dst, _ := NewArray(src.count, Query_Sparse_Kind,, allocator);
    for i: 0..src.count - 1 dst[i] = src[i];
    return dst;
}

copy_fetch_slice :: (src: [] Query_Fetch_Slot,
                     allocator: Allocator) -> [] Query_Fetch_Slot {
    if src.count == 0 return .{};
    dst, _ := NewArray(src.count, Query_Fetch_Slot,, allocator);
    for i: 0..src.count - 1 dst[i] = src[i];
    return dst;
}

acquire_rebuild_lock :: (using plan: *Query_Plan) {
    while atomic_swap(*rebuild_lock, cast(s64) 1) != 0 {
    }
}

release_rebuild_lock :: inline (using plan: *Query_Plan) {
    atomic_write(*rebuild_lock, cast(s64) 0);
}

add_sparse_slot :: (using buffers: *Build_Buffers,
                    info: *Type_Info, kind: Query_Sparse_Kind) -> s64 {
    for i: 0..sparse_types.count - 1 {
        if sparse_types[i] == info {
            existing := sparse_kinds[i];
            if existing == .LOOKUP_ONLY {
                sparse_kinds[i] = kind;
            } else if kind != .LOOKUP_ONLY {
                assert(existing == kind, "Conflicting sparse filter for %!", info);
            }
            return i;
        }
    }
    array_add(*sparse_types, info);
    array_add(*sparse_kinds, kind);
    return sparse_types.count - 1;
}

add_term :: (using buffers: *Build_Buffers,
             term: *Type_Info, enable_fetch: bool) {
    role, info := classify_term(term);
    if !enable_fetch && role == .REQUIRED_FETCH {
        role = .WITH;
    }

    storage := get_storage_kind(info);

    if role == {
        case .REQUIRED_FETCH;
            if storage == .SPARSE_SET {
                slot := add_sparse_slot(buffers, info, .REQUIRED);
                array_add(*fetches, .{
                    type = info,
                    optional = false,
                    is_sparse = true,
                    sparse_slot = slot,
                });
            } else {
                array_add(*req_arch, info);
                array_add(*fetches, .{
                    type = info,
                    optional = false,
                    is_sparse = false,
                    sparse_slot = -1,
                });
            }

        case .OPTIONAL_FETCH;
            if storage == .SPARSE_SET {
                slot := add_sparse_slot(buffers, info, .LOOKUP_ONLY);
                array_add(*fetches, .{
                    type = info,
                    optional = true,
                    is_sparse = true,
                    sparse_slot = slot,
                });
            } else {
                array_add(*fetches, .{
                    type = info,
                    optional = true,
                    is_sparse = false,
                    sparse_slot = -1,
                });
            }

        case .WITH;
            if storage == .SPARSE_SET {
                add_sparse_slot(buffers, info, .REQUIRED);
            } else {
                array_add(*req_arch, info);
            }

        case .WITHOUT;
            if storage == .SPARSE_SET {
                add_sparse_slot(buffers, info, .EXCLUDED);
            } else {
                array_add(*excl_arch, info);
            }
    }
}

sort_type_infos :: (types: *[..] *Type_Info) {
    if types.count <= 1 return;
    for i: 1..types.count - 1 {
        key := (<<types)[i];
        j := i - 1;
        while j >= 0 && cast(u64) (<<types)[j] > cast(u64) key {
            (<<types)[j + 1] = (<<types)[j];
            j -= 1;
        }
        (<<types)[j + 1] = key;
    }
    write := 1;
    for i: 1..types.count - 1 {
        if (<<types)[i] != (<<types)[write - 1] {
            (<<types)[write] = (<<types)[i];
            write += 1;
        }
    }
    types.count = write;
}

matches_archetype_filters :: (req_arch: [] *Type_Info, excl_arch: [] *Type_Info,
                              arch: *Archetype) -> bool #must {
    if req_arch.count > 0 {
        if !contains_all(*arch.id, req_arch) return false;
    }
    if excl_arch.count > 0 {
        if !contains_none(*arch.id, excl_arch) return false;
    }
    return true;
}

rebuild_matched_archetypes :: (plan: *Query_Plan, match: *Query_Filter_Match,
                               components: *Components) {
    array_reset_keeping_memory(*match.matched_arch);
    array_reset_keeping_memory(*match.arch_to_slot);

    arch_count := get_archetype_count(components);
    array_resize(*match.arch_to_slot, arch_count);
    for i: 0..match.arch_to_slot.count - 1 {
        match.arch_to_slot[i] = -1;
    }

    if plan.req_arch.count > 0 {
        best_i: s64 = 0;
        best_count: s64 = -1;
        for i: 0..plan.req_arch.count - 1 {
            list := get_component_archetypes(components, plan.req_arch[i]);
            if best_count < 0 || list.count < best_count {
                best_i = i;
                best_count = list.count;
            }
        }
        candidates := get_component_archetypes(components, plan.req_arch[best_i]);
        for arch_index: candidates {
            arch := get_archetype(components, arch_index);
            if !matches_archetype_filters(plan.req_arch, plan.excl_arch, arch) {
                continue;
            }
            slot := cast(s32) match.matched_arch.count;
            array_add(*match.matched_arch, arch_index);
            match.arch_to_slot[arch_index] = slot;
        }
    } else {
        for arch_i: 0..arch_count - 1 {
            arch_index := cast(Archetype_Index) arch_i;
            arch := get_archetype(components, arch_index);
            if !matches_archetype_filters(plan.req_arch, plan.excl_arch, arch) {
                continue;
            }
            slot := cast(s32) match.matched_arch.count;
            array_add(*match.matched_arch, arch_index);
            match.arch_to_slot[arch_i] = slot;
        }
    }
}

bind_projection_columns :: (plan: *Query_Plan, snap: *Query_Snapshot,
                            components: *Components) {
    array_reset_keeping_memory(*snap.matched_cols);
    if !snap.filter_match return;

    for arch_index: snap.filter_match.matched_arch {
        arch := get_archetype(components, arch_index);
        for fetch: plan.fetches {
            if fetch.is_sparse {
                array_add(*snap.matched_cols, INVALID_COLUMN_INDEX);
                continue;
            }
            col_index, found := table_find(*arch.column_map, fetch.type);
            if found {
                array_add(*snap.matched_cols, col_index);
            } else {
                array_add(*snap.matched_cols, INVALID_COLUMN_INDEX);
            }
        }
    }
}
