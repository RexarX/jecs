#import "Basic";

DEFAULT_PAGED_SPARSE_PAGE_BITS :: 12;

Page :: struct (page_bits: s64) {
    slots: [1 << page_bits] Entity.Index;
}

Paged_Sparse_Array :: struct (page_bits := DEFAULT_PAGED_SPARSE_PAGE_BITS) {
    page_table: [..] *My_Page;
    allocator:  Allocator;

    My_Page :: Page(page_bits);
}

init :: inline (array: *Paged_Sparse_Array($page_bits),
                allocator: Allocator = .{}) {
    array.allocator = resolve_allocator(array, allocator);
    array.page_table.allocator = array.allocator;
}

reset :: (using array: *Paged_Sparse_Array($page_bits)) {
    for page: page_table {
        if page free(page,, allocator);
    }
    array_reset(*page_table);
}

clear :: (using array: *Paged_Sparse_Array($page_bits)) {
    for page: page_table {
        if page {
            for * page.slots {
                it.* = Entity.INVALID_INDEX;
            }
        }
    }
}

assign :: (using array: *Paged_Sparse_Array($page_bits),
           entity_index: Entity.Index, value: Entity.Index) {
    page_i := cast(s64) entity_index >> page_bits;
    ensure_page_capacity(array, page_i);

    page := page_table[page_i];
    if !page {
        page = New(Paged_Sparse_Array(page_bits).My_Page,, allocator);
        for * page.slots {
            it.* = Entity.INVALID_INDEX;
        }
        page_table[page_i] = page;
    }

    slot := cast(s64) entity_index & ((1 << page_bits) - 1);
    page.slots[slot] = value;
}

clear_index :: (using array: *Paged_Sparse_Array($page_bits),
                entity_index: Entity.Index) -> bool {
    page_i := cast(s64) entity_index >> page_bits;
    if page_i >= page_table.count return false;

    page := page_table[page_i];
    if !page return false;

    slot := cast(s64) entity_index & ((1 << page_bits) - 1);
    if page.slots[slot] == Entity.INVALID_INDEX return false;

    page.slots[slot] = Entity.INVALID_INDEX;
    return true;
}

get :: inline (using array: *Paged_Sparse_Array($page_bits),
               entity_index: Entity.Index) -> Entity.Index #must {
    value, ok := try_get(array, entity_index);
    assert(ok, "Entity index % is not present!", entity_index);
    return value;
}

try_get :: (using array: *Paged_Sparse_Array($page_bits),
            entity_index: Entity.Index) -> Entity.Index, bool #must {
    page_i := cast(s64) entity_index >> page_bits;
    if page_i >= page_table.count return Entity.INVALID_INDEX, false;

    page := page_table[page_i];
    if !page return Entity.INVALID_INDEX, false;

    slot := cast(s64) entity_index & ((1 << page_bits) - 1);
    value := page.slots[slot];
    if value == Entity.INVALID_INDEX return Entity.INVALID_INDEX, false;
    return value, true;
}

contains :: (using array: *Paged_Sparse_Array($page_bits),
             entity_index: Entity.Index) -> bool #must {
    page_i := cast(s64) entity_index >> page_bits;
    if page_i >= page_table.count return false;

    page := page_table[page_i];
    if !page return false;

    slot := cast(s64) entity_index & ((1 << page_bits) - 1);
    return page.slots[slot] != Entity.INVALID_INDEX;
}

// Grow the page-table so page_i is in range (new entries null).
ensure_page_capacity :: (array: *Paged_Sparse_Array($page_bits), page_i: s64) {
    if page_i < array.page_table.count return;

    old_count := array.page_table.count;
    array_resize(*array.page_table, page_i + 1);
    for i: old_count..array.page_table.count - 1 {
        array.page_table[i] = null;
    }
}
