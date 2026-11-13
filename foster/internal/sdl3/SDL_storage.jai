// SDL_storage.h — the SDL_Storage subset used by storage/content_storage.jai.
// Signatures transcribed from the vendored SDL 3.4.12 headers
// (tools/sdl3/include/SDL3/SDL_storage.h) and cross-checked against the
// exports of the shipped SDL3.dll.
//
// A few types live in other SDL headers in C but are declared here, because the
// storage API is their only user in this port (same practice as SDL_free being
// declared in SDL_filesystem.jai):
//   SDL_PathType / SDL_PathInfo / SDL_EnumerationResult and
//   SDL_EnumerateDirectoryCallback  — SDL_filesystem.h
//   SDL_Time                        — SDL_stdinc.h
// SDL_PropertiesID comes from SDL_properties.jai (loaded first in module.jai).

/* Opaque handle types */

SDL_Storage :: void;

/* SDL_stdinc.h */
SDL_Time :: s64;   // nanoseconds since the Unix epoch

/* SDL_filesystem.h */

using SDL_PathType :: enum s32 {
    SDL_PATHTYPE_NONE;      // path does not exist
    SDL_PATHTYPE_FILE;      // a normal file
    SDL_PATHTYPE_DIRECTORY; // a directory
    SDL_PATHTYPE_OTHER;     // device node, pipe, etc.
}

SDL_PathInfo :: struct {
    type:        SDL_PathType;
    size:        u64;        // file size in bytes
    create_time: SDL_Time;
    modify_time: SDL_Time;
    access_time: SDL_Time;
}

using SDL_EnumerationResult :: enum s32 {
    SDL_ENUM_CONTINUE;  // keep enumerating
    SDL_ENUM_SUCCESS;   // stop, successfully
    SDL_ENUM_FAILURE;   // stop, as a failure
}

SDL_EnumerateDirectoryCallback :: #type (userdata: *void, dirname: *u8, fname: *u8) -> SDL_EnumerationResult #c_call;

/* SDL_storage.h */

#if OS != .WASM {
SDL_OpenTitleStorage :: (override_path: *u8, props: SDL_PropertiesID) -> *SDL_Storage #foreign SDL3;
SDL_OpenUserStorage  :: (org: *u8, app: *u8, props: SDL_PropertiesID) -> *SDL_Storage #foreign SDL3;
SDL_OpenFileStorage  :: (path: *u8) -> *SDL_Storage #foreign SDL3;

SDL_CloseStorage :: (storage: *SDL_Storage) -> bool #foreign SDL3;
SDL_StorageReady :: (storage: *SDL_Storage) -> bool #foreign SDL3;

SDL_GetStorageFileSize :: (storage: *SDL_Storage, path: *u8, length: *u64) -> bool #foreign SDL3;
SDL_ReadStorageFile    :: (storage: *SDL_Storage, path: *u8, destination: *void, length: u64) -> bool #foreign SDL3;
SDL_WriteStorageFile   :: (storage: *SDL_Storage, path: *u8, source: *void, length: u64) -> bool #foreign SDL3;

SDL_CreateStorageDirectory :: (storage: *SDL_Storage, path: *u8) -> bool #foreign SDL3;
SDL_EnumerateStorageDirectory :: (storage: *SDL_Storage, path: *u8,
                                  callback: SDL_EnumerateDirectoryCallback, userdata: *void) -> bool #foreign SDL3;
SDL_RemoveStoragePath :: (storage: *SDL_Storage, path: *u8) -> bool #foreign SDL3;
SDL_RenameStoragePath :: (storage: *SDL_Storage, oldpath: *u8, newpath: *u8) -> bool #foreign SDL3;
SDL_CopyStorageFile   :: (storage: *SDL_Storage, oldpath: *u8, newpath: *u8) -> bool #foreign SDL3;
SDL_GetStoragePathInfo :: (storage: *SDL_Storage, path: *u8, info: *SDL_PathInfo) -> bool #foreign SDL3;
SDL_GetStorageSpaceRemaining :: (storage: *SDL_Storage) -> u64 #foreign SDL3;
}

// SDL_GlobFlags (SDL_filesystem.h) — only the one flag SDL defines.
using SDL_GlobFlags :: enum_flags u32 {
    SDL_GLOB_CASEINSENSITIVE :: 0x00000001;
}

// Returns a NULL-terminated array of paths (one SDL allocation, free with
// SDL_free) plus the entry count in *count; NULL on failure.
#if OS != .WASM {
SDL_GlobStorageDirectory :: (storage: *SDL_Storage, path: *u8, pattern: *u8,
                             flags: SDL_GlobFlags, count: *s32) -> **u8 #foreign SDL3;
}

// Not bound (no user yet): the SDL_StorageInterface vtable used for custom
// backends, and SDL_EnumerateDirectory / SDL_GlobDirectory from
// SDL_filesystem.h.
