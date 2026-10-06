#!/bin/zsh
# Builds "Loaded Models.app" into ./build. Pass "install" to copy it to /Applications and launch it.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
APP="build/Loaded Models.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LoadedModels "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x LoadedModels || true
  rm -rf "/Applications/Loaded Models.app"
  cp -R "$APP" /Applications/
  open "/Applications/Loaded Models.app"
  echo "Installed to /Applications and launched"
fi
