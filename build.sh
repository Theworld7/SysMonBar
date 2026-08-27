#!/usr/bin/env bash
#
# build.sh — 一键 build + 打包 SysMonBar.app
#
# 用法：
#   ./build.sh           # build + 注入图标 + 生成 zip
#   ./build.sh --no-zip  # 只 build + 注图标，不打 zip
#
# 输出：
#   build/Build/Products/Release/SysMonBar.app
#   SysMonBar-v<MARKETING_VERSION>.zip
#
# 不需要 Developer ID 账号。ad-hoc 本地签名（CODE_SIGNING_ALLOWED=NO），
# 用户首次打开需在"系统设置 → 隐私与安全性"点"仍要打开"。

set -euo pipefail

# 切到脚本所在目录（项目根）
cd "$(dirname "$0")"

# 配置
APP_NAME="SysMonBar"
OUTPUT_DIR="build/Build/Products/Release"

# 从 xcodeproj 的 build setting 读 MARKETING_VERSION，避免解析未生成的 Info.plist
VERSION=$(xcodebuild -project "${PWD}/${APP_NAME}.xcodeproj" -showBuildSettings \
    -configuration Release 2>/dev/null \
    | awk -F' = ' '/MARKETING_VERSION/ {print $2; exit}')
echo "VERSION read from build settings: '${VERSION}'"
VERSION="${VERSION:-1.0.0}"
APP_PATH="${OUTPUT_DIR}/${APP_NAME}.app"
ZIP_PATH="${APP_NAME}-v${VERSION}.zip"

echo "==> Building ${APP_NAME} ${VERSION} (Release, ad-hoc signed)..."
xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="${VERSION}" \
    build 2>&1 | tail -5

if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: ${APP_PATH} not found. Build failed." >&2
    exit 1
fi

echo "==> Injecting app icon (.icns)..."
ICONSET_DIR="$(mktemp -d)/${APP_NAME}.iconset"
mkdir -p "${ICONSET_DIR}"

# 从 AppIcon.appiconset/ 拷贝所有尺寸到 iconset 标准命名
cp "SysMonBar/Assets.xcassets/AppIcon.appiconset/AppIcon-16.png"   "${ICONSET_DIR}/icon_16x16.png"
cp "SysMonBar/Assets.xcassets/AppIcon.appiconset/AppIcon-32.png"   "${ICONSET_DIR}/icon_16x16@2x.png"
cp "SysMonBar/Assets.xcassets/AppIcon.appiconset/AppIcon-32.png"   "${ICONSET_DIR}/icon_32x32.png"
cp "SysMonBar/Assets.xcassets/AppIcon.appiconset/AppIcon-64.png"   "${ICONSET_DIR}/icon_32x32@2x.png"
cp "SysMonBar/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png"  "${ICONSET_DIR}/icon_128x128.png"
cp "SysMonBar/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png"  "${ICONSET_DIR}/icon_128x128@2x.png"
cp "SysMonBar/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png"  "${ICONSET_DIR}/icon_256x256.png"
cp "SysMonBar/Assets.xcassets/AppIcon.appiconset/AppIcon-512.png"  "${ICONSET_DIR}/icon_256x256@2x.png"
cp "SysMonBar/Assets.xcassets/AppIcon.appiconset/AppIcon-512.png"  "${ICONSET_DIR}/icon_512x512.png"
cp "SysMonBar/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" "${ICONSET_DIR}/icon_512x512@2x.png"

ICNS_PATH="${OUTPUT_DIR}/${APP_NAME}.icns"
iconutil -c icns "${ICONSET_DIR}" -o "${ICNS_PATH}"
cp "${ICNS_PATH}" "${APP_PATH}/Contents/Resources/${APP_NAME}.icns"
rm -rf "$(dirname "${ICONSET_DIR}")"

# 在 Info.plist 注册图标（已存在则覆盖）
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string ${APP_NAME}" \
    "${APP_PATH}/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ${APP_NAME}" \
       "${APP_PATH}/Contents/Info.plist"

# 重新注册到 Launch Services（让 Finder 立即看到新图标）
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
"${LSREGISTER}" -f "${APP_PATH}" > /dev/null 2>&1 || true

echo "==> Done. App: ${APP_PATH}"

if [[ "${1:-}" == "--no-zip" ]]; then
    exit 0
fi

echo "==> Creating zip: ${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo ""
echo "✓ Built ${APP_NAME} ${VERSION}"
echo "  App:  ${APP_PATH}"
echo "  Zip:  ${ZIP_PATH}"
echo ""
echo "Upload ${ZIP_PATH} to your GitHub release."