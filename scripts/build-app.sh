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
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/UIReview" "$app_dir/Contents/MacOS/UIReview"
cp "$bin_dir/ui-review-mcp" "$app_dir/Contents/MacOS/ui-review-mcp"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_dir/Contents/MacOS/ui-review-mcp"
codesign --force --sign - "$app_dir"
echo "$app_dir"
