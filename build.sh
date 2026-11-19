#!/bin/zsh
# Build the ttkeep CLI and ttkeep.app (menu bar), optionally install the app to ~/Applications.
#   ./build.sh            build both into ./build
#   ./build.sh install    build, then copy ttkeep.app to ~/Applications and launch it
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
FW=(-framework IOKit -framework CoreGraphics -framework ColorSync)

swiftc -O Core.swift main.swift "${FW[@]}" -o build/ttkeep

APP=build/ttkeep.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library Core.swift App.swift "${FW[@]}" -framework AppKit -framework ServiceManagement -o "$APP/Contents/MacOS/ttkeep"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.ttkeep</string>
  <key>CFBundleName</key><string>ttkeep</string>
  <key>CFBundleExecutable</key><string>ttkeep</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP"
echo "built build/ttkeep and $APP"

if [[ "${1:-}" == install ]]; then
  pkill -x ttkeep 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/ttkeep.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/ttkeep.app
  echo "installed ~/Applications/ttkeep.app and launched it"
fi
