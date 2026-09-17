#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2;; esac
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift_options=(--cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --disable-sandbox)
swift build "${swift_options[@]}" -c "$configuration"
bin_dir="$(swift build "${swift_options[@]}" -c "$configuration" --show-bin-path)"
app_dir="$PWD/build/UI Review.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
cp "$bin_dir/UIReview" "$app_dir/Contents/MacOS/UIReview"
cp "$bin_dir/ui-review-mcp" "$app_dir/Contents/MacOS/ui-review-mcp"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"

sparkle_framework=""
for candidate in "$PWD"/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework; do
  if [ -d "$candidate" ]; then sparkle_framework="$candidate"; break; fi
done
if [ -z "$sparkle_framework" ]; then
  sparkle_framework="$(find "$PWD/.build" -path '*Sparkle.xcframework/macos-*/Sparkle.framework' -type d | head -n 1 || true)"
fi
if [ -z "$sparkle_framework" ] || [ ! -d "$sparkle_framework" ]; then
  echo "Sparkle.framework not found under .build" >&2
  exit 1
fi
rm -rf "$app_dir/Contents/Frameworks/Sparkle.framework"
ditto "$sparkle_framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$app_dir/Contents/MacOS/UIReview" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$app_dir/Contents/MacOS/UIReview"
fi

sign_sparkle() {
  local identity="$1"
  shift
  local fw="$app_dir/Contents/Frameworks/Sparkle.framework/Versions/Current"
  codesign --force "$@" --sign "$identity" "$fw/XPCServices/Downloader.xpc"
  codesign --force "$@" --sign "$identity" "$fw/XPCServices/Installer.xpc"
  codesign --force "$@" --sign "$identity" "$fw/Updater.app"
  codesign --force "$@" --sign "$identity" "$fw/Autoupdate"
  codesign --force "$@" --sign "$identity" "$app_dir/Contents/Frameworks/Sparkle.framework"
}
sign_sparkle -
codesign --force --sign - "$app_dir/Contents/MacOS/ui-review-mcp"
codesign --force --sign - "$app_dir/Contents/MacOS/UIReview"
codesign --force --sign - "$app_dir"
echo "$app_dir"
