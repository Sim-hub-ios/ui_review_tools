#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: scripts/publish-release.sh [--package] [--skip-notarize] [--dry-run]

Upload the current version's pkg, Sparkle zip, and appcast to GitHub Releases.
Creates tag v<version> if needed; existing releases are updated in place.
The uploaded installer is named UIReview-<version>.pkg (no spaces).

  --package         Run scripts/package-app.sh first
  --skip-notarize   Passed to package-app.sh when --package is set
  --dry-run         Print the gh command without uploading

Environment:
  RELEASE_ROOT        Directory that contains build/ artifacts (default: repo root)
  GITHUB_REPOSITORY   owner/name (default: Sim-hub-ios/ui_review_tools)
EOF
}

do_package=0
skip_notarize=0
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --package) do_package=1 ;;
    --skip-notarize) skip_notarize=1 ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$do_package" -eq 1 ]; then
  if [ "$skip_notarize" -eq 1 ]; then
    bash scripts/package-app.sh --skip-notarize
  else
    bash scripts/package-app.sh
  fi
fi

root="${RELEASE_ROOT:-$PWD}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
repo="${GITHUB_REPOSITORY:-Sim-hub-ios/ui_review_tools}"
pkg_path="$root/build/UI Review-$version.pkg"
upload_pkg="$root/build/UIReview-$version.pkg"
zip_path="$root/build/sparkle/UIReview-$version.zip"
appcast="$root/build/sparkle/appcast.xml"
notes="$root/docs/releases/UIReview-$version.md"
tag="v$version"

for path in "$pkg_path" "$zip_path" "$appcast"; do
  if [ ! -f "$path" ]; then
    echo "Missing release artifact: $path" >&2
    echo "Build with: bash scripts/package-app.sh" >&2
    exit 1
  fi
done

if [ "$dry_run" -eq 0 ]; then
  cp "$pkg_path" "$upload_pkg"
fi

gh_create=(release create "$tag" --repo "$repo" --title "UI Review $version")
gh_upload=(release upload "$tag" --repo "$repo" --clobber "$upload_pkg" "$zip_path" "$appcast")
if [ -f "$notes" ]; then
  gh_create+=(--notes-file "$notes")
  notes_flag="--notes-file \"$notes\""
else
  gh_create+=(--notes "UI Review $version")
  notes_flag="--notes \"UI Review $version\""
fi
gh_create+=("$upload_pkg" "$zip_path" "$appcast")

create_command="gh release create \"$tag\" --repo $repo --title \"UI Review $version\" $notes_flag \"$upload_pkg\" \"$zip_path\" \"$appcast\""
upload_command="gh release upload \"$tag\" --repo $repo --clobber \"$upload_pkg\" \"$zip_path\" \"$appcast\""
if [ "$dry_run" -eq 1 ]; then
  echo "$create_command"
  echo "$upload_command"
  exit 0
fi

if [ -z "${GH_TOKEN:-}" ]; then
  if token="$(gh auth token -u Sim-hub-ios 2>/dev/null)"; then
    export GH_TOKEN="$token"
  fi
fi
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  gh "${gh_upload[@]}"
else
  gh "${gh_create[@]}"
fi
echo "https://github.com/$repo/releases/tag/$tag"
