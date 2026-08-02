#import "Basic";

Storage_Kind :: enum u8 {
    ARCHETYPE;
    SPARSE_SET;
}

infer_default_storage :: inline ($T: Type) -> Storage_Kind #must #compile_time {
    #if #run is_tag(T) return .SPARSE_SET;
    return .ARCHETYPE;
}

get_storage_kind :: ($T: Type) -> Storage_Kind #must #compile_time {
    info :: type_info(T);
    #if info.type == {
        case .STRUCT;
            struct_info :: cast(*Type_Info_Struct) info;
            storage_kind :: #run try_get_storage_kind_member(struct_info);
            #if storage_kind return <<storage_kind;

        case .VARIANT;
            variant_info :: cast(*Type_Info_Variant) info;
            #if variant_info.variant_of.type == .STRUCT {
                struct_info :: cast(*Type_Info_Struct) variant_info.variant_of;
                storage_kind :: #run try_get_storage_kind_member(struct_info);
                #if storage_kind return <<storage_kind;
            }
    }

    return infer_default_storage(T);
}

get_storage_kind :: (info: *Type_Info) -> Storage_Kind #must {
    if info.type == {
        case .STRUCT;
            struct_info := cast(*Type_Info_Struct) info;
            storage_kind := try_get_storage_kind_member(struct_info);
            if storage_kind return <<storage_kind;

        case .VARIANT;
            variant_info := cast(*Type_Info_Variant) info;
            if variant_info.variant_of.type == .STRUCT {
                struct_info := cast(*Type_Info_Struct) variant_info.variant_of;
                storage_kind := try_get_storage_kind_member(struct_info);
                if storage_kind return <<storage_kind;
            }
    }

    size := info.runtime_size;
    if size < 0 size = 0;
    if size == 0 return .SPARSE_SET;
    return .ARCHETYPE;
}

is_tag :: inline ($T: Type) -> bool #must #compile_time {
    return size_of(T) == 0;
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

Component_Metadata :: struct {
    type:         *Type_Info;
    name:         string;
    size:         s64;
    alignment:    s64;
    storage_kind: Storage_Kind;
    is_tag:       bool;
}

make_component_metadata :: inline ($T: Type) -> Component_Metadata #must {
    return .{
        type         = type_info(T),
        name         = #run get_component_name(T),
        size         = size_of(T),
        alignment    = #run get_component_alignment(T),
        storage_kind = #run get_storage_kind(T),
        is_tag       = #run is_tag(T),
    };
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
    };
}

#scope_file;

try_get_storage_kind_member :: (struct_info: *Type_Info_Struct) -> *Storage_Kind #must {
    for struct_info.members {
        if it.name == "JECS_STORAGE_KIND"
           && it.type == type_info(Storage_Kind)
           && (it.flags & .CONSTANT)
           && it.offset_into_constant_storage >= 0 {
            storage_kind_ptr := struct_info.constant_storage.data + it.offset_into_constant_storage;
            return cast(*Storage_Kind) storage_kind_ptr;
        }
    }

    return null;
}
