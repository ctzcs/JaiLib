//
// clay_backend.jai — Clay v0.14 纯 Jai 移植（第五层：olib 后端扩展）
//
// 移植自 olib: D:\MySpace\Github\olib\thirdparty\clay\clay_backend.odin (62 行)
// 上游: nicbarker/clay v0.14 (b25a31c1a152915cd7dd6796e6592273e5a10aac)。
// Copyright (c) 2024 Nic Barker. Altered source; see LICENSE.md and README.md。
//
// 这一层的三个符号是 olib 在原生 C clay 绑定之外额外加的（不在上游 clay.h 里）：
//   * `LayoutElementInfo` / `GetLayoutElementInfo` —— 布局后取整棵元素树
//     （id / parentId / clipId / boundingBox），给渲染后端做命中测试或调试用。
//   * `PointerHitTest` / `SetPointerHitTestFunction` / `_BackendPointInside`
//     —— 把「点是否落在元素上」的可插拔判断（默认走 `_PointIsInsideRect`）。
//
// 与 olib 的差异（只有一处，见下）：
//   olib 的 `PointerHitTest :: #type proc(...)` 是 `#type` 声明；
//   JaiLib 里 `PointerHitTest` 这个**类型**已经在 clay_types.jai 定义好了
//   （它是 Context.pointerHitTest 的第一个字段，必须与 Context 同层）。
//   所以这里不再重复定义类型，只定义使用它的过程。
//
// `[^]i32` -> `*s32`、`u32(...)` -> `cast(u32) ...`、`len(output)` -> `output.count`。
//

//@region 布局元素树条目

// olib: LayoutElementInfo
// A copy of the layout identity and ancestry; valid after EndLayout.
LayoutElementInfo :: struct {
    id: u32;
    parentId: u32;
    clipId: u32;
    boundingBox: BoundingBox;
}
//@endregion

//@region 指针命中测试

// olib: SetPointerHitTestFunction
SetPointerHitTestFunction :: (callback: PointerHitTest, userData: *void) {
    ctx := GetCurrentContext();
    ctx.pointerHitTest = callback;
    ctx.pointerHitTestUserData = userData;
}

// olib: _BackendPointInside
_BackendPointInside :: (id: u32, position: Vector2, bounds: BoundingBox, clip: bool) -> bool {
    ctx := GetCurrentContext();
    if ctx.pointerHitTest != null {
        return ctx.pointerHitTest(id, position, bounds, clip, ctx.pointerHitTestUserData);
    }
    return _PointIsInsideRect(position, bounds);
}
//@endregion

//@region 布局元素树导出

// olib: GetLayoutElementInfo
// Returns required length; writes only if the caller's buffer is large enough.
// Floating roots inherit their attachment parent's visual transform.
//
// 移植注记：
//   * olib 的 `for i in 0..<count` 直接写成 while（无 continue，等价）。
//   * `output[index].parentId = ...` 里 index 来自 `(cast([^]i32)children.elements)[j]`；
//     Jai 的 children.elements 本身就是 *s32，直接下标。
//     ⚠ olib 这里不检查 index 范围（布局保证合法）；Jai 的数组下标越界会 panic，
//     这里保持同一假设，不做额外 clamp（与 olib 的越界行为不同，但合法输入一致）。
GetLayoutElementInfo :: (output: [] LayoutElementInfo) -> s64 {
    ctx := GetCurrentContext();
    if ctx.booleanWarnings.maxElementsExceeded {
        return 0;
    }
    count := ctx.layoutElements.length;
    if output.count < count {
        return cast(s64) count;
    }
    i: s32 = 0;
    while i < count {
        element := ctx.layoutElements.internalArray + i;
        output[i] = .{
            id = element.id,
            clipId = _s32_to_u32(ctx.layoutElementClipElementIds.internalArray[i]),
            boundingBox = GetElementData(.{ id = element.id }).boundingBox,
        };
        i += 1;
    }
    i = 0;
    while i < count {
        element := ctx.layoutElements.internalArray + i;
        if _ElementHasConfig(element, CLAY__ELEMENT_CONFIG_TYPE_TEXT) {
            i += 1;
            continue;
        }
        children := element.childrenOrTextContent.children;
        j: s32 = 0;
        while j < children.length {
            index := children.elements[j];
            output[index].parentId = element.id;
            j += 1;
        }
        i += 1;
    }
    i = 0;
    while i < ctx.layoutElementTreeRoots.length {
        root := ctx.layoutElementTreeRoots.internalArray[i];
        output[root.layoutElementIndex].parentId = root.parentId;
        i += 1;
    }
    return cast(s64) count;
}
//@endregion
