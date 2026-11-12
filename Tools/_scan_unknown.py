"""粗糙的 unknown-identifier 预扫描：收集 kit/tools/shader_lab 里的调用名，扣掉在
相关模块（jfoster / kit / core / thirdparty / Jai stdlib）里声明过的名字，输出可疑清单。

只用于缩小 jaic 一次只报一个 error 的排查范围；不是编译器。
"""
import os, re, sys

ROOT = r"D:\MySpace\Github\JaiLib"
GH = r"D:\MySpace\Github"
STD = r"D:\MySpace\RefProject\jai\jai\modules"

TARGET_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "kit", "tools", "shader_lab")

DECL_MODULE_DIRS = [
    os.path.join(GH, "jfoster"),
    os.path.join(ROOT, "kit"),
    os.path.join(ROOT, "core"),
    os.path.join(ROOT, "thirdparty"),
    os.path.join(STD, "Basic"),
    os.path.join(STD, "String"),
    os.path.join(STD, "Math"),
    os.path.join(STD, "File"),
    os.path.join(STD, "File_Utilities"),
    os.path.join(STD, "Hash_Table"),
    os.path.join(STD, "ImGui"),
    os.path.join(STD, "Sort"),
    os.path.join(STD, "Atomics"),
    os.path.join(STD, "Bucket_Array"),
]

decl = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*::")
call = re.compile(r"(?<![A-Za-z0-9_.])([a-z_][A-Za-z0-9_]*)\s*\(")

declared = set()
for d in DECL_MODULE_DIRS:
    for dp, _, fns in os.walk(d):
        for fn in fns:
            if not fn.endswith(".jai"):
                continue
            try:
                txt = open(os.path.join(dp, fn), encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for line in txt.splitlines():
                m = decl.match(line)
                if m:
                    declared.add(m.group(1))

# also pick up `name :: (` inline after `;`
for d in DECL_MODULE_DIRS:
    for dp, _, fns in os.walk(d):
        for fn in fns:
            if not fn.endswith(".jai"):
                continue
            txt = open(os.path.join(dp, fn), encoding="utf-8", errors="replace").read()
            for m in re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)\s*::\s*[\(\w]", txt):
                declared.add(m.group(1))

KEYWORDS = set("""if else while for do return defer cast it size_of type_of is_constant
inline no_inline expand_insert code_of code_typestr string constants array data struct enum union
push_use push_context use switch case default break continue then auto_cast void_all
insert load new delete sizeof align_of any_of same_as type_info module
""".split())

suspects = {}
for dp, _, fns in os.walk(TARGET_DIR):
    for fn in sorted(fns):
        if not fn.endswith(".jai"):
            continue
        path = os.path.join(dp, fn)
        txt = open(path, encoding="utf-8", errors="replace").read()
        if re.search(r"\*/\s*$", txt):
            pass
        # strip block comments
        stripped = re.sub(r"/\*.*?\*/", "", txt, flags=re.S)
        for i, line in enumerate(stripped.splitlines(), 1):
            if line.strip().startswith("//"):
                continue
            line = re.sub(r"//.*", "", line)
            for m in call.finditer(line):
                name = m.group(1)
                if name in declared or name in KEYWORDS:
                    continue
                suspects.setdefault(name, []).append(
                    "%s:%d" % (os.path.relpath(path, ROOT), i))

for name in sorted(suspects):
    hits = suspects[name]
    print("%-32s %s" % (name, ", ".join(hits[:4]) + (" …(%d)" % len(hits) if len(hits) > 4 else "")))
print("--- %d suspects" % len(suspects), file=sys.stderr)
