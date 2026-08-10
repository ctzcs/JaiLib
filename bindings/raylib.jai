// raylib.jai
// Jai FFI bindings for raylib (subset used by Ascension).
// Requires raylib.dll next to the executable (e.g. from
// D:\Lib\odin\vendor\raylib\windows\).

raylib :: #system_library "raylib";

Vector2 :: struct { x: float32; y: float32; }
Vector3 :: struct { x: float32; y: float32; z: float32; }
Vector4 :: struct { x: float32; y: float32; z: float32; w: float32; }

Color :: struct { r: u8; g: u8; b: u8; a: u8; }
Rectangle :: struct { x: float32; y: float32; width: float32; height: float32; }

Texture :: struct {
    id:      u32;
    width:   s32;
    height:  s32;
    mipmaps: s32;
    format:  s32;
}

RenderTexture :: struct {
    id:      u32;
    texture: Texture;
    depth:   Texture;
}

Shader :: struct {
    id:   u32;
    locs: *s32;
}

Camera2D :: struct {
    offset:   Vector2;
    target:   Vector2;
    rotation: float32;
    zoom:     float32;
}

// raylib 6.0 keycodes (rkeys.h)
KeyboardKey :: enum s32 {
    NULL           :: 0;
    APOSTROPHE     :: 39;
    COMMA          :: 44;
    MINUS          :: 45;
    PERIOD         :: 46;
    SLASH          :: 47;
    ZERO           :: 48;
    ONE            :: 49;
    TWO            :: 50;
    THREE          :: 51;
    FOUR           :: 52;
    FIVE           :: 53;
    SIX            :: 54;
    SEVEN          :: 55;
    EIGHT          :: 56;
    NINE           :: 57;
    SEMICOLON      :: 59;
    EQUAL          :: 61;
    A              :: 65;
    B              :: 66;
    C              :: 67;
    D              :: 68;
    E              :: 69;
    F              :: 70;
    G              :: 71;
    H              :: 72;
    I              :: 73;
    J              :: 74;
    K              :: 75;
    L              :: 76;
    M              :: 77;
    N              :: 78;
    O              :: 79;
    P              :: 80;
    Q              :: 81;
    R              :: 82;
    S              :: 83;
    T              :: 84;
    U              :: 85;
    V              :: 86;
    W              :: 87;
    X              :: 88;
    Y              :: 89;
    Z              :: 90;
    LEFT_BRACKET   :: 91;
    BACKSLASH      :: 92;
    RIGHT_BRACKET  :: 93;
    GRAVE          :: 96;
    SPACE          :: 32;
    ESCAPE         :: 256;
    ENTER          :: 257;
    TAB            :: 258;
    BACKSPACE      :: 259;
    INSERT         :: 260;
    DELETE         :: 261;
    RIGHT          :: 262;
    LEFT           :: 263;
    DOWN           :: 264;
    UP             :: 265;
    PAGE_UP        :: 266;
    PAGE_DOWN      :: 267;
    HOME           :: 268;
    END            :: 269;
    CAPS_LOCK      :: 280;
    SCROLL_LOCK    :: 281;
    NUM_LOCK       :: 282;
    PRINT_SCREEN   :: 283;
    PAUSE          :: 284;
    F1             :: 290;
    F2             :: 291;
    F3             :: 292;
    F4             :: 293;
    F5             :: 294;
    F6             :: 295;
    F7             :: 296;
    F8             :: 297;
    F9             :: 298;
    F10            :: 299;
    F11            :: 300;
    F12            :: 301;
    LEFT_SHIFT     :: 340;
    LEFT_CONTROL   :: 341;
    LEFT_ALT       :: 342;
    LEFT_SUPER     :: 343;
    RIGHT_SHIFT    :: 344;
    RIGHT_CONTROL  :: 345;
    RIGHT_ALT      :: 346;
    RIGHT_SUPER    :: 347;
    KB_MENU        :: 348;
    KP_0           :: 320;
    KP_1           :: 321;
    KP_2           :: 322;
    KP_3           :: 323;
    KP_4           :: 324;
    KP_5           :: 325;
    KP_6           :: 326;
    KP_7           :: 327;
    KP_8           :: 328;
    KP_9           :: 329;
    KP_DECIMAL     :: 330;
    KP_DIVIDE      :: 331;
    KP_MULTIPLY    :: 332;
    KP_SUBTRACT    :: 333;
    KP_ADD         :: 334;
    KP_ENTER       :: 335;
    KP_EQUAL       :: 336;
}

// raylib 6.0 mouse buttons
RL_MouseButton :: enum s32 {
    LEFT    :: 0;
    RIGHT   :: 1;
    MIDDLE  :: 2;
    SIDE    :: 3;
    EXTRA   :: 4;
    FORWARD :: 5;
    BACK    :: 6;
}

// raylib 6.0 mouse cursors
// RL_ prefix: ImGui module also declares MouseCursor.
RL_MouseCursor :: enum s32 {
    DEFAULT       :: 0;
    ARROW         :: 1;
    IBEAM         :: 2;
    CROSSHAIR     :: 3;
    POINTING_HAND :: 4;
    RESIZE_EW     :: 5;
    RESIZE_NS     :: 6;
    RESIZE_NWSE   :: 7;
    RESIZE_NESW   :: 8;
    RESIZE_ALL    :: 9;
    NOT_ALLOWED   :: 10;
}

TextureFilter :: enum s32 {
    POINT :: 0;
    BILINEAR :: 1;
    ANISOTROPIC_4X :: 2;
    ANISOTROPIC_8X :: 3;
    ANISOTROPIC_16X :: 4;
}

TextureWrap :: enum s32 {
    REPEAT :: 0;
    CLAMP :: 1;
    MIRROR_REPEAT :: 2;
    MIRROR_CLAMP :: 3;
}

BlendMode :: enum s32 {
    ALPHA :: 0;
    ADDITIVE :: 1;
    MULTIPLIED :: 2;
    ADD_COLORS :: 3;
    SUBTRACT_COLORS :: 4;
    ALPHA_PREMULTIPLY :: 5;
    CUSTOM :: 6;
    CUSTOM_SEPARATE :: 7;
}

ShaderUniformDataType :: enum s32 {
    FLOAT :: 0;
    VEC2 :: 1;
    VEC3 :: 2;
    VEC4 :: 3;
    INT :: 4;
    IVEC2 :: 5;
    IVEC3 :: 6;
    IVEC4 :: 7;
    SAMPLER2D :: 8;
}

// --- Window flags ---
// RL_ prefix: ImGui module also declares ConfigFlags.
RL_ConfigFlags :: enum_flags s32 {
    VSYNC_HINT                :: 64;
    FULLSCREEN_MODE           :: 2;
    WINDOW_RESIZABLE          :: 4;
    WINDOW_UNDECORATED        :: 8;
    WINDOW_HIDDEN             :: 128;
    WINDOW_MINIMIZED          :: 512;
    WINDOW_MAXIMIZED          :: 1024;
    WINDOW_UNFOCUSED          :: 2048;
    WINDOW_TOPMOST            :: 4096;
    WINDOW_HIGHDPI            :: 8192;
    WINDOW_MOUSE_PASSTHROUGH  :: 16384;
    BORDERLESS_WINDOWED_MODE  :: 32768;
    MSAA_4X_HINT              :: 32;
    INTERLACED_HINT           :: 65536;
}

// --- Window ---
SetConfigFlags :: (flags: RL_ConfigFlags) #foreign raylib;
InitWindow :: (width: s32, height: s32, title: *u8) #foreign raylib;
WindowShouldClose :: () -> bool #foreign raylib;
CloseWindow :: () #foreign raylib;
IsWindowFocused :: () -> bool #foreign raylib;
IsWindowFullscreen :: () -> bool #foreign raylib;
GetScreenWidth :: () -> s32 #foreign raylib;
GetScreenHeight :: () -> s32 #foreign raylib;
GetRenderWidth :: () -> s32 #foreign raylib;
GetRenderHeight :: () -> s32 #foreign raylib;
GetCurrentMonitor :: () -> s32 #foreign raylib;
GetMonitorWidth :: (monitor: s32) -> s32 #foreign raylib;
GetMonitorHeight :: (monitor: s32) -> s32 #foreign raylib;
GetFrameTime :: () -> float32 #foreign raylib;
// rl prefix: ImGui module also declares SetClipboardText/GetClipboardText.
rlSetClipboardText :: (text: *u8) #foreign raylib "SetClipboardText";
rlGetClipboardText :: () -> *u8 #foreign raylib "GetClipboardText";

// --- Drawing ---
BeginDrawing :: () #foreign raylib;
EndDrawing :: () #foreign raylib;
ClearBackground :: (color: Color) #foreign raylib;
DrawFPS :: (pos_x: s32, pos_y: s32) #foreign raylib;

// --- Camera ---
BeginMode2D :: (camera: Camera2D) #foreign raylib;
EndMode2D :: () #foreign raylib;
GetScreenToWorld2D :: (position: Vector2, camera: Camera2D) -> Vector2 #foreign raylib;

// --- Textures / render targets ---
LoadTexture :: (file_name: *u8) -> Texture #foreign raylib;
UnloadTexture :: (texture: Texture) #foreign raylib;
SetTextureFilter :: (texture: Texture, filter: TextureFilter) #foreign raylib;
SetTextureWrap :: (texture: Texture, wrap: TextureWrap) #foreign raylib;
SetShapesTexture :: (texture: Texture, source: Rectangle) #foreign raylib;

LoadRenderTexture :: (width: s32, height: s32) -> RenderTexture #foreign raylib;
UnloadRenderTexture :: (target: RenderTexture) #foreign raylib;
BeginTextureMode :: (target: RenderTexture) #foreign raylib;
EndTextureMode :: () #foreign raylib;

// --- Shaders ---
LoadShader :: (vs_file_name: *u8, fs_file_name: *u8) -> Shader #foreign raylib;
LoadShaderFromMemory :: (vs_code: *u8, fs_code: *u8) -> Shader #foreign raylib;
UnloadShader :: (shader: Shader) #foreign raylib;
GetShaderLocation :: (shader: Shader, uniform_name: *u8) -> s32 #foreign raylib;
SetShaderValue :: (shader: Shader, loc_index: s32, value: *void, uniform_type: ShaderUniformDataType) #foreign raylib;
SetShaderValueTexture :: (shader: Shader, loc_index: s32, texture: Texture) #foreign raylib;
BeginShaderMode :: (shader: Shader) #foreign raylib;
EndShaderMode :: () #foreign raylib;
BeginBlendMode :: (mode: BlendMode) #foreign raylib;
EndBlendMode :: () #foreign raylib;

// --- 2D primitives ---
DrawRectangle :: (pos_x: s32, pos_y: s32, width: s32, height: s32, color: Color) #foreign raylib;
DrawRectangleRec :: (rec: Rectangle, color: Color) #foreign raylib;
DrawRectanglePro :: (rec: Rectangle, origin: Vector2, rotation: float32, color: Color) #foreign raylib;
DrawRectangleRounded :: (rec: Rectangle, roundness: float32, segments: s32, color: Color) #foreign raylib;
DrawCircleV :: (center: Vector2, radius: float32, color: Color) #foreign raylib;
DrawLineEx :: (start_pos: Vector2, end_pos: Vector2, thick: float32, color: Color) #foreign raylib;
DrawText :: (text: *u8, pos_x: s32, pos_y: s32, font_size: s32, color: Color) #foreign raylib;
DrawTexturePro :: (texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: float32, tint: Color) #foreign raylib;
DrawTextureRec :: (texture: Texture, source: Rectangle, position: Vector2, tint: Color) #foreign raylib;

// --- Input ---
IsKeyDown :: (key: KeyboardKey) -> bool #foreign raylib;
IsKeyPressed :: (key: KeyboardKey) -> bool #foreign raylib;
IsKeyReleased :: (key: KeyboardKey) -> bool #foreign raylib;
GetKeyPressed :: () -> KeyboardKey #foreign raylib;
GetCharPressed :: () -> s32 #foreign raylib;
IsMouseButtonDown :: (button: RL_MouseButton) -> bool #foreign raylib;
IsMouseButtonPressed :: (button: RL_MouseButton) -> bool #foreign raylib;
IsMouseButtonReleased :: (button: RL_MouseButton) -> bool #foreign raylib;
GetMousePosition :: () -> Vector2 #foreign raylib;
GetMouseDelta :: () -> Vector2 #foreign raylib;
GetMouseWheelMoveV :: () -> Vector2 #foreign raylib;
SetMousePosition :: (x: s32, y: s32) #foreign raylib;
SetMouseCursor :: (cursor: RL_MouseCursor) #foreign raylib;
HideCursor :: () #foreign raylib;
ShowCursor :: () #foreign raylib;

// --- Misc ---
GetRandomValue :: (min: s32, max: s32) -> s32 #foreign raylib;

// --- Color constants ---
BLANK    :: Color.{ r = 0,   g = 0,   b = 0,   a = 0 };
BLACK    :: Color.{ r = 0,   g = 0,   b = 0,   a = 255 };
WHITE    :: Color.{ r = 255, g = 255, b = 255, a = 255 };
RAYWHITE :: Color.{ r = 245, g = 245, b = 245, a = 255 };
LIGHTGRAY :: Color.{ r = 200, g = 200, b = 200, a = 255 };
DARKGRAY :: Color.{ r = 80,  g = 80,  b = 80,  a = 255 };
DARKGREEN :: Color.{ r = 0,   g = 117, b = 44,  a = 255 };
SKYBLUE  :: Color.{ r = 102, g = 191, b = 255, a = 255 };
GOLD     :: Color.{ r = 255, g = 203, b = 0,   a = 255 };

// Takes a screenshot of current screen (saved in a 24-bit PNG format)
TakeScreenshot :: (file_name: *u8) #foreign raylib;
