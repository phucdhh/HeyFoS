#!/bin/bash
# make-release.sh — Build and package HeyFoS.app for Apple Silicon (macOS 14+)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="1.0.0"
APP_NAME="HeyFoS"
BUNDLE_ID="com.heyfos.desktop"
RELEASE_DIR="$SCRIPT_DIR/release"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
ZIP_NAME="${APP_NAME}-${VERSION}-arm64.zip"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  HeyFoS Desktop — Release Builder v$VERSION"
echo "  Platform : macOS 14+ · Apple Silicon (arm64)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Check requirements ────────────────────────────────────────────────────
echo ""
echo "▸ Checking build requirements…"

if ! command -v swift &>/dev/null; then
    echo "  ✗ swift not found. Install Xcode or the Swift toolchain."
    exit 1
fi
if ! brew list libraw &>/dev/null 2>&1; then
    echo "  ⚠  libraw not found via Homebrew. Installing…"
    brew install libraw
fi
echo "  ✓ Requirements met"

# ── 2. Build release binary ──────────────────────────────────────────────────
echo ""
echo "▸ Building HeyFoSApp (release · arm64)…"
swift build -c release --arch arm64 --product HeyFoS 2>&1 | \
    grep -E "error:|warning:|Build complete|Compiling|Linking" | \
    sed 's/^/  /'

BINARY_PATH="$SCRIPT_DIR/.build/release/$APP_NAME"
if [ ! -f "$BINARY_PATH" ]; then
    echo "  ✗ Build failed — binary not found at $BINARY_PATH"
    exit 1
fi
echo "  ✓ Binary built: $(du -sh "$BINARY_PATH" | cut -f1)"

# ── 3. Assemble .app bundle ──────────────────────────────────────────────────
echo ""
echo "▸ Assembling ${APP_NAME}.app bundle…"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Write Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>         <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>         <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>               <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>        <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>            <string>100</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>LSApplicationCategoryType</key>  <string>public.app-category.photography</string>
    <key>NSDocumentsFolderUsageDescription</key>
        <string>HeyFoS needs access to your images to perform focus stacking.</string>
    <key>NSDesktopFolderUsageDescription</key>
        <string>HeyFoS saves the result to your Desktop by default.</string>
    <key>NSDownloadsFolderUsageDescription</key>
        <string>HeyFoS can load images from Downloads.</string>
    <key>CFBundleSupportedPlatforms</key>
        <array><string>MacOSX</string></array>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "  ✓ Bundle structure created"

# ── 4. Bundle Homebrew dynamic libraries ─────────────────────────────────────
echo ""
echo "▸ Bundling dynamic libraries…"
FRAMEWORKS="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

# Copy a Homebrew dylib and fix its install name + transitive deps.
bundle_dylib() {
    local src="$1"
    local name
    name=$(basename "$src")
    local dst="$FRAMEWORKS/$name"
    [[ -f "$dst" ]] && return 0
    cp "$src" "$dst"
    chmod +w "$dst"
    install_name_tool -id "@rpath/$name" "$dst"
    while read -r raw_dep; do
        local dep dep_name
        dep=$(echo "$raw_dep" | awk '{print $1}')
        [[ "$dep" == /opt/homebrew* ]] || continue
        dep_name=$(basename "$dep")
        bundle_dylib "$dep"
        install_name_tool -change "$dep" "@rpath/$dep_name" "$dst"
    done < <(otool -L "$dst" | tail -n +2)
}

bundle_dylib "$(brew --prefix libraw)/lib/libraw.24.dylib"

# Fix the main binary's Homebrew references
BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
while read -r raw_dep; do
    dep=$(echo "$raw_dep" | awk '{print $1}')
    [[ "$dep" == /opt/homebrew* ]] || continue
    dep_name=$(basename "$dep")
    install_name_tool -change "$dep" "@rpath/$dep_name" "$BIN"
    echo "  fixed: $dep → @rpath/$dep_name"
done < <(otool -L "$BIN" | tail -n +2)
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" 2>/dev/null || true

DYLIB_COUNT=$(ls "$FRAMEWORKS" | wc -l | tr -d ' ')
echo "  ✓ Bundled ${DYLIB_COUNT} dylib(s): $(ls "$FRAMEWORKS" | tr '\n' ' ')"
REMAINING=$(otool -L "$BIN" | grep -c "/opt/homebrew" || true)
[[ "$REMAINING" -eq 0 ]] && echo "  ✓ No Homebrew absolute paths remain in binary" || echo "  ✗ WARNING: $REMAINING Homebrew path(s) still in binary!"

# ── 5. Ad-hoc code sign ──────────────────────────────────────────────────────
echo ""
echo "▸ Ad-hoc code signing (no notarization)…"
codesign --force --sign - --deep --timestamp=none "$APP_BUNDLE" 2>&1 | sed 's/^/  /'
echo "  ✓ Signed"

# ── 6. Create ZIP ────────────────────────────────────────────────────────────
echo ""
echo "▸ Creating ${ZIP_NAME}…"
cd "$RELEASE_DIR"
rm -f "$ZIP_NAME"
zip -r --quiet "$ZIP_NAME" "${APP_NAME}.app"
ZIP_SIZE=$(du -sh "$ZIP_NAME" | cut -f1)
echo "  ✓ Archive: release/$ZIP_NAME ($ZIP_SIZE)"
cd "$SCRIPT_DIR"

# ── 7. Substitute index.html template (Vapor serves from release/) ────────────
echo ""
echo "▸ Generating release/index.html…"
sed -i '' "s/__ZIP_NAME__/${ZIP_NAME}/g;s/__VERSION__/${VERSION}/g" \
    "$RELEASE_DIR/index.html"
echo "  ✓ release/index.html ready (href → ${ZIP_NAME})"

# ── 8. Copy to frontend/build/release (static fallback) ─────────────────────
echo ""
echo "▸ Publishing to frontend/build/release/…"
FRONTEND_RELEASE="$SCRIPT_DIR/frontend/build/release"
mkdir -p "$FRONTEND_RELEASE"
cp "$RELEASE_DIR/$ZIP_NAME" "$FRONTEND_RELEASE/"
cp "$RELEASE_DIR/index.html" "$FRONTEND_RELEASE/"
echo "  ✓ Files copied → frontend/build/release/"

# ── 9. Summary ───────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done!  HeyFoS v${VERSION} is ready."
echo ""
echo "  App bundle : release/${APP_NAME}.app"
echo "  Download   : release/${ZIP_NAME} (${ZIP_SIZE})"
echo "  Download URL: https://heyfos.truyenthong.edu.vn/release/"
echo ""
echo "  Installation instructions:"
echo "  1. Download ${ZIP_NAME}"
echo "  2. Double-click to extract → HeyFoS.app"
echo "  3. Move HeyFoS.app to /Applications"
echo "  4. Right-click → Open (first launch only — bypasses Gatekeeper)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
