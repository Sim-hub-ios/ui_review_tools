#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/test-app-bundle-replace.sh
bash scripts/test-pkg-postinstall.sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift test --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --disable-sandbox
python3 scripts/test-mcp.py .build/debug/ui-review-mcp
