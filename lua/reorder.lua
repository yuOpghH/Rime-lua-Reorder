-- rime-reorder / reorder.lua
-- Rime 候選調序（方案 B）：lua_filter + lua_translator
--
-- 資料檔（與本檔同一使用者目錄下的 reorder\ 資料夾）：
--   rank.tsv      詞<TAB>分數        分數 -5..+5（±5 硬置頂/置底，±1..4 加權）
--   extra.tsv     編碼<TAB>詞        疊加新詞（lua_translator 注入）
--   status.tsv    心跳（本檔只寫，不讀）
--   candidates.tsv 最近一次候選清單（供工作台顯示）
--
-- 設計原則：fail-open。任何檔案缺失、壞行或 Lua 錯誤，都原序放行，不吞鍵、不讓候選消失。

local M = {}

-- 1.4.10：① extra 的長碼（≥3 碼、無空白）依方案拼寫集生成「分音節變體」，注入時原串與
--          變體都查；② 候選排序加入「輸入覆蓋率」，只覆蓋前段的候選退到完整覆蓋之後。
-- 1.4.11：造詞提速——追加檔只取檔尾判斷換行；vocab 同詞同碼改用大小索引；簡碼一次批量寫；
--          造詞後只增量併入新行（含前綴索引）；undo 快照只存本次改動的檔。
-- 1.4.12：長碼分段變體改惰性生成（第一次遇到該碼才切），解析不再對上萬個長碼跑 DP。
-- 1.4.13：造詞時把連寫碼按方案拼寫回切成逐字段（唯一且段數＝字數才切），
--          落到 extra 的主碼用分段形態，簡碼／衍生碼（derive／abbrev／fuzz）才會生成；
--          切不出時保留原樣，並在歷史寫 newsegfail 一行（不靜默）。
-- 1.4.14：工作台卡頓修復（GUI 為主，lua 僅同步版本號）。
-- 1.4.15：多截碼整詞合成——整串碼按段查（詞庫前段候選／extra.tsv／vocab.txt），
--          拼成整詞後參與分數排序（依段數／碼長給分，位次最多第 3）；rules.yaml 的 compose_candidates 可關閉。
-- 1.4.16：排序開關拆兩層（enabled＝意向、rank.tsv(.off)＝運行時）：退出只收 .off、不改 enabled；
--          工作台每次啟動按意向恢復一次；GUI 新增開機自啟（托盤靜默）。lua 僅同步版本號。
-- 1.4.17：候選標記全跟排序走——rank.tsv 不在（排序已解除，只剩 rank.tsv.off）時一個 emoji 都不貼，
--          也不再退化成 🆕；注入照舊（關著排序仍會注入，只是不帶標記）。
-- 1.4.18：注入／捕捉改跟「工作台在不在」走：判據＝工作台在場（reorder\gui_alive.tsv，
--          每 3 秒刷新、>60 秒失效）or rank.tsv 真的存在；兩者都假才全停（不注入、不標記、
--          不寫 candidates.tsv／status.tsv）。與 exitonclose 的解除組合各自正確。
-- 1.4.19：① 合成詞若已在候選流（原生詞或既有詞條）→ 不新增，改把那條提到第 3 位（前二不動）；
--          ② 同一 segment 內的空格／'／` 視為權威分段（優先於自動切分），引擎已多 segment 則不跨段；
--          ③ 上屏合成詞時鏡像寫入 extra.tsv 與 userdb（config.ini 的 userdb=on／off／rebuild，預設 on）。
-- 1.4.20：① ; 是方案拼寫碼（屏=p;），不再當分隔符；詞庫候選的註釋碼可作局部碼供逐段查詢；
--          ② config.ini 新增 mirror=userdb（預設）／both：合成詞上屏預設只寫 userdb，
--             造詞（Shift+Space）仍照舊寫 extra.tsv；鏡像檔加第三欄標記來源；
--          ③ userdb 寫入改為「記憶體＋直接更新 tabledb 文字檔」，並把每一步寫進 userdb.log
--             （status.tsv 每 2 秒整檔重寫，失敗訊息留不住）。
-- 1.4.21：① 修上屏 0 記錄：weasel 的 librime-lua 沒有 env.commit_notifier（實測為 nil，
--             connect 直接拋錯且 bound 先鎖死），改從 env.engine.context.commit_notifier 連，
--             連上才鎖定、每次入口重試；「已存在只提位」的合成詞也一併記錄；視窗 30→120 秒，
--             對不上／過期都寫 userdb.log；
--          ② 合成位置改按「匹配詞」：無匹配詞（本工具 extra／vocab／rank／歷史造詞）→ 直接第 1；
--             有匹配詞 → 不搶第一，按分數落在第 2/3；「已有同文固定移到第 3」的舊規則移除；
--          ③ 覆蓋率計算不再剝除 ;（gbz;／gb z; 這類碼可拿到完整覆蓋，不再被原生詞壓到尾部）。
-- 1.4.22：① 「匹配詞」判定下沉到分段：整串碼能按段切出本工具管理的詞（extra／vocab／rank，
--             每段 ≥2 碼）就算有匹配詞，合成候選只落第 2/3（stp; 不再搶第 1）；
--          ② 跨段上屏兜底記帳：引擎已多 segment、無合成候選時，用 filter 每鍵快取的整串碼與
--             分段，在上屏時把「上屏文本」寫進 userdb（2..4 段、2..8 字、最後一段命中
--             extra／vocab／rank）。config.ini 可 commitrecord=off 關閉；超限只寫一行 skip。
-- 1.4.23：合成詞功能加獨立開關 compose=on|off（方案 config.ini，預設 off）：
--           off 時完全不參與——不生成合成候選、不做切段匹配（whole_code_managed）、
--           不算 compose_score、不插入候選、也不寫任何相關日誌；on 時維持 1.4.22 行為。
-- 1.4.24：模組路徑推導失敗時，兜底改用 %APPDATA%\Rime；環境變數為空才退回中性相對路徑。
local VERSION = "1.4.24"

local BASE      = nil
local DIR       = nil
local RANK      = nil
local EXTRA     = nil
local STATUS    = nil
local CANDIDATES = nil
local HISTORY   = nil
local UDLOG     = nil   -- 1.4.20：userdb 寫入的持久診斷日誌（append，不被心跳覆蓋）
local CONFIG    = nil
local RULES     = nil
local REV       = nil
local VOCAB     = nil
local VOCAB_OPS = nil   -- 1.3.24：本工具對 vocab.txt 的增刪記錄（工作台據此略過外部編輯套用）
local ALIVE     = nil   -- 1.4.18：工作台在場標記檔
local MIRROR    = nil   -- 1.4.19：本工具已寫進 userdb 的鏡像清單（每方案一份）

-- 1.4.0：方案（schema）分家。每個方案各自一套資料檔，另設 default 共用層；
-- 找不到方案目錄就退回舊的 reorder\ 位置（升級不讓舊設定失效）。
local PROFILE_ROOT = nil
local prof_state = { schema = nil, id = nil, dir = nil, next_check = 0 }
local prof_bundles = {}

-- 快取（1.3.11：以「檔案內容雜湊」判斷是否重解析；內容沒變就不解析、不重算正則）
-- 舊版用 os.time() 秒節流：同一秒內的寫檔看不到，且每鍵都可能整檔重解析。
local rank_cache = { text_sig = nil, data = {}, src = {}, pos = {}, sig = 0 }
local extra_cache = { text_sig = nil, data = {}, list = {}, q = {}, count = 0, idx = nil, gen = 0 }
local vocab_cache = { text_sig = nil, words = {} }
-- 1.4.10：方案拼寫集快取（schema -> {拼寫=true}）；只在 extra 重解析時用到
local spell_cache = { id = nil, set = nil }
-- 1.3.21：工作台每次寫檔都會更新 rev.tsv（極小檔）。Lua 每個按鍵只讀它，
-- 內容一變就讓 rank／extra／rules 的快取全部失效，不必等「每秒一次」的整檔比對，
-- 保證「關閉／清空」後下一個按鍵立刻回到引擎原序。
local rev_state = { text = nil }
local refresh_rev   -- 前置宣告（pref_cache／rules_cache 定義後才補完整失效清單）
local last_sig = nil
local last_status_sec = -1
local calls = 0
local parse_rank, parse_extra, parse_rules, writes_cand = 0, 0, 0, 0

local function path_of_module()
  local info = debug and debug.getinfo and debug.getinfo(1, "S")
  local src = (info and info.source) or ""
  src = src:gsub("^@", "")
  local base = src:match("(.+)[/\\]lua[/\\][^/\\]+$")
  if base and base ~= "" then
    return base
  end
  -- 後備：以使用者環境變數推導；取不到才退回中性相對路徑
  local appdata = os.getenv("APPDATA")
  if appdata and appdata ~= "" then
    return appdata .. "\\Rime"
  end
  return "."
end

local function init_paths()
  if DIR then return end
  local base = path_of_module()
  BASE = base
  DIR = base .. "\\reorder\\"
  PROFILE_ROOT = DIR .. "profiles\\"
  RANK = DIR .. "rank.tsv"
  EXTRA = DIR .. "extra.tsv"
  STATUS = DIR .. "status.tsv"
  CANDIDATES = DIR .. "candidates.tsv"
  HISTORY = DIR .. "history.tsv"
  CONFIG = DIR .. "config.ini"
  RULES = DIR .. "rules.yaml"
  REV = DIR .. "rev.tsv"
  VOCAB = DIR .. "vocab.txt"
  VOCAB_OPS = DIR .. "vocab_ops.tsv"
  ALIVE = DIR .. "gui_alive.tsv"   -- 1.4.18：工作台在場標記（GUI 每 3 秒刷新）
  MIRROR = DIR .. "userdb_mirror.tsv"   -- 1.4.19：userdb 鏡像記錄（code<TAB>word[<TAB>mode]）
  UDLOG = DIR .. "userdb.log"           -- 1.4.20：userdb 寫入診斷（append-only）
end

local function read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local ok, text = pcall(function() return f:read("*a") end)
  pcall(function() f:close() end)
  if not ok then return nil end
  return text
end

-- 內容簽章（djb2＋長度）：同內容不重解析；換行／BOM 差異也會被視為變更
local function content_sig(text)
  text = text or ""
  local h = 5381
  for i = 1, #text do
    h = (h * 33 + string.byte(text, i)) % 4294967296
  end
  return string.format("%d:%d", h, #text)
end

-- 1.3.20：檔案大小快篩＋每秒最多一次整檔比對。
-- 回傳 (text, false)＝內容有變或首次載入，需重解析；(nil, true)＝沿用快取。
-- 同一秒內只開檔取大小，不讀內容；大小沒變就完全跳過解析與索引重建。
local function file_size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local ok, sz = pcall(function() return f:seek("end") end)
  pcall(function() f:close() end)
  if not ok then return nil end
  return sz
end

-- 1.4.3：內容簽章降級為「大小＋頭尾抽樣」。逐位元組全文雜湊只在 rev.tsv
-- 變更後做一次；平時外部編輯只比大小與抽樣，避免每秒整檔掃描。
local function sample_sig(text)
  local n = #text
  local head = text:sub(1, 192)
  local tail = (n > 192) and text:sub(n - 191) or ""
  return string.format("%d:", n) .. content_sig(head .. "\x1f" .. tail)
end

local function cached_text(path, cache, now)
  now = now or os.time()
  local rev = rev_state.text
  -- 主判據：rev.tsv 沒變就不碰檔案本體（工作台每次寫檔都會更新 rev）
  if cache.ready and cache.rev == rev then return nil, true end
  local sz = file_size(path)
  if sz == nil then sz = 0 end
  -- 同一秒內看過同大小且 rev 未變：沿用（外部編輯最多 1 秒延遲）
  if cache.ready and cache.rev == rev and cache.size == sz and cache.checked_sec == now then
    return nil, true
  end
  local text = read_all(path) or ""
  local sig
  if cache.ready and cache.rev == rev then
    sig = sample_sig(text)       -- 外部編輯（rev 未動）：只比抽樣
  else
    sig = content_sig(text)      -- rev 變了：整檔簽章做一次
  end
  cache.size, cache.checked_sec, cache.rev = sz, now, rev
  if cache.ready and cache.text_sig == sig then return nil, true end
  cache.text_sig = sig
  cache.ready = true
  return text, false
end

local function write_all(path, text)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  local ok = pcall(function()
    f:write(text)
  end)
  pcall(function() f:close() end)
  if not ok then
    pcall(function() os.remove(tmp) end)
    return false
  end
  -- Windows 上 os.rename 不覆蓋既有檔，先移除再改名；失敗則直接寫目的檔
  pcall(function() os.remove(path) end)
  local rok = pcall(function() os.rename(tmp, path) end)
  if rok then return true end
  pcall(function() os.remove(tmp) end)
  local f2 = io.open(path, "w")
  if not f2 then return false end
  pcall(function() f2:write(text); f2:close() end)
  return true
  end

-- 前置宣告（load_extra 需要在下方才定義的規則工具）
local normalize_code, utf8_chars, build_short, load_rules, make_short_codes, build_prefix_index
local rules_cache   -- 1.4.0：load_extra 需讀 strict_spelling，先宣告（下方才建表）
local pref_cache    -- 1.4.0：按方案分家時要整組換掉，先宣告
local ensure_commit_hook   -- 1.3.23(3a)：filter 入口比實作先定義，先宣告
local preedit_segments     -- 1.3.24：filter 要先記下整串輸入的分段（造詞取碼用）
local comp                 -- 1.3.24：同上（上屏字序累積）
local snapshot_before, snapshot_after   -- 1.4.2：造詞的前／後快照（實作在 undo 工具旁）

-- 1.3.18：前綴分段匹配的兩層索引（字數 -> 首段首 2 碼 -> 詞條）。
-- 只在 extra 內容變更時建一次；每個詞只進一個桶（首段滿 2 碼取前 2 碼，
-- 不足 2 碼取現有長度）。詞條預存分段位置／長度／全碼總長，DP 期間不再切字串。
-- 1.3.24：同一個碼可以有多個同音詞（extra.tsv 同碼多行），索引一併保留全部詞。
build_prefix_index = function(list, bycode)
  local codes = {}
  for code in pairs(list) do
    if code:find(" ", 1, true) then codes[#codes + 1] = code end
  end
  table.sort(codes)   -- 同分時取先出現者：固定順序，避免每次跳動
  local idx = {}
  local ord = 0
  for i = 1, #codes do
    local code = codes[i]
    local entries = list[code]
    if entries and #entries > 0 then
      local starts, lens = {}, {}
      local total, p = 0, 1
      for part in code:gmatch("%S+") do
        starts[#starts + 1] = p
        lens[#lens + 1] = #part
        total = total + #part
        p = p + #part + 1   -- ＋1 為分段間的一個空白
      end
      local n = #lens
      if n > 1 then
        local ws = {}
        for j = 1, #entries do
          local w = entries[j].word
          if w and utf8_chars(w) == n then ws[#ws + 1] = w end
        end
        if #ws > 0 then
          ord = ord + 1
          local key
          if lens[1] >= 2 then
            key = code:sub(starts[1], starts[1] + 1)
          else
            key = code:sub(starts[1], starts[1])
          end
          local g = idx[n]
          if not g then g = {}; idx[n] = g end
          local b = g[key]
          if not b then b = {}; g[key] = b end
          local ent = {
            words = ws, word = ws[1], code = code, starts = starts, lens = lens,
            total = total, ord = ord,
          }
          b[#b + 1] = ent
          if bycode then bycode[code] = ent end
        end
      end
    end
  end
  return idx, ord
end

-- 1.3.24：rank 的分數語義只有 -5..+5。
-- 舊資料（詞彙檔權重 5000／4999／4967／4555…）被照原值搬進 rank，幾千分等於給每個詞判
-- 一次絕對硬鎖；這裡一律先歸一化：|n|>5 不再當硬鎖，但仍保留彼此的相對次序
-- （單調壓到 4~5 之間，且永遠低於真正的 4.9 與 ±5，不會蓋過使用者明確設定的置頂/置底）。
local function norm_score(n)
  if n > 5 then
    return 5 - 1 / (1 + n / 100000)
  elseif n < -5 then
    return -(5 - 1 / (1 - n / 100000))
  end
  return n
end

-- 讀 rank.tsv（節流快取）。回傳 table: "方案:輸入碼\x1f詞" -> score
--
-- 1.3.1：rank 不再以「詞」單獨為鍵。每一筆必須帶「方案:輸入碼」的碼別（第 3 欄），
-- 只套用到完全相同的方案與輸入碼。舊的兩欄（無碼別）條目一律不套用，避免一次
-- 在寬鬆前綴（例如 z）上做的排序污染其他碼（例如 zs）的候選。
local function load_rank()
  init_paths()
  local text, hit = cached_text(RANK, rank_cache)
  if hit then return rank_cache.data end
  parse_rank = parse_rank + 1

  local data = {}
  local src = {}   -- 1.3.9：第 4 欄來源（ladder＝階梯重算；缺欄視為 user）
  local pos = {}   -- 1.3.20：第 5 欄位置序（拖曳只改這一欄；缺欄＝按原本排序）
  -- 1.3.24：標記判據改成「方案:碼」級（lock_keys／user_keys 的鍵是 sc\x1f詞）。
  -- 舊版只有逐詞索引，詞在 A 方案有記錄就會在 B 方案也被當成本工具管的，把別人的 📌 蓋掉。
  local lockk, userk = {}, {}
  -- 1.4.22：碼集合（方案:碼 的第 3 欄取碼），供「整串碼按段切出本工具管理的詞」判定用
  local codes = {}
  local sig = 0
  for line in text:gmatch("[^\r\n]+") do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local f = {}
      for part in line:gmatch("[^\t]+") do f[#f + 1] = part end
      local w, s, sc = f[1], f[2], f[3]
      if w and s and sc and sc ~= "" then
        local n = tonumber(s)
        if n then
          n = norm_score(n)
          local k = sc .. "\x1f" .. w
          data[k] = n
          -- 1.4.22：sc 形如「方案:碼」，碼去空白轉小寫後入集合（分段匹配用）
          local colon = sc:find(":", 1, true)
          local cc = (colon and sc:sub(colon + 1) or sc):lower():gsub("[`%s]+", "")
          if cc ~= "" then codes[cc] = true end
          if f[4] == "ladder" then src[k] = true end
          -- 1.3.23：ladder 是自動重算的鄰居，不算使用者身份
          if f[4] ~= "ladder" then
            if n >= 4.99 or n <= -4.99 then
              lockk[k] = true
            elseif n > -4.99 and n < 4.99 then
              userk[k] = true
            end
          end
          local pv = tonumber(f[5])
          if pv then pos[k] = pv end
          sig = sig + #w + #sc + math.floor((n + 5) * 100)
        end
      end
    end
  end
  rank_cache.data = data
  rank_cache.src = src
  rank_cache.pos = pos
  rank_cache.codes = codes
  rank_cache.lock_keys = lockk
  rank_cache.user_keys = userk
  rank_cache.sig = sig + #text
  return data
end

-- 1.4.10：讀方案拼寫集（音節拼寫）。來源＝本方案 .dict.yaml 的碼欄（第 2 欄）字母片段；
-- 只有主字典不存在時才退回 build/<schema>.schema.yaml 裡的 dictionary 名。
-- 結果按 schema 快取；讀不到就回 nil（呼叫端維持原行為，不生成變體）。
local function load_spellings()
  init_paths()
  local sid = prof_state.schema
  if not sid or sid == "" or sid == "?" or sid == "_unknown" then return nil end
  if spell_cache.id == sid then return spell_cache.set end
  local names, seen = {}, {}
  local function add_name(n)
    if n and n ~= "" and not seen[n] then seen[n] = true; names[#names + 1] = n end
  end
  local dtext = read_all(BASE .. "\\" .. sid .. ".dict.yaml")
  if not dtext then
    local btext = read_all(BASE .. "\\build\\" .. sid .. ".schema.yaml")
    if btext then
      for name in btext:gmatch("dictionary:%s*\"?([%w_%.%-]+)\"?") do add_name(name) end
    end
    for i = 1, #names do
      local t = read_all(BASE .. "\\" .. names[i] .. ".dict.yaml")
      if t then dtext = t; break end
    end
  end
  local set = {}
  if dtext then
    for line in dtext:gmatch("[^\r\n]+") do
      if line ~= "" and line:sub(1, 1) ~= "#" and line ~= "..." then
        local code = line:match("^[^\t]*\t([^\t]*)")
        if code then
          for tok in code:gmatch("[%a]+") do
            tok = tok:lower()
            if #tok >= 1 and #tok <= 6 then set[tok] = true end
          end
        end
      end
    end
  end
  spell_cache.id = sid
  spell_cache.set = (next(set) ~= nil) and set or nil
  return spell_cache.set
end

-- 1.4.10：把一整串碼按拼寫集切成音節（最少段數；同段數取「尾段較長」的切法）。
-- 本身已是合法拼寫、含空白、或切不完整 → 回 nil（保留原串，不生成變體）。
local function split_by_spelling(code, set)
  if type(code) ~= "string" or code == "" or not set then return nil end
  if code:find(" ", 1, true) or set[code] then return nil end
  local n = #code
  local best, prev, cnt = { [0] = 0 }, {}, { [0] = 1 }
  for i = 1, n do
    for l = 1, math.min(6, i) do
      local seg = code:sub(i - l + 1, i)
      if best[i - l] and set[seg] then
        local v = best[i - l] + 1
        if not best[i] or v < best[i] then
          best[i], prev[i], cnt[i] = v, { pos = i - l, l = l }, cnt[i - l]
        elseif v == best[i] then
          -- 1.4.13：同段數的切法不只一種時要能判斷「不唯一」，不能隨便挑一種
          cnt[i] = math.min(999, cnt[i] + cnt[i - l])
          if not prev[i] or l > prev[i].l then prev[i] = { pos = i - l, l = l } end
        end
      end
    end
  end
  if not best[n] or best[n] < 2 then return nil end
  local parts, i = {}, n
  while i > 0 and prev[i] do
    parts[#parts + 1] = code:sub(prev[i].pos + 1, i)
    i = prev[i].pos
  end
  if i ~= 0 then return nil end
  local out = {}
  for j = #parts, 1, -1 do out[#out + 1] = parts[j] end
  return table.concat(out, " "), #out, cnt[n]
end

-- 讀 extra.tsv（節流快取）。回傳 table: 編碼 -> 詞；品質另存 extra_cache.q（編碼 -> 品質）
-- 1.3.6：可選第 3 欄＝品質。主碼（全碼）沒有第 3 欄＝4.9；規則產生的簡碼帶較低品質。
-- 1.4.0：可選第 4 欄＝屬性（derive／xform／abbrev／fuzz）。
--          strict_spelling: true 時，帶 fuzz／abbrev 的碼不能單獨出「單字」（只留詞組用）。
--          xform 改寫主碼本身時，該詞在執行期不再從原碼注入（檔案不動）。
-- 1.3.24：同一個編碼可以對應多個詞（同音詞）。data 只保留最後一筆（相容舊路徑），
--         新增 extra_cache.list（碼 -> { {word=詞, q=品質, attr=屬性}, ... }）保留全部，注入時逐個產出。
-- 1.4.11：把一筆（碼、詞、品質、屬性）併進 extra 快取；整檔解析與造詞增量共用。
-- 回傳 true＝確實新增（strict_spelling 擋掉或重複則 false）。
local function extra_insert(code, word, qual, attr, from_file)
  if rules_cache.strict == true and (attr == "fuzz" or attr == "abbrev")
     and utf8_chars(word) == 1 then
    return false   -- strict_spelling：縮略／模糊碼不單獨出單字
  end
  local seen = extra_cache.seen
  if not seen then seen = {}; extra_cache.seen = seen end
  local sk = code .. "\x1f" .. word
  if seen[sk] then return false end
  seen[sk] = true
  local list = extra_cache.list
  local L = list[code]
  if not L then L = {}; list[code] = L end
  -- 1.4.11：file＝這一行確實落在 extra.tsv（造詞時不必再掃全檔確認是否已寫過）
  L[#L + 1] = { word = word, q = qual, attr = attr, file = from_file }
  extra_cache.data[code] = word
  local words = extra_cache.words
  if words then words[word] = true end
  if qual then extra_cache.q[code] = qual end
  extra_cache.count = (extra_cache.count or 0) + 1
  return true
end

-- 1.4.11：檔案裡是否已有「這個碼＋這個詞」的行（只看 file=true 的條目）
local function extra_file_has(code, word)
  local L = extra_cache.list[code]
  if not L then return false end
  for i = 1, #L do
    if L[i].file and L[i].word == word then return true end
  end
  return false
end

-- 1.4.11：把某個分段碼整體掛進前綴索引（與 build_prefix_index 同構；已掛過就更新詞表）
local function idx_insert(code)
  local idx, list = extra_cache.idx, extra_cache.list
  if not idx or not list[code] then return end
  local starts, lens = {}, {}
  local total, p = 0, 1
  for part in code:gmatch("%S+") do
    starts[#starts + 1] = p
    lens[#lens + 1] = #part
    total = total + #part
    p = p + #part + 1
  end
  local n = #lens
  if n <= 1 then return end
  local ws = {}
  for j = 1, #list[code] do
    local w = list[code][j].word
    if w and utf8_chars(w) == n then ws[#ws + 1] = w end
  end
  if #ws == 0 then return end
  local by = extra_cache.idx_by_code
  local ent = by and by[code]
  if ent then
    ent.words = ws
    ent.word = ws[1]
    return
  end
  local key = (lens[1] >= 2) and code:sub(starts[1], starts[1] + 1) or code:sub(starts[1], starts[1])
  local g = idx[n]
  if not g then g = {}; idx[n] = g end
  local b = g[key]
  if not b then b = {}; g[key] = b end
  extra_cache.ord = (extra_cache.ord or 0) + 1
  ent = {
    words = ws, word = ws[1], code = code, starts = starts, lens = lens,
    total = total, ord = extra_cache.ord,
  }
  b[#b + 1] = ent
  if by then by[code] = ent end
end

-- 1.4.11：造詞後只把新寫入的行增量併進快取（含簡碼與前綴索引），不再整檔重解析。
-- from_file＝這一行確實落在 extra.tsv（變體解析惰性做，改動時把查詢表清空即可）。
local function extra_apply_row(code, word, qual, attr, from_file)
  if not extra_cache.idx then return false end   -- 尚未載入：留給下次整檔解析
  if not extra_insert(code, word, qual, attr, from_file) then return false end
  idx_insert(code)
  extra_cache.vres = {}
  extra_cache.gen = extra_cache.gen + 1
  return true
end

-- 1.4.11：造詞的主碼行 ＋ 依 rules.yaml 的簡碼（與整檔解析的 seeds 段相同語義）
local function extra_apply_word(code, word)
  if not extra_apply_row(code, word, nil, nil, true) then return false end
  local segs = {}
  for part in code:gmatch("%S+") do segs[#segs + 1] = part end
  local nchars = utf8_chars(word)
  if #segs >= 1 and #segs == nchars and nchars > 0 then
    local shorts, suppress = make_short_codes(segs, nchars, code)
    for _, sc in ipairs(shorts) do
      if not extra_cache.list[sc.code] then
        extra_apply_row(sc.code, word, sc.q, sc.attr, false)
      end
    end
    if suppress then
      -- xform 只留改寫後的碼：把這個詞從原碼移除（僅執行期；extra.tsv 原行不動）
      local L = extra_cache.list[code]
      if L then
        local keep = {}
        for i = 1, #L do
          if L[i].word ~= word then keep[#keep + 1] = L[i] end
        end
        if #keep > 0 then extra_cache.list[code] = keep else extra_cache.list[code] = nil end
        if extra_cache.data[code] == word then
          extra_cache.data[code] = (keep[1] and keep[1].word) or nil
        end
      end
      -- xform 是罕見路徑：索引重建一次，保證與整檔解析結果一致
      extra_cache.idx_by_code = {}
      extra_cache.idx, extra_cache.ord =
        build_prefix_index(extra_cache.list, extra_cache.idx_by_code)
    end
  end
  return true
end

local function load_extra()
  init_paths()
  local text, hit = cached_text(EXTRA, extra_cache)
  -- 1.4.0：default 共用層（只讀合併；本方案同詞記錄優先）
  local dtext = nil
  if prof_state.id and prof_state.id ~= "default" and prof_state.id ~= "legacy" then
    local dpath = PROFILE_ROOT .. "default\\extra.tsv"
    if file_size(dpath) ~= nil then
      extra_cache.dflt = extra_cache.dflt or {}
      local dt, dh = cached_text(dpath, extra_cache.dflt)
      if not dh then dtext = dt; hit = false end
    end
  end
  if hit then return extra_cache.data end
  parse_extra = parse_extra + 1
  load_rules()   -- 1.4.0：取得 strict_spelling 與算子

  -- 1.4.11：解析與增量共用同一組表，直接掛在 extra_cache 上
  extra_cache.data = {}
  extra_cache.list = {}
  extra_cache.seen = {}
  extra_cache.q = {}
  extra_cache.words = {}   -- 1.3.23：詞 -> true（標記用；與碼別無關）
  extra_cache.vres = {}   -- 1.4.12：分段變體惰性解析結果（碼 → 變體碼／false）
  extra_cache.count = 0

  for line in text:gmatch("[^\r\n]+") do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local code, word, qs, at = line:match("^(.-)\t([^\t]+)\t?([^\t]*)\t?([^\t]*)$")
      if code and code ~= "" and word and word ~= "" then
        -- 1.3.9：舊資料（1.3.7 熱鍵錄入）碼欄可能是反引號分隔，讀取時一律正規化，
        -- 否則轉譯端索引用原字串，永遠對不上使用者打的簡碼。
        code = normalize_code(code)
      end
      if code and code ~= "" and word and word ~= "" then
        if at == "" then at = nil end
        extra_insert(code, word, tonumber(qs), at, true)
      end
    end
  end
  -- 1.4.0：合併 default 共用層。本方案已有同一個詞就不再收（本方案優先）。
  if dtext and dtext ~= "" then
    for line in dtext:gmatch("[^\r\n]+") do
      if line ~= "" and line:sub(1, 1) ~= "#" then
        local code, word, qs, at = line:match("^(.-)\t([^\t]+)\t?([^\t]*)\t?([^\t]*)$")
        if code and code ~= "" and word and word ~= "" then
          code = normalize_code(code)
          if code ~= "" and not extra_cache.words[word] then
            if at == "" then at = nil end
            extra_insert(code, word, tonumber(qs), at, true)
          end
        end
      end
    end
  end
  -- 1.3.9：舊資料缺簡碼（1.3.7 熱鍵錄入只寫主碼）→ 依 rules.yaml 在記憶體補齊簡碼，
  -- 讓「詞彙頁看得到、規則回饋算得出」的詞真的打得出；不改寫檔案。
  -- 1.3.10：rules.yaml 多了 fuzz 條目，這裡一併補（沒有規則時下面自然不產生）。
  -- 1.4.0：單字（length_equal: 1）也納入；xform 改寫主碼時停用該詞的原碼注入。
  local seeds = {}
  for code, entries in pairs(extra_cache.list) do
    seeds[#seeds + 1] = { code = code, entries = entries }
  end
  for _, s in ipairs(seeds) do
    local segs = {}
    for part in s.code:gmatch("%S+") do segs[#segs + 1] = part end
    for _, ent in ipairs(s.entries) do
      local nchars = utf8_chars(ent.word)
      if #segs >= 1 and #segs == nchars and nchars > 0 then
        -- 1.3.10：formula 只套「最 specific」的一條；算子逐段替換各生成一條
        local shorts, suppress = make_short_codes(segs, nchars, s.code)
        for _, sc in ipairs(shorts) do
          if not extra_cache.list[sc.code] then
            extra_insert(sc.code, ent.word, sc.q, sc.attr)
          end
        end
        if suppress then
          -- xform 只留改寫後的碼：把這個詞從原碼移除（僅執行期；extra.tsv 原行不動）
          local L = extra_cache.list[s.code]
          if L then
            local keep = {}
            for i = 1, #L do
              if L[i].word ~= ent.word then keep[#keep + 1] = L[i] end
            end
            if #keep > 0 then extra_cache.list[s.code] = keep else extra_cache.list[s.code] = nil end
            if extra_cache.data[s.code] == ent.word then
              extra_cache.data[s.code] = (keep[1] and keep[1].word) or nil
            end
          end
        end
      end
    end
  end

  -- 1.4.12：長碼分段變體不在解析時整表生成（29,851 個 ≥3 碼的 DP 會讓首鍵多花 90ms），
  -- 改成 extra_words 第一次遇到該碼才切（見 variant_lookup），這裡只清空查詢快取。
  extra_cache.vres = {}

  extra_cache.idx_by_code = {}
  extra_cache.idx, extra_cache.ord = build_prefix_index(extra_cache.list, extra_cache.idx_by_code)
  extra_cache.gen = extra_cache.gen + 1
  return extra_cache.data
end

-- 1.4.12：分段變體改成「第一次遇到該碼才切」。整檔解析不再對上萬個長碼跑 DP，
-- 只保留一張查過就記住的結果表（碼 → 變體碼或 false）；extra 有增量時整表清空。
local function variant_lookup(code, list)
  local vres = extra_cache.vres
  if not vres then return nil end
  local hit = vres[code]
  if hit == nil then
    local v = false
    if #code >= 3 and not code:find(" ", 1, true) and code:match("^[%a]+$") then
      -- 正向：長碼依方案拼寫集切音節（例 zyhd → zy hd）
      local ok_sp, sp = pcall(load_spellings)
      if ok_sp and sp then v = split_by_spelling(code:lower(), sp) or false end
    elseif code:find(" ", 1, true) then
      -- 反向：輸入是分段形態（zy hd），檔案裡是連寫碼（zyhd）→ 回連寫碼取詞
      local joined = code:gsub("%s+", "")
      if joined ~= "" and (list[joined] or list[joined:lower()]) then v = joined end
    end
    vres[code] = v
    hit = v
  end
  if not hit then return nil end
  local VL = list[hit] or list[hit:lower()]
  if VL and #VL > 0 then return VL, hit end
  return nil
end

-- 1.3.24：取某個編碼底下的全部詞（同音詞）；比對順序與舊版單詞路徑一致。
local function extra_words(code)
  if type(code) ~= "string" or code == "" then return nil end
  local list = extra_cache.list or {}
  local L = list[code]
  local key = code
  if not L then L = list[code:lower()]; key = code:lower() end
  if not L then
    local norm = normalize_code(code)
    if norm ~= "" and norm ~= code and norm ~= code:lower() then
      L = list[norm]
      key = norm
      if not L then L = list[norm:lower()]; key = norm:lower() end
    end
  end
  if L and #L > 0 then return L, key end
  -- 1.4.10／1.4.12：原串沒中時查「分音節變體」（惰性、查過即記）
  return variant_lookup(code, list)
end

-- 1.3.24：標記判據用的「碼」歸一鍵（去掉所有空白；zung man 與 zungman 視為同一個碼）
local function code_key(code)
  if type(code) ~= "string" then return "" end
  return (normalize_code(code):gsub("%s+", ""))
end

-- 1.3.24：vocab.txt 的「詞＋方案＋碼」索引（標記判據）。
-- 舊版只記詞，於是詞在別的方案有記錄時，本方案也被當成本工具在管，會蓋掉別人的 📌。
-- 回傳 full（列上有方案：schema\x1f碼\x1f詞）與 any（列上沒方案：碼\x1f詞）。
-- 1.4.15：多了 bycode（碼 → 詞，同碼取第一筆），供多截碼整詞合成查表用；
-- 只加索引，不改 full／any 的既有語義。
local function parse_vocab_text(text, full, any, bycode)
  for line in (text or ""):gmatch("[^\r\n]+") do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local w, cf = line:match("^([^\t]+)\t([^\t]+)")
      if w and w ~= "" then
        local schema, code = "", (cf or "")
        local colon = code:find(":", 1, true)
        if colon then
          schema = code:sub(1, colon - 1)
          schema = schema:gsub("^%s+", ""):gsub("%s+$", "")
          code = code:sub(colon + 1)
        end
        local ck = code_key(code)
        if ck ~= "" then
          any[ck .. "\x1f" .. w] = true
          if schema ~= "" then full[schema .. "\x1f" .. ck .. "\x1f" .. w] = true end
          if bycode and bycode[ck] == nil then bycode[ck] = w end
        end
      end
    end
  end
end

local function load_vocab_words()
  init_paths()
  local text, hit = cached_text(VOCAB, vocab_cache)
  -- 1.4.0：default 共用層（只讀合併）
  local dtext = nil
  if prof_state.id and prof_state.id ~= "default" and prof_state.id ~= "legacy" then
    local dpath = PROFILE_ROOT .. "default\\vocab.txt"
    if file_size(dpath) ~= nil then
      vocab_cache.dflt = vocab_cache.dflt or {}
      local dt, dh = cached_text(dpath, vocab_cache.dflt)
      if not dh then dtext = dt; hit = false end
    end
  end
  if hit then return vocab_cache.words end
  local full, any = {}, {}
  local bycode = {}
  parse_vocab_text(text, full, any, bycode)
  parse_vocab_text(dtext, full, any, bycode)
  local res = { full = full, any = any, bycode = bycode }
  vocab_cache.words = res
  return res
end

local function clean_text(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("\t", " "):gsub("\r", " "):gsub("\n", " ")
  return s
end

-- ---------- 造詞熱鍵（reorder\config.ini 的 wordhotkey=…） ----------

-- markstyle=emoji（預設）｜symbol（字型不支援 emoji 時的備援）
local cfg_cache = {
  sec = -1, spec = "Shift+Space", vk = 32, mods = 1,
  dspec = "Shift+Delete", dvk = 46, dmods = 1,   -- 1.3.23：Shift+Del 刪除本工具詞
  style = "emoji",
  enabled = nil,   -- 1.4.4：本方案 config.ini 的 enabled（nil＝未設定，視為開啟）
  userdb = "on",   -- 1.4.19：上屏合成詞時是否寫入 userdb（on／off／rebuild）
  mirror = "userdb", -- 1.4.20：合成詞上屏寫哪裡：userdb（預設，只寫 userdb）／both（再加 extra.tsv）
}

local KEY_NAMES = {
  space = 32, tab = 9, enter = 13, esc = 27, escape = 27, backspace = 8,
  delete = 46, del = 46, insert = 45, ins = 45, home = 36, ["end"] = 35,
  pageup = 33, pgup = 33, pagedown = 34, pgdn = 34,
  left = 37, right = 39, up = 38, down = 40,
}

-- librime 修飾鍵位：Shift=1, Lock=2, Ctrl=4, Alt=8, Super=16, NumLock=128
local function has_bit(v, b)
  return math.floor((v or 0) / b) % 2 == 1
end

local function relevant_mods(m)
  local r = 0
  if has_bit(m, 1) then r = r + 1 end
  if has_bit(m, 4) then r = r + 4 end
  if has_bit(m, 8) then r = r + 8 end
  if has_bit(m, 16) then r = r + 16 end
  return r
end

local function parse_key_spec(spec)
  if type(spec) ~= "string" then return nil end
  local parts = {}
  for p in spec:gmatch("[^+]+") do
    p = p:gsub("%s+", ""):lower()
    if p ~= "" then parts[#parts + 1] = p end
  end
  if #parts < 2 then return nil end
  local mods = 0
  for i = 1, #parts - 1 do
    local p = parts[i]
    if p == "ctrl" or p == "control" then mods = mods + 4
    elseif p == "alt" then mods = mods + 8
    elseif p == "shift" then mods = mods + 1
    elseif p == "win" or p == "super" or p == "meta" then mods = mods + 16
    else return nil end
  end
  local k = parts[#parts]
  local vk = nil
  if #k == 1 and k:find("%a") then vk = string.byte(k:upper())
  elseif #k == 1 and k:find("%d") then vk = string.byte(k)
  elseif k:match("^f%d+$") then
    local n = tonumber(k:sub(2))
    if n and n >= 1 and n <= 24 then vk = 112 + n - 1 end
  else vk = KEY_NAMES[k] end
  if not vk or mods == 0 then return nil end
  return vk, mods
end

local function load_config()
  init_paths()
  local now = os.time()
  -- 1.4.4：rev 也納入快取鍵；工作台切換 enabled 會同步 BumpRev，下一鍵即重讀
  if now == cfg_cache.sec and cfg_cache.path == CONFIG
     and cfg_cache.rev == rev_state.text then
    return cfg_cache
  end
  cfg_cache.sec = now
  cfg_cache.path = CONFIG
  cfg_cache.rev = rev_state.text
  local spec = "Shift+Space"
  local dspec = "Shift+Delete"
  local style = "emoji"
  local enabled = nil
  -- 1.4.19：userdb 鏡像開關。預設 on（否則第 3 條等於沒做）；off 一鍵全關；
  -- rebuild＝把本方案 extra.tsv 全部重寫進 userdb，完成後自動改回 on。
  local userdb = "on"
  -- 1.4.20：mirror=userdb｜both。預設 userdb：合成詞上屏只寫 userdb，不重複寫 extra.tsv
  -- （使用者平時用 Shift+Space 造詞已把詞寫進表）；both＝恢復 1.4.19 的雙寫。
  local mirror = "userdb"
  -- 1.4.22：跨段上屏兜底記帳（引擎已多 segment、不產生合成候選時，用整串碼寫 userdb）。
  -- 預設 on；off 一鍵全關。
  local commitrecord = "on"
  -- 1.4.23：多截碼整詞合成獨立開關。預設 off（舊配置無需改動即不合成）；
  -- 只有方案 config.ini 明確 compose=on 才參與合成與切段匹配。
  local compose = "off"
  -- 1.4.6：enabled 只認「本方案自己的 config.ini」。方案沒有自己的 config 時，
  -- 其餘設定仍可繼承 default，但排序開關不再被共用層的 enabled 影響。
  local own_cfg = true
  if prof_state.id and prof_state.id ~= "default" and prof_state.id ~= "legacy" then
    own_cfg = (prof_state.dir ~= nil) and (CONFIG == prof_state.dir .. "config.ini")
  end
  local text = read_all(CONFIG)
  if text then
    for line in text:gmatch("[^\r\n]+") do
      local k, v = line:match("^(%w+)%s*=%s*(.-)%s*$")
      if k == "wordhotkey" and v and v ~= "" then spec = v end
      if k == "delhotkey" and v and v ~= "" then dspec = v end
      if k == "markstyle" and v and v ~= "" then
        v = v:lower()
        style = (v == "symbol") and "symbol" or "emoji"
      end
      -- 1.4.4：排序開關改由本方案 config.ini 的 enabled 決定
      if own_cfg and k == "enabled" and v and v ~= "" then
        local lv = v:lower()
        if lv == "0" or lv == "false" or lv == "off" then enabled = false
        elseif lv == "1" or lv == "true" or lv == "on" then enabled = true end
      end
      -- 1.4.19：userdb 鏡像（鍵名只能是 %w，故不用 user_db）
      if k == "userdb" and v and v ~= "" then
        local lv = v:lower()
        if lv == "0" or lv == "false" or lv == "off" then userdb = "off"
        elseif lv == "rebuild" then userdb = "rebuild"
        elseif lv == "1" or lv == "true" or lv == "on" then userdb = "on" end
      end
      -- 1.4.20：mirror=userdb（預設）／both
      if k == "mirror" and v and v ~= "" then
        local lv = v:lower()
        if lv == "both" or lv == "1" or lv == "true" or lv == "on" then mirror = "both"
        else mirror = "userdb" end
      end
      -- 1.4.22：跨段上屏兜底記帳開關
      if k == "commitrecord" and v and v ~= "" then
        local lv = v:lower()
        if lv == "0" or lv == "false" or lv == "off" then commitrecord = "off"
        else commitrecord = "on" end
      end
      -- 1.4.23：合成詞開關（預設 off；只有明確 on 才開）
      if k == "compose" and v and v ~= "" then
        local lv = v:lower()
        if lv == "1" or lv == "true" or lv == "on" then compose = "on"
        else compose = "off" end
      end
    end
  end
  cfg_cache.style = style
  cfg_cache.enabled = enabled
  cfg_cache.userdb = userdb
  cfg_cache.mirror = mirror
  cfg_cache.commitrecord = commitrecord
  cfg_cache.compose = compose
  local vk, mods = parse_key_spec(spec)
  if vk and mods then
    cfg_cache.spec = spec
    cfg_cache.vk = vk
    cfg_cache.mods = mods
  end
  local dvk, dmods = parse_key_spec(dspec)
  if dvk and dmods then
    cfg_cache.dspec = dspec
    cfg_cache.dvk = dvk
    cfg_cache.dmods = dmods
  end
  return cfg_cache
end

-- 1.4.11：只在檔尾 seek 取 1 個位元組判斷是否需要補換行，不再整檔讀入。
local function append_tsv(path, line)
  local need_nl = false
  local f = io.open(path, "rb")
  if f then
    local ok, last = pcall(function()
      local sz = f:seek("end")
      if sz and sz > 0 then
        f:seek("set", sz - 1)
        return f:read(1)
      end
    end)
    pcall(function() f:close() end)
    if ok and last and last ~= "\n" and last ~= "\r" then need_nl = true end
  end
  local a = io.open(path, "a")
  if not a then return false end
  local ok = pcall(function()
    if need_nl then a:write("\n") end
    a:write(line .. "\n")
  end)
  pcall(function() a:close() end)
  return ok
end

local function schema_id(env)
  local ok, id = pcall(function()
    return env.engine.schema.schema_id
  end)
  if ok and id and id ~= "" then return id end
  return "?"
end

-- ---------- 1.4.0：方案（schema）分家 ----------
-- 目錄：reorder\profiles\<schema>\ 與共用層 reorder\profiles\default\
-- 查找：本方案 → default → 舊 reorder\ 位置（相容；升級不讓老設定失效）。
-- 每套快取常駐 prof_bundles：切換只換引用，不重建索引、不卡首鍵。
local function profile_dir_has(dir)
  -- 1.4.1：工作台建立方案時會寫 .profile 標記，空目錄也算可用
  if file_size(dir .. ".profile") ~= nil then return true end
  local names = { "rules.yaml", "extra.tsv", "vocab.txt", "rank.tsv", "rank.tsv.off", "config.ini" }
  for i = 1, #names do
    if file_size(dir .. names[i]) ~= nil then return true end
  end
  return false
end

local function new_bundle()
  return {
    rank  = { text_sig = nil, data = {}, src = {}, pos = {}, sig = 0 },
    extra = { text_sig = nil, data = {}, list = {}, q = {}, count = 0, idx = nil, gen = 0 },
    vocab = { text_sig = nil, words = {} },
    rules = { text_sig = nil, rules = {}, ops = {}, memo = {}, prefix_on = true, strict = false, compose_on = true },
    pref  = { key = nil, hit = nil },
  }
end

-- 單檔查找：本方案 → default → 舊位置（只讀相容；新檔仍寫在本方案目錄）
local function pick_file(dir, name)
  local p = dir .. name
  if file_size(p) ~= nil then return p end
  local ddir = PROFILE_ROOT .. "default\\"
  if dir ~= ddir and file_size(ddir .. name) ~= nil then return ddir .. name end
  local old = DIR .. name
  if file_size(old) ~= nil then return old end
  return p
end

-- rank 另判：本方案寫了 rank.tsv.off 就是明確關閉，不可回退到別層的 rank.tsv
-- 1.4.6：default 的 .off 同樣是「明確關閉」，優先於舊位置殘留的 rank.tsv；
--         舊位置只在方案與 default 都沒有任何 rank 相關檔時才使用。
local function pick_rank(dir)
  local p = dir .. "rank.tsv"
  if file_size(p) ~= nil then return p end
  if file_size(p .. ".off") ~= nil then return p end
  local ddir = PROFILE_ROOT .. "default\\"
  if dir ~= ddir then
    if file_size(ddir .. "rank.tsv") ~= nil then return ddir .. "rank.tsv" end
    if file_size(ddir .. "rank.tsv.off") ~= nil then return p end
  end
  if file_size(DIR .. "rank.tsv") ~= nil then return DIR .. "rank.tsv" end
  if file_size(DIR .. "rank.tsv.off") ~= nil then return DIR .. "rank.tsv" end
  return p
end

-- 1.4.1：寫一律落本方案目錄。目標檔不存在時，先把目前解析到的來源
-- （default／舊位置）複製一份作起點；未分家（legacy）則維持寫原處。
local function write_target(name, src)
  init_paths()
  local dir = prof_state.dir or DIR
  if dir == DIR then return DIR .. name end
  local dst = dir .. name
  if file_size(dst) == nil and src and src ~= dst then
    local text = read_all(src)
    if text then write_all(dst, text) end
  end
  -- 寫完就把讀取路徑綁到本方案這一份，立刻再寫不會重複追加
  if name == "extra.tsv" then EXTRA = dst
  elseif name == "vocab.txt" then VOCAB = dst
  elseif name == "config.ini" then CONFIG = dst
  elseif name == "rules.yaml" then RULES = dst
  elseif name == "rank.tsv" then RANK = dst
  elseif name == "rank.tsv.off" then RANK = dst:gsub("%.off$", "") end
  return dst
end

local function use_profile(env)
  init_paths()
  local schema = schema_id(env)
  local now = os.time()
  -- 每鍵只做一次字串比較；方案目錄可能由工作台即時建立，最多每 2 秒重探一次
  if prof_state.schema == schema and prof_state.id and now < prof_state.next_check then
    return
  end
  prof_state.next_check = now + 2
  prof_state.schema = schema

  local sdir = PROFILE_ROOT .. ((schema ~= "?" and schema ~= "") and schema or "_unknown") .. "\\"
  local ddir = PROFILE_ROOT .. "default\\"
  local id, dir
  if schema ~= "?" and schema ~= "" and profile_dir_has(sdir) then
    id, dir = schema, sdir
  elseif profile_dir_has(ddir) then
    id, dir = "default", ddir
  else
    id, dir = "legacy", DIR
  end
  if prof_state.id ~= id then
    local b = prof_bundles[id]
    if not b then b = new_bundle(); prof_bundles[id] = b end
    prof_state.id, prof_state.dir = id, dir
    rank_cache, extra_cache, vocab_cache, rules_cache, pref_cache =
      b.rank, b.extra, b.vocab, b.rules, b.pref
    cfg_cache.sec = -1   -- 方案換了：config.ini 可能不同，下一鍵重讀
    last_sig = nil
  end
  RANK = pick_rank(dir)
  EXTRA = pick_file(dir, "extra.tsv")
  VOCAB = pick_file(dir, "vocab.txt")
  CONFIG = pick_file(dir, "config.ini")
  RULES = pick_file(dir, "rules.yaml")
  -- status／candidates／history／rev 為全機共用（工作台只看得到一份心跳）
end

-- 反引號→空白、收斂空白、去頭尾（與工作台 NormalizeCode 一致）
normalize_code = function(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("`", " ")
  s = s:gsub("%s+", " ")
  s = s:gsub("^ ", ""):gsub(" $", "")
  return s
end

-- ---------- 1.4.19：上屏合成詞 → extra.tsv ＋ userdb 鏡像 ----------
-- 原則：userdb 是「額外能力」，任何一步失敗都不得影響上屏與既有流程，全部 pcall 隔離。
-- 鏡像記錄（reorder\userdb_mirror.tsv，每方案一份）只記本工具確實寫進 userdb 的 code＋word，
-- 供刪詞同步與日後清理；它不是資料來源，壞了最多多留幾條 userdb 記錄。
local mem_state = { sid = nil, mem = nil, fail_ts = 0 }
local sweep_state = { sec = -1 }
local rebuild_state = { sec = -1 }

local function mirror_path()
  init_paths()
  -- src 傳 nil：鏡像檔不從 default／舊位置複製過來（避免把別方案的記錄帶進新方案）
  return write_target("userdb_mirror.tsv", nil)
end

-- 1.4.20：持久診斷。status.tsv 每 2 秒被心跳整檔重寫，userdb 失敗訊息留不住；
-- 這裡改寫 append-only 的 userdb.log（每筆上屏／刪詞／對帳一行，量很小）。
local function udlog(fields)
  init_paths()
  append_tsv(UDLOG, os.date("%Y-%m-%d %H:%M:%S") .. "\t" .. table.concat(fields, "\t"))
end

-- 1.4.20：鏡像行第三欄＝來源（extra＝extra.tsv 也有；userdb＝只在 userdb）。
-- 舊版兩欄行一律視為 extra，保持向後相容。
local function mirror_mode(line)
  local md = line:match("^[^\t]+\t[^\t]+\t([%a]+)")
  return (md == "userdb") and "userdb" or "extra"
end

local function mirror_lines(text)
  local out = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

local function mirror_write(path, lines)
  local body = table.concat(lines, "\n")
  if #lines > 0 then body = body .. "\n" end
  return write_all(path, body)
end

local function mirror_add(code, word, mode)
  mode = (mode == "extra") and "extra" or "userdb"
  local p = mirror_path()
  local text = read_all(p) or ""
  local key = code .. "\x1f" .. word
  local lines, found, changed = mirror_lines(text), false, false
  for i = 1, #lines do
    local line = lines[i]
    local c, w = line:match("^([^\t]+)\t([^\t]+)")
    if c and w and c .. "\x1f" .. w == key then
      found = true
      if mode == "extra" and mirror_mode(line) ~= "extra" then
        lines[i] = code .. "\t" .. word .. "\textra"
        changed = true
      end
    end
  end
  if found then
    if changed then return mirror_write(p, lines) end
    return true
  end
  return append_tsv(p, code .. "\t" .. word .. "\t" .. mode)
end

local function mirror_remove(code, word)
  local p = mirror_path()
  local text = read_all(p)
  if not text then return false end
  local out, hit = {}, false
  for _, line in ipairs(mirror_lines(text)) do
    local c, w = line:match("^([^\t]+)\t([^\t]+)")
    if c and w and c == code and w == word then hit = true
    else out[#out + 1] = line end
  end
  if not hit then return false end
  return mirror_write(p, out)
end

-- userdb 連線快取：同一個方案內重用；建立失敗 60 秒內不再重試（避免每個按鍵都撞一次）
local function userdb_mem(env)
  local sid = schema_id(env)
  if mem_state.sid == sid then
    if mem_state.mem then return mem_state.mem end
    if (os.time() - (mem_state.fail_ts or 0)) < 60 then return nil end
  end
  local mem = nil
  local ok, err = pcall(function()
    if type(Memory) ~= "function" then error("Memory unavailable") end
    mem = Memory(env.engine, env.engine.schema, "translator")
  end)
  if ok and mem then
    mem_state.sid, mem_state.mem, mem_state.err = sid, mem, ""
    return mem
  end
  mem_state.sid, mem_state.mem, mem_state.fail_ts = sid, false, os.time()
  mem_state.err = ok and "Memory nil" or tostring(err)
  return nil
end

-- 1.4.20：使用者字典是否真的載入（寫入失敗最常見的原因是 user_dict 未載入）
local function userdb_loaded(mem)
  local v = nil
  pcall(function()
    local ud = mem.user_dict
    if ud then v = ud.loaded end
  end)
  return v
end

-- commits>0 寫入；commits<0 標記刪除。custom_code＝整串碼（不依賴引擎拼碼）。
-- 1.4.20：回傳第二個值＝診斷字串（寫進 userdb.log），不再讓 pcall 把原因吞掉。
local function userdb_update(env, code, word, commits)
  code, word = normalize_code(clean_text(code)), clean_text(word)
  if code == "" or word == "" then return false, "empty" end
  local mem = userdb_mem(env)
  if not mem then return false, "mem=" .. tostring(mem_state.err or "nil") end
  local ok, res = pcall(function()
    if type(DictEntry) ~= "function" then error("DictEntry unavailable") end
    local entry = DictEntry()
    entry.text = word
    entry.custom_code = code
    return mem:update_userdict(entry, commits, "")
  end)
  if not ok then return false, "err=" .. tostring(res) end
  local loaded = userdb_loaded(mem)
  if res == true then return true, "ret=true loaded=" .. tostring(loaded) end
  return false, "ret=" .. tostring(res) .. " loaded=" .. tostring(loaded)
end

-- 1.4.20：tabledb 的使用者字典只更新記憶體；librime 的 TextDb::Update 只設 modified_，
-- 要等 Close() 才 SaveToFile（引擎結束／重新部署）。所以上屏當下直接改同一份文字檔，
-- 讓詞立刻可見；引擎之後存檔時記憶體裡也有同一筆（共用同一個 Db），不會互相蓋掉。
local function tabledb_file(env)
  init_paths()
  local sid = schema_id(env)
  if sid == "?" or sid == "" then return nil end
  local p = BASE .. "\\" .. sid .. ".txt"
  local text = read_all(p)
  if not text then return nil end
  if not text:find("#@/db_type\ttabledb", 1, true) then return nil end
  return p, text
end

-- 直接在 tabledb 文字檔加／改／刪一筆（格式：詞<TAB>碼<TAB>次數；負次數＝刪除）
local function tabledb_update(env, code, word, commits)
  local p, text = tabledb_file(env)
  if not p then return false, "no_tabledb" end
  local out, found, changed, tick = {}, false, false, nil
  for line in (text:gsub("\r\n", "\n")):gmatch("[^\n]+") do
    local tk = line:match("^#@/tick\t(%d+)$")
    local w, c, n = line:match("^([^\t]+)\t([^\t]+)\t?(%-?%d*)$")
    if tk then
      tick = tonumber(tk) or 0
      out[#out + 1] = line
    elseif w and c and w == word and normalize_code(c) == code then
      found = true
      local old = tonumber(n) or 0
      if commits < 0 then
        changed = true                     -- 刪除：整行不輸出
      else
        local nn = old + commits
        if nn < 1 then nn = 1 end
        out[#out + 1] = word .. "\t" .. c .. "\t" .. tostring(nn)
        if nn ~= old then changed = true end
      end
    else
      out[#out + 1] = line
    end
  end
  if not found then
    if commits > 0 then
      out[#out + 1] = word .. "\t" .. code .. "\t" .. tostring(commits)
      changed = true
    else
      return true, "absent"
    end
  end
  if not changed then return true, "same" end
  if tick then
    for i = 1, #out do
      if out[i]:match("^#@/tick\t") then
        out[i] = "#@/tick\t" .. tostring(tick + 1)
        break
      end
    end
  end
  local pok, wok = pcall(write_all, p, table.concat(out, "\n") .. "\n")
  if not pok or wok ~= true then
    -- 寫入失敗：把原內容補回去，寧可這次不記，也不能弄丟既有詞庫
    pcall(function()
      local f = io.open(p, "w")
      if f then f:write(text); f:close() end
    end)
    return false, "write_fail"
  end
  return true, "written"
end

-- 上屏合成詞：依 mirror 設定寫 extra.tsv（預設不寫），再寫 userdb（記憶體＋文字檔）。
-- extra_done=true 表示呼叫端已經把這筆寫進 extra.tsv（造詞流程），這裡只補 userdb。
local function mirror_commit(env, code, word, extra_done)
  local cfg = load_config()
  if cfg.userdb == "off" then return false end
  init_paths()
  pcall(use_profile, env)
  code, word = normalize_code(clean_text(code)), clean_text(word)
  if code == "" or word == "" then
    udlog({ "commit", "empty", tostring(code), tostring(word) })
    return false
  end
  pcall(load_extra)
  local dup = false
  local L = (extra_cache.list or {})[code]
  if L then
    for i = 1, #L do
      if L[i].word == word then dup = true; break end
    end
  end
  -- 1.4.20：預設 mirror=userdb → 合成詞上屏不重複寫 extra.tsv（造詞路徑 extra_done=true 照舊）
  local wrote_extra = false
  if not dup and not extra_done and cfg.mirror == "both" then
    local target = write_target("extra.tsv", EXTRA)
    if not append_tsv(target, code .. "\t" .. word) then
      udlog({ "commit", "extra_fail", code, word })
      return false
    end
    pcall(extra_apply_word, code, word)
    wrote_extra = true
  end
  local mode = (extra_done or dup or wrote_extra) and "extra" or "userdb"
  local ok, why = userdb_update(env, code, word, 1)
  local file_ok, file_why = false, "skip"
  if ok then
    pcall(mirror_add, code, word, mode)
    file_ok, file_why = tabledb_update(env, code, word, 1)
  end
  udlog({ "commit", ok and "ok" or "fail", "mode=" .. mode,
      "extra=" .. tostring(extra_done or wrote_extra or dup), code, word, why,
      "file=" .. tostring(file_ok) .. ":" .. tostring(file_why),
      "schema=" .. schema_id(env) })
  if not ok then
    pcall(append_tsv, STATUS, "userdbfail\t" .. os.date("%Y-%m-%d %H:%M:%S")
        .. "\t" .. code .. "\t" .. word)
  end
  return ok
end

-- 刪詞同步：extra 刪掉後，userdb 也要刪，否則下次又冒出來
local function userdb_delete(env, code, word)
  local cfg = load_config()
  if cfg.userdb == "off" then return false end
  code, word = normalize_code(clean_text(code)), clean_text(word)
  if code == "" or word == "" then return false end
  local ok, why = userdb_update(env, code, word, -1)
  local file_ok, file_why = false, "skip"
  if ok then
    pcall(mirror_remove, code, word)
    file_ok, file_why = tabledb_update(env, code, word, -1)
  end
  udlog({ "delete", ok and "ok" or "fail", code, word, why,
      "file=" .. tostring(file_ok) .. ":" .. tostring(file_why),
      "schema=" .. schema_id(env) })
  return ok
end

-- 掃描對帳：鏡像裡有、extra.tsv 已沒有的 → 刪 userdb 並移除鏡像行。
-- 這條同時涵蓋「工作台刪詞／手改 extra.tsv」等不經過 lua 刪詞路徑的情況。
-- 1.4.20：第三欄 userdb＝只在 userdb 的詞（mirror=userdb 的預設行為），不對帳、不誤刪；
--          兩欄舊行與 extra 行才跟 extra.tsv 對帳。
local function userdb_sweep(env)
  local p = mirror_path()
  local text = read_all(p)
  if not text or text == "" then return false end
  local target = write_target("extra.tsv", EXTRA)
  if file_size(target) == nil then return false end   -- 沒有 extra：不判斷、不刪
  pcall(load_extra)
  local set = {}
  local list = extra_cache.list or {}
  for code, L in pairs(list) do
    for i = 1, #L do set[code .. "\x1f" .. L[i].word] = true end
  end
  local out, changed, n = {}, false, 0
  for _, line in ipairs(mirror_lines(text)) do
    local c, w = line:match("^([^\t]+)\t([^\t]+)")
    if c and w then
      if mirror_mode(line) == "userdb" then
        out[#out + 1] = line                    -- 只在 userdb：保留
      elseif set[c .. "\x1f" .. w] then
        out[#out + 1] = line
      elseif userdb_update(env, c, w, -1) then
        pcall(tabledb_update, env, c, w, -1)
        changed, n = true, n + 1
      else
        out[#out + 1] = line
      end
    else
      out[#out + 1] = line
    end
  end
  if changed then
    mirror_write(p, out)
    pcall(append_tsv, STATUS, "userdbsweep\t" .. os.date("%Y-%m-%d %H:%M:%S") .. "\t" .. tostring(n))
    udlog({ "sweep", "removed=" .. tostring(n), "schema=" .. schema_id(env) })
  end
  return changed
end

-- 重建：把本方案 extra.tsv 的每一筆（code<TAB>word）用同一整串碼寫進 userdb。
-- 觸發條件：config.ini 寫 userdb=rebuild；完成後自動改回 userdb=on（失敗保留 rebuild 供重試）。
local function userdb_rebuild(env)
  local target = write_target("extra.tsv", EXTRA)
  local text = read_all(target) or ""
  local mp = mirror_path()
  local mtext = read_all(mp) or ""
  local mset, mlines = {}, {}
  for _, line in ipairs(mirror_lines(mtext)) do
    local c, w = line:match("^([^\t]+)\t([^\t]+)")
    if c and w then mset[c .. "\x1f" .. w] = true end
    mlines[#mlines + 1] = line                  -- 保留原行（含第三欄）
  end
  local ok_all, total = true, 0
  for line in text:gmatch("[^\r\n]+") do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local c, w = line:match("^(.-)\t([^\t]+)")
      if c and w then
        c = normalize_code(c)
        if c ~= "" and c:match("^[%a%s';`]+$") then
          total = total + 1
          if userdb_update(env, c, w, 1) then
            local k = c .. "\x1f" .. w
            if not mset[k] then
              mset[k] = true
              mlines[#mlines + 1] = c .. "\t" .. w .. "\textra"
            end
          else
            ok_all = false
          end
        end
      end
    end
  end
  if #mlines > 0 then
    mirror_write(mp, mlines)
  end
  if ok_all or total == 0 then
    local ct = write_target("config.ini", CONFIG)
    local ctext = read_all(ct)
    local lines, found = {}, false
    if ctext and ctext ~= "" then
      for line in ctext:gmatch("[^\r\n]+") do
        if line:match("^%s*userdb%s*=") then
          lines[#lines + 1] = "userdb=on"
          found = true
        else
          lines[#lines + 1] = line
        end
      end
    end
    if not found then
      if #lines == 0 or lines[1] ~= "#v1" then table.insert(lines, 1, "#v1") end
      lines[#lines + 1] = "userdb=on"
    end
    if write_all(ct, table.concat(lines, "\n") .. "\n") then
      cfg_cache.userdb = "on"
      cfg_cache.sec = -1
    end
  end
  pcall(append_tsv, STATUS, "userdbrebuild\t" .. os.date("%Y-%m-%d %H:%M:%S")
      .. "\t" .. tostring(total) .. "\t" .. (ok_all and "ok" or "partial"))
  udlog({ "rebuild", ok_all and "ok" or "partial", "total=" .. tostring(total),
      "schema=" .. schema_id(env) })
  return ok_all
end

-- 每個按鍵最多走到這裡一次：rebuild 優先（手動觸發），其餘每 120 秒對帳一次
local function userdb_tick(env)
  local cfg = load_config()
  if cfg.userdb == "off" then return end
  local now = os.time()
  if cfg.userdb == "rebuild" then
    if (now - (rebuild_state.sec or -1)) < 60 then return end
    rebuild_state.sec = now
    return userdb_rebuild(env)
  end
  if (now - (sweep_state.sec or -1)) < 120 then return end
  sweep_state.sec = now
  return userdb_sweep(env)
end


-- UTF-8 字數（只數非續位元組）
utf8_chars = function(s)
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then n = n + 1 end
  end
  return n
end

-- 依 formula 由主碼分段組出簡碼（規則與工作台一致：Z＝末字、z＝末碼）
build_short = function(segs, nchars, formula)
  if #formula == 0 or #formula % 2 ~= 0 then return nil end
  local out = {}
  for i = 1, #formula, 2 do
    local u = formula:sub(i, i)
    local l = formula:sub(i + 1, i + 1)
    if not u:match("^[A-Z]$") or not l:match("^[a-z]$") then return nil end
    local ci
    if u == "Z" then ci = nchars else ci = string.byte(u) - 64 end
    if ci < 1 or ci > nchars then return nil end
    local sg = segs[ci]
    if not sg or sg == "" then return nil end
    local want
    if l == "z" then want = #sg else want = string.byte(l) - 96 end
    if want < 1 or want > #sg then return nil end
    out[#out + 1] = sg:sub(want, want)
  end
  local s = table.concat(out)
  if s == "" then return nil end
  return s
end

-- ---------- 迷你正則（fuzz 規則用） ----------
-- rules.yaml 的 fuzz/<pattern>/<replacement>/ 照 Rime algebra 寫法；這裡實作 fuzz 常見語法：
-- ^ $ . [...] (...) * + ? {n} {n,m} | \x。匹配採「整段完全匹配」，replacement 支援 $0..$9。
local RX_MAX_GROUPS = 16

local function rx_snap(caps, n)
  local t = {}
  for i = 1, n do
    local v = caps[i]
    t[i] = v and { v[1], v[2] } or nil
  end
  return t
end

local function rx_rest(caps, t)
  for i = 1, #t do
    local v = t[i]
    caps[i] = v and { v[1], v[2] } or nil
  end
end

local rx_match_node, rx_match_alt, rx_match_seq

rx_match_seq = function(comp, kids, i, s, pos, caps, k)
  if i > #kids then return k(pos) end
  return rx_match_node(comp, kids[i], s, pos, caps, function(p)
    return rx_match_seq(comp, kids, i + 1, s, p, caps, k)
  end)
end

rx_match_alt = function(comp, branches, s, pos, caps, k)
  for bi = 1, #branches do
    local snap = rx_snap(caps, comp.groups)
    if rx_match_seq(comp, branches[bi], 1, s, pos, caps, k) then return true end
    rx_rest(caps, snap)
  end
  return false
end

local function rx_match_rep(comp, node, s, pos, caps, k)
  local mn, mx = node.mn, node.mx
  local go
  go = function(n, p)
    if mx < 0 or n < mx then
      local snap = rx_snap(caps, comp.groups)
      local ok = rx_match_node(comp, node.kid, s, p, caps, function(np)
        if np == p then return false end
        return go(n + 1, np)
      end)
      if ok then return true end
      rx_rest(caps, snap)
    end
    if n >= mn then return k(p) end
    return false
  end
  return go(0, pos)
end

local function rx_match_group(comp, node, s, pos, caps, k)
  local snap = rx_snap(caps, comp.groups)
  caps[node.idx] = { pos, pos - 1 }
  local function close(p)
    caps[node.idx][2] = p - 1
    if k(p) then return true end
    caps[node.idx][2] = pos - 1
    return false
  end
  local ok = rx_match_alt(comp, node.kids, s, pos, caps, close)
  if not ok then rx_rest(caps, snap) end
  return ok
end

rx_match_node = function(comp, node, s, pos, caps, k)
  local t = node.t
  if t == "char" then
    if pos > #s or s:sub(pos, pos) ~= node.c then return false end
    return k(pos + 1)
  elseif t == "any" then
    if pos > #s then return false end
    return k(pos + 1)
  elseif t == "class" then
    if pos > #s then return false end
    local ch = s:sub(pos, pos)
    local hit = false
    for _, it in ipairs(node.items) do
      if ch >= it[1] and ch <= it[2] then hit = true; break end
    end
    if node.neg then hit = not hit end
    if not hit then return false end
    return k(pos + 1)
  elseif t == "group" then
    return rx_match_group(comp, node, s, pos, caps, k)
  elseif t == "rep" then
    return rx_match_rep(comp, node, s, pos, caps, k)
  end
  return false
end

local function rx_compile(pattern)
  local p = pattern or ""
  if p:sub(1, 1) == "^" then p = p:sub(2) end
  if p:sub(-1) == "$" then p = p:sub(1, -2) end
  local pos, glen = 1, #p
  local groups = 0
  local parse_atom, parse_quant, parse_seq, parse_alt

  parse_atom = function()
    local c = p:sub(pos, pos)
    if c == "(" then
      pos = pos + 1
      groups = groups + 1
      local gid = groups
      local node = { t = "group", idx = gid, kids = parse_alt() }
      if p:sub(pos, pos) == ")" then pos = pos + 1 end
      return node
    elseif c == "[" then
      pos = pos + 1
      local neg = false
      if p:sub(pos, pos) == "^" then neg = true; pos = pos + 1 end
      local items = {}
      while pos <= glen do
        local ch = p:sub(pos, pos)
        if ch == "]" and #items > 0 then break end
        pos = pos + 1
        if ch == "\\" and pos <= glen then
          ch = p:sub(pos, pos)
          pos = pos + 1
        end
        if p:sub(pos, pos) == "-" and pos < glen and p:sub(pos + 1, pos + 1) ~= "]" then
          items[#items + 1] = { ch, p:sub(pos + 1, pos + 1) }
          pos = pos + 2
        else
          items[#items + 1] = { ch, ch }
        end
      end
      if p:sub(pos, pos) == "]" then pos = pos + 1 end
      return { t = "class", neg = neg, items = items }
    elseif c == "." then
      pos = pos + 1
      return { t = "any" }
    elseif c == "\\" then
      pos = pos + 1
      local e = p:sub(pos, pos)
      pos = pos + 1
      return { t = "char", c = e }
    else
      pos = pos + 1
      return { t = "char", c = c }
    end
  end

  parse_quant = function()
    local atom = parse_atom()
    local c = p:sub(pos, pos)
    if c == "*" then pos = pos + 1; return { t = "rep", kid = atom, mn = 0, mx = -1 } end
    if c == "+" then pos = pos + 1; return { t = "rep", kid = atom, mn = 1, mx = -1 } end
    if c == "?" then pos = pos + 1; return { t = "rep", kid = atom, mn = 0, mx = 1 } end
    if c == "{" then
      local inner = p:match("^{([%d,]*)}", pos)
      if inner then
        local a, b = inner:match("^(%d+)%,(%d*)$")
        local n = inner:match("^(%d+)$")
        if a then
          pos = pos + #inner + 2
          return { t = "rep", kid = atom, mn = tonumber(a), mx = (b ~= "" and tonumber(b)) or -1 }
        elseif n then
          pos = pos + #inner + 2
          return { t = "rep", kid = atom, mn = tonumber(n), mx = tonumber(n) }
        end
      end
    end
    return atom
  end

  parse_seq = function()
    local kids = {}
    while pos <= glen do
      local c = p:sub(pos, pos)
      if c == "|" or c == ")" then break end
      if c == "^" or c == "$" then
        pos = pos + 1
      else
        kids[#kids + 1] = parse_quant()
      end
    end
    return kids
  end

  parse_alt = function()
    local branches = { parse_seq() }
    while p:sub(pos, pos) == "|" do
      pos = pos + 1
      branches[#branches + 1] = parse_seq()
    end
    return branches
  end

  local branches = parse_alt()
  if groups > RX_MAX_GROUPS then return nil end
  return { branches = branches, groups = groups }
end

local function rx_apply(comp, s, rep)
  local caps = {}
  local ok = rx_match_alt(comp, comp.branches, s, 1, caps, function(p) return p > #s end)
  if not ok then return nil end
  local out = rep:gsub("%$(%d+)", function(i)
    local idx = tonumber(i)
    if idx == 0 then return s end
    local cp = caps[idx]
    if not cp then return "" end
    return s:sub(cp[1], cp[2])
  end)
  return out
end

-- 解析 reorder\rules.yaml（只支援本專案格式；壞條目略過）
-- 1.3.10：新增 fuzz/<pattern>/<replacement>/（逐段套用）
-- 1.4.0：補齊 Rime spelling algebra 的四個算子（derive／xform／abbrev／fuzz），
--        並支援 strict_spelling。作用域限定在「本工具管理的詞」：
--        extra.tsv 的詞、vocab.txt 新建的詞、以及本工具重算出的輔助碼；
--        引擎原生詞庫的碼不讀、不寫、也碰不到。
local OP_KINDS = { derive = true, xform = true, abbrev = true, fuzz = true }
rules_cache = {
  text_sig = nil, rules = {}, ops = {}, memo = {},
  prefix_on = true, strict = false, compose_on = true,
}
load_rules = function()
  init_paths()
  local text, hit = cached_text(RULES, rules_cache)
  if hit then return rules_cache.rules end
  parse_rules = parse_rules + 1
  rules_cache.memo = {}   -- 規則換了：舊簡碼快取全部作廢
  local rules = {}
  local ops = {}
  local prefix_on = true   -- 1.3.15：不定碼連續輸入（前綴分段匹配）預設開啟
  local strict = false     -- 1.4.0：strict_spelling（預設 off）
  local compose_on = true  -- 1.4.15：多截碼整詞合成（預設 on）
  -- 目前的字數區段；nil＝尚未出現 length_*（算子在此時為全域）
  local minlen, maxlen = nil, -1
  local function op_range()
    return minlen or 1, maxlen or -1
  end
  for line in text:gmatch("[^\r\n]+") do
    if line:match("^%s*#") then
      -- 註解行（含 fuzz／formula 字樣）一律略過
    else
      local pv = line:match("^%s*prefix_match%s*:%s*([%w]+)")
      local sv = line:match("^%s*strict_spelling%s*:%s*([%w]+)")
      local cv = line:match("^%s*compose_candidates%s*:%s*([%w]+)")
      if pv then
        -- on/off、true/false、1/0（大小寫不拘）；其餘視為 on
        pv = pv:lower()
        prefix_on = not (pv == "off" or pv == "false" or pv == "0")
      elseif sv then
        sv = sv:lower()
        strict = not (sv == "off" or sv == "false" or sv == "0")
      elseif cv then
        -- 1.4.15：多截碼整詞合成開關（預設 on；off 只關這條追加路徑）
        cv = cv:lower()
        compose_on = not (cv == "off" or cv == "false" or cv == "0")
      else
        local kind, body = line:match("^%s*[%-]?%s*([%a]+)/(.+)$")
        if kind and OP_KINDS[kind] then
          body = body:gsub('[%s"\']+$', "")
          if body:sub(-1) == "/" then
            local inner = body:sub(1, -2)
            local pat, rep = inner:match("^(.+)/(.*)$")
            if pat and pat ~= "" then
              local comp = rx_compile(pat)
              if comp then
                local omin, omax = op_range()
                -- fuzz 沿用 1.3.x 的「全域有效、不分字數」語義（相容既有設定）
                if kind == "fuzz" then omin, omax = 1, -1 end
                local op = { kind = kind, pat = pat, rep = rep, comp = comp,
                             min = omin, max = omax }
                ops[#ops + 1] = op
              end
            end
          end
        else
          local n = line:match("length_equal:%s*(%d+)")
          if n then
            minlen, maxlen = tonumber(n), tonumber(n)
          else
            local lo, hi = line:match("length_in_range:%s*%[%s*(%d+)%s*,%s*(%d*)%s*%]")
            if lo then
              minlen = tonumber(lo)
              maxlen = (hi ~= "" and hi) and tonumber(hi) or -1
            else
              local one = line:match("length_in_range:%s*%[%s*(%d+)%s*%]")
              if one then minlen, maxlen = tonumber(one), -1 end
            end
          end
          local f = line:match('formula:%s*"([^"]*)"')
          if not f then f = line:match("formula:%s*([%a]+)") end
          if f and minlen and #f % 2 == 0 then
            local valid = true
            for i = 1, #f, 2 do
              if not f:sub(i, i):match("^[A-Z]$") or not f:sub(i + 1, i + 1):match("^[a-z]$") then
                valid = false
                break
              end
            end
            if valid then rules[#rules + 1] = { min = minlen, max = maxlen, formula = f } end
          end
        end
      end
    end
  end
  rules_cache.rules = rules
  rules_cache.ops = ops
  rules_cache.prefix_on = prefix_on
  rules_cache.strict = strict
  rules_cache.compose_on = compose_on
  return rules
end

-- 產生簡碼清單（1.3.10／1.4.0）：
--   formula：只套「命中規則中最 specific 的一條」（min 最大），品質 4.7 起每條 -0.2
--   derive／xform／abbrev／fuzz：按檔案書寫順序逐段（每字全碼）套用
--     derive：原碼保留，另外生成一條（模糊音、容錯拼寫）
--     abbrev：生成帶「縮略」屬性的碼（首字母簡拼）
--     xform ：只生成改寫後的碼，原碼不再生成（derive 的對偶；後寫覆蓋先寫）
--     fuzz  ：生成帶「模糊」屬性的碼
--   回傳 out（{code,q,attr} 清單）與 suppress（xform 改寫了主碼本身時為 true）
make_short_codes = function(segs, nchars, main_code)
  -- 1.3.11：同一主碼在「同一份 rules」下只算一次；連續打字不重跑正則
  local rules = load_rules()
  local memo = rules_cache.memo
  local hit = memo[main_code]
  if hit then return hit.out, hit.suppress end
  local out = {}
  if nchars == 0 or #segs ~= nchars then
    memo[main_code] = { out = out, suppress = false }
    return out, false
  end
  local seen = { [main_code] = true }
  -- 1.3.12：每條含空白的簡碼再生成一條「去空白連寫版」（可直接連打，不必反引號）
  --   連寫版品質＝分段版 −0.1（不佔用規則階梯的 −0.2 步進）
  local function push_code(c, q, attr)
    if not c or c == "" or seen[c] then return false end
    seen[c] = true
    out[#out + 1] = { code = c, q = q, attr = attr }
    return true
  end
  local function push_short(c, q, attr)
    local added = push_code(c, q, attr)
    if c:find(" ", 1, true) then
      local cc = c:gsub(" ", "")
      local qq = q - 0.1
      if qq < 1.0 then qq = 1.0 end
      push_code(cc, qq, attr)
    end
    return added
  end

  local best = nil
  for _, r in ipairs(rules) do
    if nchars >= r.min and (r.max < 0 or nchars <= r.max) then
      if not best or r.min > best then best = r.min end
    end
  end
  local q = 4.7
  local nform = 0   -- 只計「分段主體」，連寫版不影響 fuzz 起算品質
  if best then
    for _, r in ipairs(rules) do
      if r.min == best and nchars >= r.min and (r.max < 0 or nchars <= r.max) then
        local sc = build_short(segs, nchars, r.formula)
        if sc and sc ~= "" then
          if push_short(sc, q, "formula") then
            nform = nform + 1
            q = q - 0.2
            if q < 1.0 then q = 1.0 end
          end
        end
      end
    end
  end

  -- 1.4.0：算子鏈。每個「拼寫狀態」代表一條目前有效的碼；
  -- derive／abbrev／fuzz 由它再長出新的狀態，xform 直接把該狀態改寫掉。
  local ops = rules_cache.ops or {}
  local states = { { segs = segs, attr = nil, base = true, changed = false } }
  local suppress = false
  for _, op in ipairs(ops) do
    if nchars >= op.min and (op.max < 0 or nchars <= op.max) then
      local adds = {}
      for si = 1, #states do
        local st = states[si]
        local parts, ok = {}, true
        for i = 1, nchars do
          local ns = rx_apply(op.comp, st.segs[i], op.rep)
          if not ns or ns == "" then ok = false; break end
          parts[i] = ns
        end
        if ok then
          local cur = table.concat(st.segs, " ")
          local nw = table.concat(parts, " ")
          if nw ~= cur then
            if op.kind == "xform" then
              -- 只留改寫後的碼；主碼本身被改寫時，執行期同步停用原碼
              if st.base and not st.changed then suppress = true end
              st.segs = parts
              st.attr = "xform"
              st.changed = true
            else
              adds[#adds + 1] = { segs = parts, attr = op.kind }
            end
          end
        end
      end
      for _, a in ipairs(adds) do
        states[#states + 1] = { segs = a.segs, attr = a.attr, base = false, changed = false }
      end
    end
  end

  local fq = 4.7 - 0.2 * math.max(nform, 1)
  for si = 1, #states do
    local st = states[si]
    if (not st.base) or st.changed then
      local c = table.concat(st.segs, " ")
      if push_short(c, fq, st.attr) then
        fq = fq - 0.2
        if fq < 1.0 then fq = 1.0 end
      end
    end
  end
  memo[main_code] = { out = out, suppress = suppress }
  return out, suppress
end

-- Shift+空格造詞時，依 rules.yaml 由主碼分段產生簡碼寫回 extra.tsv
-- （formula 4.7 起，derive／xform／abbrev／fuzz 依書寫順序每條 -0.2）
-- 1.4.0：第 4 欄寫屬性（derive／xform／abbrev／fuzz）；formula 不留屬性欄。
-- 1.4.11：extra.tsv 只整檔讀一次、缺的簡碼一次批量寫入（不再每條 append 前重讀），
--         寫完把手上的行增量併進快取。
local function expand_shorts(code, word)
  local nchars = utf8_chars(word)
  local segs = {}
  for s in code:gmatch("%S+") do segs[#segs + 1] = s end
  if nchars == 0 or #segs ~= nchars then return end
  local target = write_target("extra.tsv", EXTRA)
  -- 只比對檔案實際內容（load_extra 會在記憶體補簡碼，不能拿來判斷「已寫入」）。
  -- 1.4.11：快取已載入時直接看條目的 file 標記，不再整檔掃 4.5 萬行；未載入才退回掃描。
  local scan = not extra_cache.idx
  local exists = nil
  if scan then
    exists = {}
    local text = read_all(target)
    if text then
      for line in text:gmatch("[^\r\n]+") do
        local c2, w2 = line:match("^(.-)\t([^\t]+)")
        if c2 then
          c2 = normalize_code(c2)
          if c2 ~= "" and w2 == word then exists[c2] = true end
        end
      end
    end
  end
  local shorts = make_short_codes(segs, nchars, code)
  local rows, codes = {}, {}
  local picked = {}
  for _, sc in ipairs(shorts) do
    local hit = picked[sc.code]
    if hit == nil then
      if scan then hit = (exists[sc.code] == true) else hit = extra_file_has(sc.code, word) end
      picked[sc.code] = hit
    end
    if not hit then
      local row = sc.code .. "\t" .. word .. "\t" .. string.format("%.2f", sc.q)
      if sc.attr and sc.attr ~= "" and sc.attr ~= "formula" then
        row = row .. "\t" .. sc.attr
      end
      rows[#rows + 1] = row
      codes[#codes + 1] = sc
    end
  end
  if #rows == 0 then return end
  if not append_tsv(target, table.concat(rows, "\n")) then return end
  for i = 1, #codes do
    local sc = codes[i]
    local attr = (sc.attr ~= "" and sc.attr ~= "formula") and sc.attr or nil
    pcall(extra_apply_row, sc.code, word, sc.q, attr, true)
  end
end

-- 1.3.21：造詞也寫進 vocab.txt（否則歷史有紀錄、詞彙表找不到、刪不掉）。
-- 1.3.23：改成回傳成功／失敗原因，失敗要能留下可見痕跡（不再靜默 return）。
-- 1.4.11：同詞同碼的確認改用「大小不變就沿用的索引」，不再每次整檔掃 3.6 萬行。
-- 格式：詞\t碼\t權重\t類型\t時間；同詞同碼不重複寫。
local vocab_scan = { path = nil, size = nil, set = {} }

-- 1.4.11：確保 vocab 索引對應目前檔案大小（大小沒變就沿用，不重掃 3.6 萬行）
local function vocab_ensure(target)
  local sz = file_size(target) or 0
  if vocab_scan.path ~= target or vocab_scan.size ~= sz then
    vocab_scan.path, vocab_scan.size, vocab_scan.set = target, sz, {}
    local text = read_all(target)
    if text then
      for line in text:gmatch("[^\r\n]+") do
        local w2, c2 = line:match("^([^\t]+)\t([^\t]+)")
        if w2 and c2 then vocab_scan.set[w2 .. "\t" .. c2] = true end
      end
    end
  end
  return vocab_scan.set
end

-- 1.4.11：造詞前先問「這個詞／碼是否已在 vocab」——已在就不必為 vocab 存快照
local function vocab_has(code, word)
  init_paths()
  word = clean_text(word)
  code = clean_text(code)
  if word == "" or code == "" then return false end
  local target = write_target("vocab.txt", VOCAB)
  return vocab_ensure(target)[word .. "\t" .. code] == true
end

local function vocab_append(code, word)
  init_paths()
  word = clean_text(word)
  code = clean_text(code)
  if word == "" or code == "" then return false, "empty" end
  -- 1.4.1：寫入本方案目錄（缺檔先從讀取來源複製）；append_tsv 會補檔尾換行
  local target = write_target("vocab.txt", VOCAB)
  local key = word .. "\t" .. code
  local set = vocab_ensure(target)
  if set[key] then return true, "exists" end
  if not append_tsv(target,
      word .. "\t" .. code .. "\t4.9\t新詞\t" .. os.date("%Y-%m-%d %H:%M")) then
    return false, "write"
  end
  set[key] = true
  vocab_scan.size = file_size(target) or 0
  -- 1.3.24：記下這次是「本工具追加」，工作台看到後略過外部編輯套用，
  -- 不再多寫一條 edit 歷史、也不再重複寫 rank。
  append_tsv(VOCAB_OPS, "+" .. word .. "\t" .. code)
  return true, "ok"
end

-- 1.4.13：造詞碼回切。只有「整串連寫（無空白、無反引號）」且段數≠字數時才嘗試：
-- 用方案拼寫集切成剛好「字數」段，且切法唯一、平均每段≥2 字母才採用；
-- 切不出就回 nil 與原因（保留原樣，另留診斷標記，不猜）。
local function auto_split_code(code, nchars)
  if type(code) ~= "string" or code == "" or nchars < 2 then return nil, "short" end
  if code:find("%s") or code:find("`", 1, true) then return nil, "spaced" end
  if #code < nchars * 2 then return nil, "len=" .. #code end
  local ok_sp, sp = pcall(load_spellings)
  if not ok_sp or not sp then return nil, "nospell" end
  local s, nparts, ways = split_by_spelling(code:lower(), sp)
  if not s then return nil, "unmatched" end
  if nparts ~= nchars then return nil, "parts=" .. tostring(nparts) end
  if (ways or 0) ~= 1 then return nil, "ways=" .. tostring(ways) end
  return s
end

local function record_newword(env, code, word, preedit)
  init_paths()
  pcall(use_profile, env)   -- 1.4.0：造詞要寫進當前方案的 extra.tsv
  local sid = schema_id(env)
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  -- 取證：原樣記錄本函式收到的 input／preedit（%TEMP%\rime_reorder_newword.log）
  local tmp = os.getenv("TEMP") or "."
  local lf = io.open(tmp .. "\\rime_reorder_newword.log", "a")
  if lf then
    pcall(function()
      lf:write(ts .. "\tinput=[" .. tostring(code) .. "]\tpreedit=[" ..
               tostring(preedit) .. "]\tword=[" .. tostring(word) .. "]\n")
    end)
    pcall(function() lf:close() end)
  end
  code = clean_text(code)
  word = clean_text(word)
  code = normalize_code(code)   -- 反引號分隔統一成空白，工作台才能切成 4 段
  -- 1.4.13：連寫碼先按方案拼寫回切成逐字段，後面才能生成簡碼／衍生碼
  local nchars = utf8_chars(word)
  local nseg = 0
  for _ in code:gmatch("%S+") do nseg = nseg + 1 end
  local split_from, split_to, split_why = nil, nil, nil
  if nchars > 0 and nseg ~= nchars and not code:find("%s") then
    local s, why = auto_split_code(code, nchars)
    if s then
      split_from, split_to, code = code, s, s
    else
      split_why = why
    end
  end
  -- 1.4.2：造詞前先寫前像（失敗也照常造詞，只是這一筆不可撤）
  -- 1.4.11：造詞只會動 extra／vocab，快照不再連 rank 也複製一份；
  --          同詞同碼已在 vocab → vocab 不會變，連 vocab 快照也省掉。
  local need_vocab = not vocab_has(code, word)
  local snap_key, snap_paths = snapshot_before({ extra = true, vocab = need_vocab })
  local extra_ok = append_tsv(snap_paths.extra, code .. "\t" .. word)
  local hist_extra = snap_key and ("1|" .. snap_key) or ""
  append_tsv(HISTORY, ts .. "\tnewword\t" .. word .. "\t\t\t" .. clean_text(sid) .. "\t" .. hist_extra)
  -- 1.4.13：回切結果／失敗原因各留一列（歷史永久留存；status 供即時診斷）
  if split_to then
    append_tsv(HISTORY, ts .. "\tnewseg\t" .. word .. "\t" .. split_from .. "\t" .. split_to
        .. "\t" .. clean_text(sid) .. "\t")
    append_tsv(STATUS, "newseg\t" .. ts .. "\t" .. split_from .. "\t" .. split_to .. "\t" .. word)
  elseif split_why then
    append_tsv(HISTORY, ts .. "\tnewsegfail\t" .. word .. "\t" .. code
        .. "\t\t" .. clean_text(sid) .. "\t" .. split_why)
    append_tsv(STATUS, "newsegfail\t" .. ts .. "\t" .. code .. "\t" .. word .. "\t" .. split_why)
  end
  -- 心跳註記：status.tsv 最後多一行，方便除錯／工作台追蹤
  append_tsv(STATUS, "newword\t" .. ts .. "\t" .. code .. "\t" .. word)
  -- 1.3.21：造詞後要讓快取看到剛剛 append 的詞；
  -- 1.4.11：只增量併入新行（含簡碼與前綴索引），不再整檔重解析、也不打壞快取。
  if extra_ok then pcall(extra_apply_word, code, word) end
  -- 1.4.19：造詞也鏡像進 userdb（extra 已寫成功才做；失敗只是少一份，不影響造詞）
  if extra_ok then pcall(mirror_commit, env, code, word, true) end
  local vocab_ok, vocab_why = vocab_append(code, word)
  pcall(expand_shorts, code, word)
  -- 1.4.2：造詞完成後存操作後像，Ctrl+Y 可位元級重做整筆造詞
  snapshot_after(snap_key, snap_paths, { extra = true, vocab = need_vocab })
  -- 1.3.23：任何一處落檔失敗都不再靜默——記進 status 與歷史（工作台看得到「造詞失敗」）
  if (not extra_ok) or (not vocab_ok) then
    append_tsv(STATUS, "newwordfail\t" .. ts .. "\t" .. code .. "\t" .. word
        .. "\textra=" .. (extra_ok and "ok" or "fail")
        .. "\tvocab=" .. tostring(vocab_why))
    append_tsv(HISTORY, ts .. "\tnewwordfail\t" .. word .. "\t" .. code
        .. "\t\t" .. clean_text(sid) .. "\t")
  end
  return true
end

-- 寫心跳 status.tsv（有節流）與候選清單 candidates.tsv（每次變更即時寫，供工作台顯示）
local function write_status(env, input, ranked, moved, count)
  local now = os.time()
  last_status_sec = now
  local sid = schema_id(env)
  local lines = {
    "#v1",
    "ts\t" .. now,
    "iso\t" .. os.date("%Y-%m-%d %H:%M:%S", now),
    "schema\t" .. clean_text(sid),
    "profile\t" .. clean_text(prof_state.id or "legacy"),
    "scope\t" .. clean_text(sid .. ":" .. input),
    "calls\t" .. tostring(calls),
    "version\t" .. VERSION,
    "count\t" .. tostring(count),
    "ranked\t" .. tostring(ranked),
    "moved\t" .. tostring(moved),
    "input\t" .. clean_text(input),
    "parse\trank:" .. parse_rank .. " extra:" .. parse_extra .. " rules:" .. parse_rules,
    "writes\tcand:" .. writes_cand,
  }
  write_all(STATUS, table.concat(lines, "\n") .. "\n")
end

local function dump_candidates(env, input, ordered_cands, scores, ords, poss, hasposs, ranked, moved, count, off)
  local now = os.time()
  local sid = schema_id(env)
  local clines = {
    "#v1",
    "ts\t" .. now,
    "schema\t" .. clean_text(sid),
    "input\t" .. clean_text(input),
    "count\t" .. tostring(count),
    "ranked\t" .. tostring(ranked),
    "moved\t" .. tostring(moved),
  }
  -- 1.3.22：排序關閉時仍寫完整候選，只多這一行說明「本批未調序」
  if off then clines[#clines + 1] = "off\t1" end
  for i, c in ipairs(ordered_cands) do
    local txt = clean_text(c.text)
    local sc = scores[i] or 0
    -- 1.3.3：comment 已是候選窗顯示字串（「編碼 標記」或只「標記」），原樣寫入
    local note = clean_text(c.comment)
    -- 1.3.20：追加引擎原序（ord）與位置序（pos），供工作台拖曳計算座標
    local ordv = tostring(ords[i] or i)
    local posv = (hasposs[i] and poss[i])
        and string.format("%.10g", poss[i]) or ""
    clines[#clines + 1] = "c\t" .. tostring(i - 1) .. "\t" ..
      string.format("%.2f", sc) .. "\t" .. txt .. "\t" .. note ..
      "\t" .. ordv .. "\t" .. posv
  end
  write_all(CANDIDATES, table.concat(clines, "\n") .. "\n")
end

local function simple_hash(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + string.byte(s, i)) % 4294967296
  end
  return tostring(h)
end

-- ===== 1.3.14：執行期前綴分段匹配 =====
-- extra.tsv 的分段全碼（例 szwc siai sqnc lurr）就是該詞每字的全碼。
-- 使用者打任意連續輸入（不必含分隔符）時，把去反引號／空白後的連續字串 S，
-- 切成剛好「詞的字數」N 段，每段非空、是對應字全碼的前綴，且整串剛好用完。
-- 例：szsisqlu → sz|si|sq|lu；只命中一個候選（同一詞只吐一條）。
-- 切法選擇：S 長度固定，總命中碼數恆等於 |S|，故比例＝|S|／全碼總長；
--   同比例時取「先出現」的切法（DFS 由短到長，結果穩定不跳動）。
-- 效能（1.3.18）：載入 extra 時建「字數 -> 首段首 2 碼」索引，查詢只掃
--   「字數 ≤ |S|」且首段前綴相同的桶（L=1 天生只剩單字詞）；DP 期間不切字串、
--   不比對臨時子字串（改用 string.byte），暫存表重用不清空重建。
--   同一輸入字串與同一 extra 內容直接回快取。
-- 已知限制：只認「前綴」；變長音碼若前綴不足以區分仍需分隔符或字碼表。
pref_cache = { key = nil, hit = nil }

-- 1.3.21：rev.tsv 有變 → 全部快取失效（工作台每個寫檔動作都會更新這個小檔）。
-- 1.4.4：rev 不再承擔開關語義（只當「資料變了」的戳記），排序開關看 config.ini 的 enabled。
refresh_rev = function()
  local text = read_all(REV) or ""
  if rev_state.text == text then return end
  rev_state.text = text
  rank_cache.ready = false
  extra_cache.ready = false
  vocab_cache.ready = false
  rules_cache.ready = false
  rules_cache.memo = {}
  pref_cache.key = nil
  pref_cache.hit = nil
  last_sig = nil   -- 下一鍵重新寫 candidates.tsv（工作台才看得到新狀態）
end

-- 「排序生效」開關（1.4.4）：本方案 config.ini 的 enabled（預設開啟）＋
-- 本方案 rank.tsv 存在。工作台關閉時把 rank.tsv 改名成 rank.tsv.off，
-- 所以這裡看不到檔就是關閉。關閉＝完全旁路：不注入 extra、不改序、不加註記。
-- 1.4.6：明確 enabled=1 即生效（即使檔尚未建立）；未設定時才看 rank 檔是否存在。
local function rank_active()
  refresh_rev()
  local cfg = load_config()
  if cfg.enabled == false then return false end
  if cfg.enabled == true then return true end
  return file_size(RANK) ~= nil
end

-- 1.4.18：工作台「在場」標記（reorder\gui_alive.tsv）。工作台啟動即建立、每 3 秒刷新、
-- 退出時刪除；內容 pid＋時間戳。lua 每鍵只 stat 一次；超過 60 秒沒刷新視為不在，
-- 避免工作台崩潰後殘留標記導致一直注入。同秒內重用結果，不重複開檔。
local alive_state = { sec = -1, hit = false }

local function gui_present()
  init_paths()
  local now = os.time()
  if alive_state.sec == now then return alive_state.hit end
  local hit = false
  local f = io.open(ALIVE, "r")
  if f then
    local ok, txt = pcall(function() return f:read("*a") end)
    pcall(function() f:close() end)
    if ok and type(txt) == "string" then
      local ts = tonumber(txt:match("ts%s+(%d+)")) or tonumber(txt:match("^(%d+)"))
      if ts and now >= ts and (now - ts) <= 60 then hit = true end
    end
  end
  alive_state.sec, alive_state.hit = now, hit
  return hit
end

-- 1.4.18：注入／捕捉的唯一判據＝「工作台在場 or rank.tsv 真的存在」。
-- 兩個都假才全停（不注入、不貼標記、不寫 candidates.tsv／status.tsv 心跳）。
-- 注意不能寫成 rank_active()：第 4 種組合（工作台不在、exitonclose=0、rank 仍在）
-- 要繼續注入與排序，第 2 種（工作台在、rank 收成 .off）要能注入與捕捉。
local function helper_on()
  return gui_present() or (file_size(RANK) ~= nil)
end

-- DP 暫存（模組層級重用；dead 以世代號標記，避免每次重建表）
local dp_state = {
  s = nil, code = nil, starts = nil, lens = nil, n = 0, ls = 0,
  gen = 0, take = {}, dead = {},
}
local sbyte = string.byte

local function dp_dfs(k, pos)
  local st = dp_state
  if k > st.n then return pos > st.ls end
  local dk = k * 1000 + pos
  if st.dead[dk] == st.gen then return false end
  local remain = st.ls - pos + 1
  local cap = remain - (st.n - k)
  if cap < 1 then st.dead[dk] = st.gen; return false end
  local maxlen = st.lens[k]
  if maxlen > cap then maxlen = cap end
  local cpos = st.starts[k]
  for len = 1, maxlen do
    local same = true
    for i = 0, len - 1 do
      if sbyte(st.code, cpos + i) ~= sbyte(st.s, pos + i) then
        same = false
        break
      end
    end
    if same and dp_dfs(k + 1, pos + len) then
      st.take[k] = len
      return true
    end
  end
  st.dead[dk] = st.gen
  return false
end

-- 回傳 split 字串（sz|si|sq|lu）、|S|；不合則 nil
local function dp_match(e, s, ls)
  local st = dp_state
  st.gen = st.gen + 1
  st.s, st.code, st.starts, st.lens = s, e.code, e.starts, e.lens
  st.n, st.ls = #e.lens, ls
  if not dp_dfs(1, 1) then return nil end
  local parts, p = {}, 1
  for k = 1, st.n do
    local l = st.take[k]
    parts[k] = s:sub(p, p + l - 1)
    p = p + l
  end
  return table.concat(parts, "|"), ls
end

-- 掃一個索引桶，更新最佳命中（同分時取碼序較前者）；命中碼底下的同音詞全部保留
local function scan_bucket(b, s, ls, best, best_q, best_ord)
  for i = 1, #b do
    local e = b[i]
    if e.total >= ls then
      local split, used = dp_match(e, s, ls)
      if split then
        local q = 4.0 + 0.9 * (used / e.total)
        if q > 4.9 then q = 4.9 end
        if (not best) or q > best_q + 1e-9
          or (q > best_q - 1e-9 and e.ord < best_ord) then
          best = { words = e.words, word = e.words[1], split = split, q = q }
          best_q, best_ord = q, e.ord
        end
      end
    end
  end
  return best, best_q, best_ord
end

-- 1.3.15：開關在 rules.yaml 的 prefix_match（預設 on）；off 只關 DP 這條路徑，
-- formula／fuzz 固定簡碼與連寫碼照舊。
local function prefix_enabled()
  load_rules()
  return rules_cache.prefix_on ~= false
end

-- 依連續輸入找一個前綴分段命中；回傳 words（同音詞清單）, split, q
local function prefix_match(input)
  if type(input) ~= "string" or input == "" then return nil end
  if not prefix_enabled() then return nil end
  local s = input:gsub("`", ""):gsub("%s+", "")
  if s == "" then return nil end
  local ck = tostring(extra_cache.gen) .. "\x1f" .. s
  if pref_cache.key == ck then
    local h = pref_cache.hit
    if h then return h.words, h.split, h.q end
    return nil
  end
  load_extra()
  local idx = extra_cache.idx
  local ls = #s
  local best, best_q, best_ord = nil, nil, nil
  -- 段數 ≤ 輸入長度（每段至少 1 碼）：L=1 時 n≥2 全數剪掉。
  -- 單段詞（n=1）走精確碼路徑，不進索引，故從 n=2 起掃。
  for n = 2, ls do
    local g = idx and idx[n]
    if g then
      local b = g[s:sub(1, 1)]
      if b then best, best_q, best_ord = scan_bucket(b, s, ls, best, best_q, best_ord) end
      if ls >= 2 then
        local b2 = g[s:sub(1, 2)]
        if b2 and b2 ~= b then
          best, best_q, best_ord = scan_bucket(b2, s, ls, best, best_q, best_ord)
        end
      end
    end
  end
  pref_cache.key = ck
  pref_cache.hit = best
  if best then return best.words, best.split, best.q end
  return nil
end

-- ===== 1.4.15：多截碼整詞合成 =====
-- 問題：extra.tsv 的注入是「整串碼 → 整詞」的固定候選，不參與引擎組詞；
-- 詞庫有「網頁」、extra 有 bjl＝「版」時，整串碼拼不出「網頁版」。
-- 做法：把本次輸入碼切成若干段，每段分別在「詞庫前段候選／extra.tsv／vocab.txt」
-- 查到文本，首尾相接成整詞，最後只追加到候選列表尾部（不重排、不擠掉原生候選）。
-- 性能：只做 hash 查表＋小規模 DP；超過上限直接放棄，失敗不寫任何檔案／日誌。
local COMPOSE_MIN_LEN     = 4    -- 輸入碼短於此不嘗試
local COMPOSE_MIN_SEG     = 2    -- 每段最少碼長（避免單字母亂配）
local COMPOSE_MAX_SEG_LEN = 16   -- 每段最長碼長
local COMPOSE_MAX_SEGS    = 6    -- 最多切幾段
local COMPOSE_MAX_OUT     = 1    -- 合成位置：單次最多產出 1 條合成候選
local COMPOSE_MAX_STEPS   = 320  -- 單次最多查表次數（DP 與枚舉共用）

local compose_cache = { gen = nil, extra = nil }

local function compose_enabled()
  pcall(load_rules)
  return rules_cache.compose_on ~= false
end

-- 合成位置：合成候選的分數（沿用 rank 的 -5..+5 體系，並經 norm_score 歸一化）。
-- 段數越多＝拼得越散，分數略低；碼越長略加一點，但絕不越過原生 4.9 的主碼候選。
-- 2 段 4.80、3 段 4.60、4 段 4.40……下限 3.0，避免長串合成被壓到看不見。
local function compose_score(segs, ncode)
  local s = 4.8 - 0.2 * (segs - 2) - 0.01 * math.max(0, ncode - 6)
  if s < 3.0 then s = 3.0 end
  return norm_score(s)
end

-- extra.tsv：code（去空白、小寫）→ 第一筆詞；extra 有增量（gen 變）時重建一次
local function compose_extra_map()
  if compose_cache.gen == extra_cache.gen and compose_cache.extra then
    return compose_cache.extra
  end
  local m = {}
  local list = extra_cache.list or {}
  for code, L in pairs(list) do
    local k = code:lower():gsub("%s+", "")
    if k ~= "" and m[k] == nil and L[1] and type(L[1].word) == "string" and L[1].word ~= "" then
      m[k] = L[1].word
    end
  end
  compose_cache.gen, compose_cache.extra = extra_cache.gen, m
  return m
end

-- 詞庫候選：取「消耗前段」的候選（end 可到整串尾），碼用去分隔符小寫比對；
-- end 不可用時退回註釋開頭的碼串（同樣要求是整串的前段）。
local function compose_lex_map(cands, raw, flat)
  local m = {}
  local n = #raw
  for i = 1, #cands do
    local c = cands[i]
    local t = c.text
    if type(t) == "string" and t ~= "" then
      local e = c._end
      if type(e) ~= "number" then e = c["end"] end
      -- 1.4.20：; 是拼寫碼（屏=p;），只剝空格／'／`；整串前綴鍵仍保留 ;
      local pre = nil
      if type(e) == "number" and e > 0 and e <= n then
        pre = raw:sub(1, e):lower():gsub("[%s`']+", "")
        local k = pre
        if k ~= "" and k ~= flat and m[k] == nil then m[k] = t end
      end
      -- 1.4.20：候選註釋碼當「局部碼」索引（第二段以後的詞也要查得到）。
      -- 只取前導碼字元；必須能對齊到候選自己消耗到的位置（_end 的前綴結尾），
      -- 沒 _end 時退而要求是全串結尾，避免把碼套到不相干的位置。
      local run = clean_text(c.comment or ""):match("^([%a;%s`']+)")
      if run then
        local k = run:gsub("[%s`']+", ""):lower()
        if k ~= "" and k ~= flat and #k <= #flat and m[k] == nil then
          -- 對齊：候選消耗前綴的結尾，或整串結尾（_end 偶有偏差時仍能認最後一段）
          local aligned = (flat:sub(-#k) == k)
          if not aligned and pre and #k <= #pre then
            aligned = (pre:sub(-#k) == k)
          end
          if aligned then m[k] = t end
        end
      end
    end
  end
  return m
end

-- 1.4.19：權威分段。空格／'／` 是使用者明示的切點，優先於自動切分。
-- 1.4.20：; 是合法拼寫碼（屏=p;），不是切點；每段可含 ;，且必須是碼字元。
local function compose_parts(raw)
  local parts = {}
  for p in raw:gmatch("[^%s'`]+") do
    if not p:match("^[%a;]+$") then return nil end
    parts[#parts + 1] = p:lower()
  end
  return parts
end

-- 1.4.19：引擎已經把輸入切成多個 segment 時不跨段合成（各自維持現狀）。
-- 回傳 nil＝拿不到資訊（例如離線測試）或只有 1 段。
local function segment_count(env)
  local n = nil
  pcall(function()
    local c = env.engine.context.composition
    if not c then return end
    local s = c:toSegmentation()
    if not s then return end
    local list = s:get_segments()
    if type(list) == "table" then
      n = #list
      if n == 0 then
        local ok, sz = pcall(function() return list:size() end)
        if ok and type(sz) == "number" then n = sz end
      end
    else
      local ok, sz = pcall(function() return list:size() end)
      if ok and type(sz) == "number" then n = sz end
    end
  end)
  if n and n < 1 then n = nil end
  return n
end

-- 回傳 (合成候選, 段數, 碼長)；任何一步不成立就回 nil。
-- 1.4.19：含分隔符時走「權威分段」直查，不做 DP、也不回退自動切分。
local function compose_tail(cands, raw, vw, segcount)
  if not compose_enabled() then return nil end
  if segcount and segcount > 1 then return nil end   -- 引擎已多 segment：不跨段
  if type(raw) ~= "string" or raw == "" then return nil end
  local parts = compose_parts(raw)
  if not parts or #parts == 0 then return nil end
  local flat = raw:lower():gsub("[%s'`]+", "")
  if #flat < COMPOSE_MIN_LEN or #flat > 48 then return nil end
  load_extra()
  if not extra_cache.list then return nil end
  local emap = compose_extra_map()
  local vby = (vw and vw.bycode) or nil
  local lex = compose_lex_map(cands, raw, flat)
  local function text_of(seg)
    return emap[seg] or (vby and vby[seg]) or lex[seg]
  end

  -- 權威分段：逐段直查；任何一段查不到就放棄（避免用自動切分拼出使用者沒要的詞）
  if #parts >= 2 then
    if #parts > COMPOSE_MAX_SEGS then return nil end
    local acc, codes = {}, {}
    for i = 1, #parts do
      local p = parts[i]
      if #p > COMPOSE_MAX_SEG_LEN then return nil end
      local w = text_of(p)
      if not w then return nil end
      acc[#acc + 1] = w
      codes[#codes + 1] = p
    end
    local word = table.concat(acc)
    if word == "" then return nil end
    local cand = nil
    local ok = pcall(function()
      cand = Candidate("reorder_extra", 0, #raw, word, table.concat(codes, "|"))
    end)
    if not (ok and cand) then return nil end
    return cand, #parts, #flat
  end

  local code = parts[1]
  local N = #code
  if N < COMPOSE_MIN_LEN or N > 48 then return nil end
  local steps = 0
  local memo = {}
  memo[N + 1] = 0
  -- best(i)：從第 i 碼切到結尾的最少段數（false／nil＝切不出）
  local function best(i)
    local m = memo[i]
    if m ~= nil then return m end
    m = false
    local last = i + COMPOSE_MAX_SEG_LEN - 1
    if last > N then last = N end
    for j = i + COMPOSE_MIN_SEG - 1, last do
      steps = steps + 1
      if steps > COMPOSE_MAX_STEPS then break end
      if text_of(code:sub(i, j)) then
        local r = best(j + 1)
        if r and r ~= false and (m == false or 1 + r < m) then m = 1 + r end
      end
    end
    memo[i] = m
    return m
  end
  local need = best(1)
  if not need or need < 2 or need > COMPOSE_MAX_SEGS then return nil end
  -- 枚舉前 COMPOSE_MAX_OUT 種切法（先長後短，段數與 best 一致）
  local out = {}
  local emitted = {}
  local function walk(i, n, acc, codes)
    if i > N then
      local w = table.concat(acc)
      -- 1.4.19：已存在的詞也照樣回傳，讓 filter 判定「提位」而不是「新增」
      if w ~= "" and not emitted[w] then
        emitted[w] = true
        out[#out + 1] = { word = w, split = table.concat(codes, "|") }
      end
      return
    end
    local last = i + COMPOSE_MAX_SEG_LEN - 1
    if last > N then last = N end
    for j = last, i + COMPOSE_MIN_SEG - 1, -1 do
      steps = steps + 1
      if steps > COMPOSE_MAX_STEPS or #out >= COMPOSE_MAX_OUT then return end
      local seg = code:sub(i, j)
      local w = text_of(seg)
      if w then
        local r = memo[j + 1]
        if r and r ~= false and 1 + r == n then
          acc[#acc + 1] = w
          codes[#codes + 1] = seg
          walk(j + 1, r, acc, codes)
          acc[#acc] = nil
          codes[#codes] = nil
        end
      end
    end
  end
  walk(1, need, {}, {})
  if #out == 0 then return nil end
  local res = {}
  for i = 1, #out do
    local o = out[i]
    local cand = nil
    local ok = pcall(function()
      cand = Candidate("reorder_extra", 0, #raw, o.word, o.split)
    end)
    if ok and cand then res[#res + 1] = cand end
  end
  if #res == 0 then return nil end
  -- 合成位置：回傳單條合成候選與它的段數／碼長，供 filter 依分數插入
  return res[1], need, #flat
end

-- 1.4.19：最近一次合成結果的詞與整串碼；上屏時用它判定要不要落庫。
-- 1.4.21：已存在於候選流的詞也一樣要記（使用者選的就是合成候選，不能因去重而漏記）。
local synth_state = { word = "", code = "", ts = 0 }

-- 1.4.22：跨段上屏兜底記帳的快取。filter 每鍵都跑，這裡記下「當前整串碼＋分段＋方案」；
-- 上屏時引擎已把多 segment 切開、不會產生合成候選，就用這份快取把整串碼寫進 userdb。
local commit_ctx = { input = "", flat = "", segs = nil, sid = "", ts = 0 }

-- 1.4.21：匹配詞判定用的「歷史造過的詞」集合（newword／newseg／edit／addword）。
-- 只快取詞集合，檔案大小沒變就不重解析；歷史檔很小，重解析成本可忽略。
local hist_cache = { text_sig = nil, words = {} }
local function load_hist_words()
  init_paths()
  local text, hit = cached_text(HISTORY, hist_cache)
  if hit then return hist_cache.words end
  local words = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    local f = {}
    for col in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = col end
    local act = f[2] or ""
    if act == "newword" or act == "newseg" or act == "edit" or act == "addword" then
      local w = clean_text(f[3] or "")
      if w ~= "" then words[w] = true end
    end
  end
  hist_cache.words = words
  return words
end

-- 1.4.22：把整串碼按本工具管理的碼切段（每段 ≥2 碼，取段數最少者）。
-- 命中來源與「匹配詞」判定一致：extra／vocab／rank。切不出回 nil。
-- （實測本機 librime-lua 的 preedit.text 不含分段空白，例 ccsmgowlwb → "ccsmgowlwb"，
--   所以跨段記帳的分段只能由碼本身切，不能靠 preedit。）
local function split_managed(flat)
  flat = (flat or ""):lower():gsub("[%s'`]+", "")
  local N = #flat
  if N < 2 or N > 64 then return nil end
  pcall(load_extra)
  local vw2 = nil
  pcall(function() vw2 = load_vocab_words() end)
  local emap = compose_extra_map()
  local vby = (type(vw2) == "table") and vw2.bycode or nil
  local rcodes = rank_cache.codes or {}
  local function seg_ok(s)
    return (emap[s] ~= nil) or (vby and vby[s] ~= nil) or (rcodes[s] ~= nil)
  end
  local memo = {}
  local function walk(i)
    if i > N then return {} end
    if memo[i] ~= nil then return memo[i] end
    local best = false
    local last = i + 15
    if last > N then last = N end
    for j = i + 1, last do
      local s = flat:sub(i, j)
      if seg_ok(s) then
        local r = walk(j + 1)
        if r and (best == false or #r + 1 < #best) then
          local t = { s }
          for k = 1, #r do t[#t + 1] = r[k] end
          best = t
        end
      end
    end
    memo[i] = best
    return best
  end
  return walk(1)
end

-- 1.4.22：跨段上屏兜底記帳。
-- 條件：commitrecord=on（預設）；快取新鮮（30 秒）；2 ≤ 段數 ≤ 4；上屏字數 2..8；
--       最後一段是本工具管理的碼（extra／vocab／rank）。
-- 任何一條不滿足都直接跳過，只寫一行 userdb.log；失敗也靜默，絕不影響上屏。
local function record_cross_commit(env, word)
  local cfg = load_config()
  if cfg.commitrecord ~= "on" then return false end
  local word2 = clean_text(word or "")
  local cc = commit_ctx
  local dt = os.time() - (cc.ts or 0)
  if cc.ts == 0 or cc.input == "" or dt > 30 then
    pcall(udlog, { "commitx", "skip", "stale", word2, "dt=" .. tostring(dt) })
    return false
  end
  local segs = cc.segs or {}
  local n = #segs
  if n < 2 or n > 4 then
    pcall(udlog, { "commitx", "skip", "segs=" .. tostring(n), cc.input, word2 })
    return false
  end
  local wlen = utf8_chars(word2) or 0
  if wlen < 2 or wlen > 8 then
    pcall(udlog, { "commitx", "skip", "len=" .. tostring(wlen), cc.input, word2 })
    return false
  end
  init_paths()
  -- 注意：commit 回呼期間不要碰 rime 物件（use_profile／schema 之類），
  -- filter 每鍵已切好方案；這裡只做純檔案 IO，避免原生層 AV。
  pcall(load_extra)
  local vw2 = nil
  pcall(function() vw2 = load_vocab_words() end)
  local emap = compose_extra_map()
  local vby = (type(vw2) == "table") and vw2.bycode or nil
  local rk = rank_cache.codes or {}
  local last = tostring(segs[n] or ""):lower():gsub("[`%s]+", "")
  local hit = (emap[last] ~= nil) or (vby and vby[last] ~= nil) or (rk[last] ~= nil)
  if last == "" or not hit then
    pcall(udlog, { "commitx", "skip", "last", cc.input, word2, "seg=" .. tostring(last) })
    return false
  end
  local code = table.concat(segs, " ")
  cc.ts = 0   -- 同一輪輸入只記一次
  local ok = mirror_commit(env, code, word2)
  pcall(udlog, { "commitx", ok and "ok" or "fail", code, word2,
      "segs=" .. tostring(n) })
  return ok
end

local function filter_compute(cands, env)
  init_paths()
  calls = calls + 1
  pcall(userdb_tick, env)   -- 1.4.19：rebuild／對帳（自帶節流）

  local count = #cands

  -- 本次按鍵的碼別：方案 + 目前輸入碼。rank 只在完全相同碼別時才套用。
  local inp = ""
  pcall(function() inp = tostring(env.engine.context.input) end)

  -- 1.3.24：記錄整串輸入的引擎分段（此時 preedit 還沒有已確認漢字）。
  -- 逐字選字後 preedit 只剩「已確認漢字＋剩餘碼」，整串分段就取不回來；
  -- 造詞要靠它把已確認字與當前選字拼回完整詞、還原完整分段碼。
  if comp and inp ~= "" then
    local segs = nil
    pcall(function()
      local pd = env.engine.context:get_preedit()
      local txt = (type(pd) == "table" and pd.text) or nil
      if type(txt) == "string" and txt ~= "" then
        local s2 = preedit_segments(txt)
        if #s2 >= 1 and
           table.concat(s2, ""):lower() == inp:gsub("[`%s]+", ""):lower() then
          comp.segs = s2
          segs = s2
        end
      end
    end)
    -- 1.4.22：跨段記帳用的分段。使用者自打的分隔符最權威；其次 preedit 若有真分段；
    -- 都沒有就按本工具管理的碼切（本機 preedit.text 不含分段空白，實測）。
    -- 這幾行必須在 pcall 之外，否則某次取 preedit 失敗會連快取都寫不進去。
    local parts = {}
    for part in inp:gmatch("[^%s`']+") do parts[#parts + 1] = part end
    local csegs
    if #parts > 1 then
      csegs = parts
    elseif segs and #segs > 1 then
      csegs = segs
    else
      csegs = split_managed(inp) or parts
    end
    commit_ctx.input = inp
    commit_ctx.flat = inp:lower():gsub("[%s'`]+", "")
    commit_ctx.segs = csegs
    commit_ctx.sid = schema_id(env)
    commit_ctx.ts = os.time()
  elseif inp == "" then
    commit_ctx.ts = 0   -- 輸入已清空：舊快取作廢，避免下一次上屏誤記
  end

  -- 1.3.22：把「觀察」與「旁路」拆開。
  --   觀察（寫 candidates.tsv 給工作台）任何時候都做，與排序開關無關；
  --   旁路只針對「注入候選、改順序、加註記」，關閉時候選按引擎原序原樣輸出。
  local active = rank_active()

  -- 1.4.18：工作台不在、rank.tsv 也被收成 .off → 全停：一個字都不動，也不寫任何檔
  -- （不注入、不貼標記、不寫 candidates.tsv、不寫 status.tsv 心跳）。
  if not helper_on() then return cands end

  -- 空候選也要落一次快照，否則工作台會停在上一批（1.3.21 的直接 return 是缺陷）。
  if count == 0 then
    local sid = schema_id(env)
    local sig = "empty\x1e" .. clean_text(sid) .. "\x1e" .. clean_text(inp)
        .. "\x1e" .. (active and "1" or "0")
    if sig ~= last_sig then
      last_sig = sig
      writes_cand = writes_cand + 1
      local clines = {
        "#v1",
        "ts\t" .. os.time(),
        "schema\t" .. clean_text(sid),
        "input\t" .. clean_text(inp),
        "count\t0",
        "ranked\t0",
        "moved\t0",
      }
      if not active then clines[#clines + 1] = "off\t1" end
      pcall(write_all, CANDIDATES, table.concat(clines, "\n") .. "\n")
      pcall(write_status, env, inp, 0, 0, 0)
    elseif os.time() - last_status_sec >= 2 then
      -- 心跳最多每 2 秒一次，避免空候选时每个按键都写档
      pcall(write_status, env, inp, 0, 0, 0)
    end
    return cands
  end

  -- 1.3.22：排序關閉＝只旁路「注入／調序／註記」，不動觀察。
  -- 候選順序、文字、原註記一律保持引擎原樣（等同未安裝本外掛）。
  if not active then
    -- 1.4.1：排序關閉只旁路「注入／調序／註記」，不該連「同文去重」一起關掉。
    -- 引擎在 custom_phrase 置頂詞與詞典同碼同文時會各出一筆（例：zsmf 的兩個「中文」），
    -- 去重與排序無關，這裡保留第一筆（通常是 📌 那個）。
    local seen_text, uniq = {}, {}
    for _, c in ipairs(cands) do
      local t = c.text or ""
      if t == "" or not seen_text[t] then
        seen_text[t] = true
        uniq[#uniq + 1] = c
      end
    end
    if #uniq ~= #cands then
      cands = uniq
      count = #cands
    end
    local scores, ords, poss, hasposs = {}, {}, {}, {}
    local sigparts = { "off", clean_text(inp), clean_text(schema_id(env)), tostring(count) }
    for i, c in ipairs(cands) do
      scores[i] = 0
      ords[i] = i
      hasposs[i] = false
      sigparts[#sigparts + 1] = clean_text(c.text)
      sigparts[#sigparts + 1] = clean_text(c.comment)
    end
    local ok, sig = pcall(function() return simple_hash(table.concat(sigparts, "\x1e")) end)
    if ok and sig ~= last_sig then
      last_sig = sig
      writes_cand = writes_cand + 1
      pcall(dump_candidates, env, inp, cands, scores, ords, poss, hasposs, 0, 0, count, true)
    end
    local now = os.time()
    if inp == "" or now - last_status_sec >= 2 then
      pcall(write_status, env, inp, 0, 0, count)
    end
    return cands
  end

  local scope = schema_id(env) .. ":" .. inp

  local rank = load_rank()
  load_extra()  -- 1.3.6：取得簡碼品質（extra_cache.q）
  local extra_q = extra_cache.q

  -- 1.3.11：本次輸入對應的 extra 詞。比對順序與 translator 完全相同
  -- （原字串 → 小寫 → 正規化 → 正規化後小寫），兩種寫法都容許。
  -- 1.3.24：同一個碼可能有多個同音詞，命中集合改為「逐詞」。
  local hit_words = {}   -- 詞 -> 本次命中的品質
  local hit_code = nil
  local hit_q = nil
  local L, key0 = extra_words(inp)
  if L then
    hit_code = key0
    hit_q = extra_q[key0] or 4.9
    for i = 1, #L do hit_words[L[i].word] = hit_q end
  else
    -- 1.3.14：精確碼沒中時，改用前綴分段匹配（品質依命中比例；註記顯示切法）
    local ws, split, q = prefix_match(inp)
    if ws then
      hit_code, hit_q = split, q
      for i = 1, #ws do hit_words[ws[i]] = q end
    end
  end

  local scores = {}
  local cpos, chas = {}, {}   -- 1.3.20：位置序（B 方案）
  local rank_pos = rank_cache.pos or {}
  local ranked = 0
  for i, c in ipairs(cands) do
    local txt = c.text or ""
    local s = rank[scope .. "\x1f" .. txt]
    -- 新詞沒有 rank 條目時用該碼的品質（主碼 4.9、簡碼較低）。
    -- 1.3.11：原本只認 type == reorder_extra，導致「詞已在詞庫」時注入候選被去重、
    -- 留下的原生候選分數仍是 0，簡碼排序等於沒生效。改為「同文命中」一律套品質。
    if not s and hit_words[txt] then
      s = hit_words[txt]
    end
    if not s and c.type == "reorder_extra" then
      s = 4.9
    end
    scores[i] = s or 0
    if s then ranked = ranked + 1 end
    local pv = rank_pos[scope .. "\x1f" .. txt]
    if pv then cpos[i] = pv; chas[i] = true end
  end

  -- 1.3.20（B 方案）：先算「不含位置序」的基準序（分數→引擎原序），
  -- 再把每列的座標定為「顯式位置序」或「基準序 × 1000」；±5 硬鎖仍分組最高優先。
  local function cgroup(s)
    if s >= 4.99 then return -1 end
    if s <= -4.99 then return 1 end
    return 0
  end
  local idx = {}
  for i = 1, count do idx[i] = i end
  table.sort(idx, function(a, b)
    if scores[a] ~= scores[b] then
      return scores[a] > scores[b]
    end
    return a < b -- 同分維持引擎原序（穩定）
  end)
  local base = {}
  local gl = { [-1] = 0, [0] = 0, [1] = 0 }
  for _, oi in ipairs(idx) do
    local g = cgroup(scores[oi])
    base[oi] = gl[g]
    gl[g] = gl[g] + 1
  end
  local coord = {}
  for oi = 1, count do
    coord[oi] = chas[oi] and cpos[oi] or (base[oi] * 1000)
  end
  -- 1.4.10：輸入覆蓋率。候選註釋開頭若是一串碼（可多個並列拼寫，如「li lk lz ni」），
  -- 逐個看它是不是輸入的前段；只要有一個只是前段（#code < #inp 且逐字相符），
  -- 覆蓋率＝其中最長者／#inp。對不上（其他編碼慣例、非碼註釋）一律視為完整覆蓋（1）。
  -- 1.4.21：; 是方案拼寫碼（屏=p;、糾正=gb z;），不可剝除。舊版把它刪掉，
  -- 使註釋「gbz;」只剩 3/4、註釋「gb z;」只剩 1/2，被完整覆蓋的原生詞壓到尾部。
  -- 這裡同時比對「去空白整串」與「單一 token」兩種寫法，取較高者。
  local cov = {}
  local cinp = inp:gsub("[`%s]+", ""):lower()
  for i = 1, count do
    local ratio = 1
    if cinp ~= "" then
      local raw = clean_text(cands[i].comment or "")
      local run = raw:match("^([%a%s;`']+)")
      if run then
        local best = nil
        local joined = run:gsub("[%s`']+", ""):lower()
        if joined ~= "" and cinp:sub(1, #joined) == joined then
          best = math.min(#joined, #cinp) / #cinp
        end
        for tok in run:gmatch("[%a;]+") do
          tok = tok:lower()
          if tok ~= "" and #tok <= #cinp and cinp:sub(1, #tok) == tok then
            local r = #tok / #cinp
            if not best or r > best then best = r end
          end
        end
        if best then ratio = best end
      end
    end
    cov[i] = ratio
  end
  table.sort(idx, function(a, b)
    local ga, gb = cgroup(scores[a]), cgroup(scores[b])
    if ga ~= gb then return ga < gb end
    -- 1.4.10：覆蓋整串的候選優先於只覆蓋前段的候選；同覆蓋率內仍按分數／位置序（穩定）
    if cov[a] ~= cov[b] then return cov[a] > cov[b] end
    if coord[a] ~= coord[b] then return coord[a] < coord[b] end
    return a < b
  end)

  local moved = 0
  local ordered = {}
  local ordered_scores = {}
  local ordered_ord = {}
  local ordered_pos = {}
  local ordered_haspos = {}
  for i, oi in ipairs(idx) do
    ordered[i] = cands[oi]
    ordered_scores[i] = scores[oi]
    ordered_ord[i] = oi
    ordered_pos[i] = cpos[oi]
    ordered_haspos[i] = chas[oi]
    if oi ~= i then moved = moved + 1 end
  end

  -- 同文去重（排序後、yield 前）：只比 text。
  -- 1.4.10：若同文既有候選只覆蓋輸入前段、而我們注入的那筆覆蓋整串，改為保留我們這筆
  -- （分數／註釋／標記來自 extra）；有 📌（custom_phrase）時仍讓給 📌。
  -- 其餘情況維持舊行為：保留既有那筆，記下命中碼給註記用。
  local annot = {}
  local has_real, has_ours, has_cp, prefix_only = {}, {}, {}, {}
  for i, c in ipairs(ordered) do
    local t = c.text or ""
    if c.type == "reorder_extra" then
      has_ours[t] = true
    else
      has_real[t] = true
      if c.type == "custom_phrase" or clean_text(c.comment):find("📌", 1, true) then
        has_cp[t] = true
      end
      if (cov[ordered_ord[i]] or 1) < 1 then prefix_only[t] = true end
    end
  end
  local first = {}
  local uo, us, uord, upos, uhas = {}, {}, {}, {}, {}
  local function push(i, c)
    first[c.text or ""] = true
    uo[#uo + 1] = c
    us[#us + 1] = ordered_scores[i]
    -- 1.4.1：原本寫成 uord[#uord]（等於寫到索引 0），三欄全部落空，
    -- candidates.tsv 的 ord／pos 永遠是空的：工作台每次重載都丟掉拖曳座標，
    -- 連續往首位拖會每次算出同一個 -500，看起來像沒拖動。
    uord[#uord + 1] = ordered_ord[i] or i
    upos[#upos + 1] = ordered_pos[i] or 0
    uhas[#uhas + 1] = ordered_haspos[i] and true or false
  end
  for i, c in ipairs(ordered) do
    local t = c.text or ""
    if c.type == "reorder_extra" then
      if has_real[t] and (has_cp[t] or not prefix_only[t]) then
        annot[t] = hit_code or true   -- 讓給既有那筆（📌 或完整覆蓋的詞典候選）
      elseif not first[t] then
        push(i, c)
      end
    else
      local replaced = has_ours[t] and prefix_only[t] and not has_cp[t]
      if not replaced and not first[t] then push(i, c) end
    end
  end
  ordered = uo
  ordered_scores = us
  count = #ordered

  -- 1.3.24 候選窗標記：只動「本工具確實在管」的詞，其餘候選的原註釋一字不改。
  --   判據：詞在 rank.tsv／extra.tsv／vocab.txt 有沒有本工具的記錄（不看方案能否解析）。
  --   📍＝rank ±5 硬鎖（逐詞）／🎛＝人工調頻（逐詞）／🆕＝本工具注入的新詞
  --   別人的 📌（custom_phrase／其他 lua）保留：不再抹除，也不再整條重建註釋。
  local cfg = load_config()
  local marks = (cfg.style == "symbol")
      and { fixed = "◆", tuned = "▣", new = "★" }
      or  { fixed = "📍", tuned = "🎛", new = "🆕" }
  local lockk = rank_cache.lock_keys or {}
  local userk = rank_cache.user_keys or {}
  local rank = rank_cache.data or {}
  local vfull, vany = {}, {}
  local okv, vw = pcall(load_vocab_words)
  if okv and type(vw) == "table" then
    vfull = vw.full or {}
    vany = vw.any or {}
  end
  -- 當前輸入碼的所有等價寫法（原字串／小寫／正規化／正規化小寫，再全部去空白）
  local ckeys, cseen = {}, {}
  for _, v in ipairs({ inp, inp:lower(), normalize_code(inp), normalize_code(inp):lower() }) do
    local ck = code_key(v)
    if ck ~= "" and not cseen[ck] then cseen[ck] = true; ckeys[#ckeys + 1] = ck end
  end
  local sid = schema_id(env)
  local function scope_hit(t)
    if rank[scope .. "\x1f" .. t] ~= nil then return "rank" end
    for j = 1, #ckeys do
      local ck = ckeys[j]
      if vany[ck .. "\x1f" .. t] or vfull[sid .. "\x1f" .. ck .. "\x1f" .. t] then return "vocab" end
    end
    return nil
  end
  -- 1.4.17：標記全跟排序走。1.4.16 起退出只把 rank.tsv 收成 .off、enabled 仍是 1（意向），
  -- 因此 rank_active() 仍為真、注入照跑；但此時沒有 rank 資料，若照舊判定，注入詞會退化成 🆕。
  -- 這裡改用「rank.tsv 是否真的存在」作為標記閘門：排序被解除時一個 📍／🎛／🆕 都不貼。
  local mark_live = (file_size(RANK) ~= nil)
  for i, c in ipairs(ordered) do
    local t = c.text or ""
    -- 1.3.24：判據必須帶「方案:碼」。只有本工具在「當前這個方案、這個碼」確實有記錄
    -- （rank 的 方案:碼、extra 本次命中的碼、vocab 的 方案:碼），才碰這個候選的註釋；
    -- 其餘候選（引擎原生 custom_phrase 等）原註釋一字不改，別人的 📌 也原樣保留。
    local hit = nil
    if mark_live then
      if c.type == "reorder_extra" or hit_words[t] ~= nil then
        hit = "extra"
      else
        hit = scope_hit(t)
      end
    end
    if hit then
      local mk = nil
      if lockk[scope .. "\x1f" .. t] then
        mk = marks.fixed
      elseif userk[scope .. "\x1f" .. t] then
        mk = marks.tuned
      else
        mk = marks.new
      end
      if mk then
        -- 只在原註釋後面追加本工具標記；已有就不重複疊加，他人的 📌 等原樣保留
        local raw = clean_text(c.comment)
        if raw:find(mk, 1, true) == nil then
          local txt = (raw ~= "") and (raw .. " " .. mk) or mk
          pcall(function() c.comment = txt end)
        end
      end
    end
  end

  -- 1.4.15：多截碼整詞合成。1.4.21 起位置改按「匹配詞」判定：
  -- 匹配詞＝本工具自己管理的記錄（本次 extra 命中／rank・vocab 當前碼／歷史造過的詞），
  -- 不含 rime 原生詞庫候選。當前候選沒有匹配詞 → 合成詞直接第 1；
  -- 有匹配詞 → 不搶第一，按分數落在第 2 或第 3（同文已存在時把那條移到同一位置）。
  local hist_words = load_hist_words()
  local function managed_word(t)
    if not t or t == "" then return false end
    if hit_words[t] ~= nil then return true end
    if hist_words[t] then return true end
    return scope_hit(t) ~= nil
  end
  local function has_other_managed(skip)
    for i = 1, #ordered do
      local t = ordered[i].text or ""
      if t ~= skip and managed_word(t) then return true end
    end
    return false
  end
  -- 1.4.22：整串碼按段切分，只要切出的每一段都是本工具管理的碼（extra／vocab／rank，
  -- 每段長度 ≥2，避免單字母碼把所有輸入都判成有匹配詞），就算「有匹配詞」。
  -- 這樣 stp;（st＋p;）不會再被當成「無匹配詞」而搶第 1。
  local function whole_code_managed()
    local flat = (inp or ""):lower():gsub("[%s'`]+", "")
    local N = #flat
    if N < 4 or N > 64 then return false end
    local emap = compose_extra_map()
    local vby = (okv and type(vw) == "table") and vw.bycode or nil
    local rcodes = rank_cache.codes or {}
    local function seg_ok(s)
      return (emap[s] ~= nil) or (vby and vby[s] ~= nil) or (rcodes[s] ~= nil)
    end
    local memo = {}
    local function walk(i)
      if i > N then return 0 end
      if memo[i] ~= nil then return memo[i] end
      local bestn = false
      local last = i + 15
      if last > N then last = N end
      for j = i + 1, last do
        if seg_ok(flat:sub(i, j)) then
          local r = walk(j + 1)
          if r and r ~= false and (bestn == false or r + 1 < bestn) then bestn = r + 1 end
        end
      end
      memo[i] = bestn
      return bestn
    end
    return walk(1) ~= false
  end
  -- 1.4.23：合成總閘。off（預設）時整段跳過：不切段匹配、不取詞、不算分、不插入。
  local compose_live = (cfg.compose == "on") and compose_enabled()
  if not compose_live then
    -- 關閉時清掉可能殘留的合成狀態，避免 commit 回呼再寫 hook_miss／hook_expire
    synth_state.word, synth_state.code, synth_state.ts = "", "", 0
  end
  local seg_matched = compose_live and whole_code_managed() or false
  local function synth_pos(sscore, lo)
    local pos = 1
    while pos <= #ordered and (ordered_scores[pos] or 0) >= sscore do pos = pos + 1 end
    if pos < lo then pos = lo end
    local cap = #ordered + 1
    if pos > cap then pos = cap end
    return pos
  end

  local synth, ssegs, slen
  if compose_live then
    synth, ssegs, slen = compose_tail(ordered, inp,
        (okv and type(vw) == "table") and vw or nil, segment_count(env))
  end
  if synth then
    local sw = clean_text(synth.text or "")
    local scode = clean_text(synth.comment or ""):gsub("|", " ")
    if first[sw] then
      local at = nil
      for i = 1, #ordered do
        if (ordered[i].text or "") == sw then at = i; break end
      end
      if at then
        local target
        if not seg_matched and not has_other_managed(sw) then
          target = 1                                  -- 整串切不出、候選也沒有匹配詞：第 1
        else
          target = synth_pos(ordered_scores[at] or 0, 2)
          if target > 3 then target = 3 end           -- 有匹配詞：只落在第 2/3
        end
        if target ~= at then
          local oc = ordered[at]
          local osc = ordered_scores[at]
          local our, oup, ouh = uord[at], upos[at], uhas[at]
          table.remove(ordered, at)
          table.remove(ordered_scores, at)
          table.remove(uord, at)
          table.remove(upos, at)
          table.remove(uhas, at)
          table.insert(ordered, target, oc)
          table.insert(ordered_scores, target, osc)
          table.insert(uord, target, our)
          table.insert(upos, target, oup)
          table.insert(uhas, target, ouh)
          count = #ordered
        end
      end
      -- 已存在的合成詞同樣要記：使用者選中的就是合成候選，去重不能變成漏記。
      synth_state.word = sw
      synth_state.code = scode
      synth_state.ts = os.time()
    else
      local sscore = compose_score(ssegs, slen)
      local pos
      if not seg_matched and not has_other_managed(sw) then
        pos = 1                                       -- 整串切不出、候選也沒有匹配詞：第 1
      else
        pos = synth_pos(sscore, 2)
        if pos > 3 then pos = 3 end                   -- 有匹配詞：不搶第一
      end
      local ordv = #uord + 1                   -- 合成候選不屬於引擎原序，給新錨點
      table.insert(ordered, pos, synth)        -- ordered 即 uo，同一張表
      table.insert(ordered_scores, pos, sscore)
      table.insert(uord, pos, ordv)
      table.insert(upos, pos, 0)
      table.insert(uhas, pos, false)
      first[sw] = true
      count = #ordered
      synth_state.word = sw
      synth_state.code = scode
      synth_state.ts = os.time()
    end
  end

  -- 1.3.11：候選快照只在「集合或順序真的變了」才寫（簽章去重）。
  -- 不再加時間節流：librime 的 Lua 沒有毫秒級時鐘、也沒有閒置回呼，
  -- 節流會讓「最後一次按鍵」的狀態永遠不落盤（驗收要讀最終狀態）。
  local parts = {
    inp, scope, tostring(rank_cache.sig), tostring(extra_cache.count), tostring(cfg.style),
  }
  for i, c in ipairs(ordered) do
    parts[#parts + 1] = clean_text(c.text) .. "\x1f" ..
      string.format("%.2f", ordered_scores[i] or 0) .. "\x1f" .. clean_text(c.comment or "")
  end
  local ok, sig = pcall(function() return simple_hash(table.concat(parts, "\x1e")) end)
  if ok and sig ~= last_sig then
    last_sig = sig
    writes_cand = writes_cand + 1
    pcall(dump_candidates, env, inp, ordered, ordered_scores, uord, upos, uhas, ranked, moved, count)
  end

  -- status.tsv：心跳／狀態檔，2~5 秒寫一次即可（輸入清空＝收字，立刻寫）
  local now = os.time()
  if inp == "" or now - last_status_sec >= 2 then
    pcall(write_status, env, inp, ranked, moved, count)
  end

  return ordered
end

-- lua_filter 入口（由 rime 呼叫：func(input, env)）
function M.filter(input, env)
  pcall(use_profile, env)   -- 1.4.0：依當前方案換檔
  pcall(ensure_commit_hook, env)
  local cands = {}
  pcall(function()
    for cand in input:iter() do
      cands[#cands + 1] = cand
    end
  end)
  -- 1.3.22：空候選也進 filter_compute，讓工作台拿到「count 0」而不是停在上一批。
  if #cands == 0 then
    pcall(filter_compute, cands, env)
    return
  end

  local ok, ordered = pcall(filter_compute, cands, env)
  local out = (ok and type(ordered) == "table") and ordered or cands
  for _, cand in ipairs(out) do
    yield(cand)
  end
end

-- ---------- lua_processor：造詞熱鍵 ----------
-- 預設 Shift+Space（可在 reorder\config.ini 以 wordhotkey=… 修改）。
-- 僅在組字狀態攔截；其餘一律回 kNoop（不吞鍵）。
-- 取 context.input（含分隔符的原碼）與 preedit；preedit 仍含英文字母時，
-- 以 preedit 的空白段邊界還原整串碼，只有段數等於詞的字數才造詞（1.3.10）。
local function is_key_release(key)
  local ok, r = pcall(function() return key:release() end)
  return ok and r == true
end

-- 1.3.10：從 preedit 取回段邊界。連續打（無反引號）時 input 是一整串，
-- 引擎只在 preedit 以空白分段（例：szwcsiaisqnclurr → szwc siai sqnc lurr），
-- 可能另附「〔造詞中〕」後綴；只接受純碼段（小寫字母、分號），其餘視為不適用。
preedit_segments = function(ptext)
  if type(ptext) ~= "string" or ptext == "" then return {} end
  local mark = ptext:find("〔", 1, true)
  if mark then ptext = ptext:sub(1, mark - 1) end
  ptext = ptext:gsub("`", " ")
  local segs = {}
  for part in ptext:gmatch("%S+") do
    if not part:match("^[%l;]+$") then return {} end
    segs[#segs + 1] = part
  end
  return segs
end

-- 1.3.24：preedit 開頭「已確認的漢字」前綴（例「租ci」→「租」、「中文大臠dau」→「中文大臠」）。
-- 逐字選字後引擎把已確認字放進 preedit 開頭，造詞要把這些字一併算進去。
local function preedit_cjk_prefix(ptext)
  if type(ptext) ~= "string" or ptext == "" then return "" end
  local mark = ptext:find("〔", 1, true)
  if mark then ptext = ptext:sub(1, mark - 1) end
  local out, i = {}, 1
  while i <= #ptext do
    local b = ptext:byte(i)
    if b < 0x80 then break end          -- ASCII／空白＝分段碼開始，前綴到此為止
    local len = 3
    if b >= 0xF0 then len = 4 elseif b >= 0xE0 then len = 3 elseif b >= 0xC0 then len = 2 end
    out[#out + 1] = ptext:sub(i, i + len - 1)
    i = i + len
  end
  return table.concat(out)
end

-- 1.3.24：把「已上屏字序」與 preedit 前綴合併（重疊時只保留一份，避免重複計字）
local function merge_word(a, b)
  a, b = a or "", b or ""
  if a == "" then return b end
  if b == "" then return a end
  if a == b then return a end
  local n = math.min(#a, #b)
  for i = n, 1, -1 do
    if a:sub(-i) == b:sub(1, i) then return a .. b:sub(i + 1) end
  end
  return a .. b
end

-- 1.3.23(3a)：本輪組字「已經上屏」的字序與已消耗的碼。
-- 舊版只從候選窗取當前快照，逐字上屏（城→大→饋）時前面幾輪已被推走，只剩最後一個字。
-- 這裡改由 commit_notifier 累積：每次上屏都記下文字與被消耗的輸入碼，造詞時按序列拼。
comp = {
  word = "", raw = "", last_input = "", segs = nil,
  last_commit = "", last_commit_ts = 0,
  bound = false, bind_logged = false, suppress = false,
}

-- 1.4.21：上屏通知要從 env.engine.context.commit_notifier 取。
-- weasel 這版 librime-lua 的 env.commit_notifier 是 nil：舊版 pcall 直接拋錯，而 bound
-- 又先被鎖死，整場會話再也不會重試 → 上屏 0 記錄。改為「連上才鎖定」，入口每次重試。
ensure_commit_hook = function(env)
  if comp.bound then return end
  local notifier = nil
  pcall(function() notifier = env.engine.context.commit_notifier end)
  if not notifier then
    if not comp.bind_logged then
      comp.bind_logged = true
      pcall(udlog, { "hook_connect", "no-notifier", "ctx=" .. tostring(env.engine.context ~= nil) })
    end
    return
  end
  local ok, err = pcall(function()
    notifier:connect(function(ctx)
      if comp.suppress then return end
      local t = ""
      pcall(function() t = ctx:get_commit_text() end)
      t = clean_text(t or "")
      local remain = ""
      pcall(function() remain = tostring(ctx.input or "") end)
      local prev = comp.last_input or ""
      local consumed = ""
      if remain == "" then
        consumed = prev
      elseif #prev >= #remain and prev:sub(-#remain) == remain then
        consumed = prev:sub(1, #prev - #remain)
      end
      if t ~= "" then
        comp.word = (comp.word or "") .. t
        comp.last_commit, comp.last_commit_ts = t, os.time()
      end
      -- 1.4.19：上屏的正是剛剛合成的詞 → 寫入 userdb（1.4.20 預設不再重複寫 extra.tsv）
      -- 1.4.20：視窗放寬到 30 秒；1.4.21 再放到 120 秒（選字可能想很久），
      -- 對不上或過期都留一行，方便用 userdb.log 實測。
      local recorded = false
      if t ~= "" and synth_state.word ~= "" then
        local dt = os.time() - (synth_state.ts or 0)
        if t == synth_state.word and dt <= 120 then
          local scode = synth_state.code
          synth_state.word, synth_state.code, synth_state.ts = "", "", 0
          pcall(mirror_commit, env, scode, t)
          recorded = true
        elseif dt <= 120 then
          pcall(udlog, { "hook_miss", "want=" .. tostring(synth_state.word),
              "got=" .. t, "code=" .. tostring(synth_state.code), "dt=" .. tostring(dt) })
        else
          pcall(udlog, { "hook_expire", "want=" .. tostring(synth_state.word),
              "got=" .. t, "code=" .. tostring(synth_state.code), "dt=" .. tostring(dt) })
          synth_state.word, synth_state.code, synth_state.ts = "", "", 0
        end
      end
      -- 1.4.22：引擎已多 segment、沒有合成候選時，用 filter 快取的整串碼兜底記帳
      -- （條件見 record_cross_commit：2..4 段、上屏 2..8 字、最後一段是本工具管理的碼）
      if t ~= "" and not recorded then
        pcall(record_cross_commit, env, t)
      end
      if consumed ~= "" then
        -- 每次上屏消耗的碼自成一段；用空白接起來，逐字上屏也能還原分段碼
        local c2 = consumed:gsub("^[%s`]+", ""):gsub("[%s`]+$", "")
        if c2 ~= "" then
          comp.raw = ((comp.raw or "") ~= "") and ((comp.raw or "") .. " " .. c2) or c2
        end
      end
      comp.last_input = remain
      -- 整串收字（沒有剩餘輸入）＝本輪結束，累積歸零，下一輪重新開始
      if remain == "" then
        comp.word, comp.raw = "", ""
        synth_state.word, synth_state.code, synth_state.ts = "", "", 0
      end
    end)
  end)
  if ok then comp.bound = true end
  pcall(udlog, { "hook_connect", tostring(ok), tostring(err) })
end

local function reset_comp()
  comp.word, comp.raw, comp.last_input, comp.segs = "", "", "", nil
end

-- 上屏字序＋當前選取的候選＝要造／要刪的完整詞
-- 1.3.24：逐字選字後前面的字留在 preedit 開頭（commit_notifier 收不到），
-- 這裡把 preedit 的漢字前綴一併併入，避免只記到最後一個字。
local function compose_word(ctx, ptext)
  local sel = nil
  pcall(function() sel = ctx:get_selected_candidate() end)
  local w = sel and sel.text or nil
  if (not w or w == "") then
    local ct = nil
    pcall(function() ct = ctx:get_commit_text() end)
    w = ct
  end
  if type(w) ~= "string" or w == "" then return nil, nil end
  w = clean_text(w)
  if w == "" then return nil, nil end
  if w:find("[A-Za-z]") then return nil, nil end
  local word = merge_word(merge_word(comp.word, preedit_cjk_prefix(ptext)), w)
  word = clean_text(word)
  if word == "" or utf8_chars(word) == 0 then return nil, nil end
  return word, sel
end

-- 造詞碼：有累積（逐字上屏）時併上先前消耗的碼；沒有時沿用 1.3.20 的原邏輯
local function compose_code(input, ptext, sel, nchars)
  if (comp.raw or "") ~= "" then
    local raw = comp.raw .. " " .. input
    local segs = {}
    for part in raw:gsub("`", " "):gmatch("%S+") do segs[#segs + 1] = part end
    if #segs == nchars then
      return normalize_code(table.concat(segs, " "))
    end
    -- 分不出段（連續輸入）：整串連續碼，下次同樣連續打才精確命中
    return normalize_code(raw:gsub("`", ""):gsub("%s+", ""))
  end
  -- 1.3.24：preedit 已有已確認漢字（逐字選字）時，preedit 只剩「漢字＋剩餘碼」，
  -- 整串分段要用輸入期間記下的 comp.segs；只剩 1 個已確認字時可直接由尾部剩餘碼還原。
  local pre = preedit_cjk_prefix(ptext)
  if pre ~= "" then
    local k = utf8_chars(pre)
    local rem = {}
    local tail = ptext:sub(#pre + 1):gsub("`", " ")
    for part in tail:gmatch("[%l;]+") do rem[#rem + 1] = part end
    local fs = comp.segs
    if fs and #fs >= k then
      local segs = {}
      local ok = true
      for i = 1, k do segs[#segs + 1] = fs[i] end
      if #rem >= 1 then
        -- 記下的整串分段若含剩餘段，就以「前 k 段＋preedit 剩餘段」為準
        for _, r in ipairs(rem) do segs[#segs + 1] = r end
      elseif #fs > k then
        ok = false
      end
      if ok and #segs == nchars then
        return normalize_code(table.concat(segs, " "))
      end
    end
    if k == 1 and #rem >= 1 then
      local fused_rem = table.concat(rem, "")
      local fi = input:gsub("[`%s]+", "")
      if #fi > #fused_rem and fi:sub(-#fused_rem) == fused_rem then
        local segs = { fi:sub(1, #fi - #fused_rem) }
        for _, r in ipairs(rem) do segs[#segs + 1] = r end
        if #segs == nchars then
          return normalize_code(table.concat(segs, " "))
        end
      end
    end
  end
  -- 1.3.24：整串分段與字數一致時優先採用（逐字上屏後 preedit 只剩最後一段碼）
  local fs2 = comp.segs
  if fs2 and #fs2 == nchars and
     table.concat(fs2, ""):lower() == input:gsub("[`%s]+", ""):lower() then
    return normalize_code(table.concat(fs2, " "))
  end
  -- 1.3.20：造詞碼來源依序為
  --   1) 反引號造詞模式：input 本身就是分段碼
  --   2) preedit 的空白分段（段數＝字數）
  --   3) 前綴匹配候選的 comment（例 sz|si|sq|lu，帶實際切法）
  --   4) 以上都拿不到時，退回整串 input
  local code = nil
  if input:find("`", 1, true) then
    code = input
  else
    local segs = preedit_segments(ptext)
    if #segs >= 2 and #segs == nchars then
      code = table.concat(segs, " ")
    end
  end
  if not code and sel then
    local cm = nil
    pcall(function() cm = sel.comment end)
    if type(cm) == "string" then
      local segs, ok = {}, true
      for part in cm:gsub("|", " "):gmatch("%S+") do
        if part:match("^[%l;]+$") then
          segs[#segs + 1] = part
        else
          ok = false
          break
        end
      end
      if ok and #segs >= 2 and #segs == nchars then
        code = table.concat(segs, " ")
      end
    end
  end
  if not code or code == "" then code = input end
  return normalize_code(code)
end

-- ---------- 1.3.23(3b)：Shift+Del 刪除本工具加的詞（rank / extra / vocab 三處） ----------

local function active_rank_path()
  if file_size(RANK) ~= nil then return RANK end
  local off = RANK .. ".off"
  if file_size(off) ~= nil then return off end
  return RANK
end

local function tab_field_is(line, field, word)
  local i = 0
  for part in line:gmatch("[^\t]+") do
    i = i + 1
    if i == field then return part == word end
  end
  return false
end

local function text_has_word(text, field, word)
  if not text then return false end
  for line in text:gmatch("[^\r\n]+") do
    if line ~= "" and line:sub(1, 1) ~= "#" and tab_field_is(line, field, word) then
      return true
    end
  end
  return false
end

-- 這個詞是否真的屬於本工具（rank 第 1 欄／extra 第 2 欄／vocab 第 1 欄）
local function tool_owns_word(word)
  if text_has_word(read_all(VOCAB), 1, word) then return true end
  if text_has_word(read_all(EXTRA), 2, word) then return true end
  if text_has_word(read_all(active_rank_path()), 1, word) then return true end
  return false
end

-- 刪掉整個檔裡屬於該詞的所有行；回傳 (是否有變更, 刪除行數, 被刪的行)
local function remove_word_lines(path, field, word)
  local text = read_all(path)
  if text == nil then return false, 0, nil end
  local out, removed, n = {}, {}, 0
  for line in text:gmatch("[^\r\n]+") do
    if line ~= "" and line:sub(1, 1) ~= "#" and tab_field_is(line, field, word) then
      n = n + 1
      removed[#removed + 1] = line
    else
      out[#out + 1] = line
    end
  end
  if n == 0 then return false, 0, nil end
  local body = table.concat(out, "\n")
  if #out > 0 then body = body .. "\n" end
  return write_all(path, body), n, removed
end

local function undo_file(key, suffix)
  return DIR .. "undo\\" .. key .. suffix
end

-- 1.4.6：快照鍵帶方案前綴；完整方案名寫進 .act，工作台還原前會核對
local function profile_tag()
  local id = prof_state.id or "?"
  id = id:gsub("[^%w%-_]", "_")
  if id == "" then id = "_" end
  return id
end

local function snapshot_act_text(onoff)
  local prof = prof_state.id or "?"
  return onoff .. "\nprofile=" .. prof ..
         "\ntarget=" .. ((onoff == "on") and "rank.tsv" or "rank.tsv.off") .. "\n"
end

local function save_snapshot(key, suffix, path)
  local text = read_all(path) or ""
  return write_all(undo_file(key, suffix), text)
end

-- 1.4.2：造詞也走快照交易（與拖曳／刪詞同一套 undo\,<key>.* 機制）。
-- 造詞前先把（本次會改的）檔案現況寫成前像；造詞後再存 <key>.a 後像供重做。
-- 1.4.11：which 指定要存的檔（缺省＝三份全存）。造詞只改 extra／vocab，
--          不再連 1.4MB 的 rank 也複製兩遍；工作台還原時缺哪份就跳過哪份。
-- 回傳 key（失敗為 nil）與實際寫入路徑；工作台據歷史列的「1|key」整筆撤回。
snapshot_before = function(which)
  -- 1.4.11：which 只列「這次真的要存」的檔；nil＝三份全存
  if not which then which = { rank = true, extra = true, vocab = true } end
  local rankp = active_rank_path()
  local onoff = (file_size(RANK) ~= nil) and "on" or "off"
  local paths = {
    rank  = write_target(onoff == "on" and "rank.tsv" or "rank.tsv.off", rankp),
    extra = write_target("extra.tsv", EXTRA),
    vocab = write_target("vocab.txt", VOCAB),
  }
  local key = profile_tag() .. "-" .. os.date("%Y%m%d%H%M%S") .. "-" ..
              tostring(math.random(10000, 99999))
  local ok = true
  if which.rank then ok = ok and save_snapshot(key, ".tsv", paths.rank) end
  if which.extra then ok = ok and save_snapshot(key, ".x.tsv", paths.extra) end
  if which.vocab then ok = ok and save_snapshot(key, ".v.tsv", paths.vocab) end
  ok = ok and write_all(undo_file(key, ".act"), snapshot_act_text(onoff)) and true or false
  return (ok and key or nil), paths
end

snapshot_after = function(key, paths, which)
  if not key or key == "" or not paths then return end
  if not which then which = { rank = true, extra = true, vocab = true } end
  if which.rank then save_snapshot(key .. ".a", ".tsv", paths.rank) end
  if which.extra then save_snapshot(key .. ".a", ".x.tsv", paths.extra) end
  if which.vocab then save_snapshot(key .. ".a", ".v.tsv", paths.vocab) end
  local onoff = (paths.rank and paths.rank:sub(-4) == ".off") and "off" or "on"
  write_all(undo_file(key .. ".a", ".act"), snapshot_act_text(onoff))
end

-- 刪詞並寫入可撤銷交易（工作台 Ctrl+Z 會用 undo\<key>.* 整批還原）
local function delete_tool_word(env, word)
  init_paths()
  local rankp = active_rank_path()
  local onoff = (file_size(RANK) ~= nil) and "on" or "off"
  -- 1.4.1：刪除也屬於「寫」——目標一律落本方案目錄
  local wrank = write_target(onoff == "on" and "rank.tsv" or "rank.tsv.off", rankp)
  local wextra = write_target("extra.tsv", EXTRA)
  local wvocab = write_target("vocab.txt", VOCAB)
  local key = profile_tag() .. "-" .. os.date("%Y%m%d%H%M%S") .. "-" ..
              tostring(math.random(10000, 99999))
  local ok_snap = save_snapshot(key, ".tsv", wrank)
      and save_snapshot(key, ".x.tsv", wextra)
      and save_snapshot(key, ".v.tsv", wvocab)
      and write_all(undo_file(key, ".act"), snapshot_act_text(onoff)) and true or false

  local _, nr = remove_word_lines(wrank, 1, word)
  local _, ne, removedE = remove_word_lines(wextra, 2, word)
  local _, nv, removedV = remove_word_lines(wvocab, 1, word)
  local total = nr + ne + nv
  if total == 0 then return false end
  -- 1.4.19：extra 刪了就同步刪 userdb（用被刪那幾行的碼），避免下次又從 userdb 冒出來
  if removedE then
    for _, line in ipairs(removedE) do
      local c2 = line:match("^([^\t]+)")
      if c2 and c2 ~= "" then
        pcall(userdb_delete, env, c2, word)
      end
    end
  end
  -- 1.3.24：本工具刪掉的 vocab 行也留記號，工作台不會把它當成使用者外部編輯再套用一次
  -- 記號只存「詞＋正規化後的碼」（去掉「方案:」前綴），與工作台解析出的欄位對齊
  if removedV then
    for _, line in ipairs(removedV) do
      local w2, c2 = line:match("^([^\t]+)\t([^\t]+)")
      if w2 and c2 then
        local sc, cc = c2:match("^([^:]+):(.+)$")
        if sc then c2 = cc end
        c2 = normalize_code(c2)
        append_tsv(VOCAB_OPS, "-" .. w2 .. "\t" .. c2)
      end
    end
  end

  if ok_snap then
    save_snapshot(key .. ".a", ".tsv", wrank)
    save_snapshot(key .. ".a", ".x.tsv", wextra)
    save_snapshot(key .. ".a", ".v.tsv", wvocab)
  end

  rank_cache.ready = false
  extra_cache.ready = false
  vocab_cache.ready = false
  pref_cache.key, pref_cache.hit = nil, nil
  last_sig = nil

  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local sid = ""
  pcall(function() sid = clean_text(schema_id(env) or "") end)
  local extra_field = ok_snap and (tostring(total) .. "|" .. key) or tostring(total)
  append_tsv(HISTORY, ts .. "\tdelword\t" .. word .. "\t\t\t" .. sid .. "\t" .. extra_field)
  append_tsv(STATUS, "delword\t" .. ts .. "\t" .. word
      .. "\trank=" .. tostring(nr) .. "\textra=" .. tostring(ne)
      .. "\tvocab=" .. tostring(nv) .. "\tundo=" .. (ok_snap and "1" or "0"))
  return true
end

local function try_delete(env, ctx, composing)
  local targets = {}
  if composing then
    local w = compose_word(ctx)
    if w and w ~= "" then targets[#targets + 1] = w end
    local sel = nil
    pcall(function() sel = ctx:get_selected_candidate() end)
    if sel and type(sel.text) == "string" and sel.text ~= "" then
      local st = clean_text(sel.text)
      if st ~= "" and not st:find("[A-Za-z]") then targets[#targets + 1] = st end
    end
    if (comp.word or "") ~= "" then targets[#targets + 1] = comp.word end
  end
  if (comp.last_commit or "") ~= "" and (os.time() - (comp.last_commit_ts or 0)) <= 30 then
    targets[#targets + 1] = comp.last_commit
  end
  local seen = {}
  for _, w in ipairs(targets) do
    if w ~= "" and not seen[w] then
      seen[w] = true
      if tool_owns_word(w) then return delete_tool_word(env, w) end
    end
  end
  return false
end

-- librime 的 keycode 是 X11 keysym（Delete=0xFFFF），舊版 key 表用的是 Windows VK（46）；
-- 兩種都認，避免熱鍵在不同 librime 版本下失效。
local function key_hit(kc, target)
  if kc == target then return true end
  if target == 46 or target == 0xFFFF then return kc == 46 or kc == 0xFFFF end
  return false
end

local function processor_body(key, env)
  if is_key_release(key) then return 2 end
  -- 1.3.21：排序關閉時完全不攔鍵（等同沒裝）
  if not rank_active() then return 2 end
  ensure_commit_hook(env)
  local cfg = load_config()
  local kc = key.keycode or 0
  local km = relevant_mods(key.modifier)
  local is_word = key_hit(kc, cfg.vk) and km == cfg.mods
  local is_del = key_hit(kc, cfg.dvk) and km == cfg.dmods
  if (not is_word) and (not is_del) then return 2 end

  local ctx = env.engine.context
  local composing = false
  pcall(function() composing = ctx:is_composing() end)

  if is_del then
    -- 只刪本工具加過的詞；不是就原樣放行（不誤刪引擎自帶內容）
    if try_delete(env, ctx, composing) then return 1 end
    return 2
  end

  if not composing then return 2 end
  local input = ctx.input or ""
  if input == "" then return 2 end

  local preedit = nil
  pcall(function() preedit = ctx:get_preedit() end)
  local ptext = (preedit and preedit.text) or ""

  local word, sel = compose_word(ctx, ptext)
  if not word then return 2 end
  local nchars = utf8_chars(word)
  if nchars == 0 then return 2 end

  local code = compose_code(input, ptext, sel, nchars)
  if code == "" then code = normalize_code(input) end
  if code == "" then return 2 end

  -- 上字（commit 已含前面各段）＋寫 extra/history/心跳
  synth_state.word, synth_state.code, synth_state.ts = "", "", 0
  comp.suppress = true
  pcall(function() env.engine:commit_text(word) end)
  pcall(function() ctx:clear() end)
  comp.suppress = false
  comp.last_commit, comp.last_commit_ts = word, os.time()
  reset_comp()
  pcall(record_newword, env, code, word, ptext)
  return 1
end

function M.processor(key, env)
  pcall(use_profile, env)   -- 1.4.0：依當前方案換檔
  local ok, ret = pcall(processor_body, key, env)
  if ok and (ret == 1 or ret == 2) then return ret end
  return 2
end

local function translator_body(input, seg, env)
  init_paths()
  -- 1.4.18：注入判據改為「工作台在場 or rank.tsv 真的存在」，兩個都假才完全不注入。
  -- 不再用 rank_active()：工作台把排序收成 .off（或 exitonclose=0 但工作台已退出）
  -- 這兩種情況仍要能注入／捕捉，只是排序與標記各自照 mark_live／active 判定。
  if not helper_on() then return end
  load_extra()
  local code = input
  local key = code
  -- 1.3.24：同一個碼可以有多個同音詞，全部注入（否則非全拼碼表方案只剩一個）
  local words = extra_words(code)
  -- 1.3.14：精確碼沒中 → 前綴分段匹配（連續輸入 szsisqlu 也能命中，不必事先寫入組合）
  if not words then
    local ws, split = prefix_match(code)
    if ws then
      words = ws
      key = split   -- 註記顯示實際切法（例 sz|si|sq|lu）
    end
  end
  if words and #words > 0 then
    -- 虛擬詞：type = reorder_extra，comment＝實際命中的碼（正規化後，與 extra.tsv 一致）
    -- 品質由 filter 依「同文命中」套用（Candidate 只有 5 個參數，沒有品質欄）
    if type(seg) == "userdata" or type(seg) == "table" then
      local end_pos = seg._end
      if end_pos == nil then end_pos = seg["end"] end
      for i = 1, #words do
        local w = words[i]
        if type(w) == "table" then w = w.word end
        if type(w) == "string" and w ~= "" then
          pcall(function()
            yield(Candidate("reorder_extra", seg.start, end_pos, w, key))
          end)
        end
      end
    end
  end
end

-- lua_translator 入口（由 rime 呼叫：func(input, seg, env)）
function M.translator(input, seg, env)
  pcall(use_profile, env)   -- 1.4.0：依當前方案換檔
  pcall(ensure_commit_hook, env)
  -- 1.3.23(3a)：追蹤本次組字的輸入，供 commit_notifier 算出「已被上屏消耗的碼」
  if type(input) == "string" then
    if input == "" then
      reset_comp()
    else
      comp.last_input = input
    end
  end
  pcall(translator_body, input, seg, env)
end

-- 單一模組同時供 lua_filter@*reorder 與 lua_translator@*reorder 使用。
-- 第二個參數是 env(table) → filter；是 segment(userdata) → translator。
function M.func(x, a, b)
  if type(a) == "table" then
    -- 同為 (obj, env)：processor 的 obj 是 KeyEvent（有 keycode），filter 的是候選迭代器
    local ok, kc = pcall(function() return x.keycode end)
    if ok and type(kc) == "number" then
      return M.processor(x, a)
    end
    return M.filter(x, a)
  end
  return M.translator(x, a, b)
end

function M.init(env)
  init_paths()
  pcall(use_profile, env)   -- 1.4.0：啟動時就先綁定當前方案
  ensure_commit_hook(env)   -- 1.3.23(3a)：越早接上，逐字上屏才不會漏記
end

function M.fini(env)
end

return M
