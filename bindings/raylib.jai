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

KeyboardKey :: enum s32 {
    SPACE :: 32;
    F1 :: 290;
    F2 :: 291;
}

RL_MouseButton :: enum s32 {
    LEFT :: 0;
    RIGHT :: 1;
    MIDDLE :: 2;
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
    ALPHA_PREMULTIPLY :: 2;
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

// --- Window ---
InitWindow :: (width: s32, height: s32, title: *u8) #foreign raylib;
WindowShouldClose :: () -> bool #foreign raylib;
CloseWindow :: () #foreign raylib;
GetFrameTime :: () -> float32 #foreign raylib;

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
IsKeyPressed :: (key: KeyboardKey) -> bool #foreign raylib;
IsKeyReleased :: (key: KeyboardKey) -> bool #foreign raylib;
IsMouseButtonDown :: (button: RL_MouseButton) -> bool #foreign raylib;
IsMouseButtonPressed :: (button: RL_MouseButton) -> bool #foreign raylib;
IsMouseButtonReleased :: (button: RL_MouseButton) -> bool #foreign raylib;
GetMousePosition :: () -> Vector2 #foreign raylib;
GetMouseDelta :: () -> Vector2 #foreign raylib;
GetMouseWheelMoveV :: () -> Vector2 #foreign raylib;

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
