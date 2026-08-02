#import "Basic";

// Prefer an explicit allocator; otherwise capture context.allocator / default.
resolve_allocator :: inline (thing: *$T,
                             allocator: Allocator) -> Allocator #must {
    if allocator.proc return allocator;
    remember_allocators(thing);
    return thing.allocator;
}
