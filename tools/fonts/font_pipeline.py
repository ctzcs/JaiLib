"""显式字符来源、顺序 fallback、确定性子集与离线 MSDF 批次校验；不扫描源码。"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib


# //@region 字符来源与子集

class FontError(ValueError):
	"""输入、工具或产物不符合离线字体契约。"""


def sha256(path):
	return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def json_bytes(value):
	return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2,
		allow_nan=False) + "\n").encode("utf-8")


def read_json(path):
	def unique(pairs):
		result = {}
		for key, value in pairs:
			if key in result:
				raise FontError(f"重复 JSON key: {key}")
			result[key] = value
		return result

	def invalid_constant(value):
		raise FontError(f"非标准 JSON 数值: {value}")

	return json.loads(Path(path).read_text(encoding="utf-8-sig"),
		object_pairs_hook=unique, parse_constant=invalid_constant)


def scalar(cp):
	if type(cp) is not int or not 0 <= cp <= 0x10FFFF or 0xD800 <= cp <= 0xDFFF:
		raise FontError(f"非法 Unicode scalar: {cp!r}")
	return cp


def canonical_codepoints(codepoints):
	result = sorted({scalar(cp) for cp in codepoints})
	if not result:
		raise FontError("字符集为空")
	return result


def collect_codepoints(chars=(), text_files=(), codepoint_files=(), json_files=()):
	"""返回排序去重码点及来源记录。JSON 只读字符串值，不读 key/数字；不解析语言源码。"""
	points = set()
	sources = []

	def text(value):
		# 文本排版控制符不作为字形请求；其他字符（包括空格）原样保留，不做 NFC。
		points.update(ord(ch) for ch in value if ch not in "\r\n\t")

	def strings(value):
		if isinstance(value, str):
			text(value)
		elif isinstance(value, list):
			for child in value:
				strings(child)
		elif isinstance(value, dict):
			for child in value.values():
				strings(child)

	for value in chars:
		text(value)
		sources.append({"kind": "literal", "text": value})
	for kind, paths in (("text", text_files), ("codepoints", codepoint_files),
		("json-values", json_files)):
		for name in paths:
			path = Path(name)
			content = path.read_text(encoding="utf-8-sig")
			if kind == "text":
				text(content)
			elif kind == "json-values":
				strings(read_json(path))
			else:
				for line in content.splitlines():
					for token in line.split("#", 1)[0].split():
						if not re.fullmatch(r"(?:U\+|0[xX])[0-9A-Fa-f]{1,6}", token):
							raise FontError(f"{path}: 码点须为 U+XXXX 或 0xXXXX: {token}")
						points.add(scalar(int(token[2:], 16)))
			sources.append({"kind": kind, "path": str(path), "sha256": sha256(path)})
	return canonical_codepoints(points), sources


def font_coverage(path):
	from fontTools.ttLib import TTFont

	with TTFont(path, recalcTimestamp=False) as font:
		if font.flavor or "fvar" in font:
			raise FontError(f"{path}: 只支持静态 TTF/OTF；可变字体须先实例化目标轴值")
		return {cp for cp, glyph in (font.getBestCmap() or {}).items()
			if font.getGlyphID(glyph) != 0}


def assign_fallback(codepoints, coverages):
	"""每个码点仅分配给第一个覆盖它的字体；不生成跨字体 kerning。"""
	remaining = set(canonical_codepoints(codepoints))
	assigned = []
	for coverage in coverages:
		owned = remaining.intersection(coverage)
		assigned.append(sorted(owned))
		remaining.difference_update(owned)
	if remaining:
		raise FontError("缺字: " + " ".join(f"U+{cp:04X}" for cp in sorted(remaining)))
	return assigned


def save_subset(source, output, codepoints):
	"""与 ImGui 共用：无 hint/塑形，保留所有 name ID（默认语言集）及 head.modified。"""
	from fontTools import subset
	from fontTools.ttLib import TTFont

	if Path(source).resolve() == Path(output).resolve():
		raise FontError("子集不能覆盖源字体")
	points = canonical_codepoints(codepoints)
	assign_fallback(points, [font_coverage(source)])
	options = subset.Options()
	options.layout_features = []
	options.hinting = False
	options.name_IDs = ["*"]
	with TTFont(source, recalcTimestamp=False) as font:
		subsetter = subset.Subsetter(options)
		subsetter.populate(unicodes=points)
		subsetter.subset(font)
		Path(output).parent.mkdir(parents=True, exist_ok=True)
		font.save(output)
	# 保留 ImGui 既有 bidi/glyph closure；可能多出镜像 cmap，MSDF 另用显式 charset 限定。
	if set(points) - font_coverage(output):
		raise FontError(f"子集 cmap 缺少请求字形: {output}")

# //@endregion

# //@region MSDF JSON 归一

def number(value, name, positive=False):
	if type(value) not in (int, float) or not math.isfinite(value):
		raise FontError(f"{name}: 需要有限数值")
	if positive and value <= 0:
		raise FontError(f"{name}: 必须大于零")
	return value


def bounds(value, name, scale=1):
	if not isinstance(value, dict):
		raise FontError(f"{name}: 缺少边界")
	result = {key: number(value.get(key), f"{name}.{key}") / scale
		for key in ("left", "top", "right", "bottom")}
	if result["left"] >= result["right"] or result["top"] >= result["bottom"]:
		raise FontError(f"{name}: 非正面积或非 top-origin 边界")
	return result


def normalize_msdf(data, assignments=None):
	"""flat/variants -> Foster flat JSON；各 variant 的 em 归一为 1，合并行度量包络。"""
	if not isinstance(data, dict) or not isinstance(data.get("atlas"), dict):
		raise FontError("缺少 atlas")
	atlas = data["atlas"]
	if atlas.get("type") != "msdf" or atlas.get("yOrigin") != "top":
		raise FontError("必须为 msdf / top-origin")
	if number(atlas.get("distanceRangeMiddle", 0), "distanceRangeMiddle") != 0:
		raise FontError("只支持对称距离范围")
	for key in ("width", "height"):
		if type(atlas.get(key)) is not int or atlas[key] <= 0:
			raise FontError(f"atlas.{key}: 需要正整数")
	result_atlas = {key: atlas[key] for key in ("type", "yOrigin", "width", "height")}
	for key in ("size", "distanceRange"):
		result_atlas[key] = number(atlas.get(key), f"atlas.{key}", positive=True)
	result_atlas["distanceRangeMiddle"] = 0
	variants = data.get("variants", [data])
	if not isinstance(variants, list) or not variants:
		raise FontError("variants 为空或不是数组")
	if "variants" in data and any(key in data for key in ("metrics", "glyphs", "kerning")):
		raise FontError("不能混用 flat 与 variants")
	if assignments is not None and len(variants) != len(assignments):
		raise FontError("variant 数量与非空字体子集不一致")
	glyphs = {}
	kernings = {}
	all_metrics = []
	for index, variant in enumerate(variants):
		if not isinstance(variant, dict) or not isinstance(variant.get("metrics"), dict):
			raise FontError("variant 缺少 metrics")
		metrics = variant["metrics"]
		em = number(metrics.get("emSize"), "emSize", positive=True)
		metric = {key: number(metrics.get(key), key) / em for key in
			("lineHeight", "ascender", "descender", "underlineY", "underlineThickness")}
		if (metric["lineHeight"] <= 0 or metric["ascender"] > 0 or
			metric["descender"] < 0 or metric["underlineThickness"] < 0):
			raise FontError("非法 top-origin metrics")
		all_metrics.append(metric)
		items = variant.get("glyphs")
		if not isinstance(items, list) or not items:
			raise FontError("缺少 glyphs")
		owned = set()
		for item in items:
			if not isinstance(item, dict):
				raise FontError("非法 glyph")
			cp = scalar(item.get("unicode"))
			if cp in glyphs:
				raise FontError(f"重复字形 U+{cp:04X}")
			owned.add(cp)
			glyph = {"unicode": cp, "advance": number(item.get("advance"), "advance") / em}
			if ("planeBounds" in item) != ("atlasBounds" in item):
				raise FontError("planeBounds/atlasBounds 必须同时存在")
			if "planeBounds" in item:
				glyph["planeBounds"] = bounds(item["planeBounds"], "planeBounds", em)
				box = bounds(item["atlasBounds"], "atlasBounds")
				if (box["left"] < 0 or box["top"] < 0 or
					box["right"] > atlas["width"] or box["bottom"] > atlas["height"]):
					raise FontError("字形边界超出图集")
				glyph["atlasBounds"] = box
			glyphs[cp] = glyph
		if assignments is not None and owned != set(assignments[index]):
			raise FontError(f"variant {index}: 字形与请求不一致（缺字或额外字形）")
		pairs = variant.get("kerning", [])
		if not isinstance(pairs, list):
			raise FontError("kerning 不是数组")
		for pair in pairs:
			if not isinstance(pair, dict):
				raise FontError("非法 kerning")
			key = (scalar(pair.get("unicode1")), scalar(pair.get("unicode2")))
			if any(cp not in owned for cp in key) or key in kernings:
				raise FontError("kerning 引用了其他字体/缺失字形，或重复字距")
			kernings[key] = {"unicode1": key[0], "unicode2": key[1],
				"advance": number(pair.get("advance"), "kerning.advance") / em}
	metric = dict(all_metrics[0])
	metric["emSize"] = 1
	metric["ascender"] = min(m["ascender"] for m in all_metrics)
	metric["descender"] = max(m["descender"] for m in all_metrics)
	metric["lineHeight"] = max(metric["descender"] - metric["ascender"],
		*(m["lineHeight"] for m in all_metrics))
	return {"atlas": result_atlas, "metrics": metric,
		"glyphs": [glyphs[cp] for cp in sorted(glyphs)],
		"kerning": [kernings[key] for key in sorted(kernings)]}

# //@endregion

# //@region PNG 与批次校验

def validate_png(path, width, height):
	"""仅接受无色彩变换元数据的 8-bit RGB PNG；解滤波后检查 RGB 两两不相同。"""
	data = Path(path).read_bytes()
	if not data.startswith(b"\x89PNG\r\n\x1a\n"):
		raise FontError("不是 PNG")
	offset = 8
	compressed = bytearray()
	seen_header = False
	seen_end = False
	idat_ended = False
	seen_idat = False
	while offset < len(data):
		if offset + 12 > len(data):
			raise FontError("PNG chunk 截断")
		length = struct.unpack_from(">I", data, offset)[0]
		kind = data[offset + 4:offset + 8]
		end = offset + 12 + length
		if end > len(data):
			raise FontError("PNG payload 截断")
		payload = data[offset + 8:end - 4]
		if zlib.crc32(kind + payload) != struct.unpack_from(">I", data, end - 4)[0]:
			raise FontError("PNG CRC 不符")
		if not seen_header and kind != b"IHDR":
			raise FontError("PNG 首个 chunk 必须为 IHDR")
		if kind == b"IHDR":
			if seen_header or length != 13:
				raise FontError("非法 IHDR")
			w, h, depth, color, comp, filt, interlace = struct.unpack(">IIBBBBB", payload)
			if (w, h) != (width, height) or (depth, color, comp, filt, interlace) != (8, 2, 0, 0, 0):
				raise FontError("PNG 必须与 JSON 同尺寸，8-bit RGB、非交错、无 alpha（不预乘）")
			seen_header = True
		elif kind == b"IDAT":
			if idat_ended:
				raise FontError("PNG IDAT 不连续")
			seen_idat = True
			compressed.extend(payload)
		elif kind == b"IEND":
			if length or end != len(data):
				raise FontError("非法 IEND 或尾随数据")
			seen_end = True
		elif kind in (b"sRGB", b"iCCP", b"gAMA", b"tRNS"):
			raise FontError("距离场不允许色彩变换或透明度元数据")
		elif kind[0] & 32 == 0 and kind != b"PLTE":
			raise FontError(f"未知 PNG critical chunk: {kind!r}")
		if seen_idat and kind != b"IDAT":
			idat_ended = True
		offset = end
	if not seen_header or not seen_end or not seen_idat:
		raise FontError("PNG 缺少 IHDR/IDAT/IEND")
	stride = width * 3
	expected = (stride + 1) * height
	if expected > 256 * 1024 * 1024:
		raise FontError("PNG 解码上限为 256 MiB")
	decoder = zlib.decompressobj()
	try:
		raw = decoder.decompress(compressed, expected + 1)
	except zlib.error as error:
		raise FontError(f"PNG zlib 失败: {error}") from error
	if len(raw) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
		raise FontError("PNG 解压长度/流结尾不符")
	previous = bytearray(stride)
	different = [False, False, False]
	for y in range(height):
		start = y * (stride + 1)
		method = raw[start]
		if method > 4:
			raise FontError("未知 PNG filter")
		row = bytearray(raw[start + 1:start + 1 + stride])
		for x in range(stride):
			a = row[x - 3] if x >= 3 else 0
			b = previous[x]
			c = previous[x - 3] if x >= 3 else 0
			predictor = 0
			if method == 1:
				predictor = a
			elif method == 2:
				predictor = b
			elif method == 3:
				predictor = (a + b) // 2
			elif method == 4:
				p = a + b - c
				distances = (abs(p - a), abs(p - b), abs(p - c))
				predictor = (a, b, c)[distances.index(min(distances))]
			row[x] = (row[x] + predictor) & 255
		for x in range(0, stride, 3):
			r, g, b = row[x:x + 3]
			different[0] |= r != g
			different[1] |= r != b
			different[2] |= g != b
		previous = row
	if not all(different):
		raise FontError("RGB 通道退化为相同距离信息；不是可验收的多通道 MSDF")


def validate_pair(data, png, assignments=None):
	result = normalize_msdf(data, assignments)
	validate_png(png, result["atlas"]["width"], result["atlas"]["height"])
	return result


def batch_id(artifacts):
	return hashlib.sha256(json_bytes(artifacts)).hexdigest()


def validate_batch(directory):
	"""校验 provenance 中全部文件 hash、同批 raw/flat JSON、字符分配及 RGB PNG。"""
	root = Path(directory)
	record = read_json(root / "provenance.json")
	if not isinstance(record, dict) or record.get("schema") != 1:
		raise FontError("未知 provenance schema")
	artifacts = record.get("artifacts")
	if not isinstance(artifacts, dict) or not artifacts:
		raise FontError("provenance 缺少 artifacts")
	for name in ("font.json", "font.png", "generator.json"):
		if name not in artifacts:
			raise FontError(f"provenance 缺少 {name}")
	for name, digest in artifacts.items():
		if not isinstance(name, str) or Path(name).name != name or "/" in name or "\\" in name:
			raise FontError("非法 artifact 文件名")
		path = root / name
		if path.is_symlink() or not path.is_file() or sha256(path) != digest:
			raise FontError(f"批次 hash 不符: {name}")
	if record.get("batch_id") != batch_id(artifacts):
		raise FontError("批次 ID 不符")
	assignments = record.get("assignments")
	if not isinstance(assignments, list) or not assignments:
		raise FontError("provenance 缺少 assignments")
	if any(not isinstance(group, list) or group != canonical_codepoints(group)
		for group in assignments):
		raise FontError("assignments 须为非空、排序去重的码点数组")
	points = canonical_codepoints(cp for group in assignments for cp in group)
	if sum(map(len, assignments)) != len(points):
		raise FontError("fallback 分配包含重复码点")
	fonts = record.get("fonts")
	if not isinstance(fonts, list) or not fonts:
		raise FontError("provenance 缺少 fonts/许可")
	active = []
	for index, info in enumerate(fonts):
		if not isinstance(info, dict) or not isinstance(info.get("license"), dict):
			raise FontError("provenance 字体/许可记录不完整")
		license_info = info["license"]
		license_name = f"license-{index:03d}.txt"
		if (license_info.get("copy") != license_name or license_name not in artifacts or
			license_info.get("sha256") != artifacts[license_name]):
			raise FontError("许可副本与来源 hash 不符")
		owned = info.get("codepoints")
		if not isinstance(owned, list):
			raise FontError("字体缺少 codepoints")
		if owned:
			active.append(owned)
			if info.get("subset") not in artifacts or info.get("charset") not in artifacts:
				raise FontError("字体缺少子集/charset 文件")
	if active != assignments:
		raise FontError("字体顺序与 fallback 分配不一致")
	if points != record.get("codepoints"):
		raise FontError("provenance 字符清单不一致")
	flat = validate_pair(read_json(root / "generator.json"), root / "font.png", assignments)
	if flat != read_json(root / "font.json"):
		raise FontError("归一 JSON 与同批 generator JSON 不一致")
	return record

# //@endregion

# //@region 构建、发布与 CLI

def build(codepoints, fonts, output_root, temp_root, generator, tool_version,
		sources=(), size=48, pxrange=8, seed=0, timeout=300):
	"""fonts 为有序 (字体, 许可) 对；只发布新目录，失败不改变已有输出。返回 provenance。"""
	points = canonical_codepoints(codepoints)
	number(size, "size", positive=True)
	number(pxrange, "pxrange", positive=True)
	number(timeout, "timeout", positive=True)
	if type(seed) is not int or not 0 <= seed <= 0x7FFFFFFF:
		raise FontError("seed 必须为 0..2147483647 整数")
	if not tool_version or not tool_version.strip():
		raise FontError("必须显式记录生成器版本标签")
	output = Path(output_root).resolve()
	temporary = Path(temp_root).resolve()
	if output.exists():
		raise FontError(f"输出目录已存在；请使用新目录，不覆盖正式资产: {output}")
	if temporary == output or output in temporary.parents or temporary in output.parents:
		raise FontError("输出根与临时根不能相同或互相包含")
	font_inputs = [(Path(font), Path(license_path)) for font, license_path in fonts]
	if not font_inputs:
		raise FontError("至少需要一个字体及其许可证")
	for font, license_path in font_inputs:
		if font.suffix.lower() not in (".ttf", ".otf"):
			raise FontError(f"需要静态 .ttf/.otf: {font}")
		for path in (font, license_path):
			if not path.is_file() or not path.stat().st_size:
				raise FontError(f"输入文件不存在或为空: {path}")
			if output == path.resolve() or output in path.resolve().parents:
				raise FontError("输出不能包含输入文件")
	tool = shutil.which(str(generator))
	if tool is None or not Path(tool).is_file():
		raise FontError(f"找不到生成器: {generator}")
	tool = str(Path(tool).resolve())
	assigned = assign_fallback(points, [font_coverage(font) for font, _ in font_inputs])
	temporary.mkdir(parents=True, exist_ok=True)
	with tempfile.TemporaryDirectory(prefix="olib-fonts-", dir=temporary) as work_name:
		work = Path(work_name)
		font_records = []
		active = []
		font_arguments = []
		for index, ((font, license_path), owned) in enumerate(zip(font_inputs, assigned)):
			license_name = f"license-{index:03d}.txt"
			shutil.copyfile(license_path, work / license_name)
			info = {"path": str(font), "sha256": sha256(font), "codepoints": owned,
				"license": {"path": str(license_path), "sha256": sha256(license_path),
					"copy": license_name}}
			if owned:
				subset_name = f"subset-{index:03d}{font.suffix.lower()}"
				charset_name = f"charset-{index:03d}.txt"
				save_subset(font, work / subset_name, owned)
				(work / charset_name).write_bytes(
					("\n".join(f"0x{cp:04X}" for cp in owned) + "\n").encode("ascii"))
				info["subset"] = subset_name
				info["charset"] = charset_name
				if active:
					font_arguments.append("-and")
				font_arguments.extend(["-font", subset_name, "-charset", charset_name])
				active.append(owned)
			font_records.append(info)
		command = [tool, "-type", "msdf", "-format", "png", "-size", str(size),
			"-pxrange", str(pxrange), "-yorigin", "top", "-seed", str(seed), "-threads", "1",
			*font_arguments, "-imageout", "font.png", "-json", "generator.json"]
		try:
			result = subprocess.run(command, cwd=work, capture_output=True, text=True,
				encoding="utf-8", errors="replace", timeout=timeout, check=False)
		except (OSError, subprocess.TimeoutExpired) as error:
			raise FontError(f"生成器启动/超时失败: {error}") from error
		if result.returncode:
			raise FontError(f"生成器退出 {result.returncode}:\n{result.stdout}\n{result.stderr}")
		for name in ("font.png", "generator.json"):
			path = work / name
			if path.is_symlink() or not path.is_file() or not path.stat().st_size:
				raise FontError(f"本批次生成器未输出 {name}")
		flat = validate_pair(read_json(work / "generator.json"), work / "font.png", active)
		if flat["atlas"]["size"] != size or flat["atlas"]["distanceRange"] != pxrange:
			raise FontError("生成器未遵循 size/pxrange 参数")
		(work / "font.json").write_bytes(json_bytes(flat))
		# 不保存耗时/绝对临时路径日志，避免 provenance 混入非确定性内容。
		import fontTools
		record = {"schema": 1, "codepoints": points, "assignments": active,
			"sources": list(sources), "fonts": font_records,
			"tool": {"path": tool, "sha256": sha256(tool), "version_label": tool_version,
				"version_label_source": "caller", "argv": command, "cwd": "<BATCH>",
				"timeout_seconds": timeout},
			"pipeline": {"sha256": sha256(__file__), "python": platform.python_version(),
				"fonttools": fontTools.__version__, "layout_features": [], "hinting": False,
				"name_IDs": ["*"], "recalcTimestamp": False},
			"sampling": {"y_origin": "top", "premultiplied": False, "color_space": "linear"}}
		record["artifacts"] = {path.name: sha256(path) for path in sorted(work.iterdir())}
		record["batch_id"] = batch_id(record["artifacts"])
		(work / "provenance.json").write_bytes(json_bytes(record))
		validate_batch(work)
		# 目标同卷暂存后整体 rename；输出目录须不存在。失败只清理本次拥有的目录。
		output.parent.mkdir(parents=True, exist_ok=True)
		with tempfile.TemporaryDirectory(prefix=".olib-fonts-publish-", dir=output.parent) as stage:
			staged = Path(stage) / "batch"
			shutil.copytree(work, staged)
			if output.exists():
				raise FontError(f"输出目录已出现，拒绝覆盖: {output}")
			staged.rename(output)
	return record


def main(argv=None):
	parser = argparse.ArgumentParser(description=__doc__)
	commands = parser.add_subparsers(dest="command", required=True)
	bake = commands.add_parser("build", help="生成新批次（不覆盖已有目录）")
	bake.add_argument("--font", type=Path, action="append", required=True,
		help="按 fallback 优先顺序重复，静态 TTF/OTF")
	bake.add_argument("--license", type=Path, action="append", required=True,
		help="与 --font 一一对应的许可文件")
	bake.add_argument("--chars", action="append", default=[])
	bake.add_argument("--text-file", type=Path, action="append", default=[])
	bake.add_argument("--codepoints-file", type=Path, action="append", default=[])
	bake.add_argument("--json-file", type=Path, action="append", default=[])
	bake.add_argument("--output-root", type=Path, required=True)
	bake.add_argument("--temp-root", type=Path, required=True)
	bake.add_argument("--generator", required=True, help="本地 msdf-atlas-gen 路径或 PATH 名称")
	bake.add_argument("--tool-version", required=True, help="调用者核实的版本标签，另记录二进制 hash")
	bake.add_argument("--size", type=float, default=48)
	bake.add_argument("--pxrange", type=float, default=8)
	bake.add_argument("--seed", type=int, default=0)
	bake.add_argument("--timeout", type=float, default=300)
	check = commands.add_parser("validate", help="复核完整批次及同批 hash")
	check.add_argument("directory", type=Path)
	args = parser.parse_args(argv)
	try:
		if args.command == "validate":
			record = validate_batch(args.directory)
		else:
			if len(args.font) != len(args.license):
				raise FontError("--font 与 --license 必须一一对应")
			points, sources = collect_codepoints(args.chars, args.text_file,
				args.codepoints_file, args.json_file)
			record = build(points, zip(args.font, args.license), args.output_root,
				args.temp_root, args.generator, args.tool_version, sources,
				args.size, args.pxrange, args.seed, args.timeout)
		print(f"OK {record['batch_id']}: {len(record['codepoints'])} codepoints")
		return 0
	except (FontError, OSError, ValueError, ImportError) as error:
		print(f"font pipeline: {error}", file=sys.stderr)
		return 1


if __name__ == "__main__":
	sys.exit(main())

# //@endregion
