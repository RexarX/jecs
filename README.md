# jecs

Jai ECS library.

## Using as a module

Clone or submodule this repository into your project's `modules` folder:

```
my_project/
  modules/
    jecs/          ← this repo
```

```jai
Jecs :: #import "jecs";
```

The folder name must be `jecs` — the compiler resolves `#import "jecs"` to `modules/jecs/module.jai`.

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

## Building the static library

```bash
jai build.jai
```

Build presets: `-debug` (default), `-relwithdebinfo`, `-release` (can be combined to build multiple presets in parallel).

```bash
jai build.jai - -release
```

Output goes to `bin/<platform>-<arch>-<preset>/`.
