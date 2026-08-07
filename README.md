# jecs

Jai ECS library.

## Using as a module

Clone or submodule this repository into your project's `modules` folder:

```
your_project/
  modules/
    jecs/          ← this repo
```

```jai
Jecs :: #import "jecs";
```

The folder name must be `jecs` — the compiler resolves `#import "jecs"` to `modules/jecs/module.jai`.

### Module parameters

Override entity handle field types at import time (defaults: `u32` / `u32`):

```jai
// 64-bit indices and generations
Jecs :: #import "jecs"(INDEX_TYPE = u64, GENERATION_TYPE = u64);
```

Supported types: `u16`, `u32`, `u64` (unsigned only). `Entity.Index` and `Entity.Generation` propagate to dense indices, archetype rows, sparse maps, etc.

Generation encoding (alive bit + counter) scales with `GENERATION_TYPE` width automatically.

### Option 1: command line

Point `-import_dir` at the **parent** of the `jecs` folder:

```bash
jai your_program.jai -import_dir path/to/modules
```

### Option 2: metaprogram

```jai
import_path: [..] string;
array_add(*import_path, tprint("%/modules", #filepath));
array_add(*import_path, ..options.import_path);
options.import_path = import_path;
```

## Examples

### World and entities

`World` owns an entity manager and component storage. Create entities through the world so component tracking is set up automatically.

```jai
Jecs :: #import "jecs";

Position :: struct { x, y: float; }

main :: () {
    world: Jecs.World;
    Jecs.init(*world);
    defer Jecs.deinit(*world);

    player := Jecs.create_entity(*world);
    Jecs.add_component(*world, player, Position.{x = 10, y = 20});

    pos := Jecs.get_component(*world, player, Position);
    pos.x += 1;

    Jecs.destroy_entity(*world, player);
}
```

Entities are `{index, generation}` handles. Stale handles fail `validate_entity` after destroy/recycle.

### Components

Typed API — storage kind and layout are resolved at compile time:

```jai
Jecs.add_component(*world, entity, Velocity.{x = 1, y = 0});
assert(Jecs.has_component(*world, entity, Velocity));
Jecs.get_component(*world, entity, Velocity).x = 2;
Jecs.remove_component(*world, entity, Velocity);

// false if already present / absent — no overwrite
assert(Jecs.try_add_component(*world, entity, Velocity.{}));
assert(Jecs.try_remove_component(*world, entity, Velocity));
```

Batch API via `Any` (useful when component types come from a runtime list):

```jai
Jecs.add_components(*world, entity, Position.{x = 0, y = 0}, Velocity.{x = 1, y = 0});
Jecs.remove_components(*world, entity, Position, Velocity);
```

### Storage: archetype vs sparse

By default, **value components** live in archetype columns (SoA, fast iteration over matching sets). **Tag components** (zero size) use sparse sets.

Override with struct notes:

```jai
// Force sparse storage for a non-tag component
Paused :: struct @sparse {
    flag: bool;
}

// Force archetype storage (e.g. empty struct used as a marker)
Marker :: struct @archetype {}
```

`Dead :: struct {}` is a tag → sparse automatically. `Position` with fields → archetype automatically.

### Cleanup for owning components

POD components have zero overhead. Heap-owning components opt in with a typed `JECS_ON_REMOVE` constant on the struct (or its `variant_of` struct):

```jai
Inventory :: struct {
    items: [..] Item;

    JECS_ON_REMOVE :: (using inv: *Inventory) {
        array_free(items);
    };
}
```

Cleanup runs when a component is removed, overwritten, dropped during archetype migration, or when storage is reset/cleared. Register components via the typed path (`add_component`, `register`) so the trampoline is baked in at compile time.

### Reserved entities

`reserve_entity` is thread-safe and returns a handle before the slot is materialized. Flush when ready to use it in the world:

```jai
reserved := Jecs.reserve_entity(*world);
// ... other threads may reserve concurrently ...
Jecs.flush_reserved_entities(*world);
assert(Jecs.validate_entity(*world, reserved));
Jecs.add_component(*world, reserved, Position.{});
```

### Queries

Queries are lightweight handles: `*Entities`, `*Components`, and an embedded `Query_Plan`.
Each `query()` / `query_entities()` builds a fresh plan into the handle.

Default allocator is `temp` — use it for queries that don't outlive `reset_temporary_storage` call.
If query need to be valid for a long time use a persistent allocator and `deinit`:

```jai
movement := Jecs.query(*world, Position, Velocity, allocator = world.allocator);
defer Jecs.deinit(*movement);

for row, entity: movement { /* ... */ }

// One-shot (default temp):
for row, entity: Jecs.query(*world, Position) { /* ... */ }
```

Terms:

- Bare non-tag type — required fetch
- Bare tag — required presence filter
- `Optional(T)` — nullable fetch (value components only)
- `With(T)` / `Without(T)` — presence filters without fetching

```jai
Dead     :: struct {}
Selected :: struct {}
Health   :: struct { value: float; }

// Optional: fetch when present; Without
// Without: exclude entities with Dead component
for row, entity: Jecs.query(*world, Position, Jecs.Optional(Health), Jecs.Without(Dead)) {
    pos := Jecs.get(row, Position);      // always non-null
    hp  := Jecs.try_get(row, Health);    // *Health or null
    pos.x += ifx hp then hp.value else 0;
}

// With: require Selected without fetching it (useful for tags)
for row, entity: Jecs.query(*world, Position, Jecs.With(Selected)) {
    _ = Jecs.get(row, Position);
}

// Entity-only query that gets dead entities (no component fetch)
for entity: Jecs.query_entities(*world, Position, Jecs.With(Dead)) {
    // ...
}

```

**Reuse:** pass a persistent `allocator` and call `deinit` when done.
Default `temp` is for one-shot iteration in the same scope. Structural mutation concurrent with iteration is not safe.

**Invalidation:** archetype-catalog growth (new archetype) refreshes matched archetype lists; entity migration among existing archetypes does not.
Sparse bindings refresh when that component's sparse storage is first created.

**Invalidates the handle:** `deinit(*query)`, world going out of scope while the query still holds pointers into a world-owned allocator, or `deinit(*world)` while plan memory used that allocator.

**Invalidates an in-progress iteration:** create/destroy entities, `clear`/`reset`, add/remove components.
Value mutation through `get`/`try_get` pointers is allowed. Result order is unspecified.
