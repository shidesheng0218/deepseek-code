#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

matches="$(
  cd "$ROOT_DIR"
  git ls-files --cached --others --exclude-standard \
    | rg -v '^(node_modules|dist|venv|macos/DeepSeekCode/\.build)/' \
    | xargs -r rg -l -i 'sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY' 2>/dev/null \
    || true
)"

if [[ -n "$matches" ]]; then
  echo "Potential credential material found in tracked or untracked files:" >&2
  printf '%s\n' "$matches" >&2
  exit 1
fi

echo "Secret scan passed"
