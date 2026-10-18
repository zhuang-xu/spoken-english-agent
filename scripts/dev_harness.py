#!/usr/bin/env python3
"""Small Codex runner with independent repository documentation checks."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import tempfile
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TASK = ROOT / 'scripts/tasks/reconcile-architecture.md'


def run_process(command, cwd, timeout, stdout, stderr, input_text=None):
    """Bound the entire process group, including children, on POSIX."""
    with stdout.open('w') as out, stderr.open('w') as err:
        process = subprocess.Popen(command, cwd=cwd, stdin=subprocess.PIPE,
                                   stdout=out, stderr=err, text=True,
                                   start_new_session=True)
        try:
            process.communicate(input_text, timeout=timeout)
            return {'status': 'passed' if process.returncode == 0 else 'failed',
                    'returncode': process.returncode}
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            return {'status': 'timeout', 'returncode': process.returncode}


def broken_links(root):
    failures = []
    files = [root / 'README.md', root / 'AGENTS.md', *sorted((root / 'docs').rglob('*.md'))]
    for path in files:
        fence = None
        for number, line in enumerate(path.read_text().splitlines(), 1):
            marker = re.match(r'^\s{0,3}(`{3,}|~{3,})', line)
            if marker:
                token = marker.group(1)
                if fence is None:
                    fence = token
                elif token[0] == fence[0] and len(token) >= len(fence):
                    fence = None
                continue
            if fence:
                continue
            # Inline destinations, optionally angle-wrapped or followed by a title.
            for match in re.finditer(r'!?\[[^\]]*\]\(\s*(<[^>]*>|[^\s)]+)(?:\s+["\'][^\n]*?["\'])?\s*\)', line):
                target = match.group(1).strip('<>')
                parsed = urlsplit(target)
                if parsed.scheme or parsed.netloc or not parsed.path:
                    continue
                if not (path.parent / unquote(parsed.path)).is_file():
                    failures.append(f'{path.relative_to(root)}:{number}: missing {target}')
    return failures


def verify(root, report, timeout):
    results = {}
    git = shutil.which('git')
    if git:
        try:
            results['git_diff_check'] = run_process([git, 'diff', '--check'], root, timeout,
                                                  report / 'diff-check.stdout', report / 'diff-check.stderr')
        except OSError as exc:
            results['git_diff_check'] = {'status': 'failed', 'error': str(exc)}
    else:
        results['git_diff_check'] = {'status': 'failed', 'error': 'missing tool: git'}
    failures = broken_links(root)
    results['markdown_links'] = {'status': 'failed' if failures else 'passed', 'errors': failures}
    return results


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--dry-run', action='store_true')
    modes.add_argument('--verify-only', action='store_true')
    parser.add_argument('--task', type=Path, default=DEFAULT_TASK)
    parser.add_argument('--timeout', type=float, default=600)
    parser.add_argument('--check-timeout', type=float, default=30)
    args = parser.parse_args(argv)
    if args.timeout <= 0 or args.check_timeout <= 0:
        parser.error('timeouts must be positive')
    base = ROOT / '.harness-runs'
    base.mkdir(exist_ok=True)
    report = Path(tempfile.mkdtemp(prefix='run-', dir=base))
    results = {}
    try:
        if args.verify_only:
            results['codex'] = {'status': 'skipped', 'reason': 'verify-only'}
        else:
            brief = args.task.read_text()
            (report / 'task.md').write_text(brief)
            codex = shutil.which('codex')
            command = [codex or 'codex', 'exec', '--sandbox', 'workspace-write',
                       '--json', '--cd', str(ROOT), '--output-last-message',
                       str(report / 'final-message.txt'), '-']
            (report / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
            if not codex:
                results['codex'] = {'status': 'failed', 'error': 'missing tool: codex'}
            elif args.dry_run:
                print(shlex.join(command))
                results['codex'] = {'status': 'skipped', 'reason': 'dry-run'}
            else:
                results['codex'] = run_process(command, ROOT, args.timeout,
                                               report / 'events.jsonl', report / 'codex.stderr', brief)
                if results['codex']['status'] == 'passed' and not (report / 'final-message.txt').is_file():
                    results['codex'] = {'status': 'failed', 'error': 'missing final message'}
    except (OSError, ValueError) as exc:
        results['codex'] = {'status': 'failed', 'error': str(exc)}
    # Always verify independently, even when Codex fails or is skipped.
    try:
        results.update(verify(ROOT, report, args.check_timeout))
    except (OSError, ValueError) as exc:
        results['verification'] = {'status': 'failed', 'error': str(exc)}
    (report / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))
    print(f'Report: {report}')
    return int(any(result['status'] not in ('passed', 'skipped') for result in results.values()))


if __name__ == '__main__':
    raise SystemExit(main())
