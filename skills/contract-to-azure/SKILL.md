---
name: contract-to-azure
description: Implement and release Python FastAPI features from a Markdown API contract, with reusable pytest mocks, local verification, Azure Functions deployment, hosted smoke tests, and GitHub publication when requested.
---

# Contract to Azure

Use this workflow for a backend feature or release. Follow the stages requested by
the user; invoking the skill for planning or documentation does not authorize a
production deployment or GitHub push. Existing explicit authorization remains valid.

For the Spoken Agents repository, read [the project reference](references/spoken-agents.md)
for file locations, prior results, and resource names. Treat its recorded deployment
and test results as history, and recheck current state before acting.

## 1. Write or update the contract

Keep one separate Markdown API contract file per feature under `docs/`. Before
creating a file, look for an existing contract for that same feature and update it.
For a new feature, create `docs/<feature>-api-contract.md`; do not append it to
another feature's contract or a shared `contract.md`. A feature may cover
multiple related endpoints (for example, learner audio and transcript capture).
When splitting an existing combined contract, move the feature content, preserve
its acceptance cases and verification history, and update links. Cross-reference
related features instead of duplicating their contracts.

Use stable contract filenames and Markdown link targets without the `todo-`
prefix. Track pending, implemented, and verified work inside each contract,
not in its filename. When renaming a contract, update all Markdown references
and check that local links resolve.

Record the feature's purpose, scope, HTTP method/path, input fields and validation,
response shape, error status codes, storage transitions, external-provider behavior,
authentication, and acceptance cases. Separate implemented, verified, and deferred
work. Add a contract-to-test mapping as cases become covered.

Preserve explicit user choices. Resolve routine details from the project; ask only
for missing product decisions that change observable behavior. A contract-only
request ends with the contract, not an implementation or release.

## 2. Implement the agreed behavior

Inspect repository instructions, working-tree changes, runtime, and existing design.
Preserve unrelated user work. Keep HTTP routes, schema validation, workflow,
provider HTTP, and persistence separable; extend existing functions without adding
unnecessary abstractions.

For Azure OpenAI, verify current official API documentation and available deployment
versions. Azure hosting and Azure OpenAI inference are separate resources. Use the
resource endpoint, deployment name, and Azure authentication; do not substitute an
Azure key into a hardcoded direct OpenAI URL. Keep credentials in environment
settings, and keep response credentials out of storage and logs.

Update `.env.example`, README, and contract when configuration or behavior changes.

## 3. Write maintainable tests

Use `tests/conftest.py` for reusable fixtures: isolated settings, a temporary
database, fake provider responses, a configurable HTTP mock, and the API client.
Expose the mock so tests can inspect calls, override responses, or raise timeouts.
Keep provider defaults explicit: a Realtime response is not a universal OpenAI mock.

Keep feature assertions in feature test files and provider-protocol assertions in
provider tests. Exercise real validation, workflow, and temporary persistence;
mock the external HTTP boundary. Restore dependency overrides and mocks after each
test. Automated tests must not require a real provider key or paid API calls.

Cover acceptance cases and meaningful failure paths: invalid input, provider
rejection/timeout/malformed data, missing configuration, database failure, and
credential handling. Check state transitions as well as HTTP status where relevant.

## 4. Run local verification

Check the actual interpreter version before using `.venv`. Use the project's
supported Python version. If the existing environment is incompatible, create a
separate environment without replacing it. Install the project's requirements.

Run the changed feature tests, then the full relevant suite with that interpreter:

```sh
python -m pytest tests/test_session_creation.py -v
python -m pytest -q
git diff --check
```

Adapt the feature filename to the repository. Fix failures before deployment.
Report actual counts, warnings, and limitations. Mocked success does not establish
real provider connectivity; conduct an authorized real-provider check separately.

## 5. Update Azure and verify the hosted service

Inspect the signed-in subscription, target Function App, Python version, settings,
AI resource, deployed model, and quota. Reuse the intended target and preserve
unrelated settings. Create resources only within the requested setup scope. Do not
assume resource names or model availability from a previous project.

Prepare a source ZIP with the Functions entry point, `host.json`, requirements, and
application modules at the correct paths. Inspect its contents. Exclude `.env`,
keys, local databases, virtual environments, Git metadata, caches, and tests.
A manually created ZIP does not automatically honor `.funcignore`.

Keep Azure keys in memory during transfer or use a suitable secret-management
mechanism. Do not expose them in command arguments, logs, source files, or responses.

For a compatible Python Function App, deploy the inspected archive with a remote
build using `az functionapp deployment source config-zip --build-remote true` and
the verified resource group and app name. Azure installs Linux dependencies and
loads the ASGI entry point. Wait for completion, not only HTTP 202 acceptance.

Smoke-test the hosted routes: access protection, health, OpenAPI, invalid input,
and one valid feature request. Check the real response contract without printing
tokens. A health response alone does not verify storage or provider connectivity.
If verification fails, diagnose the specific failure before retrying; do not
repeatedly redeploy an unchanged package or silently replace resource targets.

Record deployment evidence and limitations. For Realtime, credential creation does
not prove a WebRTC conversation works. Report temporary storage honestly; do not
label the release production-ready while durability or user access is unresolved.

## 6. Upload the verified code to GitHub

Perform this stage when the user requests publication, including a full release
request that explicitly includes GitHub. Verify remote URL, branch, and current
working-tree changes. Do not assume all pre-existing changes belong in the release.

Inspect and stage explicit in-scope paths, including contract, implementation,
tests, and documentation. Check the staged diff for accidental secrets and local
artifacts. For an authorized release/upload, publish to `main` by default unless
the user explicitly selects another branch or repository rules require a PR.
Do not create a separate release branch merely because the user did not specify one.
Fetch the remote before integrating the verified changes into `main`; use a
fast-forward when possible and preserve remote work. If branch protection requires
a PR, follow that requirement and report that `main` is pending rather than treating
a branch push as a completed main release. Commit with a message describing final behavior.

Push to the verified remote branch; do not force-push or change repository visibility.
When a push is rejected, inspect the remote changes and resolve within scope rather
than overwrite them. Create a PR when requested or appropriate to the agreed flow;
use the final behavior, test results, deployment evidence, and limitations in its body.

Record the pushed commit SHA and branch/PR URL. If Azure was deployed before the
commit, ensure packaged application files match the committed files; otherwise
retest and redeploy the changed code. GitHub publication and Azure deployment are
separate actions unless verified CI connects them.

## Completion report

Summarize contract changes, implementation, test files/results, Azure verification,
and GitHub commit/PR independently. Mark skipped, pending, or blocked stages
explicitly. Never describe a planned push or mocked provider response as completed
publication or successful cloud integration.
