// coroutine —— 单线程无栈协程的两种写法：把“走到哪了”存成普通数据，每帧推进。
// 一比一移植自 olib core/coroutine/coroutine.odin；状态机语义、字段、参数顺序、
// 返回语义保持一致。
//
//   Flow：检查点写法。每帧从头重入 step 过程，已过的检查点直接跳过，不用定义枚举。
//     适合短的线性序列。检查点按出现顺序编号，所以每帧走过的检查点序列必须一致：
//     - 副作用包进 flow_once，否则每帧都会执行；
//     - 分支条件先存进序列结构体，不要让 flow_wait 随条件时有时无；
//     - 增删检查点后，旧快照与存档里的 step 会错位。
//
//   Cursor(S)：枚举写法。配合 switch，步骤有名字，漏写分支编译报错。
//     适合有分支、循环或需要存档的序列。新步骤加在枚举末尾，或显式写枚举值。
//     泛型参数上不能用隐式枚举选择子：写 Door_Step.Swing，不写 .Swing。
//
// 包不做调度、不存 proc 指针、不分配：序列是不含指针的值类型，由游戏放进普通数组，
// 自己遍历推进、完成后移除；嵌套就是把子序列作为字段，在父序列里调用它的 step。
// 零值即从头开始。序列可直接随快照复制，但 step 过程跨帧不得持有 temp_allocator
// 的内存或实体指针（存句柄，每帧检查）。取消由序列自己清理后从数组移除。
//
// 用法（示例代码已改成 Jai 语法，块结构与 odin 版逐行对应）：
//   co :: #import "core/coroutine";
//
//   Door_Seq :: struct { flow: co.Flow; }
//
//   door_seq_step :: (seq: *Door_Seq, world: *World, dt: float32) -> bool {
//       f := *seq.flow;
//       co.flow_begin(f, dt);
//       if co.flow_wait(f, 0.5) return false;
//       if co.flow_once(f) {
//           play_sound(world, .Door);
//       }
//       t, active := co.flow_progress(f, 1.5);
//       if active {
//           world.door_angle = t * 90;
//       }
//       if co.flow_wait(f, 1.5) return false;
//       return true;
//   }
//
//   Door_Step :: enum u8 { Unlock; Swing; Done; }
//   Door_Seq :: struct { cursor: co.Cursor(Door_Step); }
//
//   door_seq_step :: (seq: *Door_Seq, world: *World, dt: float32) -> bool {
//       seq.cursor.elapsed += dt;
//       while true { // 每个分支要么 return，要么切步，否则死循环
//           if seq.cursor.step == {
//               case Door_Step.Unlock;
//                   if !co.cursor_wait(*seq.cursor, 0.5, Door_Step.Swing) return false;
//               case Door_Step.Swing;
//                   world.door_angle = co.cursor_progress(seq.cursor, 1.5) * 90;
//                   if !co.cursor_wait(*seq.cursor, 1.5, Door_Step.Done) return false;
//               case Door_Step.Done;
//                   return true;
//           }
//       }
//       return true;
//   }
//
// Jai 侧差异（行为不变，逐条对应上面的 odin 写法）：
//   - 没有 switch：枚举分派用 `if x == { case .A; ... }`（见上例），枚举成员写全名；
//   - 没有 odin 的 `^T`：指针类型写 `*T`，取址写 `*x`（对应 odin 的 `&x`）；传值参数
//     可以直接接指针（写 cursor_progress(c, ...)，不必像 odin 那样显式解引用 c^），
//     指针成员访问也自动解引用；
//   - int 字面量不自动转 float32：凡与 float32 混算的位置都显式 cast 或把字面量写在
//     右侧（`t * 90`）；
//   - Cursor 在 odin 里带 `where intrinsics.type_is_enum(S)` 约束，Jai 的泛型结构体
//     无法表达类型约束，这里去掉；误传非枚举类型时不会在声明处报错，而是在用到比较/
//     分派的地方报错（约束只是提示，运行时语义不受影响）；
//   - flow_progress 的具名返回值 (t, active) 在 Jai 里只能匿名写 `-> (float32, bool)`，
//     名字保留在注释里；调用处 Jai 的 if 初始化不支持同时声明多个变量，所以拆成
//     `t, active := co.flow_progress(...)` + `if active { }`，语义相同；
//   - 枚举零值仍是第一个枚举成员（与 odin 一致），Cursor 零值即从第一步开始。
#import "Basic";
#import "Math";

//@region Flow —— 检查点写法

Flow :: struct {
    step: s32; // 已完成的检查点数
    at: s32; // 本次重入走到第几个检查点，由 flow_begin 重置
    elapsed: float32; // 当前检查点已等待的时间
}

// 每次重入 step 过程时最先调用一次。
flow_begin :: (f: *Flow, dt: float32) {
    f.at = 0;
    f.elapsed += dt;
}

// 只执行一次的动作：第一次走到时返回 true。
flow_once :: (f: *Flow) -> bool {
    at := f.at;
    f.at += 1;
    if at != f.step return false;
    f.step += 1;
    return true;
}

// 等待 seconds，多出的时间带入下一个检查点。返回 true 表示还要等，调用方应 return。
flow_wait :: (f: *Flow, seconds: float32) -> bool {
    at := f.at;
    f.at += 1;
    if at < f.step return false;
    if f.elapsed < seconds return true;
    f.step += 1;
    f.elapsed -= seconds;
    return false;
}

// 等条件成立，成立后清零计时。返回 true 表示还要等，调用方应 return。
// cond 每次重入都会求值，等子序列时子序列完成后仍会被调用，须保持返回 true。
flow_until :: (f: *Flow, cond: bool) -> bool {
    at := f.at;
    f.at += 1;
    if at < f.step return false;
    if !cond return true;
    f.step += 1;
    f.elapsed = 0;
    return false;
}

// 紧接着的 flow_wait 正在等待时返回其进度（0..=1）；放在该 flow_wait 之前调用，
// 等待结束的那一次 t 为 1，末值不会丢。不占检查点。
// odin 的具名返回 (t: f32, active: bool) 在 Jai 里匿名返回，语义与调用处的
// `t, active := flow_progress(...)` 拆包一致。
flow_progress :: (f: *Flow, seconds: float32) -> (float32, bool) {
    if f.at != f.step return 0, false;
    if seconds <= 0 return 1, true;
    return min(f.elapsed / seconds, 1), true;
}
//@endregion

//@region Cursor —— 枚举写法

// elapsed 由 step 过程每次进入时自行累加 dt。
// odin 的泛型约束 `where intrinsics.type_is_enum(S)` 无法在 Jai 的泛型结构体上表达。
Cursor :: struct($S: Type) {
    step: S;
    elapsed: float32; // 当前步已经过的时间
}

// 条件满足后切步：清零计时。
cursor_enter :: (c: *Cursor($S), next: S) {
    c.step = next;
    c.elapsed = 0;
}

// 当前步满 seconds 后切到 next，多出的时间带入下一步。seconds 为 0 即瞬时步。
cursor_wait :: (c: *Cursor($S), seconds: float32, next: S) -> bool {
    if c.elapsed < seconds return false;
    c.step = next;
    c.elapsed -= seconds;
    return true;
}

// 当前步的进度（0..=1）。
cursor_progress :: (c: Cursor($S), seconds: float32) -> float32 {
    if seconds <= 0 return 1;
    return min(c.elapsed / seconds, 1);
}
//@endregion
