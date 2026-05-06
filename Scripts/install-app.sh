#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/FreeWhisper.app"
DEFAULT_INSTALL_DIR="/Applications"
CODESIGN_IDENTITY="${FREEWHISPER_CODESIGN_IDENTITY:--}"
CODESIGN_REQUIREMENTS="${FREEWHISPER_CODESIGN_REQUIREMENTS:-=designated => identifier \"app.freewhisper\"}"
APP_SUPPORT_DIR="${FREEWHISPER_APP_SUPPORT_DIR:-$HOME/Library/Application Support/FreeWhisper}"
SECRETS_FILE="${FREEWHISPER_SECRETS_FILE:-$APP_SUPPORT_DIR/secrets.env}"

choose_install_dir() {
  if [[ -n "${FREEWHISPER_INSTALL_DIR:-}" ]]; then
    printf '%s\n' "$FREEWHISPER_INSTALL_DIR"
    return
  fi

  local test_file="$DEFAULT_INSTALL_DIR/.freewhisper-write-test.$$"
  if touch "$test_file" >/dev/null 2>&1; then
    rm -f "$test_file"
    printf '%s\n' "$DEFAULT_INSTALL_DIR"
    return
  fi

  mkdir -p "$HOME/Applications"
  printf '%s\n' "$HOME/Applications"
}

extract_deepgram_key() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk -F= '
    /^[[:space:]]*DEEPGRAM_API_KEY[[:space:]]*=/ {
      value=$0
      sub(/^[[:space:]]*DEEPGRAM_API_KEY[[:space:]]*=[[:space:]]*/, "", value)
      gsub(/^[\"\047]|[\"\047]$/, "", value)
      if (length(value) > 0) {
        print value
        exit 0
      }
    }
  ' "$file"
}

write_deepgram_key() {
  local key="$1"
  mkdir -p "$APP_SUPPORT_DIR"
  chmod 700 "$APP_SUPPORT_DIR" >/dev/null 2>&1 || true
  if [[ -f "$SECRETS_FILE" ]]; then
    awk '!/^[[:space:]]*DEEPGRAM_API_KEY[[:space:]]*=/' "$SECRETS_FILE" > "$SECRETS_FILE.tmp"
    printf 'DEEPGRAM_API_KEY=%s\n' "$key" >> "$SECRETS_FILE.tmp"
    mv "$SECRETS_FILE.tmp" "$SECRETS_FILE"
  else
    printf 'DEEPGRAM_API_KEY=%s\n' "$key" > "$SECRETS_FILE"
  fi
  chmod 600 "$SECRETS_FILE" >/dev/null 2>&1 || true
}

bootstrap_deepgram_key() {
  local key=""
  local source=""

  if [[ -n "${DEEPGRAM_API_KEY:-}" ]]; then
    key="$DEEPGRAM_API_KEY"
    source="DEEPGRAM_API_KEY environment variable"
  elif key="$(extract_deepgram_key "$SECRETS_FILE" 2>/dev/null)" && [[ -n "$key" ]]; then
    source="$SECRETS_FILE"
  else
    local candidates=()
    [[ -n "${FREEWHISPER_DEEPGRAM_ENV_FILE:-}" ]] && candidates+=("$FREEWHISPER_DEEPGRAM_ENV_FILE")
    candidates+=(
      "$ROOT/.env"
      "$ROOT/secrets.env"
      "$HOME/.config/freewhisper/secrets.env"
    )
    for candidate in "${candidates[@]}"; do
      if key="$(extract_deepgram_key "$candidate" 2>/dev/null)" && [[ -n "$key" ]]; then
        source="$candidate"
        break
      fi
    done
  fi

  if [[ -n "$key" ]]; then
    write_deepgram_key "$key"
    printf 'Deepgram key: configured from %s\n' "$source"
  else
    cat <<EOF
Deepgram key: missing.

FreeWhisper can still install, but Deepgram transcription needs an API key.

Get a Deepgram key here:
  https://console.deepgram.com/signup

Deepgram currently advertises a free \$200 credit on the Pay As You Go plan:
  https://deepgram.com/pricing

Then run one of these:
  DEEPGRAM_API_KEY=YOUR_KEY Scripts/install-app.sh

or:
  mkdir -p "$APP_SUPPORT_DIR"
  printf 'DEEPGRAM_API_KEY=YOUR_KEY\n' > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
EOF
  fi
}

"$ROOT/Scripts/build-app.sh" >/dev/null
bootstrap_deepgram_key

INSTALL_DIR="$(choose_install_dir)"
DEST="$INSTALL_DIR/FreeWhisper.app"

pkill -f "$DEST/Contents/MacOS/freewhisper" >/dev/null 2>&1 || true
pkill -f "$ROOT/build/FreeWhisper.app/Contents/MacOS/freewhisper" >/dev/null 2>&1 || true

rm -rf "$DEST"
ditto --norsrc --noextattr "$APP" "$DEST"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$DEST" >/dev/null 2>&1 || true
  xattr -c "$DEST" >/dev/null 2>&1 || true
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign "$CODESIGN_IDENTITY" --requirements "$CODESIGN_REQUIREMENTS" "$DEST" >/dev/null
fi

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$DEST" >/dev/null 2>&1 || true
  xattr -c "$DEST" >/dev/null 2>&1 || true
fi

printf '%s\n' "$DEST"
