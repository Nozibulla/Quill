# Contributing to Quill

Bug reports and focused pull requests are welcome. For substantial changes, open an issue first to discuss the behavior and scope.

## Local development

1. Open `Quill.xcodeproj` in Xcode and use the Quill scheme.
2. Run `./scripts/test.sh` before submitting changes.
3. Run `./scripts/build.sh` to check the Release build when changing app code.

There are no third-party package dependencies. The checked-in project can be built without XcodeGen. If you change target configuration, update `project.yml` and regenerate the project with `xcodegen generate`; include both changes.

## Changes and tests

Keep changes focused and describe the user-visible behavior, the reason for the change, and how it was tested. Add meaningful coverage when changing selection validation, cancellation, clipboard ownership, protocol handling, or replacement verification.

Use synthetic text for manual tests. Never include private drafts, credentials, account details, or diagnostic screenshots containing personal information in issues or commits. Local reports under `validation/` and build outputs are ignored by Git.

Accessibility tests need user approval and a real editable field. Unit tests cannot establish compatibility with every editor. For an integration change, report the macOS version, target app, selected-text behavior, and whether replacement was confirmed. Do not submit the test draft as a chat message.

## Live diagnostics

The optional `scripts/probe_codex.py` submits a synthetic correction through the signed-in Codex runtime and consumes account allowance. It is separate from the unit tests.

Debug builds support `--smoke-test`. Other explicit diagnostic options include `--permission-check`, `--diagnostics`, and `--snapshot`. These write local reports or render Quill's own window under `/tmp`; inspect artifacts before sharing them. Normal launches do not enable these diagnostics.

## Boundaries to preserve

- Correct only after an explicit user action.
- Reject secure fields and changed or unverifiable destinations.
- Verify replacement before reporting success; never send the draft.
- Preserve clipboard ownership and reject stale or cancelled completions.
- Keep authentication in the official runtime and corrections in isolated ephemeral sessions.
