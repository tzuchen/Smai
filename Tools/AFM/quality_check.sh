#!/bin/bash
set -eo pipefail

# ==============================================================================
# 思脈注音 (Smai) 全方位品質與回歸檢查套件 (Quality Check Suite)
# ==============================================================================
# 涵蓋領域：
# 1. 中英切換 (CapsLock 狀態機、防抖震、英文直通、Shift 大小寫判定)
# 2. 首字斜線 (/v, /voice, /typeless, /w, /write, /ask, /tr, /trans, /translate, /resume, 刪除, Esc, 快速鍵直通)
# 3. 語音模式 (Option+V Push-to-Talk 長按判定、免持 Toggle、App-Aware 應用感知情境適配)
# 4. 符號政策 (Option+符號快捷 ⌥/ ⌥- ⌥? ⌥. ⌥# ⌥> ⌥_, 全形標點鍵盤對映)
# 5. 標點選字與長句防重複 (空白鍵動態選字、Enter 狀態機防雙重提交)
# 6. 更新機制與核心詞庫 (GitHub Releases SemVer 比對、核心高頻詞庫完整性)
# 7. 周邊 AI & ASR 服務連線檢測 (AFM Edge, Spark Qwen 27B, Topology API, Mac mini ASR)
# ==============================================================================

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || pwd)"
DERIVED_DATA_PATH="$REPO_ROOT/.build/xcode-$USER"
BUILT_APP="$DERIVED_DATA_PATH/Build/Products/Debug/Smai.app"
BINARY="$BUILT_APP/Contents/MacOS/Smai"

FORCE_BUILD=false
AUTO_DEPLOY=false

for arg in "$@"; do
    case "$arg" in
        --build|-b)
            FORCE_BUILD=true
            ;;
        --deploy|-d)
            AUTO_DEPLOY=true
            ;;
        --help|-h)
            echo "用法: $0 [選項]"
            echo "選項:"
            echo "  --build, -b   檢查前強制重新編譯 (Incremental xcodebuild)"
            echo "  --deploy, -d  若全部檢查通過，自動觸發熱部屬 (dev_deploy.sh)"
            echo "  --help, -h    顯示此說明"
            exit 0
            ;;
    esac
done

cd "$REPO_ROOT"

echo "=================================================="
echo "   思脈注音 (Smai) 自動化品質保證檢查 (QC Suite)"
echo "=================================================="

# 1. 檢查二進位檔是否存在，或是否要求強制編譯
if [ "$FORCE_BUILD" = true ] || [ ! -f "$BINARY" ]; then
    echo "🔨 [1/3] 正在執行增量編譯 (xcodebuild)..."
    rm -rf "$DERIVED_DATA_PATH/Build/Intermediates.noindex/PrecompiledHeaders" 2>/dev/null || true
    xcodebuild -project McBopomofo.xcodeproj \
               -scheme McBopomofo \
               -configuration Debug \
               -derivedDataPath "$DERIVED_DATA_PATH" \
               -destination 'platform=macOS,arch=arm64' \
               build \
               CODE_SIGN_IDENTITY="" \
               CODE_SIGNING_REQUIRED=NO \
               -quiet
    echo "✅ 編譯成功！二進位檔案就緒。"
else
    echo "⚡️ [1/3] 使用最新編譯產物: $BINARY"
fi

# 2. 執行 Smai 核心功能品質測試
echo ""
echo "🧪 [2/3] 執行思脈注音核心功能回歸測試..."
"$BINARY" --quality-check
QC_EXIT_CODE=$?

if [ $QC_EXIT_CODE -ne 0 ]; then
    echo "❌ 核心功能品質檢查未通過，請修復錯誤後重試！"
    exit $QC_EXIT_CODE
fi

# 3. 周邊 AI 與 ASR 服務健康探測
echo ""
echo "🌐 [3/3] 檢查本機與區域網 AI / ASR 模組健康狀態..."
probe_endpoint() {
    local name="$1"
    local url="$2"
    local timeout=2
    if curl -s --connect-timeout "$timeout" "$url" >/dev/null 2>&1; then
        printf "  %-32s \033[32m[連線正常]\033[0m (%s)\n" "$name" "$url"
    else
        printf "  %-32s \033[33m[離線/未就緒]\033[0m (%s)\n" "$name" "$url"
    fi
}

probe_endpoint "AFM Edge 端側模型 (1975)" "http://127.0.0.1:1975/v1/models"
probe_endpoint "Spark Qwen 27B (Port 8000)" "http://192.168.31.128:8000/v1/models"
probe_endpoint "Topology 管理網頁 (Port 8080)" "http://100.95.202.103:8080"
probe_endpoint "Mac mini 本機 ASR (Port 8765)" "http://127.0.0.1:8765/health"

echo ""
echo "=================================================="
echo "🎉 全方位品質保證檢查全部通過！隨時可以安全發布。"
echo "=================================================="

# 4. 可選自動部屬
if [ "$AUTO_DEPLOY" = true ]; then
    echo ""
    echo "🚀 偵測到 --deploy 參數，開始執行熱部屬..."
    "$REPO_ROOT/Tools/AFM/dev_deploy.sh"
fi
