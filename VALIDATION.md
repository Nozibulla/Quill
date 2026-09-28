# Validation

## Tested environment

Development was tested on Apple Silicon with Xcode 27.0, Swift 6.4, and Codex `0.158.0-alpha.2.1`. The deployment target is macOS 14; this does not establish testing on every supported macOS version or on Intel.

## Automated checks

The 27-test XCTest suite passed. Coverage includes prompt boundaries, model selection, revision cancellation, JSON-lines framing, clipboard ownership, shortcut registration conflicts, app state, destination invalidation, and replacement verification.

Replacement checks include UTF-16 selection offsets, preservation of surrounding text, invalid ranges, no-op delivery, reverted edits, and stable changes. The Release build and local code-signature verification also passed.

## Live checks

- A synthetic correction completed through the existing ChatGPT-managed Codex sign-in.
- The correction thread was ephemeral, with no loaded instruction sources and no tool items emitted.
- A user confirmed that selected text in a ChatGPT draft changed in place. App diagnostics independently confirmed the expected text, with no error and no review window open.
- That sample took approximately 4.3 seconds: 4.0 seconds for the request and 0.3 seconds for paste and verification. These are measurements, not latency guarantees.
- Accessibility approval was verified for the installed build. Rebuilding an ad-hoc signed app can require approval again.

## Not established by these checks

Compatibility with Teams, all browser editors, rich-text applications, Intel Macs, and every supported macOS version remains unverified. Unit tests do not substitute for testing actual Accessibility behavior in each editor.

Browser sign-in recovery, exhausted allowance, prolonged network failures, launch at login after an OS login, and distribution signing/notarization have not all been exercised end to end.

Raw local screenshots, logs, and diagnostic reports are excluded from the public repository.
