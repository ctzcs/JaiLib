// Matches olib imgui_impl_ofoster/olib_ui.odin; old ImGui color names are mapped below.
imgui_foster_style_kit :: (scale: float32 = 1) {
    StyleColorsDark();
    style := GetStyle();
    style.WindowRounding = 4;
    style.ChildRounding = 4;
    style.FrameRounding = 3;
    style.PopupRounding = 4;
    style.GrabRounding = 3;
    style.TabRounding = 3;
    style.ScrollbarRounding = 6;
    style.WindowPadding = .{ 10, 10 };
    style.FramePadding = .{ 7, 4 };
    style.ItemSpacing = .{ 8, 6 };
    style.ItemInnerSpacing = .{ 6, 4 };
    style.WindowBorderSize = 1;
    style.FrameBorderSize = 0;
    accent := imgui_foster_rgba(117, 184, 255);
    style.Colors[Col.Text] = imgui_foster_rgba(210, 219, 228);
    style.Colors[Col.TextDisabled] = imgui_foster_rgba(140, 154, 168);
    style.Colors[Col.WindowBg] = imgui_foster_rgba(22, 26, 33);
    style.Colors[Col.ChildBg] = imgui_foster_rgba(0, 0, 0, 0);
    style.Colors[Col.PopupBg] = imgui_foster_rgba(22, 26, 33, 250);
    style.Colors[Col.Border] = imgui_foster_rgba(43, 51, 60);
    style.Colors[Col.FrameBg] = imgui_foster_rgba(31, 38, 47);
    style.Colors[Col.FrameBgHovered] = imgui_foster_rgba(41, 51, 63);
    style.Colors[Col.FrameBgActive] = imgui_foster_rgba(36, 54, 77);
    style.Colors[Col.TitleBg] = imgui_foster_rgba(13, 16, 20);
    style.Colors[Col.TitleBgActive] = imgui_foster_rgba(22, 26, 33);
    style.Colors[Col.TitleBgCollapsed] = imgui_foster_rgba(13, 16, 20);
    style.Colors[Col.MenuBarBg] = imgui_foster_rgba(18, 22, 28);
    style.Colors[Col.ScrollbarBg] = imgui_foster_rgba(13, 16, 20, 160);
    style.Colors[Col.ScrollbarGrab] = imgui_foster_rgba(43, 51, 60);
    style.Colors[Col.ScrollbarGrabHovered] = imgui_foster_rgba(60, 72, 84);
    style.Colors[Col.ScrollbarGrabActive] = imgui_foster_rgba(78, 94, 110);
    style.Colors[Col.CheckMark] = accent;
    style.Colors[Col.SliderGrab] = imgui_foster_rgba(92, 150, 214);
    style.Colors[Col.SliderGrabActive] = accent;
    style.Colors[Col.Button] = imgui_foster_rgba(33, 41, 51);
    style.Colors[Col.ButtonHovered] = imgui_foster_rgba(44, 56, 69);
    style.Colors[Col.ButtonActive] = imgui_foster_rgba(36, 54, 77);
    style.Colors[Col.Header] = imgui_foster_rgba(36, 54, 77);
    style.Colors[Col.HeaderHovered] = imgui_foster_rgba(44, 66, 94);
    style.Colors[Col.HeaderActive] = imgui_foster_rgba(52, 78, 110);
    style.Colors[Col.Separator] = imgui_foster_rgba(43, 51, 60);
    style.Colors[Col.SeparatorHovered] = imgui_foster_rgba(92, 150, 214);
    style.Colors[Col.SeparatorActive] = accent;
    style.Colors[Col.ResizeGrip] = imgui_foster_rgba(43, 51, 60, 120);
    style.Colors[Col.ResizeGripHovered] = imgui_foster_rgba(92, 150, 214);
    style.Colors[Col.ResizeGripActive] = accent;
    style.Colors[Col.Tab] = imgui_foster_rgba(28, 34, 43);
    style.Colors[Col.TabHovered] = imgui_foster_rgba(44, 66, 94);
    style.Colors[Col.TabActive] = imgui_foster_rgba(36, 54, 77);
    style.Colors[Col.TabUnfocused] = imgui_foster_rgba(18, 22, 28);
    style.Colors[Col.TabUnfocusedActive] = imgui_foster_rgba(30, 40, 54);
    style.Colors[Col.TextSelectedBg] = imgui_foster_rgba(117, 184, 255, 90);
    style.Colors[Col.NavHighlight] = accent;
    style.Colors[Col.DockingPreview] = imgui_foster_rgba(90, 155, 220, 180);
    style.Colors[Col.DockingEmptyBg] = imgui_foster_rgba(16, 19, 24, 255);
    Style.ScaleAllSizes(style, scale);
}

imgui_foster_rgba :: (r: u8, g: u8, b: u8, a: u8 = 255) -> ImVec4 {
    return .{ (cast(float32) r) / 255, (cast(float32) g) / 255, (cast(float32) b) / 255, (cast(float32) a) / 255 };
}
