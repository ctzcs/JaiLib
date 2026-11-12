// WASM64 probe using the allocator supplied with this Jai distribution.
#import "Basic";
#import "Compiler";
#run {
    set_build_options_dc(.{do_output=false});
    w := compiler_create_workspace("JaiLib WASM64 probe");
    options := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(),*options);
    options.output_type=.EXECUTABLE; options.backend=.LLVM;
    options.os_target=.WASM; options.cpu_target=.CUSTOM;
    options.backtrace_on_crash=.OFF;
    options.llvm_options.target_system_features="+bulk-memory";
    options.llvm_options.enable_split_modules=false;
    options.llvm_options.function_sections=true;
    options.output_path=tprint("%../../.test_tmp/web_probe/",#filepath);
    options.output_executable_name="probe";
    base := compiler_get_base_path();
    paths: [..]string;
    array_add(*paths,tprint("%/examples/wasm/modules",base));
    array_add(*paths,tprint("%../../Libs/Engine",#filepath));
    array_add(*paths,tprint("%../../..",#filepath));
    for options.import_path array_add(*paths,it);
    options.import_path=paths;
    options.additional_linker_arguments=.["--stack-first","-z","stack-size=24576",tprint("%/examples/wasm/walloc.o",base)];
    remap_import(w,"*","Default_Allocator","Walloc");
    file := "main.jai";
    for get_build_options().compile_time_command_line if it == "gfx" {file="gfx.jai";options.output_executable_name="gfx-probe";}
    set_build_options(options,w);
    add_build_file(tprint("%1%2",#filepath,file),w);
}


