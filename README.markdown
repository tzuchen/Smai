# 思脈注音 (Smai) — 次世代 AI 神經語意與提示詞注音輸入法

> 基於 OpenVanilla McBopomofo 小麥注音，專為 Coding Agent 使用者、LLM 提示詞工程師與高效率打字者打造的次世代邊緣 AI 注音輸入法。

思脈注音在傳統小麥注音的堅實基礎上，深度融合了大語言模型（LLM）的**「整句神經語意校正」**、**「提示詞工程最佳化」**與**「中英夾雜上文回溯縫合」**能力。透過雙引擎協同（Spark Qwen 27B 區域加速 + Apple Foundation Model 邊緣備援），在維持極致打字流暢度與隱私的前提下，全面釋放中文智慧輸入的潛能。

---

## ✨ 核心特色與創新突破

### 1. 嚴格同音/近音約束與整句校正 (Homophone-First Constraint)
* **突破 N-gram 限制**：不再受限於雙字或三字詞庫斷詞，以整句語境進行多跳常識推理（例如由物理語境推敲出「這顆球不太圓」而非「這苛求不太原」）。
* **同音優先，杜絕胡亂替換**：輸入法的核心是注音編碼。思脈注音嚴格遵守「同音/近音優先」原則，避免傳統 AI 的過度腦補與詞義幻覺（例如當輸入「地球有多元」，精準定錨為同音之「地球有多**圓**」，絕不隨意替換為發音無關的「大」）。
* **一字對一字對齊**：嚴格維持原句字數與標點符號不變，精準標記修正位置。

### 2. LLM 提示詞工程最佳化 (Prompt Optimization)
* **雙重即時觸發**：
  * **句尾雙句號 `。。`**：輸入口語需求並以中文句號連打 `。。` 結尾（如「請幫我看看LLM最新進展。。」）。
  * **雙大於符號 `>>`**：於句首或句尾輸入 `>>`（如「>> 優化這段程式碼」）。
* **即時重構為專業 Prompt**：在 2~3 秒內自動將粗略的口語想法擴展為結構精準、點出盲點、具備防誤導條件的高品質繁體中文 Prompt（專為 agy、codex、Claude 等 Coding Agent 量身打造）。

### 3. 中英夾雜上文自動回溯縫合 (Preceding Context Aggregation)
* **解決跨語言截斷痛點**：在打字過程中切換輸入法（例如打「請幫我看看」$\rightarrow$ 切換英文輸入「LLM」$\rightarrow$ 切回注音打「的最新進展。。」）時，前面的中文與英文已提交通知應用程式。
* **自動回溯縫合**：思脈注音會自動向當前應用程式回溯讀取游標前最多 120 字的已提交文字，縫合成完整語句傳送給模型，並在生成完畢後**將前面已提交的文字連同組字區一併替換**為完整 Prompt！

### 4. Caps Lock 智慧英文小寫模式 (Smart Case Policy)
* **工程師友善直覺**：按下 Caps Lock 鎖定鍵時，預設直接輸出**英文小寫字母**（如 `j`、`i`、`hello`）。
* **實體 Shift 輸出大寫**：僅在實體按住 Shift 鍵鍵入字母時，輸出**英文大寫字母**（如 `J`、`I`、`Hello`）。

### 5. 克漏字智慧填空 (Cloze Filling `??`)
* 於句子中任意位置輸入 `??` 或 `？？`（例如「這家餐廳的服務很??令人難受」），模型會依據上下文語意自動填補最通順道地的繁體中文詞彙。

### 6. 雙引擎架構 (Spark Qwen 27B + AFM Edge Fallback)
* **主力引擎：Spark Qwen 27B（區域網路 / 本機）**
  * 端點：`http://192.168.31.128:8000/v1/chat/completions`（模型 `spark-vllm-docker`）。
  * 關閉思考模式（`enable_thinking: false`），推論延遲極低（約 200ms～400ms）。
* **邊緣備援：Apple Foundation Model (~3B, AFM on-device)**
  * 端點：`http://127.0.0.1:1975/v1/chat/completions`。
  * 遇網路逾時或 Qwen 離線時，自動無縫退回本機 AFM 模型，離線依然可用。

### 7. 即時視覺狀態反饋 (Visual Feedback)
* **推論中（In-Flight）**：向 AI 發送請求時，組字區文字變為 **靛藍色（Indigo）**。
* **校正完成（Highlighted）**：AI 所修正的所有字詞立即套用 **黃底橘字＋粗底線**，一眼即知修改了哪些部分。按 Enter 即可直接送出。

---

## 📊 思脈注音功能選項對照表 (Option Table)

思脈注音的所有神經 AI 功能皆可在「偏好設定 $\rightarrow$ 進階」或輸入法選單列中自由開啟與微調：

| 功能設定 (Option) | 預設狀態 | 觸發方式 / 快捷鍵 | 功能詳細說明 (Description) |
| :--- | :---: | :--- | :--- |
| **啟用思脈神經語意校正**<br>`afmAssistEnabled` | **開啟** | 打字自動觸發 (防抖 350ms) | 主開關。啟用基於整句神經語意推理的同音與近音自動選字修復。 |
| **同音與近音錯字校正**<br>`afmNearPhoneticFixEnabled` | **開啟** | 自動 | **嚴格同音優先**。優先修正同音、同韻母/聲調之錯字，禁止替換發音無關字（如「地球有多元」$\rightarrow$「地球有多圓」）。 |
| **LLM 提示詞工程最佳化**<br>`afmPromptOptimizerEnabled` | **開啟** | 句尾 `。。` 或句首 `>>` | 將口語需求自動重構為精準 Coding/LLM Prompt；支援中英混打上文自動縫合。 |
| **中英夾雜上文自動縫合** | **內建** | 自動回溯 (最多 120 字) | 中英切換輸入提交後，觸發 Prompt 最佳化時自動縫合前段已提交文字並整句替換。 |
| **Caps Lock 智慧模式** | **內建** | 按下 Caps Lock 鍵 | Caps Lock 開啟時**預設輸出小寫英文**；僅在實體按住 Shift 鍵時輸出大寫字母。 |
| **克漏字智慧填空**<br>`afmClozeFillingEnabled` | **開啟** | 句中輸入 `??` 或 `？？` | 依據前後文語境，自動填入最適切之繁體中文詞彙替換問號。 |
| **全形標點符號規範**<br>`afmPunctuationFixEnabled` | **開啟** | 輸入標點符號 (0ms 觸發) | 自動修正標點符號全形規範，鍵入標點瞬間立即觸發整句神經校正。 |
| **語意流暢自然潤飾**<br>`afmSemanticFluencyRewriteEnabled` | **關閉** | 自動 | 進階選項。允許打破一字對一字字數限制，可適度增減字數進行自然潤飾。 |
| **雙引擎自動容錯備援** | **內建** | 逾時/斷線自動切換 | 優先使用 Spark Qwen 27B，遇逾時或連線失敗自動無縫切換至本機 AFM Edge (~3B)。 |
| **即時色彩視覺反饋** | **內建** | 自動 | 推論中呈現靛藍色，AI 修正完成後呈現黃底橘字高亮提醒。 |

---

## 🚀 快速安裝與熱部屬指南

### 快速熱部屬 (Fast Dev Deploy，約 3~4 秒)

本專案具備極速熱部屬腳本，專為開發除錯與日常快速更新打造：

```bash
# 1. 單次熱部屬（增量編譯 + 覆蓋安裝至 /Library/Input Methods/Smai.app）
./Tools/AFM/dev_deploy.sh

# 2. 監聽模式（Watch Mode）：檔案變更自動觸發熱部屬
./Tools/AFM/dev_deploy.sh --watch
```

部屬完成後，只需重啟輸入法進程即可套用最新變更：
```bash
killall McBopomofo
```

### 系統需求

* macOS 14 (Sonoma) 或 macOS 15 (Sequoia) 以上（支援 Apple Silicon AFM Edge）
* Xcode 15 或更高版本
* 本機或區域網路已部署相容 OpenAI API 之服務（如 Spark Qwen 27B、AFM Proxy）

---

## 📜 社群公約與開源授權

本專案衍生自 OpenVanilla McBopomofo 小麥注音輸入法，遵循小麥注音社群公約（[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)）。

本軟體以 **MIT License** 授權釋出，自由使用、修改與散播，詳見 [LICENSE.txt](LICENSE.txt)。
