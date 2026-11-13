// Hand-written SDL3 bindings — the subset of SDL actually used by the Foster port.
// Layouts and signatures transcribed from the official SDL 3.4.12 headers
// (vendored under tools/sdl3/include/SDL3 for reference).
// Mirrors Foster's own Internal/ThirdParty/SDL3.cs binding.
//
// The `SDL3 :: #library ...` declaration lives in the repo-root module.jai,
// because Windows LoadLibrary rejects paths containing ".." segments and the
// native libraries live under internal/native/.

#load "SDL_error.jai";
#load "SDL_version.jai";
#load "SDL_init.jai";
#load "SDL_hints.jai";
#load "SDL_log.jai";
#load "SDL_properties.jai";
#load "SDL_keycode.jai";
#load "SDL_scancode.jai";
#load "SDL_keyboard.jai";
#load "SDL_mouse.jai";
#load "SDL_video.jai";
#load "SDL_events.jai";
#load "SDL_gpu.jai";
#load "SDL_filesystem.jai";
#load "SDL_joystick.jai";
#load "SDL_gamepad.jai";
#load "SDL_clipboard.jai";
#load "SDL_image.jai";

// Appended (only addition to this file): SDL_Storage bindings for
// storage/content_storage.jai. Order does not matter for symbols, so it goes
// last to keep the original load list untouched.
#load "SDL_storage.jai";

// 音频（kit/audio 需要；Foster 原版把音频放在 Foster.Audio 里，没有对应绑定）
#load "SDL_audio.jai";
