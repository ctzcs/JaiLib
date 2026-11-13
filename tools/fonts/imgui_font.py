"""把 Noto Sans CJK SC Regular 裁成 ImGui 内置字体子集（ASCII、Latin-1、GB2312）。"""

import argparse
from pathlib import Path
import sys

from font_pipeline import FontError, font_coverage, save_subset, sha256


SOURCE_SHA256 = "2C76254F6FC379FDDFCE0A7E84FB5385BB135D3E399294F6EEB6680D0365B74B"
DEFAULT_OUTPUT = Path(__file__).resolve().parents[2] / "assets" / "fonts" / "NotoSansCJKsc-Regular-subset.otf"


def charset():
	"""ImGui 只按码点取字形、不做塑形；GB2312 双字节区覆盖常用汉字与全角符号。"""
	codepoints = set(range(0x20, 0x7F)) | set(range(0xA0, 0x100)) | {0x2026}
	for high in range(0xA1, 0xF8):
		for low in range(0xA1, 0xFF):
			try:
				codepoints.add(ord(bytes([high, low]).decode("gb2312")))
			except UnicodeDecodeError:
				pass
	return sorted(codepoints)


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("source", type=Path, help="NotoSansCJKsc-Regular.otf")
	parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
	args = parser.parse_args()

	try:
		digest = sha256(args.source).upper()
		if digest != SOURCE_SHA256:
			raise FontError(f"源字体 SHA-256 不符：{digest}")
		# 与通用 MSDF 工具共享确定性子集；既有 source/--output/默认路径保持不变。
		codepoints = charset()
		save_subset(args.source, args.output, codepoints)
		covered = font_coverage(args.output)
		print(f"{args.output}: {args.output.stat().st_size} bytes, {len(covered)} codepoints")
	except (FontError, OSError, ValueError, ImportError) as error:
		print(f"imgui font: {error}", file=sys.stderr)
		return 1
	return 0


if __name__ == "__main__":
	sys.exit(main())
