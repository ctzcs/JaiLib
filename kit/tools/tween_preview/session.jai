// tween_preview:session —— 可嵌入的动效试验台。Session 拥有预览实例和轨迹，借用当前模块的案例表。
// 不读取全局输入、不编译代码、不修改源对象；dispose 必须早于卸载案例所在 DLL。
//
// 一比一移植自 olib kit/tools/tween_preview/session.odin（727 行）。公开类型/过程/字段、参数顺序、
// 默认参数与返回语义与 olib 一致；逐处退化见下表（每一条都是 Jai/编译器形态差异，不是接口发明）：
//
//   | olib (Odin)                                    | JaiLib (Jai)                                                |
//   | ---------------------------------------------- | ----------------------------------------------------------- |
//   | `Case_ID :: distinct string`（Channel/Parameter 同）| `Case_ID :: string` 等（Jai 没有 distinct，类型别名不可区分）   |
//   | `Stored_ID($T: typeid)` 泛型快照                 | 非泛型 `Stored_ID` + `id_text(*Stored_ID) -> string`         |
//   | `id_text :: proc(id: ^Stored_ID($T)) -> T`      | 同上：类型参数丢失，调用点不需要（也无法）显式实例化              |
//   | `target_id == (Target_ID{})` 结构体相等           | `target_id_equal` / `target_id_is_zero`（jacket 无结构体 ==） |
//   | `[Status]string` 消息表 + 下标取值                | `status_message(status)` 的 if 链（Jai 无 enum 下标数组）      |
//   | `math.is_nan / is_inf / ceil / floor / cos / sin`| `JM.isnan / isinf / ceil / floor / cos / sin`               |
//   | `foster.Vec2` / `foster.Color`                  | `JM.Vector2` / `F.Color`（字段 x,y / r,g,b,a，且都是小写）      |
//   | `a + b` / `a * s`（foster.Vec2 运算符）          | 逐分量写法（jacket 的 Vector2 operator 不在作用域，见 vec2_*）   |
//   | `fmt.ctprintf("%s", x)`                         | `tprint("%", x)`（jacket 的 `%` 就是唯一占位符）                 |
//   | `fmt.ctprintf("%.3f", x)`                       | `tprint("%", formatFloat(x, trailing_width = 3,               |
//   |                                                 |   zero_removal = FormatFloat.Zero_Removal.NO))`              |
//   | `fmt.ctprintf("%016x", id.high)`                | `tprint("%", formatInt(id.high, base = 16, minimum_digits = 16))`|
//   | `f32(x)` / `int(x)` / `f64(x)`                   | `cast(float32)` / `cast(int)` / `cast(float64)`（类型当函数调被拒）|
//   | `len(x)` / `x[i:j]`                             | `x.count` / 手工拼 data+count 的视图（Jai 没有 `[a:b]` 切片）    |
//   | `[dynamic]Sample` + `make/append/delete/clear`   | `[..] Sample` + `array_add` / `array_free` / `count = 0`     |
//   | `allocator: mem.Allocator` 字段                  | 删除：Jai 的 array_* 固定走 context.allocator（见下面的说明）    |
//   | `s.parameters[:len(item.parameters)]`            | 指向字段的 `[] float64` 视图（不拷贝，与 olib 同一语义）         |
//   | `for x in a..< b`                               | `for x: a..b - 1`（Jai 的 range **含右端**）                   |
//   | `imgui.Xxx(...)`（olib 的 imgui 包）             | `imgui_xxx(...)`：kit/tools/lab_imgui.jai 的包装               |
//   | `imgui.PushIDPtr(rawptr(s))`                    | `imgui_push_id_ptr(cast(*void) s)`                          |
//   | `imgui.DrawList_AddLine/AddQuad/...`            | `imgui_draw_line / imgui_draw_quad / imgui_draw_quad_filled` |
//   | `item != nil ? item.name : "…"`（三元）           | 先给默认值再 `if` 改写（Jai 没有三元）                          |
//   | 字段 `loop`                                      | 改名 `looping`（`loop` 是 Jai 的循环关键字）                    |
//   | `defer imgui.PopID()` / `defer PopClipRect()`   | 拆出内层过程 + 显式 Pop（保证与 Push 同层成对、早退不泄漏）      |
//
// 三条必须知道的行为差异（依赖库形态，不是接口变化）：
//   1. **分配器不再由 Session 保存**：olib 的 `make([dynamic]Sample, s.allocator)` / `delete` 带分配器，
//      jacket 的 array_add / array_free 只吃 context.allocator。默认（context.allocator）下与 olib 一致，
//      需要自定义分配器的宿主请在 init 前后切换 context.allocator。
//   2. **轨迹数组惰性分配**：olib 在 init 里 `make([dynamic]Sample)` 建空数组；Jai 的零值 `[..] Sample`
//      已经等价（array_add 首次追加时分配），所以 init 不再显式建表。
//   3. **`%.Nf` 的显示位数靠 formatFloat 保位**：零值保留 3/4/5 位小数，与 olib 的 `%.3f/%.4f/%.5f`
//      屏幕效果一致；差异只在极端大数的有效位数（printf 有、jacket 的十进制展开没有）。
//
// 导入由 module.jai 提供（#load 的文件共享这一层的名字）：Basic（tprint / formatFloat / formatInt /
// min / max / clamp / memcpy / array_add / array_free / array_reserve）、STRING（保留）、
// JM（Vector2 / cos / sin / floor / ceil / isnan / isinf）、ImGui（宿主负责 context 与帧）、
// F（jfoster 的 Color）、lab（../lab_imgui.jai 的 imgui_* 包装）。

//@region 案例协议与所有权

MAX_CHANNELS :: 16;
MAX_PARAMETERS :: 16;
MAX_STEPS :: 30000;

// olib: `Case_ID :: distinct string`。Jai 没有 distinct：这里退化成别名，编译期不再区分三类 ID，
// 跨类别误用（把通道书签当案例书签）由调用方自觉保证。
Case_ID :: string;
Channel_ID :: string;
Parameter_ID :: string;

// 项目定义的 128 位稳定身份；库只比较/保存，不哈希、不解释为数组下标或指针。
// 全零保留给 open 的“选择默认对象”，不能登记为实际对象 ID。
Target_ID :: struct {
    high, low: u64;
}

// olib 的 `Target_ID == Target_ID{}` 依赖 Odin 的结构体比较；jacket 没有 `operator ==` 的结构体重载，
// 所以改成两个小过程，语义相同（逐字段比较）。
target_id_equal :: (a: Target_ID, b: Target_ID) -> bool {
    return a.high == b.high && a.low == b.low;
}

target_id_is_zero :: (id: Target_ID) -> bool {
    return id.high == 0 && id.low == 0;
}

// 语义 ID 的无指针快照。olib 用 `Stored_ID($T)` 保留身份类别（不能把通道书签当案例书签）；
// Jai 的泛型结构体在这里实例化不了，退化成同一个结构 + `id_text` 返回 `string`。
Stored_ID :: struct {
    bytes: [128] u8;
    length: u32;
}

BOOKMARK_VERSION :: 2;

// 无指针的模块间书签。只恢复选择与速度，不延续模拟状态和临时参数。
Bookmark :: struct {
    version: u32;
    case_id: Stored_ID;
    target_id: Target_ID;
    channel_id: Stored_ID;
    speed: float64;
}

Target :: struct {
    id: Target_ID;
    name: string;
}

Channel :: struct {
    id: Channel_ID;
    name, unit: string;
}

Parameter :: struct {
    id: Parameter_ID;
    name: string;
    initial, minimum, maximum: float64;
}

Pose :: struct {
    position, size: JM.Vector2;
    rotation: float32;
    color: F.Color;
}

Observation :: struct {
    values: [MAX_CHANNELS] float32;
    pose: Pose;
    has_pose: bool;
}

// 坐标为 ImGui 最终输出链路的逻辑坐标，origin 为预览原点。
// 自定义绘制不得结束窗口或改变宿主渲染状态；裁剪由工具维护。
Canvas :: struct {
    draw_list: *ImGui.ImDrawList;
    origin, size: JM.Vector2;
    scale: float32;
}

// olib 把回调直接写在 Case 里（`create: proc(...)`）；jacket 的过程类型不接受 `proc(` 前缀，
// 按 kit/asset/loader.jai 的写法提成具名过程类型，调用点完全一致。
Case_Create :: (user_data: *void, target_id: Target_ID, parameters: [] float64) -> *void;
Case_Destroy :: (instance: *void);
Case_Step :: (instance: *void, dt: float64, elapsed: float64);
Case_Observe :: (instance: *void) -> Observation;
Case_Draw :: (instance: *void, canvas: Canvas);
Case_Open_Source :: (user_data: *void, path: string, line: int);

Case :: struct {
    id: Case_ID;
    name, source: string;
    source_line: int;
    duration: float64;
    targets: [] Target;
    channels: [] Channel;
    parameters: [] Parameter;
    // 项目按稳定键解析并校验源对象，再创建独立副本；不保存源对象裸指针。
    // 对象已删除/失效或创建失败时自行回收部分资源并返回 null。
    create: Case_Create;
    destroy: Case_Destroy;
    step: Case_Step;
    observe: Case_Observe;
    // null 时使用 Observation.pose 绘制矩形；无 pose 仍可查看通道。
    draw: Case_Draw;
}

Config :: struct {
    cases: [] Case;
    user_data: *void;
    fixed_dt: float64;   // 0 使用 1/120 秒；每个案例最多 MAX_STEPS 步。
    step_budget: int;    // 0 使用每帧 480 步，时间定位可跨帧完成。
    open_source: Case_Open_Source;
}

Status :: enum {
    Ready;
    Case_Missing;
    Target_Missing;
    Create_Failed;
    Invalid_Observation;
}

Sample :: struct {
    time: float64;
    observation: Observation;
}

Session :: struct {
    config: Config;
    bookmark: Bookmark;
    status: Status;
    // olib 的 `playing, seeking, loop`：`loop` 是 Jai 的循环关键字，改名 looping。
    playing, seeking, looping: bool;
    elapsed, requested_time: float64;
    parameters: [MAX_PARAMETERS] float64;
    trace: [..] Sample;
    // 以下字段由工具维护，接入方不要直接修改。
    instance: *void;
    case_index, target_index, channel_index, step_index: int;
    initialized, seek_requested: bool;
}
//@endregion

//@region 创建与选择

// 配置中的字符串、切片和函数必须保持有效至 dispose。成功后 Session 不得复制。
init :: (s: *Session, config: Config, saved := Bookmark.{}) -> string {
    if saved.version != 0 && saved.version != BOOKMARK_VERSION {
        return "不支持的预览书签版本；身份协议升级后请重启预览宿主";
    }
    if saved.version == BOOKMARK_VERSION {
        if saved.case_id.length > 128 || saved.channel_id.length > 128 {
            return "损坏的预览书签 ID 长度";
        }
        case_key := saved.case_id;
        channel_key := saved.channel_id;
        if (case_key.length > 0 && !valid_id(id_text(*case_key))) ||
            (channel_key.length > 0 && !valid_id(id_text(*channel_key))) {
            return "损坏的预览书签 ID";
        }
    }
    if s.initialized return "会话已初始化";
    c := config;
    if c.fixed_dt == 0 c.fixed_dt = 1.0 / 120.0;
    if c.step_budget == 0 c.step_budget = 480;
    if !finite(c.fixed_dt) || c.fixed_dt <= 0 || c.step_budget < 1 ||
        c.step_budget > MAX_STEPS {
        return "无效的固定步长或重演预算";
    }
    for item, i: c.cases {
        if !valid_id(item.id) || item.name == "" || !finite(item.duration) ||
            item.duration <= 0 || item.duration / c.fixed_dt > MAX_STEPS {
            return "案例 ID、名称或时长无效（最多 30000 步）";
        }
        if item.create == null || item.destroy == null || item.step == null || item.observe == null {
            return "案例缺少实例生命周期或观察回调";
        }
        if item.targets.count == 0 || item.channels.count > MAX_CHANNELS ||
            item.parameters.count > MAX_PARAMETERS {
            return "案例对象为空或通道/参数超过 16 项";
        }
        // olib: `for other in c.cases[:i]`。Jai 没有切片语法，用前缀下标循环（i == 0 时 0..-1 不迭代）。
        for k: 0..i - 1 {
            if c.cases[k].id == item.id return "重复的案例 ID";
        }
        for target, j: item.targets {
            if target_id_is_zero(target.id) || target.name == "" return "无效的对象键或名称";
            for k: 0..j - 1 {
                if target_id_equal(item.targets[k].id, target.id) return "重复的对象 ID";
            }
        }
        for channel, j: item.channels {
            if !valid_id(channel.id) || channel.name == "" return "无效的通道 ID 或名称";
            for k: 0..j - 1 {
                if item.channels[k].id == channel.id return "重复的通道 ID";
            }
        }
        for p, j: item.parameters {
            if !valid_id(p.id) || p.name == "" || !finite(p.initial) || !finite(p.minimum) ||
                !finite(p.maximum) || p.minimum > p.initial || p.initial > p.maximum {
                return "无效的临时参数定义";
            }
            for k: 0..j - 1 {
                if item.parameters[k].id == p.id return "重复的参数 ID";
            }
        }
    }
    s.* = Session.{ config = c, initialized = true, case_index = -1, target_index = -1,
                    channel_index = -1, status = Status.Case_Missing };
    s.bookmark = Bookmark.{ version = BOOKMARK_VERSION, speed = 1 };
    if saved.version == BOOKMARK_VERSION {
        s.bookmark = saved;
        if !finite(saved.speed) || saved.speed < 0.05 || saved.speed > 4 s.bookmark.speed = 1;
    }
    case_id := id_text(*s.bookmark.case_id);
    target_id := s.bookmark.target_id;
    if saved.version == 0 && c.cases.count > 0 case_id = c.cases[0].id;
    // open 会写入书签，先复制语义 ID 避免与写入区域别名。
    case_copy := make_id(case_id);
    open(s, id_text(*case_copy), target_id);
    return "";
}

dispose :: (s: *Session) {
    if !s.initialized return;
    stop_instance(s);
    array_free(s.trace);
    s.* = Session.{};
}

// 编辑器对象入口与案例列表共用此入口。全零 target_id 选择案例默认对象。
// 身份不存在时保留请求并显示缺失；格式非法的案例 ID 不改变当前选择。
open :: (s: *Session, case_id: Case_ID, target_id := Target_ID.{}) -> bool {
    if !s.initialized || !valid_id(case_id) return false;
    requested_case := make_id(case_id);
    requested_target := target_id;
    previous_case := s.bookmark.case_id;
    stop_instance(s);
    s.bookmark.case_id = requested_case;
    s.bookmark.target_id = requested_target;
    s.case_index = -1;
    s.target_index = -1;
    s.channel_index = -1;
    s.elapsed = 0;
    s.requested_time = 0;
    s.seeking = false;
    s.seek_requested = false;
    s.trace.count = 0;
    for item, i: s.config.cases {
        if item.id == id_text(*requested_case) {
            s.case_index = i;
            break;
        }
    }
    item := current_case(s);
    if item == null {
        s.status = Status.Case_Missing;
        return false;
    }
    if target_id_is_zero(requested_target) s.bookmark.target_id = item.targets[0].id;
    for target, i: item.targets {
        if target_id_equal(target.id, s.bookmark.target_id) {
            s.target_index = i;
            break;
        }
    }
    if id_text(*previous_case) != item.id s.bookmark.channel_id = Stored_ID.{};
    for channel, i: item.channels {
        if channel.id == id_text(*s.bookmark.channel_id) s.channel_index = i;
    }
    if s.channel_index < 0 && item.channels.count > 0 {
        s.channel_index = 0;
        s.bookmark.channel_id = make_id(item.channels[0].id);
    }
    reset_parameters(s);
    if s.target_index < 0 {
        s.status = Status.Target_Missing;
        return false;
    }
    return restart(s);
}

supports_target :: (item: *Case, target_id: Target_ID) -> bool {
    for target: item.targets {
        if target_id_equal(target.id, target_id) return true;
    }
    return false;
}

current_case :: (s: *Session) -> *Case {
    if !s.initialized || s.case_index < 0 || s.case_index >= s.config.cases.count return null;
    return *s.config.cases[s.case_index];
}

current_target :: (s: *Session) -> *Target {
    item := current_case(s);
    if item == null || s.target_index < 0 || s.target_index >= item.targets.count return null;
    return *item.targets[s.target_index];
}

select_channel :: (s: *Session, id: Channel_ID) -> bool {
    item := current_case(s);
    if item == null return false;
    for channel, i: item.channels {
        if channel.id == id {
            s.channel_index = i;
            s.bookmark.channel_id = make_id(id);
            return true;
        }
    }
    return false;
}

// olib 的 `id_text :: proc(id: ^Stored_ID($T)) -> T`：类型参数随 distinct 类型一起消失。
// 返回的 string 指向快照自身的 bytes（不分配、不拷贝），随快照一起失效。
id_text :: (id: *Stored_ID) -> string {
    if id.length > 128 return "";
    result: string;
    result.data = *id.bytes[0];
    result.count = id.length;
    return result;
}
//@endregion

//@region 播放与固定步长重演

restart :: (s: *Session) -> bool {
    if !reset_instance(s) return false;
    s.playing = true;
    return true;
}

set_speed :: (s: *Session, speed: float64) -> bool {
    if !finite(speed) || speed < 0.05 || speed > 4 return false;
    s.bookmark.speed = speed;
    return true;
}

// 暂停并定位。回退时间从初态重演；向前沿用同一实例；观察值只显示实际到达的时间。
seek :: (s: *Session, seconds: float64) -> bool {
    item := current_case(s);
    if item == null || s.instance == null || !finite(seconds) return false;
    target := clamp(seconds, 0.0, item.duration);
    if target < s.elapsed && !reset_instance(s) return false;
    s.playing = false;
    s.requested_time = target;
    s.seeking = target_step(s, target) > s.step_index;
    s.seek_requested = s.seeking;
    return true;
}

update :: (s: *Session, dt: float64) {
    if !s.initialized || s.instance == null || s.status != Status.Ready return;
    if !finite(dt) || dt < 0 return;
    item := current_case(s);
    if !s.playing && !s.seek_requested {
        // 暂停播放时丢弃积压；显式时间定位则允许在暂停状态下跨帧完成。
        s.requested_time = s.elapsed;
        s.seeking = false;
        return;
    }
    if s.playing && !s.seek_requested {
        // 最多积压两个循环，避免长时间挂起后无限追赶；正常跨帧不丢时。
        limit := item.duration;
        if s.looping limit = item.duration * 2;
        s.requested_time = min(s.requested_time + dt * s.bookmark.speed, limit);
    }
    for _: 0..s.config.step_budget - 1 {
        if s.elapsed >= item.duration && s.playing && s.looping && s.requested_time > item.duration {
            carry := s.requested_time - item.duration;
            if !restart(s) return;
            s.requested_time = carry;
        }
        goal := target_step(s, min(s.requested_time, item.duration));
        if s.step_index >= goal break;
        s.step_index += 1;
        next := min(cast(float64) s.step_index * s.config.fixed_dt, item.duration);
        item.step(s.instance, next - s.elapsed, next);
        s.elapsed = next;
        if !record(s) return;
    }
    s.seeking = s.step_index < target_step(s, min(s.requested_time, item.duration)) ||
        (s.looping && s.requested_time > item.duration);
    if !s.seeking s.seek_requested = false;
    if s.elapsed >= item.duration && !s.looping s.playing = false;
}

set_parameter :: (s: *Session, id: Parameter_ID, value: float64) -> bool {
    item := current_case(s);
    if item == null || !finite(value) return false;
    for p, i: item.parameters {
        if p.id != id continue;
        if value < p.minimum || value > p.maximum return false;
        if s.parameters[i] == value return true;
        s.parameters[i] = value;
        return restart(s);
    }
    return false;
}

reset_parameters :: (s: *Session) {
    item := current_case(s);
    if item == null return;
    for p, i: item.parameters s.parameters[i] = p.initial;
}

has_overrides :: (s: *Session) -> bool {
    item := current_case(s);
    if item == null return false;
    for p, i: item.parameters {
        if s.parameters[i] != p.initial return true;
    }
    return false;
}

observation :: (s: *Session) -> Observation {
    if s.trace.count == 0 return Observation.{};
    return s.trace[s.trace.count - 1].observation;
}
//@endregion

//@region 内部校验与实例管理

finite :: (value: float64) -> bool {
    return !JM.isnan(value) && !JM.isinf(value);
}

valid_id :: (id: string) -> bool {
    if id.count == 0 || id.count > 128 return false;
    for id if it == 0 return false;
    return true;
}

// olib: `make_id :: proc(text: $T/string) -> Stored_ID(T)`；泛型随 Stored_ID 一起去掉。
make_id :: (text: string) -> Stored_ID {
    result: Stored_ID;
    if text.count > 128 return result;
    if text.count > 0 memcpy(result.bytes.data, text.data, text.count);
    result.length = cast(u32) text.count;
    return result;
}

stop_instance :: (s: *Session) {
    if s.instance != null {
        s.config.cases[s.case_index].destroy(s.instance);
        s.instance = null;
    }
    s.playing = false;
}

reset_instance :: (s: *Session) -> bool {
    item := current_case(s);
    target := current_target(s);
    if item == null || target == null return false;
    stop_instance(s);
    s.trace.count = 0;
    s.elapsed = 0;
    s.requested_time = 0;
    s.step_index = 0;
    s.seeking = false;
    s.seek_requested = false;
    // olib: `s.parameters[:len(item.parameters)]`。Jai 没有切片语法，手工拼一个指向字段本身的视图：
    // 元素仍是 Session 里那份（回调改它等价于改覆盖值），不做拷贝。
    parameters: [] float64;
    parameters.data = *s.parameters[0];
    parameters.count = item.parameters.count;
    s.instance = item.create(s.config.user_data, target.id, parameters);
    if s.instance == null {
        s.status = Status.Create_Failed;
        return false;
    }
    s.status = Status.Ready;
    return record(s);
}

target_step :: (s: *Session, seconds: float64) -> int {
    duration := current_case(s).duration;
    if seconds >= duration return cast(int) JM.ceil(duration / s.config.fixed_dt);
    return cast(int) JM.floor(seconds / s.config.fixed_dt + 1.0e-9);
}

record :: (s: *Session) -> bool {
    item := current_case(s);
    o := item.observe(s.instance);
    valid := true;
    for i: 0..item.channels.count - 1 {
        valid = valid && finite(cast(float64) o.values[i]);
    }
    if o.has_pose {
        valid = valid && finite(cast(float64) o.pose.position.x) && finite(cast(float64) o.pose.position.y) &&
            finite(cast(float64) o.pose.size.x) && finite(cast(float64) o.pose.size.y) &&
            finite(cast(float64) o.pose.rotation);
    }
    if !valid {
        s.status = Status.Invalid_Observation;
        s.playing = false;
        s.seeking = false;
        return false;
    }
    array_add(*s.trace, Sample.{ time = s.elapsed, observation = o });
    return true;
}

// olib 的 `messages := [Status]string{...}` 表：Jai 没有 enum 下标数组，退化成 if 链（顺序即枚举）。
status_message :: (status: Status) -> string {
    if status == Status.Ready return "";
    if status == Status.Case_Missing return "案例不存在";
    if status == Status.Target_Missing return "对象不存在或此案例不支持该对象，请重新选择。";
    if status == Status.Create_Failed return "源对象已失效或独立实例创建失败；请重新选择对象或重播重试。";
    if status == Status.Invalid_Observation return "观察数据包含 NaN/Inf，已停止；请修复案例。";
    return "";
}
//@endregion

//@region 可嵌入面板

// 在宿主 Begin/End 内调用，不创建顶层窗口；宿主自行安排 Dock、输入与生命周期。
//
// olib 在这里用的是 `imgui.PushIDPtr` + `defer imgui.PopID()`。Jai 的 `defer` 虽然也会在提前 return
// 时触发，但把面板主体拆成 draw_panel 后 Push/Pop 的配对就是纯顺序关系，不依赖 defer 语义；
// 面板中间的 `return`（未找到案例）也不会让 ID 栈失衡。
draw :: (s: *Session) {
    if !s.initialized return;
    imgui_push_id_ptr(cast(*void) s);
    draw_panel(s);
    imgui_pop_id();
}

draw_panel :: (s: *Session) {
    item := current_case(s);
    // olib: `item != nil ? item.name : "案例不存在，请选择"`（Jai 没有三元）。
    case_label := "案例不存在，请选择";
    if item != null case_label = item.name;
    imgui_set_next_item_width(-1);
    if imgui_begin_combo("##case", tprint("动效：%", case_label)) {
        for candidate: s.config.cases {
            imgui_push_id(candidate.id);
            if imgui_selectable(candidate.name, candidate.id == id_text(*s.bookmark.case_id)) {
                open(s, candidate.id);
            }
            imgui_pop_id();
        }
        imgui_end_combo();
    }
    item = current_case(s);
    if item == null {
        imgui_text_unformatted(tprint("未找到案例 ID：%", id_text(*s.bookmark.case_id)));
        return;
    }
    target := current_target(s);
    target_label := "对象不存在，请选择";
    if target != null target_label = target.name;
    imgui_set_next_item_width(-1);
    if imgui_begin_combo("##target", tprint("对象：%", target_label)) {
        for candidate: item.targets {
            imgui_push_id(tprint("%:%",
                formatInt(candidate.id.high, base = 16, minimum_digits = 16),
                formatInt(candidate.id.low, base = 16, minimum_digits = 16)));
            if imgui_selectable(candidate.name, target_id_equal(candidate.id, s.bookmark.target_id)) {
                open(s, item.id, candidate.id);
            }
            imgui_pop_id();
        }
        imgui_end_combo();
    }
    imgui_text_unformatted(tprint("ID：% / %:%", item.id,
        formatInt(s.bookmark.target_id.high, base = 16, minimum_digits = 16),
        formatInt(s.bookmark.target_id.low, base = 16, minimum_digits = 16)));
    if item.source != "" {
        if s.config.open_source != null {
            if imgui_small_button("打开源码") {
                s.config.open_source(s.config.user_data, item.source, item.source_line);
            }
            imgui_same_line();
        }
        imgui_text_unformatted(tprint("%:%", item.source, item.source_line));
    }
    if s.status != Status.Ready {
        imgui_text_wrapped(status_message(s.status));
    }
    imgui_begin_disabled(target == null);
    if imgui_button("重播 (R)") restart(s);
    imgui_same_line();
    // olib: `imgui.Button(s.playing ? "暂停 (Space)" : "继续 (Space)")`
    toggle_label := "继续 (Space)";
    if s.playing toggle_label = "暂停 (Space)";
    if imgui_button(toggle_label) {
        if s.elapsed >= item.duration {
            restart(s);
        } else {
            s.playing = !s.playing;
        }
    }
    imgui_same_line();
    imgui_checkbox("循环", *s.looping);
    value := cast(float32) s.bookmark.speed;
    imgui_set_next_item_width(-100);
    if imgui_slider_float("播放速度", *value, 0.05, 4, "%.2fx") set_speed(s, cast(float64) value);
    time_value := cast(float32) s.requested_time;
    imgui_set_next_item_width(-100);
    if imgui_slider_float("定位时间", *time_value, 0, cast(float32) item.duration, "%.3f s") {
        seek(s, cast(float64) time_value);
    }
    play_state := "暂停 / 已结束";
    if s.seeking play_state = "重演中";
    else if s.playing play_state = "播放中";
    imgui_text_unformatted(tprint("实际 % s / % s | % | 步长 % s",
        formatFloat(s.elapsed, trailing_width = 3, zero_removal = FormatFloat.Zero_Removal.NO),
        formatFloat(item.duration, trailing_width = 3, zero_removal = FormatFloat.Zero_Removal.NO),
        play_state,
        formatFloat(s.config.fixed_dt, trailing_width = 5, zero_removal = FormatFloat.Zero_Removal.NO)));
    // olib 的标题是 cstring（"…###overrides" 里的 ### 是 ImGui 的稳定 ID 后缀）；包装层吃 string。
    override_title := "临时参数覆盖###overrides";
    if has_overrides(s) override_title = "临时参数覆盖 *（未保存）###overrides";
    if imgui_collapsing_header(override_title) {
        imgui_text_wrapped("只影响预览。切换案例/对象或热更新会清除；不改写源码或游戏内容。");
        for p, i: item.parameters {
            imgui_push_id(p.id);
            v := s.parameters[i];
            lo := p.minimum;
            hi := p.maximum;
            // olib: `imgui.SliderScalar(label, .Double, &v, &lo, &hi, "%.3f")`。
            if imgui_slider_double(p.name, *v, *lo, *hi, "%.3f") {
                set_parameter(s, p.id, v);
            }
            imgui_pop_id();
        }
        if item.parameters.count == 0 imgui_text_unformatted("此案例未提供可覆盖参数。");
        if imgui_button("恢复代码默认值并重播") {
            reset_parameters(s);
            restart(s);
        }
    }
    imgui_end_disabled();
    imgui_separator();
    avail := imgui_get_content_region_avail();
    wide := avail.x >= 850;
    width := avail.x;
    if wide width = (width - ImGui.GetStyle().ItemSpacing.x) * 0.5;
    imgui_begin_group();
    imgui_text_unformatted("独立预览 · 初态轮廓 / 运动轨迹");
    draw_viewport(s, ImGui.ImVec2.{ max(width, cast(float32) 80), 240 });
    imgui_end_group();
    if wide imgui_same_line();
    imgui_begin_group();
    if item.channels.count == 0 {
        imgui_text_unformatted("未提供通道；仍可播放和绘制独立对象。");
    } else {
        // olib 依赖 open() 的后置保证（channels 非空时 channel_index >= 0）；Jai 没有越界 panic，
        // 这里把同一个不变量显式写成一行防御，正常路径永不触发。
        if s.channel_index < 0 s.channel_index = 0;
        channel := item.channels[s.channel_index];
        imgui_set_next_item_width(max(width, cast(float32) 80));
        if imgui_begin_combo("##channel", tprint("通道：%", channel.name)) {
            for entry: item.channels {
                if imgui_selectable(tprint("%##%", entry.name, entry.id), entry.id == channel.id) {
                    select_channel(s, entry.id);
                }
            }
            imgui_end_combo();
        }
        draw_curve(s, ImGui.ImVec2.{ max(width, cast(float32) 80), 210 });
        imgui_text_unformatted(tprint("当前值 % % · 曲线为已重演区间",
            formatFloat(cast(float64) observation(s).values[s.channel_index], trailing_width = 4,
                        zero_removal = FormatFloat.Zero_Removal.NO),
            item.channels[s.channel_index].unit));
    }
    imgui_end_group();
}
//@endregion

//@region 画布与通道曲线

// 项目也可在自定义 draw 回调里复用默认形状绘制。
// olib 用 `[4]foster.Vec2` 字面量 + Vec2 运算符；Jai 的数组字面量不支持 `[4]T.{...}`，
// Vec2 的 operator 也不在作用域（要 `using JM`），所以四个角由 pose_corner 逐个算，
// 与 olib 的局部坐标 `{-h,-h} {h,-h} {h,h} {-h,h}` 与旋转公式逐项一致。
pose_corner :: (pose: Pose, canvas: Canvas, x: float32, y: float32,
                co: float32, si: float32) -> ImGui.ImVec2 {
    rotated := JM.Vector2.{ x * co - y * si, x * si + y * co };
    return ImGui.ImVec2.{
        canvas.origin.x + (pose.position.x + rotated.x) * canvas.scale,
        canvas.origin.y + (pose.position.y + rotated.y) * canvas.scale,
    };
}

draw_pose :: (canvas: Canvas, pose: Pose, outline := false) {
    half_w := pose.size.x * 0.5;
    half_h := pose.size.y * 0.5;
    co := JM.cos(pose.rotation);
    si := JM.sin(pose.rotation);
    p0 := pose_corner(pose, canvas, -half_w, -half_h, co, si);
    p1 := pose_corner(pose, canvas, half_w, -half_h, co, si);
    p2 := pose_corner(pose, canvas, half_w, half_h, co, si);
    p3 := pose_corner(pose, canvas, -half_w, half_h, co, si);
    c := pose.color;
    // foster.Color 是 RGBA8，与 ImGui 的 IM_COL32 打包顺序（R 在最低字节）一致。
    // 必须先加宽再左移：jacket 的 `cast(u32) c.g << 8` 会把 `<<` 收进 cast 里（u8 移位后高位丢光），
    // 所以每个分量都写成 `(cast(u32) x) << n`。
    color := cast(ImGui.ImU32) ((cast(u32) c.r) | ((cast(u32) c.g) << 8) |
                                ((cast(u32) c.b) << 16) | ((cast(u32) c.a) << 24));
    if outline {
        imgui_draw_quad(canvas.draw_list, p0, p1, p2, p3, color);
    } else {
        imgui_draw_quad_filled(canvas.draw_list, p0, p1, p2, p3, color);
        imgui_draw_line(canvas.draw_list, p0, p1, 0xffe8fff3, 2);
    }
}

// olib 用 `defer imgui.DrawList_PopClipRect(list)`；这里把裁剪内的绘制拆成 draw_viewport_content，
// Pop 与 Push 纯顺序配对（与 olib 一样保证早退也不泄漏裁剪栈）。
draw_viewport :: (s: *Session, size: ImGui.ImVec2) {
    p := imgui_get_cursor_screen_pos();
    imgui_dummy(size);
    list := imgui_get_window_draw_list();
    end := ImGui.ImVec2.{ p.x + size.x, p.y + size.y };
    imgui_draw_rect_filled(list, p, end, 0xff201812);
    imgui_draw_push_clip_rect(list, p, end, true);
    canvas := Canvas.{
        draw_list = list,
        origin = JM.Vector2.{ p.x + size.x * 0.5, p.y + size.y * 0.5 },
        size = JM.Vector2.{ size.x, size.y },
        scale = min(size.x / cast(float32) 640, size.y / cast(float32) 360),
    };
    draw_viewport_content(s, canvas, p, size);
    imgui_draw_pop_clip_rect(list);
}

draw_viewport_content :: (s: *Session, canvas: Canvas, p: ImGui.ImVec2, size: ImGui.ImVec2) {
    list := canvas.draw_list;
    for x: -5..5 {
        px := canvas.origin.x + cast(float32) x * 60 * canvas.scale;
        imgui_draw_line(list, ImGui.ImVec2.{ px, p.y }, ImGui.ImVec2.{ px, p.y + size.y }, 0xff332b24);
    }
    for y: -3..3 {
        py := canvas.origin.y + cast(float32) y * 60 * canvas.scale;
        imgui_draw_line(list, ImGui.ImVec2.{ p.x, py }, ImGui.ImVec2.{ p.x + size.x, py }, 0xff332b24);
    }
    if s.status != Status.Ready || s.trace.count == 0 return;
    if s.trace.count > 1 {
        for i: 1..s.trace.count - 1 {
            a := s.trace[i - 1].observation;
            b := s.trace[i].observation;
            if !a.has_pose || !b.has_pose continue;
            imgui_draw_line(list,
                ImGui.ImVec2.{ canvas.origin.x + a.pose.position.x * canvas.scale,
                               canvas.origin.y + a.pose.position.y * canvas.scale },
                ImGui.ImVec2.{ canvas.origin.x + b.pose.position.x * canvas.scale,
                               canvas.origin.y + b.pose.position.y * canvas.scale }, 0xff907854, 1.5);
        }
    }
    initial := s.trace[0].observation;
    if initial.has_pose {
        initial.pose.color = F.Color.{ 90, 110, 135, 255 };
        draw_pose(canvas, initial.pose, true);
    }
    item := current_case(s);
    if item.draw != null {
        item.draw(s.instance, canvas);
    } else {
        current := observation(s);
        if current.has_pose draw_pose(canvas, current.pose);
    }
}

draw_curve :: (s: *Session, size: ImGui.ImVec2) {
    p := imgui_get_cursor_screen_pos();
    imgui_dummy(size);
    list := imgui_get_window_draw_list();
    end := ImGui.ImVec2.{ p.x + size.x, p.y + size.y };
    imgui_draw_rect_filled(list, p, end, 0xff201812);
    if s.trace.count == 0 return;
    lo := s.trace[0].observation.values[s.channel_index];
    hi := lo;
    for sample: s.trace {
        v := sample.observation.values[s.channel_index];
        lo = min(lo, v);
        hi = max(hi, v);
    }
    padding := max((hi - lo) * 0.1, cast(float32) 0.01);
    lo -= padding;
    hi += padding;
    duration := current_case(s).duration;
    imgui_draw_push_clip_rect(list, p, end, true);
    previous := ImGui.ImVec2.{ 0, 0 };
    for sample, i: s.trace {
        point := ImGui.ImVec2.{
            p.x + cast(float32) (sample.time / duration) * size.x,
            p.y + (1 - (sample.observation.values[s.channel_index] - lo) / (hi - lo)) * size.y,
        };
        if i > 0 imgui_draw_line(list, previous, point, 0xffbce86c, 1.5);
        previous = point;
    }
    x := p.x + cast(float32) (s.elapsed / duration) * size.x;
    imgui_draw_line(list, ImGui.ImVec2.{ x, p.y }, ImGui.ImVec2.{ x, p.y + size.y }, 0xffeedab3);
    imgui_draw_text(list, ImGui.ImVec2.{ p.x + 6, p.y + 4 }, 0xffbba899,
        tprint("%", formatFloat(cast(float64) hi, trailing_width = 3,
                                zero_removal = FormatFloat.Zero_Removal.NO)));
    imgui_draw_text(list, ImGui.ImVec2.{ p.x + 6, p.y + size.y - 22 }, 0xffbba899,
        tprint("%", formatFloat(cast(float64) lo, trailing_width = 3,
                                zero_removal = FormatFloat.Zero_Removal.NO)));
    imgui_draw_pop_clip_rect(list);
}
//@endregion
