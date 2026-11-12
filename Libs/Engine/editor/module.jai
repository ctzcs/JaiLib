// Reflection-driven ImGui widgets. Call only between ImGui NewFrame and Render.
#import "Basic";
#import "Hash_Table";
IM :: #import "ImGui";
EA :: #import "asset";
#load "frame.jai";

// Edited strings borrow these buffers. Copy strings into application-owned
// storage before destroying the editor or before moving edited objects.
Editor_String :: struct { bytes: [] u8; }
Property_Editor :: struct { strings: Table(*void, Editor_String); max_depth: s64 = 16; }
property_editor_destroy :: (editor: *Property_Editor) {
    for editor.strings free(it.bytes.data);
    deinit(*editor.strings);
}
property_drawer :: (editor: *Property_Editor, label: string, value: *$T) -> bool {
    return property_draw_value(editor, label, value, type_info(T), 0);
}
property_read_integer :: (data: *void, info: *Type_Info_Integer) -> s64 {
    if info.signed {
        if info.runtime_size == 1 return <<cast(*s8) data;
        if info.runtime_size == 2 return <<cast(*s16) data;
        if info.runtime_size == 4 return <<cast(*s32) data;
    }
    bits: s64; memcpy(*bits, data, info.runtime_size); return bits;
}
property_draw_value :: (editor: *Property_Editor, label: string, data: *void, info: *Type_Info, depth: s64) -> bool {
    if data == null || info == null || depth > editor.max_depth return false;
    name := temp_c_string(label);
    // Labels distinguish overlapping union fields; addresses distinguish rows.
    IM.PushID(data); defer IM.PopID();
    if info.type == .BOOL return IM.Checkbox(name, cast(*bool) data);
    if info.type == .INTEGER {
        integer := cast(*Type_Info_Integer) info;
        kind: IM.DataType;
        if info.runtime_size == 1 kind = .S8;
        else if info.runtime_size == 2 kind = .S16;
        else if info.runtime_size == 4 kind = .S32;
        else if info.runtime_size == 8 kind = .S64;
        else return false;
        if !integer.signed kind = cast(IM.DataType) (cast(s32) kind + 1);
        return IM.DragScalar(name, kind, data);
    }
    if info.type == .FLOAT {
        kind := IM.DataType.Float;
        if info.runtime_size == 8 kind = .Double;
        return IM.DragScalar(name, kind, data, 0.1);
    }
    if info.type == .STRING {
        value := cast(*string) data;
        if value.count >= 4096 { IM.Text("%: string exceeds editor limit (4095 bytes)", label); return false; }
        text, exists := table_find(*editor.strings, data);
        if !exists {
            text.bytes = NewArray(4096, u8);
            table_set(*editor.strings, data, text);
        }
        if value.data != text.bytes.data {
            memcpy(text.bytes.data, value.data, value.count); text.bytes[value.count] = 0;
        }
        if IM.InputText(name, text.bytes.data, cast(u64) text.bytes.count) {
            count: s64; while count < text.bytes.count && text.bytes[count] != 0 count += 1;
            <<value = .{data = text.bytes.data, count = count}; return true;
        }
        return false;
    }
    if info.type == .ENUM {
        e := cast(*Type_Info_Enum) info;
        current := property_read_integer(data, e.internal_type);
        preview := tprint("%", current);
        for v, i: e.values if v == current { preview = e.names[i]; break; }
        changed := false;
        if IM.BeginCombo(name, temp_c_string(preview)) {
            for v, i: e.values {
                if IM.Selectable(temp_c_string(e.names[i]), v == current) {
                    memcpy(data, *v, info.runtime_size); changed = true;
                }
            }
            IM.EndCombo();
        }
        return changed;
    }
    if info.type == .STRUCT {
        s := cast(*Type_Info_Struct) info;
        // Union members overlap and cannot be edited without a discriminant.
        if ((cast(u32) s.textual_flags) & (cast(u32) Struct_Textual_Flags.UNION)) != 0 { IM.Text("%: union", label); return false; }
        changed := false;
        if IM.TreeNode(name) {
            for member: s.members {
                if (member.flags & .CONSTANT) != 0 || (member.flags & .IMPORTED) != 0 continue;
                hidden := false;
                for note: member.notes if note == "editor_hide" hidden = true;
                if hidden continue;
                if property_draw_value(editor, member.name, cast(*u8) data + member.offset_in_bytes, member.type, depth + 1) changed = true;
            }
            IM.TreePop();
        }
        return changed;
    }
    if info.type == .ARRAY {
        a := cast(*Type_Info_Array) info;
        count := a.array_count; bytes := cast(*u8) data;
        if a.array_type != .FIXED {
            view := cast(*[] u8) data; count = view.count; bytes = view.data;
        }
        changed := false;
        if IM.TreeNode(name) {
            for i: 0..min(count, 256)-1 {
                if property_draw_value(editor, tprint("[%]", i), bytes + i * a.element_type.runtime_size, a.element_type, depth + 1) changed = true;
            }
            if count > 256 IM.Text("Showing first 256 of % elements", count);
            IM.TreePop();
        }
        return changed;
    }
    IM.Text("%: unsupported field type (%)", label, info.type);
    return false;
}

// Selection changes only the GUID. Acquire/release the actual asset in the
// application; listing the manifest does not upload textures or load blobs.
asset_selector :: (label: string, manager: *EA.Asset_Manager, guid: *EA.Guid, extension: string = "") -> bool {
    if !manager.manifest_loaded {
        _ := EA.manifest_load(manager); manager.manifest_loaded = true;
    }
    preview := "<none>";
    if !EA.guid_equals(<<guid, EA.GUID_NONE) preview = "<missing asset>";
    for manager.manifest if EA.guid_equals(it, <<guid) { preview = it_index; break; }
    IM.PushID(guid); defer IM.PopID();
    changed := false;
    if IM.BeginCombo(temp_c_string(label), temp_c_string(preview)) {
        if IM.Selectable("<none>", EA.guid_equals(<<guid, EA.GUID_NONE)) { <<guid = EA.GUID_NONE; changed = true; }
        for manager.manifest {
            path := it_index;
            if extension.count > 0 {
                if path.count < extension.count continue;
                suffix := string.{data = path.data + path.count - extension.count, count = extension.count};
                if suffix != extension continue;
            }
            if IM.Selectable(temp_c_string(path), EA.guid_equals(it, <<guid)) { <<guid = it; changed = true; }
        }
        IM.EndCombo();
    }
    return changed;
}
