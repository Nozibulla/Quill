# Quill

**Better writing, one shortcut away.**

Quill is a native macOS menu bar app that corrects selected text directly in the app where you are writing. Select a draft, press **⌘⇧E**, and Quill replaces the selection after checking that the original field is still unchanged.

Built with SwiftUI and AppKit. No third-party package dependencies.

## Features

- Correct text in place without opening a separate editor.
- Choose from eight writing styles, including custom guidance.
- Use a compatible local Codex runtime with ChatGPT sign-in.
- Choose an available model and optional Fast speed in Settings.
- Cancel a correction by pressing the shortcut again.
- Copy a completed result when automatic replacement is unavailable.
- Launch at login and customize the global shortcut.

Quill is an independent project and is not affiliated with or endorsed by OpenAI. ChatGPT and Codex are OpenAI products.

## Requirements

- macOS 14 or later.
- Xcode with the macOS SDK to build from source. Development was tested with Xcode 27.0 on Apple Silicon; Intel builds have not been verified.
- A compatible official Codex CLI or desktop-bundled runtime, signed in with a ChatGPT account that has access to Codex.
- Internet access for corrections and macOS Accessibility permission for in-place editing.

The runtime integration was tested with Codex `0.158.0-alpha.2.1`. It uses experimental app-server capabilities, so compatibility with other versions is not guaranteed. The runtime is not bundled in this repository.

## Build and install

Open `Quill.xcodeproj` in Xcode, select the **Quill** scheme, and run. Or build from the repository directory:

```sh
./scripts/build.sh
open build/Build/Products/Release/Quill.app
```

To install at a stable location, quit any running copy of Quill, then run:

```sh
./scripts/install.sh
```

The installer builds the app, copies it to `/Applications/Quill.app`, verifies its signature, and launches it. An existing Quill installation is backed up under `build/Quill-previous.app`. Write access to `/Applications` is required.

The checked-in Xcode project is ready to build. `project.yml` is available for optional regeneration with XcodeGen.

Development builds are ad-hoc signed and are not notarized distribution releases. Rebuilding can invalidate macOS Accessibility approval. Distribution requires your own signing and notarization setup.

## First use

1. Open Quill from Applications. Look for the feather icon in the menu bar.
2. Open **Settings** and check the detected Codex runtime. You can supply an absolute executable path if detection fails.
3. Use **Sign in with ChatGPT** if the runtime is not already signed in.
4. Grant Quill **Accessibility** access in macOS System Settings. On some versions this pane is called **Device Control and Data Access**.
5. Select text in an editable field and press **⌘⇧E**. Keep the same app, field, and selection active while the correction runs.

Quill pastes the correction into the original selection and verifies the resulting field before reporting success. It does not press Return or submit chat messages. Changing the app, field, or selection blocks automatic replacement. Press the shortcut again during generation to cancel.

The optional **Manual editor** lets you paste text and copy a correction. It is not required for the shortcut workflow.

### Styles and speed

Styles include Correct only, Natural, Professional, Friendly, Concise, Confident, Casual, and Custom. Natural is the default.

Models are discovered from the runtime. Automatic selection prefers GPT-6 Luna when available and uses low reasoning where supported. Standard speed is the default. Fast is offered only when the selected model advertises support and consumes the shared account allowance faster. Settings shows request timing; latency depends on the model and network.

## Compatibility and limitations

In-place replacement has been verified in a ChatGPT draft. Support in other editors, including Teams, depends on the app exposing readable Accessibility text and selection information; it is not guaranteed.

- Secure fields and unverifiable selections are rejected.
- Plain-text replacement may lose formatting within the selection.
- If replacement cannot be confirmed, inspect the draft before retrying and use **Copy last result** if needed.
- Quill temporarily uses the clipboard for paste. It restores previous contents after confirmed consumption unless the clipboard has changed in the meantime. An unconfirmed paste can leave the correction on the clipboard.
- Corrections consume the existing account's Codex allowance. Quill does not purchase credits, change billing methods, or offer an API-key fallback.

### Accessibility is enabled but Quill says access is denied

A permission entry can refer to an older signed build. Quit Quill, remove its old entry in System Settings, add `/Applications/Quill.app` again, enable access, and restart Quill. Settings includes the running app path and controls to recheck access or restart. Quill cannot grant permission itself.

## Privacy

Selected text is sent to the configured OpenAI Codex service when you explicitly request a correction. Processing is not entirely local. Quill does not monitor typing for background uploads or maintain a correction history.

The Codex runtime manages authentication and credential storage. Quill does not read credential files or browser cookies. Existing ChatGPT sign-in is shared with other Codex clients; signing in can affect the account those clients use.

Each correction uses a fresh ephemeral thread in an empty temporary directory. Quill disables tools, configured MCP servers, skills, and project instructions for that session and rejects requests when it cannot confirm the required isolation. It does not edit global Codex configuration. Service-side retention and runtime metadata remain governed by the runtime and account policies.

## Development

Run the unit tests without a ChatGPT sign-in:

```sh
./scripts/test.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidance and [VALIDATION.md](VALIDATION.md) for tested behavior and remaining limitations. Live diagnostic commands use the signed-in account and may consume allowance; they are not part of the unit suite.

| Location | Purpose |
| --- | --- |
| `Sources/` | App lifecycle, UI, correction service, Accessibility and clipboard handling |
| `Tests/` | Unit tests for state, protocol framing and replacement safeguards |
| `Resources/` | App icon and asset catalog |
| `scripts/` | Build, installation and optional live protocol probe |
| `project.yml` | XcodeGen project definition |

Report ordinary bugs through GitHub Issues. For security-sensitive reports, follow [SECURITY.md](SECURITY.md).

## License

Quill is open source under the [MIT License](LICENSE).
