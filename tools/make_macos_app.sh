#!/usr/bin/env bash
# Package the macOS build into RevengeRecompiled.app.
#
# On Apple, recompui::file::get_program_path() returns the bundle's Resources directory
# (RecompFrontend's file.cpp), so assets/ and recompcontrollerdb.txt must live there --
# not next to the executable as on Windows.
#
# Usage: tools/make_macos_app.sh [build-dir] [output-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${1:-$ROOT/build-macos}"
OUTDIR="${2:-$ROOT}"
APP="$OUTDIR/RevengeRecompiled.app"

[ -x "$BUILD/RevengeRecompiled" ] || { echo "error: $BUILD/RevengeRecompiled not built" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BUILD/RevengeRecompiled" "$APP/Contents/MacOS/"
cp -R "$ROOT/assets" "$APP/Contents/Resources/assets"
cp "$ROOT/recompcontrollerdb.txt" "$APP/Contents/Resources/"

# App icon: build an .icns from the 512x512 source PNG.
ICONSET="$(mktemp -d)/Revenge.iconset"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$ROOT/icons/app.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$ROOT/icons/app.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Revenge.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Revenge Recompiled</string>
    <key>CFBundleDisplayName</key><string>WCW/nWo Revenge: Recompiled</string>
    <key>CFBundleExecutable</key><string>RevengeRecompiled</string>
    <key>CFBundleIdentifier</key><string>com.jessetbh.RevengeRecompiled</string>
    <key>CFBundleIconFile</key><string>Revenge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
PLIST

# Vendor the Homebrew dylibs so the bundle does not depend on /opt/homebrew.
# sdl2-compat dlopens libSDL3.dylib by name, searching @loader_path first.
FW="$APP/Contents/Frameworks"
cp "$(brew --prefix sdl2-compat)/lib/libSDL2-2.0.0.dylib" "$FW/"
cp "$(brew --prefix sdl3)/lib/libSDL3.0.dylib"            "$FW/libSDL3.dylib"
cp "$(brew --prefix freetype)/lib/libfreetype.6.dylib"    "$FW/"
cp "$(brew --prefix libpng)/lib/libpng16.16.dylib"        "$FW/"
chmod u+w "$FW"/*.dylib

install_name_tool -id @rpath/libSDL2-2.0.0.dylib     "$FW/libSDL2-2.0.0.dylib"
install_name_tool -id @rpath/libfreetype.6.dylib     "$FW/libfreetype.6.dylib"
install_name_tool -id @loader_path/libSDL3.dylib     "$FW/libSDL3.dylib"
install_name_tool -id @loader_path/libpng16.16.dylib "$FW/libpng16.16.dylib"
install_name_tool -change "$(brew --prefix libpng)/lib/libpng16.16.dylib" \
    @loader_path/libpng16.16.dylib "$FW/libfreetype.6.dylib"

BIN="$APP/Contents/MacOS/RevengeRecompiled"
install_name_tool -change "$(brew --prefix sdl2-compat)/lib/libSDL2-2.0.0.dylib" \
    @rpath/libSDL2-2.0.0.dylib "$BIN"
install_name_tool -change "$(brew --prefix freetype)/lib/libfreetype.6.dylib" \
    @rpath/libfreetype.6.dylib "$BIN"
install_name_tool -add_rpath @executable_path/../Frameworks "$BIN"

# The build bakes an absolute Homebrew path in as the FIRST LC_RPATH. dyld searches rpaths in
# order, so @rpath/libSDL2-2.0.0.dylib resolved to /opt/homebrew and the vendored copies were
# never loaded -- `otool -L` still looked correct because it only shows the @rpath load
# commands. Drop every absolute Homebrew rpath so the bundle is genuinely self-contained.
while otool -l "$BIN" | grep -A2 LC_RPATH | grep -q "path $(brew --prefix)"; do
    RP="$(otool -l "$BIN" | grep -A2 LC_RPATH | awk -v p="$(brew --prefix)" '$1=="path" && index($2,p)==1 {print $2; exit}')"
    [ -n "$RP" ] || break
    install_name_tool -delete_rpath "$RP" "$BIN"
done

# install_name_tool invalidates arm64 signatures, so re-sign ad-hoc (inside out).
codesign --force --sign - "$FW"/*.dylib
codesign --force --sign - "$BIN"
codesign --force --sign - "$APP"

if otool -L "$BIN" "$FW"/*.dylib | grep -q "$(brew --prefix)"; then
    echo "error: bundle still references Homebrew paths" >&2; exit 1
fi
# Also check LC_RPATH: an @rpath load command is only as good as the search paths.
if otool -l "$BIN" | grep -A2 LC_RPATH | grep -q "path $(brew --prefix)"; then
    echo "error: bundle still has a Homebrew LC_RPATH; @rpath would resolve outside the app" >&2; exit 1
fi
echo "built $APP"
