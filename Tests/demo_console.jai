#import "Basic";

// Explorer gives a console exe its own short-lived console. Keep that window
// open for the result; do not block callers in an existing terminal or CI.
demo_console_finish :: (success: bool) {
    automatic := false;
    force_wait := false;
    for get_command_line_arguments() {
        if it == "auto" automatic = true;
        if it == "--wait" force_wait = true;
    }
    #if OS == .WINDOWS {
        processes: [8] u32;
        count := Demo_GetConsoleProcessList(*processes[0], 8);
        input := Demo_GetStdHandle(0xFFFFFFF6); // STD_INPUT_HANDLE (-10 as DWORD)
        mode: u32;
        // A redirected input stream cannot acknowledge a console prompt.
        if !automatic && (count == 1 || force_wait) && Demo_GetConsoleMode(input, *mode) != 0 {
            print("\nFinished. Press Enter to close this window.\n");
            buffer: [256] u16;
            read: u32;
            _ := Demo_ReadConsoleW(input, *buffer[0], 256, *read, null);
        }
    }
    if !success exit(1);
}

#scope_file
#if OS == .WINDOWS {
    Demo_Kernel32 :: #system_library "kernel32";
    Demo_GetConsoleProcessList :: (ids: *u32, size: u32) -> u32 #foreign Demo_Kernel32 "GetConsoleProcessList";
    Demo_GetStdHandle :: (kind: u32) -> *void #foreign Demo_Kernel32 "GetStdHandle";
    Demo_GetConsoleMode :: (handle: *void, mode: *u32) -> s32 #foreign Demo_Kernel32 "GetConsoleMode";
    Demo_ReadConsoleW :: (handle: *void, buffer: *u16, size: u32, read: *u32, reserved: *void) -> s32 #foreign Demo_Kernel32 "ReadConsoleW";
}
