#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: scripts/package-app.sh [--skip-build] [--skip-notarize] [--install]

Build a Developer ID signed, notarized installer that always installs to
/Applications/UI Review.app. Also writes Sparkle's GitHub Release zip and
appcast to build/sparkle/.

  --skip-build      Reuse the existing release app bundle
  --skip-notarize   Sign the pkg but do not submit it to Apple
  --install         Forget any previous receipt and install to /Applications

Environment:
  CODESIGN_IDENTITY   Developer ID Application identity
  PKG_IDENTITY        Developer ID Installer identity
  NOTARY_PROFILE      notarytool keychain profile
EOF
}

skip_build=0
skip_notarize=0
do_install=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) skip_build=1 ;;
    --skip-notarize) skip_notarize=1 ;;
    --install) do_install=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

codesign_identity="${CODESIGN_IDENTITY:-Developer ID Application: Farqan Ali (SW58YL2DDN)}"
pkg_identity="${PKG_IDENTITY:-Developer ID Installer: Shenzhen Rayvision Technology Co., Ltd. (CYR85GCQD9)}"
notary_profile="${NOTARY_PROFILE:-support2@rayvision.com}"
bundle_id="dev.uireview.mac"
app_name="UI Review.app"
app_dir="$PWD/build/$app_name"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
pkg_path="$PWD/build/UI Review-$version.pkg"

if [ "$skip_build" -eq 0 ]; then
  bash scripts/build-app.sh release
fi
if [ ! -d "$app_dir" ]; then
  echo "Missing app bundle: $app_dir" >&2
  exit 1
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
if [ ! -d "$app_dir/Contents/Frameworks/Sparkle.framework" ]; then
  echo "Missing Sparkle.framework in app bundle. Rebuild with scripts/build-app.sh." >&2
  exit 1
fi
sign_sparkle "$codesign_identity" --options runtime --timestamp
codesign --force --options runtime --timestamp --sign "$codesign_identity" "$app_dir/Contents/MacOS/ui-review-mcp"
codesign --force --options runtime --timestamp --sign "$codesign_identity" "$app_dir/Contents/MacOS/UIReview"
codesign --force --options runtime --timestamp --sign "$codesign_identity" "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

root_dir="$(mktemp -d)"
plist_path="$(mktemp)"
trap 'rm -rf "$root_dir" "$plist_path"' EXIT
ditto "$app_dir" "$root_dir/$app_name"
pkgbuild --analyze --root "$root_dir" "$plist_path"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$plist_path"

rm -f "$pkg_path"
pkgbuild \
  --identifier "$bundle_id" \
  --version "$version" \
  --install-location /Applications \
  --root "$root_dir" \
  --component-plist "$plist_path" \
  --scripts "$PWD/scripts/pkg" \
  --sign "$pkg_identity" \
  "$pkg_path"

info_dir="$(mktemp -d)"
trap 'rm -rf "$root_dir" "$plist_path" "$info_dir"' EXIT
xar -xf "$pkg_path" -C "$info_dir" PackageInfo
if awk '/<relocate/,/<\/relocate>|<relocate\/>/' "$info_dir/PackageInfo" | grep -q '<bundle'; then
  echo "Package is still relocatable; refusing to distribute." >&2
  cat "$info_dir/PackageInfo" >&2
  exit 1
fi
if ! grep -q 'install-location="/Applications"' "$info_dir/PackageInfo"; then
  echo "Package install-location is not /Applications." >&2
  cat "$info_dir/PackageInfo" >&2
  exit 1
fi
if ! xar -tf "$pkg_path" | grep -qx Scripts; then
  echo "Package is missing Scripts/postinstall." >&2
  exit 1
fi

if [ "$skip_notarize" -eq 0 ]; then
  xcrun notarytool submit "$pkg_path" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$pkg_path"
  xcrun stapler staple "$app_dir"
  xcrun stapler validate "$pkg_path"
fi

echo "$pkg_path"

sparkle_dir="$PWD/build/sparkle"
rm -rf "$sparkle_dir"
mkdir -p "$sparkle_dir"
zip_path="$sparkle_dir/UIReview-$version.zip"
ditto -c -k --keepParent "$app_dir" "$zip_path"
notes="docs/releases/UIReview-$version.md"
if [ -f "$notes" ]; then
  cp "$notes" "$sparkle_dir/UIReview-$version.md"
fi
generate_appcast="$PWD/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [ ! -x "$generate_appcast" ]; then
  generate_appcast="$(find "$PWD/.build" -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' | head -n 1 || true)"
fi
if [ -z "$generate_appcast" ] || [ ! -x "$generate_appcast" ]; then
  echo "generate_appcast not found under .build" >&2
  exit 1
fi
"$generate_appcast" \
  --account ui-review \
  --download-url-prefix "https://github.com/Sim-hub-ios/ui_review_tools/releases/download/v$version/" \
  --maximum-deltas 0 \
  -o "$sparkle_dir/appcast.xml" \
  "$sparkle_dir"
echo "$zip_path"
echo "$sparkle_dir/appcast.xml"
echo "Publish with: bash scripts/publish-release.sh"

if [ "$do_install" -eq 1 ]; then
  sudo pkgutil --forget "$bundle_id" >/dev/null 2>&1 || true
  sudo installer -pkg "$pkg_path" -target /
  if [ ! -d "/Applications/$app_name" ]; then
    echo "Install finished, but /Applications/$app_name is missing." >&2
    exit 1
  fi
  echo "/Applications/$app_name"
fi
