#import "Basic";

Storage_Kind :: enum u8 {
    ARCHETYPE;
    SPARSE_SET;
}

infer_default_storage :: inline ($T: Type) -> Storage_Kind #must #compile_time {
    #if #run is_tag(T) return .SPARSE_SET;
    return .ARCHETYPE;
}

infer_default_storage :: (info: *Type_Info) -> Storage_Kind #must {
    if is_tag(info) return .SPARSE_SET;
    return .ARCHETYPE;
}

has_note :: ($T: Type, key: string) -> bool #must {
    return has_note(type_info(T), key);
}

has_note :: (info: *Type_Info, key: string) -> bool #must {
    if info.type == {
        case .STRUCT;
            struct_info := cast(*Type_Info_Struct) info;
            for struct_info.notes {
                if it == key return true;
            }
            return false;

        case .VARIANT;
            variant_info := cast(*Type_Info_Variant) info;
            if variant_info.variant_of.type == .STRUCT {
                struct_info := cast(*Type_Info_Struct) variant_info.variant_of;
                return has_note(struct_info, key);
            }
    }
    return false;
}

get_storage_kind :: ($T: Type) -> Storage_Kind #must #compile_time {
    return #run get_storage_kind(type_info(T));
}

get_storage_kind :: (info: *Type_Info) -> Storage_Kind #must {
    if info.type == {
        case .STRUCT;
            struct_info := cast(*Type_Info_Struct) info;
            if has_note(struct_info, "sparse") return .SPARSE_SET;
            if has_note(struct_info, "archetype") return .ARCHETYPE;

        case .VARIANT;
            struct_info := try_get_struct_info(info);
            if struct_info {
                if has_note(struct_info, "sparse") return .SPARSE_SET;
                if has_note(struct_info, "archetype") return .ARCHETYPE;
            }
    }

    return infer_default_storage(info);
}

is_tag :: inline ($T: Type) -> bool #must #compile_time {
    return size_of(T) == 0;
}

is_tag :: inline (info: *Type_Info) -> bool #must {
    size := info.runtime_size;
    if info.runtime_size <= 0 return true;
    return false;
}

get_component_name :: ($T: Type) -> string #must #compile_time {
    info :: type_info(T);
    #if info.type == {
        case .STRUCT;
            struct_info :: cast(*Type_Info_Struct) info;
            if struct_info.name return struct_info.name;

        case .ENUM;
            enum_info :: cast(*Type_Info_Enum) info;
            if enum_info.name return enum_info.name;

        case .VARIANT;
            variant_info :: cast(*Type_Info_Variant) info;
            if variant_info.name return variant_info.name;
    }

    return tprint("%", T);
}

get_component_name :: (info: *Type_Info) -> string #must {
    if info.type == {
        case .STRUCT;
            struct_info := cast(*Type_Info_Struct) info;
            if struct_info.name return struct_info.name;

        case .ENUM;
            enum_info := cast(*Type_Info_Enum) info;
            if enum_info.name return enum_info.name;

        case .VARIANT;
            variant_info := cast(*Type_Info_Variant) info;
            if variant_info.name return variant_info.name;
    }

    return tprint("%", info);
}

get_component_alignment :: ($T: Type) -> s64 #must #compile_time {
    #if size_of(T) == 0 return 1;

    Alignment_Probe :: struct {
        pad: u8;
        value: T;
    }

    struct_info :: cast(*Type_Info_Struct) type_info(Alignment_Probe);
    for struct_info.members {
        if it.name == "value" return it.offset_in_bytes;
    }
    return 1;
}

Component_Cleanup_Proc :: #type (data: *void);

invoke_cleanup :: inline (on_remove: Component_Cleanup_Proc, data: *void) {
    if on_remove && data {
        on_remove(data);
    }
}

Component_Metadata :: struct {
    type:         *Type_Info;
    name:         string;
    size:         s64;
    alignment:    s64;
    storage_kind: Storage_Kind;
    is_tag:       bool;
    on_remove:    Component_Cleanup_Proc; // null = POD, no-op
}

make_component_metadata :: inline ($T: Type) -> Component_Metadata #must #compile_time {
    meta: Component_Metadata = .{
        type         = type_info(T),
        name         = #run get_component_name(T),
        size         = size_of(T),
        alignment    = #run get_component_alignment(T),
        storage_kind = #run get_storage_kind(T),
        is_tag       = #run is_tag(T),
        on_remove    = null,
    };

    #if #run has_on_remove_member(type_info(T)) {
        #run validate_on_remove_signature(type_info(T));
        trampoline :: (data: *void) {
            T.JECS_ON_REMOVE(cast(*T) data);
        }
        meta.on_remove = trampoline;
    }

    return meta;
}

make_component_metadata :: (info: *Type_Info) -> Component_Metadata #must {
    size := info.runtime_size;
    if size < 0 size = 0;
    return .{
        type         = info,
        name         = get_component_name(info),
        size         = size,
        alignment    = 1,
        storage_kind = get_storage_kind(info),
        is_tag       = size == 0,
        on_remove    = null, // typed trampoline requires $T; register(T) first
    };
}

invoke_cleanup :: inline (meta: Component_Metadata, data: *void) {
    invoke_cleanup(meta.on_remove, data);
}

has_on_remove_member :: ($T: Type) -> bool #must #compile_time {
    return #run has_on_remove_member(type_info(T));
}

has_on_remove_member :: (info: *Type_Info) -> bool #must {
    struct_info := try_get_struct_info(info);
    if !struct_info return false;

    for struct_info.members {
        if it.name == "JECS_ON_REMOVE" && (it.flags & .CONSTANT) {
            return true;
        }
    }
    return false;
}

validate_on_remove_signature :: ($T: Type) #compile_time {
    #run validate_on_remove_signature(type_info(T));
}

validate_on_remove_signature :: (info: *Type_Info) {
    struct_info := try_get_struct_info(info);
    assert(struct_info != null,
           "JECS_ON_REMOVE requires a struct or struct-variant component!");

    for struct_info.members {
        if it.name == "JECS_ON_REMOVE" && (it.flags & .CONSTANT) {
            assert(it.type.type == .PROCEDURE,
                   "JECS_ON_REMOVE must be a procedure constant!");

            proc_info := cast(*Type_Info_Procedure) it.type;

            assert(proc_info.argument_types.count == 1,
                   "JECS_ON_REMOVE must take exactly (*T) -> void!");
            assert(proc_info.return_types.count == 0,
                   "JECS_ON_REMOVE must return void!");

            arg_type := proc_info.argument_types[0];
            assert(arg_type.type == .POINTER,
                   "JECS_ON_REMOVE's parameter must be *T!");
            pointed := cast(*Type_Info_Pointer) arg_type;
            // Declared on the struct (or its variant_of): accept *Component or *StructBase.
            base_info := cast(*Type_Info) struct_info;
            assert(pointed.pointer_to == info || pointed.pointer_to == base_info,
                   "JECS_ON_REMOVE's parameter must be *T!");
            return;
        }
    }
    assert(false, "JECS_ON_REMOVE member not found!");
}

#scope_file;

try_get_struct_info :: (info: *Type_Info) -> *Type_Info_Struct #must {
    if info.type == {
        case .STRUCT;
            return cast(*Type_Info_Struct) info;

        case .VARIANT;
            variant_info := cast(*Type_Info_Variant) info;
            if variant_info.variant_of.type == .STRUCT {
                return cast(*Type_Info_Struct) variant_info.variant_of;
            }
    }
    return null;
}
