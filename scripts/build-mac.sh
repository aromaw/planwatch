#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "请在 Mac 上执行此脚本。Linux 可在 collector 目录运行 go test ./...。" >&2
  exit 1
fi
for tool in swift go xcrun codesign ditto; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "缺少 $tool。请安装 Xcode Command Line Tools 和 Go 1.22+。" >&2
    exit 1
  fi
done

swift test
(cd collector && go test ./...)

swift build -c release --arch arm64 --arch x86_64
binary_dir=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
app_path="$PWD/dist/PlanWatch.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$PWD/.build/collector"
cp "$binary_dir/PlanWatch" "$app_path/Contents/MacOS/PlanWatch"
for arch in arm64 amd64; do
  (cd collector && CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -buildvcs=false -trimpath -ldflags='-s -w' -o "../.build/collector/$arch" .)
done
xcrun lipo -create .build/collector/arm64 .build/collector/amd64 -output "$app_path/Contents/Resources/planwatch-collector"
cp scripts/Info.plist "$app_path/Contents/Info.plist"
xcrun swift scripts/make-icon.swift "$PWD/.build/AppIcon.iconset"
xcrun iconutil -c icns .build/AppIcon.iconset -o "$app_path/Contents/Resources/AppIcon.icns"

# A Developer ID can be supplied for distribution; local builds use an ad-hoc signature.
identity="${PLANWATCH_SIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none --sign "$identity" "$app_path/Contents/Resources/planwatch-collector"
codesign --force --options runtime --timestamp=none --sign "$identity" "$app_path"
codesign --verify --deep --strict "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$PWD/dist/PlanWatch-mac-universal.zip"
echo "已生成 $app_path"
echo "将 PlanWatch.app 拖到 Applications 文件夹后打开。"
