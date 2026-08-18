#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$(mktemp -d)"
target_dir="$(mktemp -d)/browser"
module_source="$(mktemp -d)/playwright-core"
module_target="$(mktemp -d)/playwright-core"
mkdir -p "$source_dir"
mkdir -p "$module_source"
printf '#!/usr/bin/env sh\nexit 0\n' > "$source_dir/chrome-headless-shell"
printf 'export const chromium = {}\n' > "$module_source/index.js"
chmod +x "$source_dir/chrome-headless-shell"

DEEPSEEK_BROWSER_RUNTIME_SOURCE="$source_dir" DEEPSEEK_BROWSER_RUNTIME_DIR="$target_dir" DEEPSEEK_PLAYWRIGHT_MODULE_SOURCE="$module_source" DEEPSEEK_PLAYWRIGHT_MODULE_DIR="$module_target" "$root/scripts/prepare-browser-runtime.sh"
test -x "$target_dir/chrome-headless-shell"
test -f "$module_target/index.js"

cache_home="$(mktemp -d)"
cache_source="$cache_home/Library/Caches/ms-playwright/chromium_headless_shell-9999/chrome-headless-shell-mac-arm64"
cache_target="$(mktemp -d)/browser"
mkdir -p "$cache_source"
printf '#!/usr/bin/env sh\nexit 0\n' > "$cache_source/chrome-headless-shell"
chmod +x "$cache_source/chrome-headless-shell"

HOME="$cache_home" DEEPSEEK_BROWSER_RUNTIME_DIR="$cache_target" DEEPSEEK_PLAYWRIGHT_MODULE_SOURCE="$module_source" DEEPSEEK_PLAYWRIGHT_MODULE_DIR="$(mktemp -d)/playwright-core" "$root/scripts/prepare-browser-runtime.sh"
test -x "$cache_target/chrome-headless-shell"
echo "Bundled browser runtime preparation checks passed"
