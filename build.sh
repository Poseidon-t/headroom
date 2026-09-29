#!/bin/zsh
# Builds Unslow.app and installs it to /Applications. Set SIGN_ID to a
# code-signing identity in your keychain; without it the app is signed ad hoc.
# Pass --no-install to stop after the build.
set -euo pipefail
cd "${0:A:h}"
mkdir -p build

# Some Command Line Tools installs ship a stale swift module.modulemap that
# collides with bridging.modulemap. An overlay hides it; swiftc needs the
# overlay passed both ways.
OVERLAY=()
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ -f $STALE ]]; then
  : > build/empty.modulemap
  cat > build/vfs.yaml <<YAML
{ "version": 0, "case-sensitive": false, "use-external-names": false,
  "roots": [ { "type": "file", "name": "$STALE", "external-contents": "$PWD/build/empty.modulemap" } ] }
YAML
  OVERLAY=(-vfsoverlay build/vfs.yaml -Xcc -ivfsoverlay -Xcc build/vfs.yaml)
fi

swiftc -O -swift-version 5 $OVERLAY \
  -framework AppKit -framework UserNotifications -framework ServiceManagement \
  main.swift Core.swift SelfTest.swift -o build/Unslow

./build/Unslow --selftest

APP=build/Unslow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp build/Unslow "$APP/Contents/MacOS/Unslow"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.sarathsabarish.unslow</string>
  <key>CFBundleName</key><string>Unslow</string>
  <key>CFBundleDisplayName</key><string>Unslow</string>
  <key>CFBundleExecutable</key><string>Unslow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${SIGN_ID:--}" --identifier com.sarathsabarish.unslow --timestamp=none "$APP"

[[ "${1:-}" == "--no-install" ]] && { echo "built $APP"; exit 0; }

pkill -x Unslow || true
rm -rf /Applications/Unslow.app
cp -R "$APP" /Applications/Unslow.app
open /Applications/Unslow.app
echo "installed /Applications/Unslow.app"
