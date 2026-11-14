// ui:visual —— 子树视觉变换 / Tween 插值 / 变换感知命中测试 / 按 ID 的状态驱动动效。
//
// 视觉树直接来自 clay.GetLayoutElementInfo（EndLayout 之后整棵元素树，带 parentId / clipId /
// 包围盒），命中测试通过 clay.SetPointerHitTestFunction 装成 clay 自己的命中回调
// （本文件末尾的「命中测试」区，与 olib ui_visual.odin 一一对应）。于是：
//   * clay.PointerOver / pointerOverIds / 滚动优先级 / onHover 全部按显示变换判定；
//   * 变换本身、父子合成、透明度继承、反算指针到逻辑坐标（ui_pointer_local）与发射时的
//     裁剪/颜色处理都在这一层，绘制与输入共用同一套矩阵。

//@region 视觉属性 —— 不改变布局占位；零值不可见，请从 UI_VISUAL_DEFAULT 开始。

UI_Visual :: struct {
    offset: F.Vector2;
    scale: F.Vector2;
    rotation: float32; // 弧度；屏幕坐标中正值顺时针。
    pivot: F.Vector2; // 相对布局矩形的归一化支点，允许在 0..1 之外。
    opacity: float32;
}

UI_VISUAL_DEFAULT :: UI_Visual.{ scale = .{ 1, 1 }, pivot = .{ 0.5, 0.5 }, opacity = 1 };

// 每帧 begin/end 之间按稳定 ID 注册；同 ID 最后一次注册生效。
// 子树继承矩阵和透明度，浮动元素按 clay 的 attachment parent 继承。
// 不持有 visual 指针；Tween 绑定的状态由调用方保持地址稳定并负责释放。
ui_set_visual :: (ctx: *UI_Context, id: string, visual: UI_Visual) {
    table_set(*ctx.visuals, clay.ID(id).id, visual);
}

// 可直接传给 core/tween 的 spring；不限制过冲，透明度在绘制时钳制。
ui_visual_lerp :: (a: UI_Visual, b: UI_Visual, t: float32) -> UI_Visual {
    return .{
        offset = a.offset + (b.offset - a.offset) * t,
        scale = a.scale + (b.scale - a.scale) * t,
        rotation = a.rotation + (b.rotation - a.rotation) * t,
        pivot = a.pivot + (b.pivot - a.pivot) * t,
        opacity = a.opacity + (b.opacity - a.opacity) * t,
    };
}

UI_Visual_Element :: struct {
    info: clay.LayoutElementInfo; // id / parentId / clipId / boundingBox
    transform: F.Matrix3x2;
    opacity: float32;
    inert: bool; // 位于退场中的 presence 子树：不命中、不参与导航
    resolved, resolving: bool;
}

UI_VISUAL_IDENTITY :: F.Matrix3x2.{ 1, 0, 0, 1, 0, 0 };
//@endregion

//@region 布局快照 —— 保存数值，不保留 clay 帧内指针

// 把 [..]T 当 []T 只读视图（Jai 没有动态数组到切片的隐式转换，也没有切片语法）。
ui_layout_info_view :: (elements: [..] clay.LayoutElementInfo) -> [] clay.LayoutElementInfo {
    result: [] clay.LayoutElementInfo;
    result.data = elements.data;
    result.count = elements.count;
    return result;
}

ui_visual_snapshot :: (ctx: *UI_Context) {
    table_reset(*ctx.visual_elements);
    if ctx.visuals.count == 0 && ctx.inert.count == 0 return;
    // 先问长度再取内容：GetLayoutElementInfo 在缓冲区不够时只返回所需长度。
    count := clay.GetLayoutElementInfo(.[]);
    if count <= 0 {
        ctx.visual_layout.count = 0;
        return;
    }
    array_resize(*ctx.visual_layout, count);
    clay.GetLayoutElementInfo(ui_layout_info_view(ctx.visual_layout));
    for info: ctx.visual_layout {
        table_set(*ctx.visual_elements, info.id, UI_Visual_Element.{
            info = info,
            transform = UI_VISUAL_IDENTITY,
            opacity = 1,
        });
    }
    for info: ctx.visual_layout _ = ui_visual_resolve(ctx, info.id);
}

ui_visual_resolve :: (ctx: *UI_Context, id: u32) -> UI_Visual_Element {
    found, e := table_find(*ctx.visual_elements, id);
    if !found || e.resolving return UI_Visual_Element.{ transform = UI_VISUAL_IDENTITY, opacity = 1 };
    if e.resolved return e;
    e.resolving = true;
    table_set(*ctx.visual_elements, id, e);
    parent := ui_visual_resolve(ctx, e.info.parentId);
    e.transform = parent.transform;
    e.opacity = parent.opacity;
    e.inert = parent.inert;
    is_inert, inert_key := table_find(*ctx.inert, id);
    if is_inert _ = inert_key; // 只关心存在性
    if is_inert e.inert = true;
    ok, v := table_find(*ctx.visuals, id);
    if ok {
        bb := e.info.boundingBox;
        pivot := F.Vector2.{ bb.x + bb.width * v.pivot.x, bb.y + bb.height * v.pivot.y };
        c := JM.cos(v.rotation);
        s := JM.sin(v.rotation);
        local := F.Matrix3x2.{
            c * v.scale.x, s * v.scale.x,
            -s * v.scale.y, c * v.scale.y,
            0, 0,
        };
        local.m31 = pivot.x + v.offset.x - pivot.x * local.m11 - pivot.y * local.m21;
        local.m32 = pivot.y + v.offset.y - pivot.x * local.m12 - pivot.y * local.m22;
        e.transform = ui_visual_compose(parent.transform, local);
        e.opacity *= clamp(v.opacity, 0, 1);
    }
    e.resolved = true;
    e.resolving = false;
    table_set(*ctx.visual_elements, id, e);
    return e;
}

ui_visual_compose :: (a: F.Matrix3x2, b: F.Matrix3x2) -> F.Matrix3x2 {
    return .{
        a.m11 * b.m11 + a.m21 * b.m12, a.m12 * b.m11 + a.m22 * b.m12,
        a.m11 * b.m21 + a.m21 * b.m22, a.m12 * b.m21 + a.m22 * b.m22,
        a.m11 * b.m31 + a.m21 * b.m32 + a.m31,
        a.m12 * b.m31 + a.m22 * b.m32 + a.m32,
    };
}

ui_visual_point :: (m: F.Matrix3x2, p: F.Vector2) -> F.Vector2 {
    return .{ p.x * m.m11 + p.y * m.m21 + m.m31, p.x * m.m12 + p.y * m.m22 + m.m32 };
}

// 第一版裁剪仍为屏幕轴对齐矩形；旋转裁剪容器时使用变换后包围盒。
ui_visual_clip :: (m: F.Matrix3x2, bb: clay.BoundingBox) -> clay.BoundingBox {
    points: [4] F.Vector2 = .[.{ bb.x, bb.y }, .{ bb.x + bb.width, bb.y },
                               .{ bb.x + bb.width, bb.y + bb.height }, .{ bb.x, bb.y + bb.height }];
    lo := ui_visual_point(m, points[0]);
    hi := lo;
    for i: 1..3 {
        p := ui_visual_point(m, points[i]);
        lo = .{ min(lo.x, p.x), min(lo.y, p.y) };
        hi = .{ max(hi.x, p.x), max(hi.y, p.y) };
    }
    return .{ lo.x, lo.y, hi.x - lo.x, hi.y - lo.y };
}
//@endregion

//@region 输入 —— 与既有 clay 一样使用上一帧布局和显示变换

// 返回去掉子树变换后的逻辑指针；供自定义滑条/拖动控件使用。
// 零缩放不可逆时 ok=false，不能开始或推进拖动。
ui_pointer_local :: (ctx: *UI_Context, id: string) -> (point: F.Vector2, ok: bool) {
    return ui_visual_pointer(ctx, clay.ID(id).id, .{ ctx.pointer_x, ctx.pointer_y });
}

ui_visual_pointer :: (ctx: *UI_Context, id: u32, point: F.Vector2) -> (F.Vector2, bool) {
    found, e := table_find(*ctx.visual_elements, id);
    if !found return point, true;
    return ui_visual_inverse_point(e.transform, e.opacity, point);
}

// 逆变换的唯一实现：窗口逻辑坐标 -> 矩阵局部坐标。奇异（不可逆）或整体透明时 ok=false，
// 调用方必须当作「没有命中/不能拖动」，这正是奇异变换下不产生捕获的依据。
ui_visual_inverse_point :: (m: F.Matrix3x2, opacity: float32, point: F.Vector2) -> (F.Vector2, bool) {
    det := m.m11 * m.m22 - m.m12 * m.m21;
    if JM.abs(det) < UI_VISUAL_SINGULAR_EPSILON || opacity <= 0 return .{ 0, 0 }, false;
    p := F.Vector2.{ point.x - m.m31, point.y - m.m32 };
    return .{ (p.x * m.m22 - p.y * m.m21) / det,
              (p.y * m.m11 - p.x * m.m12) / det }, true;
}

UI_VISUAL_SINGULAR_EPSILON :: 0.000001;

ui_visual_inside :: (p: F.Vector2, bb: clay.BoundingBox) -> bool {
    return p.x >= bb.x && p.y >= bb.y && p.x <= bb.x + bb.width && p.y <= bb.y + bb.height;
}
//@endregion

//@region 发射 —— 预乘颜色与最终像素矩阵

ui_visual_apply_ops :: (ctx: *UI_Context, id: u32, ops: *[..] UI_Op, start: int) {
    found, e := table_find(*ctx.visual_elements, id);
    if !found return;
    for i: start..ops.count - 1 {
        op := *ops.*[i];
        if op.kind == .Quad {
            op.transformed = !ui_matrix_identity(e.transform);
            op.transform = e.transform;
            // UI 颜色为预乘 alpha，RGB 和 A 必须同步衰减。
            op.color = .{
                cast(u8) (cast(float32) op.color.r * e.opacity),
                cast(u8) (cast(float32) op.color.g * e.opacity),
                cast(u8) (cast(float32) op.color.b * e.opacity),
                cast(u8) (cast(float32) op.color.a * e.opacity),
            };
        } else if op.kind == .Scissor_Start {
            bb := ui_visual_clip(e.transform, .{ op.clip_x, op.clip_y, op.clip_w, op.clip_h });
            op.clip_x = bb.x;
            op.clip_y = bb.y;
            op.clip_w = bb.width;
            op.clip_h = bb.height;
        }
    }
}

ui_matrix_identity :: (m: F.Matrix3x2) -> bool {
    return m.m11 == 1 && m.m12 == 0 && m.m21 == 0 && m.m22 == 1 && m.m31 == 0 && m.m32 == 0;
}

ui_visual_pixel_matrix :: (ctx: *UI_Context, m: F.Matrix3x2) -> [16] float32 {
    s := ctx.scale;
    return .[m.m11 * s, m.m12 * s, 0, 0,
              m.m21 * s, m.m22 * s, 0, 0,
              0, 0, 1, 0,
              m.m31 * s + ctx.viewport_origin.x, m.m32 * s + ctx.viewport_origin.y, 0, 1];
}
//@endregion

//@region 状态驱动动效

//
// 便利层，建立在 ui_set_visual 之上：自算 UI_Visual、Tween/Sequence 与自绘照常可用，
// 同一 ID 本帧后续的 ui_set_visual 仍按最后一次注册覆盖，嵌套元素的变换照常合成。

//@region 参数

// time 约为到位所需秒数，0 为立即到位；bounce 0 为不过冲，越接近 1 越弹（见 core/tween.spring）。
// 游戏把参数写成具名常量集中放置，配合热重载调手感。
UI_Motion :: struct {
    time: float32;
    bounce: float32;
}

UI_Motion_State :: struct {
    value, velocity: UI_Visual;
    seen: bool;
}

UI_Presence_State :: struct {
    t, velocity: float32;
    seen: bool;
}
//@endregion

//@region 追随与冲击

// 按 ui_begin 的 dt 把该 ID 的当前值推向 target，注册为本帧视觉并返回当前值。
// 首次出现的 ID 直接取 target（入场用 ui_presence）；目标中途改变时保留速度，无需打断。
ui_motion :: (ctx: *UI_Context, id: string, target: UI_Visual, motion: UI_Motion) -> UI_Visual {
    key := clay.ID(id).id;
    state := table_find_pointer(*ctx.motions, key);
    if state == null {
        table_set(*ctx.motions, key, UI_Motion_State.{ value = target, seen = true });
        ui_set_visual(ctx, id, target);
        return target;
    }
    if !state.seen {
        state.value, state.velocity = ui_motion_step(state.value, state.velocity, target, motion, ctx.delta_time);
        state.seen = true;
    }
    ui_set_visual(ctx, id, state.value);
    return state.value;
}

// 给已有状态叠加速度（各字段单位/秒，零值字段无冲击），下一次推进生效并由弹簧回到目标。
// 例如按压回弹 {scale = {-2, -2}}。ID 尚未经 ui_motion 声明时忽略。
ui_motion_kick :: (ctx: *UI_Context, id: string, velocity: UI_Visual) {
    state := table_find_pointer(*ctx.motions, clay.ID(id).id);
    if state != null state.velocity = ui_visual_add(state.velocity, velocity);
}

// 读取当前值与速度，供定制动画在原语结果上加工；ID 没有状态时 ok=false。
ui_motion_state :: (ctx: *UI_Context, id: string) -> (value: UI_Visual, velocity: UI_Visual, ok: bool) {
    found, state := table_find(*ctx.motions, clay.ID(id).id);
    return state.value, state.velocity, found;
}

ui_spring :: (value: float32, velocity: float32, target: float32,
              time: float32, bounce: float32, dt: float32) -> (float32, float32) {
    return tw.spring(value, velocity, target, time, bounce, dt);
}

ui_spring_vec2 :: (value: F.Vector2, velocity: F.Vector2, target: F.Vector2,
                   time: float32, bounce: float32, dt: float32) -> (F.Vector2, F.Vector2) {
    vx, nvx := tw.spring(value.x, velocity.x, target.x, time, bounce, dt);
    vy, nvy := tw.spring(value.y, velocity.y, target.y, time, bounce, dt);
    return .{ vx, vy }, .{ nvx, nvy };
}

ui_motion_step :: (value: UI_Visual, velocity: UI_Visual, target: UI_Visual, motion: UI_Motion,
                   dt: float32) -> (UI_Visual, UI_Visual) {
    next, next_velocity: UI_Visual;
    next.offset, next_velocity.offset = ui_spring_vec2(value.offset, velocity.offset, target.offset,
                                                      motion.time, motion.bounce, dt);
    next.scale, next_velocity.scale = ui_spring_vec2(value.scale, velocity.scale, target.scale,
                                                    motion.time, motion.bounce, dt);
    next.rotation, next_velocity.rotation = ui_spring(value.rotation, velocity.rotation, target.rotation,
                                                     motion.time, motion.bounce, dt);
    next.pivot, next_velocity.pivot = ui_spring_vec2(value.pivot, velocity.pivot, target.pivot,
                                                    motion.time, motion.bounce, dt);
    next.opacity, next_velocity.opacity = ui_spring(value.opacity, velocity.opacity, target.opacity,
                                                    motion.time, motion.bounce, dt);
    return next, next_velocity;
}

ui_visual_add :: (a: UI_Visual, b: UI_Visual) -> UI_Visual {
    return .{ a.offset + b.offset, a.scale + b.scale, a.rotation + b.rotation,
              a.pivot + b.pivot, a.opacity + b.opacity };
}
//@endregion

//@region 进出场

// open 为 true 时进度 t 向 1 推进（enter），false 时向 0 退回（exit）；弹性参数下 t 可能过冲。
// t 怎样映射成画面由调用方决定（如 ui_visual_lerp 或自算）。alive 为 false 时不再声明该元素。
// 退场期间该 ID 的子树从下一帧起不接受指针命中、不参与键盘导航；同名元素须在本帧声明。
ui_presence :: (ctx: *UI_Context, id: string, open: bool, enter: UI_Motion, exit: UI_Motion) -> (alive: bool, t: float32) {
    key := clay.ID(id).id;
    state := table_find_pointer(*ctx.presences, key);
    if state == null {
        if !open return false, 0;
        table_set(*ctx.presences, key, UI_Presence_State.{});
        state = table_find_pointer(*ctx.presences, key);
    }
    if !state.seen {
        motion := exit;
        if open motion = enter;
        target: float32;
        if open target = 1;
        state.t, state.velocity = tw.spring(state.t, state.velocity, target, motion.time, motion.bounce, ctx.delta_time);
        state.seen = true;
    }
    if !open && state.t <= UI_PRESENCE_EPSILON {
        table_remove(*ctx.presences, key);
        return false, 0;
    }
    if !open table_set(*ctx.inert, key, 1);
    return true, state.t;
}

UI_PRESENCE_EPSILON: float32 : 0.001;

// 上一帧布局中该元素位于退场子树内。
ui_visual_inert :: (ctx: *UI_Context, id: u32) -> bool {
    found, e := table_find(*ctx.visual_elements, id);
    return found && e.inert;
}
//@endregion

//@region 帧末回收

ui_motion_end :: (ctx: *UI_Context) {
    ui_motion_prune_motions(ctx);
    ui_motion_prune_presences(ctx);
}

// 遍历中不删键：先收集再删。
ui_motion_prune_motions :: (ctx: *UI_Context) {
    stale: [..] u32;
    for *state, key: *ctx.motions {
        if !state.seen array_add(*stale, key);
        state.seen = false;
    }
    for key: stale table_remove(*ctx.motions, key);
    array_free(stale);
}

ui_motion_prune_presences :: (ctx: *UI_Context) {
    stale: [..] u32;
    for *state, key: *ctx.presences {
        if !state.seen array_add(*stale, key);
        state.seen = false;
    }
    for key: stale table_remove(*ctx.presences, key);
    array_free(stale);
}
//@endregion
//@endregion

//@region 命中测试 —— clay 的可插拔命中回调（SetPointerHitTestFunction）

// clay 在 _BackendPointInside 里调用它（clay_layout 的 pointerOverIds / 滚动优先级 / onHover 都
// 走这里）。两种调用形态：
//   clip = false：id 是**被测试的元素**，bounds 是它的布局框 —— 指针要逆变换进该元素的局部空间；
//   clip = true ：id 是**裁剪祖先**，bounds 是它的布局框 —— clay 原生只检查最近一级裁剪，为了与
//                 完整嵌套 scissor 一致，这里先用裁剪祖先自己的变换把框变到屏幕空间再判。
// 视口外与退场（presence 的 inert）子树一律不命中；奇异变换（不可逆）或整体透明同样不命中，
// 这也正是「奇异变换下不产生捕获」的依据。

ui_visual_hit :: (id: u32, position: clay.Vector2, bounds_arg: clay.BoundingBox,
                  clip: bool, user_data: *void) -> bool {
    bounds := bounds_arg;
    ctx := cast(*UI_Context) user_data;
    if ctx == null return false;
    p := F.Vector2.{ position[0], position[1] };
    push_context ctx.callback_context {
        if !ui_visual_inside(p, .{ 0, 0, ctx.width, ctx.height }) || ui_visual_inert(ctx, id) {
            return false;
        }
        if clip {
            found, e := table_find(*ctx.visual_elements, id);
            if found bounds = ui_visual_clip(e.transform, bounds);
        } else {
            local, ok := ui_visual_pointer(ctx, id, p);
            if !ok return false;
            p = local;
            // clay 原生只检查最近一级裁剪；动画命中需要与完整嵌套 scissor 相交一致。
            found, e := table_find(*ctx.visual_elements, id);
            if found {
                clip_id := e.info.clipId;
                depth := 0;
                while clip_id != 0 && depth < ctx.visual_elements.count {
                    ancestor_found, ancestor := table_find(*ctx.visual_elements, clip_id);
                    if !ancestor_found break;
                    bb := ui_visual_clip(ancestor.transform, ancestor.info.boundingBox);
                    if !ui_visual_inside(F.Vector2.{ position[0], position[1] }, bb) return false;
                    clip_id = ancestor.info.clipId;
                    depth += 1;
                }
            }
        }
        return ui_visual_inside(p, bounds);
    }
}

//@endregion
