#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x scripts/pkg/postinstall ] || fail "scripts/pkg/postinstall must exist and be executable"
grep -q -- '--scripts' scripts/package-app.sh || fail "package-app.sh must pass --scripts to pkgbuild"

# shellcheck disable=SC1091
source scripts/pkg/postinstall

opened=0
signals=()
running=0
console_name="sim"
APP_PATH="/Applications/UI Review.app"
QUIT_WAIT_TRIES=4
QUIT_WAIT_SLEEP=0

console_user() { printf '%s\n' "$console_name"; }
user_uid() { printf '501\n'; }
is_process_running() { [ "$running" -eq 1 ]; }
signal_process() { signals+=("$1"); [ "$1" = TERM ] && running=0; return 0; }
open_app() { opened=1; }

opened=0
signals=()
running=0
console_name="root"
relaunch_after_install
[ "$opened" -eq 0 ] || fail "root console must not open the app"
[ "${#signals[@]}" -eq 0 ] || fail "root console must not signal UIReview"

opened=0
signals=()
running=0
console_name="loginwindow"
relaunch_after_install
[ "$opened" -eq 0 ] || fail "loginwindow must not open the app"

opened=0
signals=()
running=0
console_name="sim"
relaunch_after_install
[ "$opened" -eq 1 ] || fail "GUI session must open the app when it is not running"
[ "${#signals[@]}" -eq 0 ] || fail "must not signal UIReview when it is not running"

opened=0
signals=()
running=1
relaunch_after_install
[ "$opened" -eq 1 ] || fail "must open the app after quitting the old process"
[ "${signals[*]}" = "TERM" ] || fail "expected TERM only, got: ${signals[*]-}"

opened=0
signals=()
running=1
signal_process() { signals+=("$1"); return 0; }
relaunch_after_install
[ "$opened" -eq 1 ] || fail "must open even if the old process ignores TERM"
[ "${signals[*]}" = "TERM KILL" ] || fail "expected TERM then KILL, got: ${signals[*]-}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/root/UI Review.app"
printf 'payload\n' > "$tmp/root/UI Review.app/placeholder"
pkgbuild \
  --identifier dev.uireview.mac.postinstall-test \
  --version 0 \
  --install-location /Applications \
  --root "$tmp/root" \
  --scripts scripts/pkg \
  "$tmp/out.pkg" >/dev/null
pkgutil --expand "$tmp/out.pkg" "$tmp/expanded"
[ -x "$tmp/expanded/Scripts/postinstall" ] || fail "expanded pkg is missing executable Scripts/postinstall"
echo "ok"
