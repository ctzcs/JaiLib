// 热重载前置命令测试的夹具：充当生成器和编译器，由测试运行时现编
// （对应 olib tests/core/hotreload/testdata/pre_command/main.odin，那边是 odin build 现编，
//  这里是 jaic 现编 —— jaic 一次只编一个入口文件，所以夹具就是一个普通 .jai 程序）。
//
// 用法（与 olib 完全相同的三个子命令）：
//   fixture generate <目标文件> <内容>
//   fixture build -out:<产物路径>
//   fixture fail
#import "Basic";
FILE :: #import "File";

main :: () {
    args := get_command_line_arguments();
    // args[0] 是 exe 自己的路径（与 odin 的 os.args 一致）。
    mode := ifx args.count > 1 then args[1] else "";
    if mode == "generate" {
        if args.count < 4 exit(1);
        path := args[2];
        text := args[3];
        // 与真实生成器一致：内容相同不写盘。
        previous, read_ok := FILE.read_entire_file(path);
        if read_ok {
            same := previous == text;
            free(previous);
            if same return;
        }
        if !FILE.write_entire_file(path, text) exit(1);
        return;
    }
    if mode == "build" {
        if args.count < 3 exit(1);
        out := args[2];
        // odin 版是 strings.trim_prefix(args[1], "-out:")；这里直接跳过 5 个字节。
        if out.count <= 5 exit(1);
        path := string.{ out.count - 5, out.data + 5 };
        if !FILE.write_entire_file(path, "module") exit(1);
        return;
    }
    // odin: os.exit(7)
    if mode == "fail" exit(7);
}

// Loop scopes adapted.
