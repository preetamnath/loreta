# Loreta Speak

Loreta Speak is a local-only macOS menu bar dictation app.

It records microphone audio with `Option + Space`, transcribes it on-device,
optionally cleans the transcript with Apple's on-device Foundation Models
runtime, inserts the result into the focused app, and saves local history.

## Current Status

The local v1 app is complete for development-machine use.

This repo does not currently ship a notarized app or DMG installer. Clone,
build, and run it locally.

## Requirements

- macOS 26 or newer
- Xcode with the macOS 26 SDK
- Apple Development signing configured in Xcode for the normal local install
- Microphone permission
- Accessibility permission for text insertion
- Local Apple Speech assets available on the Mac
- Apple Intelligence / Foundation Models availability if transcript cleanup is enabled

## Build And Run

From the Loreta repo root:

```sh
speak/scripts/install-local.sh
```

This builds the Xcode project, installs the app at:

```text
/Applications/LoretaSpeak.app
```

and launches it.

Use `Option + Space` to start and stop dictation.

## First Run

1. Run `speak/scripts/install-local.sh`.
2. Grant Microphone permission when macOS prompts.
3. Enable `LoretaSpeak` in System Settings > Privacy & Security > Accessibility.
4. Focus a text field in another app.
5. Press `Option + Space`, speak, then press `Option + Space` again to insert the transcript.

If text insertion does not work after rebuilding, reset Accessibility:

```sh
speak/scripts/install-local.sh --reset-accessibility --open-accessibility-settings
```

Then re-enable `LoretaSpeak` in Accessibility settings.

## Signing Notes

The default install path uses the Xcode project's configured signing settings.
That is the preferred local test path because macOS ties Accessibility trust to
the app bundle identity, path, and signing requirement.

If the signed build fails because your machine does not have the expected Xcode
account or certificate, you can use the unsigned fallback:

```sh
speak/scripts/install-local.sh --unsigned-fallback
```

Use this only for local testing. It changes the app's Accessibility trust
identity, resets Accessibility permission, and requires re-enabling
`LoretaSpeak` in System Settings.

## What The App Does Locally

- Records microphone-only audio.
- Suppresses audible system output during active recording when the current
  output route supports it.
- Transcribes locally on-device.
- Optionally cleans up transcripts locally.
- Inserts text at the current cursor or replaces selected text.
- Saves transcript text and audio clips in local history.
- Supports `Paste Last Transcription` from the menu bar.

## Limitations

- No cloud transcription or cloud cleanup fallback.
- No system-audio capture.
- No meeting capture, speaker labeling, or MCP integration.
- No notarized release artifact yet.
- Runtime behavior depends on local macOS speech and Apple Intelligence
  availability.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).

The license covers this repository's source code. It does not grant rights to
Apple SDKs, macOS system frameworks, Apple Speech assets, or Apple Intelligence
/ Foundation Models runtimes used by the app on the local machine.
