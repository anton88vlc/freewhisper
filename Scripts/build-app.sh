#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/FreeWhisper.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
CODESIGN_IDENTITY="${FREEWHISPER_CODESIGN_IDENTITY:--}"
CODESIGN_REQUIREMENTS="${FREEWHISPER_CODESIGN_REQUIREMENTS:-=designated => identifier \"app.freewhisper\"}"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/.build/release/freewhisper" "$MACOS/freewhisper"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP" >/dev/null 2>&1 || true
  xattr -c "$APP" >/dev/null 2>&1 || true
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign "$CODESIGN_IDENTITY" --requirements "$CODESIGN_REQUIREMENTS" "$APP" >/dev/null
fi

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP" >/dev/null 2>&1 || true
  xattr -c "$APP" >/dev/null 2>&1 || true
fi

echo "$APP"
