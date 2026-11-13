// jfoster — wasm64 宿主（浏览器 / Node 共用）
//
// 职责：
//   1. 提供 wasm 的全部 import：`env.*`（jfoster 的桥，见 internal/web/web_bridge.jai）
//      和 `wasi_snapshot_preview1.*`（jacket 的 WASI 运行时）。
//   2. 拿住导出的 memory（Jai 侧传的是 s32 内存偏移，这里换成 typed array 视图）。
//   3. 浏览器里接管 DOM：canvas 尺寸、键盘/指针/滚轮/焦点/可见性/resize 事件、
//      剪贴板、全屏、指针锁定、隐藏 input（IME）、Gamepad API。
//   4. 调一次 fw_boot()，然后用 requestAnimationFrame 每帧调 fw_step(dt)，
//      直到它返回 0。
//
// 刻意做成「经典脚本」（不是 ESM）：file:// 下浏览器禁止加载 ES module（CORS），
// 但允许 <script src>。Node 侧用 createRequire 载入，见 verify.mjs。
//
// ===========================================================================
// 硬事实（实测，见 internal/web/README.md）
// ===========================================================================
// * Jai 的 wasm64 里指针是 i64 → JS 收到的是 BigInt。**本桥所有指针参数都改成了
//   s32 内存偏移**，所以 env.* 的参数全是普通 Number，一个 BigInt 都不用。
// * 不要调 _start，也不要调导出的 main：两者都会跑 __jai_runtime_fini，把 Jai
//   保存的 context 拆掉。只调 fw_boot / fw_step / fw_stats。
// * env.* 的实现必须**一个不少**：少一个 instantiate 就抛 LinkError。
//   instantiate() 会拿 WebAssembly.Module.imports() 对一遍，缺谁报谁。
// * WASI preview1 的地址是 u32（即使内存是 64 位）：iovec 步长 8 字节，
//   nwritten / clock_time_get 的 out 也是 u32。见 makeWasi()。
// ===========================================================================

(function (root) {
  "use strict";

  // =========================================================== 共享常量
  //
  // 这些数值必须和 Jai 侧一致。verify.mjs 会用导出的 fw_layout() 对拍，
  // 所以错位不会静默。

  // internal/web/web_events.jai :: WireDomEvent（6 × s32 = 24 字节）
  var DOM_REC_BYTES = 24;

  // internal/web/web_events.jai :: WEB_EV_*
  var EV = {
    KEY_DOWN: 1,
    KEY_UP: 2,
    POINTER_DOWN: 3,
    POINTER_UP: 4,
    POINTER_MOVE: 5,
    WHEEL: 6,
    FOCUS: 7,
    BLUR: 8,
    VISIBILITY: 9,
    RESIZE: 10,
    TEXT: 11,
  };

  // internal/web/web_events.jai :: Web_Gamepad_Rec（152 字节）
  var GAMEPAD = {
    BYTES: 152,
    NAME_OFF: 32,
    NAME_MAX: 64,
    AXES_OFF: 96,
    AXES_MAX: 8,
    BUTTONS_OFF: 128,
    BUTTONS_MAX: 24,
  };

  // ============================================================ 查询参数
  //
  // 宿主行为用 URL 查询串控制（浏览器里改地址就能开关，不用重新 build）：
  //   ?driver=timeout   帧调度走 setTimeout（无头验证；rAF 在 --virtual-time-budget
  //                     下只触发一次）
  //   ?preserve=1       打开 preserveDrawingBuffer（截图 / 跨任务读回）
  //   ?frames=3400      跑满 N 帧就停（[W6] 的内存稳定性 soak；0 / 缺省 = 不限制）
  //
  // 同一个开关也可以用 start({ ... }) 的配置项传，配置项优先（Node 校验环境没有
  // location）。
  function queryParam(name) {
    try {
      if (!root.location) return null;
      return new URLSearchParams(root.location.search).get(name);
    } catch (e) {
      return null;
    }
  }

  function queryFlag(name) {
    var value = queryParam(name);
    if (value === null || value === undefined) return null;
    if (value === "" || value === "0" || value === "false") return false;
    return true;
  }

  function queryNumber(name) {
    var value = queryParam(name);
    if (value === null || value === undefined) return null;
    var n = parseInt(value, 10);
    return isFinite(n) ? n : null;
  }

  // ================================================================= 日志
  function makeSink(options) {
    var lines = [];
    var sink = {
      lines: lines,
      write: function (text) {
        lines.push(text);
        if (lines.length > 1024) lines.splice(0, lines.length - 1024);
        if (options && options.onLog) options.onLog(text);
        else if (typeof root.console !== "undefined") root.console.log("[wasm] " + text);
      },
    };
    return sink;
  }

  // ================================================== event.code → SDL scancode
  //
  // 这是一张纯数据表：DOM 的 KeyboardEvent.code（物理键位，与键盘布局/大写
  // 状态无关）→ SDL_Scancode。Jai 侧直接拿它当 Keys 用
  // （input/enums.jai: Keys 的值就是 SDL scancode），所以桌面与 web 的
  // `keyboard_down(kb, .W)` 完全相同。
  //
  // 覆盖：A-Z、0-9、F1-F12、方向键、编辑键簇、小键盘、修饰键、标点。
  // 未列出的 code（浏览器/输入法扩展键）返回 0 = Keys.UNKNOWN。
  var SCANCODE = (function () {
    var t = {};
    function def(code, scancode) {
      t[code] = scancode;
    }

    // A-Z (4..29)
    for (var i = 0; i < 26; i++) def("Key" + String.fromCharCode(65 + i), 4 + i);
    // 1-9, 0 (30..39)
    for (var d = 1; d <= 9; d++) def("Digit" + d, 29 + d);
    def("Digit0", 39);

    def("Enter", 40);
    def("Escape", 41);
    def("Backspace", 42);
    def("Tab", 43);
    def("Space", 44);
    def("Minus", 45);
    def("Equal", 46);
    def("BracketLeft", 47);
    def("BracketRight", 48);
    def("Backslash", 49);
    def("IntlBackslash", 50); // SDL_SCANCODE_NONUSHASH
    def("Semicolon", 51);
    def("Quote", 52);
    def("Backquote", 53);
    def("Comma", 54);
    def("Period", 55);
    def("Slash", 56);
    def("CapsLock", 57);

    for (var f = 1; f <= 12; f++) def("F" + f, 57 + f); // 58..69

    def("PrintScreen", 70);
    def("ScrollLock", 71);
    def("Pause", 72);
    def("Insert", 73);
    def("Home", 74);
    def("PageUp", 75);
    def("Delete", 76);
    def("End", 77);
    def("PageDown", 78);
    def("ArrowRight", 79);
    def("ArrowLeft", 80);
    def("ArrowDown", 81);
    def("ArrowUp", 82);

    def("NumLock", 83);
    def("NumpadDivide", 84);
    def("NumpadMultiply", 85);
    def("NumpadSubtract", 86);
    def("NumpadAdd", 87);
    def("NumpadEnter", 88);
    for (var k = 1; k <= 9; k++) def("Numpad" + k, 88 + k); // 89..97
    def("Numpad0", 98);
    def("NumpadDecimal", 99);

    def("ControlLeft", 224);
    def("ShiftLeft", 225);
    def("AltLeft", 226);
    def("MetaLeft", 227);
    def("OSLeft", 227); // 老 Chrome/Firefox 的旧名
    def("ControlRight", 228);
    def("ShiftRight", 229);
    def("AltRight", 230);
    def("MetaRight", 231);
    def("OSRight", 231);

    return t;
  })();

  function scancodeFromCode(code) {
    var value = SCANCODE[code];
    return typeof value === "number" ? value : 0;
  }

  // ============================================== Web Gamepad → SDL 编号
  //
  // W3C "standard" mapping 的按键索引 → SDL_GamepadButton。桌面端把 SDL 的
  // 索引直接喂给 input_controller_button，所以这里也对齐到 SDL 的编号，
  // 这样 `controller_down(c, .SOUTH)` 在两个目标上指的是同一个物理键。
  //
  //   0 south(A) 1 east(B) 2 west(X) 3 north(Y)
  //   4 back     5 guide  6 start  7 left-stick  8 right-stick
  //   9 LB      10 RB     11 dpad-up 12 dpad-down 13 dpad-left 14 dpad-right
  var W3C_TO_SDL_BUTTON = {
    0: 0, // A / south
    1: 1, // B / east
    2: 2, // X / west
    3: 3, // Y / north
    4: 9, // LB
    5: 10, // RB
    8: 4, // back
    9: 6, // start
    10: 7, // left stick click
    11: 8, // right stick click
    12: 11, // dpad up
    13: 12, // dpad down
    14: 13, // dpad left
    15: 14, // dpad right
    16: 5, // guide
  };
  // W3C 的扳机是 button 6/7（0..1 的模拟量），SDL 把它当轴 4/5。
  var W3C_TRIGGER_AXIS = { 6: 4, 7: 5 };

  // ================================================== 存档（内存+LS+OPFS）
  //
  // 三层，原因见 internal/web/storage_web.jai 的文件头：
  //   1. memory Map  —— 同步读写，永远可用（Node 里就只靠它）
  //   2. localStorage —— 同步，boot 时整份载入，写时立刻回写
  //   3. OPFS        —— 异步镜像，只写不读（读同步才是桥能用的前提）
  function makeStorage(deps) {
    var sink = deps.sink;
    var map = new Map();
    var LS_PREFIX = "jfoster:";
    var log = function (text) {
      sink.write("[storage] " + text + "\n");
    };

    var ls = null;
    try {
      if (typeof root.localStorage !== "undefined" && root.localStorage) {
        // 有的浏览器在 file:// / 隐私模式下访问 localStorage 就抛异常。
        root.localStorage.getItem(LS_PREFIX + "__probe");
        ls = root.localStorage;
      }
    } catch (e) {
      ls = null;
    }

    var decoder = new TextDecoder("utf-8");
    var encoder = new TextEncoder();

    function loadFromLocalStorage() {
      if (!ls) return 0;
      var loaded = 0;
      for (var i = 0; i < ls.length; i++) {
        var key = ls.key(i);
        if (!key || key.indexOf(LS_PREFIX) !== 0) continue;
        var value = ls.getItem(key);
        if (value === null) continue;
        map.set(key.slice(LS_PREFIX.length), value);
        loaded++;
      }
      return loaded;
    }

    function persist(key) {
      if (ls) {
        try {
          if (map.has(key)) ls.setItem(LS_PREFIX + key, map.get(key));
          else ls.removeItem(LS_PREFIX + key);
        } catch (e) {
          log("localStorage 写入失败（配额？）：" + e.message);
        }
      }
      mirrorToOpfs(key);
    }

    // ---- OPFS 镜像（异步，尽力而为）----
    var opfsDir = null;
    var opfsQueue = Promise.resolve();
    var opfsReady = false;

    function opfsName(key) {
      // OPFS 是文件系统，键是 "save/slot1.dat"：用一个平坦的百分号编码名，
      // 免得再实现一套嵌套目录创建。
      return encodeURIComponent(key);
    }

    function initOpfs() {
      if (opfsReady) return Promise.resolve(opfsDir);
      if (typeof root.navigator === "undefined" || !root.navigator.storage ||
          typeof root.navigator.storage.getDirectory !== "function") {
        opfsReady = true;
        opfsDir = null;
        return Promise.resolve(null);
      }
      return root.navigator.storage
        .getDirectory()
        .then(function (dirHandle) {
          return dirHandle.getDirectoryHandle("jfoster-save", { create: true });
        })
        .then(function (dir) {
          opfsDir = dir;
          opfsReady = true;
          return dir;
        })
        .catch(function (e) {
          log("OPFS 不可用，退回 localStorage/内存：" + e.message);
          opfsDir = null;
          opfsReady = true;
          return null;
        });
    }

    function mirrorToOpfs(key) {
      if (typeof root.navigator === "undefined" || !root.navigator.storage) return;
      opfsQueue = opfsQueue
        .then(function () {
          return initOpfs();
        })
        .then(function (dir) {
          if (!dir) return;
          var name = opfsName(key);
          if (!map.has(key)) {
            return dir.removeEntry(name).catch(function () {});
          }
          return dir
            .getFileHandle(name, { create: true })
            .then(function (fileHandle) {
              return fileHandle.createWritable();
            })
            .then(function (writable) {
              return writable.write(map.get(key)).then(function () {
                return writable.close();
              });
            });
        })
        .catch(function (e) {
          log("OPFS 镜像写失败：" + e.message);
        });
    }

    function hydrateFromOpfs() {
      // 只有在内存里**没有**这个键时才用 OPFS 的值：localStorage 是同步真相，
      // OPFS 是耐久备份。启动顺序保证 localStorage 先灌完。
      return initOpfs().then(function (dir) {
        if (!dir) return 0;
        var loaded = 0;
        var iterator = dir.entries();
        function step() {
          return iterator.next().then(function (result) {
            if (result.done) return loaded;
            var name = result.value[0];
            var handle = result.value[1];
            if (handle.kind !== "file") return step();
            return handle
              .getFile()
              .then(function (file) {
                return file.text();
              })
              .then(function (text) {
                var key = decodeURIComponent(name);
                if (!map.has(key)) {
                  map.set(key, text);
                  loaded++;
                }
                return step();
              });
          });
        }
        return step();
      }).catch(function (e) {
        log("OPFS 读取失败，只用 localStorage/内存：" + e.message);
        return 0;
      });
    }

    var fromLs = loadFromLocalStorage();
    var hydration = hydrateFromOpfs();

    return {
      map: map,
      backend: ls ? "localStorage+内存" : "内存（无 localStorage）",
      log,
      // 启动时打印一次实际状态，浏览器验收看这一行就知道走了哪条路
      describe: function () {
        return (
          "存档后端：" + (ls ? "localStorage" : "内存") +
          "（载入 " + fromLs + " 项；OPFS " +
          (typeof root.navigator !== "undefined" && root.navigator.storage ? "可用（后台镜像）" : "不可用") + "）"
        );
      },
      whenHydrated: function () {
        return hydration;
      },
      has: function (key) {
        return map.has(key);
      },
      size: function (key) {
        return map.has(key) ? encoder.encode(map.get(key)).length : -1;
      },
      readBytes: function (key, buffer, offset, capacity) {
        if (!map.has(key)) return -1;
        var bytes = encoder.encode(map.get(key));
        var count = Math.min(capacity, bytes.length);
        if (count > 0) new Uint8Array(buffer, offset, count).set(bytes.subarray(0, count));
        return bytes.length;
      },
      writeBytes: function (key, buffer, offset, length) {
        var bytes = new Uint8Array(buffer, offset, length);
        map.set(key, decoder.decode(bytes));
        persist(key);
        return length;
      },
      remove: function (key) {
        if (!map.has(key)) return -1;
        map.delete(key);
        persist(key);
        return 0;
      },
      list: function (prefix) {
        var out = [];
        var head = prefix ? prefix + "/" : "";
        map.forEach(function (value, key) {
          if (!head) {
            out.push(key);
            return;
          }
          if (key.indexOf(head) === 0 && key.length > head.length) {
            out.push(key.slice(head.length));
          }
        });
        out.sort();
        return out;
      },
    };
  }

  // ==================================================== WebGL2（W3，gl_* 导入）
  //
  // internal/web/graphics_device_web.jai 的后半截：Jai 侧把 jfoster 的枚举翻成
  // GL 常量（web_gl.jai），这里只做三件事：
  //   1. 用**句柄数组**把整数 id 映射到 WebGL 对象（1 起，0 = 无效）；
  //   2. 调对应的 WebGL2 方法；
  //   3. 把 draw / upload / pass 的计数记下来（gl_stats，报告用）。
  //
  // 特意不做的两件事：
  //   * **不做枚举翻译**。传下来的一律已经是 GL 常量，JS 里没有一行 jfoster 语义。
  //   * **不缓存状态**。WebGL2 没有状态对象，Jai 侧每次都设；这里如果自作聪明
  //     去 dedupe，就会和 Jai 侧的「这次 pass 里已经设过」的判断打架。
  //
  // 没有 canvas / 没有 WebGL2 时（Node 校验环境、老浏览器）每个入口都返回 0
  // 或 -1，绝不抛异常 —— 同一份 fw.wasm 因此既能被 verify.mjs 驱动，也能在
  // 浏览器里画像素。
  function makeGl(deps) {
    var getMemory = deps.getMemory;
    var sink = deps.sink;
    var dom = deps.dom; // Node 下是 null
    var canvas = dom ? dom.canvas : null;

    // [W6] `preserveDrawingBuffer` 现在**可配**，默认关。
    //
    // 打开它（W3..W5 唯一的选择）等于告诉驱动「任务结束后我还可能读这张 buffer」，
    // 于是部分驱动（尤其是移动端 / tile-based 的 GLES 实现）必须把整帧保留下来，
    // 关掉 tile 优化；WebGL 规范里这是明确列出的性能陷阱。
    //
    // 关掉之后，同一**任务**内的 readPixels 依然有效（规范只保证到合成前），而本示例
    // 的所有像素断言都发生在「画完 → 同一个 fw_step 里读回」，所以默认关是安全的。
    // 需要截图 / 跨任务读回 / --screenshot 时用 `?preserve=1`（或 start() 的配置项）。
    var preserveDrawingBuffer = false;
    if (deps.preserveDrawingBuffer !== undefined && deps.preserveDrawingBuffer !== null) {
      preserveDrawingBuffer = !!deps.preserveDrawingBuffer;
    } else {
      var queryPreserve = queryFlag("preserve");
      if (queryPreserve !== null) preserveDrawingBuffer = queryPreserve;
    }

    var gl = null;
    var objects = [null]; // 1 起：objects[id] = { kind, obj, ...元数据 }
    var logged = {};
    var stats = {
      draws: 0, passes: 0, clears: 0, textureUploads: 0, bufferUploads: 0,
      shaders: 0, programs: 0, pipelines: 0, readbacks: 0, pixelsRead: 0, errors: 0,
      uniformUploads: 0, uniformBindings: 0,
      // [W5] target / MSAA / blit
      framebuffers: 0, renderbuffers: 0, blits: 0, failedBlits: 0, incompleteFbos: 0,
      // [W6] **存活**对象计数。上面那几个是「创建过多少次」的累计值，永远单调增长，
      // 因此看不出泄漏；内存稳定性要的是「现在有多少个真对象」，所以每个 create
      // 加一、每个 destroy 减一（见 live()）。gl_stats(19..24) 暴露给内存报告。
      live: { texture: 0, buffer: 0, program: 0, pipeline: 0, framebuffer: 0, renderbuffer: 0, sampler: 0, uniformBuffer: 0 },
    };

    // 存活计数：创建 +1，销毁 -1。`slot` 是 kinds 的名字（见 stats.live）。
    function live(kind, delta) {
      if (!Object.prototype.hasOwnProperty.call(stats.live, kind)) return;
      stats.live[kind] += delta;
      if (stats.live[kind] < 0) stats.live[kind] = 0;
    }
    // 当前 render pass 的目标高度（top-left → GL bottom-left 的翻转要用它）
    var targetWidth = 0, targetHeight = 0;
    var currentFbo = null;
    // [W5] EXT_color_buffer_float：决定 RGBA16F 之类的浮点格式能不能当**渲染目标**
    // （采样是 WebGL2 核心功能，渲染要这个扩展）。Jai 侧的格式矩阵通过
    // gl_get_param(11) 读它，而不是假设"有 GL 就有"。
    var floatRenderable = false;

    var decoder = new TextDecoder("utf-8");
    var encoder = new TextEncoder();

    function log(text) {
      sink.write("[gl] " + text + "\n");
    }

    function logOnce(tag, text) {
      if (logged[tag]) return;
      logged[tag] = true;
      log(text);
    }

    function entry(id) {
      var e = objects[id | 0];
      return e && e.obj ? e : null;
    }

    function add(entryObj) {
      objects.push(entryObj);
      return objects.length - 1;
    }

    function readUtf8(ptr, len) {
      var offset = ptr >>> 0;
      var count = len >>> 0;
      if (count <= 0) return "";
      return decoder.decode(new Uint8Array(getMemory().buffer, offset, count));
    }

    function writeUtf8(ptr, cap, text) {
      var bytes = encoder.encode(text);
      var count = Math.min(cap >>> 0, bytes.length);
      if (count > 0) new Uint8Array(getMemory().buffer, ptr >>> 0, count).set(bytes.subarray(0, count));
      return bytes.length;
    }

    // wasm 线性内存的一个视图。读回/上传都直接用视图，避免整块拷贝。
    function memBytes(ptr, len) {
      return new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0);
    }

    function memFloats(ptr, floatCount) {
      var memory = getMemory();
      if ((ptr >>> 0) % 4 === 0) return new Float32Array(memory.buffer, ptr >>> 0, floatCount >>> 0);
      // 理论上不会发生（Jai 的数组分配至少 8 字节对齐），但错位会让构造器抛
      // RangeError，所以兜底拷一份。
      var copy = new Float32Array(floatCount);
      new Uint8Array(copy.buffer).set(new Uint8Array(memory.buffer, ptr >>> 0, floatCount * 4));
      return copy;
    }

    function uniformLoc(program, name) {
      if (!name) return null;
      if (!Object.prototype.hasOwnProperty.call(program.uniformCache, name)) {
        program.uniformCache[name] = gl.getUniformLocation(program.obj, name);
      }
      return program.uniformCache[name];
    }

    // ------------------------------------------------------------- device
    function gl_device_create(width, height) {
      if (!canvas) {
        logOnce("nocanvas", "没有 canvas（Node 校验环境？）—— WebGL2 后端不启用");
        return 0;
      }
      if (gl) return 1; // 一个页面一个 context

      var attrs = {
        // alpha:false → 默认 framebuffer 没有 alpha 通道，readPixels 的 A 恒为
        // 255。桌面回到窗口的那条路径同样不透明，像素比对因此更确定。
        alpha: false,
        depth: true,
        stencil: true,
        // antialias:false → 没有隐式 MSAA 解析，边缘像素与桌面一致（MSAA 是 W5）。
        antialias: false,
        premultipliedAlpha: true,
        // [W6] 默认 **false**：读回全部发生在同一个 fw_step 任务里，不需要它；
        // 打开会阻止驱动的 tile 优化（见 makeGl 顶部关于 preserveDrawingBuffer 的说明）。
        // 要跨任务截图就用 `?preserve=1`。
        preserveDrawingBuffer: preserveDrawingBuffer,
        powerPreference: "high-performance",
      };

      gl = canvas.getContext("webgl2", attrs);
      if (!gl) {
        logOnce("nowebgl2", "canvas.getContext('webgl2') 返回 null —— 这个浏览器/设备没有 WebGL2");
        return 0;
      }
      // 有 canvas 但没扩展：报出来，免得后面的失败看起来像我们的 bug。
      canvas.addEventListener("webglcontextlost", function (e) {
        e.preventDefault();
        log("webglcontextlost —— GPU 上下文丢失，需要重新 boot");
      });
      canvas.addEventListener("webglcontextrestored", function () {
        log("webglcontextrestored");
      });

      if (width > 0 && height > 0 && (canvas.width !== width || canvas.height !== height)) {
        canvas.width = width;
        canvas.height = height;
      }

      gl.viewport(0, 0, canvas.width | 0, canvas.height | 0);
      gl.disable(gl.DEPTH_TEST);
      gl.disable(gl.STENCIL_TEST);
      gl.disable(gl.CULL_FACE);
      gl.disable(gl.BLEND);
      gl.disable(gl.SCISSOR_TEST);
      gl.colorMask(true, true, true, true);
      gl.depthMask(true);
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false); // 与 SDL 一致：字节序就是上传序
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);

      // 可选扩展：拿到就打开（浮点渲染目标），拿不到就诚实记录。
      floatRenderable = gl.getExtension("EXT_color_buffer_float") !== null;
      log("webgl2 context 建立：" + gl.getParameter(gl.VERSION) +
          "  EXT_color_buffer_float=" + (floatRenderable ? "yes" : "no"));
      return add({ kind: "device", obj: gl });
    }

    function gl_device_destroy() {
      if (!gl) return -1;
      // 对象表整体作废；context 交给 GC（loseContext 会让同一 canvas 上的下次
      // getContext 返回被丢失的 context，反而更难恢复）。
      objects = [null];
      gl = null;
      targetWidth = 0;
      targetHeight = 0;
      currentFbo = null;
      floatRenderable = false;
      // 对象表整体作废：存活计数跟着归零（否则一次 headless 重启之后计数就是负的）
      for (var kind in stats.live) if (Object.prototype.hasOwnProperty.call(stats.live, kind)) stats.live[kind] = 0;
      return 1;
    }

    function gl_swapchain_bind(width, height) {
      if (!gl || !canvas) return -1;
      var w = Math.max(1, width | 0);
      var h = Math.max(1, height | 0);
      if (canvas.width !== w) canvas.width = w;
      if (canvas.height !== h) canvas.height = h;
      targetWidth = w;
      targetHeight = h;
      gl.viewport(0, 0, w, h);
      return 1;
    }

    function gl_present() {
      if (!gl) return -1;
      // WebGL2 没有 present：浏览器在任务结束时合成。flush 把已排队的 GL 命令
      // 交给驱动，等于桌面 SDL_SubmitGPUCommandBuffer + Present 的那一步。
      gl.flush();
      return 1;
    }

    function gl_get_error(tagPtr, tagLen) {
      if (!gl) return 0;
      var code = gl.getError();
      if (code !== gl.NO_ERROR) {
        stats.errors += 1;
        var tag = readUtf8(tagPtr, tagLen);
        log("GL error 0x" + code.toString(16) + (tag ? " @ " + tag : ""));
      }
      return code;
    }

    function gl_get_string(which, buf, cap) {
      if (!gl) return -1;
      var value = "";
      if (which === 0) value = gl.getParameter(gl.VERSION);
      else if (which === 1) value = gl.getParameter(gl.RENDERER);
      else if (which === 2) value = gl.getParameter(gl.VENDOR);
      else if (which === 3) value = gl.getParameter(gl.SHADING_LANGUAGE_VERSION);
      return writeUtf8(buf, cap, String(value));
    }

    function gl_get_param(which) {
      if (!gl) return 0;
      if (which === 0) return canvas ? canvas.width | 0 : 0;
      if (which === 1) return canvas ? canvas.height | 0 : 0;
      if (which === 2) return gl.getParameter(gl.MAX_TEXTURE_SIZE) | 0;
      if (which === 3) return gl.getParameter(gl.MAX_VERTEX_ATTRIBS) | 0;
      if (which === 4) return gl.getParameter(gl.MAX_COMBINED_TEXTURE_IMAGE_UNITS) | 0;
      if (which === 5) return gl.getParameter(gl.MAX_SAMPLES) | 0;
      if (which === 6) return gl.drawingBufferWidth | 0;
      if (which === 7) return gl.drawingBufferHeight | 0;
      if (which === 8) return gl.getParameter(gl.MAX_UNIFORM_BUFFER_BINDINGS) | 0;
      if (which === 9) return gl.getParameter(gl.MAX_RENDERBUFFER_SIZE) | 0;
      if (which === 10) return gl.getParameter(gl.MAX_COLOR_ATTACHMENTS) | 0;
      // 11 = EXT_color_buffer_float 是否可用（决定 RGBA16F 能不能当渲染目标）
      if (which === 11) return floatRenderable ? 1 : 0;
      return 0;
    }

    // ------------------------------------------------------------ textures
    function gl_create_texture(width, height, internalFormat, minFilter, magFilter, wrapS, wrapT) {
      if (!gl) return 0;
      var tex = gl.createTexture();
      if (!tex) return 0;
      gl.bindTexture(gl.TEXTURE_2D, tex);
      try {
        // texStorage2D（不可变存储）：mip 层一次定死，部分上传不会让纹理变成
        // incomplete —— 这正是 SDL_CreateGPUTexture(num_levels = 1) 的语义。
        gl.texStorage2D(gl.TEXTURE_2D, 1, internalFormat, Math.max(1, width | 0), Math.max(1, height | 0));
      } catch (error) {
        log("texStorage2D(" + width + "x" + height + ", 0x" + (internalFormat >>> 0).toString(16) + ") 失败：" + error.message);
        gl.deleteTexture(tex);
        return 0;
      }
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, minFilter);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, magFilter);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, wrapS);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, wrapT);
      live("texture", 1);
      return add({ kind: "texture", obj: tex, width: width | 0, height: height | 0 });
    }

    function gl_set_texture_data(texture, x, y, w, h, ptr, length, format, type) {
      var t = entry(texture);
      if (!t || !gl) return -1;
      gl.bindTexture(gl.TEXTURE_2D, t.obj);
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
      try {
        gl.texSubImage2D(gl.TEXTURE_2D, 0, x | 0, y | 0, w | 0, h | 0, format, type, memBytes(ptr, length));
      } catch (error) {
        log("texSubImage2D 抛异常：" + error.message);
        return -1;
      }
      stats.textureUploads += 1;
      return 1;
    }

    var scratchFbo = null;

    // 读回一张纹理。
    //
    // [W5] 多了两个参数：format/type 决定 readPixels 拿什么像素格式读。WebGL2 的
    // readPixels 只允许「和附件格式匹配」的组合（R8 必须 format=RED，RG8 必须
    // format=RG 且 PACK_ALIGNMENT=1），所以格式化的事必须在 Jai 侧翻好再传下来
    // （web_gl.jai :: web_gl_sdl_data_format）。attachment 同理：颜色读
    // COLOR_ATTACHMENT0，深度要 DEPTH_ATTACHMENT。
    function gl_get_texture_data(texture, x, y, w, h, ptr, length, format, type, attachment) {
      var t = entry(texture);
      if (!t || !gl) return -1;
      if (!scratchFbo) scratchFbo = { kind: "fbo", obj: gl.createFramebuffer() };
      var point = attachment > 0 ? (attachment | 0) : gl.COLOR_ATTACHMENT0;

      gl.bindFramebuffer(gl.FRAMEBUFFER, scratchFbo.obj);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, point, gl.TEXTURE_2D, t.obj, 0);

      var status = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
      if (status !== gl.FRAMEBUFFER_COMPLETE) {
        log("临时 FBO 不完整（0x" + status.toString(16) + "）—— 这张纹理不能作为附件读回");
        gl.framebufferTexture2D(gl.FRAMEBUFFER, point, gl.TEXTURE_2D, null, 0);
        gl.bindFramebuffer(gl.FRAMEBUFFER, currentFbo);
        return -1;
      }

      // 单通道/双通道读回时行宽常常不是 4 的倍数，PACK_ALIGNMENT 必须是 1。
      gl.pixelStorei(gl.PACK_ALIGNMENT, 1);
      // Public texture row zero is the logical top row, including target outputs.
      try {
        gl.readPixels(x | 0, y | 0, w | 0, h | 0,
          format | 0, type | 0, memBytes(ptr, length));
      } catch (error) {
        log("readPixels 抛异常（format=0x" + (format >>> 0).toString(16) + "）：" + error.message);
        gl.framebufferTexture2D(gl.FRAMEBUFFER, point, gl.TEXTURE_2D, null, 0);
        gl.bindFramebuffer(gl.FRAMEBUFFER, currentFbo);
        return -1;
      }
      var readError = gl.getError();
      if (readError !== gl.NO_ERROR) {
        log("readPixels 报 GL error 0x" + readError.toString(16) +
            "（format=0x" + (format >>> 0).toString(16) + " type=0x" + (type >>> 0).toString(16) + "）");
        stats.errors += 1;
        gl.framebufferTexture2D(gl.FRAMEBUFFER, point, gl.TEXTURE_2D, null, 0);
        gl.bindFramebuffer(gl.FRAMEBUFFER, currentFbo);
        return -1;
      }

      gl.framebufferTexture2D(gl.FRAMEBUFFER, point, gl.TEXTURE_2D, null, 0);
      gl.bindFramebuffer(gl.FRAMEBUFFER, currentFbo);

      stats.readbacks += 1;
      stats.pixelsRead += (w | 0) * (h | 0);
      return 1;
    }

    function gl_destroy_texture(texture) {
      var t = entry(texture);
      if (!t || !gl) return -1;
      gl.deleteTexture(t.obj);
      t.obj = null;
      live("texture", -1);
      return 1;
    }

    // --------------------------------------------- framebuffer / target（W5）
    //
    // 一个 FBO 就是 objects 里的一条记录，元数据里记着「谁被挂上来了、几倍采样」，
    // 于是错配（把 4× renderbuffer 当纹理采样、把深度纹理挂到 COLOR_ATTACHMENT0）
    // 在日志里能直接看见，而不是变成一个静默的黑屏。
    //
    // 附件枚举由 Jai 侧翻译后传下来（web_gl.jai 的 GL_COLOR_ATTACHMENT0 / …）：
    // JS 这边只把它当数字用，一行 jfoster 的语义都没有（和 gl_* 的其余部分一致）。
    //
    // 返回值的约定：
    //   * 创建类：>0 = 对象 id，0 = 失败（没有 GL / 驱动拒绝）
    //   * 挂接类：**返回 framebuffer 的完整状态**（gl.FRAMEBUFFER_COMPLETE = 0x8CD5），
    //     调用方（web_gl_target_build）据此把「不完整的 FBO」变成一条明确错误，
    //     而不是继续画到一个画不出东西的 framebuffer 上。
    //   * blit / 其它：1 = 成功，-1 = 失败（已经打过日志）

    function gl_create_framebuffer() {
      if (!gl) return 0;
      var fbo = gl.createFramebuffer();
      if (!fbo) return 0;
      stats.framebuffers += 1;
      live("framebuffer", 1);
      return add({ kind: "framebuffer", obj: fbo, attachments: [], samples: 0, width: 0, height: 0 });
    }

    function gl_destroy_framebuffer(framebuffer) {
      var f = entry(framebuffer);
      if (!f || !gl) return -1;
      gl.deleteFramebuffer(f.obj);
      f.obj = null;
      live("framebuffer", -1);
      return 1;
    }

    function framebufferStatus() {
      var status = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
      if (status !== gl.FRAMEBUFFER_COMPLETE) stats.incompleteFbos += 1;
      return status | 0;
    }

    function gl_attach_texture(framebuffer, attachment, texture) {
      var f = entry(framebuffer);
      if (!f || !gl) return -1;
      var t = entry(texture);
      if (!t) {
        log("gl_attach_texture: 纹理 id " + texture + " 不存在");
        return -1;
      }
      var previous = currentFbo;
      gl.bindFramebuffer(gl.FRAMEBUFFER, f.obj);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, attachment | 0, gl.TEXTURE_2D, t.obj, 0);
      var status = framebufferStatus();
      gl.bindFramebuffer(gl.FRAMEBUFFER, previous);
      f.attachments.push("tex:" + (texture | 0) + "@0x" + (attachment >>> 0).toString(16));
      return status;
    }

    function gl_create_renderbuffer(internalFormat, width, height, samples) {
      if (!gl) return 0;
      var rb = gl.createRenderbuffer();
      if (!rb) return 0;
      var w = Math.max(1, width | 0);
      var h = Math.max(1, height | 0);
      var n = Math.max(1, samples | 0);
      gl.bindRenderbuffer(gl.RENDERBUFFER, rb);
      // 上一次没清掉的 error 会让下面这次判断失去意义。
      while (gl.getError() !== gl.NO_ERROR) { /* drain */ }
      try {
        if (n > 1) gl.renderbufferStorageMultisample(gl.RENDERBUFFER, n, internalFormat | 0, w, h);
        else gl.renderbufferStorage(gl.RENDERBUFFER, internalFormat | 0, w, h);
      } catch (error) {
        log("renderbufferStorage(" + w + "x" + h + ", 0x" + (internalFormat >>> 0).toString(16) +
            ", " + n + "×) 抛异常：" + error.message);
        gl.bindRenderbuffer(gl.RENDERBUFFER, null);
        gl.deleteRenderbuffer(rb);
        return 0;
      }
      var error = gl.getError();
      gl.bindRenderbuffer(gl.RENDERBUFFER, null);
      if (error !== gl.NO_ERROR) {
        // 典型原因：样本数超过 MAX_SAMPLES，或这个 internalformat 不是 renderable 的。
        log("renderbufferStorage 报 GL error 0x" + error.toString(16) +
            "（0x" + (internalFormat >>> 0).toString(16) + ", " + n + "×, " + w + "x" + h + "）");
        stats.errors += 1;
        gl.deleteRenderbuffer(rb);
        return 0;
      }
      stats.renderbuffers += 1;
      live("renderbuffer", 1);
      return add({ kind: "renderbuffer", obj: rb, internalFormat: internalFormat | 0, width: w, height: h, samples: n });
    }

    function gl_destroy_renderbuffer(renderbuffer) {
      var rb = entry(renderbuffer);
      if (!rb || !gl) return -1;
      gl.deleteRenderbuffer(rb.obj);
      rb.obj = null;
      live("renderbuffer", -1);
      return 1;
    }

    function gl_attach_renderbuffer(framebuffer, attachment, renderbuffer) {
      var f = entry(framebuffer);
      if (!f || !gl) return -1;
      var rb = entry(renderbuffer);
      if (!rb) {
        log("gl_attach_renderbuffer: renderbuffer id " + renderbuffer + " 不存在");
        return -1;
      }
      var previous = currentFbo;
      gl.bindFramebuffer(gl.FRAMEBUFFER, f.obj);
      gl.framebufferRenderbuffer(gl.FRAMEBUFFER, attachment | 0, gl.RENDERBUFFER, rb.obj);
      var status = framebufferStatus();
      gl.bindFramebuffer(gl.FRAMEBUFFER, previous);
      if (rb.samples > f.samples) f.samples = rb.samples;
      f.attachments.push("rb:" + (renderbuffer | 0) + "@0x" + (attachment >>> 0).toString(16) + "#" + rb.samples);
      return status;
    }

    function gl_framebuffer_status(framebuffer) {
      var f = entry(framebuffer);
      if (!f || !gl) return -1;
      var previous = currentFbo;
      gl.bindFramebuffer(gl.FRAMEBUFFER, f.obj);
      var status = framebufferStatus();
      gl.bindFramebuffer(gl.FRAMEBUFFER, previous);
      return status;
    }

    // blitFramebuffer 的 mask 位（Jai 侧 web_gl.jai :: WEB_BLIT_*）
    var BLIT_COLOR = 1, BLIT_DEPTH = 2, BLIT_STENCIL = 4;

    function gl_bindFramebufferForBlit(id, target) {
      if (!(id > 0)) { gl.bindFramebuffer(target, null); return true; }
      var f = entry(id);
      if (!f) { log("gl_blit_framebuffer: framebuffer id " + id + " 不存在"); return false; }
      gl.bindFramebuffer(target, f.obj);
      return true;
    }

    // 整块/区域拷贝，或者「多重采样 → 单采样」的 resolve —— 三者都是同一条
    // glBlitFramebuffer。src/dst 传 0 表示 canvas 的默认 framebuffer。
    //
    // Coordinates are raw GL rows. Public textures have logical row zero at V=0;
    // target publication passes reversed destination Y bounds explicitly.
    function gl_blit_framebuffer(src, dst, sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter) {
      if (!gl) return -1;
      var scissor = gl.isEnabled(gl.SCISSOR_TEST);
      try {
        if (!gl_bindFramebufferForBlit(src, gl.READ_FRAMEBUFFER)) return -1;
        if (!gl_bindFramebufferForBlit(dst, gl.DRAW_FRAMEBUFFER)) return -1;
        var bits = 0;
        if ((mask & BLIT_COLOR) !== 0) bits |= gl.COLOR_BUFFER_BIT;
        if ((mask & BLIT_DEPTH) !== 0) bits |= gl.DEPTH_BUFFER_BIT;
        if ((mask & BLIT_STENCIL) !== 0) bits |= gl.STENCIL_BUFFER_BIT;
        if (bits === 0) return -1;
        gl.disable(gl.SCISSOR_TEST);
        while (gl.getError() !== gl.NO_ERROR) { /* drain */ }
        gl.blitFramebuffer(sx0 | 0, sy0 | 0, sx1 | 0, sy1 | 0,
          dx0 | 0, dy0 | 0, dx1 | 0, dy1 | 0, bits, filter | 0);
        var error = gl.getError();
        if (error !== gl.NO_ERROR) {
          stats.errors += 1;
          throw new Error("GL error 0x" + error.toString(16));
        }
        stats.blits += 1;
        return 1;
      } catch (error) {
        log("blitFramebuffer failed (src=" + src + " dst=" + dst + "): " + error.message);
        stats.failedBlits += 1;
        return -1;
      } finally {
        gl.bindFramebuffer(gl.FRAMEBUFFER, currentFbo);
        if (scissor) gl.enable(gl.SCISSOR_TEST);
      }
    }

    // ------------------------------------------------------------- buffers
    function gl_create_buffer(target) {
      if (!gl) return 0;
      var buffer = gl.createBuffer();
      if (!buffer) return 0;
      live("buffer", 1);
      return add({ kind: "buffer", obj: buffer, capacity: 0, target: target });
    }

    function gl_set_buffer_data(buffer, ptr, length, destOffset, capacity, target) {
      var b = entry(buffer);
      if (!b || !gl) return -1;

      // ELEMENT_ARRAY_BUFFER 的绑定是 VAO 状态：解绑 VAO，免得这次上传把当前
      // pipeline 的索引槽改指到别的 buffer 上。
      if (target === gl.ELEMENT_ARRAY_BUFFER) gl.bindVertexArray(null);
      gl.bindBuffer(target, b.obj);

      if ((capacity | 0) > b.capacity) {
        gl.bufferData(target, Math.max(1, capacity | 0), gl.DYNAMIC_DRAW);
        b.capacity = capacity | 0;
      }
      if ((length | 0) > 0) {
        gl.bufferSubData(target, Math.max(0, destOffset | 0), memBytes(ptr, length));
        stats.bufferUploads += 1;
      }
      return 1;
    }

    function gl_destroy_buffer(buffer) {
      var b = entry(buffer);
      if (!b || !gl) return -1;
      gl.deleteBuffer(b.obj);
      b.obj = null;
      live("buffer", -1);
      return 1;
    }

    // ------------------------------------------------------------ samplers
    function gl_create_sampler(minFilter, magFilter, wrapS, wrapT) {
      if (!gl) return 0;
      var sampler = gl.createSampler();
      if (!sampler) return 0;
      gl.samplerParameteri(sampler, gl.TEXTURE_MIN_FILTER, minFilter);
      gl.samplerParameteri(sampler, gl.TEXTURE_MAG_FILTER, magFilter);
      gl.samplerParameteri(sampler, gl.TEXTURE_WRAP_S, wrapS);
      gl.samplerParameteri(sampler, gl.TEXTURE_WRAP_T, wrapT);
      live("sampler", 1);
      return add({ kind: "sampler", obj: sampler });
    }

    function gl_destroy_sampler(sampler) {
      var s = entry(sampler);
      if (!s || !gl) return -1;
      gl.deleteSampler(s.obj);
      s.obj = null;
      live("sampler", -1);
      return 1;
    }

    // ------------------------------------------------------- uniform buffers
    //
    // One GL buffer object per (stage, slot) binding point, owned by the Jai side
    // (web_gl.jai :: web_gpu.uniform_buffers). The Jai side re-uploads the whole
    // std140 block on every draw -- that is what desktop's
    // SDL_PushGPU*UniformData does -- so these are just dumb storage objects here.
    function gl_create_uniform_buffer(size) {
      if (!gl) return 0;
      var buffer = gl.createBuffer();
      if (!buffer) return 0;
      var capacity = Math.max(16, size | 0);
      gl.bindBuffer(gl.UNIFORM_BUFFER, buffer);
      gl.bufferData(gl.UNIFORM_BUFFER, capacity, gl.DYNAMIC_DRAW);
      gl.bindBuffer(gl.UNIFORM_BUFFER, null);
      live("uniformBuffer", 1);
      return add({ kind: "uniform_buffer", obj: buffer, capacity: capacity });
    }

    function gl_set_uniform_buffer_data(buffer, ptr, length, destOffset, capacity) {
      var b = entry(buffer);
      if (!b || !gl) return -1;
      gl.bindBuffer(gl.UNIFORM_BUFFER, b.obj);
      var wanted = Math.max(16, capacity | 0);
      if (wanted > b.capacity) {
        gl.bufferData(gl.UNIFORM_BUFFER, wanted, gl.DYNAMIC_DRAW);
        b.capacity = wanted;
      }
      if ((length | 0) > 0) {
        gl.bufferSubData(gl.UNIFORM_BUFFER, Math.max(0, destOffset | 0), memBytes(ptr, length));
        stats.uniformUploads += 1;
      }
      gl.bindBuffer(gl.UNIFORM_BUFFER, null);
      return 1;
    }

    function gl_bind_uniform_buffer(buffer, binding) {
      var b = entry(buffer);
      if (!gl) return -1;
      gl.bindBufferBase(gl.UNIFORM_BUFFER, binding | 0, b ? b.obj : null);
      stats.uniformBindings += 1;
      return 1;
    }

    function gl_destroy_uniform_buffer(buffer) {
      var b = entry(buffer);
      if (!b || !gl) return -1;
      gl.deleteBuffer(b.obj);
      b.obj = null;
      live("uniformBuffer", -1);
      return 1;
    }

    // ------------------------------------------------- shaders / programs
    function gl_create_shader(stage, srcPtr, srcLen, namePtr, nameLen) {
      if (!gl) return 0;
      var name = readUtf8(namePtr, nameLen) || "(unnamed)";
      var shader = gl.createShader(stage);
      if (!shader) return 0;

      gl.shaderSource(shader, readUtf8(srcPtr, srcLen));
      gl.compileShader(shader);

      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        var stageName = stage === gl.VERTEX_SHADER ? "vertex" : "fragment";
        log(stageName + " shader '" + name + "' 编译失败：\n" + gl.getShaderInfoLog(shader));
        gl.deleteShader(shader);
        return 0;
      }

      stats.shaders += 1;
      return add({ kind: "shader", obj: shader, stage: stage, name: name });
    }

    function typeName(type) {
      var names = {};
      names[gl.FLOAT] = "float";
      names[gl.FLOAT_VEC2] = "vec2";
      names[gl.FLOAT_VEC3] = "vec3";
      names[gl.FLOAT_VEC4] = "vec4";
      names[gl.INT] = "int";
      names[gl.SAMPLER_2D] = "sampler2D";
      names[gl.FLOAT_MAT4] = "mat4";
      return names[type] || "0x" + (type >>> 0).toString(16);
    }

    // std140 uniform blocks: binding point = uniform slot (W4)
    //
    // SDL_GPU addresses a uniform buffer by *slot* (HLSL `register(bN, spaceM)`);
    // WebGL2 addresses a uniform block by a *binding point* the app assigns with
    // gl.uniformBlockBinding. A binding point is one flat namespace per context,
    // so vertex slot i -> binding i and fragment slot i -> FRAGMENT_BASE + i
    // (FRAGMENT_BASE = 8 = jfoster's MAX_UNIFORM_BUFFERS). That is the whole
    // table; the block *name* is never looked up, only logged.
    //
    // The vertex/fragment split comes from the GL query, not from the name:
    // UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER / ..._FRAGMENT_SHADER, and within
    // a stage the blocks are numbered in declaration order (GL ES 3.0 assigns
    // block indices vertex-first, followed by fragment).
    var UNIFORM_FRAGMENT_BASE = 8;

    function bindUniformBlocks(program, name) {
      var count = gl.getProgramParameter(program, gl.ACTIVE_UNIFORM_BLOCKS) || 0;
      var blocks = [];
      var vertexSlot = 0;
      var fragmentSlot = 0;
      for (var b = 0; b < count; b += 1) {
        var byVertex = !!gl.getActiveUniformBlockParameter(program, b, gl.UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER);
        var byFragment = !!gl.getActiveUniformBlockParameter(program, b, gl.UNIFORM_BLOCK_REFERENCED_BY_FRAGMENT_SHADER);
        var blockName = gl.getActiveUniformBlockName(program, b) || "";
        var bytes = gl.getActiveUniformBlockParameter(program, b, gl.UNIFORM_BLOCK_DATA_SIZE) | 0;
        var stage = byVertex ? "vertex" : (byFragment ? "fragment" : "none");
        var slot = -1;
        var binding = -1;
        if (byVertex) {
          slot = vertexSlot;
          vertexSlot += 1;
          binding = slot;
        } else if (byFragment) {
          slot = fragmentSlot;
          fragmentSlot += 1;
          binding = UNIFORM_FRAGMENT_BASE + slot;
        }
        if (binding >= 0) gl.uniformBlockBinding(program, b, binding);
        blocks.push({ index: b, name: blockName, bytes: bytes, stage: stage, slot: slot, binding: binding });
      }
      if (blocks.length > 0) {
        log("program '" + name + "' uniform blocks: " + blocks.map(function (b) {
          return b.stage + " slot " + b.slot + " -> binding " + b.binding + " (" + b.name + ", " + b.bytes + "B)";
        }).join(", "));
      }
      return blocks;
    }

    function gl_create_program(vs, fs, namePtr, nameLen) {
      if (!gl) return 0;
      var vertex = entry(vs);
      var fragment = entry(fs);
      if (!vertex || !fragment) return 0;

      var name = readUtf8(namePtr, nameLen) || "(unnamed)";
      var program = gl.createProgram();
      gl.attachShader(program, vertex.obj);
      gl.attachShader(program, fragment.obj);
      gl.linkProgram(program);

      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
        log("program '" + name + "' 链接失败：\n" + gl.getProgramInfoLog(program));
        gl.deleteProgram(program);
        return 0;
      }

      // 记录有哪些 uniform / 属性真的链上了。这是「GLSL 文本进到驱动并活下来」
      // 的唯一客观证据，所以进日志而不是只在出错时说话。
      var uniforms = [];
      var uniformCount = gl.getProgramParameter(program, gl.ACTIVE_UNIFORMS);
      for (var i = 0; i < uniformCount; i += 1) {
        var info = gl.getActiveUniform(program, i);
        if (info) uniforms.push(info.name + ":" + typeName(info.type));
      }

      var attributeNames = [];
      var locs = {};
      var attributeCount = gl.getProgramParameter(program, gl.ACTIVE_ATTRIBUTES);
      for (var a = 0; a < attributeCount; a += 1) {
        var attrib = gl.getActiveAttrib(program, a);
        if (!attrib) continue;
        var loc = gl.getAttribLocation(program, attrib.name);
        attributeNames.push(attrib.name + "@" + loc);
        locs[loc] = true;
      }

      log("program '" + name + "' 链上：uniforms=[" + (uniforms.join(", ") || "") +
          "] attribs=[" + (attributeNames.join(", ") || "") + "]");

      var blocks = bindUniformBlocks(program, name);

      stats.programs += 1;
      live("program", 1);
      return add({
        kind: "program", obj: program, name: name, blocks: blocks,
        uniformCache: {}, samplerUnits: {}, attribLocations: locs,
      });
    }

    function gl_destroy_program(program) {
      var p = entry(program);
      if (!p || !gl) return -1;
      gl.deleteProgram(p.obj);
      p.obj = null;
      live("program", -1);
      return 1;
    }

    function gl_destroy_shader(shader) {
      var s = entry(shader);
      if (!s || !gl) return -1;
      gl.deleteShader(s.obj);
      s.obj = null;
      return 1;
    }

    // --------------------------------------------------- pipeline (VAO)
    // 属性表：每个属性 8 个 s32（slot, location, size, type, normalized,
    // stride, offset, divisor）。JS 侧记下来，因为 vertexAttribPointer 必须在
    // 真 buffer 绑上之后才调用（VAO 记的是"哪个 buffer + 哪个偏移"）。
    function gl_create_pipeline(programId, attrsPtr, attrCount) {
      var p = entry(programId);
      if (!p || !gl) return 0;

      var vao = gl.createVertexArray();
      if (!vao) return 0;

      var attrs = [];
      var view = new DataView(getMemory().buffer);
      var base = attrsPtr >>> 0;

      gl.bindVertexArray(vao);
      for (var i = 0; i < (attrCount | 0); i += 1) {
        var at = base + i * 32;
        var attr = {
          slot: view.getInt32(at + 0, true),
          loc: view.getInt32(at + 4, true),
          size: view.getInt32(at + 8, true),
          type: view.getInt32(at + 12, true),
          normalized: view.getInt32(at + 16, true) !== 0,
          stride: view.getInt32(at + 20, true),
          offset: view.getInt32(at + 24, true),
          divisor: view.getInt32(at + 28, true),
          enabled: false,
        };
        // 只 enable 这个 program 真有的 location：enable 了却没设指针的属性能让
        // 整次 draw 变成 INVALID_OPERATION。
        if (p.attribLocations[attr.loc]) {
          gl.enableVertexAttribArray(attr.loc);
          attr.enabled = true;
        }
        attrs.push(attr);
      }
      gl.bindVertexArray(null);

      stats.pipelines += 1;
      live("pipeline", 1);
      return add({ kind: "pipeline", obj: vao, program: p, attrs: attrs });
    }

    function gl_destroy_pipeline(pipeline) {
      var p = entry(pipeline);
      if (!p || !gl) return -1;
      gl.deleteVertexArray(p.obj);
      p.obj = null;
      live("pipeline", -1);
      return 1;
    }

    // ShaderPairTryReplace probe cleanup: a probe pipeline owns the throw-away
    // program it was built from (the draw path's pipelines borrow a cached one).
    function gl_release_pipeline_with_program(pipeline) {
      var p = entry(pipeline);
      if (!p || !gl) return -1;
      gl.deleteVertexArray(p.obj);
      p.obj = null;
      live("pipeline", -1);
      if (p.program && p.program.obj) {
        gl.deleteProgram(p.program.obj);
        p.program.obj = null;
        live("program", -1);
      }
      return 1;
    }

    function gl_bind_pipeline(pipeline) {
      var p = entry(pipeline);
      if (!p || !gl) return -1;
      gl.bindVertexArray(p.obj);
      gl.useProgram(p.program.obj);
      return 1;
    }

    function gl_bind_vertex_buffer(pipeline, slot, buffer) {
      var p = entry(pipeline);
      var b = entry(buffer);
      if (!p || !b || !gl) return -1;
      gl.bindVertexArray(p.obj);          // 指针要落进这个 VAO
      gl.bindBuffer(gl.ARRAY_BUFFER, b.obj);
      for (var i = 0; i < p.attrs.length; i += 1) {
        var attr = p.attrs[i];
        if (attr.slot !== (slot | 0) || !attr.enabled) continue;
        gl.vertexAttribPointer(attr.loc, attr.size, attr.type, attr.normalized, attr.stride, attr.offset);
        gl.vertexAttribDivisor(attr.loc, attr.divisor);
      }
      return 1;
    }

    function gl_bind_index_buffer(buffer) {
      var b = entry(buffer);
      if (!b || !gl) return -1;
      // ELEMENT_ARRAY_BUFFER 绑定记在当前 VAO 上（gl_bind_pipeline 刚绑好）
      gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, b.obj);
      return 1;
    }

    // --------------------------------------------------- uniforms / samplers
    function gl_bind_sampler(programId, unit, texture, sampler, namePtr, nameLen) {
      var p = entry(programId);
      if (!p || !gl) return -1;

      gl.activeTexture(gl.TEXTURE0 + (unit | 0));
      var t = entry(texture);
      gl.bindTexture(gl.TEXTURE_2D, t ? t.obj : null);
      var s = entry(sampler);
      gl.bindSampler(unit | 0, s ? s.obj : null);

      // sampler2D uniform 只需要设一次（纹理单元固定等于槽位号）
      var name = readUtf8(namePtr, nameLen);
      if (name && p.samplerUnits[name] !== (unit | 0)) {
        var loc = uniformLoc(p, name);
        if (loc !== null) {
          gl.uniform1i(loc, unit | 0);
          p.samplerUnits[name] = unit | 0;
        }
      }
      return 1;
    }

    // ------------------------------------------------------- per-draw state
    function gl_set_blend(enable, srcColor, dstColor, colorOp, srcAlpha, dstAlpha, alphaOp, colorMaskBits) {
      if (!gl) return -1;
      if (enable) {
        gl.enable(gl.BLEND);
        gl.blendEquationSeparate(colorOp, alphaOp);
        gl.blendFuncSeparate(srcColor, dstColor, srcAlpha, dstAlpha);
      } else {
        gl.disable(gl.BLEND);
      }
      gl.colorMask(
        (colorMaskBits & 1) !== 0, (colorMaskBits & 2) !== 0,
        (colorMaskBits & 4) !== 0, (colorMaskBits & 8) !== 0
      );
      return 1;
    }

    function gl_set_cull(mode) {
      if (!gl) return -1;
      if (mode === 0) {
        gl.disable(gl.CULL_FACE);
      } else {
        gl.enable(gl.CULL_FACE);
        gl.cullFace(mode);
      }
      return 1;
    }

    function gl_set_depth(test, write, compare) {
      if (!gl) return -1;
      if (test) gl.enable(gl.DEPTH_TEST); else gl.disable(gl.DEPTH_TEST);
      gl.depthMask(write !== 0);
      gl.depthFunc(compare);
      return 1;
    }

    var lastStencil = null;

    function gl_set_stencil(enable, ref, compareMask, writeMask, backCompare, backPass, backFail, backDepthFail,
                            frontCompare, frontPass, frontFail, frontDepthFail) {
      if (!gl) return -1;
      if (enable) {
        gl.enable(gl.STENCIL_TEST);
        gl.stencilMask(writeMask);
        gl.stencilFuncSeparate(gl.FRONT, frontCompare, ref, compareMask);
        gl.stencilFuncSeparate(gl.BACK, backCompare, ref, compareMask);
        gl.stencilOpSeparate(gl.FRONT, frontFail, frontDepthFail, frontPass);
        gl.stencilOpSeparate(gl.BACK, backFail, backDepthFail, backPass);
      } else {
        gl.disable(gl.STENCIL_TEST);
      }
      return 1;
    }

    function gl_set_viewport(x, y, w, h) {
      if (!gl) return -1;
      var height = targetHeight || gl.drawingBufferHeight;
      // 调用方用左上原点；GL 是左下原点。
      gl.viewport(x | 0, (height - (y | 0) - (h | 0)) | 0, w | 0, h | 0);
      return 1;
    }

    function gl_set_scissor(x, y, w, h, enabled) {
      if (!gl) return -1;
      if (!enabled) {
        gl.disable(gl.SCISSOR_TEST);
        return 1;
      }
      var height = targetHeight || gl.drawingBufferHeight;
      gl.enable(gl.SCISSOR_TEST);
      gl.scissor(x | 0, (height - (y | 0) - (h | 0)) | 0, w | 0, h | 0);
      return 1;
    }

    // -------------------------------------------------------- render pass
    function gl_begin_render_pass(framebuffer, width, height) {
      if (!gl) return -1;
      // framebuffer 0 = canvas 的默认 framebuffer（null）；>0 = W5 的离屏 target。
      if ((framebuffer | 0) > 0) {
        var f = entry(framebuffer);
        if (!f) {
          log("gl_begin_render_pass: framebuffer id " + framebuffer + " 不存在");
          currentFbo = null;
          gl.bindFramebuffer(gl.FRAMEBUFFER, null);
          return -1;
        }
        currentFbo = f.obj;
        f.width = width | 0;
        f.height = height | 0;
      } else {
        currentFbo = null;
      }
      gl.bindFramebuffer(gl.FRAMEBUFFER, currentFbo);
      targetWidth = width | 0;
      targetHeight = height | 0;
      gl.viewport(0, 0, targetWidth, targetHeight);
      // clear 不受上一次 pass 的 scissor 影响
      gl.disable(gl.SCISSOR_TEST);
      return 1;
    }

    function gl_clear(r, g, b, a, colorMask, depth, stencil, depthMask, stencilMask) {
      if (!gl) return -1;
      gl.disable(gl.SCISSOR_TEST); // 见 gl_begin_render_pass 的同一条注释
      var bits = 0;
      if (colorMask) {
        gl.clearColor((r | 0) / 255, (g | 0) / 255, (b | 0) / 255, (a | 0) / 255);
        bits |= gl.COLOR_BUFFER_BIT;
      }
      if (depthMask) {
        gl.depthMask(true);
        gl.clearDepth(depth);
        bits |= gl.DEPTH_BUFFER_BIT;
      }
      if (stencilMask) {
        gl.stencilMask(0xff);
        gl.clearStencil(stencil | 0);
        bits |= gl.STENCIL_BUFFER_BIT;
      }
      if (bits !== 0) gl.clear(bits);
      if (!depthMask) gl.depthMask(false);
      stats.clears += 1;
      return 1;
    }

    function gl_end_render_pass() {
      if (!gl) return -1;
      // WebGL2 没有 pass 对象，但**有**「当前绑定的 framebuffer」：关掉一个离屏
      // pass 之后必须回到 canvas，否则下一次 gl_read_pixels（读 canvas）会去读
      // 那个 target，而画到窗口的下一帧会继续画到离屏纹理上。
      //
      // 多重采样的 resolve 不在这里做：Jai 侧要先 blit 再关 pass（它需要知道
      // resolve 目标是谁），见 graphics_device_web.jai :: sdl_end_render_pass。
      currentFbo = null;
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      targetWidth = canvas ? canvas.width | 0 : gl.drawingBufferWidth | 0;
      targetHeight = canvas ? canvas.height | 0 : gl.drawingBufferHeight | 0;
      return 1;
    }

    // --------------------------------------------------------- draw calls
    function gl_draw(mode, first, count, instances) {
      if (!gl) return -1;
      if ((count | 0) <= 0) return 0;
      if ((instances | 0) > 1) gl.drawArraysInstanced(mode, first | 0, count | 0, instances | 0);
      else gl.drawArrays(mode, first | 0, count | 0);
      stats.draws += 1;
      return 1;
    }

    function gl_draw_indexed(mode, count, elementType, offsetBytes, instances, baseVertex) {
      if (!gl) return -1;
      if ((count | 0) <= 0) return 0;
      if ((baseVertex | 0) !== 0) {
        logOnce("basevertex", "WebGL2 没有 drawElementsBaseVertex —— baseVertex=" + baseVertex + " 被忽略");
      }
      if ((instances | 0) > 1) {
        gl.drawElementsInstanced(mode, count | 0, elementType, Math.max(0, offsetBytes | 0), instances | 0);
      } else {
        gl.drawElements(mode, count | 0, elementType, Math.max(0, offsetBytes | 0));
      }
      stats.draws += 1;
      return 1;
    }

    // ------------------------------------------------------------ readback
    //
    // [W6] 多了一个 framebuffer 参数（Jai 侧 web_gl_readback_fbo 算出来）：
    //   -1 / undefined = 保持当前绑定（W3/W4 的行为）
    //    0            = canvas 的默认 framebuffer（窗口级 MSAA 解析后的落点）
    //   >0            = 某个离屏 FBO（target 的单采样 FBO）
    //
    // 为什么必须显式指定：窗口级 MSAA 打开后 currentFbo 是那张**多重采样** FBO，
    // 而 WebGL2 的 readPixels 不允许读 MS 附件（INVALID_OPERATION）—— 读回必须
    // 打在 resolve 之后的 0 号 FBO 上（Jai 侧已经先 blit 过了）。
    function gl_read_pixels(x, y, w, h, ptr, length, framebuffer) {
      if (!gl) return -1;
      var bind = (framebuffer === undefined || framebuffer === null) ? -1 : framebuffer | 0;
      var height = targetHeight || gl.drawingBufferHeight;
      var sourceFbo = currentFbo;

      if (bind >= 0) {
        if (bind === 0) {
          sourceFbo = null;
          height = targetHeight || gl.drawingBufferHeight;
        } else {
          var f = entry(bind);
          if (!f) {
            log("gl_read_pixels: framebuffer id " + bind + " 不存在");
            return -1;
          }
          sourceFbo = f.obj;
          // 离屏 FBO 的高度得自己记着（gl_begin_render_pass 记过一次；这次读的
          // 若是从没被 begin 过的 target，就用调用方要读的那一行反推不出来，
          // 只能退化到当前 pass 的高度 —— 那种情况读出来是空的，本来也不是
          // 有效路径）。
          if (f.height > 0) height = f.height;
        }
      }

      gl.bindFramebuffer(gl.FRAMEBUFFER, sourceFbo);
      try {
        // 左上坐标 → GL 的左下坐标
        gl.readPixels(x | 0, (height - (y | 0) - (h | 0)) | 0, w | 0, h | 0,
          gl.RGBA, gl.UNSIGNED_BYTE, memBytes(ptr, length));
      } catch (error) {
        log("readPixels 抛异常：" + error.message);
        gl.bindFramebuffer(gl.FRAMEBUFFER, currentFbo);
        return -1;
      }
      var readError = gl.getError();
      if (readError !== gl.NO_ERROR) {
        // 典型原因：从多重采样 FBO 读（INVALID_OPERATION）、越界（INVALID_VALUE）。
        log("readPixels 报 GL error 0x" + readError.toString(16) +
            "（" + (w | 0) + "x" + (h | 0) + " @ " + (x | 0) + "," + (y | 0) + "，fbo=" + bind + "）");
        stats.errors += 1;
        gl.bindFramebuffer(gl.FRAMEBUFFER, currentFbo);
        return -1;
      }
      gl.bindFramebuffer(gl.FRAMEBUFFER, currentFbo);
      stats.readbacks += 1;
      stats.pixelsRead += (w | 0) * (h | 0);
      return 1;
    }

    function gl_stats(which) {
      if (which === 0) return stats.draws;
      if (which === 1) return stats.passes;
      if (which === 2) return stats.clears;
      if (which === 3) return stats.textureUploads;
      if (which === 4) return stats.bufferUploads;
      if (which === 5) return stats.shaders;
      if (which === 6) return stats.programs;
      if (which === 7) return stats.pipelines;
      if (which === 8) return stats.readbacks;
      if (which === 9) return stats.pixelsRead;
      if (which === 10) return stats.errors;
      if (which === 11) return gl ? 1 : 0;
      if (which === 12) return stats.uniformUploads;
      if (which === 13) return stats.uniformBindings;
      // [W5] target / MSAA / blit
      if (which === 14) return stats.framebuffers;
      if (which === 15) return stats.renderbuffers;
      if (which === 16) return stats.blits;
      if (which === 17) return stats.failedBlits;
      if (which === 18) return stats.incompleteFbos;
      // [W6] 存活对象计数（内存稳定性用；上面那五个是累计值）
      if (which === 19) return stats.live.texture;
      if (which === 20) return stats.live.buffer;
      if (which === 21) return stats.live.program;
      if (which === 22) return stats.live.pipeline;
      if (which === 23) return stats.live.framebuffer;
      if (which === 24) return stats.live.renderbuffer;
      if (which === 25) return stats.live.sampler;
      if (which === 26) return stats.live.uniformBuffer;
      // 27 = MAX_TEXTURE_SIZE（Jai 侧 web_gl.jai 自己也有一份；这里给宿主报告用）
      if (which === 27) return gl ? gl.getParameter(gl.MAX_TEXTURE_SIZE) | 0 : 0;
      // 28 = 预留（premultipliedAlpha / preserveDrawingBuffer 的实际取值，见 gl_device_create）
      if (which === 28) return preserveDrawingBuffer ? 1 : 0;
      return -1;
    }

    return {
      gl_device_create: gl_device_create,
      gl_device_destroy: gl_device_destroy,
      gl_swapchain_bind: gl_swapchain_bind,
      gl_present: gl_present,
      gl_get_error: gl_get_error,
      gl_get_string: gl_get_string,
      gl_get_param: gl_get_param,
      gl_create_texture: gl_create_texture,
      gl_set_texture_data: gl_set_texture_data,
      gl_get_texture_data: gl_get_texture_data,
      gl_destroy_texture: gl_destroy_texture,
      gl_create_buffer: gl_create_buffer,
      gl_set_buffer_data: gl_set_buffer_data,
      gl_destroy_buffer: gl_destroy_buffer,
      gl_create_sampler: gl_create_sampler,
      gl_destroy_sampler: gl_destroy_sampler,
      gl_create_uniform_buffer: gl_create_uniform_buffer,
      gl_set_uniform_buffer_data: gl_set_uniform_buffer_data,
      gl_bind_uniform_buffer: gl_bind_uniform_buffer,
      gl_destroy_uniform_buffer: gl_destroy_uniform_buffer,
      gl_create_shader: gl_create_shader,
      gl_create_program: gl_create_program,
      gl_destroy_shader: gl_destroy_shader,
      gl_destroy_program: gl_destroy_program,
      gl_create_pipeline: gl_create_pipeline,
      gl_destroy_pipeline: gl_destroy_pipeline,
      gl_release_pipeline_with_program: gl_release_pipeline_with_program,
      gl_begin_render_pass: gl_begin_render_pass,
      gl_clear: gl_clear,
      gl_end_render_pass: gl_end_render_pass,
      gl_bind_pipeline: gl_bind_pipeline,
      gl_bind_vertex_buffer: gl_bind_vertex_buffer,
      gl_bind_index_buffer: gl_bind_index_buffer,
      gl_bind_sampler: gl_bind_sampler,
      gl_set_blend: gl_set_blend,
      gl_set_cull: gl_set_cull,
      gl_set_depth: gl_set_depth,
      gl_set_stencil: gl_set_stencil,
      gl_set_viewport: gl_set_viewport,
      gl_set_scissor: gl_set_scissor,
      gl_draw: gl_draw,
      gl_draw_indexed: gl_draw_indexed,
      gl_read_pixels: gl_read_pixels,
      gl_stats: gl_stats,
      // [W5] render-to-target / MSAA / blit
      gl_create_framebuffer: gl_create_framebuffer,
      gl_destroy_framebuffer: gl_destroy_framebuffer,
      gl_attach_texture: gl_attach_texture,
      gl_create_renderbuffer: gl_create_renderbuffer,
      gl_destroy_renderbuffer: gl_destroy_renderbuffer,
      gl_attach_renderbuffer: gl_attach_renderbuffer,
      gl_framebuffer_status: gl_framebuffer_status,
      gl_blit_framebuffer: gl_blit_framebuffer,
    };
  }

  // =================================================== env.* 实现（第 1 组）
  function makeEnv(deps) {
    var getMemory = deps.getMemory;
    var sink = deps.sink;
    var storage = deps.storage;
    var events = deps.events;
    var dom = deps.dom; // 浏览器 DOM 环境；Node 下是 null
    var decoder = new TextDecoder("utf-8");
    var encoder = new TextEncoder();

    function view() {
      return new DataView(getMemory().buffer);
    }

    function readUtf8(ptr, len) {
      var offset = Number(ptr) | 0;
      var count = Number(len) | 0;
      if (count <= 0) return "";
      return decoder.decode(new Uint8Array(getMemory().buffer, offset, count));
    }

    function writeInt32(ptr, value) {
      view().setInt32(Number(ptr) | 0, value | 0, true);
    }

    function writeUtf8(ptr, capacity, text) {
      var bytes = encoder.encode(text);
      var count = Math.min(capacity, bytes.length);
      if (count > 0) new Uint8Array(getMemory().buffer, Number(ptr) | 0, count).set(bytes.subarray(0, count));
      return bytes.length;
    }

    // ---------------------------------------------------------------- 日志
    function fw_log(ptr, len) {
      var text = readUtf8(ptr, len);
      if (text) sink.write(text);
    }

    // ---------------------------------------------------------------- 时钟
    function fw_now_ms() {
      return typeof performance !== "undefined" ? performance.now() : Date.now();
    }

    // [W6] 线性内存当前字节数。内存 soak 的唯一直接读数：
    // Jai 侧的缓存表只能证明「对象没变多」，证明不了「内存没涨」——
    // 每帧分配再丢弃的临时缓冲在表里看不见，在 memory.buffer.byteLength 上看得见。
    function fw_memory_bytes() {
      var memory = getMemory();
      if (!memory || !memory.buffer) return -1;
      return memory.buffer.byteLength | 0;
    }

    // --------------------------------------------------------------- canvas
    function fw_canvas_size(widthOff, heightOff) {
      var size = dom ? dom.canvasSize() : { width: 0, height: 0 };
      writeInt32(widthOff, size.width);
      writeInt32(heightOff, size.height);
    }

    function fw_pixel_ratio() {
      return dom ? dom.pixelRatio() : 1;
    }

    // ------------------------------------------------------------- 窗口/DOM
    function fw_set_title(ptr, len) {
      if (!dom) return -1;
      return dom.setTitle(readUtf8(ptr, len));
    }

    function fw_request_fullscreen(on) {
      if (!dom) return -1;
      return dom.requestFullscreen(on !== 0);
    }

    function fw_set_cursor_css(ptr, len) {
      if (!dom) return -1;
      return dom.setCursor(readUtf8(ptr, len));
    }

    function fw_mouse_relative(on) {
      if (!dom) return -1;
      return dom.setPointerLock(on !== 0);
    }

    function fw_text_input_area(x, y, w, h, on) {
      if (!dom) return -1;
      return dom.setTextInputArea(x, y, w, h, on !== 0);
    }

    // ---------------------------------------------------------------- 剪贴板
    function fw_clipboard_set(ptr, len) {
      var text = readUtf8(ptr, len);
      if (dom) dom.clipboardSet(text);
      return text.length;
    }

    function fw_clipboard_get(buf, cap) {
      var text = dom ? dom.clipboardGet() : "";
      if (!text) return 0;
      return writeUtf8(buf, cap, text);
    }

    // ------------------------------------------------------------------ 存档
    function fw_storage_read(keyPtr, keyLen, buf, cap) {
      var key = readUtf8(keyPtr, keyLen);
      if (!key) return -1;
      return storage.readBytes(key, getMemory().buffer, Number(buf) | 0, cap | 0);
    }

    function fw_storage_write(keyPtr, keyLen, valPtr, valLen) {
      var key = readUtf8(keyPtr, keyLen);
      if (!key) return -1;
      return storage.writeBytes(key, getMemory().buffer, Number(valPtr) | 0, valLen | 0);
    }

    function fw_storage_remove(keyPtr, keyLen) {
      var key = readUtf8(keyPtr, keyLen);
      if (!key) return -1;
      return storage.remove(key);
    }

    function fw_storage_list(prefixPtr, prefixLen, buf, cap) {
      var prefix = readUtf8(prefixPtr, prefixLen);
      var lines = storage.list(prefix).join("\n");
      return writeUtf8(buf, cap | 0, lines);
    }

    // ------------------------------------------------------------ DOM 事件
    function fw_dom_event_push(recPtr, cap) {
      if ((cap | 0) < 1) return 0;
      var rec = events.pop();
      if (!rec) return 0;
      var dv = view();
      var base = Number(recPtr) | 0;
      dv.setInt32(base + 0, rec.kind | 0, true);
      dv.setInt32(base + 4, rec.a | 0, true);
      dv.setInt32(base + 8, rec.b | 0, true);
      dv.setInt32(base + 12, rec.c | 0, true);
      dv.setInt32(base + 16, rec.d | 0, true);
      dv.setInt32(base + 20, 0, true);
      return 1;
    }

    // -------------------------------------------------------------- Gamepad
    function fw_gamepad_poll(recPtr, count) {
      if (!dom) return 0;
      var pads = dom.gamepads();
      var max = count | 0;
      var dv = view();
      var base = Number(recPtr) | 0;
      var written = 0;

      for (var slot = 0; slot < max; slot++) {
        var rec = base + slot * GAMEPAD.BYTES;
        var pad = slot < pads.length ? pads[slot] : null;

        // 先整体清零，没接手柄的槽位也必须是一条合法的「未连接」记录。
        new Uint8Array(getMemory().buffer, rec, GAMEPAD.BYTES).fill(0);

        if (!pad) continue;

        var nameBytes = encoder.encode(pad.name || "");
        nameBytes = nameBytes.subarray(0, GAMEPAD.NAME_MAX);

        dv.setInt32(rec + 0, 1, true); // connected
        dv.setInt32(rec + 4, pad.index | 0, true);
        dv.setInt32(rec + 8, Math.min(pad.buttons.length, GAMEPAD.BUTTONS_MAX), true);
        dv.setInt32(rec + 12, Math.min(pad.axes.length, GAMEPAD.AXES_MAX), true);
        dv.setInt32(rec + 16, nameBytes.length, true);
        dv.setInt32(rec + 20, 0, true); // vendor：Gamepad API 不暴露 USB vendor id
        dv.setInt32(rec + 24, 0, true); // product
        dv.setInt32(rec + 28, pad.index | 0, true);

        if (nameBytes.length > 0) {
          new Uint8Array(getMemory().buffer, rec + GAMEPAD.NAME_OFF, nameBytes.length).set(nameBytes);
        }

        for (var i = 0; i < GAMEPAD.AXES_MAX; i++) {
          dv.setFloat32(rec + GAMEPAD.AXES_OFF + i * 4, i < pad.axes.length ? pad.axes[i] : 0, true);
        }

        var buttonCount = Math.min(pad.buttons.length, GAMEPAD.BUTTONS_MAX);
        for (var b = 0; b < buttonCount; b++) {
          var target = W3C_TO_SDL_BUTTON[b];
          if (typeof target === "undefined") continue;
          var pressed = pad.buttons[b] && (pad.buttons[b].pressed || pad.buttons[b].value > 0.5);
          if (pressed) {
            new Uint8Array(getMemory().buffer, rec + GAMEPAD.BUTTONS_OFF + target, 1)[0] = 1;
          }
          // 扳机同时喂给轴 4/5（SDL 的语义：扳机是轴）
          if (W3C_TRIGGER_AXIS[b] !== undefined) {
            var value = pad.buttons[b] ? pad.buttons[b].value || 0 : 0;
            dv.setFloat32(rec + GAMEPAD.AXES_OFF + W3C_TRIGGER_AXIS[b] * 4, value, true);
          }
        }

        written++;
      }

      return written;
    }

    // gl_*（W3）：平铺进同一个 env 命名空间 —— wasm 的 import module 只有一个
    // `env`，makeGl() 返回的正是这张函数表。
    return Object.assign({
      fw_log: fw_log,
      fw_now_ms: fw_now_ms,
      fw_memory_bytes: fw_memory_bytes,
      fw_canvas_size: fw_canvas_size,
      fw_pixel_ratio: fw_pixel_ratio,
      fw_set_title: fw_set_title,
      fw_request_fullscreen: fw_request_fullscreen,
      fw_set_cursor_css: fw_set_cursor_css,
      fw_clipboard_get: fw_clipboard_get,
      fw_clipboard_set: fw_clipboard_set,
      fw_storage_read: fw_storage_read,
      fw_storage_write: fw_storage_write,
      fw_storage_list: fw_storage_list,
      fw_storage_remove: fw_storage_remove,
      fw_dom_event_push: fw_dom_event_push,
      fw_mouse_relative: fw_mouse_relative,
      fw_text_input_area: fw_text_input_area,
      fw_gamepad_poll: fw_gamepad_poll,
    }, deps.gl || {});
  }

  // ===================================================== 事件队列（JS 侧）
  function makeEventQueue() {
    var queue = [];
    var total = 0;
    return {
      push: function (kind, a, b, c, d) {
        queue.push({
          kind: kind | 0,
          a: (a | 0) || 0,
          b: (b | 0) || 0,
          c: (c | 0) || 0,
          d: (d | 0) || 0,
        });
        total++;
        // 防止「Jai 侧不再拉」时无限增长（比如页面在后台跑了很久）
        if (queue.length > 4096) queue.splice(0, queue.length - 4096);
      },
      pop: function () {
        return queue.length > 0 ? queue.shift() : null;
      },
      get length() {
        return queue.length;
      },
      get total() {
        return total;
      },
    };
  }

  // ============================================================ 浏览器 DOM
  //
  // 只在真的浏览器里存在；Node 下 dom = null，于是所有 DOM 相关导入返回 -1
  // （「不支持」），而事件队列永远是空的。
  function attachDom(options) {
    if (typeof root.document === "undefined" || !root.document) return null;

    var canvas = options.canvas || root.document.getElementById("stage");
    var events = options.events;
    var sink = options.sink;
    var log = function (text) {
      sink.write("[dom] " + text + "\n");
    };

    var clipboardCache = "";

    function canvasSize() {
      if (!canvas) return { width: 0, height: 0 };
      return { width: canvas.width | 0, height: canvas.height | 0 };
    }

    function resizeCanvasToCss() {
      if (!canvas) return;
      var rect = canvas.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return;
      var ratio = root.devicePixelRatio || 1;
      canvas.width = Math.max(1, Math.round(rect.width * ratio));
      canvas.height = Math.max(1, Math.round(rect.height * ratio));
    }

    // ------------------------------------------------------- 隐藏 input（IME）
    var textInput = root.document.createElement("input");
    textInput.type = "text";
    textInput.autocomplete = "off";
    textInput.setAttribute("autocorrect", "off");
    textInput.setAttribute("autocapitalize", "off");
    textInput.setAttribute("spellcheck", "false");
    textInput.style.position = "absolute";
    textInput.style.opacity = "0";
    textInput.style.pointerEvents = "none";
    textInput.style.border = "0";
    textInput.style.padding = "0";
    textInput.style.background = "transparent";
    textInput.style.display = "none";
    root.document.body.appendChild(textInput);

    function pushText(text) {
      if (!text) return;
      for (var i = 0; i < text.length; ) {
        var cp = text.codePointAt(i);
        events.push(EV.TEXT, cp, 0, 0, 0);
        i += cp > 0xffff ? 2 : 1;
      }
      textInput.value = "";
    }

    textInput.addEventListener("input", function () {
      pushText(textInput.value);
    });
    textInput.addEventListener("compositionend", function () {
      pushText(textInput.value);
    });
    textInput.addEventListener("keydown", function (e) {
      // 让按键继续走 canvas/window 那条路（否则 IME 打开时 WASD 就没了）。
      // 但回车/退格在这里是「文本编辑」，不该触发游戏动作。
      if (e.code === "Enter" || e.code === "Escape") {
        textInput.value = "";
        if (e.code === "Escape") textInput.blur();
      }
    });

    // ------------------------------------------------------------ 键盘
    function onKeyDown(e) {
      var scancode = scancodeFromCode(e.code);
      if (scancode === 0) return; // 表里没有的键：不猜

      events.push(EV.KEY_DOWN, scancode, e.repeat ? 1 : 0, 0, 0);

      // 文本输入：可打印字符 + 没按修饰键。IME 输入的字符走上面的 input 事件。
      if (textInput.style.display !== "none" && e.key && e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
        // 交给 input 元素自己产生 input 事件，避免同一次按键报两遍。
      }

      // Tab 会把焦点移走（canvas 失去 keydown），Space 会滚动页面 —— 游戏里都不想要。
      if (e.code === "Tab" || e.code === "Space" || e.code.indexOf("Arrow") === 0) {
        e.preventDefault();
      }
    }

    function onKeyUp(e) {
      var scancode = scancodeFromCode(e.code);
      if (scancode === 0) return;
      events.push(EV.KEY_UP, scancode, 0, 0, 0);
    }

    // ------------------------------------------------------------ 指针
    var pointerRelative = false;

    function pushPointer(kind, e) {
      var rect = canvas ? canvas.getBoundingClientRect() : { left: 0, top: 0 };
      var x = e.clientX - rect.left;
      var y = e.clientY - rect.top;
      if (kind === EV.POINTER_MOVE) {
        events.push(kind, x, y, e.movementX || 0, e.movementY || 0);
      } else {
        events.push(kind, e.button + 1, x, y, 0); // DOM 0=左 → SDL 1=左
      }
    }

    function onPointerDown(e) {
      if (canvas) canvas.focus();
      pushPointer(EV.POINTER_DOWN, e);
      if (canvas) {
        try {
          canvas.setPointerCapture(e.pointerId);
        } catch (err) {
          /* 某些浏览器对合成事件会拒绝，忽略 */
        }
      }
    }

    function onPointerUp(e) {
      pushPointer(EV.POINTER_UP, e);
      if (canvas) {
        try {
          canvas.releasePointerCapture(e.pointerId);
        } catch (err) {}
      }
    }

    function onPointerMove(e) {
      pushPointer(EV.POINTER_MOVE, e);
    }

    function onWheel(e) {
      // SDL 的 wheel 单位是「行」，DOM 的 deltaY 是像素（一格约 100）。
      events.push(EV.WHEEL, Math.round(e.deltaX), Math.round(e.deltaY), 0, 0);
      e.preventDefault();
    }

    function onFocus() {
      events.push(EV.FOCUS, 0, 0, 0, 0);
      refreshClipboard();
    }

    function onBlur() {
      events.push(EV.BLUR, 0, 0, 0, 0);
    }

    function onVisibility() {
      events.push(EV.VISIBILITY, root.document.hidden ? 0 : 1, 0, 0, 0);
    }

    function pushResize() {
      resizeCanvasToCss();
      if (!canvas) return;
      var rect = canvas.getBoundingClientRect();
      events.push(
        EV.RESIZE,
        Math.round(rect.width),
        Math.round(rect.height),
        canvas.width,
        canvas.height
      );
    }

    // ---------------------------------------------------------- 剪贴板
    function refreshClipboard() {
      var clip = root.navigator && root.navigator.clipboard;
      if (!clip || typeof clip.readText !== "function") return;
      clip.readText()
        .then(function (text) {
          clipboardCache = text || "";
        })
        .catch(function () {
          /* 没有权限：保持缓存不变 */
        });
    }

    // ------------------------------------------------------------ 安装
    if (canvas) {
      canvas.tabIndex = 0; // 让 canvas 能收 keydown
      canvas.style.outline = "none";
      canvas.addEventListener("pointerdown", onPointerDown);
      canvas.addEventListener("pointerup", onPointerUp);
      canvas.addEventListener("pointermove", onPointerMove);
      canvas.addEventListener("wheel", onWheel, { passive: false });
      canvas.addEventListener("contextmenu", function (e) {
        e.preventDefault();
      });
      resizeCanvasToCss();
    }

    root.addEventListener("keydown", onKeyDown);
    root.addEventListener("keyup", onKeyUp);
    root.addEventListener("focus", onFocus);
    root.addEventListener("blur", onBlur);
    root.document.addEventListener("visibilitychange", onVisibility);
    root.addEventListener("resize", pushResize);
    root.document.addEventListener("pointerlockchange", function () {
      pointerRelative = root.document.pointerLockElement === canvas;
    });

    refreshClipboard();
    log("canvas=" + (canvas ? canvas.width + "x" + canvas.height : "无") +
        " dpr=" + (root.devicePixelRatio || 1) +
        " 键表=" + Object.keys(SCANCODE).length + " 项");

    return {
      canvas: canvas,
      canvasSize: canvasSize,
      pixelRatio: function () {
        return root.devicePixelRatio || 1;
      },
      setTitle: function (title) {
        root.document.title = title;
        return title.length;
      },
      requestFullscreen: function (on) {
        try {
          if (on) {
            var el = canvas || root.document.documentElement;
            if (el.requestFullscreen) {
              var p = el.requestFullscreen();
              if (p && p.catch) p.catch(function () {});
            }
          } else if (root.document.fullscreenElement && root.document.exitFullscreen) {
            var q = root.document.exitFullscreen();
            if (q && q.catch) q.catch(function () {});
          }
          return 1;
        } catch (e) {
          return -1;
        }
      },
      setCursor: function (css) {
        if (!canvas) return -1;
        canvas.style.cursor = css;
        return css.length;
      },
      setPointerLock: function (on) {
        try {
          if (on) {
            if (canvas && canvas.requestPointerLock) {
              var p = canvas.requestPointerLock();
              if (p && p.catch) p.catch(function () {});
            }
          } else if (root.document.exitPointerLock) {
            root.document.exitPointerLock();
          }
          return 1;
        } catch (e) {
          return -1;
        }
      },
      setTextInputArea: function (x, y, w, h, on) {
        if (!on) {
          textInput.style.display = "none";
          textInput.blur();
          return 0;
        }
        var rect = canvas ? canvas.getBoundingClientRect() : { left: 0, top: 0 };
        textInput.style.display = "block";
        textInput.style.left = rect.left + x + "px";
        textInput.style.top = rect.top + y + "px";
        textInput.style.width = Math.max(1, w) + "px";
        textInput.style.height = Math.max(1, h) + "px";
        // 不主动 focus()：静默抢焦点会让 pointer lock 和 canvas keydown 都失效。
        // 真正的焦点由点击 canvas / 调用方决定。
        return 1;
      },
      clipboardGet: function () {
        return clipboardCache;
      },
      clipboardSet: function (text) {
        clipboardCache = text;
        var clip = root.navigator && root.navigator.clipboard;
        if (clip && typeof clip.writeText === "function") {
          clip.writeText(text).catch(function (e) {
            log("剪贴板写入被拒：" + e.message);
          });
        }
      },
      gamepads: function () {
        var api = root.navigator && root.navigator.getGamepads ? root.navigator.getGamepads() : null;
        if (!api) return [];
        var out = [];
        for (var i = 0; i < api.length; i++) {
          if (api[i]) out.push(api[i]);
        }
        return out;
      },
      pushResize: pushResize,
    };
  }

  // ========================================================= WASI 桩（齐全）
  //
  // jacket 的 wasm 目标产出的是 WASI 模块：Basic 用到的 print/时钟/argc/argv/poll
  // 都会变成 wasi_snapshot_preview1 的导入。这里给最小可用实现：fd_write 真的
  // 接到 sink，其余返回 0（成功）。
  //
  // ★ WASI preview1 规范是「32 位内存」的，所以 **所有 WASI 参数的地址都是 u32**，
  //   即使目标内存是 memory64。iovec 步长 8 字节（u32+u32），nwritten 也是 u32。
  function makeWasi(deps) {
    var getMemory = deps.getMemory;
    var sink = deps.sink;
    var decoder = new TextDecoder("utf-8");

    var table = {
      fd_write: function (fd, iovs, iovsLen, nwritten) {
        var memory = getMemory();
        var dv = new DataView(memory.buffer);
        var total = 0;
        var text = "";
        for (var i = 0; i < iovsLen; i++) {
          var base = iovs + i * 8;
          var buf = dv.getUint32(base, true);
          var len = dv.getUint32(base + 4, true);
          if (!len) continue;
          text += decoder.decode(new Uint8Array(memory.buffer, buf, len));
          total += len;
        }
        if (text) sink.write(text);
        dv.setUint32(nwritten, total, true);
        return 0;
      },

      clock_time_get: function (clockId, precision, out) {
        var ms = typeof performance !== "undefined" ? performance.now() : Date.now();
        new DataView(getMemory().buffer).setBigUint64(out, BigInt(Math.round(ms * 1e6)), true);
        return 0;
      },

      args_sizes_get: function (argcPtr, argvBufSizePtr) {
        var dv = new DataView(getMemory().buffer);
        dv.setUint32(argcPtr, 0, true);
        dv.setUint32(argvBufSizePtr, 0, true);
        return 0;
      },
      args_get: function () {
        return 0;
      },

      proc_exit: function (code) {
        throw new Error("wasm called proc_exit(" + code + ") —— 不要调 _start / main，调 fw_boot");
      },

      poll_oneoff: function () {
        return 0;
      },
    };

    return {
      wasi_snapshot_preview1: new Proxy(table, {
        get: function (target, prop) {
          if (Object.prototype.hasOwnProperty.call(target, prop)) return target[prop];
          return function wasiStub() {
            return 0; // errno = SUCCESS
          };
        },
      }),
    };
  }

  // ============================================================== 实例化
  async function instantiate(bytes, options) {
    options = options || {};
    var sink = makeSink(options);
    var events = makeEventQueue();
    var storage = makeStorage({ sink: sink });

    var state = { memory: null, exports: null };
    var deps = {
      getMemory: function () {
        return state.memory;
      },
      sink: sink,
      storage: storage,
      events: events,
      dom: null,
      gl: null,
    };

    var dom = attachDom({ canvas: options.canvas, events: events, sink: sink });
    deps.dom = dom;
    // WebGL2 的后端对象要在 dom 之后建（它要 canvas），但在 instantiate 之前
    // （env.gl 必须在 imports 里）—— getMemory 是闭包，内存还没就位也没关系。
    deps.gl = makeGl({
      getMemory: deps.getMemory,
      sink: sink,
      dom: dom,
      preserveDrawingBuffer: options.preserveDrawingBuffer,
    });

    // makeEnv() 返回的是 env 模块的**扁平**函数表（fw_log、fw_step …），
    // 所以这里必须把它挂在 imports.env 下，而不是和 wasi 平铺展开。
    var imports = Object.assign({ env: makeEnv(deps) }, makeWasi(deps));

    // 缺导入时给出可读的错误，而不是一句 LinkError: env.foo is not a function。
    var declared = WebAssembly.Module.imports(new WebAssembly.Module(bytes));
    var missing = declared
      .filter(function (entry) {
        return entry.kind === "function";
      })
      .filter(function (entry) {
        var module = imports[entry.module];
        return !module || typeof module[entry.name] !== "function";
      })
      .map(function (entry) {
        return entry.module + "." + entry.name;
      });
    if (missing.length > 0) {
      throw new Error("宿主缺少 wasm 导入：" + missing.join(", "));
    }

    var instance = await WebAssembly.instantiate(bytes, imports);
    state.exports = instance.instance ? instance.instance.exports : instance.exports;
    state.memory = state.exports.memory;
    if (!state.memory) {
      throw new Error("wasm 没有导出 memory —— 本桥依赖默认的 memory 导出");
    }

    var api = {
      exports: state.exports,
      sink: sink,
      memory: state.memory,
      storage: storage,
      events: events,
      dom: dom,
      gl: deps.gl,
      setCanvas: function (canvas) {
        if (dom) dom.canvas = canvas;
        else deps.dom = attachDom({ canvas: canvas, events: events, sink: sink });
      },
      boot: function () {
        if (typeof state.exports.fw_boot !== "function") {
          throw new Error("缺少 fw_boot 导出（检查 #program_export 是否写成声明前缀）");
        }
        return state.exports.fw_boot() !== 0;
      },
      step: function (dt) {
        if (typeof state.exports.fw_step !== "function") {
          throw new Error("缺少 fw_step 导出");
        }
        return state.exports.fw_step(dt) !== 0;
      },
      stats: function (which) {
        return state.exports.fw_stats ? state.exports.fw_stats(which) : -1;
      },
      layout: function (which) {
        return state.exports.fw_layout ? state.exports.fw_layout(which) : -1;
      },
      pushEvent: function (kind, a, b, c, d) {
        if (!state.exports.fw_push_dom_event) return 0;
        return state.exports.fw_push_dom_event(kind, a, b, c, d);
      },
    };
    return api;
  }

  // ======================================================== rAF 驱动（浏览器）
  function runFrameLoop(api, options) {
    options = options || {};
    var onFrame = options.onFrame;
    var frames = 0;
    var stopped = false;
    var last = null;

    if (!api.boot()) {
      api.sink.write("fw_boot 返回 0：Jai 侧运行时没起来\n");
      return Promise.resolve({ frames: frames, stopped: true });
    }
    api.sink.write("[host] " + api.storage.describe() + "\n");

    return new Promise(function (resolve) {
      // 帧调度：真实浏览器走 requestAnimationFrame；无头验证走 setTimeout。
      //
      // 为什么需要这个开关：Chrome 的 --virtual-time-budget 只推进 setTimeout /
      // performance.now，requestAnimationFrame 全程只触发一次（实测 raf=1），
      // 而像素读回断言在第 30 帧。加 ?driver=timeout 就能在无头环境里跑满帧数；
      // 普通打开（无参数）仍然走 rAF，行为不变。
      var driver = "raf";
      try {
        var query = root.location ? root.location.search : "";
        driver = new URLSearchParams(query).get("driver") || "raf";
      } catch (e) {
        driver = "raf";
      }

      function schedule() {
        if (driver === "timeout") {
          root.setTimeout(function () {
            frame(root.performance ? root.performance.now() : Date.now());
          }, 16);
        } else {
          root.requestAnimationFrame(frame);
        }
      }

      function frame(now) {
        if (stopped) return;
        if (last === null) last = now;
        var dt = (now - last) / 1000;
        last = now;
        if (!isFinite(dt) || dt < 0) dt = 0;

        var keep = false;
        try {
          keep = api.step(dt);
        } catch (error) {
          api.sink.write("fw_step 抛异常: " + error + "\n");
          stopped = true;
          resolve({ frames: frames, stopped: true, error: error });
          return;
        }
        frames += 1;
        if (onFrame) onFrame(frames, dt);

        if (!keep) {
          api.sink.write("fw_step 返回 0，停止帧循环（共 " + frames + " 帧）\n");
          stopped = true;
          resolve({ frames: frames, stopped: true });
          return;
        }
        schedule();
      }

      schedule();
    });
  }

  // ============================================================ 取 wasm 字节流
  async function loadBytes(options) {
    options = options || {};
    var url = options.url || "./.build/fw.wasm";
    var isHttp = typeof location !== "undefined" && /^https?:$/.test(location.protocol);

    if (isHttp) {
      var response = await fetch(url);
      if (!response.ok) throw new Error("取 " + url + " 失败: " + response.status);
      return new Uint8Array(await response.arrayBuffer());
    }

    var base64 = root.FW_WASM_BASE64;
    if (!base64) {
      throw new Error(
        "没有 FW_WASM_BASE64。file:// 下必须先跑 build.bat（它会生成内嵌 base64），" +
          "或者用 http 服务器打开（python -m http.server）。"
      );
    }
    var binary = atob(base64);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  // ================================================================== 一步到位
  async function start(options) {
    options = options || {};
    var bytes = options.bytes || (await loadBytes(options));
    var api = await instantiate(bytes, options);
    if (options.canvas) api.setCanvas(options.canvas);
    if (options.hooks && options.hooks.onReady) options.hooks.onReady(api);
    return runFrameLoop(api, options);
  }

  var jfosterWeb = {
    instantiate: instantiate,
    runFrameLoop: runFrameLoop,
    loadBytes: loadBytes,
    start: start,
    makeSink: makeSink,
    // 暴露给测试/宿主脚本
    constants: { EV: EV, GAMEPAD: GAMEPAD, DOM_REC_BYTES: DOM_REC_BYTES, SCANCODE: SCANCODE },
    scancodeFromCode: scancodeFromCode,
  };
  root.jfosterWeb = jfosterWeb;
  if (typeof module !== "undefined" && module.exports) module.exports = jfosterWeb;
})(typeof globalThis !== "undefined" ? globalThis : this);
