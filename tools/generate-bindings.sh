#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
app_dir="$repo_root/app"
header="$repo_root/engine/bindings/crazycut.h"
config="$app_dir/ffigen.yaml"
output="$app_dir/lib/engine/crazycut_bindings_generated.dart"

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: flutter is required to generate CrazyCut bindings" >&2
  exit 1
fi

if [[ ! -f "$header" || ! -f "$config" ]]; then
  echo "error: binding header or ffigen configuration is missing" >&2
  exit 1
fi

cd "$app_dir"
flutter pub get
flutter pub run ffigen --config ffigen.yaml

echo "Generated ${output#"$repo_root/"} from ${header#"$repo_root/"}"
