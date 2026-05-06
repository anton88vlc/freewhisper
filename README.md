# FreeWhisper

SuperWhisper asked me for a Pro subscription this morning. Rude.

So I made a tiny macOS dictation app in Codex instead.

Hold a hotkey, speak, release/press again, get the transcript pasted back into the app you were using. If macOS refuses Accessibility permission because it woke up dramatic today, FreeWhisper still copies the text to your clipboard.

This is not a giant polished product. It is the useful core: record, transcribe, paste, keep recent audio so a failed transcription does not eat your thought.

## What It Does

- menu bar app for macOS;
- global hotkey recording;
- Deepgram Nova-3 transcription;
- multilingual mode that works better for Russian with English technical terms;
- local recording history with retry buttons;
- fast upload path: audio is converted to compact 16 kHz FLAC before Deepgram;
- automatic paste into the previous app when Accessibility is allowed;
- clipboard fallback when Accessibility is not allowed;
- stable ad-hoc signing, so macOS permissions do not break on every rebuild.

## Install

You need macOS 14+, Xcode command line tools / Swift, and ideally `ffmpeg`.

```bash
git clone https://github.com/pix0010/freewhisper.git
cd freewhisper
Scripts/install-app.sh
open /Applications/FreeWhisper.app
```

On first launch macOS will ask for Microphone. Say yes, obviously.

For auto-paste, also enable Accessibility for `FreeWhisper.app` in System Settings. If you skip it, transcripts still land in the clipboard.

## Deepgram Key

FreeWhisper uses Deepgram because it is fast and pretty good at messy real speech.

If you already have a key:

```bash
DEEPGRAM_API_KEY=YOUR_KEY Scripts/install-app.sh
open /Applications/FreeWhisper.app
```

The installer will store it here:

```text
~/Library/Application Support/FreeWhisper/secrets.env
```

Format:

```text
DEEPGRAM_API_KEY=YOUR_KEY
```

No key yet? Get one here:

https://console.deepgram.com/signup

Deepgram currently advertises a free $200 credit on the Pay As You Go plan:

https://deepgram.com/pricing

If no key is found, the installer still installs the app and prints the exact command to add one.

## Why The History Exists

The whole reason this project exists is that losing a dictated thought is maddening.

FreeWhisper keeps recent recordings under:

```text
~/Library/Application Support/FreeWhisper/Recordings
```

Each recording keeps:

- `audio.wav` — original local recording;
- `deepgram-16k.flac` — compact upload copy, generated when needed;
- `metadata.json` — status, transcript, provider, timing.

Open the menu, go to `Open Recordings`, and retry a failed transcription instead of re-dictating the whole thing like a medieval punishment.

## Build App

```bash
Scripts/build-app.sh
open build/FreeWhisper.app
```

That is for development checks. For real use, run:

```bash
Scripts/install-app.sh
open /Applications/FreeWhisper.app
```

The installer signs the app with a stable designated requirement:

```text
designated => identifier "app.freewhisper"
```

That matters because macOS permissions are weirdly tied to code-signing identity. If the identity changes every build, System Settings may claim permission is enabled while the app still gets denied. Fun little haunted house. This avoids that for local builds.

For proper distribution, use a real Developer ID:

```bash
FREEWHISPER_CODESIGN_IDENTITY="Developer ID Application: ..." Scripts/install-app.sh
```

## Settings

Settings live here:

```text
~/Library/Application Support/FreeWhisper/settings.json
```

Defaults:

- provider: Deepgram Nova-3;
- language: multilingual, tuned for Russian plus English terms;
- hotkey: Option + Space;
- history limit: 50 recordings;
- auto-paste: on.

## Sharp Edges

- This is currently source-install first, not a notarized DMG.
- Deepgram requires an API key.
- Local Whisper retry expects `whisper` to be installed separately.
- macOS permission UX is still macOS permission UX. We can reduce the nonsense, not abolish it.

Still: it works, it keeps your audio, and it does not ask for a Pro plan because you had the audacity to dictate a sentence.
