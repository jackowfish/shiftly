#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Shiftly.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Shiftly.icns" "$APP/Contents/Resources/Shiftly.icns"

swiftc -O "$ROOT"/Sources/*.swift \
	-o "$APP/Contents/MacOS/Shiftly" \
	-framework AppKit \
	-framework Carbon \
	-framework ApplicationServices \
	-framework AVFoundation \
	-framework CoreMedia \
	-framework CoreVideo \
	-framework Vision

# Sign with a stable identity so the Accessibility grant survives rebuilds
# (ad-hoc signing changes the app's identity every build, and TCC keys grants
# to the identity). SIGN_IDENTITY overrides; otherwise prefer Developer ID
# (same identity as releases, so dev and release builds share one grant),
# then a self-signed "Shiftly Dev Signing" cert, then ad-hoc.
IDENTITIES=$(security find-identity -p codesigning -v)
if [ -n "${SIGN_IDENTITY:-}" ]; then
	IDENTITY="$SIGN_IDENTITY"
elif echo "$IDENTITIES" | grep -q "Developer ID Application"; then
	IDENTITY="Developer ID Application"
elif echo "$IDENTITIES" | grep -q "Shiftly Dev Signing"; then
	IDENTITY="Shiftly Dev Signing"
else
	IDENTITY=""
fi
if [ -n "$IDENTITY" ]; then
	codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
	echo "warning: no signing identity found, ad-hoc signing (accessibility grant will break on rebuild)" >&2
	codesign --force --sign - "$APP"
fi

echo "built $APP"
