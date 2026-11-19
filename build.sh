#!/bin/zsh
# Build the holdcolortemp CLI and HoldColorTemp.app (menu bar), optionally install the app to ~/Applications.
#   ./build.sh            build both into ./build
#   ./build.sh install    build, then copy HoldColorTemp.app to ~/Applications and launch it
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
FW=(-framework IOKit -framework CoreGraphics -framework ColorSync)

swiftc -O Core.swift main.swift "${FW[@]}" -o build/holdcolortemp

APP=build/HoldColorTemp.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library Core.swift App.swift "${FW[@]}" -framework AppKit -framework ServiceManagement -o "$APP/Contents/MacOS/HoldColorTemp"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.holdcolortemp</string>
  <key>CFBundleName</key><string>HoldColorTemp</string>
  <key>CFBundleExecutable</key><string>HoldColorTemp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP"
echo "built build/holdcolortemp and $APP"

if [[ "${1:-}" == install ]]; then
  pkill -x HoldColorTemp 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/HoldColorTemp.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/HoldColorTemp.app
  echo "installed ~/Applications/HoldColorTemp.app and launched it"
fi
