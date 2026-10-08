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

### 3. Shell 命令智慧合成與危險指令防護 (Shell Command Synthesis & Safety Guardrails)
* **終端一般 Shell 自動合成**：在標準終端機（bash / zsh）中鍵入中文口語需求並加上 `。。` 或 `>>`（例如「幫我寫一個計時器。。」或「列出佔用8000埠號的程序>>」），模型會自動轉換為**單行高效 macOS zsh 指令**。
* **危險指令主動防護（Safety Guardrails）**：針對破壞性、不可逆或具高風險之指令（如 `rm -rf`、`kill -9`、`git reset --hard`、`git clean -f`、`diskutil`、`dd`、`sudo` 等），自動於指令前綴加上 `# ⚠️ [危險指令確認] ` 註解，**防止使用者按 Enter 誤執行**，必須手動刪除警告前綴才能送出！
* **全域 `$$` 強制觸發**：在任何環境（包含 AI CLI 或一般視窗）中輸入 `$$`（如「清除快取$$」或「$$查找大檔案」），皆可強制生成安全防護 Shell 命令。

### 4. 終端情境自動感應分流 (Terminal Context Awareness)
* **AI Coding CLI 專屬保護**：當使用者在 `agy`、`codex`、`claude`、`chatgpt` 等 AI Agent CLI 中操作時，鍵入 `。。` 或 `>>` **100% 嚴格維持為 Prompt 提示詞最佳化（50–80 字）**，絕不干擾或誤轉為 Shell 指令。
* **極速進程樹辨識**：採用零權限限制的 `proc_pidpath` 與 `sysctl(KERN_PROC_PID)` 終端控制進程組（`e_tpgid`）動態追蹤，判斷耗時僅 **0.29ms**，跨使用者環境依然精準無誤。
* **嚴格行邊界（Line Bounded）**：提示詞與上下文擷取嚴格限制在「當前輸入行」，絕不跨越換行符（`\n`）滲漏至先前的終端輸出或模型回覆中。

### 5. 中英夾雜上文自動回溯縫合 (Preceding Context Aggregation)
* **解決跨語言截斷痛點**：在打字過程中切換輸入法（例如打「請幫我看看」$\rightarrow$ 切換英文輸入「LLM」$\rightarrow$ 切回注音打「的最新進展。。」）時，前面的中文與英文已提交通知應用程式。
* **自動回溯縫合**：思脈注音會自動向當前應用程式回溯讀取游標前最多 180 字的已提交文字，縫合成完整語句傳送給模型，並在生成完畢後**將前面已提交的文字連同組字區一併替換**為完整 Prompt！

### 6. Caps Lock 智慧英文小寫模式 (Smart Case Policy)
* **工程師友善直覺**：按下 Caps Lock 鎖定鍵時，預設直接輸出**英文小寫字母**（如 `j`、`i`、`hello`）。
* **實體 Shift 輸出大寫**：僅在實體按住 Shift 鍵鍵入字母時，輸出**英文大寫字母**（如 `J`、`I`、`Hello`）。

### 7. 克漏字智慧填空 (Cloze Filling `??`)
* 於句子中任意位置輸入 `??` 或 `？？`（例如「這家餐廳的服務很??令人難受」），模型會依據上下文語意自動填補最通順道地的繁體中文詞彙。

### 8. 雙引擎架構 (Spark Qwen 27B + AFM Edge Fallback)
* **主力引擎：Spark Qwen 27B（區域網路 / 本機）**
  * 端點：`http://192.168.31.128:8000/v1/chat/completions`（模型 `spark-vllm-docker`）。
  * 關閉思考模式（`enable_thinking: false`），推論延遲極低（約 200ms～400ms）。
* **邊緣備援：Apple Foundation Model (~3B, AFM on-device)**
  * 端點：`http://127.0.0.1:1975/v1/chat/completions`。
  * 遇網路逾時或 Qwen 離線時，自動無縫退回本機 AFM 模型，離線依然可用。

### 9. 即時視覺狀態反饋 (Visual Feedback)
* **推論中（In-Flight）**：向 AI 發送請求時，組字區文字變為 **靛藍色（Indigo）**。
* **校正完成（Highlighted）**：AI 所修正的所有字詞立即套用 **黃底橘字＋粗底線**，一眼即知修改了哪些部分。按 Enter 即可直接送出。

---

## 📊 思脈注音功能選項對照表 (Option Table)

思脈注音的所有神經 AI 功能皆可在「偏好設定 $\rightarrow$ 進階」或輸入法選單列中自由開啟與微調：

| 功能設定 (Option) | 預設狀態 | 觸發方式 / 快捷鍵 | 功能詳細說明 (Description) |
| :--- | :---: | :--- | :--- |
| **啟用思脈神經語意校正**<br>`afmAssistEnabled` | **開啟** | 打字自動觸發 (防抖 350ms) | 主開關。啟用基於整句神經語意推理的同音與近音自動選字修復。 |
| **同音與近音錯字校正**<br>`afmNearPhoneticFixEnabled` | **開啟** | 自動 | **嚴格同音優先**。優先修正同音、同韻母/聲調之錯字，禁止替換發音無關字（如「地球有多元」$\rightarrow$「地球有多圓」）。 |
| **LLM 提示詞最佳化**<br>`afmPromptOptimizerEnabled` | **開啟** | 句尾 `。。` 或句首 `>>` | 於 AI CLI 與一般應用程式中，將口語需求重構為精準 Coding/LLM Prompt；支援中英混打上文自動縫合。 |
| **Shell 命令合成與防護** | **內建** | 一般 Shell 鍵入 `。。` 或全域 `$$` | 於標準終端中自動轉為 zsh 指令；破壞性操作強制加上 `# ⚠️ [危險指令確認]` 防誤送。 |
| **終端情境自動分流** | **內建** | 自動進程感應 (0.29ms) | 自動辨識 `agy` / `codex` / `claude`：在 AI CLI 中保持 Prompt 最佳化，在一般 Shell 中轉為 Shell 指令。 |
| **中英夾雜上文自動縫合** | **內建** | 自動回溯 (嚴格當前行) | 中英切換輸入提交後，觸發 Prompt 最佳化時自動縫合前段已提交文字並整句替換。 |
| **Caps Lock 智慧模式** | **內建** | 按下 Caps Lock 鍵 | Caps Lock 開啟時**預設輸出小寫英文**；僅在實體按住 Shift 鍵時輸出大寫字母。 |
| **克漏字智慧填空**<br>`afmClozeFillingEnabled` | **開啟** | 句中輸入 `??` 或 `？？` | 依據前後文語境，自動填入最適切之繁體中文詞彙替換問號。 |
| **全形標點符號規範**<br>`afmPunctuationFixEnabled` | **開啟** | 輸入標點符號 (0ms 觸發) | 自動修正標點符號全形規範，鍵入標點瞬間立即觸發整句神經校正。 |
| **語意流暢自然潤飾**<br>`afmSemanticFluencyRewriteEnabled` | **關閉** | 自動 | 進階選項。允許打破一字對一字字數限制，可適度增減字數進行自然潤飾。 |
| **雙引擎自動容錯備援** | **內建** | 逾時/斷線自動切換 | 優先使用 Spark Qwen 27B，遇逾時或連線失敗自動無縫切換至本機 AFM Edge (~3B)。 |
| **即時色彩視覺反饋** | **內建** | 自動 | 推論中呈現靛藍色，AI 修正完成後呈現黃底橘字高亮提醒。 |

---

## 🚀 快速安裝與部屬指南

### 方式一：安裝套件一鍵安裝 (推薦一般與多使用者部署)

專案提供支援全使用者共享與自動熱喚醒的 `.pkg` 安裝套件：
```bash
# 1. 編譯 Release 版本並建置安裝套件
python3 Tools/AFM/build_installer.py --source .build/xcode-$USER/Build/Products/Release/Smai.app --output /tmp/Smai-Installer-v2.pkg

# 2. 雙擊安裝套件或於終端機安裝：
sudo /usr/sbin/installer -pkg "/tmp/Smai-Installer-v2.pkg" -target /
```
> 安裝程式會在 `/Library/Input Methods` 部署，並在安裝完成後自動重啟思脈注音，無需登出或重啟系統。

### 方式二：快速熱部屬 (Fast Dev Deploy，開發除錯專用，約 2~3 秒)

本專案具備極速熱部屬腳本，專為開發除錯與即時修改打造：

```bash
# 1. 單次熱部屬（增量編譯 + 自動同步至 /Library/Input Methods/Smai.app）
./Tools/AFM/dev_deploy.sh

# 2. 監聽模式（Watch Mode）：檔案變更自動觸發熱部屬
./Tools/AFM/dev_deploy.sh --watch
```

### 系統需求

* macOS 14 (Sonoma) 或 macOS 15 (Sequoia) 以上（支援 Apple Silicon AFM Edge）
* Xcode 15 或更高版本
* 本機或區域網路已部署相容 OpenAI API 之服務（如 Spark Qwen 27B、AFM Proxy）

---

## 📜 社群公約與開源授權

本專案衍生自 OpenVanilla McBopomofo 小麥注音輸入法，遵循小麥注音社群公約（[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)）。

本軟體以 **MIT License** 授權釋出，自由使用、修改與散播，詳見 [LICENSE.txt](LICENSE.txt)。
