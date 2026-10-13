#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_dir/build/UI Review.app"
if [[ ! -d "$app_path" ]]; then
  echo '请先在项目目录运行 bash scripts/build-app.sh，生成 build/UI Review.app。' >&2
  exit 1
fi
open -n "$app_path" --args --data-dir "$project_dir/build/v2-preview-data"
