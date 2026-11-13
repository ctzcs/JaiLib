#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Structs/Subtexture.cs.

Subtexture :: struct {
    Tex:    *Texture = null;
    Source: Rect;    // pixel rect in the atlas
    Frame:  Rect;    // full pre-trim bounds (can extend negatively around Source)
    TexCoords:  [4] Vector2;
    DrawCoords: [4] Vector2;
}

Subtexture_Empty :: Subtexture.{};

subtexture_make :: (texture: *Texture, source: Rect, frame: Rect) -> Subtexture {
    s: Subtexture;
    s.Tex = texture;
    s.Source = source;
    s.Frame = frame;

    s.DrawCoords[0] = .{ -frame.x,             -frame.y };
    s.DrawCoords[1] = .{ -frame.x + source.w, -frame.y };
    s.DrawCoords[2] = .{ -frame.x + source.w, -frame.y + source.h };
    s.DrawCoords[3] = .{ -frame.x,            -frame.y + source.h };

    if texture != null && texture.Width > 0 && texture.Height > 0 {
        px := 1.0 / cast(float) texture.Width;
        py := 1.0 / cast(float) texture.Height;
        tx0 := source.x * px;
        ty0 := source.y * py;
        tx1 := rect_right(source) * px;
        ty1 := rect_bottom(source) * py;
        s.TexCoords[0] = .{ tx0, ty0 };
        s.TexCoords[1] = .{ tx1, ty0 };
        s.TexCoords[2] = .{ tx1, ty1 };
        s.TexCoords[3] = .{ tx0, ty1 };
    }
    return s;
}

subtexture_make_full :: (texture: *Texture) -> Subtexture {
    if texture == null return Subtexture_Empty;
    r := Rect.{ 0, 0, cast(float) texture.Width, cast(float) texture.Height };
    return subtexture_make(texture, r, r);
}

subtexture_make_source :: (texture: *Texture, source: Rect) -> Subtexture {
    return subtexture_make(texture, source, .{ 0, 0, source.w, source.h });
}

subtexture_width  :: (s: Subtexture) -> float { return s.Frame.w; }
subtexture_height :: (s: Subtexture) -> float { return s.Frame.h; }
subtexture_size   :: (s: Subtexture) -> Vector2 { return .{ s.Frame.w, s.Frame.h }; }
subtexture_is_empty :: (s: Subtexture) -> bool {
    return s.Tex == null || (s.Source.w == 0 && s.Source.h == 0);
}

operator == :: (a: Subtexture, b: Subtexture) -> bool {
    return a.Tex == b.Tex && a.Source == b.Source && a.Frame == b.Frame;
}

operator != :: (a: Subtexture, b: Subtexture) -> bool {
    return !(a == b);
}
