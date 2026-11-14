// dev:compiler —— 开发期编译器：独立临时目录承载完整候选版本，不覆盖发布产物。
// 一比一移植自 olib kit/rendering/shader/dev/compiler.odin。
//
// 与 olib 的差异（逐条对应）：
//   | olib (Odin)                                        | JaiLib (Jai)                                          |
//   | -------------------------------------------------- | ----------------------------------------------------- |
//   | context.allocator = runtime.heap_allocator()        | dev_heap() + push_allocator（系统堆；不借用调用方分配器）|
//   | os.make_directory_temp("", "olib_shader_*", temp)   | dev_temp_directory（TEMP + 原子计数器 + 建目录）        |
//   | os.read_all_directory_by_path + Dir_Entry 递归       | FU.visit_files(root, recursive, ...)                  |
//   | os.write_entire_file / os.read_entire_file          | FILE.write_entire_file / read_entire_file             |
//   | os.remove / os.remove(root)                         | FILE.file_delete / delete_directory                   |
//   | filepath.dir / base / rel                           | STRING.path_strip_filename / path_filename + 前缀切片  |
//   | strings.replace_all(rel, "\\", "/")                 | dev_normalize_path（复制并按 '/' 归一）                 |
//   | slice.sort(paths[:])                                | SORT.quick_sort + compare_strings                     |
//   | json.unmarshal(metadata, &resources[i])             | dev_json_resources（core/encoding 的 Json_Value 逐键取）|
//   | json.marshal(struct{...})                           | dev_write_provenance（同形的固定键序 JSON 文本）        |
//   | delete(x, heap) / delete(slice, heap)               | free(x.data)（同样的堆）                                |
//   | walk 回调里 binding 目录项                            | 回调里 copy_string（visit_files 的名字只在回调内有效）   |
//
// 编译本身要真的启动 shadercross/dxc —— jfoster/JaiLib 没有这条工具链，
// 所以 compile() 在这里**逐字可编译、运行期明确失败**：comp.identify 找不到工具时
// 返回 "Cannot find compiler ... on PATH"，注入执行器后整条路径才是活的（见 compile 包文件头）。
#import "Basic";

//@region 编译候选

Resources :: struct {
    samplers: int;
    storage_textures: int;
    storage_buffers: int;
    uniform_buffers: int;
}

// Jai 的结构体相等要显式声明（运算符按词法作用域解析）。
operator == :: (a: Resources, b: Resources) -> bool {
    return a.samplers == b.samplers && a.storage_textures == b.storage_textures &&
           a.storage_buffers == b.storage_buffers && a.uniform_buffers == b.uniform_buffers;
}

Build :: struct {
    code: [2][] u8;
    resources: [2] Resources;
    error: string;
    provenance: string; // 仅完整候选成功后填写；源码、工具分发版本、固定参数及输出字节指纹。
}

build_dispose :: (b: *Build) {
    for code: b.code {
        if code.data != null free(code.data);
    }
    if b.error.data != null free(b.error.data);
    if b.provenance.data != null free(b.provenance.data);
    b.* = Build.{};
}

// source 为绝对路径；format 是 spv/dxil/msl。调用方拥有结果，使用 build_dispose。
compile :: (source: string, format: string, source_text := "", options := comp.Options.{}) -> (result: Build) {
    push_allocator(dev_heap());
    if format != "spv" && format != "dxil" && format != "msl" {
        result.error = copy_string("Unsupported shader format");
        return result;
    }
    tc, tool_error := comp.identify(options, temp);
    if tool_error != "" {
        result.error = copy_string(tool_error);
        return result;
    }

    directory, created := dev_temp_directory("olib_shader_");
    if !created {
        result.error = copy_string("Cannot create shader workspace");
        return result;
    }
    defer dev_remove_workspace(directory);
    root := STRING.path_strip_filename(source);
    if !dev_snapshot_sources(root, directory) || !dev_snapshot_includes(directory) {
        result.error = copy_string("Cannot snapshot shader sources");
        return result;
    }
    local_source := tprint("%/%", directory, STRING.path_filename(source));
    if source_text != "" {
        if !FILE.write_entire_file(local_source, source_text) {
            result.error = copy_string("Cannot write extracted shader program");
            return result;
        }
    }
    stages: [2] string = .["vertex", "fragment"];
    for stage, i: stages {
        base := tprint("%/%", directory, stage);
        spv := tprint("%.spv", base);
        stage_error := comp.stage_compile(tc, local_source, directory, stage, base,
                                         format == "dxil", format == "msl");
        if stage_error != "" {
            result.error = copy_string(stage_error);
            return result;
        }
        reflection := tprint("%/%.json", directory, stage);
        reflect_error := comp.reflect(tc, spv, stage, reflection);
        if reflect_error != "" {
            result.error = copy_string(reflect_error);
            return result;
        }
        metadata, readable := FILE.read_entire_file(reflection);
        parsed := readable && dev_json_resources(metadata, *result.resources[i]);
        if metadata.data != null free(metadata.data);
        if !parsed {
            result.error = copy_string("Cannot read shader resource reflection");
            return result;
        }
        output := tprint("%.%", base, format);
        text, read := FILE.read_entire_file(output);
        if !read || text.count == 0 {
            if text.data != null free(text.data);
            result.error = copy_string("Cannot read compiled shader");
            return result;
        }
        bytes: [] u8;
        bytes, _ = NewArray(text.count, u8);
        memcpy(bytes.data, text.data, text.count);
        free(text.data);
        result.code[i] = bytes;
    }
    sources, fingerprintable := source_fingerprint(directory);
    if !fingerprintable {
        result.error = copy_string("Cannot fingerprint shader snapshot");
        return result;
    }
    hashes: [2] string = .[comp.bytes_hash(result.code[0], temp), comp.bytes_hash(result.code[1], temp)];
    {
        builder: String_Builder;
        dev_write_provenance(*builder, tc.identity, sources, format, hashes);
        result.provenance = builder_to_string(*builder);
        free_buffers(*builder);
    }
    return result;
}
//@endregion

//@region 私有源码快照

// 两个阶段从同一份快照编译，编辑器后续保存不会改写编译中的输入。
// 只复制 .hlsl/.hlsli（同 olib），目录结构原样重建；先序回调保证父目录先建。
dev_snapshot_sources :: (root: string, destination: string) -> bool {
    entries: [..] Dev_Entry;
    defer dev_entries_dispose(entries);
    if !FU.visit_files(root, true, *entries, dev_collect_entry, visit_directories = true) return false;
    for entry: entries {
        relative := dev_relative_path(root, entry.path);
        target := tprint("%/%", destination, relative);
        if entry.is_directory {
            if !FILE.make_directory_if_it_does_not_exist(target) return false;
        } else if STRING.ends_with(entry.path, ".hlsl") || STRING.ends_with(entry.path, ".hlsli") {
            data, readable := FILE.read_entire_file(entry.path);
            if !readable return false;
            written := FILE.write_entire_file(target, data);
            if data.data != null free(data.data);
            if !written return false;
        }
    }
    return true;
}

// 把 olib 标准 include 复制到编译目录的 olib/ 下（项目里同名的 olib/ 会被覆盖）。生成的程序就在该目录，
// DXC 按当前文件所在目录找到 #include "olib/..."；shadercross 只接受一个 -I，留给项目源目录。
dev_snapshot_includes :: (destination: string) -> bool {
    target := tprint("%/olib", destination);
    if !FU.is_directory(target) && !FILE.make_directory_if_it_does_not_exist(target) return false;
    return dev_snapshot_sources(tprint("%/olib", lang.INCLUDE_DIRECTORY), target);
}

// 仅用于 dev_temp_directory 创建、由本编译器写入的目录；不跟随链接。
dev_remove_workspace :: (root: string) {
    entries: [..] Dev_Entry;
    if !FU.visit_files(root, true, *entries, dev_collect_entry, visit_directories = true) {
        dev_entries_dispose(entries);
        return;
    }
    for entry: entries if !entry.is_directory FILE.file_delete(entry.path);
    // 先序遍历：倒着删，子目录先于父目录（与 Tests/kit/storage 的递归删除同理）。
    i := entries.count - 1;
    while i >= 0 {
        if entries[i].is_directory FILE.delete_directory(entries[i].path);
        i -= 1;
    }
    dev_entries_dispose(entries);
    FILE.delete_directory(root);
}
//@endregion

//@region 源码变更检测

// 对目录内所有 .oshader/HLSL/HLSLI 内容计算指纹，包括子目录。include 应放在此根内。
// 内容散列避免编辑器原子保存、时间戳精度以及同长度修改漏检。
source_fingerprint :: (root: string) -> (hash: u64, ok: bool) {
    paths: [..] string;
    if !dev_collect_sources(root, *paths) {
        for path: paths if path.data != null free(path.data);
        if paths.data != null free(paths.data);
        return 0, false;
    }
    SORT.quick_sort(paths, (a: string, b: string) -> s64 {
        return SORT.compare_strings(a, b);
    });
    prefix := dev_directory_prefix(root);
    hash = 1469598103934665603;
    ok = true;
    for path: paths {
        data, readable := FILE.read_entire_file(path);
        if !readable {
            ok = false;
            break;
        }
        relative := path;
        if STRING.begins_with(path, prefix) {
            relative = STRING.slice(path, prefix.count, path.count);
        }
        for b: relative hash = (hash ^ cast(u64) b) * 1099511628211;
        for b: data hash = (hash ^ cast(u64) b) * 1099511628211;
        hash = (hash ^ cast(u64) data.count) * 1099511628211;
        if data.data != null free(data.data);
    }
    for path: paths if path.data != null free(path.data);
    if paths.data != null free(paths.data);
    if !ok return 0, false;
    return hash, true;
}

// .oshader / .hlsl / .hlsli 的完整路径（含子目录）；名字归当前 allocator。
dev_collect_sources :: (root: string, paths: *[..] string) -> bool {
    return FU.visit_files(root, true, paths, dev_collect_source_path);
}

dev_collect_source_path :: (info: *FU.File_Visit_Info, paths: *[..] string) {
    if info.is_directory return;
    if STRING.ends_with(info.short_name, ".hlsl") || STRING.ends_with(info.short_name, ".hlsli") ||
       STRING.ends_with(info.short_name, ".oshader") {
        array_add(paths, copy_string(info.full_name));
    }
}
//@endregion

//@region 目录与 JSON 小工具（dev 包内共用）

// olib 的 runtime.heap_allocator：内部跨线程数据只用它，不碰调用方的帧临时分配器。
dev_heap :: () -> Allocator {
    return Allocator.{ DEFAULT.allocator_proc, null };
}

DEV_TEMP_COUNTER: s64;

// olib 的 os.make_directory_temp：TEMP/TMP 下按进程内计数器取独占目录（原子递增，多线程安全）。
dev_temp_directory :: (prefix: string) -> (string, bool) {
    base := ENV.environment_variable("TEMP");
    if base == "" base = ENV.environment_variable("TMP");
    if base == "" base = "/tmp";
    normalized := dev_normalize_path(base);
    defer free(normalized.data);
    for 0..63 {
        index := ATOMICS.atomic_add(*DEV_TEMP_COUNTER, 1);
        candidate := tprint("%/%_%", normalized, prefix, index);
        if FILE.make_directory_if_it_does_not_exist(candidate) return copy_string(candidate), true;
    }
    return "", false;
}

// 把反斜杠归一成 '/' 的独立副本（FU 的路径分隔符是 '/'，前缀比较要一致）。
dev_normalize_path :: (path: string) -> string {
    result := copy_string(path);
    STRING.path_overwrite_separators(result, #char "/");
    return result;
}

// 目录前缀：带结尾 '/'，用于把完整路径切成相对路径。
dev_directory_prefix :: (root: string) -> string {
    if STRING.ends_with(root, "/") return root;
    return tprint("%/", root);
}

dev_relative_path :: (root: string, path: string) -> string {
    prefix := dev_directory_prefix(root);
    if STRING.begins_with(path, prefix) return STRING.slice(path, prefix.count, path.count);
    return STRING.path_filename(path);
}

Dev_Entry :: struct {
    path: string;
    is_directory: bool;
}

dev_collect_entry :: (info: *FU.File_Visit_Info, entries: *[..] Dev_Entry) {
    array_add(entries, Dev_Entry.{ copy_string(info.full_name), info.is_directory });
}

dev_entries_dispose :: (entries: [..] Dev_Entry) {
    for entry: entries if entry.path.data != null free(entry.path.data);
    if entries.data != null free(entries.data);
}

// shadercross 的 SPIRV->JSON 反射里只取四个计数；缺键保持 0（odin 的反射反序列化同理）。
dev_json_resources :: (metadata: string, out: *Resources) -> bool {
    document, parsed := JSON.json_parse(metadata, temp);
    if !parsed || document.kind != .Object return false;
    resources: Resources;
    dev_json_int(document, "samplers", *resources.samplers);
    dev_json_int(document, "storage_textures", *resources.storage_textures);
    dev_json_int(document, "storage_buffers", *resources.storage_buffers);
    dev_json_int(document, "uniform_buffers", *resources.uniform_buffers);
    out.* = resources;
    return true;
}

dev_json_int :: (object: JSON.Json_Value, key: string, out: *int) {
    if object.kind != .Object return;
    found, value := HASH.table_find(*object.object_val, key);
    if !found return;
    member := <<value;
    if member.kind == .Integer {
        out.* = cast(int) member.int_val;
    } else if member.kind == .Float {
        out.* = cast(int) member.number_val;
    }
}

// olib 的 json.marshal(struct{toolchain, sources, format, outputs})：键序与层级照抄，
// 只保证「同样的输入给出同样的字节」，方便宿主把它当编译指纹的一部分。
dev_write_provenance :: (b: *String_Builder, identity: comp.Identity, sources: u64,
                         format: string, outputs: [2] string) {
    print_to_builder(b, "{\"toolchain\":{\"policy\":");
    dev_write_quoted(b, identity.policy);
    print_to_builder(b, ",\"dxil\":");
    dev_write_quoted(b, identity.dxil);
    print_to_builder(b, ",\"shadercross\":{\"path\":");
    dev_write_quoted(b, identity.shadercross.path);
    print_to_builder(b, ",\"version\":");
    dev_write_quoted(b, identity.shadercross.version);
    print_to_builder(b, "},\"dxc\":{\"path\":");
    dev_write_quoted(b, identity.dxc.path);
    print_to_builder(b, ",\"version\":");
    dev_write_quoted(b, identity.dxc.version);
    print_to_builder(b, "}},\"sources\":%,\"format\":", sources);
    dev_write_quoted(b, format);
    print_to_builder(b, ",\"outputs\":[");
    dev_write_quoted(b, outputs[0]);
    print_to_builder(b, ",");
    dev_write_quoted(b, outputs[1]);
    print_to_builder(b, "]}");
}

dev_write_quoted :: (b: *String_Builder, value: string) {
    print_to_builder(b, "\"");
    for c: value {
        if c == #char "\"" {
            print_to_builder(b, "\\\"");
        } else if c == #char "\\" {
            print_to_builder(b, "\\\\");
        } else if c == #char "\n" {
            print_to_builder(b, "\\n");
        } else if c == #char "\r" {
            print_to_builder(b, "\\r");
        } else if c < 32 {
            print_to_builder(b, "\\u00%", c);
        } else {
            append(b, c);
        }
    }
    print_to_builder(b, "\"");
}
//@endregion
