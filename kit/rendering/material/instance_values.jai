// material:instance_values —— 每个实例的 [Instance] 字段数值：按槽位（字段在 Shader 里声明的先后）
// 存放的小数组。一比一移植自 olib kit/rendering/material/instance_values.odin。
//
// 它是实例化合批的数据来源，也是唯一的"每实例值"形态：
//   - 逐个绘制时用 Instance_Values 给这一次绘制的实例设值（sprite_draw 的 values 参数）；
//   - 缓冲里的大批量实例用平铺的 [][4]f32（每个实例 slots 个，见 instance_array_set），
//     长度由调用方的槽数决定。
// 名字只用来解析成句柄（instance_slot），之后全部按槽位赋值，没有字符串比较。
//
// Jai 侧差异（逐条对应 olib 的写法，数值与位模式不变）：
//   | olib (Odin)                                | JaiLib (Jai)                                         |
//   | ------------------------------------------ | ---------------------------------------------------- |
//   | `math.is_nan / math.is_inf`                | `JM.isnan / JM.isinf`                                |
//   | `math.clamp(x, lo, hi)`                    | `clamp(x, lo, hi)`（Basic）                          |
//   | `value: ..f32` 变参 + `copy(dst[:], value)` | `value: ..float32` 变参与 `memcpy(dst, value.data, n)`|
//   | `arr[i] = {}`（数组清零）                    | `memset(*arr[i], 0, 4 * size_of(float32))`            |
//   | `copy(out[:n], table.values[:n])`          | `memcpy(out.data, table.values, n * size_of(float32))`|
//   | `for slot in 0..<min(a, b)`                | `for slot: 0..min(a, b) - 1`（Jai 的 a..b 含终点）     |
//   | `set &~ fixed`                             | `set & ~fixed`（同形：~ 是按位取反）                   |
//   | `u32(slot.index)`                          | `cast(u32) slot.index`（Jai 的位移要求 u32 右值）      |
//   | `1 << u32(M)`（1 为 u32）                   | `MATERIAL_PROBE_BIT(M)`：Jai 的 `1` 是 s64，位移前先 cast |
//   | `^Instance_Values`（指针参数）               | `*Instance_Values`（Jai 的取地址就是 `*`）             |
//   | `@(private)`                               | 去掉标注，内部过程加 instance_ / value_ 前缀            |
#import "Basic";

//@region 槽位与覆盖值

// 字段名解析出的句柄。valid=false 表示材质里没有这个 [Instance] 字段（或各参数组里槽位不一致）。
Instance_Slot :: struct {
    index: int;
    valid: bool;
}

// 带掩码的槽位数组：逐个绘制的覆盖，以及材质回调拿到的一个 Pass 的实例数值。
// set 的第 i 位为 1 表示第 i 个槽位被显式设置，没设置的槽位沿用材质里保存的值。
Instance_Values :: struct {
    count: int; // 回调里：该 Pass 的 [Instance] 字段数；0 表示没有这类字段
    numbers: [sh.MAX_INSTANCE_FIELDS][4] float32; // 下标是 Instance_Slot.index，每个槽一个 float4
    set: u32;
}

// olib 的 `1 << u32(i)`：Jai 的无类型整数字面量是 s64，位移前先 cast 到 u32 才不溢出。
MATERIAL_PROBE_BIT :: inline (index: int) -> u32 {
    return cast(u32) 1 << cast(u32) index;
}

// 解析 [Instance] 字段的槽位：在每个参数组里按声明顺序数出它是第几个实例字段。
// 材质加载后调用一次并保存句柄，大批量赋值时不再查字符串。
instance_slot :: (material: *Material, field: string) -> Instance_Slot {
    if material == null || material.shader == null return Instance_Slot.{};
    found := false;
    index := 0;
    for schema: material.shader.schemas {
        rank := 0;
        for f: schema.fields {
            if !f.instance continue;
            if f.id == field {
                if found && index != rank return Instance_Slot.{}; // 不同参数组里槽位不一致，无法用同一个句柄
                found, index = true, rank;
            }
            rank += 1;
        }
    }
    return Instance_Slot.{ index = index, valid = found };
}

// 材质 Shader 的 [Instance] 字段数，即实例缓冲每个实例的槽数（sprite_buffer_init / model_buffer_init 用它）。
// 材质未加载返回 0；各参数组的字段数不一致时返回 -1（与 instance_slot 的规则一致，无法共用一个缓冲布局）。
instance_slot_count :: (material: *Material) -> int {
    if material == null || material.shader == null return 0;
    count := -1;
    for schema: material.shader.schemas {
        n := sh.instance_count(schema);
        if count >= 0 && n != count return -1;
        count = n;
    }
    return max(count, 0);
}

// 写平铺数组里第 index 个实例的一个字段：values 里每个实例连续占 slots 个 float4，按实例顺序排列
// （缓冲上传的 values 参数就是这个布局，长度 = 实例数 × slots）。
// value 依次是 x、y、z、w，只写用到的分量（Scalar 一个、Vector3 三个），没写的补 0；已有的 [4]f32 写成 ..v。
// 句柄无效、越界或超过 4 个分量返回 false，不写入。
instance_array_set :: (values: [][4] float32, slots: int, index: int, slot: Instance_Slot, value: ..float32) -> bool {
    if !slot.valid || slot.index < 0 || slot.index >= slots || index < 0 || value.count > 4 return false;
    at := index * slots + slot.index;
    if at >= values.count return false;
    memset(*values[at], 0, size_of(float32) * 4);
    if value.count > 0 memcpy(*values[at], value.data, value.count * size_of(float32));
    return true;
}

// 设置一个实例字段的值并记入掩码；value 的写法同 instance_array_set。句柄无效或超过 4 个分量返回 false，不写入。
instance_values_set :: (values: *Instance_Values, slot: Instance_Slot, value: ..float32) -> bool {
    if values == null || !slot.valid || slot.index < 0 || slot.index >= sh.MAX_INSTANCE_FIELDS || value.count > 4 {
        return false;
    }
    memset(*values.numbers[slot.index], 0, size_of(float32) * 4);
    if value.count > 0 memcpy(*values.numbers[slot.index], value.data, value.count * size_of(float32));
    values.set |= MATERIAL_PROBE_BIT(slot.index);
    values.count = max(values.count, slot.index + 1);
    return true;
}

// 平铺数组里一个实例的全部字段（该实例的 slots 个 float4，例如 values[i*slots .. i*slots+slots]）转成整套覆盖值：
// 每个槽位都算显式设置。超过 MAX_INSTANCE_FIELDS 的部分忽略。
instance_values_from :: (numbers: [][4] float32) -> (values: Instance_Values) {
    values.count = min(numbers.count, sh.MAX_INSTANCE_FIELDS);
    if values.count > 0 {
        memcpy(*values.numbers, numbers.data, values.count * size_of([4] float32));
    }
    values.set = MATERIAL_PROBE_BIT(values.count) - 1;
    return values;
}

//@endregion

//@region 求值表 —— 材质值与 Pass 固定值预先合好，逐实例只剩按槽覆盖与钳制

// 一个 Pass 的 [Instance] 求值表：材质值与 Pass 固定值预先合好，逐实例只剩按槽覆盖与钳制，
// 不再按名字查字段。由 instance_table_make 构建；材质 revision 变化后需要重建。
Instance_Table :: struct {
    count: int; // 槽数
    values: [sh.MAX_INSTANCE_FIELDS][4] float32; // 没有本次覆盖时的值（材质值，已套用 Pass 固定值）
    minimum, maximum: [sh.MAX_INSTANCE_FIELDS] float32;
    components: [sh.MAX_INSTANCE_FIELDS] u8;
    fixed: u32; // Pass 固定值所在的槽位：本次覆盖不改它们
}

instance_table_make :: (p: sh.Pass_Desc, b: Material_Binding) -> (table: Instance_Table) {
    for field, i: b.schema.fields {
        if !field.instance || table.count >= sh.MAX_INSTANCE_FIELDS continue;
        slot := table.count;
        table.values[slot] = b.values[i].number;
        table.minimum[slot], table.maximum[slot] = field.minimum, field.maximum;
        table.components[slot] = cast(u8) sh.components(field.kind);
        for fixed: p.values {
            if fixed.field == field.id {
                table.values[slot] = fixed.number;
                table.fixed |= MATERIAL_PROBE_BIT(slot);
            }
        }
        table.count += 1;
    }
    return table;
}

// 写出一个实例在该 Pass 的值：numbers 是本次覆盖（下标即槽位，可以比槽数短），set 标出有覆盖的槽位。
// 覆盖值按字段范围钳制，用到的分量有非有限值就忽略整个值，Pass 固定值优先；out 至少 table.count 个。
// 覆盖顺序与 material_pass_values 相同：材质值 < 本次覆盖 < Pass 固定值。
instance_table_write :: (table: *Instance_Table, numbers: [][4] float32, set: u32, out: [][4] float32) {
    if table.count > 0 {
        memcpy(out.data, *table.values, table.count * size_of([4] float32));
    }
    active := set & ~table.fixed;
    if active == 0 return;
    limit := min(table.count, numbers.count);
    for slot: 0..limit - 1 {
        if active & MATERIAL_PROBE_BIT(slot) == 0 continue;
        n := cast(int) table.components[slot];
        finite := true;
        for c: 0..n - 1 {
            finite = finite && !JM.isnan(numbers[slot][c]) && !JM.isinf(numbers[slot][c]);
        }
        if !finite continue;
        for c: 0..n - 1 {
            out[slot][c] = clamp(numbers[slot][c], table.minimum[slot], table.maximum[slot]);
        }
    }
}

//@endregion

//@region 套用覆盖值（material_pass_values 的原路径）

// 把显式设置的槽位写进 values（与 schema.fields 一一对应）：非有限数值忽略，其余按字段范围钳制。
instance_values_apply :: (overrides: *Instance_Values, schema: sh.Schema, values: [] sh.Value) {
    if overrides == null || overrides.set == 0 || values.count != schema.fields.count return;
    slot := 0;
    for f, i: schema.fields {
        if !f.instance continue;
        if slot < sh.MAX_INSTANCE_FIELDS && overrides.set & MATERIAL_PROBE_BIT(slot) != 0 {
            value_assign(f, *values[i], overrides.numbers[slot]);
        }
        slot += 1;
    }
}

// 数值字段的赋值规则：非有限数值整条忽略，其余按字段范围钳制（与 values_make 迁移时一致）。
value_assign :: (f: sh.Field, dst: *sh.Value, src: [4] float32) {
    if f.kind == .Texture return;
    for c: 0..sh.components(f.kind) - 1 {
        if JM.isnan(src[c]) || JM.isinf(src[c]) return;
    }
    for c: 0..sh.components(f.kind) - 1 {
        dst.number[c] = clamp(src[c], f.minimum, f.maximum);
    }
}

//@endregion
