// M0 smoke test: init SDL3, open a window, pump events, exit on close/ESC.
// Build from the repo root:  jai first.jai   (then run tests/window/window.exe)

#import "Basic";
#import "foster";

main :: () {
    if !SDL_Init(.SDL_INIT_VIDEO | .SDL_INIT_EVENTS) {
        print("SDL_Init failed: %s\n", SDL_GetError());
        return;
    }

    print("SDL version: %  (jfoster M0 smoke test)\n", SDL_GetVersion());

    window := SDL_CreateWindow("jfoster", 1280, 720, .SDL_WINDOW_RESIZABLE | .SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if window == null {
        print("SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return;
    }
    SDL_ShowWindow(window);

    running := true;
    while running {
        event: SDL_Event;
        while SDL_PollEvent(*event) {
            if event.type == {
                case .SDL_EVENT_QUIT;
                    running = false;
                case .SDL_EVENT_KEY_DOWN;
                    if event.key.scancode == .SDL_SCANCODE_ESCAPE running = false;
                case .SDL_EVENT_WINDOW_CLOSE_REQUESTED;
                    running = false;
            }
        }
    }

    SDL_DestroyWindow(window);
    SDL_Quit();
}
