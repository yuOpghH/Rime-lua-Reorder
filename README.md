# Rime 候選調序外掛（rime-reorder）1.4.24

聲明：本應用通過AI許願式編程而成，AI+人工校驗、readme由AI+人工潤色。

給小狼毫（Weasel）用的候選排序外掛：用一個外掛工作台允許一鍵拖動候選順序、造詞、刪詞。

不必改詞典、不必改 `default.yaml`、不必動輸入法服務。

---
- 版本：**1.4.24**
- 適用：Windows 上的小狼毫（需包含 librime-lua）
- 設計原則：**fail-open**。資料檔缺失、壞行或規則寫錯時，一律維持原本候選順序，不吞鍵、不讓候選消失。


<p align="center">
<img src="https://github.com/yuOpghH/Rime-lua-Reorde/blob/main/%E5%B1%95%E7%A4%BA%E5%9C%96%E7%89%87/2026-a.jpg"  style="width:500px;"/><br>
<img src="https://github.com/yuOpghH/Rime-lua-Reorde/blob/main/%E5%B1%95%E7%A4%BA%E5%9C%96%E7%89%87/2026-b.jpg"  style="width:500px;"/>
</p>

---

## 目錄

- [功能特性](#功能特性)
- [環境需求](#環境需求)
- [安裝](#安裝)
- [首次使用](#首次使用)
- [設定檔說明](#設定檔說明)
- [資料檔與備份](#資料檔與備份)
- [常見問題](#常見問題)
- [檔案清單與校驗](#檔案清單與校驗)
- [近期更新](#近期更新)
- [鳴謝](#鳴謝)

---

## 功能特性

- **候選調序**：工作台左欄就是目前的候選清單，直接拖曳即可調整順序，立即寫入、立即生效。
- **硬置頂／硬置底**：右鍵「置頂（+5）」「置底（-5）」，分數 ±5 代表硬鎖，永遠排最前或最後。
- **加權排序**：±1 至 ±4 為一般加權，分數越大越前面；同分時維持引擎原本的相對順序，不會亂跳。
- **新詞注入**：在工作台輸入「詞」與「碼」按「加入」，新詞會寫入 `extra.tsv`，打完碼就能選到。
- **簡碼規則**：依 `rules.yaml` 由你輸入的主碼自動產生簡碼與衍生碼（`derive`／`xform`／`abbrev`／`fuzz`），
  打簡碼也能出詞，不需要全碼、不需要反引號、不需要重新部署。
- **造詞熱鍵**：在組字狀態按 `Shift+Space`，把目前組字結果直接存成新詞；`Shift+Delete` 可刪除游標處由本工具管理的詞。
  （兩者都可在 `config.ini` 改鍵。）
- **多方案**：安裝時會為「已啟用」的每個方案各自加入設定；各方案的排序、新詞、規則互不干擾。
- **方案分層**：每個方案可有自己的設定目錄，另有共用的 `default` 層；尚未建立獨立設定的方案會沿用共用層。
- **合成詞（可選）**：`compose=on` 時，連續輸入的整串碼會按段查詞、拼成完整詞參與排序；
  預設 **off**，不生成合成候選，行為與舊版一致。
- **上屏記帳（可選）**：`commitrecord=on`（預設）時，跨段上屏的詞會補寫進引擎使用者詞典，
  下次更容易直接選到；可用 `commitrecord=off` 完全關閉。
- **歷史與撤銷**：右側「歷史」面板記錄每一次拖曳、置頂、置底、鎖定、刪除、造詞；
  `Ctrl+Z` 撤銷上一筆，`Ctrl+Y` 重做（僅工作台在前景時作用）。
- **狀態燈**：綠＝排序生效；黃＝心跳正常但這次沒有候選被移動；紅＝沒有心跳；關閉＝完全旁路。
- **即時開關**：「排序生效」勾選框可隨手開關排序，切換只改檔名，**不需要重新部署**。
- **可選開機自啟**：預設關閉；可在托盤選單勾選「開機自啟（托盤靜默）」，只駐托盤、不彈視窗。
- **安全邊界**：不修改 `*.dict.yaml`、`default.yaml`、`build\` 內的檔案；不安裝服務、不接管輸入法。
- **純確定性**：排序完全依你設定的分數與位置，沒有 AI 猜測、沒有雲端。

---

## 環境需求

- Windows 10／11。
- 小狼毫（Weasel），且內建或已加裝 **librime-lua**。本版已在 **小狼毫 0.17.4** 上驗證。
- Windows PowerShell 5.1 以上（系統內建即可）。
- 建議先確認小狼毫本身可正常輸入，再安裝本外掛。

> 本外掛只依賴 Rime 的 Lua 外掛機制；若你的小狼毫不含 librime-lua，`reorder.lua` 不會被載入，
> 排序與新詞都不會生效。

---

## 安裝

### 1. 解壓

把發行包解壓到任意資料夾（路徑可含中文，但建議不要放在會被同步或清理的暫存目錄）。
本包採用**對照安裝路徑**佈局：`lua\` 與 `reorder\` 可直接對照小狼毫使用者目錄複製。

```text
RimeReorder-1.4.24\
├─ install.ps1                  （留在本機，安裝器）
├─ README.md                    （留在本機，本文件）
├─ lua\
│   └─ reorder.lua              → <Rime>\lua\reorder.lua
└─ reorder\
    ├─ RimeReorder.exe          → <Rime>\reorder\RimeReorder.exe
    ├─ rules.yaml               → <Rime>\reorder\rules.yaml（僅首次需要）
    └─ vocab.txt                → <Rime>\reorder\vocab.txt（僅首次需要）
```

`<Rime>` 是小狼毫使用者目錄，通常為 `%APPDATA%\Rime`，或登錄檔
`HKCU\Software\Rime\Weasel` 的 `RimeUserDir`。若某方案使用自己的 profile 目錄，
範本亦可放在 `reorder\profiles\<方案>\` 下；不存在時工作台會自動建立。

### 2. 先預覽（建議）

由於本包採對照佈局，`install.ps1` 會優先讀取**自身同層**的 `reorder.lua` 與 `RimeReorder.exe`；
請先把它們暫存到一個臨時資料夾，再從該處執行安裝器（後續 `-Install`／`-Uninstall` 也沿用同一個 `$Stage`）：

```powershell
$Pkg   = "D:\path\to\RimeReorder-1.4.24"   # 改成你的解壓路徑
$Stage = Join-Path $env:TEMP "RimeReorder-stage"
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
Copy-Item "$Pkg\lua\reorder.lua" "$Stage\reorder.lua" -Force
Copy-Item "$Pkg\reorder\RimeReorder.exe" "$Stage\RimeReorder.exe" -Force
Copy-Item "$Pkg\install.ps1" "$Stage\install.ps1" -Force
powershell -ExecutionPolicy Bypass -File "$Stage\install.ps1" -DryRun
```

`-DryRun` 只印出計畫：會安裝到哪個 Rime 使用者目錄、哪些方案會被加入受管理區塊、會備份哪些檔案；
**不會修改任何檔案**。

### 3. 正式安裝

```powershell
powershell -ExecutionPolicy Bypass -File "$Stage\install.ps1" -Install
```

安裝完成後，安裝器會自動呼叫 `WeaselDeployer.exe /deploy` 並等待部署心跳。
若你之後手動改過方案設定，也可以用相同方式重新部署。

### 安裝器做了什麼

只做三件事：

1. 複製 `lua\reorder.lua`、`reorder\RimeReorder.exe`（若有 `RimeDeploy.exe` 也一併複製）到 Rime 使用者目錄。
2. 在每個**已啟用方案**的 `<方案>.custom.yaml` 內插入／更新一段受管理標記區塊
   （`# >>> rime-reorder:begin` 到 `# <<< rime-reorder:end`）。
3. 呼叫 `WeaselDeployer.exe /deploy` 並等待心跳。

安裝器**不會**修改 `userdb`、`*.dict.yaml`、`default.yaml`、`build\` 內的檔案，也不會刪除任何既有備份。
每次安裝都會把本次版本留一份到 `reorder\_versions\<版本>\`，方便日後獨立重裝。

### 可用參數

| 參數 | 說明 |
| --- | --- |
| `-DryRun` | 只預覽，不寫檔。可與其他參數搭配。 |
| `-Install` | 安裝或升級（預設動作）。 |
| `-Repair` | 修復：等同重新安裝，會重建受管理區塊並補回檔案。 |
| `-Restore` | 還原最近一份安裝備份（`reorder\_backup\` 下最新一份）。 |
| `-Uninstall` | 卸載：移除受管理區塊與程式檔，**保留使用者資料**。 |
| `-RimeDir <路徑>` | 指定 Rime 使用者目錄，略過自動偵測。 |
| `-NoDeploy` | 安裝後不部署（只複製檔案與改設定）。 |
| `-DeployTimeoutSec <秒>` | 部署整體逾時，預設 600。 |
| `-HeartbeatWaitSec <秒>` | 等待部署心跳的秒數，預設 60。 |

Rime 使用者目錄的解析順序：

1. 命令列 `-RimeDir` 指定的路徑；
2. 登錄檔 `HKCU\Software\Rime\Weasel` 的 `RimeUserDir`；
3. `%APPDATA%\Rime`。

### 手動複製安裝（可直接貼上）

若你偏好自己控制每一步，可把下面整段貼到**以系統管理員身分執行**的 PowerShell。
路徑含空格時都已加引號；請先把 `$Pkg` 改成你的解壓路徑。

```powershell
# 1) 關閉正在執行的工作台（沒有在跑也不會報錯）
Get-Process RimeReorder -ErrorAction SilentlyContinue | Stop-Process -Force

# 2) 取得小狼毫使用者目錄；找不到就退回 %APPDATA%\Rime
$Rime = (Get-ItemProperty "HKCU:\Software\Rime\Weasel" -ErrorAction SilentlyContinue).RimeUserDir
if (-not $Rime) { $Rime = Join-Path $env:APPDATA "Rime" }
if (-not (Test-Path $Rime)) { throw "找不到 Rime 使用者目錄：$Rime" }

# 3) 改成你的解壓路徑
$Pkg = "D:\path\to\RimeReorder-1.4.24"

# 4) 建立目標目錄並覆蓋核心檔案
New-Item -ItemType Directory -Force -Path "$Rime\lua" | Out-Null
New-Item -ItemType Directory -Force -Path "$Rime\reorder" | Out-Null
Copy-Item "$Pkg\lua\reorder.lua" "$Rime\lua\reorder.lua" -Force
Copy-Item "$Pkg\reorder\RimeReorder.exe" "$Rime\reorder\RimeReorder.exe" -Force

# 5) 範本檔只在不存在時複製，不覆蓋你已改過的規則與詞彙
foreach ($name in @("rules.yaml", "vocab.txt")) {
    $dst = Join-Path "$Rime\reorder" $name
    if (-not (Test-Path $dst)) { Copy-Item (Join-Path "$Pkg\reorder" $name) $dst }
}

# 6) 校驗兩個核心檔的 SHA-256
$want = @{
    "$Rime\lua\reorder.lua"         = "6D9228A380756B2572DC28D53ACF03187955DEDF1EF8DD29803CE0490120FBC3"
    "$Rime\reorder\RimeReorder.exe" = "552BB383D1CCDB81DF45CB2B1E5D16E887B0B272D35A6D240A7FCF9EEE0EBF86"
}
foreach ($path in $want.Keys) {
    $got = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($got -eq $want[$path]) {
        Write-Host "OK   $path" -ForegroundColor Green
    } else {
        Write-Host "FAIL $path`n     預期=$($want[$path])`n     實際=$got" -ForegroundColor Red
    }
}

# 7) 重新部署（自動尋找 WeaselDeployer.exe）
$dep = ""
$srv = Get-Process WeaselServer -ErrorAction SilentlyContinue | Select-Object -First 1
if ($srv -and $srv.Path) { $dep = Join-Path (Split-Path $srv.Path -Parent) "WeaselDeployer.exe" }
if (-not $dep -or -not (Test-Path $dep)) {
    $found = Get-ChildItem "C:\Program Files\Rime" -Filter "WeaselDeployer.exe" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { $dep = $found.FullName }
}
if ($dep -and (Test-Path $dep)) {
    & $dep /deploy
} else {
    Write-Host "找不到 WeaselDeployer.exe，請從小狼毫開始選單手動重新部署。" -ForegroundColor Yellow
}

# 8) 重新啟動工作台
Start-Process "$Rime\reorder\RimeReorder.exe"
```

> 這一節只負責「檔案」。若某個方案從來沒有加入過受管理區塊（第一次安裝），
> Rime 不會載入 `reorder.lua`；請先用上面的安裝器完成一次安裝，之後再用本節手動覆蓋升級。
> 若該方案已由安裝器加過區塊，直接手動複製即可。

### 升級與修復

新版本直接覆蓋舊版解壓目錄後，重新建立 `$Stage`（見「先預覽」）並再執行一次：

```powershell
powershell -ExecutionPolicy Bypass -File "$Stage\install.ps1" -Install
```

安裝器是冪等的：重複執行不會重複插入區塊；建議直接用 `-Repair` 也可以。

### 還原上一份安裝備份

```powershell
powershell -ExecutionPolicy Bypass -File "$Stage\install.ps1" -Restore
```

會從 `reorder\_backup\` 取最新一份備份還原：安裝時新建的 `<方案>.custom.yaml` 會被移除，
原本存在的檔案會還原成安裝前的內容。

### 解除安裝

```powershell
powershell -ExecutionPolicy Bypass -File "$Stage\install.ps1" -Uninstall
```

卸載會：

- 移除各 `<方案>.custom.yaml` 內的受管理區塊（若該檔是安裝時新建、移除後只剩空 `patch:`，會直接刪除；
  若原本就有內容，會還原原始檔）。
- 刪除 `lua\reorder.lua`、`reorder\RimeReorder.exe`、`reorder\RimeDeploy.exe`。
- 移除開機自啟登錄項 `HKCU\...\Run\RimeReorder`。
- 觸發一次重新部署。

**不會刪除**你的 `rank.tsv`、`extra.tsv`、`vocab.txt`、`history.tsv` 等資料，也不會刪除備份與 `_versions\`。
若之後想徹底清乾淨，可自行刪除 `reorder\` 資料夾。

> 卸載同樣需要安裝器在自身同層看到 `reorder.lua`，請照「先預覽」的步驟準備 `$Stage` 後再執行。

---

## 首次使用

### 呼出工作台

安裝完成並部署後，按 **`Ctrl+Alt+R`** 呼出／收起工作台（可在托盤選單「設定熱鍵」更改）。

- 工作台是普通視窗，工作列有按鈕。
- 按「最小化」會縮到工作列；按「✕」關閉則是**收進托盤**，不會結束程式。
- 真正結束請用托盤右鍵選單的「結束」。

### 介面導覽

- **頂部**：方案下拉（切換目前編輯的方案）、「複製→」（把本方案設定複製到另一個方案）、狀態燈與版本徽章。
- **左欄**：目前候選清單。每列顯示候選詞與分數；拖曳可調序。
- **左欄底部**：輸入「詞」與「碼」後按「加入」新增詞；「排序生效」勾選框控制排序開關。
- **右欄**：歷史面板，可搜尋（詞／動作／日期前綴）、逐列按「撤」。
- **左下**：規則回饋區，顯示 `rules.yaml`／`vocab.txt` 的解析結果與錯誤行號。
- **右下面板按鈕**：
  - 「補詞」：把 `vocab.txt` 裡尚未寫入 `extra.tsv` 的詞補成注入行。
  - 「詞彙」：用記事本開啟 `vocab.txt`。
  - 「規則」：用記事本開啟 `rules.yaml`；檔案不存在時會先建立帶註解的範本。

改完 `rules.yaml` 或 `vocab.txt` 存檔後，約 1.2 秒（停止編輯）會自動重新載入，不需要重啟、不需要部署。

### 調序操作

- **拖曳**：直接把候選拖到你想要的位置。
- **右鍵選單**：
  - 「置頂（+5）」：硬置頂，永遠第一。
  - 「置底（-5）」：硬置底，永遠最後。
  - 「鎖定（依位置硬鎖）」：依目前位置換算成分數鎖住。
  - 「解除」：清除該詞的排序設定。
  - 「刪除條目」：同時移除該詞在排序與新詞清單中的條目。

每一次操作都會寫入 `history.tsv`；批次拖曳會先做快照，`Ctrl+Z` 可整批還原。

### 新詞與簡碼

1. 在左欄底部輸入「詞」（例如 `一石二鳥`）。
2. 在「碼」欄輸入主碼；多段碼用空白分隔（例如 `jat jat ji niu`）。
3. 按「加入」。詞會寫入 `extra.tsv`。
4. 若 `rules.yaml` 有對應字數的規則，工具會自動再產生簡碼／衍生碼；打簡碼也能出詞。

新詞候選會標示為新詞；若同時符合多種標記，優先序為「新詞 > 固頂 > 調頻」。

### 造詞與刪詞熱鍵

- **造詞**：在組字狀態按 `Shift+Space`，把目前組字結果存成新詞（碼＝當下輸入碼，詞＝目前組字內容）。
  非組字狀態不攔鍵、不吞鍵。
- **刪詞**：在組字狀態按 `Shift+Delete`，刪除游標處由本工具管理的詞。
- 兩者可分別用 `config.ini` 的 `wordhotkey=`、`delhotkey=` 改鍵。

### 多方案

- 安裝器會掃描 `default.custom.yaml` 的 `schema_list`，為每個已啟用方案寫入受管理區塊。
- 方案之間互不干擾：`rank.tsv` 的排序帶「方案:輸入碼」作用域，只套用到完全相同的方案與輸入碼。
- 頂部方案下拉會跟隨目前輸入方案；也可手動切換要編輯的方案。

### Profile 分層

- 每個方案可有獨立的設定目錄：`reorder\profiles\<方案>\`，內含該方案自己的
  `rank.tsv`、`extra.tsv`、`vocab.txt`、`rules.yaml`、`config.ini`。
- 另有共用的 `default` 層；方案尚未建立獨立設定時會沿用共用層（或舊版位置 `reorder\`）。
- 「複製→」可把目前方案的整組設定複製到另一個方案。
- 若目前方案還沒有自己的記錄，右側會出現「『創建』本方案的獨立設定」，按一下即建立。

### 開關項

- **排序生效**（`config.ini` 的 `enabled`）：勾選時排序運作；取消勾選會把 `rank.tsv` 改名為 `rank.tsv.off`，
  **不需要重新部署**。這是「本次是否套用排序」的意向開關。
- **合成詞**（`config.ini` 的 `compose`）：預設 `off`。開啟後才會生成合成候選、做跨段匹配與計分；
  關閉時完全不參與，也不寫相關日誌。
- **上屏記帳**（`config.ini` 的 `commitrecord`）：預設 `on`。引擎已切成多段、又沒有合成候選時，
  會在上屏時把該詞補寫進引擎使用者詞典；`off` 可完全關閉。
- **關閉即解除**（`config.ini` 的 `exitonclose`）：預設 `0`。設為 `1` 時，工作台結束（托盤「結束」）會順手解除排序。

---

## 設定檔說明

設定檔為 `config.ini`，位置在目前方案的設定目錄（例如 `reorder\profiles\<方案>\config.ini`；
未分家時為 `reorder\config.ini`）。格式為 `鍵=值`，一行一項。

| 鍵 | 預設 | 說明 |
| --- | --- | --- |
| `enabled` | `1` | 排序意向開關；`0` 關閉。只認目前方案自己的 `config.ini`。 |
| `compose` | `off` | 合成詞開關；`on` 才生成合成候選、做跨段匹配與計分。 |
| `commitrecord` | `on` | 跨段上屏兜底記帳；`off` 關閉。 |
| `userdb` | `on` | 合成詞上屏寫入引擎使用者詞典：`on`／`off`／`rebuild`（重建後自動改回 `on`）。 |
| `mirror` | `userdb` | 合成詞上屏寫到哪：`userdb`（只寫使用者詞典）／`both`（同時寫 `extra.tsv`）。 |
| `hotkey` | `Ctrl+Alt+R` | 工作台呼出熱鍵（也可從托盤「設定熱鍵」修改）。 |
| `wordhotkey` | `Shift+Space` | 造詞熱鍵。 |
| `delhotkey` | `Shift+Delete` | 刪除本工具詞的熱鍵。 |
| `markstyle` | `emoji` | 候選標記樣式；字型不支援 emoji 時可設 `symbol`。 |
| `split` | `0.580` | 工作台左右欄寬比例（0.25–0.80）。 |
| `exitonclose` | `0` | 工作台結束時是否自動解除排序；`1` 為是。 |
| `undo_keep` | `20` | 撤銷快照保留份數（0–500）。 |
| `backup_keep` | `3` | `_backup` 備份目錄保留份數（0–200）。 |

### rules.yaml

`rules.yaml` 決定「加入新詞時，除了主碼之外還要產生哪些碼」。發行包附的是帶完整註解的範本，
所有規則只作用於本工具管理的詞（`extra.tsv`、`vocab.txt` 新建的詞與其衍生碼），
不會讀寫引擎原生詞庫的碼。

主要內容：

- `prefix_match: on`：開啟不定碼連續輸入的前綴分段匹配（只影響這條路徑）。
- `strict_spelling: off`：設為 `on` 時，帶 `fuzz`／`abbrev` 屬性的碼不能單獨出「單字」，只能參與詞組。
- `rules:` 之下以字數分組：
  - `length_equal: N`＝長度正好 N 個字；
  - `length_in_range: [a, b]`＝a..b；`[a]` 或 `[a, ]`＝至少 a 個字（**不是**正好 a）。
  - `formula: "AaBaCa"`：大寫＝取第幾個字（`A` 第 1 字、`Z` 最後一字），
    小寫＝取該字第幾碼（`a` 第 1 碼、`z` 末碼），兩兩一組依序串接。
- 四算子（逐段套用，格式 `算子/pattern/replacement/`）：
  - `derive`：保留原碼，另外生成一條（模糊音、容錯拼寫）。
  - `xform`：只生成改寫後的碼，不再生成原碼。
  - `abbrev`：生成帶「縮略」屬性的碼（首字母簡拼）。
  - `fuzz`：生成帶「模糊」屬性的碼（全域、不分字數）。

品質：主碼 `4.90`；`formula` 第 1 條 `4.70`、之後每條 −0.20；四算子從更低的品質起算，最低 `1.00`。
規則寫錯時只略過該條，其餘照跑，工作台左下會標示行號。

### vocab.txt

`vocab.txt` 是 UTF-8、TAB 分隔的詞彙清單，可直接用記事本編輯。欄位：

```text
漢字<TAB>編碼<TAB>權重<TAB>類型<TAB>時間
```

- 前 3 欄與 Rime `custom_phrase.txt` 相同（詞、碼、權重），可整份貼入。
- 權重照原值存、照原值排序；`±5` 為硬鎖。
- 編碼可寫「方案:碼」指定方案；沒有前綴時套用到目前作用中的方案。
- 類型（固頂／調頻／新詞）與時間（`YYYY-MM-DD HH:MM`）可留空。
- 刪除一行＝刪除該詞；新增一行＝加入新詞；改權重＝改分數。
- 空行與 `#` 開頭的行會被忽略；壞行跳過並在左下標示行號，不會改寫本檔。

---

## 資料檔與備份

所有執行期資料都在 Rime 使用者目錄下的 `reorder\`：

| 路徑 | 用途 |
| --- | --- |
| `rank.tsv` | 排序分數（`詞`、`分數`、`方案:輸入碼`）。 |
| `extra.tsv` | 新詞與工具產生的衍生碼。 |
| `vocab.txt` | 詞彙清單（可用記事本編輯）。 |
| `rules.yaml` | 簡碼／衍生碼規則。 |
| `history.tsv` | 操作歷史（拖曳、置頂、造詞、刪除等）。 |
| `candidates.tsv` | 最近一次候選快照（工作台顯示用，自動產生）。 |
| `status.tsv` | 心跳與版本資訊（自動產生）。 |
| `undo\` | 撤銷快照。 |
| `_backup\` | 安裝／匯入／重算前的備份。 |
| `_versions\<版本>\` | 每次安裝封存的版本（`reorder.lua`、`RimeReorder.exe`、`install.ps1`），安裝與卸載都不會刪。 |
| `profiles\<方案>\` | 各方案的獨立設定（`default` 為共用層）。 |

> 備份與 `_versions\` 長期保留；若空間吃緊，可自行清理 `_backup\` 內的舊目錄，
> 或在 `config.ini` 調小 `backup_keep`／`undo_keep`。

---

## 常見問題

**Q：按 `Ctrl+Alt+R` 沒反應？**

確認工作台是否正在執行（看托盤圖示）。熱鍵可能被其他程式佔用，請從托盤右鍵選單「設定熱鍵」重新指定；
若仍註冊失敗，程式會提示並改用預設組合。

**Q：狀態燈是紅色？**

紅＝沒有心跳，通常代表工作台沒在跑、或 Rime 尚未重新部署。先開一次工作台，必要時重新部署。

**Q：狀態燈是黃色？**

黃＝心跳正常，但這次輸入沒有候選被移動。可能是目前輸入碼沒有任何排序或新詞命中，屬正常現象。

**Q：排序沒有生效？**

依序檢查：

1. 工作台的「排序生效」是否勾選；
2. 目前方案是否在安裝時被加入（重新執行 `-DryRun` 可預覽）；
3. 是否切到了別的方案的 profile（頂部方案下拉）；
4. 是否剛改過設定但尚未重新部署。

**Q：新詞打了碼卻不出現？**

先看工作台左下的規則回饋是否有錯誤行號。常見原因：碼的段數與詞的字數不一致、
某段碼不夠長、`formula` 寫法不符合規則，或該方案沒有重新載入。新詞本身在 `extra.tsv` 裡就是有效的。

**Q：關掉工作台後，排序還會生效嗎？**

預設會。排序是持久生效的；只有把「排序生效」取消勾選，或把 `exitonclose` 設為 `1` 並結束工作台，
才會停止套用。

**Q：合成詞要怎麼用？**

把 `config.ini` 的 `compose` 設為 `on` 後存檔即生效。連寫輸入時，整串碼會按段查詞、
拼成完整詞參與排序；不符合分段條件時不會生成。預設 `off`，避免影響原本的輸入習慣。

**Q：會不會改動我的詞典？**

不會改 `*.dict.yaml`、`default.yaml`、`build\`，也不接管輸入法服務。只有在你允許的情況下，
合成詞上屏會寫入引擎的使用者詞典（`userdb`），可用 `userdb=off` 關閉。

**Q：卸載後我的調序資料還在嗎？**

在。卸載只移除程式與受管理設定，`rank.tsv`、`extra.tsv`、`vocab.txt`、`history.tsv` 與備份都會保留。

**Q：PowerShell 說腳本被禁止執行？**

請照文件中的指令加上 `-ExecutionPolicy Bypass`：

```powershell
powershell -ExecutionPolicy Bypass -File "$Stage\install.ps1" -Install
```

**Q：可以只裝某幾個方案嗎？**

安裝器以 `default.custom.yaml` 的 `schema_list` 為準；先在方案清單中停用不想裝的方案，
再執行安裝或修復即可。

---

## 檔案清單與校驗

發行包只包含執行所需的最小檔案：

| 檔案（包內路徑） | 大小（位元組） | 目標位置／說明 |
| --- | ---: | --- |
| `lua\reorder.lua` | 157304 | → `<Rime>\lua\reorder.lua`；Lua 外掛本體，版本 1.4.24。 |
| `reorder\RimeReorder.exe` | 257536 | → `<Rime>\reorder\RimeReorder.exe`；工作台程式，版本 1.4.24。 |
| `reorder\rules.yaml` | 6480 | → `<Rime>\reorder\rules.yaml`；簡碼規則範本（僅首次需要）。 |
| `reorder\vocab.txt` | 986 | → `<Rime>\reorder\vocab.txt`；詞彙清單範本（僅首次需要）。 |
| `install.ps1` | 41009 | 留在本機；安裝／修復／還原／卸載腳本，版本 1.4.24。 |
| `README.md` | 本文件 | 留在本機；使用說明。 |

三個核心檔案的 SHA-256 與封存清單一致：

```text
6D9228A380756B2572DC28D53ACF03187955DEDF1EF8DD29803CE0490120FBC3  lua\reorder.lua
552BB383D1CCDB81DF45CB2B1E5D16E887B0B272D35A6D240A7FCF9EEE0EBF86  reorder\RimeReorder.exe
AE3A5A3C47460DB68E9D51287F479C98A547CAC31114FF7A231007F79F274BDB  install.ps1
```

在 PowerShell 可用下列指令自行核對：

```powershell
Get-FileHash .\lua\reorder.lua, .\reorder\RimeReorder.exe, .\install.ps1 -Algorithm SHA256
```

`rules.yaml` 與 `vocab.txt` 是首次使用的範本，不屬於封存清單；若目標位置不存在，
工作台也會自動建立同樣內容的檔案。

---

## 近期更新

- **1.4.24**：修正模組路徑推導失敗時的兜底路徑：改用 `%APPDATA%\Rime`，環境變數為空才退回中性相對路徑；
  移除寫死的本機安裝路徑。其餘行為不變。
- **1.4.23**：合成詞新增獨立開關 `compose`（預設 `off`）。關閉時不生成合成候選、不做切段匹配與計分，
  也不寫相關日誌；開啟後維持 1.4.22 的行為。
- **1.4.22**：「匹配詞」判定下沉到分段，合成候選不再搶走原生第一候選；
  新增跨段上屏兜底記帳 `commitrecord`（預設 `on`）。
- **1.4.21**：修正合成詞上屏後沒有寫入使用者詞典的問題；調整合成候選的位置規則。
- **1.4.20**：新增 `mirror=userdb|both`；使用者詞典寫入改為即時更新，並把每一步寫入 `userdb.log`。
- **1.4.19**：合成詞上屏可鏡像寫入 `extra.tsv` 與使用者詞典；同段內空白視為權威分段。

---

## 鳴謝

- 感謝 **Rime** 與 **小狼毫（Weasel）** 的開發者與社群，提供穩定且可擴充的輸入法平台。
- 感謝 **librime-lua** 的維護者與貢獻者，讓 Lua 外掛能直接參與候選流程。
- 感謝粵語與多方案輸入法方案的作者與使用者，提供了大量實際輸入情境與回饋。
- 感謝所有回報問題、協助測試與提供建議的使用者。

本外掛只是候選排序的輔助工具；輸入法的核心體驗仍來自 Rime 與你所使用的方案。
