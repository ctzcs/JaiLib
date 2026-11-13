"""标准库单元测试；字体后端和外部进程由受控替身提供，不依赖字体/工具安装。"""

import contextlib
import copy
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools" / "fonts"))
import font_pipeline as fp
import imgui_font


# //@region 自包含夹具

def chunk(kind, payload):
	return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))


def png(rows=None, filters=None, color=2, extra=b"", tail=b""):
	rows = rows or [bytes([10, 30, 60, 90, 120, 180])] * 2
	filters = filters or [0] * len(rows)
	raw = bytearray()
	previous = bytes(len(rows[0]))
	for row, method in zip(rows, filters):
		raw.append(method)
		for x, value in enumerate(row):
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
				d = (abs(p - a), abs(p - b), abs(p - c))
				predictor = (a, b, c)[d.index(min(d))]
			raw.append((value - predictor) & 255)
		previous = row
	header = struct.pack(">IIBBBBB", 2, len(rows), 8, color, 0, 0, 0)
	return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + extra +
		chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"") + tail)


def variant(points=(65, 86), em=1):
	return {"metrics": {"emSize": em, "lineHeight": 1.2 * em, "ascender": -.8 * em,
		"descender": .2 * em, "underlineY": .1 * em, "underlineThickness": .05 * em},
		"glyphs": [{"unicode": cp, "advance": .6 * em,
			"planeBounds": {"left": 0, "top": -.8 * em, "right": .5 * em, "bottom": .2 * em},
			"atlasBounds": {"left": 0, "top": 0, "right": 2, "bottom": 2}}
			for cp in points], "kerning": []}


def atlas(variants=None):
	result = {"atlas": {"type": "msdf", "yOrigin": "top", "width": 2, "height": 2,
		"size": 48, "distanceRange": 8, "distanceRangeMiddle": 0}}
	if variants is None:
		result.update(variant())
	else:
		result["variants"] = variants
	return result


class FakeFont:
	flavor = None

	def __init__(self, path, recalcTimestamp):
		if recalcTimestamp:
			raise AssertionError("必须保留 head.modified")
		self.data = json.loads(Path(path).read_bytes())

	def __enter__(self):
		return self

	def __exit__(self, *args):
		pass

	def __contains__(self, key):
		return key == "fvar" and self.data.get("variable", False)

	def getBestCmap(self):
		return {cp: str(cp) for cp in self.data["points"]} | {0: ".notdef"}

	def getGlyphID(self, glyph):
		return 0 if glyph == ".notdef" else int(glyph)

	def save(self, path):
		Path(path).write_bytes(fp.json_bytes(self.data))


class FakeSubsetter:
	def __init__(self, options):
		if options.layout_features != [] or options.hinting or options.name_IDs != ["*"]:
			raise AssertionError("子集选项不符")

	def populate(self, unicodes):
		self.points = unicodes

	def subset(self, font):
		font.data["points"] = sorted(set(self.points).intersection(font.data["points"]))


def backend():
	subset = types.SimpleNamespace(Options=types.SimpleNamespace, Subsetter=FakeSubsetter)
	return mock.patch.dict(sys.modules, {
		"fontTools": types.SimpleNamespace(subset=subset, __version__="fixture-1"),
		"fontTools.ttLib": types.SimpleNamespace(TTFont=FakeFont),
	})

# //@endregion

# //@region 字符、子集、度量

class InputsTests(unittest.TestCase):
	def test_explicit_sources(self):
		with tempfile.TemporaryDirectory(prefix="olib_fonts_test_") as directory:
			root = Path(directory)
			(root / "text.txt").write_text("中A\n\t", encoding="utf-8-sig")
			(root / "cp.txt").write_text("U+0020 0x1F642 # note\nU+0041\n", encoding="utf-8")
			(root / "loc.json").write_text('{"NotACharKey": ["文", 123, {"key": "B"}]}', encoding="utf-8")
			points, sources = fp.collect_codepoints(["AA\r\n"], [root / "text.txt"],
				[root / "cp.txt"], [root / "loc.json"])
			self.assertEqual(points, sorted(map(ord, " AB中文🙂")))
			self.assertEqual(len(sources), 4)
			self.assertEqual(sources[-1]["sha256"], fp.sha256(root / "loc.json"))
			(root / "cp.txt").write_text("[32, 126]", encoding="utf-8")
			with self.assertRaises(fp.FontError):
				fp.collect_codepoints(codepoint_files=[root / "cp.txt"])
			(root / "loc.json").write_text('{"a": "A", "a": "B"}', encoding="utf-8")
			with self.assertRaises(fp.FontError):
				fp.collect_codepoints(json_files=[root / "loc.json"])
			(root / "loc.json").write_text('{"a": NaN}', encoding="utf-8")
			with self.assertRaises(fp.FontError):
				fp.collect_codepoints(json_files=[root / "loc.json"])

	def test_scalar_and_fallback(self):
		self.assertEqual(fp.assign_fallback([86, 65, 65, 20013], [{65, 86}, {65, 20013}, {65}]),
			[[65, 86], [20013], []])
		with self.assertRaisesRegex(fp.FontError, "U\\+4E2D"):
			fp.assign_fallback([65, 20013], [{65}])
		for value in ([], [True], [-1], [0xD800], [0x110000]):
			with self.subTest(value=value), self.assertRaises(fp.FontError):
				fp.canonical_codepoints(value)

	def test_subset_contract_and_imgui_compatibility(self):
		with tempfile.TemporaryDirectory(prefix="olib_fonts_test_") as directory, backend():
			root = Path(directory)
			source = root / "input.ttf"
			source.write_bytes(fp.json_bytes({"points": [65, 66, 86], "modified": 123,
				"license": "fixture license"}))
			original = source.read_bytes()
			fp.save_subset(source, root / "a.ttf", [86, 65, 65])
			fp.save_subset(source, root / "b.ttf", [65, 86])
			self.assertEqual((root / "a.ttf").read_bytes(), (root / "b.ttf").read_bytes())
			self.assertEqual(fp.font_coverage(root / "a.ttf"), {65, 86})
			self.assertEqual(source.read_bytes(), original)
			with self.assertRaises(fp.FontError):
				fp.save_subset(source, root / "missing.ttf", [20013])
			self.assertFalse((root / "missing.ttf").exists())
			with self.assertRaises(fp.FontError):
				fp.save_subset(source, source, [65])
			self.assertEqual(source.read_bytes(), original)
			# fontTools 默认 bidi closure 可保留额外镜像码点；兼容旧 ImGui 子集。
			with mock.patch.object(fp, "font_coverage", return_value={65, 66, 86, 8715}):
				fp.save_subset(source, root / "closure.ttf", [65, 86])
		self.assertEqual(len(imgui_font.charset()), 7617)
		self.assertIs(imgui_font.save_subset, fp.save_subset)

	def test_variants_em_metrics_kerning(self):
		first = variant((86, 65), em=2)
		first["kerning"] = [{"unicode1": 65, "unicode2": 86, "advance": -.2}]
		second = variant((20013,))
		second["metrics"].update(ascender=-1.1, descender=.4, lineHeight=1.3)
		flat = fp.normalize_msdf(atlas([first, second]), [[65, 86], [20013]])
		self.assertEqual([g["unicode"] for g in flat["glyphs"]], [65, 86, 20013])
		self.assertEqual(flat["metrics"]["emSize"], 1)
		self.assertEqual(flat["metrics"]["ascender"], -1.1)
		self.assertAlmostEqual(flat["metrics"]["lineHeight"], 1.5)
		self.assertEqual(flat["metrics"]["underlineY"], .1)
		self.assertEqual(flat["glyphs"][0]["advance"], .6)
		self.assertEqual(flat["glyphs"][0]["planeBounds"]["top"], -.8)
		self.assertEqual(flat["glyphs"][0]["atlasBounds"]["right"], 2)
		self.assertEqual(flat["kerning"][0]["advance"], -.1)
		self.assertEqual(fp.normalize_msdf(flat), flat)

	def test_invalid_msdf(self):
		cases = []
		for key, value in (("type", "sdf"), ("yOrigin", "bottom"), ("distanceRange", 0),
			("distanceRangeMiddle", 1), ("width", True), ("size", float("nan"))):
			item = atlas()
			item["atlas"][key] = value
			cases.append(item)
		item = atlas()
		item["glyphs"].append(copy.deepcopy(item["glyphs"][0]))
		cases.append(item)
		item = atlas()
		item["glyphs"][0]["atlasBounds"]["right"] = 3
		cases.append(item)
		item = atlas()
		del item["glyphs"][0]["planeBounds"]
		cases.append(item)
		item = atlas()
		item["kerning"] = [{"unicode1": 65, "unicode2": 20013, "advance": -.1}]
		cases.append(item)
		item = atlas()
		item["kerning"] = [{"unicode1": 65, "unicode2": 86, "advance": -.1}] * 2
		cases.append(item)
		cases.extend([atlas([variant((65,)), variant((65,))]), atlas([])])
		for item in cases:
			with self.subTest(item=item), self.assertRaises(fp.FontError):
				fp.normalize_msdf(item)
		with self.assertRaises(fp.FontError):
			fp.normalize_msdf(atlas(), [[65]])
		with self.assertRaises(fp.FontError):
			fp.normalize_msdf(atlas(), [[65], [86]])
		item = atlas()
		item["glyphs"].append({"unicode": 32, "advance": .3})
		self.assertEqual(len(fp.normalize_msdf(item)["glyphs"]), 3)

# //@endregion

# //@region PNG、批次与失败清理

class BatchTests(unittest.TestCase):
	def setUp(self):
		self.directory = tempfile.TemporaryDirectory(prefix="olib_fonts_test_")
		self.addCleanup(self.directory.cleanup)
		self.root = Path(self.directory.name)
		self.temp = self.root / "work"
		self.fonts = []
		for index, points in enumerate(([65, 86], [65, 20013], [65])):
			font = self.root / f"font {index}.ttf"
			license_path = self.root / f"license {index}.txt"
			font.write_bytes(fp.json_bytes({"points": points, "modified": 123}))
			license_path.write_bytes(b"fixture license\n")
			self.fonts.append((font, license_path))

	def run_generator(self, command, cwd, **kwargs):
		self.assertFalse((cwd / "font.png").exists())
		self.assertEqual(command.count("-and"), 1)
		self.assertEqual(command[command.index("-threads") + 1], "1")
		self.assertEqual(command[command.index("-yorigin") + 1], "top")
		self.assertNotIn("subset-002.ttf", command)
		(cwd / "font.png").write_bytes(png())
		(cwd / "generator.json").write_bytes(fp.json_bytes(atlas([variant(), variant((20013,))])))
		return subprocess.CompletedProcess(command, 0, stdout="ok", stderr="")

	def build(self, name="out", **kwargs):
		return fp.build([20013, 86, 65, 65], self.fonts, self.root / name, self.temp,
			sys.executable, "fixture-1", **kwargs)

	def test_build_determinism_and_batch_hashes(self):
		with backend(), mock.patch.object(fp.subprocess, "run", side_effect=self.run_generator):
			first = self.build()
			second = self.build("out2")
		self.assertEqual(first, second)
		one, two = self.root / "out", self.root / "out2"
		for path in one.iterdir():
			self.assertEqual(path.read_bytes(), (two / path.name).read_bytes())
		self.assertEqual(first["assignments"], [[65, 86], [20013]])
		self.assertEqual(first["fonts"][2]["codepoints"], [])
		self.assertEqual(first["tool"]["sha256"], fp.sha256(sys.executable))
		self.assertFalse(first["sampling"]["premultiplied"])
		self.assertEqual(list(self.temp.iterdir()), [])
		self.assertEqual(fp.validate_batch(one), first)
		(one / "font.png").write_bytes(png(rows=[bytes([12, 32, 64, 90, 120, 180])] * 2))
		with self.assertRaisesRegex(fp.FontError, "hash"):
			fp.validate_batch(one)

	def test_provenance_cannot_drop_license_or_mix_flat_json(self):
		with backend(), mock.patch.object(fp.subprocess, "run", side_effect=self.run_generator):
			record = self.build()
		root = self.root / "out"
		cases = []
		bad = copy.deepcopy(record)
		del bad["artifacts"]["license-000.txt"]
		bad["batch_id"] = fp.batch_id(bad["artifacts"])
		cases.append(bad)
		bad = copy.deepcopy(record)
		bad["fonts"][0]["license"]["sha256"] = "0" * 64
		cases.append(bad)
		bad = copy.deepcopy(record)
		bad["assignments"] = [65]
		cases.append(bad)
		bad = copy.deepcopy(record)
		bad["artifacts"]["../escape"] = "0" * 64
		cases.append(bad)
		for bad in cases:
			(root / "provenance.json").write_bytes(fp.json_bytes(bad))
			with self.assertRaises(fp.FontError):
				fp.validate_batch(root)
		flat = fp.read_json(root / "font.json")
		flat["glyphs"][0]["advance"] = 99
		(root / "font.json").write_bytes(fp.json_bytes(flat))
		record["artifacts"]["font.json"] = fp.sha256(root / "font.json")
		record["batch_id"] = fp.batch_id(record["artifacts"])
		(root / "provenance.json").write_bytes(fp.json_bytes(record))
		with self.assertRaisesRegex(fp.FontError, "JSON"):
			fp.validate_batch(root)

	def test_nonzero_tool_failure_timeout_missing_pair_and_no_overwrite(self):
		failures = [subprocess.CompletedProcess([], 7, stdout="failed", stderr="detail"),
			subprocess.TimeoutExpired("fixture", 1), OSError("cannot execute"),
			subprocess.CompletedProcess([], 0, stdout="no outputs", stderr="")]
		for failure in failures:
			with self.subTest(failure=failure), backend(), mock.patch.object(fp.subprocess, "run") as run:
				if isinstance(failure, Exception):
					run.side_effect = failure
				else:
					run.return_value = failure
				with self.assertRaises(fp.FontError):
					self.build()
				self.assertFalse((self.root / "out").exists())
				self.assertEqual(list(self.temp.iterdir()), [])
		(self.root / "out").mkdir()
		(self.root / "out" / "keep").write_text("keep", encoding="utf-8")
		with self.assertRaises(fp.FontError):
			self.build()
		self.assertEqual((self.root / "out" / "keep").read_text(), "keep")

	def test_only_json_is_not_a_complete_batch(self):
		def json_only(command, cwd, **kwargs):
			(cwd / "generator.json").write_bytes(fp.json_bytes(atlas()))
			return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
		with backend(), mock.patch.object(fp.subprocess, "run", side_effect=json_only):
			with self.assertRaisesRegex(fp.FontError, "font.png"):
				self.build()
		self.assertFalse((self.root / "out").exists())

	def test_png_filters_and_rejections(self):
		path = self.root / "image.png"
		for method in range(5):
			path.write_bytes(png(filters=[method, method]))
			fp.validate_png(path, 2, 2)
		invalid = [png(rows=[bytes([10, 10, 10, 20, 20, 20])] * 2),
			png(rows=[bytes([10, 10, 30, 20, 20, 40])] * 2), png(color=6),
			png(extra=chunk(b"sRGB", b"\0")), png(extra=chunk(b"gAMA", struct.pack(">I", 45455))),
			png(extra=chunk(b"tRNS", b"\0" * 6)), png(filters=[5, 0]),
			png()[:-1], png(tail=b"trailing"), png().replace(b"IDAT", b"IDAX", 1)]
		for value in invalid:
			path.write_bytes(value)
			with self.subTest(value=value), self.assertRaises(fp.FontError):
				fp.validate_png(path, 2, 2)
		path.write_bytes(png())
		with self.assertRaises(fp.FontError):
			fp.validate_png(path, 3, 2)

	def test_cli_errors_without_external_dependencies(self):
		base = ["build", "--font", str(self.fonts[0][0]), "--license", str(self.fonts[0][1]),
			"--output-root", str(self.root / "out"), "--temp-root", str(self.temp),
			"--tool-version", "fixture", "--chars", "A"]
		with contextlib.redirect_stderr(io.StringIO()):
			self.assertEqual(fp.main(base + ["--generator", str(self.root / "missing-tool")]), 1)
			with backend():
				self.assertEqual(fp.main(base + ["--generator", sys.executable, "--chars", "中"]), 1)
			with backend(), mock.patch.object(fp.subprocess, "run", return_value=
				subprocess.CompletedProcess([], 7, stdout="failed", stderr="detail")):
				self.assertEqual(fp.main(base + ["--generator", sys.executable]), 1)
			(self.fonts[0][0]).unlink()
			self.assertEqual(fp.main(base + ["--generator", sys.executable]), 1)
		self.assertFalse((self.root / "out").exists())
		# -S 确实移除 site-packages；help 和输入错误不得依赖 fontTools/Pillow。
		result = subprocess.run([sys.executable, "-B", "-S", str(Path(fp.__file__)), "--help"],
			capture_output=True, check=False)
		self.assertEqual(result.returncode, 0)

# //@endregion

if __name__ == "__main__":
	unittest.main()
