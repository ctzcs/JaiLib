"""Run the W3-W6 WebGL regressions against a built wasm sample.

Usage: python foster/tests/wasm/verify_webgl.py [--gpu] [--browser PATH]
Build first with python tools/wasm/build.py. Requires Chrome/Edge with Memory64.
Checks both 3,100 fixed steps and the original index.html timer loop.
GPU page compositing is disabled for virtual-time runs: Chromium can otherwise
report false blit feedback loops even in a standalone two-FBO reproducer.
This flag does not select the WebGL renderer; --gpu still requests hardware GL.
"""
import argparse
import html
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


CHECKS = ['W3 PIXEL', 'W4 BATCHER', 'W4 FONT', 'W4 HOT-REPLACE',
          'W5 TARGET', 'W5 BLIT', 'W5 MSAA', 'W5 ORIENTATION',
          'W6 LIMIT', 'W6 SOAK', 'W6 WINDOW-MSAA']


def run_page(browser, here, args, page, budget):
    with tempfile.TemporaryDirectory(prefix='webgl-profile-', dir=here / '.build',
                                     ignore_cleanup_errors=True) as profile:
        cmd = [browser, '--headless=new', '--no-sandbox', '--disable-extensions',
               '--disable-gpu-compositing', '--user-data-dir=' + profile,
               '--virtual-time-budget=' + str(budget), '--dump-dom']
        if not args.gpu:
            cmd += ['--enable-unsafe-swiftshader', '--use-angle=swiftshader']
        result = subprocess.run(cmd + [here.as_uri() + '/' + page],
                                capture_output=True, timeout=90)
        if result.returncode:
            raise RuntimeError('Browser exited with ' + str(result.returncode) + ': ' +
                               result.stderr.decode('utf-8', errors='replace')[-1000:])
        return result.stdout.decode('utf-8', errors='replace')


def timer_report(dom):
    match = re.search(r'<pre id="log">(.*?)</pre>', dom, re.S)
    log = html.unescape(re.sub('<[^>]+>', '', match.group(1))) if match else ''
    failures = [name for name in CHECKS if name + ': PASS' not in log]
    counters = [int(n) for n in re.findall(r'gl_error=(\d+)', log)]
    errors = max(counters) if counters else -1
    # Catch errors after the last periodic report as well.
    diagnostics = bool(re.search(r'GL error 0x|blitFramebuffer failed|fw_step 抛异常|webglcontextlost', log))
    return dict(pass_=not failures and errors == 0 and not diagnostics,
                failures=failures, errors=errors, diagnostics=diagnostics, log=log)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gpu', action='store_true')
    parser.add_argument('--browser', default=os.environ.get('CHROME'))
    args = parser.parse_args()
    candidates = [args.browser,
                  r'C:\Program Files\Google\Chrome\Application\chrome.exe',
                  r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
                  '/usr/bin/google-chrome', '/usr/bin/chromium']
    browser = next((p for p in candidates if p and Path(p).is_file()), None)
    if not browser:
        parser.error('Chrome/Edge not found; pass --browser PATH')
    here = Path(__file__).resolve().parent
    if not (here / '.build/fw_wasm_b64.js').is_file():
        parser.error('run python tools/wasm/build.py first')
    dom = run_page(browser, here, args, 'verify_webgl.html', 20000)
    match = re.search(r'<pre id="report">(.*?)</pre>', dom, re.S)
    if not match or match.group(1) == 'pending':
        raise SystemExit('No completed fixed-step WebGL report')
    fixed = json.loads(html.unescape(match.group(1)))
    # Independently enforce the complete contract, even against an older page.
    fixed['failures'] = [name for name in CHECKS if name + ': PASS' not in fixed.get('log', '')]
    fixed['pass'] = fixed['pass'] and not fixed['failures'] and fixed.get('errors') == 0
    timed = timer_report(run_page(browser, here, args, 'index.html?driver=timeout', 60000))
    timed['pass'] = timed.pop('pass_')
    report = {'pass': fixed['pass'] and timed['pass'], 'fixed': fixed, 'timer': timed}
    report_path = here / '.build/webgl_report.json'
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print('Renderer:', fixed.get('renderer', 'unknown'))
    for name, result in [('Fixed steps', fixed), ('Original page timers', timed)]:
        print(name + ':', 'PASS' if result['pass'] else 'FAIL', '| GL errors:', result.get('errors', 'unknown'))
        for failure in result.get('failures', []):
            print('Missing:', failure)
        if 'error' in result:
            print(result['error'])
    print('Report:', report_path)
    if not report['pass']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
