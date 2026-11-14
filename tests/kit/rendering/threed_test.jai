// 一比一移植自 olib tests/kit/rendering/3d/rendering3d_test.odin（CPU 侧用例）。
// GPU 路径不创建真实设备：假设备 + handle != 0 的假 Shader/贴图，只验证绑定与错误码，
// 与 olib 的「device: foster.GraphicsDevice」同一思路。
//
// 断言顺序、数值与诊断文本与 olib 一一对应。Jai 侧的写法差异：
//   | olib (Odin, core:testing)                    | 这里 (Jai, Tests/test_support.jai)                    |
//   | -------------------------------------------- | ----------------------------------------------------- |
//   | testing.expect(t, cond)                      | expect(state, cond, "说明")                            |
//   | testing.expect_value(t, a, b)                | expect(state, a == b, "说明")                          |
//   | testing.expectf(t, cond, "%v", a)            | expect(state, cond, "说明 % -> %", a, b)                |
//   | `[4]int{a,b}` + `order == [4]int{…}`         | 逐元素比较（Jai 的数组没有 ==）                          |
//   | `len(x)`                                     | `x.count`                                              |
//   | `[]f32{…}` / `{1, 2}`                        | `.[…]`（数组字面量要类型标注）                            |
//   | `foster.GraphicsDevice{…}` 当假设备           | `F.Graphics_Device` + `disposed = false`（jfoster 的零值  |
//   |                                              | 设备是「已销毁」）                                       |
//   | `foster.Shader{}.Resource = uintptr(1)`      | `New(F.Shader)` + `handle = 1` + `device`              |
//   | `foster.Mesh{GraphicsDevice = &device}`      | `*F.Mesh` + 显式 `*F.Graphics_Buffer`（jfoster 的网格    |
//   |  + `VertexData.Format.Stride = …`            | 用指针持有缓冲，没有内联的 VertexData）                   |
//   | `mat.Material{owner = &lib, …}`               | `mat.Material.{ owner = *lib, … }`                     |
//   | `[]sh.Pass_Desc{…}`                          | 定长数组 + `array_view`                                 |
//   | 嵌套 proc（read_vec4 / id_at / corners_bounds）| 顶层过程                                              |
//   | `transmute(f32)u32(0x7fc00000)`               | `JM.FLOAT32_NAN`                                       |
//   | `world.Matrix4{}` 比较                        | `W.matrix4_equal`                                      |
#import "Basic";
#import "test_support";
JM :: #import "Math";
F :: #import "foster";
mat :: #import "kit/rendering/material";
sh :: #import "kit/rendering/shader";
W :: #import "kit/world";
DA :: #import "core/dasset";
#import "kit/rendering/3d";

//@region 工具

// Tests/test_support.jai 的 expect 把 ..Any 当成一个整体再喂给 sprint（格式串的第二个 % 会报
// 「argument index is out of range」），这里用 `..args` 正确展开；计数仍记在同一个 Test_State 上。
expectf :: (state: *Test_State, condition: bool, msg: string, args: ..Any) {
    if condition {
        state.passed += 1;
    } else {
        state.failed += 1;
        print("  [FAIL] %
", sprint(msg, ..args));
    }
}

floats4_eq :: (a: [4] float32, b: [4] float32) -> bool {
    for i: 0..3 {
        if a[i] != b[i] return false;
    }
    return true;
}

v3_length :: (v: W.Vec3) -> float32 {
    return JM.sqrt(W.v3_dot(v, v));
}

// olib 的 [3]f32 与 foster.Vec3 可以互相赋值；Jai 里 Vector3 是结构体，要显式搬。
to_vec3 :: (v: [3] float32) -> W.Vec3 {
    return W.Vec3.{ v[0], v[1], v[2] };
}

// olib: read_vec4(buf, offset) —— 小端 4 个 f32。
read_vec4 :: (buf: [] u8, offset: int) -> [4] float32 {
    v: [4] float32;
    memcpy(*v, buf.data + offset, 16);
    return v;
}

read_column :: (buf: [] u8, offset: int) -> W.Matrix4 {
    result: W.Matrix4;
    result.c0 = read_vec4(buf, offset);
    result.c1 = read_vec4(buf, offset + 16);
    result.c2 = read_vec4(buf, offset + 32);
    result.c3 = read_vec4(buf, offset + 48);
    return result;
}

// jfoster 的零值设备是「已销毁」，假设备必须显式置 disposed = false。
fake_device :: () -> *F.Graphics_Device {
    device := New(F.Graphics_Device);
    device.disposed = false;
    return device;
}

// olib: `foster.Shader{}.Resource = uintptr(1)` —— 只满足「句柄非空」，不创建管线。
fake_shader :: (device: *F.Graphics_Device, stage: F.Shader_Stage) -> *F.Shader {
    program := New(F.Shader);
    program.device = device;
    program.handle = 1;
    program.Stage = stage;
    return program;
}

// olib 的 foster.Mesh 内联持有缓冲；jfoster 用指针，且 render3d_validate_mesh 会查缓冲格式。
fake_mesh :: (device: *F.Graphics_Device, stride: s32) -> *F.Mesh {
    mesh := New(F.Mesh);
    mesh.device = device;
    buffer := New(F.Graphics_Buffer);
    buffer.device = device;
    buffer.Kind = .VERTEX;
    buffer.handle = 1;
    buffer.Format.Stride = stride;
    mesh.VertexBuffer = buffer;
    return mesh;
}

release_fake_mesh :: (mesh: *F.Mesh) {
    if mesh == null return;
    if mesh.VertexBuffer != null free(mesh.VertexBuffer);
    free(mesh);
}

fake_gpu_material :: (device: *F.Graphics_Device) -> *F.Material {
    return F.material_create(fake_shader(device, .VERTEX), fake_shader(device, .FRAGMENT));
}

// F.material_destroy 只还 Material 本身；两个假 Shader 由这里一起 free。
release_fake_gpu_material :: (gpu: *F.Material) {
    if gpu == null return;
    vertex := gpu.Vertex.shader;
    fragment := gpu.Fragment.shader;
    F.material_destroy(gpu);
    if vertex != null free(vertex);
    if fragment != null free(fragment);
}

// olib: view.target.WidthInPixels / HeightInPixels = w, h（foster 的 DrawableTarget 是值）。
// jfoster 从 *Target 取尺寸，所以借一个堆上的 Target（只读尺寸，不碰 GPU）。
fake_target :: (width: s32, height: s32) -> *F.Target {
    target := New(F.Target);
    target.Width = width;
    target.Height = height;
    return target;
}
//@endregion

//@region 顶点格式 / 队列 / 打包

mesh_format_strides :: (state: *Test_State) {
    static := mesh_static_format();
    expect(state, static.Stride == 48 && static.ElementCount == 4, "静态顶点格式 48B / 4 元素");
    skin := mesh_skin_format();
    expect(state, skin.Stride == 68 && skin.ElementCount == 6, "蒙皮顶点格式 68B / 6 元素");
}

queue_sort_buckets_and_depth :: (state: *Test_State) {
    q: Render_Queue(int);
    defer queue_dispose(*q);

    // 提交乱序：透明(5)、不透明(10)、透明(1)、不透明(2)；payload 记提交序
    queue_submit(*q, 0, 5, true);
    queue_submit(*q, 1, 10, false);
    queue_submit(*q, 2, 1, true);
    queue_submit(*q, 3, 2, false);

    queue_sort(*q);

    // 不透明在前（前到后 2,10），透明在后（后到前 5,1）
    expect(state, q.items.count == 4, "四项都保留");
    order: [4] int = .[q.items[0].payload, q.items[1].payload, q.items[2].payload, q.items[3].payload];
    expected: [4] int = .[3, 1, 0, 2];
    for value, i: order {
        expectf(state, value == expected[i], "不透明前到后、透明后到前：第 % 项是 %", i, value);
    }
    expect(state, !q.items[0].transparent && q.items[3].transparent, "不透明在队首、透明在队尾");

    queue_clear(*q);
    expect(state, q.items.count == 0, "clear 清空队列");
    queue_submit(*q, 0, 20, false, 0);
    queue_submit(*q, 1, 4, false, 1);
    queue_submit(*q, 2, 2, false, 0);
    queue_submit(*q, 3, 8, true, 1);
    queue_submit(*q, 4, 12, true, 0);
    queue_submit(*q, 5, 12, true, 1);
    queue_sort(*q, grouped = true);
    grouped_expected: [6] int = .[2, 0, 1, 4, 5, 3];
    for item, i: q.items {
        expectf(state, item.payload == grouped_expected[i], "按组排序：第 % 项是 %", i, item.payload);
    }

    // 两组最近深度相同（都是 3）时按 group 键排列，组内仍前到后。
    queue_clear(*q);
    queue_submit(*q, 0, 9, false, 7);
    queue_submit(*q, 1, 3, false, 7);
    queue_submit(*q, 2, 5, false, 2);
    queue_submit(*q, 3, 3, false, 2);
    queue_submit(*q, 4, 1, false, 9); // 最近深度 1 的组排最前
    queue_sort(*q, grouped = true);
    tied: [5] int = .[4, 3, 2, 1, 0];
    for item, i: q.items {
        expectf(state, item.payload == tied[i], "同深度按组键：第 % 项是 %", i, item.payload);
    }

    // 组键超出数组范围（负数或很大）时走 map，排序结果相同。
    queue_clear(*q);
    queue_submit(*q, 0, 9, false, 7000000);
    queue_submit(*q, 1, 3, false, 7000000);
    queue_submit(*q, 2, 5, false, -2);
    queue_submit(*q, 3, 3, false, -2);
    queue_submit(*q, 4, 1, false, 9);
    queue_sort(*q, grouped = true);
    sparse: [5] int = .[4, 3, 2, 1, 0];
    for item, i: q.items {
        expectf(state, item.payload == sparse[i], "组键越界退回 map：第 % 项是 %", i, item.payload);
    }
}

queue_view_depth_uses_object_position :: (state: *Test_State) {
    camera: W.Camera3D;
    W.camera3d_init(*camera, 1280, 720);
    W.camera3d_set_position(*camera, W.Vec3.{ 0, 0, 10 });
    W.camera3d_set_target(*camera, W.Vec3.{ 0, 0, 0 });

    near_depth := queue_view_depth(*camera, W.matrix4_translation(0, 0, 5));
    far_depth := queue_view_depth(*camera, W.matrix4_translation(0, 0, -5));
    expectf(state, JM.abs(near_depth - 5) < 1e-4, "近处物体距离 5: %", near_depth);
    expectf(state, JM.abs(far_depth - 15) < 1e-4, "远处物体距离 15: %", far_depth);
}

vertex_matrix_block_pack_layout :: (state: *Test_State) {
    buf: [1024] u8;

    // WVP 与 World 各占 64B，按 Matrix4 的 c0..c3 顺序写入
    wvp := W.matrix4_translation(1, 2, 3);
    w := W.matrix4_scaling(4, 5, 6);
    expect(state, pack_vertex_matrix_block(buf, wvp, w), "矩阵块写入成功");
    read_back := read_column(buf, 0);
    expect(state, W.matrix4_equal(read_back, wvp), "WVP 读回一致");
    world_back := read_column(buf, 64);
    expect(state, W.matrix4_equal(world_back, w), "World 读回一致");

    // 越界拒绝
    expect(state, !pack_vertex_matrix_block(array_view(buf, 0, 64), wvp, w), "缓冲不足 128B 拒绝");
}

joint_palette_fills_identity_beyond_count :: (state: *Test_State) {
    buf0: [JOINT_PALETTE_BLOCK_SIZE] u8;
    buf1: [JOINT_PALETTE_BLOCK_SIZE] u8;

    palette: [2] W.Matrix4;
    palette[1] = W.matrix4_translation(9, 9, 9);

    expect(state, pack_joint_palette(buf0, buf1, array_view(palette, 0, 2)), "两块 palette 写入成功");
    // 0、1 号来自 palette；2..63 与第二块全部是单位阵
    m1 := read_column(buf0, 64);
    expect(state, W.matrix4_equal(m1, W.matrix4_translation(9, 9, 9)), "1 号关节来自 palette");
    expect(state, palette_slot_is_identity(buf0, 2), "0 块 2 号补单位阵");
    expect(state, palette_slot_is_identity(buf0, 63), "0 块 63 号补单位阵");
    expect(state, palette_slot_is_identity(buf1, 0), "1 块 0 号补单位阵");
    expect(state, palette_slot_is_identity(buf1, 63), "1 块 63 号补单位阵");
}

palette_slot_is_identity :: (buf: [] u8, index: int) -> bool {
    return W.matrix4_equal(read_column(buf, index * 64), W.MATRIX4_IDENTITY);
}

shader_blobs_embedded :: (state: *Test_State) {
    // 内嵌 blob 编译期存在且非空（常量数组保证，运行时兜底断言）
    expect(state, debugline_vertex_spv.count > 4 && debugline_vertex_dxil.count > 4, "内嵌 blob 非空");
    // SPIR-V 魔数 0x07230203（小端 03 02 23 07）
    spv := debugline_vertex_spv;
    expect(state, spv[0] == 0x03 && spv[1] == 0x02 && spv[2] == 0x23 && spv[3] == 0x07, "SPIR-V 魔数");
    // DXIL 容器魔数 "DXBC"
    dxil := debugline_vertex_dxil;
    // Jai 没有字符字面量：用码位比较
    expect(state, dxil[0] == 68 && dxil[1] == 88 && dxil[2] == 66 && dxil[3] == 67, "DXIL 容器魔数 DXBC");
    // MSL 是源码，以 #include 开头
    expect(state, debugline_vertex_msl.count > 0 && debugline_vertex_msl[0] == 35, "MSL 以 #开头");
}
//@endregion

//@region DebugDraw3D —— 几何生成计数与四边形展开

debug_draw_geometry_counts :: (state: *Test_State) {
    d: Debug_Draw_3D;
    defer debug_draw_dispose(*d); // 无 GPU：只清 vertices

    // 盒：12 条棱 = 24 端点
    debug_draw_aabb(*d, DA.Dasset_Bounds.{ min = .[-1, -1, -1], max = .[1, 1, 1] }, .[1, 1, 1, 1]);
    expect(state, debug_draw_line_count(*d) == 12, "盒 12 条棱");
    debug_draw_clear(*d);

    // 球：3 平面 × segments 条
    debug_draw_sphere(*d, .[0, 0, 0], 2, .[1, 1, 1, 1], segments = 8);
    expect(state, debug_draw_line_count(*d) == 3 * 8, "球 3 个平面各 8 段");
    debug_draw_clear(*d);

    // 网格：half=2 -> 5 条 × 2 方向 = 10 条
    debug_draw_grid(*d, 2, 1, .[0.5, 0.5, 0.5, 1]);
    expect(state, debug_draw_line_count(*d) == 10, "网格 10 条");
    debug_draw_clear(*d);

    // 视锥：默认相机（可逆矩阵）12 条棱
    camera: W.Camera3D;
    W.camera3d_init(*camera, 1280, 720);
    debug_draw_frustum(*d, W.camera3d_view_projection(*camera), .[1, 1, 1, 1]);
    expect(state, debug_draw_line_count(*d) == 12, "视锥 12 条棱");
}

debug_draw_expand_builds_quads :: (state: *Test_State) {
    d: Debug_Draw_3D;
    defer debug_draw_dispose(*d);
    d.thickness = 0.1;

    debug_draw_line(*d, .[0, 0, 0], .[1, 0, 0], .[1, 1, 1, 1]); // 沿 X
    expect(state, debug_draw_line_count(*d) == 1, "一条线");

    expanded: [..] Debug_Line_Vertex;
    defer {
        if expanded.data != null array_free(expanded);
    }
    debug_draw_expand(*d, .[0, 5, 0], *expanded); // 相机在 +Y 上看 X 线

    // 1 条线 -> 6 顶点（两个三角形）
    expect(state, expanded.count == 6, "1 条线展开 6 顶点");
    // 侧向在 Z（cross(X, toCam) = Z），半厚 0.05：X 线在 XZ 平面内展开
    a0 := expanded[0].position;
    a1 := expanded[5].position;
    expectf(state, JM.abs(a0[0]) < 1e-6 && JM.abs(a0[1]) < 1e-6, "a0 无 X/Y 偏移: % %", a0[0], a0[1]);
    expectf(state, JM.abs(JM.abs(a0[2] - a1[2]) - 0.1) < 1e-5, "厚度 0.1: %", JM.abs(a0[2] - a1[2]));
    // 颜色透传
    expect(state, floats4_eq(expanded[0].color, .[1, 1, 1, 1]), "颜色透传");
}
//@endregion

//@region LOD 选择

lod_selector_thresholds_and_hysteresis :: (state: *Test_State) {
    s: Lod_Selector;
    thresholds: [3] float32 = .[0.5, 0.2, 0];
    expect(state, lod_selector_init(*s, thresholds), "阈值合法");
    defer lod_selector_dispose(*s);
    expect(state, lod_selector_level_count(*s) == 3, "3 级");

    // 非法阈值拒绝
    bad: Lod_Selector;
    last_not_zero: [2] float32 = .[0.5, 0.2];
    expect(state, !lod_selector_init(*bad, last_not_zero), "末项非 0 拒绝");
    not_descending: [3] float32 = .[0.2, 0.5, 0];
    expect(state, !lod_selector_init(*bad, not_descending), "非降序拒绝");
    expect(state, !lod_selector_init(*bad, .[]), "空阈值拒绝");

    // 全量初选
    expect(state, lod_selector_select(*s, 0.6) == 0, "0.6 选最高细节");
    expect(state, lod_selector_select(*s, 0.3) == 1, "0.3 选中间级");
    expect(state, lod_selector_select(*s, 0.05) == 2, "0.05 选最低级");

    // 滞回：0.2 边界附近（0.19 不降级、0.17 降级，滞回 0.1）
    s.current_level = 1;
    expect(state, lod_selector_select(*s, 0.19) == 1, "0.19 >= 0.2*(1-0.1)=0.18 保持");
    expect(state, lod_selector_select(*s, 0.17) == 2, "0.17 < 0.18 降级");

    s.current_level = 1;
    expect(state, lod_selector_select(*s, 0.53) == 1, "0.53 < 0.5*1.1=0.55 保持");
    expect(state, lod_selector_select(*s, 0.56) == 0, "0.56 >= 0.55 升级");
}

lod_screen_height_estimates :: (state: *Test_State) {
    camera: W.Camera3D;
    W.camera3d_init(*camera, 1280, 720);
    W.camera3d_set_position(*camera, W.Vec3.{ 0, 0, 10 });

    // 前方 1 单位立方体（中心距相机约 10）
    h := lod_screen_height(*camera, DA.Dasset_Bounds.{ min = .[-0.5, -0.5, -0.5], max = .[0.5, 0.5, -1.5] });
    expectf(state, h > 0.01 && h < 10, "合理的屏幕高度: %", h);

    // 相机在盒内 -> 无穷大
    inside := lod_screen_height(*camera, DA.Dasset_Bounds.{ min = .[-20, -20, -20], max = .[20, 20, 20] });
    expect(state, inside == JM.FLOAT32_INFINITY, "相机在球内返回 +inf");
}

// 变换后的包围球：平移时半径不变；旋转后再非均匀缩放时，只变换 min/max 两个角会低估半径。
lod_world_sphere_is_conservative :: (state: *Test_State) {
    bounds := DA.Dasset_Bounds.{ min = .[-2, -0.5, -0.5], max = .[2, 0.5, 0.5] };
    center, radius, ok := lod_world_sphere(bounds, W.matrix4_translation(1, 2, 3));
    expect(state, ok, "仿射矩阵有效");
    expect(state, v3_length(W.v3_sub(center, W.Vec3.{ 1, 2, 3 })) < 1e-5, "球心是盒中心的像");
    expectf(state, JM.abs(radius - v3_length(W.v3_sub(to_vec3(bounds.max), to_vec3(bounds.min))) * 0.5) < 1e-5,
    "平移不改变半径");

    // 绕 Z 转 ±45° 后沿 Y 拉长 3 倍：盒的轴不再正交，两条对角线长度不同；
    // 只变换 min/max 两个角在其中一个方向上取到短对角线，必然低估。
    underestimated := false;
    signs: [2] float32 = .[1, -1];
    for sign: signs {
        half := sign * cast(float32) JM.PI / 8;
        rotated := W.matrix4_from_quaternion(.[0, 0, JM.sin(half), JM.cos(half)]);
        m := W.matrix4_multiply(rotated, W.matrix4_scaling(1, 3, 1));
        center, radius, ok = lod_world_sphere(bounds, m);
        expect(state, ok, "旋转+缩放矩阵有效");
        corners := aabb_corners(bounds);
        for corner: corners {
            p, valid := W.matrix4_transform_point(m, W.Vec3.{ corner[0], corner[1], corner[2] });
            expect(state, valid && v3_length(W.v3_sub(p, center)) <= radius + 1e-4, "所有角点都在球内");
        }
        two_corners := v3_length(W.matrix4_transform_vector(m, W.v3_sub(to_vec3(bounds.max), to_vec3(bounds.min)))) * 0.5;
        expect(state, radius >= two_corners - 1e-4, "半径不小于两角点对角线的一半");
        if two_corners < radius - 0.5 underestimated = true;
    }
    expect(state, underestimated, "只变换两个角点会低估（本实现没有）");
}
//@endregion

//@region Render3D

render3d_views_preserve_records :: (state: *Test_State) {
    device := fake_device();
    defer free(device);
    library: mat.Material_Library;
    library.device = device;
    r: Render3D;
    r.library = *library;
    defer dispose(*r);

    gpu := fake_gpu_material(device);
    defer release_fake_gpu_material(gpu);

    passes: [2] sh.Pass_Desc;
    passes[0] = sh.Pass_Desc.{ id = "body", params = "Body", draw = .Model };
    passes[1] = sh.Pass_Desc.{ id = "off", params = "Body", draw = .Model, disabled = true };
    shader := mat.Material_Shader.{ desc = sh.Shader_Desc.{ passes = array_view(passes, 0, 2) } };
    bindings: [1] mat.Material_Binding;
    bindings[0] = mat.Material_Binding.{ schema = sh.Schema.{ name = "Body" }, material = gpu };
    material := mat.Material.{ owner = *library, shader = *shader, bindings = array_view(bindings, 0, 1) };

    mesh := fake_mesh(device, DA.DASSET_VERTEX_STRIDE_STATIC);
    defer release_fake_mesh(mesh);
    bounds := DA.Dasset_Bounds.{ min = .[-0.1, -0.1, -0.1], max = .[0.1, 0.1, 0.1] };
    positions: [2] float32 = .[0, 4];
    for x: positions {
        expectf(state, model(*r, mesh, *material, W.matrix4_translation(x, 0, 0.5), *bounds) ==
        mat.Draw_Error.None, "记录 x=% 的模型", x);
    }
    bounds.max = .[0, 0, 0]; // 调用者改原数据不影响记录
    view := View.{ view_projection = W.MATRIX4_IDENTITY, view_matrix = W.MATRIX4_IDENTITY };
    expect(state, render3d_prepare(*r, view, "body") == mat.Draw_Error.None, "准备 body");
    expect(state, r.queue.items.count == 1, "视锥只留下 x=0 的一项");
    expect(state, r.queue.items[0].payload == 0, "留下的是第一条记录");
    view.view_projection = W.matrix4_translation(-4, 0, 0);
    expect(state, render3d_prepare(*r, view, "body") == mat.Draw_Error.None, "准备平移后的 body");
    expect(state, r.queue.items.count == 1, "平移后仍只有一项");
    expect(state, r.queue.items[0].payload == 1, "留下的是第二条记录");
    expect(state, r.records.count == 2, "记录不被视图消耗");
    expect(state, render3d_prepare(*r, view, "off") == mat.Draw_Error.None, "禁用的 Pass 也存在于声明中");
    expect(state, r.queue.items.count == 0, "禁用的 Pass 没有可画内容");
    expect(state, render3d_prepare(*r, view, "typo") == mat.Draw_Error.Unknown_Pass, "未知 Pass");
    expect(state, submit(*r, view) == mat.Draw_Error.Invalid_Target, "目标无效");
    // 零视矩阵不当成单位矩阵：有记录时明确报错，记录保留。
    target := fake_target(4, 4);
    defer free(target);
    missing := view;
    missing.target = F.drawable_target_target(target);
    missing.view_matrix = W.Matrix4.{};
    expect(state, submit(*r, missing) == mat.Draw_Error.Missing_View_Matrix, "缺视矩阵");
    expect(state, r.records.count == 2, "报错保留记录");
    // 视图块超长同样在发 Draw 之前报错，记录保留。
    oversized := missing;
    oversized.view_matrix = W.MATRIX4_IDENTITY;
    big: [mat.VIEW_GLOBALS_SIZE + 16] u8;
    oversized.globals = array_view(big, 0, mat.VIEW_GLOBALS_SIZE + 16);
    expect(state, submit(*r, oversized) == mat.Draw_Error.View_Globals_Too_Large, "视图块超长");
    expect(state, r.records.count == 2, "超长同样保留记录");
    clear(*r);
    expect(state, r.records.count == 0, "clear 清空记录");
    expect(state, submit(*r, view, "body") == mat.Draw_Error.None, "没有记录时提交不做事");
}

instance_buffer_layout_and_guards :: (state: *Test_State) {
    expect(state, model_stride(0) == 80, "没有字段时每实例 80B");
    expect(state, model_stride(2) == 112, "2 个字段时每实例 112B");
    expect(state, size_of(Model_Item) == model_stride(0), "Model_Item 与缓冲同一布局");
    // 槽数取自材质：没有材质、不是 instanced Shader、各参数组字段数不一致、容量为 0 都拒绝（不碰 GPU）。
    device := fake_device();
    defer free(device);
    library: mat.Material_Library;
    library.device = device;
    fields: [2] sh.Field = .[
    sh.Field.{ id = "hue", instance = true },
    sh.Field.{ id = "glow", instance = true },
    ];
    plain_schemas: [1] sh.Schema;
    plain_schemas[0] = sh.Schema.{ fields = array_view(fields, 0, 2) };
    plain := mat.Material_Shader.{ schemas = array_view(plain_schemas, 0, 1) };
    instanced_schemas: [2] sh.Schema;
    instanced_schemas[0] = sh.Schema.{ fields = array_view(fields, 0, 2) };
    instanced_schemas[1] = sh.Schema.{ fields = array_view(fields, 0, 1) };
    instanced := mat.Material_Shader.{ desc = sh.Shader_Desc.{ instanced = true },
    schemas = array_view(instanced_schemas, 0, 2) };
    buffer: Model_Buffer;
    expect(state, model_buffer_init(*buffer, null, 10) != "", "没有材质");
    plain_material := mat.Material.{ owner = *library, shader = *plain };
    expect(state, model_buffer_init(*buffer, *plain_material, 10) != "", "非 instanced Shader");
    material := mat.Material.{ owner = *library, shader = *instanced };
    expect(state, model_buffer_init(*buffer, *material, 10) != "", "各参数组字段数不一致");
    instanced.schemas = array_view(instanced_schemas, 0, 1);
    expect(state, model_buffer_init(*buffer, *material, 0) != "", "容量为 0");
    expect(state, buffer.capacity == 0, "失败的初始化不留容量");
    // 未创建的缓冲拒绝上传；越界被拒绝。
    instances: [2] Model_Item;
    expect(state, !model_buffer_upload(*buffer, instances), "未创建缓冲");
    buffer.capacity = 1;
    expect(state, !model_buffer_upload(*buffer, instances), "超出容量");
    expect(state, !model_buffer_upload(*buffer, array_view(instances, 0, 1), 1), "起始位置越界");
    buffer.capacity = 2;
    buffer.slots = 2;
    values: [3][4] float32;
    expect(state, !model_buffer_upload(*buffer, instances, 0, values), "values 长度应为 2×2");
}

// 同一组记录验证：实例数值不拆批、参数快照拆批、透明顺序屏障、多 Pass 独立覆盖。
render3d_instances_snapshots_and_order :: (state: *Test_State) {
    device := fake_device();
    defer free(device);
    library: mat.Material_Library;
    library.device = device;
    r: Render3D;
    r.library = *library;
    defer dispose(*r);

    gpu := fake_gpu_material(device);
    defer release_fake_gpu_material(gpu);

    fields: [3] sh.Field = .[
   sh.Field.{ id = "hue", kind = .Scalar, instance = true, maximum = 1 },
   sh.Field.{ id = "gain", kind = .Scalar, maximum = 1 },
   sh.Field.{ id = "albedo", kind = .Texture },
   ];
    schemas: [1] sh.Schema;
    schemas[0] = sh.Schema.{ name = "Body", fields = array_view(fields, 0, 3) };
    pass_values: [1] sh.Pass_Value;
    pass_values[0] = sh.Pass_Value.{ field = "hue", number = .[0.9, 0, 0, 0] };
    passes: [3] sh.Pass_Desc;
    passes[0] = sh.Pass_Desc.{ id = "body", params = "Body", draw = .Model };
    passes[1] = sh.Pass_Desc.{ id = "shadow", params = "Body", draw = .Model,
    values = array_view(pass_values, 0, 1) };
    passes[2] = sh.Pass_Desc.{ id = "glass", params = "Body", draw = .Model,
    state = sh.Pass_State.{ blend = .Alpha } };
    shader := mat.Material_Shader.{ desc = sh.Shader_Desc.{ instanced = true, passes = array_view(passes, 0, 3) },
    schemas = array_view(schemas, 0, 1) };

    texture := New(F.Texture);
    texture.handle = 1;
    other_texture := New(F.Texture);
    other_texture.handle = 1;

    values: [3] sh.Value;
    values[0] = sh.Value.{ number = .[0.2, 0, 0, 0] };
    values[1] = sh.Value.{ number = .[0.5, 0, 0, 0] };
    samplers: [1] F.Bound_Sampler;
    samplers[0] = F.Bound_Sampler.{ Tex = texture };
    bindings: [1] mat.Material_Binding;
    bindings[0] = mat.Material_Binding.{ schema = schemas[0], values = array_view(values, 0, 3),
    material = gpu, samplers = array_view(samplers, 0, 1) };
    m := mat.Material.{ owner = *library, shader = *shader, bindings = array_view(bindings, 0, 1) };

    mesh := fake_mesh(device, DA.DASSET_VERTEX_STRIDE_STATIC);
    defer release_fake_mesh(mesh);
    other_mesh := fake_mesh(device, DA.DASSET_VERTEX_STRIDE_STATIC);
    defer release_fake_mesh(other_mesh);

    flat: [2][4] float32 = .[.[0.4, 0, 0, 0], .[0.6, 0, 0, 0]];
    items: [2] Model_Item = .[
    Model_Item.{ world = W.matrix4_translation(0, 0, -5), tint = .[1, 1, 1, 1] },
    Model_Item.{ world = W.matrix4_translation(0, 0, -4), tint = .[1, 1, 1, 1] },
    ];
    expect(state, models(*r, mesh, *m, items, values = flat) == mat.Draw_Error.None, "两条实例记录");
    expect(state, r.values[0][0] == 0.4, "实例 0 的 body 用平铺值");
    expect(state, r.values[1][0] == 0.9, "shadow 用 Pass 固定值");
    expect(state, r.values[3][0] == 0.6, "实例 1 的 body 用平铺值");
    flat[0] = .[0, 0, 0, 0];
    items[0].world = W.MATRIX4_IDENTITY;
    expectf(state, model(*r, other_mesh, *m, W.matrix4_translation(0, 0, -7)) == mat.Draw_Error.None,
    "另一网格的记录");
    expectf(state, model(*r, mesh, *m, W.matrix4_translation(0, 0, -10)) == mat.Draw_Error.None,
    "同网格的记录");
    expect(state, r.sources.count == 1, "实例值不进入合批键");
    expect(state, r.values[6][0] == 0.2, "nil 覆盖使用材质默认值");
    line(*r, .[0, 0, 0], .[1, 0, 0], .[1, 1, 1, 1]);
    view := View.{ view_projection = W.MATRIX4_IDENTITY, view_matrix = W.MATRIX4_IDENTITY };
    expect(state, render3d_prepare(*r, view, "body") == mat.Draw_Error.None, "准备 body");
    expect(state, render3d_batch_end(*r, 0) == 2, "同网格两条记录合批");
    expect(state, render3d_prepare(*r, view, "glass") == mat.Draw_Error.None, "准备 glass");
    expected: [4] int = .[3, 2, 0, 1];
    for item, i: r.queue.items {
        expectf(state, item.payload == expected[i], "透明后到前：第 % 项是 %", i, item.payload);
    }
    expect(state, render3d_batch_end(*r, 0) == 1, "换网格断批");
    expect(state, render3d_batch_end(*r, 2) == 4, "同网格继续合批");
    expect(state, render3d_prepare(*r, view, "") == mat.Draw_Error.None, "准备全部 Pass");
    expect(state, render3d_batch_end(*r, 2) == 3, "透明多 Pass 不跨对象");
    expect(state, debug_draw_line_count(*r.debug) == 1, "调试线已排队");
    // 修改参数或贴图必须新建快照；原记录仍保留先前值。这里直接改数值并像
    // material_set_number / material_set_texture 一样递增 revision。
    values[1].number[0] = 0.8;
    m.revision += 1;
    expect(state, model(*r, mesh, *m, W.MATRIX4_IDENTITY) == mat.Draw_Error.None, "改参数后记录");
    expect(state, r.sources.count == 2, "参数变化新建来源");
    samplers[0].Tex = other_texture;
    m.revision += 1;
    expect(state, model(*r, mesh, *m, W.MATRIX4_IDENTITY) == mat.Draw_Error.None, "改贴图后记录");
    expect(state, r.sources.count == 3, "贴图变化新建来源");
    expect(state, r.snapshots[0].Fragment.Samplers[0].Tex == texture, "首个快照仍绑原贴图");
    sampler_uniform := F.uniform_buffer_get(*r.snapshots[0].Fragment.UniformBuffers[1]);
    expect(state, read_vec4(sampler_uniform, 0)[0] == 0.5, "首个快照仍是原参数");
    clear(*r);
    expect(state, debug_draw_line_count(*r.debug) == 0, "clear 清空调试线");
    expect(state, r.prepared.count == 0, "clear 清空准备缓存");
    free(texture);
    free(other_texture);
}

// 同一材质在 revision 与 Shader 不变时复用准备结果：不重新打包参数（直接改数值而不递增 revision 不会被发现，
// 这正是文档要求只经 material_set_number 等接口修改的原因）；revision、Shader 变化或 clear 后重新准备。
render3d_prepared_follows_revision :: (state: *Test_State) {
    device := fake_device();
    defer free(device);
    library: mat.Material_Library;
    library.device = device;
    r: Render3D;
    r.library = *library;
    defer dispose(*r);

    gpu := fake_gpu_material(device);
    defer release_fake_gpu_material(gpu);

    fields: [2] sh.Field = .[
   sh.Field.{ id = "hue", kind = .Scalar, instance = true, maximum = 1 },
   sh.Field.{ id = "gain", kind = .Scalar, maximum = 1 },
   ];
    schemas: [1] sh.Schema;
    schemas[0] = sh.Schema.{ name = "Body", fields = array_view(fields, 0, 2) };
    passes: [1] sh.Pass_Desc;
    passes[0] = sh.Pass_Desc.{ id = "body", params = "Body", draw = .Model };
    shader := mat.Material_Shader.{ desc = sh.Shader_Desc.{ instanced = true, passes = array_view(passes, 0, 1) },
    schemas = array_view(schemas, 0, 1) };
    values: [2] sh.Value;
    values[0] = sh.Value.{ number = .[0.2, 0, 0, 0] };
    values[1] = sh.Value.{ number = .[0.5, 0, 0, 0] };
    bindings: [1] mat.Material_Binding;
    bindings[0] = mat.Material_Binding.{ schema = schemas[0], values = array_view(values, 0, 2), material = gpu };
    m := mat.Material.{ owner = *library, shader = *shader, bindings = array_view(bindings, 0, 1) };

    mesh := fake_mesh(device, DA.DASSET_VERTEX_STRIDE_STATIC);
    defer release_fake_mesh(mesh);

    for i: 0..2 {
        expectf(state, model(*r, mesh, *m, W.MATRIX4_IDENTITY) == mat.Draw_Error.None, "记录 %", i);
    }
    expect(state, r.sources.count == 1, "同一来源");
    expect(state, r.tables.count == 1, "只准备一次");
    values[1].number[0] = 0.9; // 绕过接口直接改：沿用缓存
    expect(state, model(*r, mesh, *m, W.MATRIX4_IDENTITY) == mat.Draw_Error.None, "未递增 revision");
    expect(state, r.sources.count == 1, "不带 revision 的改动不被发现");
    m.revision += 1; // 经接口修改后重新准备，新参数进入新快照
    expect(state, model(*r, mesh, *m, W.MATRIX4_IDENTITY) == mat.Draw_Error.None, "递增 revision");
    expect(state, r.sources.count == 2, "新参数新建来源");
    second := F.uniform_buffer_get(*r.snapshots[1].Fragment.UniformBuffers[1]);
    expect(state, read_vec4(second, 0)[0] == 0.9, "新快照是新参数");
    values[1].number[0] = 0.5;
    m.revision += 1; // 改回原值：重新准备时按内容找到已有快照
    expect(state, model(*r, mesh, *m, W.MATRIX4_IDENTITY) == mat.Draw_Error.None, "改回原值");
    expect(state, r.sources.count == 2, "按内容复用已有快照");
    expect(state, r.records[r.records.count - 1].source == 0, "复用第一个来源");
    other := shader; // Shader 指针变化（reload 换了 Shader）也重新准备
    m.shader = *other;
    expect(state, model(*r, mesh, *m, W.MATRIX4_IDENTITY) == mat.Draw_Error.None, "换 Shader");
    expect(state, r.sources.count == 3, "新 Shader 新建来源");
    clear(*r);
    expect(state, model(*r, mesh, *m, W.MATRIX4_IDENTITY) == mat.Draw_Error.None, "clear 后重新记录");
    expect(state, r.sources.count == 1, "clear 后重新准备");
    expect(state, r.tables.count == 1, "表也重建");
}

// 绘制入口的错误码：都在提交 Draw 之前返回，不需要真实 GPU。
render3d_reports_errors_before_gpu :: (state: *Test_State) {
    device := fake_device();
    defer free(device);
    library: mat.Material_Library;
    library.device = device;
    passes: [1] sh.Pass_Desc;
    passes[0] = sh.Pass_Desc.{ draw = .Model };
    shader := mat.Material_Shader.{ desc = sh.Shader_Desc.{ instanced = true, passes = array_view(passes, 0, 1) } };
    material := mat.Material.{ owner = *library, shader = *shader };
    r: Render3D;
    r.library = *library;
    defer dispose(*r);
    expect(state, model(*r, null, null, W.MATRIX4_IDENTITY) == mat.Draw_Error.Missing_Material, "没有材质");
    expect(state, model(*r, null, *material, W.MATRIX4_IDENTITY) == mat.Draw_Error.Missing_Mesh, "没有网格");
    mesh := fake_mesh(device, DA.DASSET_VERTEX_STRIDE_STATIC);
    defer release_fake_mesh(mesh);
    expectf(state, buffer(*r, mesh, *material, null, 1) == mat.Draw_Error.Instance_Buffer_Required,
    "缓冲为 null");
    empty_buffer: Model_Buffer;
    expectf(state, buffer(*r, mesh, *material, *empty_buffer, 1) == mat.Draw_Error.Instance_Buffer_Required,
    "未创建的缓冲");
    // 静态入口仍拒绝蒙皮网格，必须显式提供 Skinned 材质和 palette。
    skinned := fake_mesh(device, DA.DASSET_VERTEX_STRIDE_SKIN);
    defer release_fake_mesh(skinned);
    expectf(state, model(*r, skinned, *material, W.MATRIX4_IDENTITY) == mat.Draw_Error.Unsupported_Mesh,
    "静态入口拒绝蒙皮网格");
    expectf(state, buffer(*r, skinned, *material, null, 1) == mat.Draw_Error.Unsupported_Mesh,
    "缓冲入口同样拒绝");
}

render3d_skin_palette_snapshot_and_validation :: (state: *Test_State) {
    device := fake_device();
    defer free(device);
    library: mat.Material_Library;
    library.device = device;
    r: Render3D;
    r.library = *library;
    defer dispose(*r);

    gpu := fake_gpu_material(device);
    defer release_fake_gpu_material(gpu);

    passes: [2] sh.Pass_Desc;
    passes[0] = sh.Pass_Desc.{ id = "body", params = "Body", draw = .Model };
    passes[1] = sh.Pass_Desc.{ id = "shadow", params = "Body", draw = .Model };
    shader := mat.Material_Shader.{ desc = sh.Shader_Desc.{ skinned = true, passes = array_view(passes, 0, 2) } };
    bindings: [1] mat.Material_Binding;
    bindings[0] = mat.Material_Binding.{ schema = sh.Schema.{ name = "Body" }, material = gpu };
    m := mat.Material.{ owner = *library, shader = *shader, bindings = array_view(bindings, 0, 1) };

    mesh := fake_mesh(device, DA.DASSET_VERTEX_STRIDE_SKIN);
    defer release_fake_mesh(mesh);
    palette: [MAX_JOINTS + 1] W.Matrix4;
    for *joint, i: palette joint.* = W.matrix4_translation(cast(float32) i, 0, 0);
    expectf(state, skinned_model(*r, mesh, *m, W.MATRIX4_IDENTITY, .[]) ==
    mat.Draw_Error.Invalid_Joint_Palette, "空 palette 拒绝");
    expectf(state, skinned_model(*r, mesh, *m, W.MATRIX4_IDENTITY,
    array_view(palette, 0, MAX_JOINTS + 1)) ==
    mat.Draw_Error.Invalid_Joint_Palette, "超过 MAX_JOINTS 拒绝");
    shader.desc.skinned = false;
    expectf(state, skinned_model(*r, mesh, *m, W.MATRIX4_IDENTITY, array_view(palette, 0, 1)) ==
    mat.Draw_Error.Skin_Mismatch, "非蒙皮 Shader 拒绝 palette");
    shader.desc.skinned = true;
    shader.desc.instanced = true;
    expectf(state, skinned_model(*r, mesh, *m, W.MATRIX4_IDENTITY, array_view(palette, 0, 1)) ==
    mat.Draw_Error.Skin_Mismatch, "蒙皮实例化不支持");
    shader.desc.instanced = false;
    expect(state, r.records.count == 0, "失败不留记录");
    expect(state, r.joints.count == 0, "失败不留关节");
    for i: 0..1 {
        expectf(state, skinned_model(*r, mesh, *m, W.MATRIX4_IDENTITY,
        array_view(palette, 0, MAX_JOINTS)) == mat.Draw_Error.None,
        "第 % 次蒙皮记录", i);
        palette[64] = W.matrix4_translation(300 + cast(float32) i, 0, 0);
    }
    expect(state, r.joints.count == 2 * MAX_JOINTS, "关节按记录累加");
    expect(state, W.matrix4_equal(r.joints[64], W.matrix4_translation(64, 0, 0)), "第一次的 64 号关节");
    expectf(state, W.matrix4_equal(r.joints[MAX_JOINTS + 64], W.matrix4_translation(300, 0, 0)),
    "第二次的 64 号关节");
    expect(state, r.records[1].joint_start == MAX_JOINTS, "第二条记录的关节起点");
    expect(state, r.records[0].joint_count == MAX_JOINTS, "第一条记录的关节数");
    view := View.{ view_matrix = W.MATRIX4_IDENTITY, view_projection = W.MATRIX4_IDENTITY };
    expect(state, render3d_prepare(*r, view, "body") == mat.Draw_Error.None, "准备 body");
    counts := render3d_plan(*r);
    expect(state, r.batches.count == 2, "两条记录各自成批（多 Pass 蒙皮不合批）");
    expect(state, counts[0] == 0 && counts[1] == 0, "蒙皮不占实例缓冲");
    expect(state, render3d_prepare(*r, view, "shadow") == mat.Draw_Error.None, "准备 shadow");
    expect(state, r.queue.items.count == 2, "shadow 也画两条");
    clear(*r);
    expect(state, r.joints.count == 0, "clear 清空关节");
    expect(state, r.records.count == 0, "clear 清空记录");
}

joint_palette_split_boundary_and_overflow :: (state: *Test_State) {
    palette: [MAX_JOINTS + 1] W.Matrix4;
    for *joint, i: palette joint.* = W.matrix4_translation(cast(float32) i, 2, 3);
    a: [JOINT_PALETTE_BLOCK_SIZE] u8;
    b: [JOINT_PALETTE_BLOCK_SIZE] u8;
    expect(state, pack_joint_palette(a, b, array_view(palette, 0, MAX_JOINTS)), "127 个关节写两块");
    expect(state, floats4_eq(read_vec4(a, 63 * 64), palette[63].c0), "0 块 63 号");
    expect(state, floats4_eq(read_vec4(b, 0), palette[64].c0), "1 块 0 号");
    expect(state, floats4_eq(read_vec4(b, 63 * 64), palette[127].c0), "1 块 63 号");
    expect(state, !pack_joint_palette(a, b, array_view(palette, 0, MAX_JOINTS + 1)), "129 个关节拒绝");
    expectf(state, !pack_joint_palette(array_view(a, 0, 16), b, array_view(palette, 0, 1)),
    "0 块不足 4KB 拒绝");
}

// 每次 submit 先排好全部自动实例化数据：同网格同快照合批，同一批的各 Pass 连续存放，按槽数分段，
// 绘制时只按偏移取段，不再逐批上传。
render3d_plan_packs_every_batch_once :: (state: *Test_State) {
    device := fake_device();
    defer free(device);
    library: mat.Material_Library;
    library.device = device;
    r: Render3D;
    r.library = *library;
    defer dispose(*r);

    gpu := fake_gpu_material(device);
    defer release_fake_gpu_material(gpu);

    fields: [1] sh.Field;
    fields[0] = sh.Field.{ id = "hue", kind = .Scalar, instance = true, maximum = 1 };
    schemas: [1] sh.Schema;
    schemas[0] = sh.Schema.{ name = "Body", fields = array_view(fields, 0, 1) };
    pass_values: [1] sh.Pass_Value;
    pass_values[0] = sh.Pass_Value.{ field = "hue", number = .[0.9, 0, 0, 0] };
    passes: [2] sh.Pass_Desc;
    passes[0] = sh.Pass_Desc.{ id = "body", params = "Body", draw = .Model };
    passes[1] = sh.Pass_Desc.{ id = "shadow", params = "Body", draw = .Model,
    values = array_view(pass_values, 0, 1) };
    shader := mat.Material_Shader.{ desc = sh.Shader_Desc.{ instanced = true, passes = array_view(passes, 0, 2) },
    schemas = array_view(schemas, 0, 1) };
    values: [1] sh.Value;
    values[0] = sh.Value.{ number = .[0.2, 0, 0, 0] };
    bindings: [1] mat.Material_Binding;
    bindings[0] = mat.Material_Binding.{ schema = schemas[0], values = array_view(values, 0, 1), material = gpu };
    m := mat.Material.{ owner = *library, shader = *shader, bindings = array_view(bindings, 0, 1) };

    plain_passes: [1] sh.Pass_Desc;
    plain_passes[0] = sh.Pass_Desc.{ id = "body", params = "Plain", draw = .Model };
    plain_shader := mat.Material_Shader.{ desc = sh.Shader_Desc.{ passes = array_view(plain_passes, 0, 1) } };
    plain_bindings: [1] mat.Material_Binding;
    plain_bindings[0] = mat.Material_Binding.{ schema = sh.Schema.{ name = "Plain" }, material = gpu };
    plain := mat.Material.{ owner = *library, shader = *plain_shader,
    bindings = array_view(plain_bindings, 0, 1) };

    mesh := fake_mesh(device, DA.DASSET_VERTEX_STRIDE_STATIC);
    defer release_fake_mesh(mesh);
    other_mesh := fake_mesh(device, DA.DASSET_VERTEX_STRIDE_STATIC);
    defer release_fake_mesh(other_mesh);

    items: [2] Model_Item = .[
   Model_Item.{ world = W.matrix4_translation(0, 0, -1), tint = .[1, 1, 1, 1] },
   Model_Item.{ world = W.matrix4_translation(0, 0, -2), tint = .[1, 1, 1, 1] },
   ];
    flat: [2][4] float32 = .[.[0.4, 0, 0, 0], .[0.6, 0, 0, 0]];
    expect(state, models(*r, mesh, *m, items, values = flat) == mat.Draw_Error.None, "两条实例记录");
    expectf(state, model(*r, other_mesh, *m, W.matrix4_translation(0, 0, -3)) == mat.Draw_Error.None,
    "另一网格");
    expectf(state, model(*r, mesh, *plain, W.matrix4_translation(0, 0, -0.5)) == mat.Draw_Error.None,
    "普通材质");
    view := View.{ view_projection = W.MATRIX4_IDENTITY, view_matrix = W.MATRIX4_IDENTITY };
    expect(state, render3d_prepare(*r, view, "") == mat.Draw_Error.None, "准备全部 Pass");
    // 普通材质组离得最近排在前面；实例组内前到后，换网格断批。
    counts := render3d_plan(*r);
    expect(state, r.batches.count == 3, "三段批次");
    expectf(state, r.batches[1].start == 1 && r.batches[1].end == 3 && r.batches[1].first == 0,
    "第二段覆盖两条网格记录，从实例 0 开始");
    expectf(state, r.batches[2].start == 3 && r.batches[2].end == 4 && r.batches[2].first == 4,
    "第三段是另一网格，从实例 4 开始");
    expect(state, counts[1] == 6, "(2 + 1) 个实例 × 2 个 Pass");
    expect(state, counts[0] == 0, "普通材质不占实例缓冲");
    bases := render3d_pack(*r, counts);
    stride := model_stride(1);
    expect(state, bases[1] == 0, "1 槽段从 0 开始");
    expect(state, r.upload.count == 6 * stride, "上传长度 6 × 步长");
    // 每个位置的 hue：body 用各自的值或材质默认值，shadow 用 Pass 固定值。
    hues: [6] float32 = .[0.4, 0.6, 0.9, 0.9, 0.2, 0.9];
    for hue, i: hues {
        expectf(state, read_vec4(r.upload, i * stride + MODEL_BASE_BYTES)[0] == hue,
        "第 % 个实例的 hue 是 %", i, hue);
    }
    expect(state, read_vec4(r.upload, 1 * stride + 32)[3] == -2, "第 2 个实例世界矩阵的 z");
    expect(state, read_vec4(r.upload, 4 * stride + 32)[3] == -3, "第 5 个实例世界矩阵的 z");
}

// 调试线默认只随画全部 Pass 的提交：分阶段的 shadow/body/outline 不重复叠加，需要时显式开启。
render3d_debug_lines_follow_pass_selection :: (state: *Test_State) {
    device := fake_device();
    defer free(device);
    library: mat.Material_Library;
    library.device = device;
    r: Render3D;
    expect(state, init(*r, *library) == "", "初始化成功");
    defer dispose(*r);
    line(*r, .[0, 0, 0], .[1, 0, 0], .[1, 1, 1, 1]);
    view := View.{ view_projection = W.MATRIX4_IDENTITY, view_matrix = W.MATRIX4_IDENTITY }; // 目标无效
    expect(state, submit(*r, view, "shadow") == mat.Draw_Error.None, "分阶段提交不画线，无事可做");
    expect(state, submit(*r, view) == mat.Draw_Error.Invalid_Target, "要画线才检查目标");
    view.draw_debug = true;
    view.has_draw_debug = true;
    expect(state, submit(*r, view, "shadow") == mat.Draw_Error.Invalid_Target, "显式开启后分阶段也检查目标");
    view.draw_debug = false;
    expect(state, submit(*r, view) == mat.Draw_Error.None, "显式关闭后不画线");
}

// 记录保存当时的 Shader 与槽数：之后 reload 换了 Shader（Pass 更少），已记录的快照仍按原布局准备，不越界。
render3d_records_survive_material_reload :: (state: *Test_State) {
    device := fake_device();
    defer free(device);
    library: mat.Material_Library;
    library.device = device;
    r: Render3D;
    r.library = *library;
    defer dispose(*r);

    gpu := fake_gpu_material(device);
    defer release_fake_gpu_material(gpu);

    two_passes: [2] sh.Pass_Desc;
    two_passes[0] = sh.Pass_Desc.{ id = "body", params = "A", draw = .Model };
    two_passes[1] = sh.Pass_Desc.{ id = "outline", params = "B", draw = .Model };
    two := mat.Material_Shader.{ desc = sh.Shader_Desc.{ passes = array_view(two_passes, 0, 2) } };
    one_passes: [1] sh.Pass_Desc;
    one_passes[0] = sh.Pass_Desc.{ id = "body", params = "C", draw = .Model };
    one := mat.Material_Shader.{ desc = sh.Shader_Desc.{ passes = array_view(one_passes, 0, 1) } };
    two_bindings: [2] mat.Material_Binding;
    two_bindings[0] = mat.Material_Binding.{ schema = sh.Schema.{ name = "A" }, material = gpu };
    two_bindings[1] = mat.Material_Binding.{ schema = sh.Schema.{ name = "B" }, material = gpu };
    m := mat.Material.{ owner = *library, shader = *two, bindings = array_view(two_bindings, 0, 2) };

    mesh := fake_mesh(device, DA.DASSET_VERTEX_STRIDE_STATIC);
    defer release_fake_mesh(mesh);
    expect(state, model(*r, mesh, *m, W.MATRIX4_IDENTITY) == mat.Draw_Error.None, "两条 Pass 的记录");
    // 模拟 material_reload：同一指针换成单 Pass Shader 和新的参数组。
    m.shader = *one;
    one_bindings: [1] mat.Material_Binding;
    one_bindings[0] = mat.Material_Binding.{ schema = sh.Schema.{ name = "C" }, material = gpu };
    m.bindings = array_view(one_bindings, 0, 1);
    m.revision += 1;
    view := View.{ view_projection = W.MATRIX4_IDENTITY, view_matrix = W.MATRIX4_IDENTITY };
    expect(state, render3d_prepare(*r, view, "outline") == mat.Draw_Error.None, "旧记录的 outline 仍可准备");
    expect(state, r.queue.items.count == 1, "旧记录仍在队列里");
    expect(state, r.sources[0].count == 1, "旧来源按当时的 selection 选出一个 Pass");
    expect(state, model(*r, mesh, *m, W.MATRIX4_IDENTITY) == mat.Draw_Error.None, "新 Shader 的记录");
    expect(state, r.sources.count == 2, "新 Shader 的记录不复用旧快照");
}

// CameraPosition 由视矩阵求逆得到，顶点 b0 与片元 b0 写同一个值。
camera_position_and_material_blocks :: (state: *Test_State) {
    camera: W.Camera3D;
    W.camera3d_init(*camera, 64, 64);
    W.camera3d_set_position(*camera, W.Vec3.{ 1, 2, 3 });
    W.camera3d_set_target(*camera, W.Vec3.{ 0, 0, 0 });
    position := camera_position(W.camera3d_view(*camera));
    expected: [4] float32 = .[1, 2, 3, 1];
    for value, i: expected {
        expectf(state, JM.abs(position[i] - value) < 1e-4, "camera[%] = %", i, position[i]);
    }
    zero := camera_position(W.Matrix4.{});
    expect(state, floats4_eq(zero, .[0, 0, 0, 1]), "不可逆时退回原点");

    vertex: [MATERIAL_VERTEX_BLOCK_SIZE] u8;
    frame: [MATERIAL_FRAME_BLOCK_SIZE] u8;
    target := fake_target(320, 240);
    defer free(target);
    view := View.{ time = 2, delta_time = 0.5, frame = 7 };
    view.target = F.drawable_target_target(target);
    pack_material_blocks(vertex, frame, W.MATRIX4_IDENTITY, W.MATRIX4_IDENTITY, view,
    .[1, 2, 3, 1], .[0.25, 0.75], .[1, 0.5, 0, 1]);
    expectf(state, floats4_eq(read_vec4(vertex, VERTEX_MATRIX_BLOCK_SIZE), .[2, 0.5, 7, 0]),
    "顶点 b0 的 Clock");
    expectf(state, floats4_eq(read_vec4(vertex, VERTEX_MATRIX_BLOCK_SIZE + 16), .[1, 2, 3, 1]),
    "顶点 b0 的 CameraPosition");
    expect(state, floats4_eq(read_vec4(frame, 16), .[0.25, 0.75, 320, 240]), "片元 b0 的 Pointer");
    expect(state, floats4_eq(read_vec4(frame, 32), .[1, 0.5, 0, 1]), "片元 b0 的 Tint");
    expect(state, floats4_eq(read_vec4(frame, 48), .[1, 2, 3, 1]), "片元 b0 的 CameraPosition");
}

// 3D 材质块只在 pack_material_blocks 写：顶点 WVP、World、Clock、CameraPosition，片元 Clock、Pointer、Tint、CameraPosition。
material_blocks_follow_model_include_layout :: (state: *Test_State) {
    vertex: [MATERIAL_VERTEX_BLOCK_SIZE] u8;
    frame: [MATERIAL_FRAME_BLOCK_SIZE] u8;
    wvp := W.matrix4_translation(1, 2, 3);
    target := fake_target(640, 360);
    defer free(target);
    view := View.{ time = 1.5, delta_time = 0.25, frame = 7 };
    view.target = F.drawable_target_target(target);
    pack_material_blocks(vertex, frame, wvp, W.MATRIX4_IDENTITY, view, .[4, 5, 6, 1], .[0.25, 0.75],
    .[0.5, 0.5, 0.5, 1]);
    expectf(state, floats4_eq(read_vec4(vertex, VERTEX_MATRIX_BLOCK_SIZE), .[1.5, 0.25, 7, 0]),
    "顶点 Clock");
    expectf(state, floats4_eq(read_vec4(vertex, VERTEX_MATRIX_BLOCK_SIZE + 16), .[4, 5, 6, 1]),
    "顶点 CameraPosition");
    expect(state, floats4_eq(read_vec4(frame, 0), .[1.5, 0.25, 7, 0]), "片元 Clock");
    expect(state, floats4_eq(read_vec4(frame, 16), .[0.25, 0.75, 640, 360]), "片元 Pointer");
    expect(state, floats4_eq(read_vec4(frame, 32), .[0.5, 0.5, 0.5, 1]), "片元 Tint");
    expect(state, floats4_eq(read_vec4(frame, 48), .[4, 5, 6, 1]), "片元 CameraPosition");
    // WVP 按 c0..c3 写入（与 matrix4_translation 的布局一致）
    expect(state, W.matrix4_equal(read_column(vertex, 0), wvp), "顶点 WVP");
    expect(state, W.matrix4_equal(read_column(vertex, 64), W.MATRIX4_IDENTITY), "顶点 World");
}

// 仿射矩阵的包围盒走中心/半长快速路径，结果与 8 个角点的外包盒一致；非仿射矩阵仍逐角点变换。
world_bounds_affine_matches_corners :: (state: *Test_State) {
    boxes: [3] DA.Dasset_Bounds = .[
    DA.Dasset_Bounds.{ min = .[-1, -1, -1], max = .[1, 1, 1] },
    DA.Dasset_Bounds.{ min = .[0.2, -3, 4], max = .[2.5, 1, 9] },
    DA.Dasset_Bounds.{ min = .[1, 1, 1], max = .[-1, -2, -3] }, // 反向的盒
    ];
    for i: 0..39 {
        a := cast(float32) i * 0.37;
        q: [4] float32 = .[JM.sin(a) * 0.6, JM.cos(a * 1.3) * 0.5, JM.sin(a * 0.7) * 0.4, JM.cos(a)];
        length := JM.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
        for j: 0..3 q[j] = q[j] / length;
        scale := W.matrix4_scaling(0.5 + cast(float32) (i % 3), 2 - cast(float32) (i % 2),
        0.25 + cast(float32) (i % 5));
        m := W.matrix4_multiply(
        W.matrix4_multiply(scale, W.matrix4_from_quaternion(q)),
        W.matrix4_translation(cast(float32) i - 20, cast(float32) (i % 7), -cast(float32) i * 0.5));
        for box: boxes {
            got, ok := render3d_world_bounds(box, m);
            expected := corners_bounds(box, m);
            expectf(state, ok, "矩阵 % 有效", i);
            for axis: 0..2 {
                expectf(state, JM.abs(got.min[axis] - expected.min[axis]) < 1e-4 &&
                JM.abs(got.max[axis] - expected.max[axis]) < 1e-4,
                "矩阵 % 轴 % 与角点一致", i, axis);
            }
        }
    }
    // 非仿射（透视）矩阵仍按角点变换，结果不变。
    perspective := W.matrix4_multiply(W.matrix4_translation(0, 0, -10),
    W.matrix4_perspective_fov(1, 1.5, 0.1, 100));
    got, ok := render3d_world_bounds(boxes[0], perspective);
    expected := corners_bounds(boxes[0], perspective);
    expect(state, ok && bounds_equal(got, expected), "透视矩阵按角点变换");
    nan := JM.FLOAT32_NAN;
    _, finite := render3d_world_bounds(DA.Dasset_Bounds.{ min = .[nan, 0, 0], max = .[1, 1, 1] },
    W.MATRIX4_IDENTITY);
    expect(state, !finite, "非有限的盒保守保留（返回 false）");
}

// olib: 测试里的嵌套 proc corners_bounds —— 逐角点变换后取外包盒。
corners_bounds :: (bounds: DA.Dasset_Bounds, m: W.Matrix4) -> (result: DA.Dasset_Bounds) {
    corners := aabb_corners(bounds);
    for corner, i: corners {
        p, _ := W.matrix4_transform_point(m, W.Vec3.{ corner[0], corner[1], corner[2] });
        values: [3] float32 = .[p.x, p.y, p.z];
        if i == 0 {
            result.min = values;
            result.max = values;
        } else {
            for axis: 0..2 {
                result.min[axis] = min(result.min[axis], values[axis]);
                result.max[axis] = max(result.max[axis], values[axis]);
            }
        }
    }
    return result;
}

bounds_equal :: (a: DA.Dasset_Bounds, b: DA.Dasset_Bounds) -> bool {
    return floats4_eq(.[a.min[0], a.min[1], a.min[2], 0], .[b.min[0], b.min[1], b.min[2], 0]) &&
    floats4_eq(.[a.max[0], a.max[1], a.max[2], 0], .[b.max[0], b.max[1], b.max[2], 0]);
}
//@endregion

// Loop scopes adapted.
