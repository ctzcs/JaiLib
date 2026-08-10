// tool_csv_tables.jai
// Port of Ascension/src/editor/tool_csv_tables.odin

#import "bindings/imgui_raylib";

#import "ImGui";

csv_tables_tool_draw :: (state: *void, open: *bool) {
    _ = state;
    if Begin("CSV Tables", open) {
        TextWrapped("配置表浏览器 — 待接入 leaf_config 等 CSV 预览。");
        Separator();
        TextDisabled("运行 gen.bat 重新生成 src/content/gen_csv.jai。");
    }
    End();
}
