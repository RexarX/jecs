#import "Basic";
#import "Compiler";
#import "File";

#run {
    set_build_options_dc(.{do_output = false});

    build_options := get_build_options();
    args := build_options.compile_time_command_line;

    cpu_target := CPU;
    if array_find(args, "-x64") cpu_target = .X64;

    os_target := OS;

    presets := build_presets_from_args(args);

    for preset: presets {
        output_dir_name := gen_output_dir_name(preset, cpu_target, os_target);
        output_path := tprint("%/%", DEFAULT_OUTPUT_DIRECTORY, output_dir_name);
        make_directory_if_it_does_not_exist(output_path, recursive = true);

        log("Building %", output_dir_name);

        workspace := create_workspace(preset, build_options, cpu_target,
                                      os_target, output_dir_name, output_path);
        add_build_file("module.jai", workspace);
    }
}

create_workspace :: (preset: Build_Preset, build_options: Build_Options,
                     cpu_target: CPU_Tag, os_target: Operating_System_Tag,
                     output_dir_name: string,
                     output_path: string) -> Workspace #must {
    name := tprint("jecs_%", build_preset_to_string(preset));
    workspace := compiler_create_workspace(name);

    options := get_build_options(workspace);
    copy_commonly_propagated_fields(build_options, *options);
    options.output_type = .STATIC_LIBRARY;
    options.cpu_target = cpu_target;
    options.os_target  = os_target;
    options.output_executable_name = OUTPUT_LIB_NAME;
    options.output_path = output_path;
    options.intermediate_path = tprint("%/%", DEFAULT_INTERMEDIATE_DIRECTORY,
                                       output_dir_name);
    make_directory_if_it_does_not_exist(options.intermediate_path,
                                        recursive = true);
    set_optimization_options(*options, preset);
    set_build_options(options, workspace);

    return workspace;
}

OUTPUT_LIB_NAME                :: "jecs";
DEFAULT_OUTPUT_DIRECTORY       :: "bin";
DEFAULT_INTERMEDIATE_DIRECTORY :: ".build";

Build_Preset :: enum u8 {
    DEBUG;
    RELEASE_WITH_DEBUG_INFO;
    RELEASE;
}

DEFAULT_BUILD_PRESET :: Build_Preset.DEBUG;

build_preset_to_string :: (preset: Build_Preset) -> string #must {
    if preset == {
        case .DEBUG; return "debug";
        case .RELEASE_WITH_DEBUG_INFO; return "relwithdebinfo";
        case .RELEASE; return "release";
        case; return tprint("%", preset);
    }
}

build_preset_to_optimization_type :: (preset: Build_Preset) -> Optimization_Type #must {
    if preset == {
        case .DEBUG; return .DEBUG;
        case .RELEASE_WITH_DEBUG_INFO; return .VERY_OPTIMIZED;
        case .RELEASE; return .VERY_OPTIMIZED;
        case; return .DEBUG;
    }
}

build_presets_from_args :: (args: []string) -> [..] Build_Preset #must {
    presets: [..] Build_Preset;

    if array_find(args, "-debug") add_unique_preset(*presets, .DEBUG);
    if array_find(args, "-relwithdebinfo")  {
        add_unique_preset(*presets, .RELEASE_WITH_DEBUG_INFO);
    }
    if array_find(args, "-release") add_unique_preset(*presets, .RELEASE);

    if presets.count == 0 array_add(*presets, DEFAULT_BUILD_PRESET);

    return presets;
}

add_unique_preset :: (presets: *[..] Build_Preset, preset: Build_Preset) {
    for presets.* {
        if it == preset return;
    }
    array_add(presets, preset);
}

get_cpu_target_name :: (cpu_target: CPU_Tag = CPU) -> string #must {
    if cpu_target == {
        case .X64; return "x64";
        case .ARM64; return "arm64";
        case; return tprint("%", cpu_target);
    }
}

get_platform_name :: (os_target: Operating_System_Tag = OS) -> string #must {
    if os_target == {
        case .WINDOWS; return "windows";
        case .LINUX; return "linux";
        case .MACOS; return "macos";
        case; return tprint("%", os_target);
    }
}

gen_output_dir_name :: (preset: Build_Preset = DEFAULT_BUILD_PRESET,
                        cpu_target: CPU_Tag = CPU,
                        os_target: Operating_System_Tag = OS) -> string #must {
    return tprint("%-%-%", get_platform_name(os_target),
                  get_cpu_target_name(cpu_target),
                  build_preset_to_string(preset));
}

set_optimization_options :: (options: *Build_Options,
                             preset: Build_Preset = DEFAULT_BUILD_PRESET) {
    optimization_type := build_preset_to_optimization_type(preset);
    preserve_debug_info := (preset == .DEBUG || preset == .RELEASE_WITH_DEBUG_INFO);
    set_optimization(options, optimization_type, preserve_debug_info);
}
