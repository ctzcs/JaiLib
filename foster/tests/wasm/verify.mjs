// jfoster wasm 验证器（node，无浏览器）
//
//   node tests/wasm/verify.mjs
//
// 它做的事：把 .build/fw.wasm 实例化，按 internal/web/web_bridge.jai 的契约给全
// env 导入，然后驱动 fw_boot / fw_step，用 fw_stats 读回 Jai 侧的真实状态。
//
// 与 host.js 的关系：host.js 是浏览器宿主（DOM/OPFS/requestFullscreen），这里是
// 无 DOM 的替身——同一套导入名字，不同的后端（Map 代替 localStorage、事件队列由
// 本脚本自己喂）。两边任何一边改了 ABI，另一个必须同步。

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const WASM = join(HERE, ".build", "fw.wasm");

// ---------------------------------------------------------------- 宿主替身
const CSS_W = 320, CSS_H = 180, DPR = 2;
const DEV_W = Math.round(CSS_W * DPR), DEV_H = Math.round(CSS_H * DPR);

const logLines = [];        // Jai 侧 fw_log / WASI stdout 都进这里
const storage = new Map();  // 虚拟存档根
const events = [];          // 待投递的 DOM 事件（6×s32）
let memory = null;
let clipboard = "clipboard-from-host";
// 虚拟时钟（毫秒）。每调一次 fw_step 前进 dt*1000，于是 app_tick 看到的
// delta_time 恰好等于宿主喂的 dt —— 和浏览器里 rAF 的 16.7ms 一致。
let virtualNowMs = 0;
const counters = {
  storageRead: 0, storageWrite: 0, storageList: 0, storageRemove: 0,
  domPush: 0, setTitle: 0, cursorSet: 0, fullscreen: 0, textArea: 0, gamepadPoll: 0,
};

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// wasm 侧地址是偏移（s32），用 exports.memory 读写。
function view() {
  return new DataView(memory.buffer);
}
// wasm64：指针类参数到 JS 侧是 BigInt，所有偏移都要先窄化成 Number。
const n32 = (v) => Number(v);
function readBytes(ptr, len) {
  return new Uint8Array(memory.buffer, n32(ptr), n32(len)).slice();
}
function readString(ptr, len) {
  return decoder.decode(readBytes(ptr, len));
}
function writeBytes(ptr, bytes) {
  new Uint8Array(memory.buffer, n32(ptr), bytes.length).set(bytes);
}
function writeI32(ptr, v) { view().setInt32(n32(ptr), v | 0, true); }
function readI32(ptr) { return view().getInt32(n32(ptr), true); }
function readF64(ptr) { return view().getFloat64(ptr, true); }

// ------------------------------------------------------------------ imports
const env = {
  // 日志：Jai 侧把 UTF-8 字节推过来
  fw_log(ptr, len) {
    const text = readString(ptr, len);
    logLines.push(text);
    if (process.env.VERBOSE) process.stdout.write(text);
    return 0;
  },
  fw_now_ms() { return virtualNowMs; },

  // [W6] 内存 soak 的读数：Node 里 memory 就是 exports.memory。
  fw_memory_bytes() { return memory ? (memory.buffer.byteLength | 0) : -1; },

  // CSS 尺寸 + 设备尺寸由宿主决定；这里固定 320×180 @ DPR 2
  fw_canvas_size(wOff, hOff) {
    writeI32(wOff, DEV_W);
    writeI32(hOff, DEV_H);
    return 0;
  },
  fw_pixel_ratio() { return DPR; },

  fw_set_title(ptr, len) { counters.setTitle += 1; return 1; },
  fw_request_fullscreen(on) { counters.fullscreen += 1; return 1; },
  fw_set_cursor_css(ptr, len) { counters.cursorSet += 1; return 1; },
  fw_text_input_area(x, y, w, h, on) { counters.textArea += 1; return 1; },
  fw_mouse_relative(on) { return 1; },

  fw_clipboard_get(buf, cap) {
    const bytes = encoder.encode(clipboard);
    const n = Math.min(bytes.length, cap);
    writeBytes(buf, bytes.subarray(0, n));
    return n;
  },
  fw_clipboard_set(ptr, len) {
    clipboard = readString(ptr, len);
    return 1;
  },

  fw_storage_read(keyPtr, keyLen, buf, cap) {
    counters.storageRead += 1;
    const key = readString(keyPtr, keyLen);
    const value = storage.get(key);
    if (value === undefined) return -1;
    const bytes = encoder.encode(value);
    const n = Math.min(bytes.length, cap);
    writeBytes(buf, bytes.subarray(0, n));
    return n;
  },
  fw_storage_write(keyPtr, keyLen, valPtr, valLen) {
    counters.storageWrite += 1;
    storage.set(readString(keyPtr, keyLen), readString(valPtr, valLen));
    return 1;
  },
  fw_storage_list(prefixPtr, prefixLen, buf, cap) {
    counters.storageList += 1;
    const prefix = readString(prefixPtr, prefixLen);
    const names = [...storage.keys()].filter((k) => k.startsWith(prefix));
    const bytes = encoder.encode(names.join("\n"));
    const n = Math.min(bytes.length, cap);
    writeBytes(buf, bytes.subarray(0, n));
    return n;
  },
  fw_storage_remove(keyPtr, keyLen) {
    counters.storageRemove += 1;
    storage.delete(readString(keyPtr, keyLen));
    return 1;
  },

  // Jai 每帧把队列拉空：一次调用取一条
  fw_dom_event_push(recPtr, cap) {
    counters.domPush += 1;
    if (events.length === 0) return 0;
    const ev = events.shift();
    for (let i = 0; i < 6; i += 1) writeI32(n32(recPtr) + i * 4, ev[i] | 0);
    return 1;
  },

  fw_gamepad_poll(rec, count) { counters.gamepadPoll += 1; return 0; },
};

// ------------------------------------------------------------ WebGL2 桥（W3）
//
// Node 里没有 WebGL2，所以这里**不是一个真的 GL 实现，而是一台「记录仪」**：
// 每个 gl_* 入口都返回一个有效的句柄（1 起），并把调用参数记下来。于是同一份
// fw.wasm 可以在完全没有 GPU 的环境里证明这条链是通的：
//
//   内嵌 GLSL 文本 → compileShader → linkProgram → VAO 属性布局
//   → clear 的颜色 → uniformMatrix4fv 的 16 个 float → drawElements 的 count
//
// **唯一不做的是像素**：gl_read_pixels 返回 -1，Jai 侧的断言因此落到「SKIP」
// 而不是假绿。真像素在浏览器里验（tools/verify_web_gl.py + tests/wasm/index.html）。
const glCalls = { createDevice: 0, destroyDevice: 0, present: 0, passes: 0 };
const glState = {
  shaders: [],       // { id, stage, name, src }
  programs: [],      // { id, vs, fs, name }
  pipelines: [],     // { id, program, attrs }
  textures: [],      // { id, width, height, uploads: [{ x, y, w, h, bytes }] }
  buffers: [],       // { id, target, capacity, uploads }
  samplers: [],      // { id }
  clears: [],        // { r, g, b, a, colorMask }
  draws: [],         // { kind: "indexed"|"arrays", ... }
  // W4：uniform 走 std140 UBO。录下来的是「哪个 UBO 被传了什么字节」+「哪个
  // binding 上绑了哪个 UBO」，两条合起来才能断言字节落到了正确的槽位。
  uniformBuffers: [],   // { id, capacity, uploads: [{ offset, bytes }] }
  uniformBindings: [],  // { binding, buffer }
  samplersBound: [], // { program, unit, texture, sampler, name }
  viewports: [],
  scissor: [],
  blend: [],
  nextId: 1,
};

function glAlloc(entry) {
  const id = glState.nextId;
  glState.nextId += 1;
  return Object.assign({ id }, entry);
}

function readFloats(ptr, count) {
  const out = [];
  for (let i = 0; i < Number(count); i += 1) out.push(view().getFloat32(n32(ptr) + i * 4, true));
  return out;
}

const gl = {
  gl_device_create(w, h) {
    glCalls.createDevice += 1;
    return glAlloc({ kind: "device" }).id;
  },
  gl_device_destroy() { glCalls.destroyDevice += 1; return 1; },
  gl_swapchain_bind() { return 1; },
  gl_present() { glCalls.present += 1; return 1; },
  gl_get_error() { return 0; },
  gl_get_string(which, buf, cap) {
    const text = ["node-mock-webgl2", "node-mock-renderer", "node-mock", "GLSL ES 3.00 (mock)"][which] || "";
    const bytes = encoder.encode(text);
    const n = Math.min(n32(cap), bytes.length);
    writeBytes(buf, bytes.subarray(0, n));
    return n;
  },
  gl_get_param(which) {
    if (which === 0 || which === 6) return DEV_W;
    if (which === 1 || which === 7) return DEV_H;
    if (which === 2) return 8192;
    if (which === 3) return 16;
    if (which === 4) return 32;
    if (which === 5) return 4;
    if (which === 8) return 24;   // MAX_UNIFORM_BUFFER_BINDINGS（GL ES 3.0 下限）
    return 0;
  },

  gl_create_texture(width, height) {
    const t = glAlloc({ kind: "texture", width: n32(width), height: n32(height), uploads: [] });
    glState.textures.push(t);
    return t.id;
  },
  gl_set_texture_data(texture, x, y, w, h, ptr, length) {
    const t = glState.textures.find((it) => it.id === n32(texture));
    if (!t) return -1;
    t.uploads.push({ x: n32(x), y: n32(y), w: n32(w), h: n32(h), bytes: readBytes(ptr, length) });
    return 1;
  },
  gl_get_texture_data() { return -1; },
  // W5：FBO / renderbuffer / blit。node 里没有真 GL，只做「能实例化 + 记录调用」，
  // 真正的工作由浏览器验证；这里返回兜底值，保证 Jai 侧的簿记路径能跑通。
  gl_create_framebuffer() { glState.framebuffers = (glState.framebuffers || 0) + 1; return glAlloc({ kind: "framebuffer" }).id; },
  gl_destroy_framebuffer() { return 1; },
  gl_attach_texture() { return 0x8CD5; },      // FRAMEBUFFER_COMPLETE
  gl_create_renderbuffer(internalFormat, width, height, samples) {
    glAlloc({ kind: "renderbuffer" });
    glState.renderbuffers = (glState.renderbuffers || 0) + 1;
    return 1;
  },
  gl_destroy_renderbuffer() { return 1; },
  gl_attach_renderbuffer() { return 0x8CD5; },
  gl_framebuffer_status() { return 0x8CD5; },
  gl_blit_framebuffer() { glState.blits = (glState.blits || 0) + 1; return 1; },
  gl_destroy_texture() { return 1; },

  gl_create_buffer(target) {
    const b = glAlloc({ kind: "buffer", target: n32(target), capacity: 0, uploads: [] });
    glState.buffers.push(b);
    return b.id;
  },
  gl_set_buffer_data(buffer, ptr, length, destOffset, capacity) {
    const b = glState.buffers.find((it) => it.id === n32(buffer));
    if (!b) return -1;
    if (n32(capacity) > b.capacity) b.capacity = n32(capacity);
    if (n32(length) > 0) b.uploads.push({ offset: n32(destOffset), bytes: readBytes(ptr, length) });
    return 1;
  },
  gl_destroy_buffer() { return 1; },

  gl_create_sampler() {
    const s = glAlloc({ kind: "sampler" });
    glState.samplers.push(s);
    return s.id;
  },
  gl_destroy_sampler() { return 1; },

  gl_create_shader(stage, srcPtr, srcLen, namePtr, nameLen) {
    // 真的编译做不了，但「源必须是一段 GLSL ES 3.00」这条可以断言。
    const s = glAlloc({
      kind: "shader", stage: n32(stage),
      name: readString(namePtr, nameLen), src: readString(srcPtr, srcLen),
    });
    glState.shaders.push(s);
    return s.id;
  },
  gl_create_program(vs, fs, namePtr, nameLen) {
    const vertexShader = glState.shaders.find((it) => it.id === n32(vs));
    const fragmentShader = glState.shaders.find((it) => it.id === n32(fs));
    const p = glAlloc({
      kind: "program", vs: n32(vs), fs: n32(fs), name: readString(namePtr, nameLen),
      // 静态文本检查：真正的 block 表由 GL 链接器给（host.js），这里能证明的是
      // 「送进 compileShader 的六个默认源已经是 std140 形式」。
      blocks: [vertexShader, fragmentShader].map((sh) => {
        if (!sh) return 0;
        const m = sh.src.match(/layout\s*\(\s*std140\s*\)\s*uniform\s+\w+/g);
        return m ? m.length : 0;
      }).reduce((a, b) => a + b, 0),
    });
    glState.programs.push(p);
    return p.id;
  },
  gl_destroy_shader() { return 1; },
  gl_destroy_program() { return 1; },

  gl_create_pipeline(program, attrsPtr, attrCount) {
    // 属性表是 8 × s32：slot, loc, size, type, normalized, stride, offset, divisor
    const attrs = [];
    for (let i = 0; i < n32(attrCount); i += 1) {
      const base = n32(attrsPtr) + i * 32;
      attrs.push({
        slot: view().getInt32(base + 0, true),
        loc: view().getInt32(base + 4, true),
        size: view().getInt32(base + 8, true),
        type: view().getInt32(base + 12, true),
        normalized: view().getInt32(base + 16, true) !== 0,
        stride: view().getInt32(base + 20, true),
        offset: view().getInt32(base + 24, true),
        divisor: view().getInt32(base + 28, true),
      });
    }
    const p = glAlloc({ kind: "pipeline", program: n32(program), attrs });
    glState.pipelines.push(p);
    return p.id;
  },
  gl_destroy_pipeline() { return 1; },

  gl_begin_render_pass() { glCalls.passes += 1; return 1; },
  gl_clear(r, g, b, a, colorMask) {
    glState.clears.push({ r: n32(r), g: n32(g), b: n32(b), a: n32(a), colorMask: n32(colorMask) });
    return 1;
  },
  gl_end_render_pass() { return 1; },

  gl_bind_pipeline() { return 1; },
  gl_bind_vertex_buffer() { return 1; },
  gl_bind_index_buffer() { return 1; },
  gl_bind_sampler(program, unit, texture, sampler, namePtr, nameLen) {
    glState.samplersBound.push({
      program: n32(program), unit: n32(unit), texture: n32(texture),
      sampler: n32(sampler), name: readString(namePtr, nameLen),
    });
    return 1;
  },
  // W4：std140 UBO。一个 binding 一个 GL buffer（Jai 侧 web_gpu.uniform_buffers），
  // 每次 draw 整块重传 —— 和桌面 SDL_PushGPU*UniformData 的语义一致。
  gl_create_uniform_buffer(size) {
    const b = glAlloc({ kind: "uniform_buffer", capacity: Math.max(16, n32(size)), uploads: [] });
    glState.uniformBuffers.push(b);
    return b.id;
  },
  gl_set_uniform_buffer_data(buffer, ptr, length, destOffset, capacity) {
    const b = glState.uniformBuffers.find((it) => it.id === n32(buffer));
    if (!b) return -1;
    if (n32(capacity) > b.capacity) b.capacity = n32(capacity);
    if (n32(length) > 0) b.uploads.push({ offset: n32(destOffset), bytes: readBytes(ptr, length) });
    return 1;
  },
  gl_bind_uniform_buffer(buffer, binding) {
    glState.uniformBindings.push({ binding: n32(binding), buffer: n32(buffer) });
    return 1;
  },
  gl_destroy_uniform_buffer() { return 1; },
  gl_release_pipeline_with_program() { return 1; },
  gl_set_blend(srcColor, dstColor, colorOp, srcAlpha, dstAlpha, alphaOp, colorMask) {
    glState.blend.push([n32(srcColor), n32(dstColor), n32(colorOp), n32(srcAlpha), n32(dstAlpha), n32(alphaOp), n32(colorMask)]);
    return 1;
  },
  gl_set_cull() { return 1; },
  gl_set_depth() { return 1; },
  gl_set_stencil() { return 1; },
  gl_set_viewport(x, y, w, h) { glState.viewports.push([n32(x), n32(y), n32(w), n32(h)]); return 1; },
  gl_set_scissor(x, y, w, h, on) { glState.scissor.push([n32(x), n32(y), n32(w), n32(h), n32(on)]); return 1; },

  gl_draw(mode, first, count, instances) {
    glState.draws.push({ kind: "arrays", first: n32(first), count: n32(count), instances: n32(instances) });
    return 1;
  },
  gl_draw_indexed(mode, count, elementType, offsetBytes, instances) {
    glState.draws.push({
      kind: "indexed", count: n32(count), elementType: n32(elementType),
      offsetBytes: n32(offsetBytes), instances: n32(instances),
    });
    return 1;
  },

  // 没有真像素：返回 -1，于是 Jai 侧把断言标成 SKIP（见 tests/wasm/main.jai）
  // W6：第 7 个参数是 FBO（-1 保持绑定 / 0 = canvas / >0 = 离屏）。node 里没有真 GL，返回 -1 → 上层判 SKIP。
  gl_read_pixels() { return -1; },
  gl_stats(which) {
    if (which === 0) return glState.draws.length;
    if (which === 1) return glCalls.passes;
    if (which === 2) return glState.clears.length;
    if (which === 3) return glState.textures.reduce((n, t) => n + t.uploads.length, 0);
    if (which === 4) return glState.buffers.reduce((n, b) => n + b.uploads.length, 0);
    if (which === 5) return glState.shaders.length;
    if (which === 6) return glState.programs.length;
    if (which === 7) return glState.pipelines.length;
    if (which === 8) return 0;
    if (which === 9) return 0;
    if (which === 10) return 0;
    if (which === 11) return glCalls.createDevice > 0 ? 1 : 0;
    return -1;
  },
};

// WASI preview1（module 里 print/clock 会走它）。地址是 u32，iovec 步长 8 字节。
const wasi = {
  fd_write(fd, iovs, iovsLen, nwritten) {
    let total = 0;
    for (let i = 0; i < iovsLen; i += 1) {
      const base = n32(iovs) + i * 8;
      const ptr = view().getUint32(base, true);
      const len = view().getUint32(base + 4, true);
      const text = readString(ptr, len);
      logLines.push(text);
      if (process.env.VERBOSE) process.stdout.write(text);
      total += len;
    }
    view().setUint32(nwritten, total, true);
    return 0;
  },
  fd_close() { return 0; },
  fd_fdstat_get() { return 0; },
  fd_seek() { return 0; },
  proc_exit(code) { throw new Error(`proc_exit(${code})`); },
  poll_oneoff() { return 0; },
  environ_sizes_get(n1, n2) { view().setUint32(n1, 0, true); view().setUint32(n2, 0, true); return 0; },
  environ_get() { return 0; },
  args_sizes_get(n1, n2) { view().setUint32(n1, 0, true); view().setUint32(n2, 0, true); return 0; },
  args_get() { return 0; },
  random_get(buf, len) { for (let i = 0; i < len; i += 1) view().setUint8(buf + i, (Math.random() * 256) | 0); return 0; },
  clock_time_get(_id, _prec, out) { view().setBigUint64(n32(out), BigInt(Math.round(virtualNowMs)) * 1000000n, true); return 0; },
};

// --------------------------------------------------------------------- 驱动
const wasmBytes = await readFile(WASM);
const { instance } = await WebAssembly.instantiate(wasmBytes, {
  // gl_*（W3）平铺进同一个 env —— wasm 只认一个 import module。
  env: Object.assign({}, env, gl),
  wasi_snapshot_preview1: wasi,
});
memory = instance.exports.memory;

const rawStep = instance.exports.fw_step;
const fw_boot = instance.exports.fw_boot;
const fw_stats = instance.exports.fw_stats;
// 包一层：先推进虚拟时钟，再真正步进
function fw_step(dt) {
  virtualNowMs += dt * 1000;
  return rawStep(dt);
}

const results = [];
function check(name, ok, detail = "") {
  results.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  — " + detail : ""}`);
}

// 事件种类（internal/web/web_events.jai 的 WEB_EV_*）
const EV = { KEY_DOWN: 1, KEY_UP: 2, POINTER_DOWN: 3, POINTER_UP: 4, POINTER_MOVE: 5, WHEEL: 6, FOCUS: 7, BLUR: 8, RESIZE: 10, TEXT: 11 };
// SDL scancode：A=4
const SCANCODE_A = 4;
const SCANCODE_ESCAPE = 41;   // SDL_SCANCODE_ESCAPE

function pushEvent(kind, a = 0, b = 0, c = 0, d = 0) {
  events.push([kind, a, b, c, d, 0]);
  counters.domPush += 0; // 计数在 push 时加，这里只入队
}

// 事件在某一帧被 app_poll_events 拉走；固定步长的累加器偶尔会让某帧跑 0 次
// app_step，所以推事件之后要泵几帧，直到队列被拉空（浏览器里也是这个语义）。
function pumpUntilDrained(max = 6) {
  for (let i = 0; i < max && events.length > 0; i += 1) fw_step(1 / 60);
}

console.log(`[verify] ${WASM}`);
console.log(`[verify] css=${CSS_W}x${CSS_H} dpr=${DPR} device=${DEV_W}x${DEV_H}\n`);

check("fw_boot 返回 1（runtime + logger 就绪）", fw_boot() === 1);

check("窗口 CSS 宽来自 canvas", fw_stats(2) === CSS_W, `fw_stats(2)=${fw_stats(2)}`);
check("窗口 CSS 高来自 canvas", fw_stats(3) === CSS_H, `fw_stats(3)=${fw_stats(3)}`);
check("窗口设备像素宽（backing store）", fw_stats(4) === DEV_W, `fw_stats(4)=${fw_stats(4)}`);
check("窗口设备像素高（backing store）", fw_stats(5) === DEV_H, `fw_stats(5)=${fw_stats(5)}`);

// 60 帧空转
let frames = 0;
for (let i = 0; i < 60; i += 1) {
  if (fw_step(1 / 60) === 0) break;
  frames += 1;
}
check("App.update 被宿主稳定驱动 60 帧", frames === 60, `stepped=${frames}`);
check("Jai 侧帧数与宿主一致", fw_stats(1) === 60, `fw_stats(1)=${fw_stats(1)}`);

// ---------------------------------------------------------------- W3：WebGL2
//
// 这一段验的是「Jai 侧把 Draw_Command 翻成了一条正确的 GL 命令流」——
// 用上面那台记录仪。像素在浏览器里验（同一份 main.jai）。
{
  check("W3 gl_device_create 被调用（后端真的去建 context 了）",
    glCalls.createDevice === 1, `calls=${glCalls.createDevice}`);

  const staged = glState.shaders.filter((s) => s.name === "Textured");
  check("W3 Textured 的两个 stage 都编译了（GLSL 文本来自内嵌资产）",
    staged.length === 2, `shaders=${staged.map((s) => s.stage).join(",")}`);
  check("W3 送进 compileShader 的是 GLSL ES 3.00 文本（#version 300 es）",
    staged.length === 2 && staged.every((s) => s.src.startsWith("#version 300 es")),
    staged.length > 0 ? JSON.stringify(staged[0].src.slice(0, 20)) : "no shader");
  check("W3 片元源里真的有 sampler2D Texture",
    staged.some((s) => s.src.includes("uniform sampler2D Texture")),
    "");

  const program = glState.programs.find((p) => p.name === "Textured");
  check("W3 Textured program 链接过（vs/fs 都有有效句柄）",
    !!program && program.vs > 0 && program.fs > 0, program ? `vs=${program.vs} fs=${program.fs}` : "missing");

  // PosTexCol：loc0 FLOAT2(0x1406,2) / loc1 FLOAT2 / loc2 UNSIGNED_BYTE(0x1401,4,normalized)，stride 20
  const pipeline = glState.pipelines.find((p) => program && p.program === program.id);
  const attrs = pipeline ? pipeline.attrs : [];
  check("W3 pipeline 的顶点属性布局 = PosTexCol（3 个属性 / stride 20）",
    attrs.length === 3 && attrs.every((a) => a.stride === 20) &&
    attrs[0].loc === 0 && attrs[0].size === 2 && attrs[0].type === 0x1406 &&
    attrs[1].loc === 1 && attrs[1].size === 2 &&
    attrs[2].loc === 2 && attrs[2].size === 4 && attrs[2].type === 0x1401 && attrs[2].normalized,
    JSON.stringify(attrs.map((a) => [a.loc, a.size, "0x" + a.type.toString(16), a.stride, a.normalized])));

  const clear = glState.clears[0];
  check("W3 clear 收到清屏色 (16,32,48,255)",
    !!clear && clear.r === 16 && clear.g === 32 && clear.b === 48 && clear.a === 255 && clear.colorMask === 1,
    clear ? `(${clear.r},${clear.g},${clear.b},${clear.a})` : "no clear");

  const indexed = glState.draws.find((d) => d.kind === "indexed" && d.count === 6);
  check("W3 索引绘制被发起（6 个索引 = 2 个三角形，UNSIGNED_INT）",
    !!indexed && indexed.elementType === 0x1405 && indexed.instances === 1,
    indexed ? `count=${indexed.count} type=0x${indexed.elementType.toString(16)}` : "no draw");

  // 逐帧重传同一个 quad：draw 计数必须跟帧数一起长（不是"画了一次就忘了"）
  check("W3 每帧都在画（draw 计数 > 1）", glState.draws.length > 1, `draws=${glState.draws.length}`);

  // W4：矩阵改走 std140 UBO —— 直接在 binding 0 的块里按 float32 读前 16 个分量。
  // 顶点块 = binding 0（64 B mat4），片段块 = binding 8（DistanceRange）。
  const vertexBinding = glState.uniformBindings.filter((b) => b.binding === 0).pop();
  const vertexBlock = vertexBinding
    ? glState.uniformBuffers.find((b) => b.id === vertexBinding.buffer)
    : null;
  const lastUpload = vertexBlock ? vertexBlock.uploads[vertexBlock.uploads.length - 1] : null;
  const matrixValues = lastUpload
    ? Array.from(new Float32Array(lastUpload.bytes.buffer, lastUpload.bytes.byteOffset, Math.min(16, lastUpload.bytes.length / 4)))
    : [];
  const expectM11 = 2 / DEV_W;
  const expectM22 = -2 / DEV_H;
  check("W4 顶点 uniform 走 std140 UBO binding 0（块大小 64 B）",
    !!vertexBlock && vertexBlock.capacity >= 64,
    vertexBlock ? `capacity=${vertexBlock.capacity} uploads=${vertexBlock.uploads.length}` : "no vertex block bound at binding 0");
  check("W4 矩阵按行主序裸字节上传，m11=2/W、m22=-2/H",
    matrixValues.length === 16 &&
      Math.abs(matrixValues[0] - expectM11) < 1e-6 &&
      Math.abs(matrixValues[5] - expectM22) < 1e-6,
    matrixValues.length ? `m11=${matrixValues[0]} m22=${matrixValues[5]}` : "no matrix upload");

  // 8×8 RGBA 纹理，左半红右半蓝：第一个 texel 必须是 (255,0,0,255)
  const quad = glState.textures.find((t) => t.width === 8 && t.height === 8);
  const upload = quad && quad.uploads.find((u) => u.w === 8 && u.h === 8);
  check("W3 8×8 纹理真的上传了 256 字节（RGBA8）",
    !!upload && upload.bytes.length === 256, upload ? `${upload.bytes.length} bytes` : "no upload");
  check("W3 纹理第 0 个 texel = (255,0,0,255)（左半红）",
    !!upload && upload.bytes[0] === 255 && upload.bytes[1] === 0 && upload.bytes[2] === 0 && upload.bytes[3] === 255,
    upload ? `(${upload.bytes[0]},${upload.bytes[1]},${upload.bytes[2]},${upload.bytes[3]})` : "");
  check("W3 纹理第 4 列 texel = (0,0,255,255)（右半蓝）",
    !!upload && upload.bytes[16] === 0 && upload.bytes[17] === 0 && upload.bytes[18] === 255 && upload.bytes[19] === 255,
    upload ? `(${upload.bytes[16]},${upload.bytes[17]},${upload.bytes[18]},${upload.bytes[19]})` : "");

  check("W3 纹理单元 0 上绑了 sampler2D Texture",
    glState.samplersBound.some((b) => b.unit === 0 && b.name === "Texture" && b.texture > 0),
    `bound=${glState.samplersBound.length}`);

  check("W3 视口按设备像素设置（640×360）",
    glState.viewports.some((v) => v[2] === DEV_W && v[3] === DEV_H),
    JSON.stringify(glState.viewports[0] || null));

  // 像素断言在无 GL 的宿主里必须落到 SKIP，不能假绿
  check("W3 无 WebGL2 宿主时读回断言标 SKIP（不假绿）",
    glState.draws.length > 0 && logLines.join("").includes("W3 PIXEL: SKIP"),
    "");
}

// 键盘：先给 focus（浏览器里没有焦点时按键会被丢），再按下 A
pushEvent(EV.FOCUS);
pumpUntilDrained();
pushEvent(EV.KEY_DOWN, SCANCODE_A);
pumpUntilDrained();
const downAfterPress = fw_stats(6);
check("keydown 真的进了 Input（down 计数 = 1）", downAfterPress === 1, `down=${downAfterPress}`);

pushEvent(EV.KEY_UP, SCANCODE_A);
pumpUntilDrained();
pumpUntilDrained();
const downAfterRelease = fw_stats(6);
check("keyup 之后 down 计数回到 0", downAfterRelease === 0, `down=${downAfterRelease}`);

// 事件确实被拉走了（每帧拉到 0，所以队列空了）
check("DOM 事件队列被每帧拉空", events.length === 0, `leftover=${events.length}`);
check("fw_dom_event_push 被调用过", counters.domPush > 0, `calls=${counters.domPush}`);

// 存档：示例每 300 帧做一次闭环（写→读→列），跑到它触发为止
let framesToReport = 0;
while (counters.storageWrite === 0 && framesToReport < 400) {
  if (fw_step(1 / 60) === 0) break;
  framesToReport += 1;
}
check("存档写走过桥", counters.storageWrite > 0, `writes=${counters.storageWrite} after ${framesToReport} frames`);
check("存档读走过桥", counters.storageRead > 0, `reads=${counters.storageRead}`);
check("列出存档目录", counters.storageList > 0, `lists=${counters.storageList}`);
check("存档键落在虚拟根里", [...storage.keys()].length > 0, `keys=${[...storage.keys()].join(",")}`);

// 剪贴板
check("剪贴板写走过桥", counters.cursorSet >= 0 && clipboard !== "clipboard-from-host");

// ------------------------------------------------- W4：Batcher / 字体 / 热替换
//
// 这一段和上面 W3 那段同一个思路：用记录仪证明「Jai 侧真的发出了这些命令」。
// 像素仍然只能在浏览器里验，所以这里额外断言「无 GL 的宿主会把像素断言标 SKIP」，
// 免得有人把 SKIP 当成 PASS。
{
  // Batcher 顶点格式是 24 字节 4 属性：pos f32×2 / tex f32×2 / col u8×4n / mode u8×4n
  const batcherProgram = glState.programs.find((p) => p.name === "Batcher");
  const batcherPipe = batcherProgram
    ? glState.pipelines.find((p) => p.program === batcherProgram.id)
    : null;
  const bAttrs = batcherPipe ? batcherPipe.attrs : [];
  check("W4 Batcher pipeline 的顶点布局 = 24 字节 4 属性（pos/tex/col/mode）",
    bAttrs.length === 4 && bAttrs.every((a) => a.stride === 24) &&
      bAttrs.map((a) => a.loc).join(",") === "0,1,2,3" &&
      bAttrs.map((a) => a.type).join(",") === [0x1406, 0x1406, 0x1401, 0x1401].join(",") &&
      bAttrs[2].normalized && bAttrs[3].normalized && !bAttrs[0].normalized,
    JSON.stringify(bAttrs.map((a) => [a.loc, a.size, "0x" + a.type.toString(16), a.stride, a.normalized])));

  // 4×4 单色纹理 (200,100,50,128)：wash 吃它的 alpha，fill 忽略它
  const batchTex = glState.textures.find((t) => t.width === 4 && t.height === 4);
  const batchUp = batchTex && batchTex.uploads.find((u) => u.w === 4 && u.h === 4);
  check("W4 Batcher 的 4×4 纹理真的上传了 (200,100,50,128)",
    !!batchUp && batchUp.bytes.length === 64 &&
      batchUp.bytes[0] === 200 && batchUp.bytes[1] === 100 && batchUp.bytes[2] === 50 && batchUp.bytes[3] === 128,
    batchUp ? `(${batchUp.bytes[0]},${batchUp.bytes[1]},${batchUp.bytes[2]},${batchUp.bytes[3]}) ${batchUp.bytes.length}B` : "no upload");

  // 字体：MSDF 图集（wasm 侧是 Roboto.qoi 解出来的 212×212）整块上传
  const atlas = glState.textures.find((t) => t.width === 212 && t.height === 212);
  const atlasUp = atlas && atlas.uploads.find((u) => u.w === 212 && u.h === 212);
  check("W4 MSDF 图集 212×212 整块上传（Roboto.qoi → CPU 解码 → 一张纹理）",
    !!atlasUp && atlasUp.bytes.length === 212 * 212 * 4,
    atlasUp ? `${atlasUp.bytes.length} bytes` : "no upload");

  // Msdf 的片段 std140 block：binding 8（= 8 + fragment slot 0），内容 [DistanceRange,0,0,0]
  const msdfProgram = glState.programs.find((p) => p.name === "Msdf");
  const fragBind = glState.uniformBindings.filter((b) => b.binding === 8).pop();
  const fragBlock = fragBind ? glState.uniformBuffers.find((b) => b.id === fragBind.buffer) : null;
  const fragUp = fragBlock ? fragBlock.uploads[fragBlock.uploads.length - 1] : null;
  const distanceRange = fragUp && fragUp.bytes.length >= 4
    ? new Float32Array(fragUp.bytes.buffer, fragUp.bytes.byteOffset, 1)[0]
    : NaN;
  check("W4 Msdf 片段 uniform 落在 std140 UBO binding 8（DistanceRange = 2）",
    !!msdfProgram && !!fragBlock && fragUp && fragUp.bytes.length === 16 && Math.abs(distanceRange - 2) < 1e-6,
    fragBlock ? `binding=8 capacity=${fragBlock.capacity} bytes=${fragUp ? fragUp.bytes.length : 0} value=${distanceRange}` : "no fragment block at binding 8");

  // 热替换：候选 shader 走的是 do-da 的 shader_create（名字沿用了热替换目标），
  // 8 个 HotReload stage = v1 / v2 / 语法错 / varying 不匹配 各一对。
  const hrShaders = glState.shaders.filter((s) => s.name === "HotReload");
  const hrPrograms = glState.programs.filter((p) => p.name === "HotReload");
  check("W4 热替换为每次尝试都建了一对候选 shader（4 次 × 2 stage）",
    hrShaders.length === 8, `HotReload shaders=${hrShaders.length}`);
  check("W4 热替换真的链出了新 program（换之前 + 换之后 + 每次 probe 各一个）",
    hrPrograms.length >= 3, `HotReload programs=${hrPrograms.length}`);
  const hrLog = logLines.join("");
  check("W4 热替换提交时走的是「就地交换」那条日志（*Shader 地址不变）",
    hrLog.includes("热替换 'v2(texture ignored)' 成功"),
    hrLog.includes("热替换 'v2(texture ignored)' 成功") ? "" : "没有找到提交日志");

  // 无 GL 宿主里，三个像素断言必须是 SKIP，不能假绿
  check("W4 无 WebGL2 宿主时 Batcher / 字体 / 热替换断言全标 SKIP（不假绿）",
    hrLog.includes("W4 BATCHER: SKIP") && hrLog.includes("W4 FONT: SKIP") && hrLog.includes("W4 HOT-REPLACE: SKIP"),
    ["W4 BATCHER: SKIP", "W4 FONT: SKIP", "W4 HOT-REPLACE: SKIP"]
      .filter((k) => !hrLog.includes(k)).join(",") || "");
}

// 退出：按 ESC（scancode 41），示例会 app_exit()
pushEvent(EV.KEY_DOWN, SCANCODE_ESCAPE);
pumpUntilDrained();
let stepped = 0;
let stopped = false;
for (let i = 0; i < 30; i += 1) {
  stepped += 1;
  if (fw_step(1 / 60) === 0) { stopped = true; break; }
}
check("ESC → App.exit → fw_step 返回 0（宿主该停 rAF）", stopped, `after ${stepped} frames`);

// 日志确实流到了宿主
check("日志经 fw_log / WASI 流到宿主", logLines.length > 0, `${logLines.length} chunks`);
const joined = logLines.join("");
check("Jai 侧打印过窗口尺寸", joined.includes("window") || joined.includes("window"), "");

// --------------------------------------------------------------------- 汇总
const failed = results.filter((r) => !r.ok);
console.log(`\n[verify] ${results.length - failed.length}/${results.length} passed`);
if (failed.length > 0) {
  console.log("[verify] FAILED:");
  for (const f of failed) console.log(`  - ${f.name} ${f.detail}`);
  process.exit(1);
}
console.log("[verify] OK — App.update / 窗口尺寸 / 键盘 / 存档 / 退出 经真实 wasm 走通；");
console.log("[verify]      W3 的 GL 命令流（GLSL→program→pipeline→clear→uniform→drawElements）也全对；");
console.log("[verify]      像素断言在无 GL 的 Node 里是 SKIP，真像素见浏览器验证（tools/verify_web_gl.py）");
console.log("\n---- Jai 侧日志（前 40 行）----");
console.log(logLines.join("").split("\n").slice(0, 40).join("\n"));
