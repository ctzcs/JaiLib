"""Integration contracts for the migrated repository tools (no window required)."""
from pathlib import Path
import argparse
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


class RepositoryTools(unittest.TestCase):
    def test_layout_has_no_sibling_runtime_dependency(self):
        for directory in ['foster', 'thirdparty/imgui', 'assets', 'tools', 'prompts']:
            self.assertTrue((ROOT / directory).is_dir())
        self.assertFalse(list(ROOT.glob('*.bat')))
        self.assertFalse((ROOT / 'ImGui.dll').exists())
        self.assertFalse((ROOT / 'imgui.lib').exists())
        self.assertTrue((ROOT / 'thirdparty/imgui/ImGui.dll').is_file())
        for folder in ['core', 'kit', 'foster', 'thirdparty', 'tests']:
            for source in (ROOT / folder).rglob('*.jai'):
                text = source.read_text(encoding='utf-8-sig')
                self.assertNotIn('#import "jfoster"', text, str(source))
                self.assertNotIn('#import "ImGui"', text, str(source))

    def setUp(self):
        parent = ROOT / 'build/check/tmp'
        parent.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='repository-', dir=parent)
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def command(self, *args, cwd=ROOT):
        result = subprocess.run(list(map(str, args)), cwd=cwd, capture_output=True,
                                encoding='utf-8', errors='replace', timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_new_game_guards_and_builds(self):
        generator = load('new_game', 'tools/new-game/main.py')
        target = self.root / 'project with spaces'
        generator.create(target, 'ToolProbe', allow_inside=True)
        for name in ['ui.png', 'ui.json', 'charset.txt', 'OFL.txt']:
            relative = Path('assets/fonts/msdf') / name
            self.assertEqual((target / relative).read_bytes(), (ROOT / relative).read_bytes())
        before = (target / 'README.md').read_bytes()
        with self.assertRaises(ValueError):
            generator.create(target, 'Again', allow_inside=True)
        self.assertEqual(before, (target / 'README.md').read_bytes())
        for name in ['CON', '../bad', '123name']:
            with self.assertRaises(ValueError):
                generator.create(self.root / name.replace('/', '_'), name, allow_inside=True)
        for mode in ['check', 'game', 'editor']:
            self.command(sys.executable, target / 'tools/build.py', mode, cwd=self.root)
        self.assertFalse((target / 'build/game/ImGui.dll').exists())
        self.assertTrue((target / 'build/editor/ImGui.dll').exists())

    def test_builtin_msdf_loads_without_resource_working_directory(self):
        checker = load('asset_checker', 'tools/check/main.py')
        out = self.root / 'font-check'
        checker.stage_runtime(out)
        output = self.command(checker.compiler(), '-no_dce', '-import_dir', ROOT,
                              '-output_path', out, '-exe', 'assets',
                              ROOT / 'tests/tools/assets/main.jai')
        self.assertNotRegex(output, r'\berror\[|\b[Ee]rror:')
        executable = out / ('assets.exe' if sys.platform == 'win32' else 'assets')
        output = self.command(executable, cwd=out)
        self.assertIn('PASS builtin MSDF: 509 glyphs', output)

    def test_codegen_writes_and_detects_stale_output(self):
        runner = load('tool_runner', 'tools/run.py')
        exe = runner.build('auto_gen')
        source = self.root / 'module'; source.mkdir()
        file = source / 'module.jai'
        file.write_text('Zebra :: struct {} @tag("item");\nAnt :: struct {} @tag("item");\n', encoding='utf-8')
        args = [exe, '--source', source, '--tag', 'item', '--enum', 'Kind', '--out', 'kind_generated.jai']
        self.command(*args)
        generated = source / 'kind_generated.jai'
        text = generated.read_text(encoding='utf-8')
        self.assertLess(text.index('Ant;'), text.index('Zebra;'))
        self.command(*args, '--check')
        file.write_text(file.read_text(encoding='utf-8') + 'Bee :: struct {} @tag("item");\n', encoding='utf-8')
        result = subprocess.run(list(map(str, args)) + ['--check'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(generated.read_text(encoding='utf-8'), text)

    def test_shader_templates_use_runtime_manifest_reader(self):
        runner = load('shader_runner', 'tools/run.py')
        exe = runner.build('shaders')
        for template in (ROOT / 'kit/tools/shader_lab/templates').glob('*.oshader'):
            output = self.root / template.stem; output.mkdir()
            self.command(exe, template, output)
            manifests = list(output.glob('*.shader.json'))
            self.assertEqual(len(manifests), 1)
            data = json.loads(manifests[0].read_text(encoding='utf-8'))
            self.assertEqual(data['version'], 2)
            self.assertTrue(data['schemas'])
            self.assertTrue(list(output.glob('*.hlsl')))

    def test_shader_hash_gate_rejects_changed_source_and_product(self):
        shader = load('shader_tool', 'tools/shaders/main.py')
        source = self.root / 'shaders'; source.mkdir()
        hlsl = source / 'Test.hlsl'; hlsl.write_text('original', encoding='utf-8')
        output = source / 'Compiled'; output.mkdir()
        product = output / 'Test.vertex.spv'; product.write_bytes(b'compiled')
        record = dict(policy=shader.POLICY, sources=shader.inputs(source), dxil='spirv',
                      outputs={product.name: shader.digest(product)}, tools={})
        (output / shader.RECORD).write_text(json.dumps(record), encoding='utf-8')
        args = argparse.Namespace(check=True, check_build=False, dxil='spirv')
        shader.compile_directory(source, args)
        product.write_bytes(b'corrupt')
        with self.assertRaises(ValueError):
            shader.compile_directory(source, args)
        product.write_bytes(b'compiled')
        hlsl.write_text('changed', encoding='utf-8')
        with self.assertRaises(ValueError):
            shader.compile_directory(source, args)


if __name__ == '__main__':
    unittest.main()
