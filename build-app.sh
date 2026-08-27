#!/bin/bash
# Builds VolBoost.app — an unsigned-except-ad-hoc bundle you can run locally
# or drop in /Applications. No provisioning profile, no notarization.
#
#   ./build-app.sh            release build for this Mac
#   ./build-app.sh --universal   arm64 + x86_64
#   ./build-app.sh --install     also copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

APP="VolBoost.app"
UNIVERSAL=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --install)   INSTALL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$UNIVERSAL" = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/VolBoost
else
  swift build -c release
  BIN=$(swift build -c release --show-bin-path)/VolBoost
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VolBoost"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Enough for the audio-capture permission prompt to appear;
# no developer account involved. Note the identity is the binary hash, so macOS
# treats each rebuild as a new app and re-asks for permission.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || codesign --force --sign - "$APP"

echo "built $(pwd)/$APP"

if [ "$INSTALL" = 1 ]; then
  osascript -e 'quit app "VolBoost"' >/dev/null 2>&1 || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
  echo "installed and launched /Applications/$APP"
fi
