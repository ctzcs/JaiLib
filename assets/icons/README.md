# 默认图标图集

Game Icon Pack v1.4 的 `padding/128px/white`：815 个图标，12 个分类，
统一打包为 `game-icons.png`（4096×4096）和 Kenney/Starling 格式的 `game-icons.xml`。
PNG 使用无损索引色与 straight alpha，加载后解码为 RGBA8；XML 名称为
`分类/文件名`，例如 `game/action-points`。
去掉原分类目录的数字排序前缀，不保留 `.png` 后缀。

原图的 128×128 画布与留白完整保留，每边另加 2px 边缘扩展。
坐标指向原图区域，不包含扩展边缘。排列顺序不是 API，调用方应按名字查询。
XML 中额外记录原始相对路径与 SHA-256，供更新核对；不要手动修改生成文件。

## 加载与绘制

```jai
R2D :: #import "kit/rendering/2d";
F :: #import "foster";

// 放在地址稳定的游戏状态中；设备建立后调用。
icons: R2D.Sprite_Atlas;
ok := R2D.builtin_icons_load(*icons, F.App.device);
// 使用后、销毁设备前：R2D.atlas_dispose(*icons);
```

`builtin_icons_load` 用 Jai `#run` 相对源码位置嵌入资源，不依赖进程工作目录，也不自动初始化 GPU。
调用目标必须为零值；重复加载已使用的目标会失败且保留原内容。
已加载图集不可复制/移动，返回的 Subtexture 引用图集内的纹理地址。
加载失败会清理本次分配并返回 false。

纹理为 RGBA8、无 mipmap，显存约 64 MiB；PNG 文件大小不等于显存占用。
上传后释放 CPU 图像，额外的约 64 MiB 解码像素只在加载期间存在。
采用普通线性采样、预乘 alpha 混合；白色图标通过 tint 改色。
UI 在最终像素目标绘制，小尺寸与非整数缩放仍需在项目最终输出中验收。

也可自行读取 PNG/XML，调用 `kenney_build_rects → atlas_from_rects → atlas_upload`。
此路径须自己调用一次 `F.image_premultiply`，并管理 CPU 像素生命周期。

## 来源与许可记录

来源：用户提供的 `Game-Icon-Pack-v1.4-PNG/padding/128px/white` 本地资源包。
当前提供的目录没有附带原作者、下载页面或许可证；这些信息尚待补齐。
此记录不是许可证，也不声称图标适用 JaiLib 代码的许可。对外发布或再分发前应补齐
原包许可与要求的署名。此次只生成本地仓库资源，未发布。

原始的 815 个 PNG 不重复存入仓库；重建时提供原包目录。
生成命令和完整像素校验见 [打包工具](../../tools/icons/README.md)。

## 在 ImGui 中使用

本仓库 ImGui Foster 后端使用 straight alpha。可调用 `R2D.builtin_icons_decode()`
获得 CPU 原图和名称表，自行裁剪/缩放后建立纹理，再通过
`imgui_foster_register_texture` 接入。不要复用已预乘的 atlas 纹理。
当前 Jai 后端没有 Odin 后端的 IconsInit / IconButton API，不要复制那些调用。
成功解码后用 `F.image_destroy(*image)` 和 `R2D.kenney_rects_dispose(rects)` 释放。
PNG 解码/上传路径已在 Windows 验证；Web PNG 解码能力仍受 Foster 后端限制。
