// rendering3d:uniforms —— cbuffer 的 CPU 侧打包（与光照/材质模型无关的部分）。
// 一比一移植自 olib kit/rendering/3d/uniforms.odin。
//
// 布局按 SDL std140 规则手排（全 vec4，无 padding 陷阱）。矩阵按 kit/world
// Matrix4 的存储（c0..c3）依次写 64B，HLSL 默认 column_major 读到的就是同一个
// 矩阵；world 是行向量约定（v' = v * M），所以着色器里要写 mul(v, M)。
// 光照、材质等块的布局属于具体着色器，由游戏用 mat.std140_write_* 自行打包
//（参考 olib_sample forward3d/uniforms.odin）。
//
// Jai 侧差异（逐条对应 olib 的写法；写出的字节完全相同）：
//   | olib (Odin)                              | JaiLib (Jai)                                          |
//   | ---------------------------------------- | ----------------------------------------------------- |
//   | `world.Matrix4`                          | W.Matrix4（本包具名导入 kit/world）                      |
//   | `len(buf) < N` / `buf[offset]`            | buf.count / buf.data + offset（Jai 没有切片语法）        |
//   | `mem.copy(&buf[off], &m, 64)`             | mat.std140_write_matrix（同一小端整块拷贝）              |
//   | `view.target.WidthInPixels`               | F.drawable_target_width_in_pixels(view.target)         |
//   | `world.matrix4_inverse` 的 `b, ok :=`      | 同形（Jai 多返回值按序接收）                              |
//   | `if !ok do return`                        | if !ok return（Jai 没有 do）                            |
// 导入由 module.jai 提供（#load 的文件共享这一层的名字）。

//@region 顶点矩阵块 —— WVP + World

// 顶点槽 0 的矩阵块（128B）：WVP + World，按此顺序各 64B。
VERTEX_MATRIX_BLOCK_SIZE :: 128;

// 打包 WVP/World。buf 长度不足返回 false。
pack_vertex_matrix_block :: (buf: [] u8, wvp: W.Matrix4, world_matrix: W.Matrix4) -> bool {
    if buf.count < VERTEX_MATRIX_BLOCK_SIZE return false;
    mat.std140_write_matrix(buf, 0, wvp);
    mat.std140_write_matrix(buf, 64, world_matrix);
    return true;
}

// 材质路径的顶点 b0：矩阵块之后接 Clock（time, delta_time, frame, 0）与 CameraPosition（世界坐标 xyz, 1），
// 与片元帧块同值，顶点着色器可按时间计算位置、按视线方向偏移。不声明它们的 Shader 不受影响。
MATERIAL_VERTEX_BLOCK_SIZE :: VERTEX_MATRIX_BLOCK_SIZE + 32;

// 材质路径的片元 b0：Clock、Pointer（xy 归一化指针，zw 目标像素尺寸）、Tint、CameraPosition，各 16 字节。
MATERIAL_FRAME_BLOCK_SIZE :: 64;

// 视矩阵的逆变换把原点送回世界坐标，即相机位置（w = 1）；不可逆时返回原点。
camera_position :: (view_matrix: W.Matrix4) -> [4] float32 {
    inverse, ok := W.matrix4_inverse(view_matrix);
    if !ok return .[0, 0, 0, 1];
    position, valid := W.matrix4_transform_point(inverse, W.Vec3.{ 0, 0, 0 });
    if !valid return .[0, 0, 0, 1];
    return .[position.x, position.y, position.z, 1];
}

// 写材质路径的顶点 b0 与片元 b0（布局见 olib/model.hlsli），3D 布局只在这里写：Render3D 与 Shader Lab 的 3D 预览共用。
// wvp/world_matrix 由调用方按是否实例化决定；camera 用 camera_position 求，每次提交算一次；Clock.w 为 0。
pack_material_blocks :: (vertex: [] u8, frame: [] u8, wvp: W.Matrix4, world_matrix: W.Matrix4, view: View,
                         camera: [4] float32, pointer: [2] float32, tint: [4] float32) {
    clock: [4] float32 = .[view.time, view.delta_time, cast(float32) view.frame, 0];
    pack_vertex_matrix_block(vertex, wvp, world_matrix);
    mat.std140_write_vec4(vertex, VERTEX_MATRIX_BLOCK_SIZE, clock);
    mat.std140_write_vec4(vertex, VERTEX_MATRIX_BLOCK_SIZE + 16, camera);
    mat.std140_write_vec4(frame, 0, clock);
    mat.std140_write_vec4(frame, 16, .[pointer[0], pointer[1],
                                    cast(float32) F.drawable_target_width_in_pixels(view.target),
                                    cast(float32) F.drawable_target_height_in_pixels(view.target)]);
    mat.std140_write_vec4(frame, 32, tint);
    mat.std140_write_vec4(frame, 48, camera);
}
//@endregion

//@region 骨骼 palette —— 两块各 64 关节（各 4KB）

MAX_JOINTS :: 128;
JOINT_PALETTE_BLOCK_SIZE :: 64 * 64;

// SDL 3.4 Vulkan 每槽 UBO 上限 4KB：128 关节拆两块（0-63 / 64-127），
// 槽位由调用方决定。palette 不足的位置写单位阵兜底（着色器端下标越界防护）。
// buf0 与 buf1 必须是两块不重叠的内存。
pack_joint_palette :: (buf0: [] u8, buf1: [] u8, palette: [] W.Matrix4) -> bool {
    if buf0.count < JOINT_PALETTE_BLOCK_SIZE || buf1.count < JOINT_PALETTE_BLOCK_SIZE ||
       palette.count > MAX_JOINTS {
        return false;
    }

    for i: 0..63 {
        if i < palette.count {
            mat.std140_write_matrix(buf0, i * 64, palette[i]);
        } else {
            mat.std140_write_matrix(buf0, i * 64, W.MATRIX4_IDENTITY);
        }
        if i + 64 < palette.count {
            mat.std140_write_matrix(buf1, i * 64, palette[i + 64]);
        } else {
            mat.std140_write_matrix(buf1, i * 64, W.MATRIX4_IDENTITY);
        }
    }
    return true;
}
//@endregion
