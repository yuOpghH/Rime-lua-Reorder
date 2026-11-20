<#
 rime-reorder 安裝器（粵語/多方案候選調序外掛）
 用法：
   powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun
   powershell -ExecutionPolicy Bypass -File install.ps1 -Install
   powershell -ExecutionPolicy Bypass -File install.ps1 -Repair
   powershell -ExecutionPolicy Bypass -File install.ps1 -Restore
   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall

 只做三件事：
   1. 複製 lua\reorder.lua、reorder\ 資料夾與工作台 exe
   2. 在已啟用方案的 <schema>.custom.yaml 內插入/合併受管理標記區塊
   3. 呼叫 WeaselDeployer.exe /deploy 並等心跳

 不碰 userdb、*.dict.yaml、default.yaml、build\ 內的檔案，不刪任何 rar。
#>

param(
    [switch]$Install,
    [switch]$Repair,
    [switch]$Uninstall,
    [switch]$Restore,
    [switch]$DryRun,
    [switch]$NoDeploy,
    [string]$RimeDir = "",
    [int]$DeployTimeoutSec = 600,
    [int]$HeartbeatWaitSec = 60
)

$ErrorActionPreference = "Stop"
$VERSION = "1.4.24"
$BEGIN_MARK = "# >>> rime-reorder:begin"
$END_MARK = "# <<< rime-reorder:end"
$LINE_MARK = "# rime-reorder"
$FILTER_NAME = "lua_filter@*reorder"
$TRANSLATOR_NAME = "lua_translator@*reorder"
$PROCESSOR_NAME = "lua_processor@*reorder"
$TAG_MARK = "# rime-reorder-tag"

# 1.4.5：lua_filter@*reorder 移到「會改寫字形的 simplifier」之前。
# Rime 的補丁只認數字下標（ConfigData::ResolveListIndex 解析 before/after/next/last＋數字），
# 不支援按名稱定位；而 patch 鍵以字典序套用（ConfigMap 為 std::map），
# 所以下表的下標是「該方案的 filters 清單在套用完同檔其他 engine/filters 補丁後」的位置。
# Index = -1／未列出＝維持附加在 filters 末尾。
# Anchor 只供安裝後核對 build 與報告用（空字串＝只要求排在指定下標）。
$FilterBefore = @{
    jyutsp_goi             = @{ Index = 5; Anchor = "simplifier@zh_simp2" }
    jyutsp_lab_v2          = @{ Index = 5; Anchor = "simplifier@zh_simp2" }
    jyut_sp4ver3           = @{ Index = 5; Anchor = "simplifier@zh_simp2" }
    jyut_sp4ver4           = @{ Index = 5; Anchor = "simplifier@zh_simp2" }
    jyutsp_lab_v1          = @{ Index = 3; Anchor = "simplifier@zh_simp2" }
    jyutsp_reallm          = @{ Index = 1; Anchor = "simplifier@zh_simp2" }
    jyutsp_newloengfan_goi = @{ Index = 5; Anchor = "simplifier@zh_simp2" }
    jyut6ping3             = @{ Index = 0; Anchor = "" }
    # cangjie5 不能插到 0：同檔已有 "engine/filters/@before 0"（cangjie5_suggestion），
    # 同鍵會被覆蓋。字典序 0→1，故用 1：插在 suggestion 之後、內建 simplifier 之前。
    cangjie5               = @{ Index = 1; Anchor = "simplifier" }
}

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  [!!] $msg" -ForegroundColor Yellow }
function Write-Err2($msg) { Write-Host "  [XX] $msg" -ForegroundColor Red }
function Write-Plan($msg) { Write-Host "  [計劃] $msg" -ForegroundColor DarkYellow }

# ---------- 路徑解析 ----------

function Resolve-RimeDir {
    if ($script:RimeDir -and $script:RimeDir.Trim() -ne "") {
        $p = $script:RimeDir.Trim()
        if (Test-Path $p) { return (Resolve-Path $p).Path }
        throw "指定的 RimeDir 不存在：$p"
    }
    $reg = Get-ItemProperty -Path "HKCU:\Software\Rime\Weasel" -ErrorAction SilentlyContinue
    if ($reg -and $reg.RimeUserDir) {
        $p = $reg.RimeUserDir
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    $fallback = Join-Path $env:APPDATA "Rime"
    if (Test-Path $fallback) { return (Resolve-Path $fallback).Path }
    throw "找不到 Rime 使用者目錄（登錄檔 RimeUserDir 與 %APPDATA%\Rime 均不可用）"
}

function Resolve-Deployer {
    $srv = Get-Process WeaselServer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($srv -and $srv.Path) {
        $dir = Split-Path $srv.Path -Parent
        $dep = Join-Path $dir "WeaselDeployer.exe"
        if (Test-Path $dep) { return $dep }
    }
    $cands = Get-ChildItem "C:\Program Files\Rime" -Filter "WeaselDeployer.exe" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    if ($cands.Count -gt 0) { return $cands[0].FullName }
    return ""
}

function Resolve-Payload {
    $here = $PSScriptRoot
    $p1 = Join-Path $here "payload"
    if (Test-Path (Join-Path $p1 "lua\reorder.lua")) {
        $exe = Join-Path $p1 "RimeReorder.exe"
        $dep = Join-Path $p1 "RimeDeploy.exe"
        return @{
            Lua = (Join-Path $p1 "lua\reorder.lua")
            Exe = $(if (Test-Path $exe) { $exe } else { "" })
            Deploy = $(if (Test-Path $dep) { $dep } else { "" })
        }
    }
    # 版本封存包（reorder\_versions\<ver>\）：reorder.lua + RimeReorder.exe + install.ps1 同一層
    $archLua = Join-Path $here "reorder.lua"
    if (Test-Path $archLua) {
        $archExe = Join-Path $here "RimeReorder.exe"
        return @{
            Lua = (Resolve-Path $archLua).Path
            Exe = $(if (Test-Path $archExe) { (Resolve-Path $archExe).Path } else { "" })
            Deploy = ""
        }
    }
    $devLua = Join-Path $here "..\lua\reorder.lua"
    if (-not (Test-Path $devLua)) {
        throw "找不到 payload（lua\reorder.lua / RimeReorder.exe）"
    }
    $devExe = Join-Path $here "..\gui\RimeReorder.exe"
    $devDep = Join-Path (Split-Path (Split-Path $here -Parent) -Parent) "tools\RimeDeploy.exe"
    return @{
        Lua = (Resolve-Path $devLua).Path
        Exe = $(if (Test-Path $devExe) { (Resolve-Path $devExe).Path } else { "" })
        Deploy = $(if (Test-Path $devDep) { (Resolve-Path $devDep).Path } else { "" })
    }
}

function Resolve-ServerPath {
    $srv = Get-Process WeaselServer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($srv -and $srv.Path) { return $srv.Path }
    $c = Get-ChildItem "C:\Program Files\Rime" -Filter "WeaselServer.exe" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    if ($c.Count -gt 0) { return $c[0].FullName }
    return ""
}

# 1.3.11：安裝前先關掉執行中的工作台（托盤程式沒有可見主視窗，正常關閉失敗就終止）
function Stop-ReorderGui {
    $procs = @(Get-Process RimeReorder -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return }
    Write-Warn2 "偵測到 RimeReorder 正在執行（$($procs.Count) 個），先關閉…"
    foreach ($p in $procs) {
        try { [void]$p.CloseMainWindow() } catch { }
    }
    Start-Sleep -Milliseconds 900
    $procs = @(Get-Process RimeReorder -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        foreach ($p in $procs) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {
                throw "無法結束 RimeReorder（PID $($p.Id)）：$($_.Exception.Message)"
            }
        }
        Start-Sleep -Milliseconds 600
    }
}

# ---------- 檔案讀寫（保留 BOM 與換行） ----------

function Read-Utf8File($path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $bom = $false
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bom = $true
        $offset = 3
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $text = if ($bytes.Length -gt $offset) { $enc.GetString($bytes, $offset, $bytes.Length - $offset) } else { "" }
    $crlf = $text.Contains("`r`n")
    return @{ Text = $text; Bom = $bom; Crlf = $crlf }
}

function Write-Utf8File($path, $text, [bool]$bom) {
    $enc = New-Object System.Text.UTF8Encoding($bom)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

function ConvertTo-Lines($text) {
    if ($text -eq $null) { return @() }
    return ($text -split "`r?`n")
}

function Join-Lines($lines, [bool]$crlf, [bool]$trailing) {
    $nl = if ($crlf) { "`r`n" } else { "`n" }
    $out = [string]::Join($nl, $lines)
    if ($trailing) {
        if (-not $out.EndsWith($nl)) { $out += $nl }
    } else {
        while ($out.EndsWith($nl)) { $out = $out.Substring(0, $out.Length - $nl.Length) }
    }
    return $out
}

# 1.4.5：從已編譯的 build\<schema>.schema.yaml 取出 engine.filters 清單（實測順序的唯一依據）
function Get-BuildFilterList($path) {
    $lines = ConvertTo-Lines (Read-Utf8File $path).Text
    $out = New-Object System.Collections.ArrayList
    $inList = $false
    $baseIndent = 0
    foreach ($line in $lines) {
        if (-not $inList) {
            if ($line -match "^(\s*)filters\s*:\s*$") { $inList = $true; $baseIndent = $matches[1].Length }
            continue
        }
        if ($line -match "^\s*$") { continue }
        if ($line -match "^\s*#") { continue }
        $ind = ($line -replace "^(\s*).*", '$1').Length
        if ($ind -le $baseIndent) { break }
        if ($line -match "^\s*-\s*(.+?)\s*$") {
            $v = $matches[1].Trim().Trim('"', "'")
            $v = ($v -split "\s+#")[0].Trim()
            [void]$out.Add($v)
        }
    }
    return @($out.ToArray())
}

# ---------- 方案清單 ----------

function Get-EnabledSchemas($rimeDir) {
    $def = Join-Path $rimeDir "default.custom.yaml"
    $text = ""
    if (Test-Path $def) {
        $text = (Read-Utf8File $def).Text
    } else {
        $defYaml = Join-Path $rimeDir "build\default.yaml"
        if (Test-Path $defYaml) { $text = (Read-Utf8File $defYaml).Text }
    }
    if ($text -eq "") { return @() }
    $lines = ConvertTo-Lines $text
    $inList = $false
    $baseIndent = 0
    $schemas = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if (-not $inList) {
            if ($line -match "^(\s*)schema_list\s*:\s*$") { $inList = $true; $baseIndent = $matches[1].Length }
            continue
        }
        if ($line -match "^\s*$") { continue }
        if ($line -match "^\s*#") { continue }
        $ind = ($line -replace "^(\s*).*", '$1').Length
        if ($ind -le $baseIndent -and $line -match "\S") { break }
        $m = [regex]::Match($line, "\{schema:\s*([^\s,}\]]+)")
        if ($m.Success) { [void]$schemas.Add($m.Groups[1].Value); continue }
        $m2 = [regex]::Match($line, "-?\s*schema:\s*([^\s#]+)")
        if ($m2.Success) { [void]$schemas.Add($m2.Groups[1].Value.Trim('"', "'")) }
    }
    return $schemas
}

# ---------- 受管理區塊 ----------

function Build-BlockLines([int]$indent, [bool]$needFilter, [bool]$needTranslator, [int]$filterIndex) {
    $pad = " " * $indent
    $pad2 = " " * ($indent + 2)
    $pad4 = " " * ($indent + 4)
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add("$pad$BEGIN_MARK")
    # 處理器：造詞熱鍵（1.3.2 起必裝；@before 0 先於所有內建處理器攔鍵）
    [void]$out.Add("${pad}`"engine/processors/@before 0`": `"$PROCESSOR_NAME`" $LINE_MARK")
    if ($filterIndex -ge 0) {
        # 1.4.5：插在指定下標，讓 reorder 先於會改寫字形的 simplifier
        [void]$out.Add("${pad}`"engine/filters/@before $filterIndex`": `"$FILTER_NAME`" $LINE_MARK")
    } elseif ($needFilter) {
        [void]$out.Add("${pad}engine/filters/+:")
        [void]$out.Add("$pad2- `"$FILTER_NAME`"")
    }
    if ($needTranslator) {
        [void]$out.Add("${pad}engine/translators/+:")
        [void]$out.Add("$pad2- `"$TRANSLATOR_NAME`"")
        # 第二個實例只吃 fixed 段（反引號造詞模式），讓新詞在該模式看得到
        [void]$out.Add("$pad2- translator: `"$TRANSLATOR_NAME`"")
        [void]$out.Add("${pad4}tag: fixed $TAG_MARK")
    }
    [void]$out.Add("$pad$END_MARK")
    return $out
}

function Find-PatchInfo($lines) {
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^(\s*)patch\s*:\s*$") {
            $indent = $matches[1].Length
            $child = $indent + 2
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match "^\s*$") { continue }
                if ($lines[$j] -match "^\s*#") { continue }
                $ci = ($lines[$j] -replace "^(\s*).*", '$1').Length
                if ($ci -gt $indent) { $child = $ci } else { break }
                break
            }
            return @{ Index = $i; Indent = $indent; Child = $child }
        }
    }
    return $null
}

function Find-Block($lines) {
    $b = -1; $e = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($b -eq -1 -and $lines[$i].Contains($BEGIN_MARK)) { $b = $i }
        elseif ($b -ne -1 -and $lines[$i].Contains($END_MARK)) { $e = $i; break }
    }
    return @{ Begin = $b; End = $e }
}

function Find-KeyLine($lines, $keyPattern, $fromIndex) {
    $kp = [regex]::Escape($keyPattern)
    for ($i = $fromIndex; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^(\s*)(?:`"$kp`"|$kp)\s*:[ \t]*(.*)$") {
            $val = $matches[2].Trim()
            if ($val -ne "" -and -not $val.StartsWith("#")) {
                return @{ Index = $i; Indent = $matches[1].Length; Inline = $true; Value = $val }
            }
            return @{ Index = $i; Indent = $matches[1].Length; Inline = $false; Value = "" }
        }
    }
    return $null
}

function Get-ListEnd($lines, $keyIndex, $keyIndent) {
    $end = $keyIndex
    for ($i = $keyIndex + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$") { continue }
        if ($lines[$i] -match "^\s*#") { $end = $i; continue }
        $ind = ($lines[$i] -replace "^(\s*).*", '$1').Length
        if ($ind -gt $keyIndent) { $end = $i } else { break }
    }
    return $end
}

function Convert-InlineListToBlock($line, $keyPattern, [bool]$crlf) {
    # 只處理簡單 flow list： key: [ a, b ]
    $kp = [regex]::Escape($keyPattern)
    $m = [regex]::Match($line, "^(\s*)(?:`"$kp`"|$kp)\s*:\s*\[(.*)\]\s*(#.*)?$")
    if (-not $m.Success) { return $null }
    $indent = $m.Groups[1].Value
    $inner = $m.Groups[2].Value
    $items = @()
    foreach ($piece in ($inner -split ",")) {
        $v = $piece.Trim().Trim('"', "'")
        if ($v -ne "") { $items += $v }
    }
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add("${indent}${keyPattern}:")
    foreach ($it in $items) { [void]$out.Add("$indent  - `"$it`"") }
    return $out
}

# 回傳：@{ Lines; Modes = @{filters=block|inline|beforeN; translators=...}; Changed }
function Apply-ManagedBlock($lines, [bool]$crlf, [int]$filterIndex) {
    # 先清掉上次安裝殘留的 inline 追加行（冪等 / Repair）
    $clean = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ($line -match "^\s*-\s*" -and ($line.Contains($LINE_MARK) -or $line.Contains($FILTER_NAME) -or $line.Contains($TRANSLATOR_NAME))) { continue }
        if ($line.Contains($TAG_MARK)) { continue }
        if ($line.Contains($PROCESSOR_NAME) -and $line.Contains($LINE_MARK)) { continue }
        # 1.4.5：區塊外的 @before 定位行（舊版殘留或修復中斷）一併清掉
        if ($line -match "engine/filters/@before\s+\d+" -and $line.Contains($FILTER_NAME)) { continue }
        [void]$clean.Add($line)
    }
    $lines = $clean.ToArray()

    $patch = Find-PatchInfo $lines
    if ($patch -eq $null) {
        $lines = @("patch:") + $lines
        $patch = Find-PatchInfo $lines
        if ($patch -eq $null) { throw "無法建立 patch: 區段" }
    }

    $block = Find-Block $lines
    if ($block.Begin -ne -1 -and $block.End -gt $block.Begin) {
        $keep = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($i -ge $block.Begin -and $i -le $block.End) { continue }
            [void]$keep.Add($lines[$i])
        }
        $lines = $keep.ToArray()
        $patch = Find-PatchInfo $lines
    }

    $modes = @{ filters = "block"; translators = "block" }
    $inline = @()

    # 1.4.5：指定了下標的方案，filter 由區塊內的 @before 行負責，
    # 不能再往使用者的 engine/filters/+ 追加（否則會同時留下兩份）。
    $pairs = @(@{ Key = "engine/translators/+"; Item = $TRANSLATOR_NAME; Mode = "translators" })
    if ($filterIndex -ge 0) {
        $modes["filters"] = "before$filterIndex"
    } else {
        $pairs = @(@{ Key = "engine/filters/+"; Item = $FILTER_NAME; Mode = "filters" }) + $pairs
    }

    foreach ($pair in $pairs) {
        $key = $pair.Key
        $found = Find-KeyLine $lines $key 0
        if ($found -ne $null) {
            if ($found.Inline) {
                $conv = Convert-InlineListToBlock $lines[$found.Index] $key $crlf
                if ($conv -eq $null) { throw "無法解析 $key 的 inline 列表（$($lines[$found.Index])）" }
                $tail = @()
                if ($found.Index + 1 -lt $lines.Count) { $tail = $lines[($found.Index + 1)..($lines.Count - 1)] }
                $head = @()
                if ($found.Index -gt 0) { $head = $lines[0..($found.Index - 1)] }
                $lines = @($head) + @($conv) + @($tail)
            }
            $found = Find-KeyLine $lines $key 0
            $end = Get-ListEnd $lines $found.Index $found.Indent
            $itemIndent = " " * ($found.Indent + 2)
            if ($pair.Mode -eq "translators") {
                # 主 translator + 只吃 fixed 段的第二實例
                $inline += @{ Index = $end + 1; Text = @(
                    "$itemIndent- `"$($pair.Item)`" $LINE_MARK",
                    "$itemIndent- translator: `"$($pair.Item)`"",
                    "$itemIndent  tag: fixed $TAG_MARK"
                ) }
            } else {
                $inline += @{ Index = $end + 1; Text = @("$itemIndent- `"$($pair.Item)`" $LINE_MARK") }
            }
            $modes[$pair.Mode] = "inline"
        }
    }

    # 先插入 inline 項目（由後往前，避免索引位移）
    foreach ($ins in ($inline | Sort-Object Index -Descending)) {
        $add = @($ins.Text)
        if ($ins.Index -ge $lines.Count) { $lines = @($lines) + $add }
        else {
            $head = @(); if ($ins.Index -gt 0) { $head = $lines[0..($ins.Index - 1)] }
            $tail = @(); if ($ins.Index -lt $lines.Count) { $tail = $lines[$ins.Index..($lines.Count - 1)] }
            $lines = @($head) + $add + @($tail)
        }
    }

    $needFilter = $modes["filters"] -eq "block"
    $needTranslator = $modes["translators"] -eq "block"

    # 處理器是一定要的，所以受管理區塊永遠建立（即使 filter/translator 走 inline）
    $patch = Find-PatchInfo $lines
    $blockLines = Build-BlockLines $patch.Child $needFilter $needTranslator $filterIndex
    $insAt = $patch.Index + 1
    $head = @(); if ($insAt -gt 0) { $head = $lines[0..($insAt - 1)] }
    $tail = @(); if ($insAt -lt $lines.Count) { $tail = $lines[$insAt..($lines.Count - 1)] }
    $lines = @($head) + @($blockLines) + @($tail)

    return @{ Lines = $lines; Modes = $modes; Block = ($blockLines -join "`n") }
}

function Remove-ManagedBlock($lines) {
    $out = New-Object System.Collections.ArrayList
    $inBlock = $false
    foreach ($line in $lines) {
        if ($line.Contains($BEGIN_MARK)) { $inBlock = $true; continue }
        if ($inBlock) {
            if ($line.Contains($END_MARK)) { $inBlock = $false }
            continue
        }
        if ($line -match "^\s*-\s*" -and ($line.Contains($LINE_MARK) -or $line.Contains($FILTER_NAME) -or $line.Contains($TRANSLATOR_NAME))) { continue }
        if ($line.Contains($TAG_MARK)) { continue }
        if ($line.Contains($PROCESSOR_NAME) -and $line.Contains($LINE_MARK)) { continue }
        # 1.4.5：區塊外的 @before 定位行（標記殘留）也要清掉
        if ($line -match "engine/filters/@before\s+\d+" -and $line.Contains($FILTER_NAME)) { continue }
        [void]$out.Add($line)
    }
    return $out.ToArray()
}

# ---------- 安裝主體 ----------

function Get-BackupRoot($rimeDir) { return (Join-Path $rimeDir "reorder\_backup") }

function New-Backup($rimeDir) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $dir = Join-Path (Get-BackupRoot $rimeDir) $stamp
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

# 1.3.20：每次安裝都把「本次安裝的版本」留一份到 reorder\_versions\<version>\
# （reorder.lua + RimeReorder.exe + install.ps1，可獨立重裝）。此目錄長期保留，
# 安裝／卸載／備份清理都不會刪除它。
function Save-VersionArchive($rimeDir, $payload) {
    $verRoot = Join-Path $rimeDir "reorder\_versions\$VERSION"
    New-Item -ItemType Directory -Force -Path $verRoot | Out-Null
    $luaDest = Join-Path $verRoot "reorder.lua"
    Copy-Item $payload.Lua $luaDest -Force
    if ($payload.Exe -and (Test-Path $payload.Exe)) {
        Copy-Item $payload.Exe (Join-Path $verRoot "RimeReorder.exe") -Force
    }
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        Copy-Item $PSCommandPath (Join-Path $verRoot "install.ps1") -Force
    }
    $h = (Get-FileHash $luaDest -Algorithm SHA256).Hash
    Write-Ok "已封存版本 $VERSION → $verRoot（lua sha256=$h）"
    return $verRoot
}

function Install-Managed($rimeDir, $payload, [bool]$dry) {
    $schemas = Get-EnabledSchemas $rimeDir
    if ($schemas.Count -eq 0) { throw "default.custom.yaml 內找不到 schema_list（沒有已啟用方案）" }
    Write-Step "已啟用方案：$($schemas -join ', ')"

    $backupDir = ""
    if (-not $dry) { $backupDir = New-Backup $rimeDir }

    $manifestFiles = New-Object System.Collections.ArrayList
    $changedFiles = New-Object System.Collections.ArrayList

    foreach ($schema in $schemas) {
        $file = Join-Path $rimeDir "$schema.custom.yaml"
        $created = -not (Test-Path $file)
        $crlf = $true
        $trailing = $true
        $text = "patch:`r`n"
        if (-not $created) {
            $r = Read-Utf8File $file
            $text = $r.Text
            $crlf = $r.Crlf
            $trailing = $text.EndsWith("`n")
        }
        $lines = @(ConvertTo-Lines $text)
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq "") {
            $lines = $lines[0..($lines.Count - 2)]
        }

        $filterIndex = -1
        if ($FilterBefore.ContainsKey($schema)) { $filterIndex = [int]$FilterBefore[$schema].Index }

        $result = Apply-ManagedBlock $lines $crlf $filterIndex
        $newText = Join-Lines $result.Lines $crlf $trailing

        Write-Step "方案 $schema → $file"
        Write-Plan "模式：filters=$($result.Modes['filters']), translators=$($result.Modes['translators']), 新建=$created"
        Write-Plan "區塊內容："
        foreach ($l in $result.Lines) {
            if ($l.Contains("rime-reorder") -or $l -match "engine/(filters|translators)/\+|engine/filters/@before" -or $l -match "lua_(filter|translator|processor)@\*reorder") {
                Write-Host "      |$l" -ForegroundColor DarkGray
            }
        }

        if ($dry) {
            $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
            if (-not $created) {
                $oldHash = (Get-FileHash $file -Algorithm SHA256).Hash
                Write-Plan "備份 → $(Join-Path $rimeDir "reorder\_backup\$stamp")`\$schema.custom.yaml (sha256=$oldHash)"
            }
            continue
        }

        if (-not $created) {
            Copy-Item $file (Join-Path $backupDir "$schema.custom.yaml") -Force
        }
        $bom = if ($created) { $false } else { (Read-Utf8File $file).Bom }
        Write-Utf8File $file $newText $bom
        $hash = (Get-FileHash $file -Algorithm SHA256).Hash
        [void]$changedFiles.Add($file)
        [void]$manifestFiles.Add(@{
            file = "$schema.custom.yaml"
            schema = $schema
            backup = $(if ($created) { "" } else { Join-Path $backupDir "$schema.custom.yaml" })
            sha256 = $hash
            mode = "filters:$($result.Modes['filters']),translators:$($result.Modes['translators'])"
            created = $created
        })
    }

    if ($dry) { return }

    # 複製 payload
    $luaDir = Join-Path $rimeDir "lua"
    New-Item -ItemType Directory -Force -Path $luaDir | Out-Null
    $luaDest = Join-Path $luaDir "reorder.lua"
    if (Test-Path $luaDest) { Copy-Item $luaDest (Join-Path $backupDir "reorder.lua") -Force }
    Copy-Item $payload.Lua $luaDest -Force
    Write-Ok "已安裝 lua\reorder.lua"

    $dataDir = Join-Path $rimeDir "reorder"
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    if (Test-Path $payload.Exe) {
        $exeDest = Join-Path $dataDir "RimeReorder.exe"
        Stop-ReorderGui
        $exeBak = Join-Path $backupDir "RimeReorder.exe"
        if (Test-Path $exeDest) { Copy-Item $exeDest $exeBak -Force }
        try {
            Copy-Item $payload.Exe $exeDest -Force -ErrorAction Stop
            Write-Ok "已安裝 reorder\RimeReorder.exe（舊版已備份）"
        } catch {
            if (Test-Path $exeBak) { Copy-Item $exeBak $exeDest -Force -ErrorAction SilentlyContinue }
            throw "複製 reorder\RimeReorder.exe 失敗：$($_.Exception.Message)"
        }
    } else {
        Write-Warn2 "payload 缺少 RimeReorder.exe（工作台未安裝，lua 仍可用）"
    }
    if ($payload.Deploy -and (Test-Path $payload.Deploy)) {
        Copy-Item $payload.Deploy (Join-Path $dataDir "RimeDeploy.exe") -Force
        Write-Ok "已安裝 reorder\RimeDeploy.exe（headless 部署用）"
    }
    $archiveDir = Save-VersionArchive $rimeDir $payload
    # 只在「從未用過」時才建立空的 rank.tsv；若已有 rank.tsv.off（使用者把「排序生效」關掉）
    # 就不建，避免安裝後 L1 被悄悄重新啟用
    if ((Test-Path (Join-Path $dataDir "rank.tsv.off")) -eq $false -and
        (Test-Path (Join-Path $dataDir "rank.tsv")) -eq $false) {
        Write-Utf8File (Join-Path $dataDir "rank.tsv") "#v1`r`n" $false
    }
    if (-not (Test-Path (Join-Path $dataDir "extra.tsv"))) {
        Write-Utf8File (Join-Path $dataDir "extra.tsv") "#v1`r`n" $false
    }
    # 熱鍵設定（工作台托盤「設定熱鍵」與 lua 造詞熱鍵共用此檔）
    if (-not (Test-Path (Join-Path $dataDir "config.ini"))) {
        Write-Utf8File (Join-Path $dataDir "config.ini") "# rime-reorder 設定`r`nhotkey=Ctrl+Alt+R`r`nwordhotkey=Shift+Space`r`n" $false
        Write-Ok "已建立 reorder\config.ini（hotkey=Ctrl+Alt+R / wordhotkey=Shift+Space）"
    }

    $blockText = $result.Block
    $manifest = @{
        version = $VERSION
        installed_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        rime_dir = $rimeDir
        backup_dir = $backupDir
        archive_dir = $archiveDir
        block_hash = (Get-FileHash (Join-Path $luaDir "reorder.lua") -Algorithm SHA256).Hash
        block_text = $blockText
        files = @($manifestFiles)
    }
    $manifestPath = Join-Path $dataDir "manifest.json"
    $json = $manifest | ConvertTo-Json -Depth 6
    Write-Utf8File $manifestPath $json $false
    Write-Utf8File (Join-Path $backupDir "manifest.json") $json $false
    Write-Ok "已寫入 manifest：$manifestPath"
}

function Restart-WeaselServer {
    $srv = Resolve-ServerPath
    if ($srv -eq "") { Write-Warn2 "找不到 WeaselServer.exe，略過重啟"; return }
    $p = Get-Process WeaselServer -ErrorAction SilentlyContinue
    if ($p) {
        try { Start-Process -FilePath $srv -ArgumentList "/q" -WindowStyle Hidden | Out-Null } catch { }
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Process WeaselServer -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 300
        }
        $still = Get-Process WeaselServer -ErrorAction SilentlyContinue
        if ($still) { $still | Stop-Process -Force; Start-Sleep -Milliseconds 500 }
    }
    Start-Process -FilePath $srv -WorkingDirectory (Split-Path $srv -Parent) | Out-Null
    Start-Sleep -Seconds 1
    if (Get-Process WeaselServer -ErrorAction SilentlyContinue) { Write-Ok "WeaselServer 已重啟（載入新 build）" }
    else { Write-Warn2 "WeaselServer 重啟後未偵測到進程" }
}

function Invoke-Deploy($rimeDir, $deployer, $payload, [bool]$dry, [int]$waitSec) {
    if ($NoDeploy) {
        Write-Warn2 "已指定 -NoDeploy，跳過部署（測試用）"
        return "dry"
    }

    $instDir = ""
    if ($deployer -ne "") { $instDir = Split-Path $deployer -Parent }
    elseif ((Resolve-ServerPath) -ne "") { $instDir = Split-Path (Resolve-ServerPath) -Parent }
    $rimeDll = if ($instDir -ne "") { Join-Path $instDir "rime.dll" } else { "" }
    $shared = if ($instDir -ne "") { Join-Path $instDir "data" } else { "" }

    $headless = ""
    if ($payload -and $payload.Deploy -and (Test-Path $payload.Deploy)) { $headless = $payload.Deploy }
    elseif (Test-Path (Join-Path $rimeDir "reorder\RimeDeploy.exe")) { $headless = Join-Path $rimeDir "reorder\RimeDeploy.exe" }

    if ($dry) {
        if ($headless -ne "" -and $rimeDll -ne "") {
            Write-Plan "部署命令（headless）：`"$headless`" `"$rimeDll`" `"$shared`" `"$rimeDir`""
        }
        if ($deployer -ne "") { Write-Plan "備援部署命令：`"$deployer`" /deploy" }
        return "dry"
    }

    $start = Get-Date
    $deployed = $false

    if ($headless -ne "" -and (Test-Path $rimeDll)) {
        Write-Step "部署（headless）：$headless"
        $hp = Start-Process -FilePath $headless -ArgumentList @("`"$rimeDll`"", "`"$shared`"", "`"$rimeDir`"") -PassThru -WindowStyle Hidden
        $hpOk = $false
        if ($hp) { $hpOk = $hp.WaitForExit(180000) }
        if ($hpOk -and $hp.ExitCode -eq 0) {
            Write-Ok "headless 部署完成（ExitCode=0）"
            $deployed = $true
        } else {
            Write-Warn2 "headless 部署失敗或逾時，改用 WeaselDeployer"
            if ($hp -and -not $hp.HasExited) { Stop-Process -Id $hp.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    if (-not $deployed -and $deployer -ne "") {
        Write-Step "部署（WeaselDeployer）：$deployer /deploy"
        $wp = Start-Process -FilePath $deployer -ArgumentList "/deploy" -PassThru -WindowStyle Hidden
        $wpOk = $false
        if ($wp) { $wpOk = $wp.WaitForExit(120000) }
        if ($wpOk -and $wp.ExitCode -eq 0) {
            Write-Ok "WeaselDeployer 完成（ExitCode=0）"
            $deployed = $true
        } else {
            if ($wp -and -not $wp.HasExited) { Stop-Process -Id $wp.Id -Force -ErrorAction SilentlyContinue }
            Write-Err2 "WeaselDeployer 未能完成（視窗可能停在設定對話框）"
        }
    }

    if (-not $deployed) { return "red" }
    Write-Ok "部署耗時 $([int]((Get-Date) - $start).TotalSeconds) 秒"

    # 檢查 build 內是否真的出現我們的元件（filter + translator(+fixed) + processor）
    $schemas = Get-EnabledSchemas $rimeDir
    $loaded = 0
    foreach ($s in $schemas) {
        $b = Join-Path $rimeDir "build\$s.schema.yaml"
        if (Test-Path $b) {
            $t = (Read-Utf8File $b).Text
            if ($t.Contains($FILTER_NAME) -and $t.Contains($TRANSLATOR_NAME) -and $t.Contains($PROCESSOR_NAME)) { $loaded++ }
        }
    }
    Write-Ok "build 內含 filter+translator+processor 的方案數：$loaded / $($schemas.Count)"
    if ($loaded -eq 0) {
        Write-Err2 "部署後 build 未包含 $FILTER_NAME / $TRANSLATOR_NAME / $PROCESSOR_NAME（lua 外掛可能未被載入）"
        return "red"
    }

    # 1.4.5：核對每個方案 build 內 filters 的真實順序（下標以編譯結果為準）
    Write-Step "核對 build 內 filters 順序"
    $orderBad = $false
    foreach ($s in $schemas) {
        $b = Join-Path $rimeDir "build\$s.schema.yaml"
        if (-not (Test-Path $b)) { Write-Warn2 "$s：找不到 build\$s.schema.yaml，略過核對"; continue }
        $items = Get-BuildFilterList $b
        $ri = [Array]::IndexOf($items, $FILTER_NAME)
        if ($ri -lt 0) { Write-Warn2 "$s：build 內找不到 $FILTER_NAME"; $orderBad = $true; continue }
        $desc = ($items | ForEach-Object { if ($_ -eq $FILTER_NAME) { "[$_]" } else { $_ } }) -join " → "
        Write-Host "  $s：reorder 下標=$ri／$desc" -ForegroundColor DarkGray
        if ($FilterBefore.ContainsKey($s)) {
            $want = [int]$FilterBefore[$s].Index
            $anchor = [string]$FilterBefore[$s].Anchor
            $nextOk = $true
            if ($anchor -ne "") {
                $nextOk = ($ri + 1 -lt $items.Count) -and ($items[$ri + 1] -eq $anchor)
            }
            if ($ri -ne $want -or -not $nextOk) {
                Write-Err2 "$s：預期下標=$want$(if ($anchor -ne '') { "、後接=$anchor" })，實際下標=$ri$(if ($ri + 1 -lt $items.Count) { "、後接=$($items[$ri + 1])" })"
                $orderBad = $true
            } else {
                Write-Ok "$s：位置正確（下標=$ri$(if ($anchor -ne '') { "，緊鄰 $anchor 之前" })）"
            }
        }
    }
    if ($orderBad) { Write-Warn2 "有方案的 filters 位置與預期不符；部署已繼續，但請檢查上面的清單" }

    # 讓常駐後的 WeaselServer 重新載入 build
    Restart-WeaselServer

    if ($waitSec -le 0) { return "yellow" }

    # 等心跳（需在輸入框打字才會觸發；時間戳需晚於本次部署開始）
    $status = Join-Path $rimeDir "reorder\status.tsv"
    $deadline = (Get-Date).AddSeconds($waitSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $status) {
            $mt = (Get-Item $status).LastWriteTime
            if ($mt -gt $start) {
                $txt = (Read-Utf8File $status).Text
                Write-Ok "收到心跳：$($txt -replace "`r?`n", ' | ')"
                $moved = 0
                foreach ($ln in (ConvertTo-Lines $txt)) {
                    if ($ln -match "^moved\t(\d+)") { $moved = [int]$matches[1] }
                }
                if ($moved -gt 0) {
                    Write-Ok "排序確實生效（moved=$moved）"
                    return "green"
                }
                Write-Warn2 "心跳正常但排序未改變（多半尚未有排序規則，或未重新部署）"
                return "yellow"
            }
        }
        Start-Sleep -Seconds 2
    }
    Write-Warn2 "部署完成但尚未收到心跳（需在輸入框中打字才會觸發）"
    return "yellow"
}

function Do-Install([bool]$dry, [bool]$repair) {
    $dir = Resolve-RimeDir
    Write-Step "Rime 使用者目錄：$dir"
    $payload = Resolve-Payload
    Write-Step "payload：$($payload.Lua) / $($payload.Exe)"
    $deployer = Resolve-Deployer
    Write-Step "部署器：$deployer"

    Install-Managed $dir $payload $dry
    if ($dry) {
        Invoke-Deploy $dir $deployer $payload $true 0 | Out-Null
        Write-Step "DryRun 結束：未修改任何檔案"
        return
    }
    $r = Invoke-Deploy $dir $deployer $payload $false $HeartbeatWaitSec
    if ($r -eq "red") {
        Write-Err2 "部署失敗，自動還原最後一次備份"
        Do-Restore $dir $payload
        throw "部署失敗，已還原"
    }
    Write-Step "安裝完成（狀態：$r）"
    Write-Host "  工作台：$dir\reorder\RimeReorder.exe（Ctrl+Alt+R）"
}

# ---------- 還原 / 卸載 ----------

function Get-LatestBackup($rimeDir) {
    $root = Get-BackupRoot $rimeDir
    if (-not (Test-Path $root)) { return $null }
    $dirs = Get-ChildItem $root -Directory | Sort-Object Name -Descending
    if ($dirs.Count -eq 0) { return $null }
    return $dirs[0].FullName
}

function Do-Restore($rimeDir, $payload) {
    $b = Get-LatestBackup $rimeDir
    if ($b -eq $null) { Write-Err2 "沒有可用的備份"; return }
    Write-Step "還原自：$b"
    $manifestPath = Join-Path $b "manifest.json"
    if (Test-Path $manifestPath) {
        $mf = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($f in $mf.files) {
            $dest = Join-Path $rimeDir $f.file
            if ($f.created -eq $true) {
                if (Test-Path $dest) { Remove-Item $dest -Force; Write-Ok "移除安裝時新建的 $($f.file)" }
            } elseif ($f.backup -and (Test-Path $f.backup)) {
                Copy-Item $f.backup $dest -Force
                Write-Ok "還原 $($f.file)"
            }
        }
    } else {
        $items = Get-ChildItem $b -File
        foreach ($it in $items) {
            if ($it.Name -eq "manifest.json") { continue }
            Copy-Item $it.FullName (Join-Path $rimeDir $it.Name) -Force
            Write-Ok "還原 $($it.Name)"
        }
    }
    if ($payload) {
        $dep = Resolve-Deployer
        $null = Invoke-Deploy $rimeDir $dep $payload $false 0
    }
}

function Do-Uninstall([bool]$dry) {
    $dir = Resolve-RimeDir
    Write-Step "Rime 使用者目錄：$dir"
    $payload = Resolve-Payload
    $schemas = Get-EnabledSchemas $dir
    Write-Step "已啟用方案：$($schemas -join ', ')"

    $backupDir = ""
    if (-not $dry) { $backupDir = New-Backup $dir }

    foreach ($schema in $schemas) {
        $file = Join-Path $dir "$schema.custom.yaml"
        if (-not (Test-Path $file)) { continue }
        $r = Read-Utf8File $file
        $lines = @(ConvertTo-Lines $r.Text)
        $newLines = Remove-ManagedBlock $lines
        $newText = Join-Lines $newLines $r.Crlf $r.Text.EndsWith("`n")
        $meaningful = @($newLines | Where-Object { $_.Trim() -ne "" -and -not $_.TrimStart().StartsWith("#") })
        $emptyAfter = ($meaningful.Count -eq 0 -or ($meaningful.Count -eq 1 -and $meaningful[0].Trim() -eq "patch:"))
        if ($emptyAfter) {
            # 若歷史備份存在此檔，代表原本就有（只是內容僅剩空 patch）→ 還原原始位元組；
            # 完全沒有備份者才是安裝時新建，直接刪除。
            $old = Get-ChildItem (Join-Path $dir "reorder\_backup") -Recurse -File -Filter "$schema.custom.yaml" -ErrorAction SilentlyContinue |
                Where-Object { $_.DirectoryName -ne $backupDir } |
                Sort-Object LastWriteTime | Select-Object -First 1
            $oldHasBlock = $false
            if ($old) {
                $oldHasBlock = (Read-Utf8File $old.FullName).Text.Contains($BEGIN_MARK)
            }
            if ($old -and -not $oldHasBlock) {
                Write-Plan "$schema.custom.yaml：移除後僅剩空 patch，還原為原始檔"
                if (-not $dry) {
                    Copy-Item $file (Join-Path $backupDir "$schema.custom.yaml") -Force
                    Copy-Item $old.FullName $file -Force
                    Write-Ok "已還原 $schema.custom.yaml（原始內容 $($old.Length) bytes）"
                }
                continue
            }
            Write-Plan "$schema.custom.yaml：移除後僅剩空 patch，將刪除（安裝時新建）"
            if (-not $dry) {
                Copy-Item $file (Join-Path $backupDir "$schema.custom.yaml") -Force
                Remove-Item $file -Force
                Write-Ok "已刪除 $schema.custom.yaml（原本不存在）"
            }
            continue
        }
        Write-Plan "$schema.custom.yaml：移除受管理區塊"
        if ($dry) {
            Write-Host "      |$($newText -replace "`r?`n", "`n      |")" -ForegroundColor DarkGray
            continue
        }
        Copy-Item $file (Join-Path $backupDir "$schema.custom.yaml") -Force
        Write-Utf8File $file $newText $r.Bom
        Write-Ok "已清理 $schema.custom.yaml"
    }

    if ($dry) { return }

    $lua = Join-Path $dir "lua\reorder.lua"
    if (Test-Path $lua) { Remove-Item $lua -Force; Write-Ok "已移除 lua\reorder.lua" }
    $data = Join-Path $dir "reorder"
    if (Test-Path $data) {
        Get-ChildItem $data -File |
            Where-Object { $_.Name -in @("RimeReorder.exe", "RimeDeploy.exe") } |
            Remove-Item -Force
        Write-Ok "已移除 reorder\ 程式（保留 rank.tsv / extra.tsv / history.tsv 等使用者資料）"
    }
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    if (Get-ItemProperty -Path $runKey -Name "RimeReorder" -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $runKey -Name "RimeReorder" -ErrorAction SilentlyContinue
        Write-Ok "已移除開機自啟（HKCU Run\RimeReorder）"
    }
    $deployer = Resolve-Deployer
    $null = Invoke-Deploy $dir $deployer $payload $false 0
    Write-Step "卸載完成（備份保留在 $backupDir）"
}

# ---------- 入口 ----------

$action = "install"
if ($Uninstall) { $action = "uninstall" }
elseif ($Restore) { $action = "restore" }
elseif ($Repair) { $action = "install" }

if ($action -eq "uninstall") {
    Do-Uninstall ([bool]$DryRun)
    exit 0
}
if ($action -eq "restore") {
    $dir = Resolve-RimeDir
    $payload = $null
    try { $payload = Resolve-Payload } catch { }
    Do-Restore $dir $payload
    exit 0
}

Do-Install ([bool]$DryRun) ([bool]$Repair)
exit 0
