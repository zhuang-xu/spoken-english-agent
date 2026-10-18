# Documentation conventions

Name API contracts under `docs/` as `<feature>-api-contract.md`, without a `todo-`
prefix. Markdown links must use these stable filenames. Track implementation status
inside the documents. When creating or renaming a contract, update its Markdown
references and verify that local link targets exist.

# Development harness

Use `.venv/bin/python scripts/dev_harness.py --dry-run` to inspect the saved task
and command; use `--verify-only` for independent documentation checks. See
[the harness guide](docs/harness-engineering.md) for execution and local tests.
Keep task briefs bounded, review the working tree before and after execution, and
inspect the per-run summary and logs. A successful agent exit is not verification.
