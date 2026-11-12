// HarfBuzz 11.2.1 C ABI. See HarfBuzz.LICENSE and Tools/build_harfbuzz.ps1.
#if OS == .WINDOWS {
    hb :: #library "windows/harfbuzz";
} else {
    hb :: #library,system "harfbuzz";
}
HB_Info :: struct { codepoint, mask, cluster, var1, var2: u32; }
HB_Position :: struct { x_advance, y_advance, x_offset, y_offset: s32; var: u32; }
hb_blob_create :: (data: *u8, length: u32, mode: s32, user: *void, destroy: *void) -> *void #foreign hb;
hb_blob_destroy :: (blob: *void) #foreign hb;
hb_face_create :: (blob: *void, index: u32) -> *void #foreign hb;
hb_face_destroy :: (face: *void) #foreign hb;
hb_face_get_upem :: (face: *void) -> u32 #foreign hb;
hb_font_create :: (face: *void) -> *void #foreign hb;
hb_font_destroy :: (font: *void) #foreign hb;
hb_font_set_scale :: (font: *void, x: s32, y: s32) #foreign hb;
hb_ot_font_set_funcs :: (font: *void) #foreign hb;
hb_buffer_create :: () -> *void #foreign hb;
hb_buffer_destroy :: (buffer: *void) #foreign hb;
hb_buffer_add_utf8 :: (buffer: *void, text: *u8, length: s32, offset: u32, item_length: s32) #foreign hb;
hb_buffer_guess_segment_properties :: (buffer: *void) #foreign hb;
hb_buffer_set_direction :: (buffer: *void, direction: s32) #foreign hb;
hb_buffer_set_script :: (buffer: *void, script: u32) #foreign hb;
hb_language_from_string :: (text: *u8, length: s32) -> *void #foreign hb;
hb_buffer_set_language :: (buffer: *void, language: *void) #foreign hb;
hb_shape :: (font: *void, buffer: *void, features: *void, count: u32) #foreign hb;
hb_buffer_get_glyph_infos :: (buffer: *void, count: *u32) -> *HB_Info #foreign hb;
hb_buffer_get_glyph_positions :: (buffer: *void, count: *u32) -> *HB_Position #foreign hb;
