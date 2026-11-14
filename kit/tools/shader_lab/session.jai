// shader_lab:session —— 会话拥有预览参数、相机、GPU 资源与各组独立的热重载会话。
// HLSL 由外部编辑器修改/保存；这里的参数仅供预览，不写回源码，无文档撤销历史。
// 输入由宿主的 ImGui 分配；右键轨道旋转只在预览图上开始，捕获持续到松开或 cancel。
// 一比一移植自 olib kit/tools/shader_lab/session.odin；Jai 差异见 module.jai 的全局六条，
// 本文件内的局部差异：
//   | olib (Odin)                                   | JaiLib (Jai)                                        |
//   | --------------------------------------------- | --------------------------------------------------- |
//   | `icons: imgui_foster.Icons`                    | Icon_Set（内置 Sprite_Atlas）              |
//   | `foster.Mesh` / `foster.Texture`（值）          | *F.Mesh / *F.Texture（堆对象，.handle != 0 为就绪）    |
//   | `meshes: [3]foster.Mesh`                       | [3] *F.Mesh（mesh_create 出来的）                     |
//   | `retired_textures: [dynamic]^foster.Texture`   | [..] *F.Texture + array_add / array_free             |
//   | `widgets: map[u64]Widget_Rect`                 | HASH.Table(u64, Widget_Rect)                        |
//   | `w.mode = i == 1 ? 2 : 0`                      | 先赋默认值再 if 改写（Jai 没有三元）                    |
//   | `foster.MeshInitWithFormat`                    | F.mesh_create(device, format, .THIRTY_TWO, name)     |
//   | `foster.MeshSetVerticesTyped(T, &m, v)`        | F.mesh_set_vertices(m, v)                            |
//   | `foster.ImageMake / ImageSetPixel / ImageDispose` | F.image_create / F.image_set_pixel / F.image_destroy |
//   | `foster.TextureFromImage(dev, &img, name)`     | F.texture_create_from_colors(dev, w, h, img.Pixels)  |
//   | `foster.VertexFormatDispose(&f)`               | 无需释放（jfoster 的 Vertex_Format 是纯值）             |
//   | `#load` 模板在 files.jai                         | 同样在 files.jai（编译期内嵌字符串）                    |
// 导入由 module.jai 提供（#load 的文件共享这一层的名字）。

//@region 日志与类型桥接
// olib: `log.info(fmt, …)` / `log.error(fmt, …)`。jfoster 的 log_info / log_error 只接受**已格式化**的
// string，并且自己补一个换行（log_append 追加 "\n"，print 用 "%\n"），所以这里用 tprint 做格式化
// （temp 分配器，调用作用域结束自动回收），格式串里不再写尾部 "\n"。
sl_log_info  :: (format: string, args: ..Any) { F.log_info(tprint(format, ..args)); }
sl_log_error :: (format: string, args: ..Any) { F.log_error(tprint(format, ..args)); }

// jacket 的 File.read_entire_file / write_entire_file 走 `string`（count/data），而 kit 的
// shader.resource_decode / resource_encode 走 `[] u8`。这里做零拷贝互转，所有权仍归调用方。
sl_bytes_view  :: (s: string) -> [] u8 { return [] u8.{ s.count, s.data }; }
sl_string_view :: (b: [] u8) -> string { return string.{ b.count, cast(*u8) b.data }; }

// olib: math.round（就近取整，结果仍是浮点）。jacket 的 Math 只有 floor / ceil。
sl_round :: (x: float32) -> float32 { return JM.floor(x + 0.5); }

//@region 总类型

Session :: struct {
    device: *F.Graphics_Device;
    // 2D 材质预览：Render2D 借用这个库的设备与默认材质；sprite_mesh 是 Batcher_Vertex 布局的空网格，
    // 供管线探测。
    library: mat.Material_Library;
    render: r2d.Render2D;
    // 材质 Shader 的预览与游戏一样用 Render2D / Render3D 记录后提交，材质借用 bank 的 GPU 绑定
    // （见 material_preview.jai）。
    preview_sprites: r2d.Render2D;
    preview_models: r3d.Render3D;
    sprite_mesh: *F.Mesh;
    // instanced 模型的管线探测按 [Instance] 字段数各用一个实例缓冲（只用格式），首次需要时创建。
    probe_instances: [sh.MAX_INSTANCE_FIELDS + 1] r3d.Model_Buffer;
    icons: Icon_Set; // JaiLib 内置图标图集
    delta_time: float32;
    source_root: string;
    // olib 的 `using bank`：这里显式写成字段访问（Jai 没有 using 字段），
    // 所有 `s.program_count` / `s.materials` / `s.shaders` 都等价于 `s.bank.program_count` ……，
    // 为了保持 olib 的写法，本包在 Session 上放了转发用的访问器过程（见下面的 sl_* 系列）。
    bank: *Parameter_Bank;
    pending_bank: *Parameter_Bank;
    bank_error: string;
    selected: int;
    // selected_shader=-1 表示工作区无 Shader；inspect_pass 只决定编辑哪个 Pass。
    selected_shader, inspect_pass: int;
    preview_pass: int; // -1 始终看最终效果；与编辑中的 inspect_pass 分开。
    shader_menu, preview_settings: bool;
    shader_menu_shown: bool; // 上一次 draw 结束时 Shader 菜单浮层是否打开
    workspace: int; // 0: 2D，1: 3D。
    workspace_empty: bool;
    workspaces: [2] Workspace_State;
    tick_serial: u64;
    step_requested: bool;
    parameter_watch: dev.Parameter_Watch;
    fonts_dirty: bool;
    missing_glyphs: int; // 最近一次标签校验中 ImGui 字体缺的字数
    color_picker: Color_Picker;
    meshes: [3] *F.Mesh;
    texture: *F.Texture;
    sprite_texture: *F.Texture; // Sprite 预览帧采用预乘 Alpha，旧图像预览保持原输入。
    drawing: bool; // draw 进行中：本帧 ImGui 绘制列表可能已引用旧纹理
    retired_textures: [..] *F.Texture;
    widgets: HASH.Table(u64, Widget_Rect); // 最近一次 draw 登记的控件矩形，见 widget_rect
    dropped_files: [] string; // 本次 draw 借用的拖入文件
    drop_position: [2] float32;
    camera: W.Camera3D;
    mode: int;

    yaw, pitch, distance, clock: float32;
    paused, orbiting: bool;
    viewport: F.Rect; // 预览图在最终输出中的像素区域，决定 Pass 目标尺寸与鼠标 UV
    pointer: JM.Vector2; // 鼠标的最终输出像素坐标
    initialized: bool;
    render_serial: int;
    file_dialogs: bool;
    open_file: (path: string) -> bool;
    request: File_Request;
    request_serial, schema_generation: u64;
    preview_hooks: Preview_Hooks;
    custom_preview: bool;
    pending_shader: string; // new_shader 写出的 Shader 名，编译进 bank 后自动选中
    texture_poll: float32;
}

Vertex2D :: struct {
    position: [2] float32;
    uv: [2] float32;
}

// olib 的 `using bank: ^Parameter_Bank` 在 Jai 里没有等价物：这些访问器保持 `s.program_count` 式的
// 读法在移植代码里可用（同名过程调用），语义就是 bank 字段的转发。
sl_bank_program_count :: (s: *Session) -> int { if s.bank == null return 0; return s.bank.program_count; }
//@endregion

//@region 生命周期

// Config 的路径被复制；device 借用至 dispose。Session 不得搬动。宿主的 ImGui 后端
// 可在 init 之前或之后初始化，draw 时必须已就绪。
init :: (s: *Session, device: *F.Graphics_Device, config: Config) -> bool {
    if s.initialized || device == null || config.source_root == "" return false;
    if !icons_init(*s.icons, device) return false;
    s.device = device;
    s.bank = New(Parameter_Bank);
    s.selected_shader = -1;
    s.inspect_pass = -1;
    s.preview_pass = -1;
    s.viewport = F.Rect.{ 0, 0, 960, 640 }; // 预览窗口第一次测量前的目标尺寸
    s.source_root = copy_string(config.source_root);
    s.distance = 4;
    s.yaw = 0.4;
    s.pitch = 0.25;
    s.paused = config.paused;
    s.file_dialogs = config.file_dialogs;
    s.open_file = config.open_file;
    s.preview_hooks = config.preview;
    s.custom_preview = config.preview.record != null || config.preview.mesh != null;
    for *w, i: s.workspaces {
        w.mode = 0;
        if i == 1 w.mode = 2;
        w.paused = s.paused;
        w.custom_preview = s.custom_preview;
        w.yaw = s.yaw; w.pitch = s.pitch; w.distance = s.distance;
    }
    s.clock = 1;
    dev.parameters_init(*s.parameter_watch, s.source_root);
    s.library = mat.Material_Library.{ device = device };
    reason := r2d.init(*s.render, *s.library);
    if reason != "" {
        sl_log_error("Shader Lab: %", reason);
        return false;
    }
    reason = r2d.init(*s.preview_sprites, *s.library);
    if reason != "" {
        sl_log_error("Shader Lab: %", reason);
        return false;
    }
    reason = r3d.init(*s.preview_models, *s.library);
    if reason != "" {
        sl_log_error("Shader Lab: %", reason);
        return false;
    }
    s.sprite_mesh = F.mesh_create(device, F.Batcher_Vertex_Format, .THIRTY_TWO, "sprite probe");
    quad_elements: [2] F.Vertex_Format_Element;
    quad_elements[0] = F.Vertex_Format_Element.{ Index = 0, Type = .FLOAT2, Normalized = false };
    quad_elements[1] = F.Vertex_Format_Element.{ Index = 1, Type = .FLOAT2, Normalized = false };
    format := F.vertex_format_make(quad_elements, size_of(Vertex2D));
    s.meshes[0] = F.mesh_create(device, format, .THIRTY_TWO, "preview quad");
    vertices: [4] Vertex2D;
    vertices[0] = .{ position = .[-1, 1],  uv = .[0, 0] };
    vertices[1] = .{ position = .[1, 1],   uv = .[1, 0] };
    vertices[2] = .{ position = .[1, -1],  uv = .[1, 1] };
    vertices[3] = .{ position = .[-1, -1], uv = .[0, 1] };
    indices: [6] u32;
    indices[0] = 0; indices[1] = 1; indices[2] = 2;
    indices[3] = 0; indices[4] = 2; indices[5] = 3;
    F.mesh_set_vertices(s.meshes[0], vertices);
    F.mesh_set_indices(s.meshes[0], indices);
    sphere := make_sphere(1.15, 48, 64, DA.DASSET_MATERIAL_DEFAULT);
    defer primitive_dispose(*sphere);
    // Keep source primitive CCW; only the preview upload uses Foster clockwise winding.
    for triangle: 0..sphere.indices.count / 3 - 1 {
        at := triangle * 3;
        saved := sphere.indices[at + 1];
        sphere.indices[at + 1] = sphere.indices[at + 2];
        sphere.indices[at + 2] = saved;
    }
    s.meshes[1] = New(F.Mesh);
    assert(r3d.mesh_upload(s.meshes[1], device, *sphere, "preview sphere"));
    cube := make_cube(1.8, DA.DASSET_MATERIAL_DEFAULT);
    defer primitive_dispose(*cube);
    // Keep source primitive CCW; only the preview upload uses Foster clockwise winding.
    for triangle: 0..cube.indices.count / 3 - 1 {
        at := triangle * 3;
        saved := cube.indices[at + 1];
        cube.indices[at + 1] = cube.indices[at + 2];
        cube.indices[at + 2] = saved;
    }
    s.meshes[2] = New(F.Mesh);
    assert(r3d.mesh_upload(s.meshes[2], device, *cube, "preview cube"));
    image := F.image_create(512, 512);
    defer F.image_destroy(*image);
    for y: 0..511 {
        for x: 0..511 {
            color: F.Color;
            if (x / 64 + y / 64) % 2 == 0 color = F.Color.{ 240, 245, 255, 255 };
            else                        color = F.Color.{ 100, 120, 155, 255 };
            dx := cast(float32) x - 255.5;
            dy := cast(float32) y - 255.5;
            color.a = cast(u8) (clamp(240 - JM.sqrt(dx * dx + dy * dy), 0, 1) * 255);
            F.image_set_pixel(*image, cast(s32) x, cast(s32) y, color);
        }
    }
    s.texture = F.texture_create_from_colors(device, 512, 512, image.Data, name = "checker sprite");
    F.image_premultiply(*image);
    s.sprite_texture = F.texture_create_from_colors(device, 512, 512, image.Data,
                                                    name = "premultiplied sprite frame");
    W.camera3d_init(*s.camera, 960, 640);
    s.initialized = true;
    sl_log_info("Shader Lab: save .oshader/HLSLI to reload. Sources: %", s.source_root);
    return true;
}

dispose :: (s: *Session) {
    if s.device == null return;
    color_picker_dispose(s);
    file_request_clear(s);
    bank_dispose(s.pending_bank);
    bank_dispose(s.bank);
    if s.bank_error.data != null free(s.bank_error.data);
    dev.parameters_dispose(*s.parameter_watch);
    for mesh: s.meshes {
        if mesh != null F.mesh_dispose(mesh);
    }
    r2d.dispose(*s.render);
    r2d.dispose(*s.preview_sprites);
    r3d.dispose(*s.preview_models);
    if s.sprite_mesh != null F.mesh_dispose(s.sprite_mesh);
    for *buf: s.probe_instances {
        r3d.model_buffer_dispose(buf);
    }
    mat.material_library_dispose(*s.library);
    icons_dispose(*s.icons);
    if s.texture != null F.texture_dispose(s.texture);
    if s.sprite_texture != null F.texture_dispose(s.sprite_texture);
    texture_retire_flush(s);
    if s.retired_textures.data != null array_free(s.retired_textures);
    deinit(*s.widgets);
    if s.source_root.data != null free(s.source_root.data);
    if s.pending_shader.data != null free(s.pending_shader.data);
    for *workspace: s.workspaces {
        workspace_dispose(workspace);
    }
    s.* = Session.{};
}
//@endregion

//@region 输入与面板

// 每帧调用；只推进时间与后台编译，不读取窗口输入，也不退出宿主。
update :: (s: *Session, delta_time: float32) {
    if !s.initialized return;
    s.delta_time = max(cast(float32) 0, delta_time);
    s.tick_serial += 1;
    if !s.paused s.clock += s.delta_time;
    parameters_update(s);
    if s.pending_bank != null {
        for *program: array_view(s.pending_bank.programs, 0, s.pending_bank.program_count) {
            dev.update(program, cast(float64) s.delta_time);
        }
    }
    textures_update(s);
    templates_update(s);

    if s.bank != null {
        for *program, i: array_view(s.bank.programs, 0, s.bank.program_count) {
            if !s.bank.parameters[i].available continue;
            if program.status != s.bank.last_status[i] {
                sl_log_info("%: % (revision %)", s.bank.parameters[i].name, program.status, program.revision);
                if program.status == .Error && program.diagnostic != "" sl_log_error(program.diagnostic);
                s.bank.last_status[i] = program.status;
            }
        }
    }
}

// 停用/隐藏面板、窗口离焦时调用；工具内按 Escape 也会调用。调色板恢复原值，轨道旋转结束。
cancel :: (s: *Session) {
    if !s.initialized return;
    color_picker_close(s, false);
    s.orbiting = false;
}
//@endregion

//@region 宿主约定

// 宿主负责窗口、ImGui 上下文与字体、输入路由和 Dock 布局；工具只持有独立的预览会话，
// 每帧在宿主的 ImGui 帧里提交自己的窗口。

// 工具提交的两个窗口名，宿主可据此停靠；同一 ImGui 上下文只放一个 Session。
CONTROL_WINDOW :: "着色器实验室###Shader Lab";
PREVIEW_WINDOW :: "着色器预览###Shader 预览";

Config :: struct {
    // source_root 递归发现 .oshader。
    source_root: string;
    paused: bool;
    // 宿主通过 file_request / file_reply 接入自己的文件对话框。
    file_dialogs: bool;
    // 可选：用系统默认程序打开源码文件（参数组里的“编辑 <文件>”按钮）；null 时只显示文件名。
    // path 是绝对路径。
    open_file: (path: string) -> bool;
    preview: Preview_Hooks;
}

// 自定义预览的这一次绘制：要画的 Pass、它的参数组与预览维度、时间和目标尺寸。
Preview_Frame :: struct {
    pass: string; // 本次要画的 Pass ID；2D 记录时作为 pass_id 传入
    group, dimension: string;
    time, delta_time: float32;
    frame_index: u64;
    width, height: int;
}

Preview_Hooks :: struct {
    user_data: *void;
    // 材质 Shader 的自定义预览：用游戏同一套 API 记录要画的东西，Shader Lab 负责提交。
    // 对每个要画的 Pass 调用一次；2D 记录时把 frame.pass 作为 pass_id 传入，3D 只管记录
    // （Shader Lab 按该 Pass 提交）。sprites / models 按 Shader 维度只给一个，另一个为 null。
    // 返回 false 使用内置几何。
    record: (user_data: *void, frame: Preview_Frame, material: *mat.Material,
             sprites: *r2d.Render2D, models: *r3d.Render3D) -> bool;
    // 可选：3D Preview_Model Pass 在“使用宿主模型”时绘制的网格，宿主拥有并保持地址稳定至 dispose。
    // 顶点格式须与 r3d.mesh_upload 一致；热重载的管线探测仍用内置几何。null 时用球体/立方体。
    mesh: *F.Mesh;
}
//@endregion

//@region 工作区书签

// 工作区书签：2D/3D 各自记住选中的 Shader、Pass、载体和相机。只拥有预览状态，
// 不改写 .oshader 或材质预设。

Workspace_State :: struct {
    shader, pass, preview: string; // 拥有的稳定 ID，跨候选包提交仍有效。
    paused, custom_preview, preview_settings: bool;
    mode: int;
    yaw, pitch, distance: float32;
}

workspace_dispose :: (w: *Workspace_State) {
    if w.shader.data != null free(w.shader.data);
    if w.pass.data != null free(w.pass.data);
    if w.preview.data != null free(w.preview.data);
    w.* = Workspace_State.{};
}

workspace_save :: (s: *Session) {
    if s.bank == null || s.bank.program_count == 0 || s.workspace_empty return;
    w := *s.workspaces[s.workspace];
    workspace_dispose(w);
    if s.selected_shader >= 0 {
        e := *s.bank.shaders[s.selected_shader];
        w.shader = copy_string(e.desc.name);
        if s.inspect_pass >= 0 w.pass = copy_string(e.desc.passes[s.inspect_pass].id);
        if s.preview_pass >= 0 w.preview = copy_string(e.desc.passes[s.preview_pass].id);
    }
    w.mode = s.mode;
    w.paused = s.paused;
    w.custom_preview = s.custom_preview;
    w.preview_settings = s.preview_settings;
    w.yaw = s.yaw;
    w.pitch = s.pitch;
    w.distance = s.distance;
}

workspace_view_restore :: (s: *Session) {
    w := *s.workspaces[s.workspace];
    s.mode = 0;
    if s.workspace == 1 s.mode = 2;
    s.preview_settings = false;
    s.shader_menu = false;
    s.mode = w.mode;
    s.paused = w.paused;
    s.custom_preview = w.custom_preview;
    s.preview_settings = w.preview_settings;
    s.yaw = w.yaw;
    s.pitch = w.pitch;
    s.distance = w.distance;
}

select_workspace :: (s: *Session, dimension: int) {
    if !s.initialized || dimension < 0 || dimension > 1 || dimension == s.workspace return;
    workspace_save(s);
    cancel(s);
    s.workspace = dimension;
    workspace_restore(s);
}

workspace_restore :: (s: *Session) {
    workspace_view_restore(s);
    w := *s.workspaces[s.workspace];
    s.selected_shader = -1;
    s.inspect_pass = -1;
    s.preview_pass = -1;
    s.workspace_empty = false;
    chosen := -1;
    if s.bank == null {
        s.workspace_empty = true;
        return;
    }
    for e, i: s.bank.shaders {
        if shader_has_3d(s, i) != (s.workspace == 1) continue;
        if chosen < 0 chosen = i;
        if e.desc.name == w.shader {
            chosen = i;
            break;
        }
    }
    if chosen >= 0 {
        pass := -1;
        if s.bank.shaders[chosen].desc.name == w.shader {
            for p, i: s.bank.shaders[chosen].desc.passes {
                if p.id == w.pass pass = i;
            }
        }
        select_shader(s, chosen, pass);
        if s.bank.shaders[chosen].desc.name == w.shader {
            for p, i: s.bank.shaders[chosen].desc.passes {
                if p.id == w.preview s.preview_pass = i;
            }
        }
        return;
    }
    s.workspace_empty = true;
}
//@endregion
