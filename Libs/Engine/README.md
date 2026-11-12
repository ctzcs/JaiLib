# Engine 使用说明

Engine 是一组可按需导入的 Jai 游戏库，提供基础容器、资源管线、音频、
补间和基于 jfoster 的 2D 绘制。新游戏通过 `game_app` 配置生命周期，
应用自行持有状态和绘制资源。
对标范围是 DragonLib 的通用 `Engine`；可选的 `Engine.ECS` 扩展不在范围内。

目前没有统一的 `#import "Engine"` 入口。把本目录加入 Jai 的导入路径，
然后按目录名导入模块；只用 CPU 模块时无需初始化窗口或 GPU。

## 导入与构建

本仓库使用 Jai beta 0.2.009，已验证 Windows 的 D3D12 / Vulkan。
以下 PowerShell 命令均从 **JaiLib 仓库根目录** 执行。

```jai
E  :: #import "entities";
AT :: #import "asset";
TW :: #import "tween";
```

建议给模块取别名，避免 `init`、`Handle`、`M` 等名称冲突。
新游戏的入口对应 DragonLib 的 `Engine.GameApp`；图形 API 直接使用 jfoster，
字体按需导入 `text`。

纯 CPU 程序的构建方式，例如下文的实体容器示例：

```powershell
New-Item -ItemType Directory -Force bin | Out-Null
jai -no_cwd -import_dir "$PWD\Libs\Engine" -output_path "$PWD\bin" -exe entities_quickstart Tests\entities_quickstart.jai
```

图形程序还需相邻的 jfoster 检出。使用 clay 时再增加 bindings 的导入路径。
`-import_dir` 应指向 **包含 jfoster 文件夹的父目录**：

```powershell
$fosterParent = (Resolve-Path ..).Path
jai -no_cwd -import_dir "$PWD\Libs\Engine" -import_dir "$fosterParent" -output_path "$PWD\bin" -exe game_app_demo Tests\game_app_demo.jai
Copy-Item "$fosterParent\jfoster\internal\native\windows\SDL3.dll" bin
Copy-Item "$fosterParent\jfoster\internal\third_party\stb\stb_impl.dll" bin
Copy-Item "Libs\Engine\text\windows\harfbuzz.dll" bin
.\bin\game_app_demo.exe
```

使用 ImGui 时还需要 Jai 的 `ImGui` 模块，以及链接和运行所需的
`imgui.lib` / `ImGui.dll`。现有构建脚本已配置本机的路径，可参考
[run_imgui_demo.bat](../../run_imgui_demo.bat)。

## 新建一个游戏

参照 DragonLib 的 `Libs/Engine/GameApp.cs`：C# 中继承 `GameApp` 并重写
Foster 的 `Startup / Update / Render / Shutdown`；Jai 中用 `Game_App`
保存配置和对应回调，然后 `game_app_run`，返回后 `game_app_destroy`。
两边的 GameApp 都不自动创建 Batcher、字体或场景。

下面是可编译的窗口入口。完整的矩形和文字示例见
[game_app_demo.jai](../../Tests/game_app_demo.jai)，复制它作为新游戏的起点即可。

```jai
#import "Basic";
GA :: #import "game_app";
F :: #import "jfoster";

startup :: () { /* 在这里创建游戏自己的资源 */ }
update :: () {
    if F.keyboard_pressed(F.input_keyboard(F.App.input), .ESCAPE) F.app_exit();
}
render :: () {
    target := F.drawable_target_window(F.App.window);
    F.graphics_device_clear_color(F.App.device, target, .{24, 28, 36, 255});
}
shutdown :: () { /* 在这里释放游戏自己的资源 */ }

main :: () {
    args := get_command_line_arguments();
    config := F.App_Config.{
        application_name = "MyGame", window_title = "MyGame",
        width = 800, height = 600,
    };
    app := GA.Game_App.{
        config = GA.game_app_apply_cli_args(config, args),
        startup = startup, update = update, render = render, shutdown = shutdown,
    };
    if GA.game_app_has_arg(args, "--cli") _ := GA.game_app_enable_cli(*app);
    GA.game_app_run(*app);
    GA.game_app_destroy(*app);
}
```

完整 Demo 的构建与运行：

```powershell
.\run_game_app_demo.bat
.\bin\game_app_demo.exe
.\bin\game_app_demo.exe --cli --no-focus
# 自动绘制 120 帧后退出：
.\run_game_app_demo.bat auto
```

`--no-focus` 对应 DragonLib 的 `ApplyCliArgs`，只影响窗口显示时是否激活。
`--cli` 是示例中选择调用 `EnableCli` 的开关，GameApp 自身不自动启动 CLI。
CLI 与 DragonLib 一样提供 `help / quit / history`，示例另注册了 `status`。
通过 `GA.cli_register(cli, name, description, handler, data)` 注册命令，
处理函数签名是 `(args: string, data: *void)`；`data` 代替 C# 委托捕获的实例。
输入在后台读取，处理函数在启动回调之后的主线程执行，允许在 Run 前启用。
参数和命令名按 ASCII 不区分大小写；命令参数保留 UTF-8 文本与内部空格。

生命周期：`startup` 时设备已创建；`update` 更新游戏；`render` 提交绘制；
`shutdown` 释放游戏资源；Run 返回后 Destroy 释放 CLI 和 jfoster 平台资源。
Jai 没有 C# 的异常机制，命令处理函数的断言失败不会转换成 CLI 日志。
当前 jfoster 使用全局 App，一个进程运行一个游戏实例；CLI 已验证 Windows，
其他桌面平台的 stdin 分支尚未运行验证。

## 2D 绘制、相机与 UI

下文的 `gfx` 是现有 Demo 使用的 raylib 风格兼容绘制层。
新游戏入口使用上面的 `Game_App`，绘制参考完整 Demo 中自行持有的 jfoster Batcher。

`gfx` 使用一个全局 `gfx_batcher`，适合当前的单窗口渲染流程。
`DrawRectangle`、`DrawCircleV`、`DrawLineEx` 等调用追加几何，
`gfx_pass_end(target)` 才提交绘制。`gfx_pass_begin(target, clear)` 会
清空目标和当前批次；同一目标的多个视口应先清屏一次，再分别提交各视口，
参见 [dual_camera2d_demo.jai](../../Tests/dual_camera2d_demo.jai)。

坐标原点在左上角，y 向下。通过
`F.drawable_target_width_in_pixels(target)` / `height_in_pixels(target)`
取得绘制目标的物理像素大小，窗口缩放或高 DPI 下应重新读取。

相机绘制可插入上面 render 的 pass 内：

```jai
camera := CameraState.{
    target = .{0, 0}, offset = .{400, 300}, zoom = 40, rotation = 0,
};
BeginMode2D(camera);
DrawCircleV(.{0, 0}, 1, GOLD);
EndMode2D();
```

`target` 是要放在 `offset` 位置的世界坐标，`zoom` 必须非零，旋转单位
为弧度；矩阵使用负向旋转。`world_mouse_pos(mouse, camera)` 将屏幕坐标
转换到世界坐标。输入应与相机 offset 使用相同的像素坐标系；分视口时
先减去视口原点，高 DPI 时还需按窗口逻辑尺寸与目标像素尺寸换算。

`gfx_init()` 和 `clay_foster_setup(device)` 默认使用内嵌 Roboto MSDF，
无需字体文件即可显示 ASCII 文字，支持多字号缩放。`DrawText` 遵循当前
相机变换，`MeasureText(text, font_size)` 返回相同布局的宽高。
自定义字体加载失败时打印提示并回退到内嵌 MSDF。

中文使用包含对应字形的 TTF/TTC。`extra_glyphs` 可预热常用字符，ASCII
自动加入，后续遇到新字符会按需加入图集。以下为启动回调中的用法：

```jai
gfx_init("assets/fonts/chinese.ttf", extra_glyphs = "你好，世界！开始游戏设置退出");
// clay 的等价配置：
// CF.clay_foster_setup(F.App.device, "assets/fonts/chinese.ttf", "你好，世界！开始游戏设置退出");
```

之后可在 pass 内调用 `DrawText("你好，世界！", 20, 20, 32, WHITE)`。
字体文件仅在初始化时读取；预热字符可来自本地化文本，重复字符会去重。
整条回退链都缺失的字符显示 `?`。TTC 读取第一个字体。
内嵌 Roboto 只含 ASCII；中文路径当前使用 TTF 位图图集，放大效果受烘焙
字号影响，不会自动转换成 MSDF，也不会自动扫描系统字体。

gfx 与 clay 共用 `text` 模块。TTF/TTC 经 HarfBuzz 11.2.1 处理 kerning、
连字、组合附标和上下文字形；测量与绘制使用同一布局。clay 的
`letterSpacing` 按最终像素加在 cluster 之间，`lineHeight = 0` 使用自然行高。
中文动态页只追加字形，已有布局的纹理坐标保持有效。

如需同时绘制多种字体，可自行持有 `TXT :: #import "text"` 中的
`Text_Font`：`text_font_create(device, path, extra_glyphs, bake_size)` 创建，
`text_draw` / `text_measure` 使用，`text_font_destroy` 在设备销毁前释放。
自定义路径加载失败返回 null；空路径创建内嵌 MSDF。
参见 [字体 Demo](../../Tests/font_demo.jai)。

```jai
// startup；fallback 必须活到使用它的布局和主字体停止使用为止。
cjk := TXT.text_font_create(F.App.device, "assets/fonts/chinese.ttf");
if cjk != null {
    _ := TXT.text_font_add_fallback(gfx_text_font, cjk);
    _ := CF.clay_foster_set_font(7, cjk); // TextElementConfig.fontId = 7
}
// shutdown：先注销借用关系，再释放字体。
// CF.clay_foster_set_font(7, null);
// TXT.text_font_remove_fallback(gfx_text_font, cjk);
// TXT.text_font_destroy(cjk);
```

fontId 0 是后端拥有的默认字体，1–255 借用注册的字体；未注册 ID 回退到 0。
回退链按注册顺序查找，不递归访问其他字体的回退链。切换 fontId 注册会
清理 clay 的测量缓存；若修改已注册字体的回退链，在两次布局之间调用
`clay_foster_invalidate_text()`。创建、测量、补字、绘制和销毁须在同一
渲染线程进行；clay 原生回调显式恢复创建字体时的
Jai context。不要用临时 allocator 创建长期字体。

静态标签可保存 `text_layout_create` 的结果，用 `text_layout_draw` 重复绘制，
最后 `text_layout_destroy`。布局借用字体，需先于字体销毁。复杂文字可传
`options = .{direction = .Right_To_Left, language = "ar"}`；默认猜测 run 属性。
这里提供的是 **run 级字形排版**：完整段落的双向算法、自动脚本分段、
换行和编辑光标不由 HarfBuzz 代办。混合方向段落应由应用分 run 后按视觉
顺序调用 `text_layout_run`；clay 仍负责自己的布局与换行。

Windows 运行目录要带 `harfbuzz.dll`，现有构建脚本会复制。源码版本固定为
上游 11.2.1，重建脚本是 [build_harfbuzz.ps1](../../Tools/build_harfbuzz.ps1)，
许可证见 [HarfBuzz.LICENSE](text/HarfBuzz.LICENSE)。其他平台需提供系统
HarfBuzz；本次只验证了 Windows。

| UI | 初始化 | 每帧使用 | 释放与示例 |
| --- | --- | --- | --- |
| ImGui | `imgui_foster_setup(font_path)` | update 收集输入；render 配对调用 `ED.imgui_begin_frame()` / `ED.imgui_end_frame()`，在屏幕 pass 提交前完成 | `imgui_foster_shutdown()`；[ImGui Demo](../../Tests/imgui_demo.jai) |
| clay | `clay_foster_setup(device, font_path)`；配置 clay arena 和文字测量回调 | 同步输入及布局尺寸，执行布局，将命令交给 `clay_foster_render` | `clay_foster_shutdown()`；[clay Demo](../../Tests/clay_demo.jai) |

ImGui 的 NewFrame 与 Render 必须一一对应；不要在可能一帧执行多次的
update 回调中调用 `ED.imgui_begin_frame()`。

clay 的 IMAGE 将 `imageData` 解释为借用的 `*F.Texture`，按布局 boundingBox
拉伸绘制；保持比例应在布局侧设置宽高。通过
`clay_foster_set_custom_draw(callback, user)` 注册 CUSTOM 绘制，回调收到
batcher、boundingBox、customData 和 user，继承当前裁剪；回调应配对恢复
自己修改的矩阵、材质等状态。图片、customData 与注册字体都需活到命令提交。

`ED :: #import "editor"` 提供 `Property_Editor`、`property_drawer` 和
`asset_selector`。在 ImGui 帧内调用 `ED.property_drawer(*editor, "Settings", *settings)`，
支持 bool、各宽度整数、浮点、枚举、字符串、嵌套结构及数组；字段注记
`@editor_hide` 隐藏字段，指针和 union 只读显示。递归默认最多 16 层，
数组最多显示 256 项，字符串编辑上限 4095 字节。

被编辑对象的地址必须稳定；修改后的字符串借用 editor 缓冲区，持久化时
先复制，最后调用 `property_editor_destroy`。资源选择器从导入 manifest
列出 GUID，不隐式加载资源；可用 `extension = ".png"` 筛选。
完整示例见 [editor_demo.jai](../../Tests/editor_demo.jai)。

## 实体容器

`entities` 是按实体类型分池的轻量容器。应用自己迭代和更新数据，
无需 ECS System 或 Pipeline。下面是完整的无窗口程序，可保存为
`Tests/entities_quickstart.jai`：

```jai
#import "Basic";
E :: #import "entities";

Position :: struct { x, y: float32; }
Player :: struct { base: E.Base; position: Position; }

main :: () {
    entities: E.Entities;
    E.init(*entities, .[Player], .[Position], default_cap = 128);
    defer E.shutdown(*entities);

    handle, created := E.create(*entities, Player.{position = .{10, 20}});
    assert(created);
    position, found := E.get_sub(*entities, handle, Position);
    assert(found);
    position.x += 5;
    print("Player position: %, %\n", position.x, position.y);

    assert(E.destroy(*entities, handle));
    _, still_alive := E.get(*entities, handle);
    assert(!still_alive);
}
```

实体结构必须以 `E.Base` 为首字段。`init` 的第二个参数登记实体类型，
第三个参数登记可查询的字段类型；`get_sub` 只能查询已登记的类型。
长期引用应保存 Handle，查询得到的指针只作短期使用。

使用 `begin_val` / `next_val` 迭代某类存活实体，使用
`begin_sub` / `next_sub` 迭代某类字段。`get_buffer` 包含删除后的空洞，
不能直接当作存活实体列表。每种实体容量固定，包含一个保留槽；
`default_cap` 范围为 2–2,147,483,647，实际容量受内存限制。
Handle 使用 u32 index / variant、u64 generation；同一容器生命周期内用
单调创建序号，clear 不重置，耗尽时拒绝创建，不会回绕复活旧句柄。
Handle 现在为 16 字节，旧版二进制句柄不兼容；shutdown 后重新 init 属于
新生命周期，旧句柄必须丢弃。句柄不是跨进程、跨容器的持久资产 ID。
完整迭代及性能用法见 [Entities Demo](../../Tests/entities_demo.jai)。

## 资源管线与部署

`asset` 将源文件导入为 blob，再按 GUID 或相对源路径加载：

```text
Assets/player.png + player.png.meta → Library/<guid>.blob → Asset_Handle
```

`.meta` 保存资产身份，应随源文件提交、移动；`Library` 是可重新生成的
派生缓存。开发或构建阶段调用 `import_all`，运行时只需加载产物。
下面的函数要求 `Assets/player.png` 已存在，错误交由调用方处理：

```jai
AT :: #import "asset";

load_example :: () -> AT.Asset_Error {
    _, import_error := AT.import_all("Assets", "Library");
    if import_error != .None return import_error;

    assets: AT.Asset_Manager;
    init_error := AT.assets_init(*assets, .{
        assets_root = "Assets", library_root = "Library",
    });
    if init_error != .None return init_error;
    defer AT.assets_dispose(*assets);

    handle, load_error := AT.assets_load_path(*assets, "player.png");
    if load_error != .None return load_error;
    image := AT.assets_get_image(*assets, handle);
    if image == null return .Kind_Mismatch;
    // 在这里使用 image.width、image.height 和 image.pixels。
    return .None;
}
```

`asset` 的纹理资产是 CPU 端 RGBA8 `Image`；需要 GPU 缓存时使用下面的
`graphics_assets`，不用自己重复管理上传与引用。
JSON 用 `assets_get_json`，原始字节用 `assets_get_bytes` 获取。
这些数据由管理器拥有，不能单独释放；卸载后不能继续使用。
同一 GUID 重复加载返回缓存句柄，当前没有引用计数。

发行时可只携带 `Library`，包括导入生成的 manifest；
`assets_root` 留空仍可通过 manifest 用 `assets_load_path` 加载。
示例中的相对路径按当前工作目录解释；要从任意目录启动，应用应显式
配置绝对路径。`gfx_executable_asset_path("Library")` 可获取 exe 旁路径，
返回临时字符串，长期保存时需 `copy_string` 并在结束时释放。
`assets_root` 和默认目录后端的 `library_root` 配置字符串由管理器借用，
必须保持存活。
完整管线示例见 [asset_test.jai](asset/asset_test.jai)。

### GPU 纹理和图集

```jai
GA :: #import "graphics_assets";
textures: GA.Texture_Manager;
// startup；manager 地址和配置路径字符串必须保持稳定。
error := GA.textures_init(*textures, F.App.device, .{library_root = "Library"});
handle, load_error := GA.texture_acquire_path(*textures, "player.png");
if load_error == .None {
    texture := GA.texture_get(*textures, handle); // 借用，勿直接 dispose/free
    // 在 pass 内绘制 texture。
    _ := GA.texture_release(*textures, handle);
}
// shutdown，在 device 销毁之前：GA.textures_destroy(*textures);
```

每次 acquire/retain 对应一次 release；相同 GUID 只上传一次，最后一次
release 释放 GPU 与其私有 CPU 缓存。旧 handle 查询返回 null，重复 release
返回 false。全部调用限渲染线程，至少保持引用到当前 batch 提交完成。
`textures_destroy` 强制清理剩余引用；图集需先于其 manager 销毁。

`Sprite_Atlas` 支持 `atlas_load_json(*atlas, *textures, json_text)`，格式：

```json
{"image":"sprites/sheet.png","sprites":[
  {"name":"hero","x":0,"y":0,"w":32,"h":32,"pivot_x":16,"pivot_y":16}
]}
```

image 是 manifest 中的相对路径。`atlas_get` 返回命名子图，`atlas_draw`
按 pivot、position、scale 和弧度 rotation 绘制。`atlas_pack` 接受名字数组
及 CPU `Image` 数组，生成带边缘 padding 的多页图集，不取得输入图片所有权。
加载/打包成功替换旧 atlas，失败保留旧值；atlas 须先零初始化。
最后调用 `atlas_destroy` 释放其页或纹理引用。
低层 `atlas_add` 借用纹理，调用方保持存活。当前 JSON 是上述明确的
Engine 格式；TexturePacker/Aseprite 元数据应先转换成相同记录。
像素级示例见 [engine_graphics_tests.jai](../../Tests/engine_graphics_tests.jai)。

jfoster 默认 shader、Roboto JSON/PNG 和许可证在编译时内嵌，运行时
无需根目录 `content/`。应用自定义 shader 则由应用部署：配置
`gfx_shader_dir`，用 `gfx_load_fragment_shader` 加载、设置 uniform /
sampler，再通过 `gfx_blit_pass` 执行后处理，结束时 `gfx_shader_destroy`。
HLSL 和多 pass 示例见 [fluid2d](../../Tests/fluid2d/main.jai)，其编译产物
由 [run_fluid2d.bat](../../run_fluid2d.bat) 复制到 exe 旁。

## 场景、消息、任务与 XML

`W :: #import "world"` 的 `Scene_Router(Screen)` 保存 current、previous、
transitioning 和 progress。`scene_init(*router, .Menu)` 初始化，
`scene_switch(*router, .Game, 0.3)` 立即切换 current，并开启 0.3 秒计时，
每帧 `scene_update(*router, dt)`。应用依据 progress 绘制过渡并调用自己的
场景生命周期；切换过程中再次切换会从当前场景重新开始过渡。

`MSG :: #import "messaging"` 提供单线程、值复制的通用消息：

- `Command_Queue(T)`：enqueue / dequeue / count / clear；`command_drain`
  只处理调用时已有的命令，handler 新入队的命令留给下次，不允许重入 drain。
- `Broadcast_Channel(T)`：publish 写入 pending；每帧开头调用一次
  `broadcast_advance`，所有订阅方借用同一 `broadcast_messages` 切片，
  到下次 advance 前有效。下一帧没有新消息时为空，不无限积累。

消息中的指针/字符串由应用拥有；最后分别 command_destroy / broadcast_destroy。

`J :: #import "threading"` 提供持久工作线程和有界队列：

```jai
square :: (first: s64, end: s64, user: *void, worker: s64) {
    values := cast(*s64) user;
    for i: first..end-1 values[i] = i * i;
}
// 在函数内使用，values 保持存活到 complete 返回：
jobs: J.Job_Scheduler;
assert(J.jobs_init(*jobs, worker_count = 3, capacity = 256));
values: [1000] s64;
job := J.jobs_schedule_range(*jobs, 1000, 64, square, *values);
J.job_complete(*jobs, job);
J.job_release(job);
J.jobs_destroy(*jobs);
```

range 是半开区间 [first,end)，空 range 立即完成。worker=0 表示提交/等待
线程正在协助执行，其他 worker 索引从 1 开始；不要把它当作全局线程 ID。
队列满时提交者协助执行；worker_count=0 也可运行。提交和等待可能执行
任意已排队 callback，因此 callback 不得等待自身或形成依赖环，也不得
操作仅限主线程的 GPU/UI。用户数据同步由调用方负责；scheduler 地址固定，
销毁前停止全部生产者，destroy 会排空并 join。job_release 必须在完成之后。

`X :: #import "encoding"` 新增 UTF-8 XML 树：`xml_parse` / `xml_load`
返回 `(root, Xml_Error)`，`xml_attribute`、`xml_child` 查询，`xml_string`
返回调用方释放的字符串，`xml_save` 写文件，最后 `xml_destroy(root)`。
支持属性、元素、顺序混合文本、CDATA、五种预定义实体及 Unicode 数字引用；
UTF-8、重复属性、闭合标签、非法字符和深度上限会检查。
这是配置数据用的非验证解析器：不解析 DTD/外部实体，不做 schema 或
命名空间 URI 解析；前缀保留原文，注释/处理指令不保留，声明不转换编码。
支持范围与错误路径见 [engine_core_tests.jai](../../Tests/engine_core_tests.jai)。

## 音频与其他模块

`AU :: #import "audio"` 使用 Jai 的 Sound_Player：

1. `AU.audio_init(.{})` 初始化；返回 false 时由应用决定无声运行或退出。
2. `audio_load_sound(path)` 加载 WAV / OGG，检查返回值非 null 后调用
   `audio_play(sound, .MUSIC, loop = true)` 等播放接口。
3. 默认由混音线程更新；配置 `update_from_a_thread = false` 时需定期
   `audio_update()`。实例音量和速率可通过 `audio_instance_set_*` 调整。
4. `audio_shutdown()` 停止设备/线程并释放已加载声音。提前释放某个声音
   前先停止引用它的播放实例；`audio_free_sound` 不会替你停止播放。

可运行示例见 [audio_demo.jai](../../Tests/audio_demo.jai)。

| 模块 | 典型用法 | 参考 |
| --- | --- | --- |
| `container` | `new_simple_array(T, N)` 创建定长数组；`add_element` 满时返回 null | [测试](container/simple_array_test.jai) |
| `handle` | 导出 `HA`（句柄数组）和 `HM`（可增长键值池）；也可直接导入子模块。HA 用 `add/get/remove_handle`，结束时 `delete` | [HA 测试](handle/handle_array/handle_array_test.jai)、[HM 测试](handle/handle_map/handle_map_test.jai) |
| `encoding` | JSON、CSV、UTF-8 XML；分别使用 json_destroy_value / csv_manager_destroy / xml_destroy 释放 | [测试](encoding/encoding_test.jai) |
| `tween` | `make_ex` 创建值补间、传入插值函数，`tween_get_value` 接收当前绝对时间（秒）；manager 用 `manager_update(dt)` 推进，结束时 `manager_delete` | [测试与 Sequence 用法](tween/tween_test.jai) |
| `text` | 内嵌 MSDF / TTF/TTC、动态补字、回退链、HarfBuzz run 排版 | [字体 Demo](../../Tests/font_demo.jai) |
| `profiler` | `profile_init()`；`g := profile_scope("name"); defer profile_scope_end(g);`；`profile_dump()` 输出统计 | [源码](profiler/profiler.jai) |
| `debug` | 程序导入 `#import "Basic"()(MEMORY_DEBUGGER=true);` 启用 Jai 内存调试；`track_create/track_destroy` 是兼容占位接口 | [源码](debug/debug.jai) |

world、messaging、threading 是独立的 CPU 模块，不依赖 ECS 或图形初始化。

## 运行现有验证

```powershell
.\run_tests.bat
.\run_dragonlib_demos.bat auto
.\bin\default_resources_tests.exe auto vulkan
.\bin\dual_camera2d_demo.exe auto vulkan
.\bin\font_demo.exe auto vulkan
.\bin\engine_graphics_tests.exe vulkan
.\bin\editor_demo.exe auto
```

`run_tests.bat` 验证 CPU 模块，Demo 构建脚本验证默认资源、相机、容器和
双相机、字体、GPU 资源与属性编辑器；失败返回非零退出码。`font_demo.exe` 不传 auto 时显示
字体对照窗口；可额外传入 TTF/TTC 路径和 PNG 输出路径。Demo 在 Windows
上会尝试系统黑体用于中文测试；库本身不依赖这个路径。交互 UI 和多 pass 示例分别通过
`run_imgui_demo.bat`、`run_clay_demo.bat`、`run_fluid2d.bat` 构建。

文中的 quickstart 文件由读者从代码块保存；已有可运行程序位于 `Tests`。

## 可选编辑器依赖

`#import "gfx"` 只导入运行时。使用 ImGui 的程序显式导入
`ED :: #import "editor"`，再调用 `ED.imgui_process_input()`、
`ED.imgui_begin_frame()`、`ED.imgui_end_frame()`。setup/shutdown 仍由
`bindings/imgui_foster` 负责；完整示例见 [editor_demo.jai](../../Tests/editor_demo.jai)。
普通部署调用 `Tools/stage_runtime.bat <目录>`；带编辑器的部署使用第二个
参数 `editor`，才复制 ImGui.dll。脚本不会删除目标目录已有的 DLL。

## GameStorage：资源与用户数据

`S :: #import "storage"` 提供按相对路径读写的 `Storage` 接口，
`Game_Storage.resources` 与 `Game_Storage.user` 分别用于资源和存档。
接口本身可编译到 WASM64，目录后端只在桌面目标提供。

```jai
S :: #import "storage";
game: S.Game_Storage;
resource_dir, user_dir: S.Directory_Storage;

// 放在 App.startup 中；显式给定 user 根目录时也可在窗口启动前初始化。
setup_storage :: () {
    assert(S.directory_storage_init(*resource_dir, gfx_executable_asset_path("MyGame")));
    assert(S.directory_storage_init(*user_dir, F.app_user_path(), true));
    S.game_resources_set(*game, S.directory_storage(*resource_dir));
    game.user = S.directory_storage(*user_dir);
    assert(S.storage_write_text(*game.user, "Saves/session.json", "{\"level\":3}"));
    bytes, ok := S.storage_read(*game.resources, "Levels/intro.json");
    if ok {
        defer free(bytes.data);
        // 解析 bytes；返回内存属于调用方。
    }
}
```

目录初始化复制根目录字符串，默认只读；写入模式会创建父目录。
`storage_read` 返回 `(bytes, success)`：空文件成功与文件不存在明确区分。
传入自定义 allocator 时，调用方用同一 allocator 释放结果。
路径使用 `/` 或 `\`，拒绝绝对路径、`..`、空段和 Windows 保留文件名。
这只是路径约束；目录后端不提供符号链接隔离、加密或事务存档。

自定义内嵌、压缩包或浏览器后端只需提供 `Storage` 中的函数指针。
后端 state 被借用，不能在 Storage 仍被引用时销毁或移动。应用结束时调用
`directory_storage_destroy`，并先销毁引用该后端的资源管理器。
`game_resources_set` 增加 `resources_revision` 并在调用线程触发 `changed` 回调；
已加载的纹理/资源仍由应用显式释放或重载。接口不替应用做线程同步。

shader 可直接通过该入口加载：

```jai
shader := gfx_load_fragment_shader("gutwall", 3, *game.resources, "shaders");
```

不传 storage 时保留 `gfx_shader_dir` 目录读取方式。GUID blob 加载可以使用
`SA :: #import "storage_assets"` 的 `Storage_Assets` 与 `storage_assets(*bridge)`，
传给 `Asset_Manager_Config.storage`。该桥接读取资源后端的 `Library/<guid>.blob`；
manifest 的路径索引仍使用 asset 模块原有配置。
详见 [storage_tests.jai](../../Tests/storage_tests.jai) 与
[GutWall Demo](../../Tests/gutwall_demo.jai)，后者通过资源接口读 shader、通过用户接口导出 PNG。

## shader 产物校验

当前示例使用 fragment_main，输出 DXIL 与 SPIR-V。构建脚本先验证
`manifest.json` 的源码/产物 SHA-256，源码过期、产物损坏、缺失或重复时终止。
修改 HLSL 后运行：

```powershell
.\Tools\compile_shaders.bat
powershell -NoProfile -ExecutionPolicy Bypass -File Tools\Build-Shaders.ps1 -Source Tests\gutwall\shaders\hlsl -Output Tests\gutwall\shaders\compiled
```

`Build-Shaders.ps1` 的 `Compiler` 参数可覆盖 shadercross 路径，默认使用相邻
DragonLib 的工具。全部编译成功后才发布产物和清单；编译失败不会发布新的清单。
当前清单覆盖各 HLSL 主文件，尚不支持 `#include`；Metal/GLSL 与 Web 渲染产物未加入。
校验器的拒绝路径由 [test_shaders.ps1](../../Tools/test_shaders.ps1) 自动验证。

## GutWall Demo

移植基准是 DragonLib `0466793`。生成器使用 Gray-Scott 反应扩散，生成
1400×800 的 albedo、normal 和 material（高度/粗糙度/AO/遮罩）三张图。
生成在 worker 上运行，GPU 上传与销毁在主线程执行，关闭窗口会取消并等待任务。
可切换光照/颜色/高度/法线视图，控制灯光、暖色补光、法线强度和湿润高光，
调整种子、拱起、折叠尺度等参数后 Regenerate。Cancel bake 保留上一次完成的纹理。

```powershell
.\run_gutwall_demo.bat
.\bin\gutwall_demo.exe
.\run_gutwall_demo.bat auto
```

交互导出位于 `F.app_user_path()/GutWallExport`，界面显示实际用户目录。
自动模式导出到 `.test_tmp/gutwall/GutWallExport`，包含三张原始图与七张 GPU 视图。
`auto` 会验证灯光、法线、高光和视图的像素变化，再生成一次验证纹理复用；
`vulkan` 选择 Vulkan；`cancel` 验证退出时取消后台任务。

## Web 可行性探针

本地 Jai beta 0.2.009 自带 WASM64 编译支持，探针复用其 Walloc 示例分配器。
消息队列、SceneRouter 和 GameStorage 内嵌后端已编译并在 Node 24.19.0 执行通过：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Tools\probe_web.ps1
```

本机 PATH 中的 Node 22.17.0 无法加载该模块，即使启用 experimental memory64。
验证时使用 Codex 已带的 Node 24.19.0，无需修改系统 Node。
探针默认优先使用已安装的 Codex Node；其他环境可用 `-Node` 指定兼容的运行时。
`-CheckGraphics` 追加实际 gfx 编译诊断；目前 jfoster 的 POSIX 线程/文件与 SDL_GPU
平台实现不能直接编译到 Web。还需实现浏览器输入、WebGL2 图形、资源/持久化、
音频与主循环，并处理 WASM64 指针的 BigInt 桥接。本探针没有验证浏览器运行。
