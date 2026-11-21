#!/bin/zsh
# Builds Sing.app in Release with the Core ML models inside and packs it into a DMG.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="${SING_MODELS:-$HOME/Library/Application Support/Sing/Models}"
OUT="$ROOT/build"
cd "$ROOT"
xcodegen generate >/dev/null
xcodebuild -project Sing.xcodeproj -scheme SingMac -configuration Release -derivedDataPath DerivedData build | grep -E "error:|BUILD" || true
APP="$ROOT/DerivedData/Build/Products/Release/Sing.app"
for m in htdemucs crepe_full ecapa; do
  [ -d "$MODELS/$m.mlmodelc" ] || { echo "Missing $m.mlmodelc in $MODELS (run scripts/install-model.sh)"; exit 1; }
  rm -rf "$APP/Contents/Resources/$m.mlmodelc"
  cp -R "$MODELS/$m.mlmodelc" "$APP/Contents/Resources/"
done
codesign --force --deep --sign - "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$OUT"
DMG="$OUT/Sing-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Sing!" -srcfolder "$STAGE" -ov -format ULFO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "$DMG"
