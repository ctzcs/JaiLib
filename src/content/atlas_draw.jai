// atlas_draw.jai
// Port of Ascension/src/content/atlas_draw.odin
// Anchored sprite drawing from the texture atlas.

#import "Basic";
#import "tween/math_util";
#import "bindings/raylib";
#import "content/assets";
#import "content/asset_storage";
#import "content/atlas";

// Common anchors (document space, 0~1).
ANCHOR_TOP_LEFT      :: Vector2.{ x = 0, y = 0 };
ANCHOR_CENTER        :: Vector2.{ x = 0.5, y = 0.5 };
ANCHOR_BOTTOM_CENTER :: Vector2.{ x = 0.5, y = 1 };

load_atlas :: () -> Texture {
    tex := load_texture(.Atlas);
    SetTextureFilter(tex, .POINT);
    SetTextureWrap(tex, .CLAMP);
    return tex;
}

atlas_sprite :: (name: Texture_Name) -> Atlas_Texture {
    return atlas_textures[cast(s64) name];
}

atlas_sprite_rect :: (name: Texture_Name) -> Rectangle {
    return atlas_textures[cast(s64) name].rect;
}

atlas_sprite_document_size :: (name: Texture_Name) -> Vector2 {
    t := atlas_textures[cast(s64) name];
    return .{ x = t.document_size[0], y = t.document_size[1] };
}

// anchor is a normalized coordinate on the document (0~1); (0.5, 1) is the
// bottom-center of the sprite.
atlas_sprite_origin :: (t: Atlas_Texture, anchor: Vector2, sx: float32, sy: float32) -> Vector2 {
    return .{
        x = t.document_size[0] * sx * anchor.x,
        y = t.document_size[1] * sy * anchor.y,
    };
}

// pos is the anchor's position in world coordinates; negative scale flips.
draw_atlas_sprite_ex :: (atlas: Texture, name: Texture_Name, pos: Vector2, scale: Vector2 = .{ x = 1, y = 1 }, rotation: float32 = 0, anchor: Vector2 = .{ x = 0, y = 0 }, tint: Color = WHITE) {
    if name == .None {
        return;
    }
    t := atlas_textures[cast(s64) name];

    src := t.rect;
    offset := Vector2.{ x = t.offset_left, y = t.offset_top };

    if scale.x < 0 {
        src.width = -src.width;
        offset.x = t.offset_right;
    }
    if scale.y < 0 {
        src.height = -src.height;
        offset.y = t.offset_bottom;
    }

    sx := math_abs(scale.x);
    sy := math_abs(scale.y);

    dest_w := t.rect.width * sx;
    dest_h := t.rect.height * sy;
    origin := atlas_sprite_origin(t, anchor, sx, sy);

    dest := Rectangle.{
        x = pos.x - origin.x + offset.x * sx,
        y = pos.y - origin.y + offset.y * sy,
        width = dest_w,
        height = dest_h,
    };

    DrawTexturePro(atlas, src, dest, origin, rotation, tint);
}

draw_atlas_sprite :: (atlas: Texture, name: Texture_Name, pos: Vector2, tint: Color = WHITE) {
    draw_atlas_sprite_ex(atlas, name, pos, tint = tint);
}
