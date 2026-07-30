#import "Basic";
#import "Compiler";
#import "File";

OUTPUT_LIB_NAME :: "jecs";
DEFAULT_OUTPUT_DIRECTORY :: "bin";

BuildPreset :: enum u8 {
    DEBUG;
    RELEASE_WITH_DEBUG_INFO;
    RELEASE;
}

DEFAULT_BUILD_PRESET :: BuildPreset.DEBUG;

build_preset_to_string :: (preset: BuildPreset) -> string {
    if preset == {
        case .DEBUG; return "debug";
        case .RELEASE_WITH_DEBUG_INFO; return "relwithdebinfo";
        case .RELEASE; return "release";
        case; return tprint("%", preset);
    }
}

build_preset_to_optimization_type :: (preset: BuildPreset) -> Optimization_Type {
    if preset == {
        case .DEBUG; return .DEBUG;
        case .RELEASE_WITH_DEBUG_INFO; return .VERY_OPTIMIZED;
        case .RELEASE; return .VERY_OPTIMIZED;
        case; return .DEBUG;
    }
}

build_preset_from_args :: (args: []string) -> BuildPreset {
    if array_find(args, "-debug") {
        return .DEBUG;
    } else if array_find(args, "-relwithdebinfo") {
        return .RELEASE_WITH_DEBUG_INFO;
    } else if array_find(args, "-release") {
        return .RELEASE;
    } else {
        return DEFAULT_BUILD_PRESET;
    }
}

get_cpu_target_name :: () -> string {
    if CPU == {
        case .X64; return "x64";
        case .ARM64; return "arm64";
        case; return tprint("%", CPU);
    }
}

get_platform_name :: () -> string {
    if OS == {
        case .WINDOWS; return "windows";
        case .LINUX; return "linux";
        case .MACOS; return "macos";
        case; return tprint("%", OS);
    }
}

gen_output_dir_name :: (preset: BuildPreset = DEFAULT_BUILD_PRESET) -> string {
    return tprint("%-%-%", get_platform_name(), get_cpu_target_name(), build_preset_to_string(preset));
}

set_optimization_options  :: (options: *Build_Options, preset: BuildPreset = DEFAULT_BUILD_PRESET) {
    optimization_type := build_preset_to_optimization_type(preset);
    preserve_debug_info := (preset == .DEBUG || preset == .RELEASE_WITH_DEBUG_INFO);
    set_optimization(options, optimization_type, preserve_debug_info);
}

build :: () {
    set_build_options_dc(.{do_output = false});

    build_options := get_build_options();
    args := build_options.compile_time_command_line;

    cpu_target := CPU;
    if array_find(args, "-x64") cpu_target = .X64;

    os_target := OS;

    preset := build_preset_from_args(args);
    output_dir_name := gen_output_dir_name(preset);
    output_path := tprint("%/%", DEFAULT_OUTPUT_DIRECTORY, output_dir_name);
    make_directory_if_it_does_not_exist(output_path, recursive = true);

    log("Building %", output_dir_name);

    workspace := compiler_create_workspace("jecs");

    options := get_build_options(workspace);
    copy_commonly_propagated_fields(build_options, *options);
    options.output_type = .STATIC_LIBRARY;
    options.cpu_target = cpu_target;
    options.os_target  = os_target;
    options.output_executable_name = OUTPUT_LIB_NAME;
    options.output_path = output_path;

    set_optimization_options(*options, preset);

    set_build_options(options, workspace);

    compiler_begin_intercept(workspace);
    add_build_file("src/jecs.jai", workspace);

    while true {
        message := compiler_wait_for_message();
        if message.kind == {
            case .ERROR;
                exit(1);

            case .COMPLETE;
                break;
        }
    }
    compiler_end_intercept(workspace);
}

#run build();
