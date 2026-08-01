#import "Basic";

Storage_Kind :: enum u8 {
    ARCHETYPE;
    SPARSE_SET;
}

infer_default_storage :: inline ($T: Type) -> Storage_Kind #must {
    #if #run is_tag(T) return .SPARSE_SET;
    return .ARCHETYPE;
}

// Intended for compile-time use only (`#if #run get_storage_kind(T) == ...`).
// Walking struct members is fine under #run; avoid calling this on hot runtime paths.
get_storage_kind :: ($T: Type) -> Storage_Kind #must {
    info :: type_info(T);
    #if info.type == .STRUCT {
        struct_info :: cast(*Type_Info_Struct) info;
        for struct_info.members {
            if it.name == "JECS_STORAGE_KIND"
               && it.type == type_info(Storage_Kind)
               && (it.flags & .CONSTANT)
               && it.offset_into_constant_storage >= 0 {
                return << cast(*Storage_Kind) (struct_info.constant_storage.data + it.offset_into_constant_storage);
            }
        }
    }

    return infer_default_storage(T);
}

is_tag :: inline ($T: Type) -> bool #must {
    return size_of(T) == 0;
}

// Prefer `#if #run get_storage_kind(T) == .ARCHETYPE` at call sites so the member scan stays compile-time.
is_archetype_component :: inline ($T: Type) -> bool #must {
    return get_storage_kind(T) == .ARCHETYPE;
}

is_sparse_component :: inline ($T: Type) -> bool #must {
    return get_storage_kind(T) == .SPARSE_SET;
}

component_name :: ($T: Type) -> string #must {
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

component_alignment :: ($T: Type) -> s64 #must {
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
    type: *Type_Info;
    name: string;
    size: s64;
    alignment: s64;
    storage_kind: Storage_Kind;
    is_tag: bool;
}

make_component_metadata :: inline ($T: Type) -> Component_Metadata #must {
    return .{
        type = type_info(T),
        name = component_name(T),
        size = size_of(T),
        alignment = component_alignment(T),
        storage_kind = get_storage_kind(T),
        is_tag = is_tag(T),
    };
}
