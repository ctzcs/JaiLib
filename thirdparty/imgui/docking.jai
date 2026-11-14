// Docking 1.89.6. Internal builder calls use a small C ABI bridge in the paired DLL.
#scope_file
#import "Basic";
#import "thirdparty/imgui";

dll :: #library "imgui";

#scope_export
DockNodeFlags :: enum_flags s32 {
    None :: 0;
    KeepAliveOnly :: 1;
    NoDockingInCentralNode :: 4;
    PassthruCentralNode :: 8;
    NoSplit :: 16;
    NoResize :: 32;
    AutoHideTabBar :: 64;
    DockSpace :: 1024; // imgui_internal.h, pinned together with the implementation.
}

DockSpaceOverViewport :: () -> ID #foreign dll "jlDockSpaceOverViewport";
DockBuilderAddNode :: (id: ID, flags: DockNodeFlags = .None) -> ID #foreign dll "jlDockBuilderAddNode";
DockBuilderRemoveNode :: (id: ID) #foreign dll "jlDockBuilderRemoveNode";
DockBuilderSetNodeSize :: (id: ID, x, y: float32) #foreign dll "jlDockBuilderSetNodeSize";
DockBuilderSplitNode :: (id: ID, dir: Dir, ratio: float32, at: *ID, opposite: *ID) -> ID #foreign dll "jlDockBuilderSplitNode";
DockBuilderDockWindow :: (name: *u8, id: ID) #foreign dll "jlDockBuilderDockWindow";
DockBuilderFinish :: (id: ID) #foreign dll "jlDockBuilderFinish";
WindowDockID :: (name: *u8) -> ID #foreign dll "jlWindowDockID";
UndockWindow :: (name: *u8) #foreign dll "jlUndockWindow";

docking_layout_check :: () -> bool {
    io: IO;
    style: Style;
    return native_layout_check(size_of(IO), size_of(Style), size_of(Viewport), size_of(ImDrawData),
        cast(u64) *io.MousePos - cast(u64) *io, cast(u64) *io.KeysData - cast(u64) *io,
        cast(u64) *io.WantCaptureMouse - cast(u64) *io, cast(u64) *style.Colors - cast(u64) *style);
}

#scope_file
native_layout_check :: (io, style, viewport, drawdata, mouse, keys, capture, colors: u64) -> bool #foreign dll "jlDockingLayoutCheck";
