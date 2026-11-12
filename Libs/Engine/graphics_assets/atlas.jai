ENC :: #import "encoding";
Atlas_Sprite :: struct { image: GA.Subtexture; pivot: GA.Vector2; }
Sprite_Atlas :: struct {
    sprites: Table(string, Atlas_Sprite);
    manager: *Texture_Manager;
    managed: Texture_Handle;
    pages: [..] *GA.Texture;
}
atlas_destroy :: (atlas: *Sprite_Atlas) {
    for atlas.sprites free(it_index);
    deinit(*atlas.sprites);
    if atlas.manager != null texture_release(atlas.manager, atlas.managed);
    for texture: atlas.pages { GA.texture_dispose(texture); free(texture); }
    array_free(atlas.pages); <<atlas = .{};
}
atlas_add :: (atlas: *Sprite_Atlas, texture: *GA.Texture, name: string, source: GA.Rect, pivot: GA.Vector2 = .{}) -> bool {
    if name.count == 0 || texture == null || source.w <= 0 || source.h <= 0 || source.x < 0 || source.y < 0 || source.x + source.w > cast(float32) texture.Width || source.y + source.h > cast(float32) texture.Height return false;
    _, exists := table_find(*atlas.sprites, name); if exists return false;
    table_set(*atlas.sprites, copy_string(name), .{image = GA.subtexture_make_source(texture, source), pivot = pivot});
    return true;
}
atlas_get :: (atlas: *Sprite_Atlas, name: string) -> (Atlas_Sprite, bool) {
    sprite, found := table_find(*atlas.sprites, name); return sprite, found;
}
atlas_draw :: (atlas: *Sprite_Atlas, batcher: *GA.Batcher, name: string, position: GA.Vector2, color: GA.Color, scale: GA.Vector2 = .{1, 1}, rotation: float32 = 0) -> bool {
    sprite, found := atlas_get(atlas, name); if !found return false;
    GA.batcher_subtexture_trs(batcher, sprite.image, position, sprite.pivot, scale, rotation, color); return true;
}
atlas_field :: (object: *ENC.Json_Value, name: string) -> *ENC.Json_Value {
    if object == null || object.kind != .Object return null;
    field, found := table_find(*object.object_val, name); if !found return null; return field;
}
atlas_number :: (object: *ENC.Json_Value, name: string, default_value: float32 = 0) -> float32 {
    field := atlas_field(object, name); if field == null || field.kind != .Number return default_value;
    return cast(float32) field.number_val;
}
// JSON: {"image":"sheet.png","sprites":[{"name":"hero","x":0,"y":0,"w":16,"h":16}]}
// Image paths resolve through the imported asset manifest, not process CWD.
atlas_load_json :: (atlas: *Sprite_Atlas, manager: *Texture_Manager, json: string) -> bool {
    p := ENC.Json_Parser.{text = json};
    root, parsed := ENC.json_parser_parse_value(*p); if !parsed return false;
    defer ENC.json_destroy_value(root);
    ENC.json_parser_skip_whitespace(*p);
    if p.pos != json.count return false;
    image := atlas_field(*root, "image"); sprites := atlas_field(*root, "sprites");
    if image == null || image.kind != .String || sprites == null || sprites.kind != .Array return false;
    handle, error := texture_acquire_path(manager, image.string_val); if error != .None return false;
    result := Sprite_Atlas.{manager = manager, managed = handle};
    for entry: sprites.array_val {
        name := atlas_field(entry, "name");
        if name == null || name.kind != .String { atlas_destroy(*result); return false; }
        if !atlas_add(*result, texture_get(manager, handle), name.string_val,
            .{atlas_number(entry, "x"), atlas_number(entry, "y"), atlas_number(entry, "w"), atlas_number(entry, "h")},
            .{atlas_number(entry, "pivot_x"), atlas_number(entry, "pivot_y")}) { atlas_destroy(*result); return false; }
    }
    atlas_destroy(atlas); <<atlas = result; return true;
}
// CPU images are borrowed only for this call; atlas owns uploaded pages.
atlas_pack :: (atlas: *Sprite_Atlas, device: *GA.Graphics_Device, names: [] string, images: [] GA.Image, max_size: s32 = 2048) -> bool {
    if names.count != images.count || names.count == 0 || max_size < 4 return false;
    p := GA.packer_create(.{Trim = false, Padding = 2, DuplicateEdges = true, MaxSize = max_size});
    defer GA.packer_destroy(*p);
    for image, i: images {
        if image.Width <= 0 || image.Height <= 0 || image.Width + 2 > max_size || image.Height + 2 > max_size return false;
        if image.Data.count < cast(s64) image.Width * image.Height return false;
        GA.packer_add(*p, names[i], image.Data, image.Width, image.Height);
    }
    GA.packer_pack(*p);
    result: Sprite_Atlas;
    for page: p.Pages array_add(*result.pages, GA.texture_create_from_colors(device, page.Width, page.Height, page.Data));
    for entry, i: p.Output {
        source := entry.Source;
        if !atlas_add(*result, result.pages[entry.Page], names[entry.Index], .{cast(float32) source.x, cast(float32) source.y, cast(float32) source.w, cast(float32) source.h}) {
            atlas_destroy(*result); return false;
        }
    }
    atlas_destroy(atlas); <<atlas = result; return true;
}
