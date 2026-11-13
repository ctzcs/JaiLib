// simple —— 游戏侧的最简入口：游戏写一个 State 和几个回调（Game_Hooks），库负责导出、
// 保存和交接。热重载时 State 整体交给新版本（按字节原样搬过去，不复制它指向的内存），
// 所以 State 里可以放动态数组、table、字符串、堆上的对象，以及 Batcher 这类需要重新创建的资源。
// 一比一移植自 olib core/hotreload/simple.odin。
//
// State 里可以放：
//   - 普通数据；
//   - 用宿主分配器分配的堆数据（回调里的 context.allocator 就是宿主的）：动态数组、table、
//     copy_string 出来的字符串、New 出来的对象。它们在新旧版本之间共用同一份内存；
//   - 资源字段（Batcher 等）：在 start 里重新创建（会覆盖整个字段），在 stop 里释放。
// State 里不能放：字符串字面量、过程指针、指向模块级变量或常量的指针——旧模块卸载后它们就失效，
//   新版本再用会崩溃。需要字符串就 copy_string；需要回调就存 ID。
// State 的字段布局改变（大小不同）时新版本会被拒绝，须提高 state_version 并重开，
//   或改用完整接口（api.jai）自己编码。
//
// Jai 侧差异（语义对齐，逐条说明做法与限制）：
//   - **每份 (State, Services) 组合的回调表**：odin 用 `@(static) hooks` + 泛型参数拿到
//     「每个组合一份静态存储」。Jai/jacket 既没有静态局部变量，也没有过程级泛型特化，
//     所以这里用一张模块级的小表 simple_store_entries，按
//     `type_info(Game_Hooks(State, Services))` 识别（每个组合的 Game_Hooks 是不同的类型，
//     它的 type_info 指针在进程内唯一且稳定）。语义不变：同一个模块里、同一个
//     State/Services 组合永远拿到同一份 hooks；每个模块（DLL）有自己的表副本。
//     限制：表容量 SIMPLE_STORE_CAPACITY（8）个组合，溢出时 simple_api 返回 false
//     （不是静默丢弃）。
//   - **导出回调**：odin 的 `simple_api` 里有嵌套 `proc "c"` 闭包（词法捕获 State/Services）。
//     jacket 的嵌套过程只能捕获编译期值，不能捕获运行期变量，所以这里把全部逻辑写成
//     **模块级过程**（simple_load / simple_unload / …，类型参数显式传 State、Services，
//     hooks 一律从 simple_store 取，跟 odin 的 `hooks := simple_store(State, Services)` 一致），
//     simple_api 里只留几个一行的 `#c_call` 适配过程，把 State/Services 这两个编译期值绑上去
//     （C ABI 里带不了类型参数）。没有运行期捕获，所以行为与 odin 的闭包相同。
//   - odin 的 `context = call.host_context^` → jacket 的 `#c_call` 过程里 `context` 不可赋值，
//     要用 `push_context call.host_context.* { ... }` 建立上下文（Raw 见每个适配过程）。
//   - odin 的 `new(Simple_Slot(State))` → `New(Simple_Slot(State))`（用当前 context 的分配器，
//     即上面 push 进来的宿主分配器）；`free(slot)` 同形。
//   - odin 的 `copy(dst, src)` → memcpy；`[]u8`/`len` → `[] u8` 的 count。
//   - odin 的 `simple_api(version, size, api, hooks)` 签名保留；Jai 里 State/Services 由
//     参数类型 `*Game_Hooks($State, $Services)` 反推（调用方不用写类型实参）。
#import "Basic";

//@region 协议

// State 里能放什么、不能放什么，见文件头。
Game_Hooks :: struct(State: Type, Services: Type) {
    // 新局初始化（必填）：第一次启动时调用；热重载时不调用，State 由旧版本交接。
    reset: (state: *State, services: *Services) -> void;
    update: (state: *State, services: *Services, dt: float64) -> void; // 必填
    render: (state: *State, services: *Services, dt: float64) -> void; // 必填
    // 每次加载版本后调用（含第一次）：创建资源。可为 null。
    start: (state: *State, services: *Services) -> void;
    // 每次卸载版本前调用（含热重载换掉旧版本）：释放这个版本的资源。可为 null。
    stop: (state: *State, services: *Services) -> void;
    // 游戏真正结束（宿主退出）时调用：释放 State 拥有的堆数据。热重载换版本时不调用。可为 null。
    drop: (state: *State, services: *Services) -> void;
    host_version: u64;  // 宿主协议版本，0 视为 1
    state_version: u64; // State 格式版本，0 视为 1
}

// 模块私有实例。handed_off：save 被调用过，State 已交给下一个版本，卸载时不再 drop。
Simple_Slot :: struct(T: Type) {
    state: T;
    started: bool;
    handed_off: bool;
}
//@endregion

//@region 回调表

SIMPLE_STORE_CAPACITY :: 8;

Simple_Store_Entry :: struct {
    key: *void;           // type_info(Game_Hooks(State, Services))，查找用的唯一地址
    state_type: *void;    // type_info(State)，只为可读性与诊断
    services_type: *void; // type_info(Services)，同上
    hooks: *void;         // Game_Hooks(State, Services) 的地址（模块级变量，生命周期同模块）
}

simple_store_entries: [SIMPLE_STORE_CAPACITY] Simple_Store_Entry;
simple_store_count: int;

// odin: simple_store(State, Services, set)。取到（或写入）这份组合的回调表；
// set != null 时写入并返回它。表满时返回 null，调用方按失败处理。
simple_store :: ($State: Type, $Services: Type, set: *void = null) -> *void {
    key := cast(*void) type_info(Game_Hooks(State, Services));
    // jacket 的 `for n` 是「遍历」不是「重复 n 次」，所以用闭区间 0..count-1。
    for 0..simple_store_count - 1 {
        if simple_store_entries[it].key == key {
            if set != null simple_store_entries[it].hooks = set;
            return simple_store_entries[it].hooks;
        }
    }
    if set == null return null;
    if simple_store_count >= SIMPLE_STORE_CAPACITY {
        print("hotreload: too many State/Services combinations (max %)\n", SIMPLE_STORE_CAPACITY,
              to_standard_error = true);
        return null;
    }
    simple_store_entries[simple_store_count].key = key;
    simple_store_entries[simple_store_count].state_type = cast(*void) type_info(State);
    simple_store_entries[simple_store_count].services_type = cast(*void) type_info(Services);
    simple_store_entries[simple_store_count].hooks = set;
    simple_store_count += 1;
    return set;
}
//@endregion

//@region 回调实现（模块级；类型参数显式传，hooks 从 simple_store 取）

// 交接与生命周期见 api.jai 的注释：load 只建候选状态，失败也会调用 unload。
simple_load :: ($State: Type, $Services: Type, call: *Call, snapshot: Snapshot) -> bool {
    hooks := cast(*Game_Hooks(State, Services)) simple_store(State, Services);
    if hooks == null return false;
    slot := New(Simple_Slot(State));
    call.instance = slot;
    services := cast(*Services) call.services;
    if snapshot.version == 0 {
        hooks.reset(*slot.state, services);
    } else {
        if snapshot.data.count != size_of(State) return false;
        memcpy(*slot.state, snapshot.data.data, size_of(State));
    }
    if hooks.start != null hooks.start(*slot.state, services);
    slot.started = true;
    return true;
}

simple_unload :: ($State: Type, $Services: Type, call: *Call) {
    hooks := cast(*Game_Hooks(State, Services)) simple_store(State, Services);
    slot := cast(*Simple_Slot(State)) call.instance;
    if slot == null return;
    services := cast(*Services) call.services;
    if slot.started {
        if hooks != null {
            if hooks.stop != null hooks.stop(*slot.state, services);
            if hooks.drop != null && !slot.handed_off hooks.drop(*slot.state, services);
        }
    }
    free(slot);
}

simple_snapshot_size :: ($State: Type, call: *Call) -> int {
    return size_of(State);
}

// 交接：把 State 的字节交给下一个版本，不复制它指向的内存，所以旧版本卸载时不能释放它们。
simple_save :: ($State: Type, call: *Call, destination: [] u8) -> bool {
    slot := cast(*Simple_Slot(State)) call.instance;
    if slot == null || destination.count != size_of(State) return false;
    memcpy(destination.data, *slot.state, size_of(State));
    slot.handed_off = true;
    return true;
}

simple_update :: ($State: Type, $Services: Type, call: *Call, dt: float64) {
    hooks := cast(*Game_Hooks(State, Services)) simple_store(State, Services);
    slot := cast(*Simple_Slot(State)) call.instance;
    if hooks == null || slot == null return;
    // 仍在运行说明交接没有发生（新版本被拒绝），State 仍归本版本。
    slot.handed_off = false;
    hooks.update(*slot.state, cast(*Services) call.services, dt);
}

simple_render :: ($State: Type, $Services: Type, call: *Call, dt: float64) {
    hooks := cast(*Game_Hooks(State, Services)) simple_store(State, Services);
    slot := cast(*Simple_Slot(State)) call.instance;
    if hooks == null || slot == null return;
    hooks.render(*slot.state, cast(*Services) call.services, dt);
}
//@endregion

//@region 导出

// 在导出函数里直接返回它；hooks 须在整个模块生命周期内有效（用模块级变量）：
//
//   hooks := reload.Game_Hooks(State, Services).{
//       reset = reset, update = update, render = render,
//       start = start, stop = stop, drop = drop, host_version = HOST_VERSION,
//   };
//
//   // 导出过程自己也是 #c_call：没有 context，所以先把上下文借进来。
//   get_api :: (version: u32, size: int, api: *API) -> bool #c_call {
//       ok := false;
//       push_context module_context { ok = reload.simple_api(version, size, api, *hooks); }
//       return ok;
//   }
simple_api :: (version: u32, size: int, api: *API, hooks: *Game_Hooks($State, $Services)) -> bool {
    if version != API_VERSION || size != size_of(API) return false;
    if hooks == null || hooks.reset == null || hooks.update == null || hooks.render == null {
        return false;
    }
    if simple_store(State, Services, cast(*void) hooks) == null return false;

    // C ABI 带不了类型参数，所以每个导出回调都是一个把 (State, Services) 绑上去的适配过程；
    // 真正的实现在上面的模块级过程里，hooks 一律从 simple_store 取。
    load :: (call: *Call, snapshot: Snapshot) -> bool #c_call {
        result := false;
        push_context call.host_context.* {
            result = simple_load(State, Services, call, snapshot);
        }
        return result;
    }
    unload :: (call: *Call) #c_call {
        push_context call.host_context.* {
            simple_unload(State, Services, call);
        }
    }
    snapshot_size :: (call: *Call) -> int #c_call {
        size := 0;
        push_context call.host_context.* {
            size = simple_snapshot_size(State, call);
        }
        return size;
    }
    save :: (call: *Call, destination: [] u8) -> bool #c_call {
        result := false;
        push_context call.host_context.* {
            result = simple_save(State, call, destination);
        }
        return result;
    }
    on_update :: (call: *Call, dt: float64) #c_call {
        push_context call.host_context.* {
            simple_update(State, Services, call, dt);
        }
    }
    on_render :: (call: *Call, dt: float64) #c_call {
        push_context call.host_context.* {
            simple_render(State, Services, call, dt);
        }
    }

    host_version := hooks.host_version;
    if host_version == 0 host_version = 1;
    state_version := hooks.state_version;
    if state_version == 0 state_version = 1;
    api.* = API.{
        host_version = host_version,
        state_version = state_version,
        load = load,
        unload = unload,
        snapshot_size = snapshot_size,
        save = save,
        update = on_update,
        render = on_render,
    };
    return true;
}
//@endregion
