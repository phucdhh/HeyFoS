#!/bin/bash
# HeyFoS - Build Script (Apple Silicon Release)
# Builds, bundles, signs, and packages HeyFoS into a distributable zip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="HeyFoS"
APP_VERSION="1.0.0"
APP_BUNDLE="$SCRIPT_DIR/release/$APP_NAME.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_FRAMEWORKS="$APP_BUNDLE/Contents/Frameworks"
BUILT_BINARY="$SCRIPT_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
ZIP_NAME="${APP_NAME}-${APP_VERSION}-arm64.zip"
ZIP_PATH="$SCRIPT_DIR/release/$ZIP_NAME"

echo "🔨 Building $APP_NAME $APP_VERSION for Apple Silicon (release)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Dependencies ─────────────────────────────────────────────────────────
if ! brew list libraw &>/dev/null; then
    echo "📦 Installing libraw dependency..."
    brew install libraw
fi

# ── 2. Compile ───────────────────────────────────────────────────────────────
swift build -c release --arch arm64 2>&1
echo ""

# ── 3. Copy binary into bundle ───────────────────────────────────────────────
echo "📦 Updating app bundle..."
cp "$BUILT_BINARY" "$APP_MACOS"

# ── 4. Re-bundle the dylibs (pick up any version bumps from Homebrew) ────────
mkdir -p "$APP_FRAMEWORKS"

copy_and_fix_id() {
    local src="$1" dylib="$2"
    local dst="$APP_FRAMEWORKS/$dylib"
    [[ -f "$src" ]] || return 0
    cp "$src" "$dst"
    chmod 644 "$dst"
    install_name_tool -id "@rpath/$dylib" "$dst"
}

copy_and_fix_id "$(brew --prefix libraw)/lib/libraw.24.dylib"       "libraw.24.dylib"
copy_and_fix_id "$(brew --prefix jpeg-turbo)/lib/libjpeg.8.dylib"   "libjpeg.8.dylib"
copy_and_fix_id "$(brew --prefix little-cms2)/lib/liblcms2.2.dylib" "liblcms2.2.dylib"
copy_and_fix_id "$(brew --prefix libomp)/lib/libomp.dylib"          "libomp.dylib"

# ── 5. Patch all Homebrew-absolute load paths inside each bundled dylib ───────
patch_homebrew_refs() {
    local file="$1"
    # Collect all LC_LOAD_DYLIB entries that point to /opt/homebrew
    while IFS= read -r brew_path; do
        local basename
        basename="$(basename "$brew_path")"
        if [[ -f "$APP_FRAMEWORKS/$basename" ]]; then
            install_name_tool -change "$brew_path" "@loader_path/$basename" "$file" 2>/dev/null || true
        fi
    done < <(otool -L "$file" | awk '/\/opt\/homebrew/{print $1}')
}

for f in "$APP_FRAMEWORKS"/*.dylib; do
    patch_homebrew_refs "$f"
done

# ── 6. Patch the main binary's Homebrew paths → bundle-relative ─────────────
while IFS= read -r brew_path; do
    basename="$(basename "$brew_path")"
    install_name_tool -change "$brew_path" \
        "@executable_path/../Frameworks/$basename" \
        "$APP_MACOS" 2>/dev/null || true
done < <(otool -L "$APP_MACOS" | awk '/\/opt\/homebrew/{print $1}')

# ── 7. Ad-hoc sign the whole bundle (required after any binary edit) ─────────
codesign --force --deep --sign - "$APP_BUNDLE"

# Remove quarantine so macOS doesn't warn on first launch
xattr -rd com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

# ── 8. Package into zip ───────────────────────────────────────────────────────
echo "🗜  Creating $ZIP_NAME..."
rm -f "$ZIP_PATH"
# ditto preserves resource forks and HFS+ metadata; --keepParent puts the
# .app at the root of the zip (same behaviour as Finder "Compress")
ditto -c -k --keepParent --sequesterRsrc "$APP_BUNDLE" "$ZIP_PATH"

echo ""
echo "✅ Done!"
echo "   App bundle : $APP_BUNDLE"
echo "   Zip        : $ZIP_PATH ($(du -sh "$ZIP_PATH" | cut -f1))"
echo ""
echo "👉 Quit any running HeyFoS, then: open '$APP_BUNDLE'"
