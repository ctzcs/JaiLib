// world:matrix4 —— System.Numerics 语义的 4x4 矩阵（3D 渲染组的地基）。
//
// 约定（与 DragonLib / Foster / Foster 着色器一致，写死为本包规范）：
//   - 行向量变换：v' = v * M（Vector4.Transform 语义）；
//   - 存储为 4 个列向量 c0..c3，c_j 即输出分量 j 的系数向量
//     （对应 System.Numerics 的 M11/M21/M31/M41 一列）；
//   - 透视深度 [0,1]（D3D/Vulkan/Metal，SDL GPU 全系），近平面即 c2。
//
// 不用 Math 的 Matrix4：它是列向量约定（M*v），与上面相反。
//
// Jai 侧差异（行为不变，逐条对应 olib 的写法）：
//   | olib (Odin)                        | JaiLib (Jai)                                     |
//   | foster.Vec3                        | Vec3（= Math.Vector3 的类型别名，见下）           |
//   | foster.Vec2                        | Vec2（= Math.Vector2 的类型别名）                 |
//   | foster.Vec3{x, y, z}               | Vec3.{ x, y, z }（Jai 结构体字面量）              |
//   | Vec4 :: [4]f32                     | Vec4 :: [4] float32（同形，不改）                 |
//   | Matrix4{...}（4 个 Vec4 列）        | Matrix4.{ .[...], .[...], .[...], .[...] }        |
//   | Vec4{x, y, z, w}                   | vec4(x, y, z, w)（Jai 数组字面量不能带类型前缀）    |
//   | math.PI（f64 常量隐式转 f32）       | JM.PI64（同为 f64 常量，由 cast(float32) 收窄）  |
//   | math.INF_F32                       | FLOAT32_INFINITY                                 |
//   | math.is_nan / math.is_inf          | JM.isnan / JM.isinf                              |
//   | math.abs / math.sqrt / math.tan    | abs（Basic）/ JM.sqrt / JM.tan                 |
//   | switch col { case 0: ... }         | if col == { case 0; ... }（if-switch）            |
//   | for i in 0..<4                     | for i: 0..3（Jai 的 a..b 含终点）                 |
//   | transmute([4][4]f32)m              | Jai 无对应 transmute 写法：经 matrix4_c 取列后逐分量累加 |
//   | 过程内嵌套 proc at                 | 提到模块级 matrix4_inverse_at                    |
//   | a == b（[4]f32 逐元素）            | vec4_equal(a, b)（Jai 的数组不能用 ==）           |
//   | 结构体默认逐字段 ==                | matrix4_equal + operator ==（Jai 要求显式定义）   |
//   | @(private)                         | 去掉标注（Jai 无等价物），内部过程加 matrix4_ 前缀 |
#import "Basic";

//@region 类型 —— Vec3 / Vec2 / Vec4 / Matrix4

// olib 的 foster.Vec3 / foster.Vec2：jacket Math 的 Vector3 / Vector2，字段 .x/.y/.z，
// 另有 .component 数组视图（axis 循环用）。别名不引入新类型，只是让本包读起来
// 与 olib 的 foster.Vec3 一致。
Vec3 :: JM.Vector3;
Vec2 :: JM.Vector2;

Vec4 :: [4] float32;

Matrix4 :: struct {
    c0, c1, c2, c3: Vec4; // 列向量：c_j = 输出分量 j 的系数
}

MATRIX4_IDENTITY :: Matrix4.{
    .[1, 0, 0, 0],
    .[0, 1, 0, 0],
    .[0, 0, 1, 0],
    .[0, 0, 0, 1],
};

// olib 的 `Vec4{x, y, z, w}`：Jai 的数组字面量不能带类型前缀（`Vec4.[...]` 不合法），
// 用构造过程代替；`.[x, y, z, w]` 在有期望类型时也等价。
vec4 :: (x: float32, y: float32, z: float32, w: float32) -> Vec4 {
    return .[x, y, z, w];
}

// olib 里 Vec4 / Vec3 / Vec2 / Matrix4 用 `==` 直接比：Jai 的数组不能用 ==，
// 结构体比较要显式 operator ==，所以这里给出显式过程，语义与 Odin 的逐元素
// == 相同（含 IEEE NaN：NaN 与自身不等）。
vec2_equal :: (a: Vec2, b: Vec2) -> bool {
    return a.x == b.x && a.y == b.y;
}

vec3_equal :: (a: Vec3, b: Vec3) -> bool {
    return a.x == b.x && a.y == b.y && a.z == b.z;
}

vec4_equal :: (a: Vec4, b: Vec4) -> bool {
    return a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3];
}

matrix4_equal :: (a: Matrix4, b: Matrix4) -> bool {
    return vec4_equal(a.c0, b.c0) && vec4_equal(a.c1, b.c1) &&
           vec4_equal(a.c2, b.c2) && vec4_equal(a.c3, b.c3);
}

// 逐列比较（Jai 不自动为结构体生成 ==）。跨模块调用要写 W.operator ==(a, b)
// 或直接用 matrix4_equal —— Jai 的运算符按词法作用域解析。
operator == :: (a: Matrix4, b: Matrix4) -> bool {
    return matrix4_equal(a, b);
}
//@endregion

//@region 构造 —— translation / scaling / look_at / projection

matrix4_translation :: (x: float32, y: float32, z: float32) -> Matrix4 {
    // 行向量约定：平移在 row4 -> 各列的第 4 分量
    return Matrix4.{
        .[1, 0, 0, x],
        .[0, 1, 0, y],
        .[0, 0, 1, z],
        .[0, 0, 0, 1],
    };
}

matrix4_scaling :: (x: float32, y: float32, z: float32) -> Matrix4 {
    return Matrix4.{
        .[x, 0, 0, 0],
        .[0, y, 0, 0],
        .[0, 0, z, 0],
        .[0, 0, 0, 1],
    };
}

// 右手系 look-at（System.Numerics CreateLookAt 语义）：
// 相机看向 -Z；z 轴 = normalize(eye - target)。
matrix4_look_at :: (eye: Vec3, target: Vec3, up: Vec3) -> Matrix4 {
    z := v3_normalize(v3_sub(eye, target));
    if vec3_equal(z, Vec3.{ 0, 0, 0 }) {
        return MATRIX4_IDENTITY;
    }
    x := v3_normalize(v3_cross(up, z));
    if vec3_equal(x, Vec3.{ 0, 0, 0 }) {
        // up 与视线平行：换一个不正交的基
        x = v3_normalize(v3_cross(Vec3.{ 0, 0, 1 }, z));
        if vec3_equal(x, Vec3.{ 0, 0, 0 }) {
            x = Vec3.{ 1, 0, 0 };
        }
    }
    y := v3_cross(z, x);

    // 行向量约定：h_j = dot(v-eye, basis_j) -> 列 j = (basis_j, -dot(basis_j, eye))
    tx := -v3_dot(x, eye);
    ty := -v3_dot(y, eye);
    tz := -v3_dot(z, eye);
    return Matrix4.{
        .[x.x, x.y, x.z, tx],
        .[y.x, y.y, y.z, ty],
        .[z.x, z.y, z.z, tz],
        .[0, 0, 0, 1],
    };
}

// 从四元数（xyzw）构造旋转矩阵（System.Numerics CreateFromQuaternion 语义）。
matrix4_from_quaternion :: (q: [4] float32) -> Matrix4 {
    xx, yy, zz := q[0] * q[0], q[1] * q[1], q[2] * q[2];
    xy, xz, yz := q[0] * q[1], q[0] * q[2], q[1] * q[2];
    wx, wy, wz := q[3] * q[0], q[3] * q[1], q[3] * q[2];

    return Matrix4.{
        .[1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy), 0],
        .[2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx), 0],
        .[2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy), 0],
        .[0, 0, 0, 1],
    };
}

// 从 System.Numerics 布局的 16 元素（M11..M44 行主序）构造（dasset 的
// InverseBindMatrix 即此布局）。
matrix4_from_row_major :: (m: [16] float32) -> Matrix4 {
    result: Matrix4;
    for j: 0..3 {
        for i: 0..3 {
            matrix4_set(*result, j, i, m[i * 4 + j]);
        }
    }
    return result;
}

// 透视投影（垂直 FOV，D3D 深度 [0,1]）。
// fov 弧度钳到 (0.1, π-0.1)；near 钳到 >= 0.001；far >= near + 0.001。
matrix4_perspective_fov :: (fov_: float32, aspect: float32, near_: float32, far_: float32) -> Matrix4 {
    fov := clamp(fov_, cast(float32) 0.1, cast(float32) (JM.PI64 - 0.1));
    near := max(near_, cast(float32) 0.001);
    far := max(far_, near + cast(float32) 0.001);

    sy := 1.0 / JM.tan(fov * 0.5);
    sx := sy / aspect;
    // 右手系（look_at 看 -Z，眼前 z<0）：h_w = -z，深度 [0,1]
    zz := -far / (far - near);
    zw := -near * far / (far - near);

    return Matrix4.{
        .[sx, 0, 0, 0],
        .[0, sy, 0, 0],
        .[0, 0, zz, zw],
        .[0, 0, -1, 0],
    };
}

// 中心正交投影：RH、相机朝 -Z、深度 [0,1]；width/height 必须有限且 >0。
// near/far 是相机前方距离，0<=near<far。非法或不可表示时返回 identity,false。
matrix4_orthographic :: (width: float32, height: float32, near: float32, far: float32) -> (Matrix4, bool) {
    if width <= 0 || height <= 0 {
        return MATRIX4_IDENTITY, false;
    }
    return matrix4_orthographic_off_center(-width / 2, width / 2, -height / 2, height / 2, near, far);
}

// 行向量 v*M，存储为列 c0..c3。left/right、bottom/top 映射至 NDC -1/+1；
// 允许反向端点以显式翻转轴（例如 top=0,bottom=height），不隐含屏幕 Y 方向。
// z=-near -> 0，z=-far -> 1。端点相等、非有限或 near/far 非法均拒绝。
matrix4_orthographic_off_center :: (
    left: float32, right: float32, bottom: float32, top: float32, near: float32, far: float32,
) -> (Matrix4, bool) {
    bounds : [6] float32 = .[left, right, bottom, top, near, far];
    for value: bounds {
        if JM.isnan(value) || JM.isinf(value) {
            return MATRIX4_IDENTITY, false;
        }
    }
    if left == right || bottom == top || near < 0 || far <= near {
        return MATRIX4_IDENTITY, false;
    }
    // f64 中间值防止有限 f32 端点的和/差溢出；最终仍按本包 f32 ABI 输出。
    dx := cast(float64) right - cast(float64) left;
    dy := cast(float64) top - cast(float64) bottom;
    dz := cast(float64) far - cast(float64) near;
    result := Matrix4.{
        .[cast(float32) (2 / dx), 0, 0,
          cast(float32) (-(cast(float64) right + cast(float64) left) / dx)],
        .[0, cast(float32) (2 / dy), 0,
          cast(float32) (-(cast(float64) top + cast(float64) bottom) / dy)],
        .[0, 0, cast(float32) (-1 / dz), cast(float32) (-cast(float64) near / dz)],
        .[0, 0, 0, 1],
    };
    columns : [4] Vec4 = .[result.c0, result.c1, result.c2, result.c3];
    for column: columns {
        for value: column {
            if JM.isnan(value) || JM.isinf(value) {
                return MATRIX4_IDENTITY, false;
            }
        }
    }
    if result.c0[0] == 0 || result.c1[1] == 0 || result.c2[2] == 0 {
        return MATRIX4_IDENTITY, false;
    }
    return result, true;
}
//@endregion

//@region 运算 —— multiply / inverse

// 复合矩阵 a*b：行向量约定下先应用 a 再应用 b。
matrix4_multiply :: (a: Matrix4, b: Matrix4) -> Matrix4 {
    // 按存储直接索引（[列][分量]），不逐元素调用 matrix4_c；累加顺序不变，结果逐位相同。
    result: Matrix4;
    for j: 0..3 {
        // b 的列 j（olib 的 bc[j]）
        bj := matrix4_c(b, j);
        for i: 0..3 {
            // a 的行 i = 各列 c_k 的第 i 分量；b 的列 j
            matrix4_set(*result, j, i,
                a.c0[i] * bj[0] + a.c1[i] * bj[1] + a.c2[i] * bj[2] + a.c3[i] * bj[3]);
        }
    }
    return result;
}

// 一般 4x4 求逆（伴随法）。不可逆返回 identity + false。
matrix4_inverse :: (m: Matrix4) -> (Matrix4, bool) {
    // m[row][col]：行 r 列 c 的元素（olib 的嵌套 proc at）
    a00 := matrix4_inverse_at(m, 0, 0); a01 := matrix4_inverse_at(m, 0, 1);
    a02 := matrix4_inverse_at(m, 0, 2); a03 := matrix4_inverse_at(m, 0, 3);
    a10 := matrix4_inverse_at(m, 1, 0); a11 := matrix4_inverse_at(m, 1, 1);
    a12 := matrix4_inverse_at(m, 1, 2); a13 := matrix4_inverse_at(m, 1, 3);
    a20 := matrix4_inverse_at(m, 2, 0); a21 := matrix4_inverse_at(m, 2, 1);
    a22 := matrix4_inverse_at(m, 2, 2); a23 := matrix4_inverse_at(m, 2, 3);
    a30 := matrix4_inverse_at(m, 3, 0); a31 := matrix4_inverse_at(m, 3, 1);
    a32 := matrix4_inverse_at(m, 3, 2); a33 := matrix4_inverse_at(m, 3, 3);

    b00 := a00 * a11 - a01 * a10;
    b01 := a00 * a12 - a02 * a10;
    b02 := a00 * a13 - a03 * a10;
    b03 := a01 * a12 - a02 * a11;
    b04 := a01 * a13 - a03 * a11;
    b05 := a02 * a13 - a03 * a12;
    b06 := a20 * a31 - a21 * a30;
    b07 := a20 * a32 - a22 * a30;
    b08 := a20 * a33 - a23 * a30;
    b09 := a21 * a32 - a22 * a31;
    b10 := a21 * a33 - a23 * a31;
    b11 := a22 * a33 - a23 * a32;

    det := b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
    if JM.abs(det) <= cast(float32) 1.0e-12 {
        return MATRIX4_IDENTITY, false;
    }
    inv := 1.0 / det;

    result: Matrix4;
    // row 0
    matrix4_set(*result, 0, 0, (a11 * b11 - a12 * b10 + a13 * b09) * inv);
    matrix4_set(*result, 1, 0, -(a01 * b11 - a02 * b10 + a03 * b09) * inv);
    matrix4_set(*result, 2, 0, (a31 * b05 - a32 * b04 + a33 * b03) * inv);
    matrix4_set(*result, 3, 0, -(a21 * b05 - a22 * b04 + a23 * b03) * inv);
    // row 1
    matrix4_set(*result, 0, 1, -(a10 * b11 - a12 * b08 + a13 * b07) * inv);
    matrix4_set(*result, 1, 1, (a00 * b11 - a02 * b08 + a03 * b07) * inv);
    matrix4_set(*result, 2, 1, -(a30 * b05 - a32 * b02 + a33 * b01) * inv);
    matrix4_set(*result, 3, 1, (a20 * b05 - a22 * b02 + a23 * b01) * inv);
    // row 2
    matrix4_set(*result, 0, 2, (a10 * b10 - a11 * b08 + a13 * b06) * inv);
    matrix4_set(*result, 1, 2, -(a00 * b10 - a01 * b08 + a03 * b06) * inv);
    matrix4_set(*result, 2, 2, (a30 * b04 - a31 * b02 + a33 * b00) * inv);
    matrix4_set(*result, 3, 2, -(a20 * b04 - a21 * b02 + a23 * b00) * inv);
    // row 3
    matrix4_set(*result, 0, 3, -(a10 * b09 - a11 * b07 + a12 * b06) * inv);
    matrix4_set(*result, 1, 3, (a00 * b09 - a01 * b07 + a02 * b06) * inv);
    matrix4_set(*result, 2, 3, -(a30 * b03 - a31 * b01 + a32 * b00) * inv);
    matrix4_set(*result, 3, 3, (a20 * b03 - a21 * b01 + a22 * b00) * inv);
    return result, true;
}
//@endregion

//@region transform

// 变换 Vec4（不做透视除法）。w' = 0 的方向向量同样适用。
// 行向量变换：h_j = dot(v, c_j)（列 j 即输出分量 j 的系数向量）。
matrix4_transform_vec4 :: (m: Matrix4, v: Vec4) -> Vec4 {
    return .[
        v[0] * m.c0[0] + v[1] * m.c0[1] + v[2] * m.c0[2] + v[3] * m.c0[3],
        v[0] * m.c1[0] + v[1] * m.c1[1] + v[2] * m.c1[2] + v[3] * m.c1[3],
        v[0] * m.c2[0] + v[1] * m.c2[1] + v[2] * m.c2[2] + v[3] * m.c2[3],
        v[0] * m.c3[0] + v[1] * m.c3[1] + v[2] * m.c3[2] + v[3] * m.c3[3],
    ];
}

// 变换点（w=1，含透视除法）。w≈0 时返回 false。
matrix4_transform_point :: (m: Matrix4, p: Vec3) -> (Vec3, bool) {
    h := matrix4_transform_vec4(m, vec4(p.x, p.y, p.z, 1));
    if JM.abs(h[3]) < cast(float32) 1.0e-8 {
        return Vec3.{ 0, 0, 0 }, false;
    }
    return Vec3.{ h[0] / h[3], h[1] / h[3], h[2] / h[3] }, true;
}

// 变换方向（w=0，不做透视除法）。
matrix4_transform_vector :: (m: Matrix4, v: Vec3) -> Vec3 {
    h := matrix4_transform_vec4(m, vec4(v.x, v.y, v.z, 0));
    return Vec3.{ h[0], h[1], h[2] };
}
//@endregion

//@region 向量辅助 —— v3 点积/叉积/归一化

v3_dot :: (a: Vec3, b: Vec3) -> float32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

v3_cross :: (a: Vec3, b: Vec3) -> Vec3 {
    return Vec3.{
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    };
}

v3_sub :: (a: Vec3, b: Vec3) -> Vec3 {
    return Vec3.{ a.x - b.x, a.y - b.y, a.z - b.z };
}

v3_normalize :: (v: Vec3) -> Vec3 {
    l := JM.sqrt(v3_dot(v, v));
    if l <= cast(float32) 1.0e-10 {
        return Vec3.{ 0, 0, 0 };
    }
    return Vec3.{ v.x / l, v.y / l, v.z / l };
}
//@endregion

//@region 内部 —— 取列 / 写元素

matrix4_set :: (m: *Matrix4, col: int, row: int, v: float32) {
    if col == {
        case 0; m.c0[row] = v;
        case 1; m.c1[row] = v;
        case 2; m.c2[row] = v;
        case 3; m.c3[row] = v;
    }
}

// 取第 col（0..3）列（系数向量）。
matrix4_column :: (m: Matrix4, col: int) -> Vec4 {
    return matrix4_c(m, col);
}

matrix4_c :: (m: Matrix4, col: int) -> Vec4 {
    if col == {
        case 0; return m.c0;
        case 1; return m.c1;
        case 2; return m.c2;
        case;   return m.c3;
    }
}

// olib 的嵌套 proc at（Jai 的过程里不能嵌套过程）。
matrix4_inverse_at :: (x: Matrix4, row: int, col: int) -> float32 {
    return matrix4_c(x, col)[row];
}
//@endregion
