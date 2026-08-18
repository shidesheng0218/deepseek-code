#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_cache="$HOME/Library/Caches/ms-playwright"
source_dir="${DEEPSEEK_BROWSER_RUNTIME_SOURCE:-}"
target_dir="${DEEPSEEK_BROWSER_RUNTIME_DIR:-$root/apps/deepseek-code-desktop/src-tauri/resources/browser}"
playwright_source="${DEEPSEEK_PLAYWRIGHT_MODULE_SOURCE:-$root/node_modules/playwright-core}"
playwright_target="${DEEPSEEK_PLAYWRIGHT_MODULE_DIR:-$root/apps/deepseek-code-desktop/src-tauri/resources/playwright-core}"

if [[ -z "$source_dir" ]]; then
  candidate="$(find "$default_cache" -maxdepth 5 -type f -path '*/chrome-headless-shell-mac-arm64/chrome-headless-shell' -print 2>/dev/null | sort | tail -1 || true)"
  if [[ -n "$candidate" ]]; then source_dir="$(dirname "$candidate")"; fi
fi

if [[ -z "$source_dir" || ! -x "$source_dir/chrome-headless-shell" ]]; then
  echo "Chromium headless-shell is unavailable. Install it with: npx playwright install chromium" >&2
  exit 1
fi
if [[ ! -f "$playwright_source/index.js" ]]; then
  echo "Playwright Core is unavailable. Install root dependencies with: npm ci" >&2
  exit 1
fi

mkdir -p "$target_dir"
rsync -a --delete "$source_dir/" "$target_dir/"
mkdir -p "$playwright_target"
rsync -a --delete "$playwright_source/" "$playwright_target/"
echo "Prepared bundled browser runtime: $target_dir and $playwright_target"
