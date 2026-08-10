// tool_burst_tuning.jai
// Port of Ascension/src/editor/tool_burst_tuning.odin

#import "bindings/imgui_raylib";

#import "ImGui";

burst_tuning_tool_draw :: (state: *void, open: *bool) {
    _ = state;
    if Begin("Burst Tuning", open) {
        TextWrapped("叶群爆发参数编辑器 — 待接入 content 包调参区。");
        Separator();
        TextDisabled("可在 src/content/game.jai 的 BURST_TUNING 中临时改值。");
    }
    End();
}
