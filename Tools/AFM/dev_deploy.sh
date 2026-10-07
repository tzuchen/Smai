#!/bin/bash
set -e

# ==============================================================================
# Smai (思脈注音) 極速熱部屬腳本 (Fast Dev Deploy)
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET_APP="/Library/Input Methods/Smai.app"
BUILT_APP="$REPO_ROOT/.build/xcode/Build/Products/Debug/McBopomofo.app"

cd "$REPO_ROOT"

deploy() {
    START_TIME=$(python3 -c 'import time; print(time.time())')
    echo "⚡️ [1/4] 增量編譯 (Incremental Build arm64)..."
    
    xcodebuild -project McBopomofo.xcodeproj \
               -scheme McBopomofo \
               -configuration Debug \
               -derivedDataPath .build/xcode \
               -destination 'platform=macOS,arch=arm64' \
               build \
               CODE_SIGN_IDENTITY="" \
               CODE_SIGNING_REQUIRED=NO \
               -quiet

    echo "📦 [2/4] 同步至輸入法目錄..."
    if [ ! -w "$TARGET_APP" ]; then
        # 若無寫入權限，使用 sudo 拷貝（建議執行 sudo chown -R $(whoami) "/Library/Input Methods/Smai.app" 免密）
        sudo /usr/bin/ditto "$BUILT_APP" "$TARGET_APP"
        sudo /usr/bin/codesign --force --deep --sign - "$TARGET_APP" 2>/dev/null || true
    else
        /usr/bin/ditto "$BUILT_APP" "$TARGET_APP"
        /usr/bin/codesign --force --deep --sign - "$TARGET_APP" 2>/dev/null || true
    fi

    echo "🔄 [3/4] 重啟思脈注音進程..."
    killall McBopomofo 2>/dev/null || true
    open "$TARGET_APP"

    END_TIME=$(python3 -c 'import time; print(time.time())')
    ELAPSED=$(python3 -c "print(f'{$END_TIME - $START_TIME:.2f}')")
    echo "✅ [4/4] 熱部屬完成！耗時: ${ELAPSED}s"
}

if [ "$1" == "--watch" ]; then
    echo "👀 進入監聽模式 (Watch mode)，修改 Source/ 底下檔案將自動熱部屬..."
    deploy
    LAST_HASH=$(find Source -type f \( -name "*.swift" -o -name "*.mm" -o -name "*.h" -o -name "*.plist" -o -name "*.strings" \) -exec stat -f "%m" {} + 2>/dev/null | md5)
    while true; do
        sleep 1
        CURRENT_HASH=$(find Source -type f \( -name "*.swift" -o -name "*.mm" -o -name "*.h" -o -name "*.plist" -o -name "*.strings" \) -exec stat -f "%m" {} + 2>/dev/null | md5)
        if [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
            echo ""
            echo "🔔 偵測到原始碼變更，觸發熱部屬..."
            deploy
            LAST_HASH="$CURRENT_HASH"
        fi
    done
else
    deploy
fi
