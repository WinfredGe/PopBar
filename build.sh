#!/bin/bash
# PopBar 一键构建脚本:编译 → 组装 .app → 用自签名证书签名 → 安装到 /Applications → 重启
#
# 用法: ./build.sh
#
# 签名身份是钥匙串里的 "PopBar Code Signing" 自签名证书。
# 只要证书不变,TCC 辅助功能授权在更新后依然有效,无需重新勾选。
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="PopBar Code Signing"
APP=/Applications/PopBar.app

echo "==> 编译"
BUILD=$(mktemp -d)/PopBar.app
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
swiftc -O Sources/*.swift -o "$BUILD/Contents/MacOS/PopBar" \
  -framework Cocoa -framework ApplicationServices \
  -target arm64-apple-macosx15.0

echo "==> 组装"
cp Info.plist "$BUILD/Contents/Info.plist"
cp AppIcon.icns "$BUILD/Contents/Resources/AppIcon.icns"

echo "==> 签名 ($IDENTITY)"
codesign --force -s "$IDENTITY" "$BUILD"

echo "==> 安装到 $APP"
pkill -f "$APP/Contents/MacOS/PopBar" 2>/dev/null || true
sleep 1
rm -rf "$APP"
cp -R "$BUILD" "$APP"

echo "==> 启动"
open "$APP"
echo "完成"
