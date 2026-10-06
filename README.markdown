# OpenVanilla McBopomofo 小麥注音輸入法 (AI 神經語意整句校正版)

本分支（`feat/afm-assist`）在 OpenVanilla 小麥注音輸入法的堅實基礎上，加入了基於大語言模型（LLM）的**「整句神經語意校正（Whole-Sentence Neural Correction）」**功能。

傳統注音輸入法依賴固定詞庫與 N-gram 統計模型，當遇到同音字量詞搭配（例如「這顆球圓嗎」vs「這科球員嗎」）、罕用詞斷詞衝突（如「這顆球好像不太圓」選成「這苛求好像不太原」）或長句深層語意時，往往無法自動選出最通順合理的字詞。本專案透過雙引擎神經模型架構，讓小麥注音具備理解整句上下文、自動修復同音錯字的能力。

---

## ✨ 核心特色

### 1. 整句神經語意校正 (Whole-Sentence Neural Correction)
- **跨詞界語意推敲**：不再受限於本地雙字詞或三字詞詞庫分詞，直接根據整句語境進行多跳常識推理（例如由「捏一捏」推論出「這顆球不太圓」而非「這苛求不太原」）。
- **一字對一字精準對齊**：嚴格維持原句字數與標點符號不變，僅針對不合邏輯的同音/近音錯字進行替換。

### 2. 雙引擎架構 (Spark Qwen 27B + AFM Edge Fallback)
- **主力引擎：Spark Qwen 27B（區域網路 / 本機）**
  - 預設端點：`http://192.168.31.128:8000/v1/chat/completions`（模型 `spark-vllm-docker`）。
  - 關閉 Thinking Token（`enable_thinking: false`）直接輸出校正字串，推論延遲極低（約 200ms～400ms）。
  - 對複雜量詞搭配、同音字判斷準確率極高。
- **邊緣備援：Apple Foundation Model (~3B, AFM on-device)**
  - 預設端點：`http://127.0.0.1:1975/v1/chat/completions`。
  - 當 Qwen 伺服器離線、網路不通或請求逾時（1.5s）時，自動無縫退回使用本機 AFM 模型，確保完全離線時依然具備輔助能力。

### 3. 即時視覺反饋 (Visual Feedback)
- **校正進行中（In-Flight）**：當輸入法正在向 AI 發送請求時，組字區文字會暫時轉為 **靛藍色（Indigo）**。
- **AI 校正完成（Highlighted）**：被 AI 修正的所有字詞會同步套用 **黃底橘字＋粗底線**（Multi-range Highlight），讓使用者一眼看出 AI 修改了哪些字。
- **手動確認與清除**：按 Enter 直接送出，或按方向鍵/空白鍵選字，高亮即自動恢復正常。

### 4. 智慧防抖與注音拼音邊界保護
- **注音拼音保護**：當組字緩衝區內仍有未完成的注音符號（如 `ㄋ`、`ㄧ`、`ㄝ` 等拼音中途）時，**絕不觸發 LLM**，消除打字過程中的抖動與長度不符。
- **自適應防抖機制**：
  - 一般連續打字：350ms 防抖，連續輸入流暢不卡頓。
  - 標點符號（`，`、`。`、`？`、`！` 等）：0ms 立即觸發整句校正。
- **單句獨立無污染**：每次校正僅針對當前組字區這句話，不累積歷史對話，Enter 送出後立即清空，避免歷史文本無限膨脹。

---

## 🚀 安裝與啟用

### 快速安裝預編譯套件

下載或編譯 `.pkg` 安裝包後執行：

```bash
sudo /usr/sbin/installer -pkg "/Users/Shared/McBopomofoAFM-0.2.6.pkg" -target /
killall McBopomofo
```

### 啟用 AI 輔助

1. 切換至小麥注音輸入法。
2. 點擊選單列上的小麥注音圖示（或按偏好設定快捷鍵）。
3. 勾選 **「AI-Assisted Candidate Selection（AI 輔助選字）」** 即可啟用。

---

## 🛠️ 開發與編譯

### 系統需求

- macOS 13 (Ventura) 以上（建議 macOS 15+ 以支援 AFM Edge）
- Xcode 15 或更高版本
- Python 3.9+

### 編譯與打包

```bash
# 1. 使用 Xcode 編譯
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project McBopomofo.xcodeproj \
  -scheme McBopomofo \
  -configuration Debug \
  -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO build

# 2. 打包獨立 App 與安裝程式 .pkg
python3 Tools/AFM/package.py --output .build/afm-live/McBopomofoAFM.app
python3 Tools/AFM/build_installer.py --source .build/afm-live/McBopomofoAFM.app --output /Users/Shared/McBopomofoAFM-0.2.6.pkg
```

### 即時除錯記錄

開發階段可透過本機記錄檔監控 AI 觸發與校正細節：

```bash
tail -f /Users/Shared/McBopomofoAFM-dev.log
```

---

## 社群公約

歡迎小麥注音用戶回報問題與指教，也歡迎大家參與小麥注音開發。
本專案遵循 upstream 小麥注音之社群公約與規範（[詳見公約](CODE_OF_CONDUCT.md)）。

## 軟體授權

本專案採用 MIT License 釋出，使用者可自由使用、散播本軟體，惟散播時必須完整保留版權聲明及軟體授權（[詳全文](LICENSE.txt)）。
