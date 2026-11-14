#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Input/Cursor.cs
//
// An OS mouse cursor. In C# this is a sealed IDisposable class with a
// finalizer; here it is a value struct whose `handle` is the SDL cursor, with
// an explicit cursor_destroy (Jai has no finalizers) - same choice the port
// made for Image (image_create / image_destroy).
//
// SDL_mouse.h cursor entry points. They are declared here (rather than in
// internal/sdl3/SDL_mouse.jai) because this file is not allowed to touch the
// existing bindings; move them there if that file ever grows a cursor
// section. SDL_SystemCursor is passed as u32 to avoid claiming that type name,
// which belongs to the SDL bindings: it is a 4-byte C enum, so the ABI is
// identical.
SDL_Cursor :: void;

SDL_CreateColorCursor :: (surface: *SDL_Surface, hot_x: s32, hot_y: s32) -> *SDL_Cursor #foreign SDL3;
SDL_CreateSystemCursor :: (id: u32) -> *SDL_Cursor #foreign SDL3;
SDL_DestroyCursor :: (cursor: *SDL_Cursor) -> bool #foreign SDL3;
SDL_SetCursor :: (cursor: *SDL_Cursor) -> bool #foreign SDL3;

// Built-in system cursors, a one-to-one mapping of SDL_SystemCursor:
// https://wiki.libsdl.org/SDL3/SDL_SystemCursor
Cursor_System_Types :: enum u32 {
    DEFAULT :: 0;
    TEXT;
    WAIT;
    CROSSHAIR;
    PROGRESS;
    RESIZE_NWSE;
    RESIZE_NESW;
    RESIZE_HORIZONTAL;
    RESIZE_VERTICAL;
    MOVE;
    NOT_ALLOWED;
    POINTER;
    RESIZE_NW;
    RESIZE_N;
    RESIZE_NE;
    RESIZE_E;
    RESIZE_SE;
    RESIZE_S;
    RESIZE_SW;
    RESIZE_W;
}

// Structure representing an OS Mouse Cursor.
// Bind it with window_set_mouse_cursor().
Cursor :: struct {
    // Reference to SDL's Cursor (null once destroyed).
    handle: *SDL_Cursor;

    // The Focus Point of the Cursor (where it is considered active).
    FocusPoint: Point2;

    // The Size of the Cursor Image.
    Size: Point2;

    // The System Type used to create this cursor; only meaningful when
    // HasSystemType is true (C#: SystemTypes? SystemType, null if the cursor
    // was created from an Image).
    SystemType: Cursor_System_Types;
    HasSystemType: bool;
}

// Creates a new Cursor from an Image.
// `focus_point` is the Focus Point of the Cursor, i.e. where the active point is.
// Foster: Cursor(Image image, Point2 focusPoint)
cursor_create :: (image: Image, focus_point: Point2) -> Cursor {
    c: Cursor;
    c.handle = null;
    c.FocusPoint = focus_point;
    c.Size = .{ image.Width, image.Height };
    c.SystemType = .DEFAULT;
    c.HasSystemType = false;

    // create an SDL surface from the image (RGBA, one Color per pixel)
    surface := SDL_CreateSurfaceFrom(
        image.Width,
        image.Height,
        .RGBA32,
        image.Data.data,
        image.Width * size_of(Color),
    );
    if surface == null {
        log_error(app_sdl_error_message("SDL_CreateSurfaceFrom"));
        assert(false, "SDL_CreateSurfaceFrom failed");
    }

    // create the cursor, then free the surface
    c.handle = SDL_CreateColorCursor(surface, focus_point.x, focus_point.y);
    SDL_DestroySurface(surface);

    if c.handle == null {
        log_error(app_sdl_error_message("SDL_CreateColorCursor"));
        assert(false, "SDL_CreateColorCursor failed");
    }
    return c;
}

// Creates a new Cursor from a built-in System type.
// Note that FocusPoint and Size are not valid for system cursors.
// Foster: Cursor(SystemTypes type)
cursor_create_system :: (type: Cursor_System_Types) -> Cursor {
    c: Cursor;
    c.FocusPoint = Point2_Zero;
    c.Size = Point2_Zero;
    c.SystemType = type;
    c.HasSystemType = true;
    c.handle = SDL_CreateSystemCursor(cast(u32) type);

    if c.handle == null {
        log_error(app_sdl_error_message("SDL_CreateSystemCursor"));
        assert(false, "SDL_CreateSystemCursor failed");
    }
    return c;
}

// Destroys the Cursor's resources.
// If the Cursor is currently bound through window_set_mouse_cursor(), the mouse
// changes back to the default OS cursor.
// Foster: Cursor.Dispose()
cursor_destroy :: (c: *Cursor) {
    if c.handle != null {
        SDL_DestroyCursor(c.handle);
        c.handle = null;
    }
}

// If the Cursor has been destroyed, in which case it can no longer be used.
// Foster: Cursor.Disposed
cursor_disposed :: (c: Cursor) -> bool {
    return c.handle == null;
}

// The underlying SDL_Cursor (null when destroyed).
cursor_handle :: (c: Cursor) -> *SDL_Cursor {
    return c.handle;
}

// Binds a Cursor to the Window (null, or a destroyed cursor, restores the
// default OS cursor). Until window.jai grows SetMouseCursor this lives here,
// next to the type it needs.
// Foster: Window.SetMouseCursor(Cursor? cursor)
window_set_mouse_cursor :: (w: *Window, cursor: *Cursor) {
    target: *SDL_Cursor = null;
    if cursor != null target = cursor.handle;
    if !SDL_SetCursor(target) {
        log_warning(tprint("Failed to set Mouse Cursor: %s", SDL_GetError()));
    }
}
