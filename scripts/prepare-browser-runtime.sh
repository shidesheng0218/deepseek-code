#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_cache="$HOME/Library/Caches/ms-playwright"
source_dir="${DEEPSEEK_BROWSER_RUNTIME_SOURCE:-}"
target_dir="${DEEPSEEK_BROWSER_RUNTIME_DIR:-$root/apps/deepseek-code-desktop/src-tauri/resources/browser}"

if [[ -z "$source_dir" ]]; then
  candidate="$(find "$default_cache" -maxdepth 5 -type f -path '*/chrome-headless-shell-mac-arm64/chrome-headless-shell' -print 2>/dev/null | sort | tail -1 || true)"
  if [[ -n "$candidate" ]]; then source_dir="$(dirname "$candidate")"; fi
fi

if [[ -z "$source_dir" || ! -x "$source_dir/chrome-headless-shell" ]]; then
  echo "Chromium headless-shell is unavailable. Install it with: npx playwright install chromium" >&2
  exit 1
fi

mkdir -p "$target_dir"
rsync -a --delete "$source_dir/" "$target_dir/"
echo "Prepared bundled browser runtime: $target_dir"
