// shader_lab:material_files —— ShaderLab 的文件路径适配；数据编解码交给 material/shader 包，
// 读取与原子保存由本文件用 Jai 的 File 模块完成。
// 一比一移植自 olib kit/tools/shader_lab/material_files.odin。Jai 差异：
//   | olib (Odin)                                          | JaiLib (Jai)                                        |
//   | ---------------------------------------------------- | --------------------------------------------------- |
//   | `foster.StorageContainer{Root = …}` + ReadAllBytes    | FILE.read_entire_file(完整路径)                      |
//   | `foster.WriteAllBytesAtomic`                         | F.storage_write_all_bytes_atomic      |
//   | `filepath.dir / base / abs / rel`                    | sl_path_dir / STRING.path_filename / FILE.get_absolute_path / sl_relative_path |
//   | `strings.clone(value.texture)`                       | copy_string                                          |
//   | `delete(bytes)`                                      | free(bytes.data)                                     |
// Save flushes a sibling temporary file and atomically replaces the destination.
// 导入由 module.jai 提供。

//@region 路径小工具（material 包内的同名助手只在那个包里可见）

sl_path_dir :: (path: string) -> string {
    for i: path.count - 1..0 {
        if path[i] == 47 || path[i] == 92 return STRING.slice(path, 0, i); // 47 '/', 92 '\\'
    }
    return ".";
}

sl_absolute :: (path: string) -> string {
    if sl_is_absolute(path) return copy_string(path);
    absolute, resolved := FILE.get_absolute_path(path);
    if !resolved return copy_string(path);
    return absolute;
}

// olib 的 filepath.rel(directory, absolute)：算相对路径；失败时调用方用绝对路径。
sl_relative_path :: (directory: string, target: string) -> (string, bool) {
    if directory.count == 0 return target, false;
    if target.count < directory.count return target, false;
    for i: 0..directory.count - 1 {
        a := directory[i];
        b := target[i];
        if a == 92 a = 47; // '\\' -> '/'
        if b == 92 b = 47;
        if a != b return target, false;
    }
    if target.count == directory.count return target, false;
    if target[directory.count] != 47 && target[directory.count] != 92 return target, false;
    return STRING.slice(target, directory.count + 1, target.count - directory.count - 1), true;
}
//@endregion

//@region 预设（单参数组）读写

preset_file_load :: (schema: sh.Schema, path: string) -> ([] sh.Value, string) {
    // jacket: read_entire_file -> (string, bool)；kit 的编解码要 [] u8，这里零拷贝看过去。
    text, ok := FILE.read_entire_file(path);
    if !ok || text.count == 0 {
        if text.data != null free(text.data);
        return .[], tprint("%: cannot read material or file is empty", path);
    }
    defer free(text.data);
    values, reason := sh.resource_decode(schema, sl_bytes_view(text));
    if reason != "" return .[], tprint("%: %", path, reason);
    directory := sl_absolute(sl_path_dir(path));
    defer free(directory.data);
    for *value, i: values {
        if schema.fields[i].kind != .Texture || value.texture == "" continue;
        if !sl_is_absolute(value.texture) {
            joined := tprint("%/%", directory, value.texture);
            if value.texture.data != null free(value.texture.data);
            value.texture = copy_string(joined);
        }
    }
    return values, "";
}

// 同目录临时文件完成后才替换；失败保留旧文件。texture_root 指定输入相对贴图的根。
preset_file_save :: (schema: sh.Schema, values: [] sh.Value, path: string, texture_root := "") -> string {
    if path == "" return "Empty material path";
    checked, check_error := sh.resource_encode(schema, values);
    if checked.data != null array_free(checked);
    if check_error != "" return check_error;
    owned := sh.values_make(schema, schema, values);
    defer sh.values_dispose(owned);
    directory := sl_absolute(sl_path_dir(path));
    defer free(directory.data);
    for *value, i: owned {
        if schema.fields[i].kind != .Texture || value.texture == "" continue;
        texture := value.texture;
        if !sl_is_absolute(texture) && texture_root != "" texture = tprint("%/%", texture_root, texture);
        absolute := sl_absolute(texture);
        defer free(absolute.data);
        relative, ok := sl_relative_path(directory, absolute);
        if value.texture.data != null free(value.texture.data);
        if ok value.texture = copy_string(relative);
        else      value.texture = copy_string(absolute);
    }
    bytes, reason := sh.resource_encode(schema, owned);
    defer if bytes.data != null array_free(bytes);
    if reason != "" return reason;
    return material_file_write(path, bytes);
}

material_file_write :: (path: string, bytes: [] u8) -> string {
    // jacket: write_entire_file(name, data: string)；bytes 是 kit 侧的 [] u8 视图。
    storage := F.Storage_Container.{ Writable = true };
    if !F.storage_write_all_bytes_atomic(*storage, path, bytes) return "Cannot save material; previous file retained";
    return "";
}
//@endregion

//@region 整材质（多参数组）读写

material_file_load :: (shader: sh.Shader_Desc, schemas: [] sh.Schema, path: string) -> (sh.Instance, string) {
    text, ok := FILE.read_entire_file(path);
    if !ok || text.count == 0 {
        if text.data != null free(text.data);
        return sh.Instance.{}, "Cannot read material instance or file is empty";
    }
    defer free(text.data);
    result, reason := sh.instance_decode(shader, schemas, sl_bytes_view(text));
    if reason != "" return sh.Instance.{}, reason;
    directory := sl_absolute(sl_path_dir(path));
    defer free(directory.data);
    for *group: result.groups {
        for *value, i: group.values {
            if group.schema.fields[i].kind != .Texture || value.texture == "" continue;
            if sl_is_absolute(value.texture) continue;
            joined := tprint("%/%", directory, value.texture);
            if value.texture.data != null free(value.texture.data);
            value.texture = copy_string(joined);
        }
    }
    return result, "";
}

material_file_save :: (instance: sh.Instance, path: string, texture_root := "") -> string {
    if path == "" return "Empty material path";
    checked, check_error := sh.instance_encode(instance);
    if checked.data != null array_free(checked);
    if check_error != "" return check_error;
    // 临时副本只借用 sh.Schema，独立拥有 sh.Value；不改调用方的路径。
    copy_instance := sh.Instance.{ shader = instance.shader, groups = .[] };
    array_resize(*copy_instance.groups, instance.groups.count);
    defer {
        for *group: copy_instance.groups sh.values_dispose(group.values);
        if copy_instance.groups.data != null array_free(copy_instance.groups);
    }
    directory := sl_absolute(sl_path_dir(path));
    defer free(directory.data);
    for group, i: instance.groups {
        if group.values.count != group.schema.fields.count return "Material value count differs from schema";
        copy_instance.groups[i] = sh.Instance_Group.{
            schema = group.schema,
            values = sh.values_make(group.schema, group.schema, group.values),
        };
        for *value, j: copy_instance.groups[i].values {
            if group.schema.fields[j].kind != .Texture || value.texture == "" continue;
            texture := value.texture;
            if !sl_is_absolute(texture) && texture_root != "" texture = tprint("%/%", texture_root, texture);
            absolute := sl_absolute(texture);
            defer free(absolute.data);
            relative, ok := sl_relative_path(directory, absolute);
            if value.texture.data != null free(value.texture.data);
            if ok value.texture = copy_string(relative);
            else      value.texture = copy_string(absolute);
        }
    }
    bytes, reason := sh.instance_encode(copy_instance);
    defer if bytes.data != null array_free(bytes);
    if reason != "" return reason;
    return material_file_write(path, bytes);
}
//@endregion
