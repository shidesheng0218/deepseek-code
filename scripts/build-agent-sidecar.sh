#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundled_bun="$root/node_modules/@oven/bun-darwin-aarch64/bin/bun"

# The bundled compiler currently targets Apple Silicon only.
case "$(uname -sm)" in
  "Darwin arm64") ;;
  *) echo "Unsupported local runtime target: $(uname -sm). This script builds with @oven/bun-darwin-aarch64 (Apple Silicon only); to support Intel, add @oven/bun-darwin-x64 to optionalDependencies and extend this case." >&2; exit 1 ;;
esac

if [[ ! -x "$bundled_bun" ]]; then
  echo "The bundled Bun compiler is unavailable. Run npm ci at the repository root." >&2
  exit 1
fi

runtime="$root/apps/deepseek-agent-runtime"
mkdir -p "$runtime/dist"
"$bundled_bun" build "$runtime/src/main.ts" --compile --outfile "$runtime/dist/deepseek-agent-runtime"
chmod +x "$runtime/dist/deepseek-agent-runtime"
