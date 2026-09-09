#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_dir/build/UI Review V2 Preview.app"
if [[ ! -d "$app_path" ]]; then
  echo '请先生成 build/UI Review V2 Preview.app。'
  exit 1
fi
open -n "$app_path" --args --data-dir "$project_dir/build/v2-preview-data"
