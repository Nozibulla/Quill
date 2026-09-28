# Install Quill Beta

## Before you download

- Quill requires macOS 14 or later and internet access.
- The app contains Apple Silicon and Intel code. Apple Silicon has been tested; Intel has not.
- A compatible official Codex runtime and a ChatGPT account with Codex access are required. **The runtime is not included in this download.** This beta is best suited to users who already use Codex.
- This beta is ad-hoc signed, not Developer ID signed or notarized by Apple. macOS may block its first launch. Managed Macs may not allow an exception.

## 1. Install

Download `Quill-1.0.0-beta.1-universal.dmg` from the [beta release](https://github.com/Nozibulla/Quill/releases/tag/v1.0.0-beta.1). Open the disk image and drag **Quill.app** onto **Applications**. Eject the disk image, then open Quill from Applications.

If replacing an existing copy, quit Quill from its feather menu before copying the new app.

## 2. Open the beta

If macOS says it cannot verify the developer or check the app, and you trust this download, open **System Settings → Privacy & Security → Open Anyway** after attempting to launch Quill. Confirm the prompt. Follow [Apple's instructions](https://support.apple.com/en-us/102445).

Do not disable Gatekeeper. If macOS reports malware or a damaged app, stop and report the exact message. An unidentified-developer exception is not a remedy for those errors.

Quill starts in the menu bar. Look for the feather icon; it does not open an editor window at launch.

## 3. Connect your account

Open **Quill's feather menu → Settings**. Check the **Codex Runtime** section.

Quill looks for a compatible runtime in the official ChatGPT or Codex desktop app and common Homebrew locations. The tested runtime was `0.158.0-alpha.2.1`. Other versions may not support the experimental features Quill requires.

If no runtime is detected, follow the [official desktop setup guide](https://learn.chatgpt.com/docs/quickstart) or [Codex CLI guide](https://learn.chatgpt.com/docs/codex/cli). The CLI route may require technical assistance. Installing a different version does not guarantee Quill compatibility. A custom executable path can be entered in Quill Settings. Reconnect after setup.

Choose **Sign in with ChatGPT** if needed and finish the browser flow. An existing compatible sign-in may be reused. Quill uses your shared Codex allowance; it has no API-key mode. Sign-in can affect the account used by your other Codex clients.

## 4. Enable Accessibility

In Quill Settings, choose **Open permission settings** and enable Quill. The macOS pane may be named Accessibility or Device Control and Data Access. Return to Quill Settings and choose **Recheck access**.

If access still appears denied, quit Quill, remove its old permission entry, add `/Applications/Quill.app`, enable it, and reopen Quill. This may be needed after beta updates because the app is ad-hoc signed.

## 5. Try a correction

1. Type `i has sent the file yesterday` in an unsent ChatGPT draft.
2. Select the sentence and press **Command + Shift + E**.
3. Keep the same field and selection active until Quill finishes.
4. Check that the text changed. Quill does not send the message.

Press the shortcut again during generation to cancel. If replacement is uncertain, inspect the draft before retrying. **Copy last result** is available from Quill's menu after a failed replacement with a completed correction.

## Limitations and privacy

ChatGPT draft replacement has been verified. Teams and other editors remain unverified; compatibility depends on their Accessibility support. Rich formatting within a selection may be lost. Plain-text replacement temporarily uses the clipboard; an unconfirmed paste may leave the correction there.

Selected writing is sent to OpenAI when you request a correction. Quill is not an offline tool and keeps no correction history. Runtime and service-side data policies still apply.

Report bugs at https://github.com/Nozibulla/Quill/issues using synthetic text. Include macOS version, target app, runtime version, and the exact error. Never include private drafts or account credentials.

## Uninstall

Quit Quill, move it from Applications to Trash, and remove its Accessibility entry if desired. Quill's preferences may remain. Your separately installed Codex runtime and its sign-in are not removed.
