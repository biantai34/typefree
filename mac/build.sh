#!/bin/bash
# Build the install bundle used for local installation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR/dist/Typefree Install.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
PROJECT_PATH="$SCRIPT_DIR/VoicePolish.xcodeproj"
SCHEME="VoicePolish"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/VoicePolishDerived}"

# 本机私有构建参数（不进仓库）：试用服务器地址/证书指纹、签名身份。见 local.build.env.example。
# 没有这个文件也能编译——只是编出来的版本没有试用通道（开源自编译版就是这样）。
if [ -f "$SCRIPT_DIR/local.build.env" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/local.build.env"
fi
VP_TRIAL_API_BASE="${VP_TRIAL_API_BASE:-}"
VP_TRIAL_CERT_SHA256="${VP_TRIAL_CERT_SHA256:-}"
SIGNING_NOTE="Note: local builds are ad hoc signed; distribution still needs Developer ID signing and notarization."

print_summary() {
    local app_size
    app_size="$(du -sh "$APP_DIR" | cut -f1)"
    echo ""
    echo "✅ Typefree install bundle built successfully ($app_size)"
    echo "   Location: $APP_DIR"
    echo "   $SIGNING_NOTE"
    echo ""
    echo "To install:"
    echo "   bash \"$SCRIPT_DIR/scripts/install_app.sh\""
}

copy_xcode_build_to_dist() {
    local built_app="$1"

    codesign --verify --deep --strict "$built_app"

    rm -rf "$APP_DIR"
    mkdir -p "$(dirname "$APP_DIR")"
    ditto "$built_app" "$APP_DIR"
    xattr -cr "$APP_DIR" 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
    xattr -d "com.apple.fileprovider.fpfs#P" "$APP_DIR" 2>/dev/null || true

    if ! codesign --verify --deep --strict "$APP_DIR"; then
        echo "⚠️  Exported app picked up workspace metadata after copy; source app signature was verified before export."
    fi
}

# 本地构建也用 Developer ID 重签（与正式发版同一身份）：
# macOS 把麦克风/辅助功能授权绑在「bundle ID + 签名身份」上，
# 测试版与正式版签名一致，来回安装才不会反复要求重新授权。
DEVELOPER_ID_IDENTITY="${DEVELOPER_ID_IDENTITY:-}"

developer_id_available() {
    [ -n "$DEVELOPER_ID_IDENTITY" ] || return 1
    security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEVELOPER_ID_IDENTITY"
}

resign_with_developer_id() {
    local app="$1"
    local entitlements="$SCRIPT_DIR/Resources/VoicePolish.entitlements"
    # 与 release_dmg.sh 同序：先签 Sparkle 嵌套组件（由内到外），最后签 app 本体。
    # 本地构建不加 --timestamp（无需公证，离线也能签）。
    local sp_v="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    if [ -d "$sp_v" ]; then
        for xpc in "$sp_v/XPCServices/"*.xpc; do
            [ -e "$xpc" ] && codesign --force --options runtime --sign "$DEVELOPER_ID_IDENTITY" "$xpc"
        done
        [ -e "$sp_v/Autoupdate" ]  && codesign --force --options runtime --sign "$DEVELOPER_ID_IDENTITY" "$sp_v/Autoupdate"
        [ -e "$sp_v/Updater.app" ] && codesign --force --options runtime --sign "$DEVELOPER_ID_IDENTITY" "$sp_v/Updater.app"
        codesign --force --options runtime --sign "$DEVELOPER_ID_IDENTITY" "$app/Contents/Frameworks/Sparkle.framework"
    fi
    codesign --force --options runtime \
        --entitlements "$entitlements" \
        --sign "$DEVELOPER_ID_IDENTITY" "$app"
    codesign --verify --strict "$app"
}

xcode_signing_ready() {
    [ -d "/Applications/Xcode.app" ] || return 1
    [ -d "$PROJECT_PATH" ] || return 1

    local settings
    settings="$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -showBuildSettings 2>/dev/null)" || return 1

    local team
    local identity
    team="$(printf '%s\n' "$settings" | awk -F' = ' '/DEVELOPMENT_TEAM = / { print $2; exit }')"
    identity="$(printf '%s\n' "$settings" | awk -F' = ' '/CODE_SIGN_IDENTITY = / { print $2; exit }')"

    [ -n "$team" ] || return 1
    [ "$team" != "\"\"" ] || return 1
    [ -n "$identity" ] || return 1
    [ "$identity" != "-" ] || return 1
}

build_with_xcode() {
    echo "🔨 Building Typefree with Xcode-managed signing..."

    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        VP_TRIAL_API_BASE="$VP_TRIAL_API_BASE" \
        VP_TRIAL_CERT_SHA256="$VP_TRIAL_CERT_SHA256" \
        build
    local xcode_exit=$?
    if [ $xcode_exit -ne 0 ]; then
        echo "❌ xcodebuild failed with exit code $xcode_exit"
        return 1
    fi

    local built_app="$DERIVED_DATA_PATH/Build/Products/Release/Typefree.app"
    if [ ! -d "$built_app" ]; then
        echo "❌ Xcode build completed without producing $built_app"
        return 1
    fi

    if developer_id_available; then
        echo "🔏 Re-signing with Developer ID (same identity as official releases)..."
        resign_with_developer_id "$built_app"
        SIGNING_NOTE="Note: signed with Developer ID（与正式版同签名，覆盖安装不会重新要权限）."
        echo "✅ Signed with Developer ID identity"
    else
        local signing_line
        signing_line="$(codesign -dv --verbose=2 "$built_app" 2>&1 | awk -F= '/^Authority=Apple Development:/ { print $2; exit }')"
        SIGNING_NOTE="Note: build uses Xcode-managed signing (${signing_line:-Apple Development})."
        echo "✅ Signed with Xcode-managed Apple Development identity (Developer ID cert not found)"
    fi

    copy_xcode_build_to_dist "$built_app"
}

build_with_spm() {
    echo "🔨 Building Typefree with Swift Package Manager..."

    (cd "$SCRIPT_DIR" && swift build -c release)

    local bin="$SCRIPT_DIR/.build/release/Typefree"
    if [ ! -f "$bin" ]; then
        echo "❌ SPM build completed without producing $bin"
        return 1
    fi

    local sparkle_framework
    sparkle_framework="$(find "$SCRIPT_DIR/.build" -name "Sparkle.framework" -type d | grep "arm64" | head -n 1)"
    if [ -z "$sparkle_framework" ]; then
        sparkle_framework="$(find "$SCRIPT_DIR/.build" -name "Sparkle.framework" -type d | head -n 1)"
    fi
    if [ -z "$sparkle_framework" ]; then
        echo "❌ Could not locate Sparkle.framework in .build"
        return 1
    fi

    rm -rf "$APP_DIR" "$SCRIPT_DIR/dist/Typefree.app"
    mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

    cp "$bin" "$MACOS/Typefree"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/Typefree" 2>/dev/null || true

    # Process Info.plist
    sed -e "s/\$(VP_TRIAL_API_BASE)/$VP_TRIAL_API_BASE/g" \
        -e "s/\$(VP_TRIAL_CERT_SHA256)/$VP_TRIAL_CERT_SHA256/g" \
        "$SCRIPT_DIR/Info.plist" > "$CONTENTS/Info.plist"

    echo -n "APPL????" > "$CONTENTS/PkgInfo"

    # Copy Resources
    [ -f "$SCRIPT_DIR/VoicePolish.icns" ] && cp "$SCRIPT_DIR/VoicePolish.icns" "$RESOURCES/"
    [ -f "$SCRIPT_DIR/Resources/VoicePolish.icns" ] && cp "$SCRIPT_DIR/Resources/VoicePolish.icns" "$RESOURCES/"
    [ -f "$SCRIPT_DIR/Resources/WhatsNewGuide.html" ] && cp "$SCRIPT_DIR/Resources/WhatsNewGuide.html" "$RESOURCES/"
    [ -f "$SCRIPT_DIR/Sources/statusbar-icon.png" ] && cp "$SCRIPT_DIR/Sources/statusbar-icon.png" "$RESOURCES/"
    [ -f "$SCRIPT_DIR/Sources/statusbar-icon@2x.png" ] && cp "$SCRIPT_DIR/Sources/statusbar-icon@2x.png" "$RESOURCES/"
    [ -f "$SCRIPT_DIR/Sources/record-start.wav" ] && cp "$SCRIPT_DIR/Sources/record-start.wav" "$RESOURCES/"
    [ -f "$SCRIPT_DIR/Sources/record-stop.wav" ] && cp "$SCRIPT_DIR/Sources/record-stop.wav" "$RESOURCES/"

    # Copy Frameworks
    cp -R "$sparkle_framework" "$FRAMEWORKS/"

    # Sign Sparkle framework components and app
    local entitlements="$SCRIPT_DIR/Resources/VoicePolish.entitlements"
    local sp_v="$FRAMEWORKS/Sparkle.framework/Versions/B"
    if [ -d "$sp_v" ]; then
        for xpc in "$sp_v/XPCServices/"*.xpc; do
            [ -e "$xpc" ] && codesign --force --sign - "$xpc"
        done
        [ -e "$sp_v/Autoupdate" ]  && codesign --force --sign - "$sp_v/Autoupdate"
        [ -e "$sp_v/Updater.app" ] && codesign --force --sign - "$sp_v/Updater.app"
        codesign --force --sign - "$FRAMEWORKS/Sparkle.framework"
    fi

    if developer_id_available; then
        echo "🔏 Signing with Developer ID..."
        resign_with_developer_id "$APP_DIR"
    else
        echo "🔏 Ad-hoc signing Typefree bundle..."
        codesign --force \
            --entitlements "$entitlements" \
            --sign - "$APP_DIR"
    fi

    ditto "$APP_DIR" "$SCRIPT_DIR/dist/Typefree.app"
    xattr -cr "$APP_DIR" 2>/dev/null || true
    xattr -cr "$SCRIPT_DIR/dist/Typefree.app" 2>/dev/null || true

    codesign --verify --deep --strict "$APP_DIR" || echo "⚠️ Verification warning (ad-hoc signing)"
}

if [ "${FORCE_MANUAL_BUILD:-0}" != "1" ] && xcode_signing_ready; then
    if build_with_xcode; then
        print_summary
        exit 0
    fi
    echo "⚠️  Xcode-managed build failed; falling back to SPM build."
    # 清理可能残留的旧产物，避免误安装旧版
    rm -rf "$DERIVED_DATA_PATH"
fi

build_with_spm
print_summary

