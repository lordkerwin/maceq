#!/usr/bin/env bash
# Build MacEQ.app and sign it.
#
# TCC (the Audio Recording permission) keys off the code signature, so signing with a
# stable identity means you grant permission once instead of on every rebuild. Override
# with MACEQ_IDENTITY=... if you use a different certificate.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="MacEQ.app"
IDENTITY="${MACEQ_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -m1 'Apple Development' \
  | sed -E 's/.*"(.*)"/\1/')}"

if [[ -z "$IDENTITY" ]]; then
  echo "No 'Apple Development' signing identity found." >&2
  echo "Falling back to ad-hoc signing; macOS will re-ask for permission after each rebuild." >&2
  IDENTITY="-"
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MacEQ"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacEQ"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> signing as: $IDENTITY"
codesign --force \
  --sign "$IDENTITY" \
  --entitlements Resources/MacEQ.entitlements \
  --options runtime \
  "$APP"

codesign --verify --verbose=2 "$APP"
echo "==> built $(pwd)/$APP"
echo "    run it with: open $APP"
