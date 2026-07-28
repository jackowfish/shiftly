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
	-framework ApplicationServices

# Sign with a stable identity so the Accessibility grant survives rebuilds
# (ad-hoc signing changes the app's identity every build, and TCC keys grants
# to the identity). SIGN_IDENTITY overrides for CI / Developer ID signing;
# locally a self-signed "Shiftly Dev Signing" cert is used if present.
IDENTITY="${SIGN_IDENTITY:-Shiftly Dev Signing}"
if security find-identity -p codesigning -v | grep -q "$IDENTITY"; then
	codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
	echo "warning: signing identity '$IDENTITY' missing, ad-hoc signing (accessibility grant will break on rebuild)" >&2
	codesign --force --sign - "$APP"
fi

echo "built $APP"
