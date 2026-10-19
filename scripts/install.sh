#!/bin/zsh
# Build Tick, add the app icon, sign ad hoc and install to /Applications.
set -e
cd "$(dirname "$0")/.."
pkill -x Tick || true
xcodebuild -project CircleTimer.xcodeproj -scheme CircleTimer -configuration Release \
  -derivedDataPath build PRODUCT_NAME=Tick CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES build 2>&1 | grep -E "error|BUILD"
APP=build/Build/Products/Release/Tick.app
mkdir -p $APP/Contents/Resources
cp CircleTimer/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
codesign --force --sign - $APP >/dev/null 2>&1
rm -rf /Applications/Tick.app
cp -R $APP /Applications/
touch /Applications/Tick.app
open /Applications/Tick.app
