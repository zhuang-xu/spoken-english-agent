import importlib.util
import json
import os
from pathlib import Path
import sys
import shlex
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('dev_harness', Path(__file__).parents[1] / 'dev_harness.py')
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'docs').mkdir()
        (self.root / 'README.md').write_text('User content\n')
        (self.root / 'AGENTS.md').write_text('Guidance\n')
        self.task = self.root / 'task.md'
        self.task.write_text('Bounded task')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.fake('git', 'raise SystemExit(0)')

    def fake(self, name, code):
        path = self.bin / name
        source = self.bin / (name + '.py')
        source.write_text(code + '\n')
        path.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(source)) + ' "$@"\n')
        path.chmod(0o755)
        return path

    def invoke(self, *args):
        with patch.object(harness, 'ROOT', self.root), patch.dict(os.environ, {'PATH': str(self.bin)}):
            status = harness.main(['--task', str(self.task), *args])
        report = max((self.root / '.harness-runs').iterdir(), key=lambda p: p.stat().st_mtime_ns)
        return status, json.loads((report / 'summary.json').read_text()), report

    def test_failure_still_checks_links(self):
        self.fake('codex', 'print(\'{"type":"error"}\'); raise SystemExit(7)')
        (self.root / 'docs/a.md').write_text('[bad](missing.md)')
        status, result, report = self.invoke()
        self.assertEqual(status, 1)
        self.assertEqual(result['codex']['returncode'], 7)
        self.assertEqual(result['markdown_links']['status'], 'failed')
        self.assertIn('error', (report / 'events.jsonl').read_text())
        self.assertEqual((report / 'task.md').read_text(), 'Bounded task')

    def test_timeout(self):
        self.fake('codex', 'import time\ntime.sleep(10)')
        status, result, _ = self.invoke('--timeout', '0.05')
        self.assertEqual(status, 1)
        self.assertEqual(result['codex']['status'], 'timeout')
        self.assertEqual(result['git_diff_check']['status'], 'passed')

    def test_skipped_modes_do_not_launch_codex(self):
        marker = self.root / 'launched'
        self.fake('codex', f'from pathlib import Path\nPath({str(marker)!r}).touch()')
        for mode in ('--dry-run', '--verify-only'):
            with self.subTest(mode=mode):
                status, result, _ = self.invoke(mode)
                self.assertEqual(status, 0)
                self.assertEqual(result['codex']['status'], 'skipped')
                self.assertFalse(marker.exists())
        self.assertEqual((self.root / 'README.md').read_text(), 'User content\n')

    def test_missing_tools(self):
        status, result, _ = self.invoke('--dry-run')
        self.assertEqual(status, 1)
        self.assertIn('missing tool', result['codex']['error'])
        (self.bin / 'git').unlink()
        status, result, _ = self.invoke('--verify-only')
        self.assertEqual(status, 1)
        self.assertIn('missing tool', result['git_diff_check']['error'])

    def test_success_command_and_stdin(self):
        self.fake('codex', 'import sys\nfrom pathlib import Path\n'
                  'assert sys.stdin.read() == "Bounded task"\n'
                  'assert sys.argv[1:4] == ["exec", "--sandbox", "workspace-write"]\n'
                  'assert "--json" in sys.argv and "--model" not in sys.argv\n'
                  'Path(sys.argv[sys.argv.index("--output-last-message") + 1]).write_text("done")\n'
                  'print(\'{"type":"done"}\')')
        status, _, report = self.invoke()
        self.assertEqual(status, 0)
        self.assertEqual((report / 'final-message.txt').read_text(), 'done')

    def test_missing_final_and_git_failure(self):
        self.fake('codex', 'raise SystemExit(0)')
        self.fake('git', 'print("whitespace"); raise SystemExit(2)')
        status, result, _ = self.invoke()
        self.assertEqual(status, 1)
        self.assertEqual(result['codex']['error'], 'missing final message')
        self.assertEqual(result['git_diff_check']['status'], 'failed')

    def test_link_rules(self):
        (self.root / 'docs/exists.md').touch()
        (self.root / 'docs/a.md').write_text(
            '[ok](exists.md#anchor) [web](https://example.com/no) [anchor](#no)\n'
            '[angle](<exists.md>)\n```md\n[example](absent.md)\n```\n'
            '~~~\n[example](absent.md)\n~~~\n[bad](absent.md)\n')
        errors = harness.broken_links(self.root)
        self.assertEqual(len(errors), 1)
        self.assertIn('missing absent.md', errors[0])


if __name__ == '__main__':
    unittest.main()
