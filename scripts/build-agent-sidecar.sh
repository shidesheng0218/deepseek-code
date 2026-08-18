#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundled_bun="$root/node_modules/@oven/bun-darwin-aarch64/bin/bun"

if [[ ! -x "$bundled_bun" ]]; then
  echo "The bundled Bun compiler is unavailable. Run npm install at the repository root." >&2
  exit 1
fi

case "$(uname -sm)" in
  "Darwin arm64") target="aarch64-apple-darwin" ;;
  "Darwin x86_64") target="x86_64-apple-darwin" ;;
  *) echo "Unsupported local sidecar target: $(uname -sm)" >&2; exit 1 ;;
esac

runtime="$root/apps/deepseek-agent-runtime"
binaries="$root/apps/deepseek-code-desktop/src-tauri/binaries"
mkdir -p "$runtime/dist" "$binaries"
"$bundled_bun" build "$runtime/src/main.ts" --compile --outfile "$runtime/dist/deepseek-agent-runtime"
cp "$runtime/dist/deepseek-agent-runtime" "$binaries/deepseek-agent-runtime-$target"
chmod +x "$binaries/deepseek-agent-runtime-$target"
