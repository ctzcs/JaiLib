// SDL_log.h

using SDL_LogPriority :: enum s32 {
    SDL_LOG_PRIORITY_INVALID;
    SDL_LOG_PRIORITY_TRACE;
    SDL_LOG_PRIORITY_VERBOSE;
    SDL_LOG_PRIORITY_DEBUG;
    SDL_LOG_PRIORITY_INFO;
    SDL_LOG_PRIORITY_WARN;
    SDL_LOG_PRIORITY_ERROR;
    SDL_LOG_PRIORITY_CRITICAL;
}

SDL_LogOutputFunction :: #type (userdata: *void, category: s32, priority: SDL_LogPriority, message: *u8) #c_call;

#if OS != .WASM {
SDL_SetLogOutputFunction :: (callback: SDL_LogOutputFunction, userdata: *void) #foreign SDL3;
}
