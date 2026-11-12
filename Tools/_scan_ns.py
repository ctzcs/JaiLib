"""扫描 kit/tools/* 里的 `NS.member(...)` 调用，逐个核对 member 是否在该模块里声明过。
配合 jaic 一次只报一个 error 的节奏，用来一次找出整批 unknown-identifier。"""
import os, re, sys

ROOT = r"D:\MySpace\Github\JaiLib"
GH = r"D:\MySpace\Github"
STD = r"D:\MySpace\RefProject\jai\jai\modules"

TARGET = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "kit", "tools", "shader_lab")

NS = {
    "STRING": os.path.join(STD, "String"),
    "JM": os.path.join(STD, "Math"),
    "FILE": os.path.join(STD, "File"),
    "FU": os.path.join(STD, "File_Utilities"),
    "HASH": os.path.join(STD, "Hash_Table.jai"),
    "F": os.path.join(GH, "jfoster"),
    "sh": os.path.join(ROOT, "kit", "rendering", "shader"),
    "dev": os.path.join(ROOT, "kit", "rendering", "shader", "dev"),
    "mat": os.path.join(ROOT, "kit", "rendering", "material"),
    "r2d": os.path.join(ROOT, "kit", "rendering", "2d"),
    "r3d": os.path.join(ROOT, "kit", "rendering", "3d"),
    "W": os.path.join(ROOT, "kit", "world"),
    "DA": os.path.join(ROOT, "core", "dasset"),
    "IMGF": os.path.join(ROOT, "thirdparty", "imgui_foster"),
    "ImGui": os.path.join(ROOT, "thirdparty", "imgui"),
}

def gather(path):
    names, files = set(), []
    if os.path.isfile(path):
        files = [path]
    else:
        for dp, _, fns in os.walk(path):
            files += [os.path.join(dp, f) for f in fns if f.endswith(".jai")]
    for f in files:
        txt = open(f, encoding="utf-8", errors="replace").read()
        for m in re.finditer(r"^\s*(?:using\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*::", txt, re.M):
            names.add(m.group(1))
        for m in re.finditer(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*[^:=]", txt, re.M):
            names.add(m.group(1))
    return names

decls = {}
for ns, path in NS.items():
    if not os.path.exists(path):
        print("!! missing module dir for %s: %s" % (ns, path), file=sys.stderr)
        continue
    decls[ns] = gather(path)

# also self declarations (concat all target files)
selfnames = set()
for dp, _, fns in os.walk(TARGET):
    for fn in fns:
        if fn.endswith(".jai") and fn != "module.jai":
            txt = open(os.path.join(dp, fn), encoding="utf-8", errors="replace").read()
            for m in re.finditer(r"^\s*(?:using\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*::", txt, re.M):
                selfnames.add(m.group(1))

pat = re.compile(r"(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)")
bad = {}
for dp, _, fns in os.walk(TARGET):
    for fn in sorted(fns):
        if not fn.endswith(".jai"):
            continue
        path = os.path.join(dp, fn)
        txt = open(path, encoding="utf-8", errors="replace").read()
        txt = re.sub(r"/\*.*?\*/", "", txt, flags=re.S)
        for i, line in enumerate(txt.splitlines(), 1):
            line = re.sub(r"//.*", "", line)
            for m in pat.finditer(line):
                ns, member = m.group(1), m.group(2)
                if ns not in decls:
                    continue
                if member in decls[ns]:
                    continue
                bad.setdefault("%s.%s" % (ns, member), []).append(
                    "%s:%d" % (os.path.basename(path), i))
for k in sorted(bad):
    v = bad[k]
    print("%-40s %s" % (k, ", ".join(v[:5]) + (" …(%d)" % len(v) if len(v) > 5 else "")))
print("--- %d missing ns members" % len(bad), file=sys.stderr)
