// material:std140 —— 手写 cbuffer 的 CPU 侧打包（游戏自己的光照/材质块、gizmo、ShaderLab 帧块）。
// 一比一移植自 olib kit/rendering/material/std140.odin。
//
// 布局按 SDL std140 规则手排（全 vec4，无 padding 陷阱）。矩阵按 kit/world Matrix4 的存储
// （c0..c3）依次写 64B，HLSL 默认 column_major 读到的就是同一个矩阵；world 是行向量约定
// （v' = v * M），所以着色器里要写 mul(v, M)。
// 本包不 import kit/world，矩阵参数接受任意 4×4 f32 类型。
//
// Jai 侧差异（逐条对应 olib 的写法，输出字节不变）：
//   | olib (Odin)                             | JaiLib (Jai)                                          |
//   | --------------------------------------- | ----------------------------------------------------- |
//   | `where size_of(M) == 64`（参数约束）      | `#assert(size_of(M) == 64, …)`：Jai 没有 where 子句，   |
//   |                                         | 违反时从「不参与重载」变成「编译期硬错」（不会静默）      |
//   | `when ODIN_ENDIAN == .Little { … }`     | 只保留小端整块拷贝：Jai 没有端序编译期常量，而 Jai 的   |
//   |                                         | 目标平台（x64/ARM64 的 Windows/Linux/macOS）全是小端，  |
//   |                                         | 与 olib 在小端上的逐字节结果相同；大端不在支持范围内     |
//   | `transmute([4][4]f32)m`                 | `columns: [4][4] float32 = xx local;`（位型重解释）    |
//   | `mem.copy(&buf[offset], &m, 64)`        | `memcpy(buf.data + offset, *local, 64)`（先拷到局部，   |
//   |                                         | 避免对 >32B 的按值参数取地址——jfoster 踩过的坑）        |
//   | `len(buf)` / `len(buf[offset:])`        | `buf.count`（Jai 没有切片语法，越界判断写全）            |
//   | `buf[base + 1] = u8(bits >> 8)`         | 整块 memcpy 已覆盖同一结果，大端分支不移植               |

//@region std140 写入

// 在 offset 处写一个 4×4 f32 矩阵（如 world.Matrix4；按存储顺序每 16B 一列，共 64B）。越界的列跳过。
std140_write_matrix :: (buf: [] u8, offset: int, m: $M) {
    #assert(size_of(M) == 64, "std140_write_matrix 只接受 64 字节的 4×4 f32 矩阵（如 world.Matrix4）");
    // 小端：存储顺序就是 f32 位型，整块拷贝与逐列写出的结果相同（olib 的 when ODIN_ENDIAN == .Little 路径）。
    if offset >= 0 && offset + 64 <= buf.count {
        local := m;
        memcpy(buf.data + offset, *local, 64);
        return;
    }
    // 放不下整块：逐列写（每列自己判越界），与 olib 的兜底分支一致。
    local := m;
    columns: MAT4_F32;
    memcpy(*columns, *local, 64);   // Jai 没有 transmute/xx 位型转换：按字节拷到 [4][4] float32
    for i: 0..3 {
        std140_write_vec4(buf, offset + i * 16, columns[i]);
    }
}

// 在 offset 处写一个 vec4（16B，小端，按 f32 位型直写）。越界时不写。
// 每个 Draw 要写十几次：整块拷贝，与逐字节写出的结果相同（olib 的小端分支）。
std140_write_vec4 :: (buf: [] u8, offset: int, v: [4] float32) {
    if offset < 0 || offset + 16 > buf.count return;
    local := v;
    memcpy(buf.data + offset, *local, 16);
}

// olib 里 std140 内部用 `[4][4]f32` 字面量做 transmute 目标；Jai 的 `xx` 把目标类型写在
// 变量声明上，所以这里给同一个类型起了个局部名字（不改变布局）。
MAT4_F32 :: [4][4] float32;

//@endregion
