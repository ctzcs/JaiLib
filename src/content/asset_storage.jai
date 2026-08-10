// asset_storage.jai
// Port of Ascension/src/content/asset_storage.odin
// Unified resource-loading API: paths only live in assets.odin, business code
// references assets through enums.

#import "Basic";
#import "File";
#import "bindings/raylib";
#import "content/assets";

// Jai strings from string literals are already null-terminated, so passing
// the data pointer works as a C string.
temp_cstring :: (s: string) -> *u8 {
    return s.data;
}

load_texture :: (name: TextureName) -> Texture {
    return LoadTexture(temp_cstring(all_textures[cast(s64) name].path));
}

load_shader_pair :: (vs: ShaderName, fs: ShaderName) -> Shader {
    return LoadShader(
        temp_cstring(all_shaders[cast(s64) vs].path),
        temp_cstring(all_shaders[cast(s64) fs].path),
    );
}

font_path :: (name: FontName) -> string {
    return all_fonts[cast(s64) name].path;
}

data_path :: (name: DataName) -> string {
    return all_data[cast(s64) name].path;
}

load_file_data :: (name: DataName) -> (string, bool) {
    return read_entire_file(all_data[cast(s64) name].path);
}
