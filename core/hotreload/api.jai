// api —— 开发期游戏模块协议。宿主与模块必须使用相同协议源码、相同架构与相同编译器版本。
// 不提供跨编译器 ABI；宿主接口变化必须升级 host_version 并重启。
// 一比一移植自 olib core/hotreload/api.odin。
//
// Jai 侧差异（本文件，行为不变）：
//   - odin 的 `package hotreload` 在 Jai 里就是目录名 core/hotreload，没有 package 声明；
//   - odin 的 `proc "c"` 在 Jai 里写成过程类型尾部的 `#c_call`（跨 DLL 调用必须是 C ABI），
//     具名过程类型用 `#type (...)` 别名表达 odin 的「只声明不实现」；
//   - 指针 `^T` 写 `*T`；odin 的 `runtime.Context` 在 Jai 里是内建的 `#Context`；
//   - odin 的 `[]u8` 写 `[] u8`：Jai 的 `string` 与 `[] u8` 是不同类型，快照按字节数组给，
//     调用方要写字节时显式转（`cast([] u8) str` 是别名，不复制）；
//   - 常量带类型写 `NAME : type : value;`（odin 的 `API_VERSION :: u32(1)`）。
#import "Basic";

API_VERSION : u32 : 1;
ENTRY_SYMBOL :: "olib_game_api";

// 只在当前回调内借用；模块不得保存 host_context 或 frame。
// instance 是模块私有世界/UI，可含动态数组；宿主不解释也不跨版本复制它。
// services 由宿主持有，允许指向含游戏自定义结构的宿主状态。
Call :: struct {
    host_context: *#Context;
    services: *void;
    instance: *void;
    frame: *void;
}

// data 仅在 load 调用期间有效。version=0 表示首次启动或明确要求重置。
// 快照必须自包含，不得包含指针、proc、any、typeid、分配器或 GPU 资源。
Snapshot :: struct {
    data: [] u8;
    version: u64;
}

// load 只创建私有候选状态；失败也会调用 unload，须支持部分初始化。
// activate 在提交后调用，才可注册宿主回调/启动任务；它不得失败。
// unload 必须注销回调、停止并 join 任务、释放所有私有资源。
// snapshot_size/save 必须只读；save 恰好写入所声明长度，不得保留输出地址。
// 所有 "c" 回调先执行 context = call.host_context^。
API :: struct {
    host_version: u64;
    state_version: u64;
    load: (call: *Call, snapshot: Snapshot) -> bool #c_call;
    unload: (call: *Call) #c_call;
    activate: (call: *Call) #c_call;
    snapshot_size: (call: *Call) -> int #c_call;
    save: (call: *Call, destination: [] u8) -> bool #c_call;
    update: (call: *Call, dt: float64) #c_call;
    render: (call: *Call, dt: float64) #c_call;
}

// 导出名必须为 ENTRY_SYMBOL。先校验 version/size，再写出 API；不能产生副作用。
// odin 这里是过程声明（只提供类型）；Jai 用 `#type` 别名表达同一件事，
// 宿主侧用 `cast(Get_API) symbol_address` 取回。
Get_API :: #type (version: u32, size: int, api: *API) -> bool #c_call;
