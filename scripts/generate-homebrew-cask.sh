#!/usr/bin/env bash
# 根据 dist/ 的发布产物生成 Homebrew Cask，并可选推送到 homebrew-tap 仓库。
# 用法：
#   scripts/generate-homebrew-cask.sh            # 只生成到 dist/homebrew-tap/
#   scripts/generate-homebrew-cask.sh --push     # 生成并推送到 shidesheng0218/homebrew-tap
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="$root/dist"
metadata="$release_dir/release-metadata.json"
checksums="$release_dir/SHA256SUMS.txt"
tap_checkout="${TAP_CHECKOUT:-$release_dir/homebrew-tap}"

test -f "$metadata"
test -f "$checksums"

version="$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).version" "$metadata")"
sha256="$(awk 'NR == 1 { print $1 }' "$checksums")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid version in release metadata: $version" >&2
  exit 1
fi

mkdir -p "$tap_checkout/Casks"
cat > "$tap_checkout/Casks/deepseek-code.rb" <<RUBY
cask "deepseek-code" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/shidesheng0218/deepseek-code/releases/download/v#{version}/DeepSeek-Code-#{version}-arm64.dmg"
  name "DeepSeek Code"
  desc "Local-first macOS coding agent with BYOK providers, durable sessions and verifiable delivery"
  homepage "https://github.com/shidesheng0218/deepseek-code"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "DeepSeek Code.app"

  caveats <<~EOS
    DeepSeek Code 社区构建使用 adhoc 签名（未购买 Apple Developer ID）。
    首次启动前执行一次：
      xattr -dr com.apple.quarantine "/Applications/DeepSeek Code.app"
    或在 Finder 中右键 App 选择"打开"。之后正常使用，自动更新不受影响。
  EOS

  zap trash: [
    "~/Library/Application Support/DeepSeekCode",
    "~/Library/Application Support/deepseek-code-desktop",
  ]
end
RUBY

echo "Cask written: $tap_checkout/Casks/deepseek-code.rb (v$version)"

if [[ "${1:-}" == "--push" ]]; then
  work="$(mktemp -d /tmp/deepseek-tap.XXXXXX)"
  trap 'rm -rf "$work"' EXIT
  git clone --depth 1 https://github.com/shidesheng0218/homebrew-tap "$work/tap"
  mkdir -p "$work/tap/Casks"
  cp "$tap_checkout/Casks/deepseek-code.rb" "$work/tap/Casks/deepseek-code.rb"
  git -C "$work/tap" add Casks/deepseek-code.rb
  if git -C "$work/tap" diff --cached --quiet; then
    echo "Cask already up to date."
  else
    git -C "$work/tap" -c user.name="${GIT_AUTHOR_NAME:-deepseek-release}" -c user.email="${GIT_AUTHOR_EMAIL:-release@localhost}" commit -m "Update deepseek-code to $version"
    git -C "$work/tap" push
    echo "Tap updated: shidesheng0218/homebrew-tap (v$version)"
  fi
fi
