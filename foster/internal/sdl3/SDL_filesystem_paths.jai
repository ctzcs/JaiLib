// SDL_filesystem.h —— 任意路径（非 SDL_Storage）的文件系统接口。
// SDL_PathInfo / SDL_PathType 由 SDL_storage.jai 声明，本文件必须在其之后 #load。

#if OS != .WASM {
SDL_GetPathInfo       :: (path: *u8, info: *SDL_PathInfo) -> bool #foreign SDL3;
SDL_CreateDirectory   :: (path: *u8) -> bool #foreign SDL3;
SDL_RemovePath        :: (path: *u8) -> bool #foreign SDL3;
SDL_RenamePath        :: (old_path: *u8, new_path: *u8) -> bool #foreign SDL3;
// 返回以 NULL 结尾的 char* 数组（每项与数组本身都要 SDL_free），失败返回 NULL。
SDL_GlobDirectory     :: (path: *u8, pattern: *u8, flags: u32, count: *s32) -> **u8 #foreign SDL3;
}
