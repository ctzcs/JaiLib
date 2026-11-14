// Thin CLI over the existing Jai scanner; generated files require explicit #load.
#import "Basic";
CG :: #import "core/codegen";

main :: () {
    args := get_command_line_arguments();
    source, tag, name, output: string;
    check := false;
    i := 1;
    while i < args.count {
        arg := args[i];
        if arg == "--check" {
            check = true;
            i += 1;
            continue;
        }
        if arg == "--help" {
            print("auto_gen --source DIR --tag TAG --enum NAME --out NAME_generated.jai [--check]\n");
            return;
        }
        i += 1;
        if i >= args.count {
            print("Missing option value\n");
            exit(2);
        }
        if arg == "--source" source = args[i];
        else if arg == "--tag" tag = args[i];
        else if arg == "--enum" name = args[i];
        else if arg == "--out" output = args[i];
        else {
            print("Unknown option: %\n", arg);
            exit(2);
        }
        i += 1;
    }
    if source == "" || tag == "" || name == "" || output == "" {
        print("Required: --source DIR --tag TAG --enum NAME --out NAME_generated.jai\n");
        exit(2);
    }
    generator: CG.Generator;
    options: [..] string;
    if check array_add(*options, "-check");
    CG.begin(*generator, options);
    array_free(options);
    generator.prune = false;
    generator.strict_syntax = true;
    scan := CG.scan(*generator, source);
    CG.kind_enum(*generator, scan, tag, name, output);
    exit(cast(s32) CG.finish(*generator));
}
