// scene_notes 保存场景批注；Agent 按项目约定读取 pending，处理后回写 resolved。
// 不调用模型、不监听任务、不识别游戏对象；Session 拥有文档、保存基准与撤销历史。
//
// 一比一移植自 olib kit/tools/scene_notes/scene_notes.odin。Jai 差异（对外语义不变，只换实现手段）：
//   | olib (Odin)                                      | JaiLib (Jai)                                                  |
//   | ------------------------------------------------ | ------------------------------------------------------------- |
//   | `core:encoding/json` marshal/unmarshal           | core/encoding：json_struct_to_value + json_marshal / json_parse + json_value_to_struct |
//   | `json.marshal(file, {pretty=true})` → []byte     | json_marshal(value, DEFAULT_MARSHAL_OPT) → string（4 空格缩进） |
//   | `[]byte` 快照（current/saved/disk）               | `string` 快照（同一份字节，free 用 `free(s.data)`）              |
//   | `[dynamic][]byte` 撤销/重做栈                     | `[..] string` 栈（array_add / pop / deinit）                    |
//   | `foster.StorageContainer` + ReadAllBytes         | FILE.read_entire_file(完整路径)                                 |
//   | `foster.WriteAllBytesAtomic`                     | 写 `<path>.tmp` 后 file_delete + file_move 替换（本仓库没有原子替换封装） |
//   | `strings.clone`                                  | copy_string                                                   |
//   | `strings.trim_space(x) == ""`                    | STRING.trim(x) == ""                                          |
//   | `strings.contains(x, "\x00")`                    | sn_contains_nul（逐字节）                                      |
//   | `utf8.valid_string(x)`                           | EN.oj_valid_utf8（RFC 8259 的严格子集，与 JSON 词法器同源）      |
//   | `math.is_nan/is_inf`                             | JM.isnan / JM.isinf                                           |
//   | `max(u64)`                                       | MAX_U64                                                       |
//   | `foster.Vec3 / Vec2 / Rect`                      | W.Vec3 / JM.Vector2 / F.Rect（字段 x,y / x,y,z / x,y,w,h 小写）  |
//   | `map[u64]bool`（valid_file 查重）                 | Table(u64, bool) + deinit                                     |
//   | `context.temp_allocator` 的候选文档               | NewArray + `defer array_free`（jacket 的 NewArray 走 context.allocator）|
//
// 两处必须知道的行为差异（不是 bug，是依赖库形态）：
//   1. **JSON 键序不定**：core/encoding 的对象是 Hash_Table，编码顺序是哈希顺序而不是字段声明顺序。
//      同一份文档的两次编码结果仍然逐字节一致（脏检查、撤销快照都成立），但文件里的键序与 olib 不同。
//   2. **allocator 参数只部分生效**：Jai 的 copy_string / free / 字符串快照固定走 context.allocator，
//      init 的 allocator 只用于 json_parse 的树。默认（context.allocator）下两者一致；
//      传自定义分配器时请自行在调用前后切换 context.allocator。
//
// 导入由 module.jai 提供（Basic / STRING / FILE / HASH / JM / EN / W / F）。

//@region 文件协议与会话

VERSION :: 1;
DEFAULT_PATH :: "content/editor/scene_notes.json";
PENDING :: "pending";
RESOLVED :: "resolved";
MAX_LABEL_BYTES :: 2048;
MAX_TITLE_BYTES :: 256;
MAX_TEXT_BYTES :: 16384;
MAX_FILE_BYTES :: 8 * 1024 * 1024;
HISTORY_LIMIT :: 64;
MAX_U64 :: 18446744073709551615; // olib: max(u64)

// 路径相对项目根；object_id 是宿主稳定 ID，不是地址或数组索引。
// position 是世界坐标，2D 的 Z 为 0；未绑定位置时 has_position=false。
// title 是可选的单行短标题，空字符串表示没有标题；旧文件缺少该字段时按空处理
// （json_value_to_struct 对缺失字段保留声明初值，与 olib 的 unmarshal 一致）。
Note :: struct {
    id: u64;
    title: string;
    scene: string;
    object_id: string;
    has_position: bool;
    position: W.Vec3;
    text: string;
    screenshot: string;
    source_hint: string;
    status: string;
    resolution: string;
}

File :: struct {
    version: int;
    next_id: u64;
    notes: [..] Note;
}

Error :: enum u32 {
    None;
    Invalid_Argument;
    Invalid_File;
    Read_Failed;
    Write_Failed;
    External_Change;
    Unsaved_Changes;
    Not_Found;
    No_History;
}

// 零值仅可用于 init；成功后不得浅复制。字段由本包维护，内容通过 all/find 只读借用。
Session :: struct {
    path: string;
    allocator: Allocator;
    document: File;
    current: string;
    saved: string;
    disk: string;
    disk_exists: bool;
    undo_stack: [..] string;
    redo_stack: [..] string;
    next_id_floor: u64;
    initialized: bool;
}

// 缺失文件从空文档开始，不立即写磁盘；现有文件无效时失败，不覆盖文件。
init :: (s: *Session, path := DEFAULT_PATH, allocator := context.allocator) -> Error {
    if s == null || s.initialized || STRING.trim(path) == "" || sn_contains_nul(path) {
        return .Invalid_Argument;
    }
    s.allocator = allocator;
    s.path = copy_string(path);
    s.document = File.{ version = VERSION, next_id = 1 };
    s.next_id_floor = 1;
    s.initialized = true;
    s.current, _ = encode(s.document, allocator);
    s.saved = copy_string(s.current);
    if sn_file_exists(path) {
        err := reload(s);
        if err != .None {
            dispose(s);
            return err;
        }
    }
    return .None;
}

dispose :: (s: *Session) {
    if s == null || !s.initialized return;
    dispose_file(s.document);
    sn_free_string(s.path);
    sn_free_string(s.current);
    sn_free_string(s.saved);
    sn_free_string(s.disk);
    clear_history(*s.undo_stack);
    clear_history(*s.redo_stack);
    array_free(s.undo_stack); // olib: delete(undo_stack)——Jai 的 [..] 用 array_free，没有 deinit 重载
    array_free(s.redo_stack);
    s.* = Session.{};
}

// 返回的字符串和切片只借用到下一次修改、reload 或 dispose，不得自行修改/释放。
all :: (s: *Session) -> [] Note {
    if s == null || !s.initialized return .[];
    return sn_note_view(s.document.notes);
}

find :: (s: *Session, id: u64) -> (note: Note, found: bool) {
    for item: all(s) {
        if item.id == id return item, true;
    }
    return .{}, false;
}

is_dirty :: (s: *Session) -> bool {
    return s != null && s.initialized && s.current != s.saved;
}

can_undo :: (s: *Session) -> bool {
    return s != null && s.initialized && s.undo_stack.count > 0;
}

can_redo :: (s: *Session) -> bool {
    return s != null && s.initialized && s.redo_stack.count > 0;
}

error_text :: (err: Error) -> string {
    if err == {
        case .None;              return "";
        case .Invalid_Argument;  return "无效参数或会话尚未初始化";
        case .Invalid_File;      return "批注格式无效：请检查版本、ID、状态、必填文字、单行标题与字段长度";
        case .Read_Failed;       return "无法读取批注文件，当前内容未改变";
        case .Write_Failed;      return "无法保存批注文件，旧文件与未保存内容均已保留";
        case .External_Change;   return "磁盘批注已被 Agent 或其他程序修改，请先重新载入；不会覆盖外部结果";
        case .Unsaved_Changes;   return "仍有未保存修改，请先保存，或明确放弃后重新载入";
        case .Not_Found;         return "批注已不存在，请重新选择";
        case .No_History;        return "没有可撤销或重做的操作";
    }
    return "未知批注错误";
}
//@endregion

//@region 编辑事务与历史

// 每次成功调用是一条事务；persist=true 在安全落盘后才提交，失败不改变文档或历史。
add :: (s: *Session, input: Note, persist := false) -> (id: u64, err: Error) {
    if s == null || !s.initialized return 0, .Invalid_Argument;
    note := input;
    next_id := max(s.document.next_id, s.next_id_floor);
    if next_id >= MAX_U64 return 0, .Invalid_File;
    note.id = next_id;
    note.status = PENDING;
    note.resolution = "";
    candidate := s.document;
    candidate.next_id = next_id + 1;
    candidate.notes = sn_notes_alloc(s.document.notes.count + 1);
    defer array_free(candidate.notes);
    if s.document.notes.count > 0 {
        memcpy(candidate.notes.data, s.document.notes.data, s.document.notes.count * size_of(Note));
    }
    candidate.notes[candidate.notes.count - 1] = note;
    err = commit(s, candidate, persist);
    if err != .None return 0, err;
    return note.id, .None;
}

// 一次替换一条完整批注；无变化不新增历史。resolved 必须有非空处理说明。
replace :: (s: *Session, note: Note, persist := false) -> Error {
    if s == null || !s.initialized return .Invalid_Argument;
    candidate := s.document;
    candidate.notes = sn_notes_alloc(s.document.notes.count);
    defer array_free(candidate.notes);
    if s.document.notes.count > 0 {
        memcpy(candidate.notes.data, s.document.notes.data, s.document.notes.count * size_of(Note));
    }
    for *item: candidate.notes {
        if item.id != note.id continue;
        item.* = note;
        return commit(s, candidate, persist);
    }
    return .Not_Found;
}

resolve :: (s: *Session, id: u64, resolution: string) -> Error {
    note, ok := find(s, id);
    if !ok return .Not_Found;
    note.status = RESOLVED;
    note.resolution = resolution;
    return replace(s, note);
}

reopen :: (s: *Session, id: u64) -> Error {
    note, ok := find(s, id);
    if !ok return .Not_Found;
    note.status = PENDING;
    note.resolution = "";
    return replace(s, note);
}

undo :: (s: *Session) -> Error {
    if !can_undo(s) return .No_History;
    return restore(s, *s.undo_stack, *s.redo_stack);
}

redo :: (s: *Session) -> Error {
    if !can_redo(s) return .No_History;
    return restore(s, *s.redo_stack, *s.undo_stack);
}
commit :: (s: *Session, candidate: File, persist := false) -> Error {
    if !valid_file(candidate) return .Invalid_File;
    bytes, err := encode(candidate, s.allocator);
    if err != .None return err;
    if bytes == s.current {
        sn_free_string(bytes);
        if persist return save(s);
        return .None;
    }
    owned := clone_file(candidate);
    if persist {
        write_error := write_file(s, bytes);
        if write_error != .None {
            dispose_file(owned);
            sn_free_string(bytes);
            return write_error;
        }
    }
    array_add(*s.undo_stack, s.current);
    trim_history(*s.undo_stack);
    clear_history(*s.redo_stack);
    dispose_file(s.document);
    s.document = owned;
    s.next_id_floor = max(s.next_id_floor, candidate.next_id);
    s.current = bytes;
    if persist accept_saved(s, bytes);
    return .None;
}

// 历史里存的是编码后的字节串：恢复时重新解码，避免同一份文档出现两份所有权。
// from / to 是 [..] 栈的地址：jacket 的 pop 只接受视图 `[] T`，[..] 栈的出栈就是 count -= 1，
// 而按值传 [..] 只改到副本的 count，所以这里必须传指针。
restore :: (s: *Session, from: *[..] string, to: *[..] string) -> Error {
    if from.count == 0 return .No_History;
    bytes := from.*[from.count - 1]; // 借用：下面只缩短计数，字符串本身留在调用方的栈里
    candidate, err := decode(bytes, s.allocator);
    if err != .None return err;
    from.count -= 1;
    array_add(to, s.current);
    trim_history(to);
    dispose_file(s.document);
    s.document = candidate;
    s.current = bytes;
    return .None;
}

clear_history :: (stack: *[..] string) {
    for *value: stack.* sn_free_string(value.*);
    stack.count = 0;
}

trim_history :: (stack: *[..] string) {
    if stack.count <= HISTORY_LIMIT return;
    sn_free_string(stack.*[0]);
    for i: 1..stack.count - 1 stack.*[i - 1] = stack.*[i];
    stack.count -= 1;
}
//@endregion

//@region 安全保存与外部回写

// 乐观冲突检查，不是跨进程锁。按“编辑器先保存 → Agent 处理 → 编辑器重载”串行交接。
// 不提供强制覆盖；检测到外部变化时保留双方内容，让调用方明确决定如何合并。
save :: (s: *Session) -> Error {
    if s == null || !s.initialized return .Invalid_Argument;
    write_error := write_file(s, s.current);
    if write_error != .None return write_error;
    accept_saved(s, s.current);
    return .None;
}

write_file :: (s: *Session, data: string) -> Error {
    exists := sn_file_exists(s.path);
    if exists != s.disk_exists return .External_Change;
    if exists {
        bytes, ok := sn_read_file(s.path);
        if !ok return .Read_Failed;
        same := bytes == s.disk;
        sn_free_string(bytes);
        if !same return .External_Change;
    }
    // olib 的 WriteAllBytesAtomic：这里先写临时文件，再替换目标。
    // 与 olib 的差异：file_move 覆盖不是原子的（Windows 上先 delete 再 move），已经保存好的旧文件在
    // 极短的窗口里可能既不在原位也不在新位。
    directory := sn_path_dir(s.path);
    if directory != "." FILE.make_directory_if_it_does_not_exist(directory);
    temporary := tprint("%.tmp", s.path);
    if !FILE.write_entire_file(temporary, data) return .Write_Failed;
    if exists FILE.file_delete(s.path);
    if !FILE.file_move(temporary, s.path) {
        FILE.file_delete(temporary);
        return .Write_Failed;
    }
    return .None;
}

accept_saved :: (s: *Session, bytes: string) {
    sn_free_string(s.disk);
    sn_free_string(s.saved);
    s.disk = copy_string(bytes);
    s.saved = copy_string(bytes);
    s.disk_exists = true;
}

// 默认拒绝丢弃本地修改；discard=true 必须来自宿主明确的“放弃并重载”确认。
// 成功才替换文档与历史，外部错误/坏 JSON 不破坏现有有效状态。
reload :: (s: *Session, discard := false) -> Error {
    if s == null || !s.initialized return .Invalid_Argument;
    if is_dirty(s) && !discard return .Unsaved_Changes;
    bytes, read_ok := sn_read_file(s.path);
    if !read_ok return .Read_Failed;
    candidate, err := decode(bytes, s.allocator);
    if err != .None {
        sn_free_string(bytes);
        return err;
    }
    canonical, encode_err := encode(candidate, s.allocator);
    if encode_err != .None {
        sn_free_string(bytes);
        dispose_file(candidate);
        return encode_err;
    }
    dispose_file(s.document);
    sn_free_string(s.current);
    sn_free_string(s.saved);
    sn_free_string(s.disk);
    clear_history(*s.undo_stack);
    clear_history(*s.redo_stack);
    s.document = candidate;
    s.next_id_floor = max(s.next_id_floor, candidate.next_id);
    s.current = canonical;
    s.saved = copy_string(canonical);
    s.disk = bytes;
    s.disk_exists = true;
    return .None;
}
//@endregion

//@region 编解码与所有权

valid_file :: (file: File) -> bool {
    if file.version != VERSION || file.next_id == 0 return false;
    ids: Table(u64, bool);
    defer deinit(*ids);
    for note: file.notes {
        if note.id == 0 || note.id >= file.next_id return false;
        found, _ := table_find(*ids, note.id);
        if found return false;
        table_set(*ids, note.id, true);
        if STRING.trim(note.scene) == "" || STRING.trim(note.text) == "" return false;
        if note.status != PENDING && note.status != RESOLVED return false;
        if note.status == RESOLVED && STRING.trim(note.resolution) == "" return false;
        if !valid_text(note.title, MAX_TITLE_BYTES) return false;
        if STRING.contains_any_character(note.title, "\r\n\t") return false;
        if !valid_text(note.scene, MAX_LABEL_BYTES) || !valid_text(note.object_id, MAX_LABEL_BYTES) ||
           !valid_text(note.screenshot, MAX_LABEL_BYTES) || !valid_text(note.source_hint, MAX_LABEL_BYTES) {
            return false;
        }
        if !valid_text(note.text, MAX_TEXT_BYTES) || !valid_text(note.resolution, MAX_TEXT_BYTES) {
            return false;
        }
        // foster.Vec3 在 Jai 是 Math.Vector3，分量通过 #overlay 的 component 数组遍历。
        for value: note.position.component {
            if JM.isnan(value) || JM.isinf(value) return false;
        }
    }
    return true;
}

valid_text :: (text: string, maximum: int) -> bool {
    return text.count <= maximum && EN.oj_valid_utf8(text) && !sn_contains_nul(text);
}

encode :: (file: File, allocator: Allocator) -> (string, Error) {
    info := cast(*Type_Info_Struct) cast(*Type_Info) type_info(File);
    value := EN.json_struct_to_value(*file, info);
    defer EN.json_destroy_value(value);
    bytes := EN.json_marshal(value, EN.DEFAULT_MARSHAL_OPT);
    if bytes.count > MAX_FILE_BYTES {
        sn_free_string(bytes);
        return "", .Invalid_File;
    }
    return bytes, .None;
}

// 先解析成 Value 树（借用树里的字符串），校验通过后再 clone_file 出一份独立所有权的文档。
// olib 用 arena 做同一件事：树随 arena 回收，clone 出来的才是 session 的。
decode :: (bytes: string, allocator: Allocator) -> (File, Error) {
    if bytes.count > MAX_FILE_BYTES || !EN.oj_valid_utf8(bytes) return File.{}, .Invalid_File;
    value, ok := EN.json_parse(bytes, allocator);
    if !ok return File.{}, .Invalid_File;
    defer EN.json_destroy_value(value);
    candidate: File;
    info := cast(*Type_Info_Struct) cast(*Type_Info) type_info(File);
    if !EN.json_value_to_struct(value, *candidate, info) return File.{}, .Invalid_File;
    valid := valid_file(candidate);
    owned: File;
    if valid owned = clone_file(candidate);
    array_free(candidate.notes); // 元素里的字符串借用自 Value 树，不能 dispose_file
    if !valid return File.{}, .Invalid_File;
    return owned, .None;
}

clone_file :: (file: File) -> File {
    result := file;
    result.notes = sn_notes_alloc(file.notes.count);
    for note, i: file.notes {
        result.notes[i] = note;
        result.notes[i].title = copy_string(note.title);
        result.notes[i].scene = copy_string(note.scene);
        result.notes[i].object_id = copy_string(note.object_id);
        result.notes[i].text = copy_string(note.text);
        result.notes[i].screenshot = copy_string(note.screenshot);
        result.notes[i].source_hint = copy_string(note.source_hint);
        result.notes[i].status = copy_string(note.status);
        result.notes[i].resolution = copy_string(note.resolution);
    }
    return result;
}

dispose_file :: (file: File) {
    for note: file.notes {
        if note.title.data != null free(note.title.data);
        if note.scene.data != null free(note.scene.data);
        if note.object_id.data != null free(note.object_id.data);
        if note.text.data != null free(note.text.data);
        if note.screenshot.data != null free(note.screenshot.data);
        if note.source_hint.data != null free(note.source_hint.data);
        if note.status.data != null free(note.status.data);
        if note.resolution.data != null free(note.resolution.data);
    }
    array_free(file.notes);
}
//@endregion

//@region 路径与字节小工具（Alternative：jfoster 没有 StorageContainer 等价的读/存/存在性三连）

// olib: `make([dynamic]Note, n)`。Jai 的 NewArray 返回的是**定长切片** `[] T`，赋不给 `[..] Note`
// 字段（"expected [..] Note, found [] Note"）；可增长数组只能先 reserve 再自己给 count。
// 元素保持未初始化，调用方照旧 memcpy 覆盖（add / replace）或逐字段写入（clone_file）。
sn_notes_alloc :: (count: int) -> [..] Note {
    result: [..] Note;
    if count <= 0 return result;
    array_reserve(*result, count);
    result.count = count;
    return result;
}

// `[..] Note` → `[] Note` 的只读视图。Jai 没有隐式动态数组→切片的转换，也没有 pointer[0..n]
// 切片语法（`d.data[0 .. d.count]` 是 parse 错误），所以要手动拼 data/count。
sn_note_view :: (notes: [..] Note) -> [] Note {
    result: [] Note;
    result.data = notes.data;
    result.count = notes.count;
    return result;
}

sn_free_string :: (value: string) {
    if value.data != null free(value.data);
}

sn_contains_nul :: (text: string) -> bool {
    for text if it == 0 return true;
    return false;
}

sn_read_file :: (path: string) -> (string, bool) {
    return FILE.read_entire_file(path);
}

sn_file_exists :: (path: string) -> bool {
    text, ok := FILE.read_entire_file(path);
    if ok sn_free_string(text);
    return ok;
}

sn_path_dir :: (path: string) -> string {
    for i: path.count - 1..0 {
        if path[i] == 47 || path[i] == 92 return STRING.slice(path, 0, i); // 47 '/', 92 '\'
    }
    return ".";
}
//@endregion

//@region 场景标记命中

// 宿主投影后的最终 drawable 像素坐标；2D/3D 坐标转换与对象有效性由宿主负责。
Marker :: struct {
    id: u64;
    position: JM.Vector2;
}

// 仅查询，不读取输入、不改变选中。宿主先分配 UI/视口输入，再调用；视口外不可命中。
marker_hit :: (markers: [] Marker, point: JM.Vector2, viewport: F.Rect, radius: float32) -> u64 {
    if radius <= 0 || !inside(point, viewport) return 0;
    best := radius * radius;
    id: u64;
    for marker: markers {
        if marker.id == 0 || !inside(marker.position, viewport) continue;
        dx := marker.position.x - point.x;
        dy := marker.position.y - point.y;
        distance := dx * dx + dy * dy;
        if distance <= best {
            best = distance;
            id = marker.id;
        }
    }
    return id;
}

inside :: (point: JM.Vector2, rect: F.Rect) -> bool {
    return point.x >= rect.x && point.y >= rect.y &&
           point.x < rect.x + rect.w && point.y < rect.y + rect.h;
}
//@endregion
