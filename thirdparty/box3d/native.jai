// The solver and inline bridges must use the same target and precision.
#scope_module
#if OS == .WINDOWS && CPU == .X64 {
    native :: #library "native/windows_x64/box3d";
    helpers :: #library "native/windows_x64/helpers";
} else #if OS == .LINUX && CPU == .X64 {
    native :: #library "native/linux_x64/box3d";
    helpers :: #library "native/linux_x64/helpers";
} else #if OS == .LINUX && CPU == .ARM64 {
    native :: #library "native/linux_arm64/box3d";
    helpers :: #library "native/linux_arm64/helpers";
} else #if OS == .MACOS && CPU == .X64 {
    native :: #library "native/macos_x64/box3d";
    helpers :: #library "native/macos_x64/helpers";
} else #if OS == .MACOS && CPU == .ARM64 {
    native :: #library "native/macos_arm64/box3d";
    helpers :: #library "native/macos_arm64/helpers";
} else {
    #assert false, "box3d: supported targets are Windows x64, Linux x64/ARM64 and macOS x64/ARM64";
}

#if OS == .LINUX {
    math_library :: #library,system,link_always "m";
    thread_library :: #library,system,link_always "pthread";
}
