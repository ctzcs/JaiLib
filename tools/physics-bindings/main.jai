#import "Basic";
B :: #import "Bindings_Generator";

main :: () {
    args := get_command_line_arguments();
    assert(args.count >= 5, "usage: generator HEADER INCLUDE LIBRARY OUTPUT");
    options: B.Generate_Bindings_Options;
    for i: 5..args.count - 1 array_add(*options.system_include_paths, args[i]);
    array_add(*options.include_paths, args[2]);
    array_add(*options.source_files, args[1]);
    options.strip_flags = .FUNCTIONS_WITH_VALIST;
    array_add(*options.extra_clang_arguments, "-std=c17", "-x", "c");
    options.generate_library_declarations = false;
    options.add_generator_command = false;
    options.strip_enum_prefixes = false;
    options.auto_detect_enum_prefixes = false;
    options.generate_printf_wrappers = false;
    assert(B.generate_bindings(options, args[4], log_results = false));
}
