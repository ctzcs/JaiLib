#!/usr/bin/env python3
"""
jfoster -- GLSL ES 3.00 shader assets for the WebGL2 backend (W3/W4 prerequisite).

What this script is for
=======================
jfoster's desktop backends eat *precompiled* shader blobs
(content/shaders/Compiled/<Name>.{vertex,fragment}.{spv,dxil,msl}, embedded by
graphics/default_resource_data.jai). WebGL2 only eats *GLSL ES 3.00 text*, so the
default shader set needs a second asset family. This script owns that family.

It produces and checks twelve GLSL ES 3.00 sources under internal/web/shaders/:

  canonical/   (checked in, hand-authored, what the W3 backend compiles)
      batcher.vertex.glsl    batcher.fragment.glsl
      textured.vertex.glsl   textured.fragment.glsl
      msdf.vertex.glsl       msdf.fragment.glsl

  reference/   (generated here, provenance + equivalence baseline)
      batcher.vertex.glsl    batcher.fragment.glsl
      textured.vertex.glsl   textured.fragment.glsl
      msdf.vertex.glsl       msdf.fragment.glsl
      ^ the SDL_shadercross -> spirv-cross lowering of content/shaders/*.hlsl:
        HLSL -> SPIR-V -> GLSL ES 3.00, std140 uniform blocks, layout(row_major).

Why two sets
------------
The generated set is *byte-faithful to the SPIR-V* and therefore the oracle: it is
what the desktop path executes, mechanically translated. But it is not what we
want to ship as the W3 source, because the D3D-space HLSL does not lower 1:1:

  * Msdf's HLSL `Texture.GetDimensions()` makes spirv-cross emit TWO sampler2D
    uniforms (the real one plus a SPIRV_Cross_DummySampler for textureSize).
    jfoster's Shader contract is SamplerCount == 1 (graphics/defaults.jai), so a
    2-sampler program would need extra texture-unit plumbing for no reason.
  * every interface name becomes `in_var_TEXCOORD0` / `UniformBlock.Matrix` /
    `SPIRV_Cross_CombinedTextureSampler`, i.e. none of the uniform names
    (Matrix, DistanceRange, Texture) survive.
  * the Msdf math comes out with isnan() guards around every min/max, and the
    vertex matrix goes through a `spvWorkaroundRowMajor()` identity function.

So: canonical/ is hand-authored GLSL ES 3.00 that keeps the HLSL's names, one
sampler per texture and one plain uniform per uniform slot; reference/ is the
generated oracle. This script proves the two agree by *rendering* every program
both ways in a real WebGL2 context and comparing pixels, and by comparing the
linked program interface (attribute locations/types, uniform names/types).

Usage
=====
    python tools/build_glsl_es.py             # regenerate reference/ + verify all 12
    python tools/build_glsl_es.py --check      # verify only, fail on reference/ drift
    python tools/build_glsl_es.py --gen-only   # regenerate reference/, no browser
    python tools/build_glsl_es.py --keep-page  # leave the harness HTML in .test_tmp/

Verification needs a WebGL2-capable browser; the script drives headless Chrome
(or Edge) with SwiftShader, so no GPU and no server is required. Override with
CHROME=/path/to/chrome.exe.

Requires (generation only): shadercross, spirv-cross, dxc-with-vulkan-target
(shadercross bundles it). Both were present on the machine this was written on;
`--check` works without them.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHADER_DIR = os.path.join(ROOT, "internal", "web", "shaders")
REF_DIR = os.path.join(SHADER_DIR, "reference")
HLSL_DIR = os.path.join(ROOT, "content", "shaders")
TMP_DIR = os.path.join(ROOT, ".test_tmp")

# ---------------------------------------------------------------------------
# the shader table
#
#   variant        HLSL source            stages
#   Batcher        Batcher.hlsl           vertex + fragment
#   Textured       Textured.hlsl          vertex + fragment
#   Msdf           Msdf.hlsl              vertex + fragment
#
# `vertex_stride` / `attributes` mirror graphics/batcher_vertex.jai and the
# PosTexCol layout the Textured program consumes; the pixel test builds its
# vertex buffer from exactly these bytes.
# ---------------------------------------------------------------------------
VARIANTS = ["batcher", "textured", "msdf"]
STAGES = ["vertex", "fragment"]

HLSL_NAME = {"batcher": "Batcher", "textured": "Textured", "msdf": "Msdf"}
STAGE_SUFFIX = {"vertex": "vertex_main", "fragment": "fragment_main"}

# Batcher_Vertex (24 B): pos f32x2, tex f32x2, col u8x4n, mode u8x4n
BATCHER_LAYOUT = [
    # (location, components, offset, normalized)
    (0, 2, 0, False),
    (1, 2, 8, False),
    (2, 4, 16, True),
    (3, 4, 20, True),
]
# PosTexCol (20 B): pos f32x2, tex f32x2, col u8x4n
TEXTURED_LAYOUT = [
    (0, 2, 0, False),
    (1, 2, 8, False),
    (2, 4, 16, True),
]

LAYOUTS = {
    "batcher": (24, BATCHER_LAYOUT),
    # MSDF text is drawn through the Batcher mesh, but the compiled SPIR-V has no
    # input at location 3 (the HLSL declares VsInput.Type and never reads it), so
    # the program only consumes 0/1/2. Stride stays 24 because the buffer is a
    # Batcher_Vertex stream.
    "msdf": (24, TEXTURED_LAYOUT),
    "textured": (20, TEXTURED_LAYOUT),
}

# What each program must expose once linked. Attribute locations come from the
# layout tables above.
#
# Since W4 the canonical set addresses uniforms the way the backend does: *by
# slot*, through a std140 uniform block whose binding point the app assigns with
# gl.uniformBlockBinding (vertex slot i -> binding i, fragment slot i -> binding
# 8+i; a binding point is one flat namespace per context, hence the 8). The member
# names inside a block are only a debugging label -- nothing looks them up.
#
# So EXPECTED_UNIFORMS now only lists the *plain* (non-block) uniforms, which is
# exactly the samplers (opaque types cannot live in a std140 block in GLSL ES
# 3.00), and EXPECTED_BLOCKS lists the block layout + std140 size the backend
# depends on:
#   * 64 B == the raw jfoster Matrix4 blob (4 columns x vec4),
#   * 16 B == the [4] float32 blob sprite_font_create_from_msdf pushes for Msdf
#     (std140 pads `float DistanceRange` to a vec4).
EXPECTED_UNIFORMS = {
    ("batcher", "vertex"): {},
    ("batcher", "fragment"): {"Texture": "SAMPLER_2D"},
    ("textured", "vertex"): {},
    ("textured", "fragment"): {"Texture": "SAMPLER_2D"},
    ("msdf", "vertex"): {},
    ("msdf", "fragment"): {"Texture": "SAMPLER_2D"},
}

# (min bytes, max bytes) -- the GL-reported UNIFORM_BLOCK_DATA_SIZE is the
# *minimum* buffer size the block needs: std140 keeps a trailing mat4 at exactly
# 64 B, but a lone float is reported as 4 B even though the spec rounds the block
# up to a vec4 and the backend uploads 16 B. Both are fine: the backend sizes its
# UBO to hold the whole 16-byte blob, and every member offset is what matters.
EXPECTED_BLOCKS = {
    ("batcher", "vertex"): {"JfosterVertexUniforms": (64, 64)},
    ("batcher", "fragment"): {},
    ("textured", "vertex"): {"JfosterVertexUniforms": (64, 64)},
    ("textured", "fragment"): {},
    ("msdf", "vertex"): {"JfosterVertexUniforms": (64, 64)},
    ("msdf", "fragment"): {"JfosterFragmentUniforms": (4, 16)},
}


def canon_path(variant: str, stage: str) -> str:
    return os.path.join(SHADER_DIR, f"{variant}.{stage}.glsl")


def ref_path(variant: str, stage: str) -> str:
    return os.path.join(REF_DIR, f"{variant}.{stage}.glsl")


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8", newline="") as fh:
        return fh.read().replace("\r\n", "\n")


def write_text(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


# ---------------------------------------------------------------------------
# 1. generation: HLSL -> SPIR-V -> GLSL ES 3.00
# ---------------------------------------------------------------------------
PROVENANCE = """//
// GENERATED FILE - DO NOT EDIT.  Produced by tools/build_glsl_es.py.
//
//   source   content/shaders/{hlsl}  ::  {entry}
//   chain    shadercross (HLSL -> SPIR-V, SDL_shadercross) -> spirv-cross --version 300 --es
//
// This is the mechanical lowering of the exact SPIR-V/DXIL/MSL family the desktop
// backends consume: std140 uniform blocks, layout(row_major) matrices, and
// spirv-cross's mangled interface names. It is kept as the *equivalence oracle*
// for internal/web/shaders/<variant>.<stage>.glsl (the hand-authored twin the
// WebGL2 backend actually compiles); tools/build_glsl_es.py renders both and
// compares pixels, and diffs the linked interface.
//
// Post-processed by the generator: spirv-cross names the vertex shader's
// varyings `out_var_TEXCOORD0` and the fragment shader's `in_var_TEXCOORD0`.
// GLSL ES 3.00 links varyings *by name* (explicit `layout(location)` on varyings
// is not available before ES 3.10), so crossing the two stages separately does
// not link until the prefixes are normalised. The generator renames
// out_var_* (vertex) and in_var_* (fragment) to v_*; nothing else is touched.
//
// Regenerate with:  python tools/build_glsl_es.py
//"""


def find_tool(env_name: str, exe: str, extra_dirs: list[str]) -> str | None:
    override = os.environ.get(env_name)
    if override:
        return override if os.path.exists(override) else None
    found = shutil.which(exe)
    if found:
        return found
    for d in extra_dirs:
        cand = os.path.join(d, exe)
        if os.path.exists(cand):
            return cand
        cand += ".exe"
        if os.path.exists(cand):
            return cand
    return None


def locate_generators() -> tuple[str | None, str | None]:
    shadercross = find_tool(
        "SHADERCROSS", "shadercross",
        [r"D:\Tools\ShaderCross\bin", "/d/Tools/ShaderCross/bin"],
    )
    spirv_cross = find_tool(
        "SPIRV_CROSS", "spirv-cross",
        [r"C:\VulkanSDK\1.4.357.0\Bin", "/c/VulkanSDK/1.4.357.0/Bin"],
    )
    return shadercross, spirv_cross


def generate_reference(shadercross: str, spirv_cross: str) -> dict[str, str]:
    """Returns {relative path -> content} for the six reference shaders."""
    out: dict[str, str] = {}
    work = tempfile.mkdtemp(prefix="jfoster_glsl_")
    try:
        for variant in VARIANTS:
            hlsl = os.path.join(HLSL_DIR, f"{HLSL_NAME[variant]}.hlsl")
            if not os.path.exists(hlsl):
                raise SystemExit(f"missing HLSL source: {hlsl}")
            for stage in STAGES:
                spv = os.path.join(work, f"{variant}.{stage}.spv")
                glsl = os.path.join(work, f"{variant}.{stage}.glsl")
                subprocess.run(
                    [shadercross, hlsl, "-e", STAGE_SUFFIX[stage], "-t", stage,
                     "-s", "HLSL", "-o", spv],
                    check=True, capture_output=True,
                )
                subprocess.run(
                    # --relax-nan-checks: emit plain GLSL min/max() instead of
                    # wrapping every one in isnan() guards. The HLSL never defines
                    # NaN behaviour, and the text is only an oracle here.
                    [spirv_cross, spv, "--version", "300", "--es",
                     "--relax-nan-checks", "--output", glsl],
                    check=True, capture_output=True,
                )
                body = read_text(glsl)
                out[f"{variant}.{stage}.glsl"] = with_provenance(variant, stage, body)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return out


def normalize_generated(stage: str, body: str) -> str:
    """Make the two stages link.

    spirv-cross emits `out vec4 out_var_TEXCOORD1;` in the vertex shader and
    `in vec4 in_var_TEXCOORD1;` in the fragment shader. GLSL ES 3.00 matches
    varyings by *name* (varying `layout(location)` only arrives in ES 3.10), so
    the pair fails to link with
        FRAGMENT varying in_var_TEXCOORD1 does not match any VERTEX varying.
    Rename the varying side only: vertex `out_var_` -> `v_`, fragment `in_var_`
    -> `v_`. Vertex `in_var_*` are attributes and fragment `out_var_*` is the
    colour output, so neither is touched.
    """
    if stage == "vertex":
        return re.sub(r"\bout_var_", "v_", body)
    return re.sub(r"\bin_var_", "v_", body)


def with_provenance(variant: str, stage: str, body: str) -> str:
    """Normalize varyings and insert the provenance banner after #version."""
    header = PROVENANCE.format(
        hlsl=f"{HLSL_NAME[variant]}.hlsl", entry=STAGE_SUFFIX[stage]
    )
    lines = body.split("\n")
    assert lines and lines[0].startswith("#version"), lines[0][:40]
    rest = normalize_generated(stage, "\n".join(lines[1:]))
    # spirv-cross puts a blank line after #version; keep exactly one.
    rest = rest.lstrip("\n")
    return lines[0] + "\n" + header + "\n\n" + rest


# ---------------------------------------------------------------------------
# 2. verification: compile + link + render in a real WebGL2 context
# ---------------------------------------------------------------------------
HARNESS_JS = r"""
(function () {
  const payload = JSON.parse(document.getElementById("payload").textContent);
  const out = { env: {}, shaders: [], programs: [], pixel: [], errors: [] };
  const CANVAS = 64;

  function finish() {
    const pre = document.createElement("pre");
    pre.id = "report";
    pre.textContent = JSON.stringify(out);
    const body = document.createElement("body");
    body.appendChild(pre);
    const root = document.createElement("html");
    root.appendChild(document.createElement("head"));
    root.appendChild(body);
    document.replaceChild(root, document.documentElement);
  }

  const canvas = document.createElement("canvas");
  canvas.width = CANVAS;
  canvas.height = CANVAS;
  const gl = canvas.getContext("webgl2", {
    antialias: false, alpha: true, depth: false, stencil: false,
    preserveDrawingBuffer: true, premultipliedAlpha: false,
  });
  if (!gl) { out.errors.push("no webgl2 context"); finish(); return; }

  const dbg = gl.getExtension("WEBGL_debug_renderer_info");
  out.env = {
    version: String(gl.getParameter(gl.VERSION)),
    glsl: String(gl.getParameter(gl.SHADING_LANGUAGE_VERSION)),
    vendor: String(gl.getParameter(gl.VENDOR)),
    renderer: String(dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER)),
    maxTextureUnits: gl.getParameter(gl.MAX_COMBINED_TEXTURE_IMAGE_UNITS),
    maxVertexAttribs: gl.getParameter(gl.MAX_VERTEX_ATTRIBS),
  };

  // WebGL constants live on the prototype, so Object.keys(gl) is empty; map the
  // handful we assert on explicitly instead.
  const TYPE_NAME = {};
  [
    ["FLOAT", gl.FLOAT], ["FLOAT_VEC2", gl.FLOAT_VEC2], ["FLOAT_VEC3", gl.FLOAT_VEC3],
    ["FLOAT_VEC4", gl.FLOAT_VEC4], ["FLOAT_MAT3", gl.FLOAT_MAT3], ["FLOAT_MAT4", gl.FLOAT_MAT4],
    ["INT", gl.INT], ["INT_VEC4", gl.INT_VEC4], ["UNSIGNED_BYTE", gl.UNSIGNED_BYTE],
    ["SAMPLER_2D", gl.SAMPLER_2D], ["SAMPLER_CUBE", gl.SAMPLER_CUBE],
  ].forEach(function (pair) { TYPE_NAME[pair[1]] = pair[0]; });

  // ---- shader compile -----------------------------------------------------
  function compile(stageEnum, src) {
    const sh = gl.createShader(stageEnum);
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    const ok = gl.getShaderParameter(sh, gl.COMPILE_STATUS);
    const log = gl.getShaderInfoLog(sh) || "";
    return { sh, ok: !!ok, log: log.trim() };
  }

  for (const entry of payload.shaders) {
    const stageEnum = entry.stage === "vertex" ? gl.VERTEX_SHADER : gl.FRAGMENT_SHADER;
    const r = compile(stageEnum, entry.source);
    out.shaders.push({
      key: entry.key, variant: entry.variant, stage: entry.stage,
      ok: r.ok, log: r.log, bytes: entry.source.length,
      lines: entry.source.split("\n").length,
    });
    if (!r.ok) entry.broken = true;
    entry.shader = r.sh;
  }

  // ---- program link + interface introspection -----------------------------
  const programs = {};
  for (const variant of payload.variants) {
    programs[variant] = {};
    for (const set of ["canonical", "reference"]) {
      const vs = payload.shaders.find((s) => s.variant === variant && s.stage === "vertex" && s.set === set);
      const fs = payload.shaders.find((s) => s.variant === variant && s.stage === "fragment" && s.set === set);
      const key = variant + "/" + set;
      if (!vs || !fs || vs.broken || fs.broken) {
        out.programs.push({ key, ok: false, log: "shader did not compile", attribs: [], uniforms: [], blocks: [] });
        continue;
      }
      const prog = gl.createProgram();
      gl.attachShader(prog, vs.shader);
      gl.attachShader(prog, fs.shader);
      gl.linkProgram(prog);
      const ok = !!gl.getProgramParameter(prog, gl.LINK_STATUS);
      const log = (gl.getProgramInfoLog(prog) || "").trim();
      const attribs = [];
      const na = gl.getProgramParameter(prog, gl.ACTIVE_ATTRIBUTES) || 0;
      for (let i = 0; i < na; i++) {
        const a = gl.getActiveAttrib(prog, i);
        attribs.push({ name: a.name, type: TYPE_NAME[a.type] || a.type, size: a.size, loc: gl.getAttribLocation(prog, a.name) });
      }
      const uniforms = [];
      const nu = gl.getProgramParameter(prog, gl.ACTIVE_UNIFORMS) || 0;
      for (let i = 0; i < nu; i++) {
        const u = gl.getActiveUniform(prog, i);
        uniforms.push({ name: u.name, type: TYPE_NAME[u.type] || u.type, size: u.size });
      }
      const blocks = [];
      const nb = gl.getProgramParameter(prog, gl.ACTIVE_UNIFORM_BLOCKS) || 0;
      for (let i = 0; i < nb; i++) {
        blocks.push({ name: gl.getActiveUniformBlockName(prog, i), bytes: gl.getActiveUniformBlockParameter(prog, i, gl.UNIFORM_BLOCK_DATA_SIZE) });
      }
      attribs.sort((a, b) => a.loc - b.loc);
      out.programs.push({ key, ok, log, attribs, uniforms, blocks });
      programs[variant][set] = { prog, ok, attribs, uniforms, blocks };
    }
  }

  // ---- test assets --------------------------------------------------------
  // 4x4 RGBA8 with a deterministic non-uniform pattern.
  const TEXW = 4;
  const texData = new Uint8Array(TEXW * TEXW * 4);
  for (let i = 0; i < texData.length; i++) texData[i] = (i * 37 + 11) & 0xff;
  // keep alpha of the msdf channels away from 0/255 extremes
  for (let i = 3; i < texData.length; i += 4) texData[i] = 200;

  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, TEXW, TEXW, 0, gl.RGBA, gl.UNSIGNED_BYTE, texData);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

  // Batcher ortho matrix, built exactly like graphics/batcher.jai :: batcher_render
  // (Matrix4x4.CreateOrthographicOffCenter(0, w, h, 0, 0, float.MaxValue), row-major
  // bytes: m._11, m._22, m._33, m._41 = -1, m._42 = 1, m._43 = -1, m._44 = 1).
  function orthoBlob(w, h) {
    const m = new Float32Array(16);
    m[0] = 2.0 / w;
    m[5] = -2.0 / h;
    m[10] = 1.0 / 3.4028235e38;
    m[12] = -1;
    m[13] = 1;
    m[14] = -1;
    m[15] = 1;
    return m;
  }
  const matrixBlob = orthoBlob(CANVAS, CANVAS);

  const matrixUBO = gl.createBuffer();
  gl.bindBuffer(gl.UNIFORM_BUFFER, matrixUBO);
  gl.bufferData(gl.UNIFORM_BUFFER, matrixBlob, gl.STATIC_DRAW);
  const rangeUBO = gl.createBuffer();
  gl.bindBuffer(gl.UNIFORM_BUFFER, rangeUBO);
  gl.bufferData(gl.UNIFORM_BUFFER, new Float32Array([2.0, 0, 0, 0]), gl.STATIC_DRAW);
  gl.bindBuffer(gl.UNIFORM_BUFFER, null);

  // A quad at (16,16)..(48,48). Written through the vertex format under test, so
  // the byte offsets and the stride are the ones the backend will use (24 B for
  // Batcher_Vertex, 20 B for PosTexCol).
  const QUAD = [
    [16, 16, 0, 0], [48, 16, 1, 0], [48, 48, 1, 1],
    [16, 16, 0, 0], [48, 48, 1, 1], [16, 48, 0, 1],
  ];
  // tc.color is the left-edge colour; a gradient test writes a second colour on
  // the right edge so the interpolation is actually exercised.
  function makeVB(tc, layoutKey) {
    const layout = LAYOUT[layoutKey];
    const stride = layout[0];
    const attrs = layout[1];
    const buf = new ArrayBuffer(stride * QUAD.length);
    const f32 = new Float32Array(buf);
    const u8 = new Uint8Array(buf);
    const right = tc.gradient ? tc.color2 : tc.color;
    QUAD.forEach(function (q, i) {
      const base = i * stride;
      const cols = q[2] > 0.5 ? right : tc.color;
      for (const a of attrs) {
        const loc = a[0], comps = a[1], off = a[2], norm = a[3];
        let value;
        if (loc === 0) value = [q[0], q[1]];
        else if (loc === 1) value = [q[2], q[3]];
        else if (loc === 2) value = cols;
        else value = tc.mode;
        for (let c = 0; c < comps; c++) {
          const at = base + off + (norm ? c : c * 4);
          if (norm) u8[at] = value[c];
          else f32[at / 4] = value[c];
        }
      }
    });
    return buf;
  }
  const LAYOUT = payload.layouts;
  const vbo = gl.createBuffer();
  const vao = gl.createVertexArray();
  gl.bindVertexArray(vao);
  gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
  gl.bufferData(gl.ARRAY_BUFFER,
    makeVB({ color: [255, 128, 64, 200], mode: [0, 0, 255, 0] }, "batcher"), gl.STATIC_DRAW);
  function setLayout(layoutKey) {
    const [stride, attrs] = LAYOUT[layoutKey];
    gl.bindVertexArray(vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    for (let loc = 0; loc < 4; loc++) gl.disableVertexAttribArray(loc);
    for (const a of attrs) {
      const [loc, comps, off, norm] = a;
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, comps, norm ? gl.UNSIGNED_BYTE : gl.FLOAT, norm, stride, off);
    }
  }

  function uploadUniforms(prog) {
    const locM = gl.getUniformLocation(prog, "Matrix");
    if (locM) gl.uniformMatrix4fv(locM, false, matrixBlob);
    const locD = gl.getUniformLocation(prog, "DistanceRange");
    if (locD) gl.uniform1f(locD, 2.0);
    const nb = gl.getProgramParameter(prog, gl.ACTIVE_UNIFORM_BLOCKS) || 0;
    for (let i = 0; i < nb; i++) {
      const name = gl.getActiveUniformBlockName(prog, i) || "";
      gl.uniformBlockBinding(prog, i, /fragment/i.test(name) ? 1 : 0);
    }
    gl.bindBufferBase(gl.UNIFORM_BUFFER, 0, matrixUBO);
    gl.bindBufferBase(gl.UNIFORM_BUFFER, 1, rangeUBO);
    // samplers: assign units 0..n-1 in declaration order
    let unit = 0;
    const nu = gl.getProgramParameter(prog, gl.ACTIVE_UNIFORMS) || 0;
    for (let i = 0; i < nu; i++) {
      const u = gl.getActiveUniform(prog, i);
      if (u.type === gl.SAMPLER_2D) {
        gl.uniform1i(gl.getUniformLocation(prog, u.name), unit);
        gl.activeTexture(gl.TEXTURE0 + unit);
        gl.bindTexture(gl.TEXTURE_2D, tex);
        unit += 1;
      }
    }
    return unit;
  }

  function bboxOf(pixels) {
    let x0 = 1e9, y0 = 1e9, x1 = -1, y1 = -1, nonzero = 0;
    for (let y = 0; y < CANVAS; y++) {
      for (let x = 0; x < CANVAS; x++) {
        const o = (y * CANVAS + x) * 4;
        if (pixels[o] || pixels[o + 1] || pixels[o + 2] || pixels[o + 3]) {
          nonzero += 1;
          if (x < x0) x0 = x;
          if (y < y0) y0 = y;
          if (x > x1) x1 = x;
          if (y > y1) y1 = y;
        }
      }
    }
    return { x0, y0, x1, y1, nonzero };
  }

  function render(prog, layoutKey, vbBytes) {
    gl.useProgram(prog);
    gl.disable(gl.BLEND);
    gl.disable(gl.DEPTH_TEST);
    gl.disable(gl.SCISSOR_TEST);
    gl.viewport(0, 0, CANVAS, CANVAS);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (vbBytes) {
      gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
      gl.bufferData(gl.ARRAY_BUFFER, vbBytes, gl.STATIC_DRAW);
    }
    setLayout(layoutKey);
    uploadUniforms(prog);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
    gl.flush();
    const out8 = new Uint8Array(CANVAS * CANVAS * 4);
    gl.readPixels(0, 0, CANVAS, CANVAS, gl.RGBA, gl.UNSIGNED_BYTE, out8);
    return out8;
  }

  // ---- pixel equivalence: canonical vs reference --------------------------
  const MODES = payload.pixelModes; // [{name, color, mode}]
  for (const variant of payload.variants) {
    const c = programs[variant].canonical;
    const r = programs[variant].reference;
    if (!c || !c.ok || !r || !r.ok) {
      out.pixel.push({ variant, ok: false, reason: "program missing" });
      continue;
    }
    // Batcher is the only program with a mode attribute; the other two get one case.
    const cases = variant === "batcher" ? MODES : [MODES[0]];
    for (const tc of cases) {
      const vb = makeVB(tc, variant);
      const a = render(c.prog, variant, vb);
      const b = render(r.prog, variant, vb);
      let maxdiff = 0, diffs = 0;
      for (let i = 0; i < a.length; i++) {
        const d = Math.abs(a[i] - b[i]);
        if (d) { diffs += 1; if (d > maxdiff) maxdiff = d; }
      }
      out.pixel.push({
        variant, ok: true, case: tc.name,
        maxdiff, diffBytes: diffs,
        bboxCanonical: bboxOf(a), bboxReference: bboxOf(b),
        sample: Array.from(a.slice((20 * CANVAS + 20) * 4, (20 * CANVAS + 20) * 4 + 4)),
      });
    }
  }

  finish();
})();
"""

HARNESS_HTML = """<!doctype html>
<meta charset="utf-8">
<title>jfoster GLSL ES 3.00 verification</title>
<style>body{{font:12px/1.4 monospace}}</style>
<body><pre id="o">running...</pre>
<script type="application/json" id="payload">{payload}</script>
<script>{js}</script>
"""


def build_harness(shaders: list[dict]) -> str:
    payload = {
        "variants": VARIANTS,
        "shaders": shaders,
        "layouts": {k: [v[0], [list(a) for a in v[1]]] for k, v in LAYOUTS.items()},
        "pixelModes": [
            {"name": "normal", "color": [255, 128, 64, 200], "mode": [255, 0, 0, 0]},
            {"name": "wash", "color": [255, 128, 64, 200], "mode": [0, 255, 0, 0]},
            {"name": "fill/solid", "color": [255, 128, 64, 200], "mode": [0, 0, 255, 0]},
            # gradient: fill mode, per-vertex colours differ -> interpolation on vColor
            {"name": "fill/gradient", "color": [255, 0, 0, 255],
             "color2": [0, 64, 255, 128], "mode": [0, 0, 255, 0], "gradient": True},
        ],
    }
    blob = json.dumps(payload).replace("<", "\\u003c").replace(">", "\\u003e")
    return HARNESS_HTML.format(payload=blob, js=HARNESS_JS)


def find_browser() -> str:
    override = os.environ.get("CHROME")
    if override:
        if not os.path.exists(override):
            raise SystemExit(f"CHROME points at a missing file: {override}")
        return override
    candidates = [
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/usr/bin/google-chrome",
        "/usr/bin/chromium",
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    for name in ("chrome", "google-chrome", "chromium", "msedge"):
        found = shutil.which(name)
        if found:
            return found
    raise SystemExit(
        "No Chrome/Edge found for the WebGL2 check.\n"
        "Set CHROME=/path/to/chrome.exe, or run with --gen-only."
    )


def run_harness(page_html: str, keep: bool, swiftshader: bool = True) -> dict:
    os.makedirs(TMP_DIR, exist_ok=True)
    page = os.path.join(TMP_DIR, "glsl_verify.html")
    write_text(page, page_html)
    browser = find_browser()
    url = "file:///" + page.replace("\\", "/").lstrip("/")
    cmd = [browser, "--headless=new", "--no-sandbox", "--disable-extensions"]
    if swiftshader:
        # Deterministic: pure-software rasterisation, works on a build machine
        # with no GPU at all.
        cmd += ["--disable-gpu", "--enable-unsafe-swiftshader", "--use-angle=swiftshader"]
    cmd += ["--virtual-time-budget=20000", "--dump-dom", url]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    dom = proc.stdout
    m = re.search(r'<pre id="report">(.*?)</pre>', dom, re.S)
    if not m:
        tail = dom[-2000:] if dom else proc.stderr[-2000:]
        raise SystemExit("harness produced no report.\n--- browser output tail ---\n" + tail)
    report = json.loads(html.unescape(m.group(1)))
    if not keep:
        try:
            os.remove(page)
        except OSError:
            pass
    return report


# ---------------------------------------------------------------------------
# 3. reporting
# ---------------------------------------------------------------------------
GREEN = "\033[32m"
RED = "\033[31m"
YEL = "\033[33m"
DIM = "\033[2m"
OFF = "\033[0m"


def colorize(ok: bool, text: str) -> str:
    if not sys.stdout.isatty():
        return text
    return (GREEN if ok else RED) + text + OFF


def check_interface(report: dict) -> list[str]:
    """Assert the linked program exposes the interface the backend relies on."""
    problems = []
    by_key = {p["key"]: p for p in report["programs"]}
    for variant in VARIANTS:
        want_locs = [a[0] for a in LAYOUTS[variant][1]]
        # a linked program exposes the union of the vertex and fragment uniforms
        want_u = {}
        want_b = {}
        for stage in STAGES:
            want_u.update(EXPECTED_UNIFORMS[(variant, stage)])
            want_b.update(EXPECTED_BLOCKS[(variant, stage)])
        for set_name in ("canonical", "reference"):
            key = f"{variant}/{set_name}"
            p = by_key.get(key)
            if not p or not p.get("ok"):
                problems.append(f"{key}: program did not link")
                continue
            got_locs = [a["loc"] for a in p["attribs"]]
            if got_locs != want_locs:
                problems.append(f"{key}: attribute locations {got_locs} != expected {want_locs}")
            for a in p["attribs"]:
                if a["type"] not in ("FLOAT_VEC2", "FLOAT_VEC4"):
                    problems.append(f"{key}: attribute {a['name']} has unexpected type {a['type']}")
            if set_name == "canonical":
                # the canonical set is the one the backend compiles: its plain
                # uniforms (the samplers) and its std140 blocks must match the
                # slot table web_gl.jai implements.
                # ACTIVE_UNIFORMS also lists block members as "Block.member";
                # the plain-uniform set is the samplers only.
                got_u = {u["name"]: u["type"] for u in p["uniforms"] if "." not in u["name"]}
                if got_u != want_u:
                    problems.append(f"{key}: uniforms {got_u} != expected {want_u}")
                got_b = {b["name"]: b["bytes"] for b in p["blocks"]}
                if set(got_b) != set(want_b):
                    problems.append(f"{key}: uniform blocks {sorted(got_b)} != expected {sorted(want_b)}")
                for name, (lo, hi) in want_b.items():
                    size = got_b.get(name)
                    if size is None or not (lo <= size <= hi):
                        problems.append(f"{key}: block {name} is {size} B, expected {lo}..{hi} B")
    return problems


def print_report(report: dict) -> tuple[bool, list[str]]:
    problems: list[str] = []
    env = report["env"]
    print()
    print(f"{DIM}WebGL2 context:{OFF} {env.get('version')}")
    print(f"{DIM}GLSL ES     :{OFF} {env.get('glsl')}")
    print(f"{DIM}renderer    :{OFF} {env.get('renderer')}")
    print()

    print(f"{'#':<3} {'shader':<34} {'bytes':>6} {'lines':>5}  {'compile':<8} getShaderInfoLog")
    print("-" * 96)
    hard_fail = False
    for i, s in enumerate(report["shaders"], 1):
        ok = s["ok"]
        if not ok:
            hard_fail = True
        log = "empty (= success)" if ok and not s["log"] else (s["log"] or "(empty)")
        log = log.replace("\n", " / ")
        if len(log) > 72:
            log = log[:69] + "..."
        print(f"{i:<3} {s['key']:<34} {s['bytes']:>6} {s['lines']:>5}  "
              f"{colorize(ok, 'OK ' if ok else 'FAIL'):<8} {log}")

    print()
    print("linked program interface (attribute locations must match the vertex formats)")
    print("-" * 96)
    for p in report["programs"]:
        attrs = ", ".join(f"loc{a['loc']}={a['type']}" for a in p["attribs"])
        print(f"  {colorize(bool(p['ok']), p['key']):<28} attribs[{attrs}]")
        uni = ", ".join(f"{u['name']}:{u['type']}" for u in p["uniforms"])
        blk = ", ".join(f"{b['name']}({b['bytes']}B)" for b in p["blocks"])
        print(f"  {'':<28} uniforms[{uni}]" + (f" blocks[{blk}]" if blk else ""))

    print()
    print("pixel equivalence: canonical GLSL  vs  generated (SPIR-V-derived) GLSL")
    print("-" * 96)
    for px in report["pixel"]:
        if not px.get("ok"):
            print(f"  {colorize(False, px['variant']):<12} {px.get('reason')}")
            hard_fail = True
            continue
        bc = px["bboxCanonical"]
        br = px["bboxReference"]
        same_bbox = (bc == br)
        good = px["maxdiff"] == 0 and same_bbox
        if not good:
            problems.append(f"{px['variant']}/{px['case']}: pixel mismatch (maxdiff={px['maxdiff']})")
        print(
            f"  {colorize(good, px['variant']):<12} case={px['case']:<14} "
            f"maxdiff={px['maxdiff']} diffBytes={px['diffBytes']:>5}  "
            f"bbox={bc['x0']},{bc['y0']}..{bc['x1']},{bc['y1']} "
            f"({'same' if same_bbox else 'DIFFERENT'}) px@{bc['nonzero']} "
            f"rgba={px['sample']}"
        )
        # the quad was authored at 16..47; anything else means the matrix
        # convention (row/column major) is wrong.
        expect = (16, 16, 47, 47)
        got = (bc["x0"], bc["y0"], bc["x1"], bc["y1"])
        if got != expect:
            problems.append(f"{px['variant']}/{px['case']}: quad bbox {got} != {expect} (matrix convention)")

    problems.extend(check_interface(report))
    if report.get("errors"):
        problems.extend(report["errors"])

    print()
    if hard_fail or problems:
        print(colorize(False, "[verify] FAIL"))
        for p in problems:
            print("  - " + p)
        return False, problems
    print(colorize(True, "[verify] OK - 12/12 GLSL ES 3.00 sources compile, all programs link,"))
    print(colorize(True, "         6/6 canonical programs are pixel-identical to the generated ones,"))
    print(colorize(True, "         and every quad lands at 16,16..47,47 (matrix convention correct)."))
    return True, problems


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def collect_sources() -> list[dict]:
    shaders = []
    missing = []
    for variant in VARIANTS:
        for stage in STAGES:
            for set_name, path_fn in (("canonical", canon_path), ("reference", ref_path)):
                path = path_fn(variant, stage)
                if not os.path.exists(path):
                    missing.append(os.path.relpath(path, ROOT))
                    continue
                shaders.append({
                    "key": f"{set_name}/{variant}.{stage}.glsl",
                    "variant": variant,
                    "stage": stage,
                    "set": set_name,
                    "source": read_text(path),
                })
    return shaders, missing


# ---------------------------------------------------------------------------
# 4. Jai-side check: the embedded bytes == the verified files
#
# internal/web/web_shader_source.jai embeds the six (x2) .glsl files with
# `#run` + File.read_entire_file. That is only useful if it really compiles for
# the wasm target and really carries the same bytes, so this builds a throwaway
# probe, runs it natively and compares the byte counts with the files on disk.
# ---------------------------------------------------------------------------
JAI_PROBE = r"""Basic  :: #import "Basic";
File   :: #import "File";
String :: #import "String";

#scope_module
#load "../../internal/web/web_shader_source.jai";
#scope_export

main :: () {
    for e: WEB_SHADERS {
        print("CANON % %\n", e.name, e.source.count);
    }
    for e: WEB_SHADER_REFERENCE {
        print("REF % %\n", e.name, e.source.count);
    }
}
"""


def find_jaic() -> str | None:
    override = os.environ.get("JAIC")
    if override:
        return override if os.path.exists(override) else None
    found = shutil.which("jaic")
    if found:
        return found
    for cand in (r"D:\Lib\jacket-windows-x64\jaic.exe",
                 "/d/Lib/jacket-windows-x64/jaic.exe"):
        if os.path.exists(cand):
            return cand
    return None


def check_jai_embed() -> bool:
    jaic = find_jaic()
    if not jaic:
        print(f"{YEL}[jai]{OFF} jaic not found - skipping the #run embedding check")
        print(f"{YEL}[jai]{OFF} (set JAIC=/path/to/jaic.exe to enable it)")
        return True

    probe_dir = os.path.join(TMP_DIR, "shader_src_probe")
    os.makedirs(probe_dir, exist_ok=True)
    probe = os.path.join(probe_dir, "probe.jai")
    write_text(probe, JAI_PROBE)
    exe = os.path.join(probe_dir, "probe.exe")

    print(f"[jai] jaic = {jaic}")
    proc = subprocess.run([jaic, "probe.jai", "-exe", "probe.exe"],
                          cwd=probe_dir, capture_output=True, text=True, timeout=180)
    if proc.returncode != 0 or not os.path.exists(exe):
        print(f"{RED}[jai]{OFF} probe did not build:")
        print(proc.stdout[-3000:] + proc.stderr[-3000:])
        return False

    run = subprocess.run([exe], capture_output=True, text=True, timeout=60)
    embedded = {}
    for line in run.stdout.splitlines():
        parts = line.split(" ")
        if len(parts) == 3 and parts[0] in ("CANON", "REF"):
            embedded[parts[1]] = int(parts[2])

    problems = []
    if len(embedded) != 12:
        problems.append(f"probe reported {len(embedded)} entries, expected 12")
    for name, got in sorted(embedded.items()):
        entry = name[len("reference/"):] if name.startswith("reference/") else name
        variant, stage = entry.lower().split(".")
        path = ref_path(variant, stage) if name.startswith("reference/") else canon_path(variant, stage)
        want = os.path.getsize(path)
        if got != want:
            problems.append(f"{name}: Jai embeds {got} bytes, file has {want}")

    # the same file must also survive a wasm-target check (that is the only
    # target the table is compiled for in a real build)
    wasm = subprocess.run([jaic, "-os", "wasm", "-check", "-msvc_format", "probe.jai"],
                          cwd=probe_dir, capture_output=True, text=True, timeout=180)
    wasm_ok = wasm.returncode == 0
    if not wasm_ok:
        problems.append("-os wasm -check failed:\n" + (wasm.stdout + wasm.stderr)[-2000:])

    if problems:
        print(f"{RED}[jai]{OFF} FAIL")
        for p in problems:
            print("  - " + p)
        return False
    print(f"[jai] {len(embedded)} sources embedded with the same byte counts as the files")
    print(f"[jai] internal/web/web_shader_source.jai passes `jaic -os wasm -check`")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="verify only; fail if internal/web/shaders/reference/ is stale")
    ap.add_argument("--gen-only", action="store_true", help="regenerate reference/, skip the browser")
    ap.add_argument("--keep-page", action="store_true", help="keep .test_tmp/glsl_verify.html")
    ap.add_argument("--gpu", action="store_true",
                    help="use the real GPU (ANGLE/D3D11, Metal, ...) instead of SwiftShader")
    args = ap.parse_args()

    shadercross, spirv_cross = locate_generators()
    have_gen = bool(shadercross and spirv_cross)

    if not args.check:
        if not have_gen:
            print(f"{YEL}[gen]{OFF} shadercross and/or spirv-cross not found - "
                  f"skipping regeneration of internal/web/shaders/reference/")
            print(f"{YEL}[gen]{OFF} (set SHADERCROSS= / SPIRV_CROSS= to enable it)")
        else:
            print(f"[gen] shadercross = {shadercross}")
            print(f"[gen] spirv-cross = {spirv_cross}")
            generated = generate_reference(shadercross, spirv_cross)
            wrote = 0
            for name, content in generated.items():
                path = os.path.join(REF_DIR, name)
                old = read_text(path) if os.path.exists(path) else None
                if old == content:
                    print(f"[gen]   {name:<24} unchanged")
                else:
                    write_text(path, content)
                    print(f"[gen]   {name:<24} {'rewritten' if old else 'created'}")
                    wrote += 1
            print(f"[gen] {wrote} file(s) written, {len(generated) - wrote} already up to date")

    if args.check and have_gen:
        generated = generate_reference(shadercross, spirv_cross)
        stale = []
        for name, content in generated.items():
            path = os.path.join(REF_DIR, name)
            if not os.path.exists(path) or read_text(path) != content:
                stale.append(name)
        if stale:
            print(f"{RED}[check]{OFF} reference/ is stale: {', '.join(stale)}")
            print(f"{RED}[check]{OFF} run: python tools/build_glsl_es.py")
            return 1
        print(f"[check] reference/ matches a fresh lowering of content/shaders/*.hlsl")

    shaders, missing = collect_sources()
    if missing:
        print(f"{RED}[verify]{OFF} missing shader sources: {', '.join(missing)}")
        return 1

    if args.gen_only:
        print(f"[gen] {len(shaders)} shader sources present; skipping the WebGL2 check")
        return 0

    backend = "GPU (ANGLE)" if args.gpu else "SwiftShader"
    print(f"[verify] driving a real WebGL2 context [{backend}] ({len(shaders)} sources)...")
    report = run_harness(build_harness(shaders), keep=args.keep_page, swiftshader=not args.gpu)
    ok, _ = print_report(report)
    jai_ok = check_jai_embed()
    return 0 if (ok and jai_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
