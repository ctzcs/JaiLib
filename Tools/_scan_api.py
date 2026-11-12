"""预扫描 kit/tools/*（默认 shader_lab）里可能 unknown-identifier 的名字，缩小 jaic 逐条报错的排查量。

1) 裸调用名（`foo(`）不在 self 声明 + 各导入模块声明里 → 可疑。
2) 命名空间成员（`NS.member`）不在该模块声明里 → 可疑。

stdlib 用 `jaic -print_stdlib` 那一份（jacket），不是 RefProject 里的官方 modules。
"""
import os, re, sys

ROOT = r"D:\MySpace\Github\JaiLib"
GH = r"D:\MySpace\Github"
STD = r"D:\Lib\jacket-windows-x64\stdlib"

TARGET = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "kit", "tools", "shader_lab")

NS = {
    "STRING": [os.path.join(STD, "String"), os.path.join(STD, "internal", "string")],
    "JM": [os.path.join(STD, "Math")],
    "FILE": [os.path.join(STD, "File")],
    "FU": [os.path.join(STD, "File_Utilities")],
    "HASH": [os.path.join(STD, "Hash_Table"), os.path.join(STD, "internal", "collections")],
    "F": [os.path.join(GH, "jfoster")],
    "sh": [os.path.join(ROOT, "kit", "rendering", "shader")],
    "dev": [os.path.join(ROOT, "kit", "rendering", "shader", "dev")],
    "mat": [os.path.join(ROOT, "kit", "rendering", "material")],
    "r2d": [os.path.join(ROOT, "kit", "rendering", "2d")],
    "r3d": [os.path.join(ROOT, "kit", "rendering", "3d")],
    "W": [os.path.join(ROOT, "kit", "world")],
    "DA": [os.path.join(ROOT, "core", "dasset")],
    "ImGui": [os.path.join(STD, "ImGui")],
    "IMGF": [os.path.join(ROOT, "thirdparty", "imgui_foster.jai")],
}
BARE_SOURCES = ["Basic", "String", "Math", "File", "File_Utilities", "Hash_Table", "ImGui"]

def files_of(paths):
    out = []
    for p in paths:
        if os.path.isfile(p):
            out.append(p)
        elif os.path.isdir(p):
            for dp, _, fns in os.walk(p):
                out += [os.path.join(dp, f) for f in fns if f.endswith(".jai")]
    return out

DECL = re.compile(r"^\s*(?:using\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*::", re.M)
DECL_ALIAS = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*[^:]", re.M)
FIELD = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", re.M)

def gather(paths):
    names = set()
    for f in files_of(paths):
        txt = open(f, encoding="utf-8", errors="replace").read()
        names |= set(DECL.findall(txt))
        names |= set(DECL_ALIAS.findall(txt))
        names |= set(FIELD.findall(txt))
        for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*::\s*([A-Za-z_][A-Za-z0-9_.]*)", txt):
            names.add(m.group(1))
    return names

decls = {}
for ns, paths in NS.items():
    missing = [p for p in paths if not os.path.exists(p)]
    if missing:
        print("!! %s: missing %s" % (ns, missing), file=sys.stderr)
        continue
    decls[ns] = gather(paths)

selfnames = gather([TARGET]) | gather([os.path.join(STD, m) for m in BARE_SOURCES])
if os.path.isdir(os.path.join(STD, "internal")):
    selfnames |= gather([os.path.join(STD, "internal", "collections"),
                         os.path.join(STD, "internal", "string"),
                         os.path.join(STD, "internal", "basic")])

KEYWORDS = set("""if else while for do return defer cast it size_of type_of is_constant
inline no_inline expand_insert code_of string constants array data struct enum union
push_use push_context use switch case default break continue auto_cast void_all
insert load delete align_of any_of same_as type_info module main assert print
sizeof typeof offset_of interface new""".split())

CALL = re.compile(r"(?<![A-Za-z0-9_.])([a-z_][A-Za-z0-9_]*)\s*\(")
MEM = re.compile(r"(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)")

bare, mem = {}, {}
for f in files_of([TARGET]):
    txt = re.sub(r"/\*.*?\*/", "", open(f, encoding="utf-8", errors="replace").read(), flags=re.S)
    for i, line in enumerate(txt.splitlines(), 1):
        line = re.sub(r"//.*", "", line)
        for m in CALL.finditer(line):
            n = m.group(1)
            if n in selfnames or n in KEYWORDS:
                continue
            bare.setdefault(n, []).append("%s:%d" % (os.path.basename(f), i))
        for m in MEM.finditer(line):
            ns, member = m.group(1), m.group(2)
            if ns not in decls or member in decls[ns]:
                continue
            mem.setdefault("%s.%s" % (ns, member), []).append("%s:%d" % (os.path.basename(f), i))

if bare:
    print("== bare calls not declared anywhere we scanned ==")
    for k in sorted(bare):
        v = bare[k]
        print("  %-34s %s" % (k, ", ".join(v[:5]) + (" …(%d)" % len(v) if len(v) > 5 else "")))
if mem:
    print("== namespaced members missing from their module ==")
    for k in sorted(mem):
        v = mem[k]
        print("  %-34s %s" % (k, ", ".join(v[:5]) + (" …(%d)" % len(v) if len(v) > 5 else "")))
print("--- %d bare, %d member suspects" % (len(bare), len(mem)), file=sys.stderr)
