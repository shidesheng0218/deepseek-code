#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundled_bun="$root/node_modules/@oven/bun-darwin-aarch64/bin/bun"

# 编译器与目标架构必须来自同一个平台包。@oven/bun-darwin-aarch64 只在 Apple
# Silicon 上装得上（见根 package.json 的 optionalDependencies），所以这里只接受
# Darwin arm64；之前的 x86_64 分支会用 arm64 编译器产出被命名成 x86_64 的二进制。
case "$(uname -sm)" in
  "Darwin arm64") target="aarch64-apple-darwin" ;;
  *) echo "Unsupported local sidecar target: $(uname -sm). This script builds with @oven/bun-darwin-aarch64 (Apple Silicon only); to support Intel, add @oven/bun-darwin-x64 to optionalDependencies and extend this case." >&2; exit 1 ;;
esac

if [[ ! -x "$bundled_bun" ]]; then
  echo "The bundled Bun compiler is unavailable. Run npm install at the repository root." >&2
  exit 1
fi

runtime="$root/apps/deepseek-agent-runtime"
binaries="$root/apps/deepseek-code-desktop/src-tauri/binaries"
mkdir -p "$runtime/dist" "$binaries"
"$bundled_bun" build "$runtime/src/main.ts" --compile --outfile "$runtime/dist/deepseek-agent-runtime"
cp "$runtime/dist/deepseek-agent-runtime" "$binaries/deepseek-agent-runtime-$target"
chmod +x "$binaries/deepseek-agent-runtime-$target"
