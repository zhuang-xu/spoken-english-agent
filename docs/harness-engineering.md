# Development harness

Prerequisites: Python 3, Git, and an installed, authenticated Codex CLI on PATH
for task execution. Run `codex login` if needed. The runner uses your existing
Codex account and configuration. See [Codex non-interactive execution](https://developers.openai.com/codex/noninteractive).

From the repository root, use the existing Python environment (standard library only):

```sh
.venv/bin/python -m unittest discover -s scripts/tests -v
.venv/bin/python scripts/dev_harness.py --dry-run
.venv/bin/python scripts/dev_harness.py --verify-only
```

The saved [example brief](../scripts/tasks/reconcile-architecture.md) bounds a future
architecture reconciliation. It has not been executed as part of harness setup.
Review the working tree and brief before deliberately running it:

```sh
git status --short
.venv/bin/python scripts/dev_harness.py --task scripts/tasks/reconcile-architecture.md --timeout 600 --check-timeout 30
git diff
```

Context is the saved task brief plus repository guidance and implementation. Action
is `codex exec` with `--sandbox workspace-write --json`, the repository working
directory, stdin containing the saved brief, and `--output-last-message`. The runner
omits a model override so the user's configured model remains the default. Feedback
combines the agent's final message and event stream with independent deterministic
checks; review all three before accepting a change.

Each invocation creates an ignored `.harness-runs/run-*` directory with `summary.json`
and check stdout/stderr. Task modes also save `task.md` and `command.json`; actual
execution writes `events.jsonl`, `codex.stderr`, and `final-message.txt`. Dry-run saves
the brief and command without starting Codex. Verify-only needs Git but skips Codex
and the task entirely. Dry-run requires Codex to be discoverable on PATH.

Both checks run after execution, failure, timeout, or skipped execution: `git diff
--check` and local inline Markdown link file targets in root README.md, AGENTS.md,
and all Markdown files under docs. External URLs, fragment-only links, and fenced
examples are ignored; reference-style links and fragment anchors are not validated.
Checks include existing user changes. The runner never edits README.md itself.

Failures, missing required tools, absent final messages, and timeouts return nonzero.
On timeout the runner kills the process group, including child processes (POSIX).
Timeouts do not roll back edits; inspect the diff and logs. The wrapper invokes
commands directly without a shell; Codex can still run development commands inside
its sandbox. No sandbox bypass or automatic retry is built in. The task brief
instructs Codex not to deploy, commit, or push; these are instructions, not an
enforced file allowlist.

Acceptance requires reviewing the architecture diff against the code paths cited
by Codex, confirming only the intended document changed, and retaining uncertainty
about hosted behavior. Passing link and whitespace checks does not establish
factual correctness. For a future implementation task, add the relevant backend
or browser tests to `verify()` before using this harness to accept code changes.
