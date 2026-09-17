#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# macOS can deny in-place writes to a previously signed/notarized UIReview
# binary (EPERM). Replacing the bundle first must still succeed.
if ! grep -q '^prepare_app_bundle()' scripts/build-app.sh; then
  echo "scripts/build-app.sh must define prepare_app_bundle()" >&2
  exit 1
fi
eval "$(sed -n '/^prepare_app_bundle()/,/^}/p' scripts/build-app.sh)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'NEW\n' > "$tmp/src"
app_dir="$tmp/UI Review.app"
mkdir -p "$app_dir/Contents/MacOS"
printf 'OLD\n' > "$app_dir/Contents/MacOS/UIReview"

profile="$tmp/seatbelt.sb"
cat > "$profile" <<'EOF'
(version 1)
(allow default)
(deny file-write-data (regex #"UIReview$"))
EOF

if sandbox-exec -f "$profile" cp "$tmp/src" "$app_dir/Contents/MacOS/UIReview" 2>"$tmp/cp.err"; then
  echo "expected in-place cp to fail under write-data denial" >&2
  exit 1
fi
if ! grep -q 'Operation not permitted' "$tmp/cp.err"; then
  echo "expected Operation not permitted, got: $(cat "$tmp/cp.err")" >&2
  exit 1
fi

sandbox-exec -f "$profile" /bin/bash -c "
  set -euo pipefail
  $(sed -n '/^prepare_app_bundle()/,/^}/p' scripts/build-app.sh)
  prepare_app_bundle '$app_dir'
  cp '$tmp/src' '$app_dir/Contents/MacOS/UIReview'
"

test "$(cat "$app_dir/Contents/MacOS/UIReview")" = "NEW"
test -d "$app_dir/Contents/Resources"
test -d "$app_dir/Contents/Frameworks"
echo "ok"
