// dev:shader_files —— .oshader 候选包：程序文本和参数来自同一次文件读取。
// 一比一移植自 olib kit/rendering/shader/dev/shader_files.odin。
//
// Jai 侧差异（逐条对应）：
//   | olib (Odin)                                        | JaiLib (Jai)                                          |
//   | -------------------------------------------------- | ----------------------------------------------------- |
//   | context.allocator = runtime.heap_allocator()        | dev_heap() + push_allocator（系统堆）                   |
//   | os.read_all_directory_by_path + 递归                | source_fingerprint / dev_collect_sources（compiler.jai）|
//   | make([]sh.Schema, len+len) + copy + delete          | [..] sh.Schema（动态数组；dispose 里 array_free）        |
//   | filepath.abs(path, temp)                            | FILE.get_absolute_path(path)                          |
//   | filepath.rel + replace_all("\\", "/")               | dev_relative_path（路径已归一成 '/'）                   |
//   | strings.clone(...)                                  | copy_string(...)                                      |
//   | for old in result.shaders（值拷贝）                  | for old: b.shaders（同样只读）                          |
#import "Basic";

Parameter_Program :: struct {
    group: string;
    source: string;
    text: string;
}

// 递归读取 source_directory 下的 .oshader。
// 全部持久数据归 dev_heap()，使用 parameter_build_dispose 释放。
parameters_compile :: (source_directory: string) -> (result: Parameter_Build) {
    push_allocator(dev_heap());
    paths: [..] string;
    if !dev_collect_sources(source_directory, *paths) {
        result.error = copy_string("Cannot read shader source directory");
        return result;
    }
    SORT.quick_sort(paths, (a: string, b: string) -> s64 {
        return SORT.compare_strings(a, b);
    });
    defer {
        for path: paths if path.data != null free(path.data);
        if paths.data != null free(paths.data);
    }

    for path: paths {
        if !STRING.ends_with(path, ".oshader") continue;
        data, readable := FILE.read_entire_file(path);
        if !readable {
            result.error = copy_string(tprint("Cannot read %", path));
            return result;
        }
        absolute, resolved := FILE.get_absolute_path(path);
        source_path := path;
        if resolved && absolute != "" source_path = absolute;
        // #line 与诊断都用绝对路径；文档所有权落在 dev_heap()，与 olib 的 context.allocator 一致。
        document := lang.parse(data, source_path);
        if data.data != null free(data.data);
        if document.error != "" {
            result.error = copy_string(document.error);
            lang.dispose(*document);
            if absolute.data != null free(absolute.data);
            return result;
        }
        // olib 的两种重复各自有诊断文本（测试只匹配 "duplicate shader"，但两条都保留）。
        // olib 在遇到第一个重复时立刻返回：先查 shader 名，命中就不再查参数组。
        duplicate: string;
        for old: result.shaders {
            if old.name == document.shader.name {
                duplicate = copy_string(tprint("%: duplicate shader %", path, old.name));
                break;
            }
        }
        if duplicate == "" {
            for schema: document.schemas {
                for old: result.schemas {
                    if old.name == schema.name {
                        duplicate = copy_string(tprint("%: duplicate parameter group %", path, old.name));
                        break;
                    }
                }
                if duplicate != "" break;
            }
        }
        if duplicate != "" {
            if absolute.data != null free(absolute.data);
            lang.dispose(*document);
            result.error = duplicate;
            return result;
        }
        relative := dev_relative_path(source_directory, path);
        for schema, i: document.schemas {
            added := sh.schema_clone(schema);
            sh.shader_free_string(added.shader);
            added.shader = copy_string(relative);
            array_add(*result.schemas, added);
            program := Parameter_Program.{ copy_string(document.schemas[i].name), copy_string(source_path),
                                           copy_string(document.programs[i]) };
            array_add(*result.programs, program);
        }
        array_add(*result.shaders, sh.shader_clone(document.shader));
        lang.dispose(*document);
        if absolute.data != null free(absolute.data);
    }
    return result;
}

// .oshader 和其 HLSL include 共同参与包指纹；提交前再次检查，拒绝过期候选。
parameters_fingerprint :: (source_directory: string) -> (u64, bool) {
    return source_fingerprint(source_directory);
}
