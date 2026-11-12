// gfx 模块 — jfoster 之上的 2D 图形库层。
//
//   #import "gfx"（仓库根在 import_path 时）即可使用：
//     gfx.jai    全局 Batcher + 阶段式 pass + 全屏 shader blit +
//                raylib 风格兼容绘制层（Draw*/IsKey*…）
//     camera.jai CameraState（raylib Camera2D 语义）+ 世界坐标换算
// Optional ImGui frame helpers live in #import "editor".

#load "gfx.jai";
#load "camera.jai";
