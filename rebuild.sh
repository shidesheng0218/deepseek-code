#!/usr/bin/env bash
# 快速重新编译并安装 DeepSeek Code
set -euo pipefail

echo "🔨 开始构建 DeepSeek Code..."
echo ""

# 执行构建脚本
./scripts/build-macos-app.sh

echo ""
echo "🎉 完成！新版本已自动安装并替换旧版本"
echo "💡 提示：如果应用正在运行，它已被自动关闭，请重新打开"
