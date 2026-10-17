-- 挂机破坏神 (Deskrawl.exe) 金币模块 —— 独立加载
-- 作者 YC　版本 v1.0.0　适用 Unity IL2CPP / CE 7.5+
-- 用法: 勾选 [★G0] 启动 -> 在 [★20] 金币锁定填入目标数值 -> 生效
--        填 0 即完全还原（停止锁定）
--
-- 实现: 金币钱包是「紧凑版 ObscuredInt」(hidden@X, key@X+4, 无 hash),
--       明文 = (hidden - key) XOR key (mod 2^32)。
--       定位: 内存中存档 JSON 字符串特征 {"Version":5 -> 解析 "Gold":N
--             -> 自该地址向外分块扫描解码相等的 (hidden,key) 对。
--       本模块独立于主 CT, 不加载它就不会有任何扫描开销。

local VERSION = "1.0.0"
local SYM = { CTL = "FXDG_CTL", SET = "FXDG_SET", GOLD = "FXDG_GOLD", ADDR = "FXDG_ADDR" }
local ENTRIES = {
  {t = "header", d = "═══ 挂机破坏神 —— 金币模块 ═══"},
  {t = "note",   d = "    作者 YC      版本 v" .. VERSION .. "      需先加载 Deskrawl_YC.CT 并已进游戏读档"},
  {t = "note",   d = "    勾选 [★G0] 启动 -> 填 [★20] 金币锁定 -> 填 0 还原"},
  {t = "note",   d = "    自动定位失败时：把钱包地址(HEX)填进 [G3]（见解密笔记第十一节的定位流程）"},
  {t = "header", d = "────────── 金币 ──────────"},
  {t = "value",  d = "[G2] 当前金币", sym = SYM.GOLD, vt = vtDword},
  {t = "value",  d = "[★20] 金币锁定（默认 999999，0=不锁定）", sym = SYM.SET, vt = vtDword},
  {t = "value",  d = "[G3] 钱包地址HEX（可选·自动定位失败时手填，8字节）", sym = SYM.ADDR, vt = vtQword},
  {t = "header", d = "────────── 状态 ──────────"},
  {t = "value",  d = "[G0] 金币模块状态（2=就绪 3=定位中）", sym = SYM.CTL, vt = vtByte},
}

local g_pid, g_stopped = nil, false
local g_ctl = nil
local g_goldAddr, g_goldKey = nil, nil
local g_lastScan, g_startedAt = 0, nil

local function log(msg)
  print("[DeskrawlGold v" .. VERSION .. "] " .. tostring(msg))
  pcall(function()
    local f = io.open(os.getenv("TEMP") .. "\\deskrawl_gold.log", "a")
    if f then f:write("[" .. os.date("%H:%M:%S") .. "] " .. tostring(msg) .. "\n") f:close() end
  end)
end

local function rdq(a) local ok, v = pcall(readQword, a) if ok then return v end return nil end
local function rdi(a) local ok, v = pcall(readInteger, a) if ok then return v end return nil end
local function rds(a, n)
  if not a or a < 0x10000 then return nil end
  local ok, s = pcall(readString, a, n or 48, false)
  if ok then return (s:gsub("[^%g ]", "?")) end
  return nil
end
local function reg(sym, addr)
  if addr and addr > 0x10000 then
    pcall(registerSymbol, sym, string.format("%X", addr), true)
  else
    pcall(unregisterSymbol, sym)
  end
end

local function goldDecode(addr)
  local h = rdi(addr)
  local k = rdi(addr + 4)
  if not h or not k then return nil end
  return ((h - k) % 0x100000000) ~ k
end

local function goldEncode(addr, key, value)
  writeInteger(addr, ((value ~ key) + key) % 0x100000000)
end

-- digits of "Gold":N are 7 UTF-16 chars after the opening quote
local function readUTF16Num(addr, maxChars)
  local digits, count = {}, 0
  for i = 0, maxChars - 1 do
    local v = rdi(addr + i * 2)
    if not v or v < 48 or v > 57 then break end
    digits[#digits+1] = v
    count = count + 1
  end
  if count == 0 then return nil end
  local num = 0
  for i = 1, count do num = num * 10 + (digits[i] - 48) end
  return num
end

-- anchor on the cached save JSON, then chunked outward sweep for the pair
local function resolveWallet()
  local gsl = AOBScan([[22 00 47 00 6F 00 6C 00 64 00 22 00 3A 00]], "+W-C")
  if not gsl or gsl.Count == 0 then return nil end
  -- several "Gold": occurrences may exist; take the first that parses as a number
  local jsonGold = nil
  for i = 0, math.min(gsl.Count - 1, 7) do
    local a = tonumber(gsl[i], 16)
    if a then
      local v = readUTF16Num(a + 7 * 2, 12)
      if v and v >= 0 and v <= 1000000000 then jsonGold = v break end
    end
  end
  gsl.destroy()
  if not jsonGold then return nil end
  local jsl = AOBScan([[7B 00 22 00 56 00 65 00 72 00 73 00 69 00 6F 00 6E 00 22 00 3A 00 35 00]], "+W-C")
  if jsl and jsl.Count > 0 then anchor = tonumber(jsl[0], 16) end
  if jsl then jsl.destroy() end
  if not anchor then return nil end
  local CHUNK, RANGE = 0x40000, 0x10000000   -- 256KB chunks, +/-256MB
  for _, dir in ipairs({ 1, -1 }) do
    local off = 0
    while off < RANGE do
      local base = anchor + dir * off
      if base < 0x10000 then break end
      local buf = readBytes(base, CHUNK, true)
      if buf and #buf >= 8 then
        for i = 1, #buf - 8, 4 do
          local h = buf[i] + buf[i+1] * 0x100 + buf[i+2] * 0x10000 + buf[i+3] * 0x1000000
          local k = buf[i+4] + buf[i+5] * 0x100 + buf[i+6] * 0x10000 + buf[i+7] * 0x1000000
          if k ~= 0 and k > 16 then
            if ((h - k) % 0x100000000) ~ k == jsonGold then
              return base + i - 1, k
            end
          end
        end
      end
      off = off + CHUNK
    end
  end
  return nil
end

local function buildEntries()
  local al = getAddressList()
  for i = al.Count - 1, 0, -1 do
    local mr = al.getMemoryRecord(i)
    if mr.Description then
      for _, e in ipairs(ENTRIES) do
        if mr.Description == e.d then memoryrecord_delete(mr) break end
      end
    end
  end
  al = getAddressList()
  for _, e in ipairs(ENTRIES) do
    local mr = al.createMemoryRecord()
    mr.Description = e.d
    if e.t == "header" then
      local ok = pcall(function() mr.IsGroupHeader = true end)
      if not ok then pcall(function() mr.GroupHeader = true end) end
      mr.Address = "0"
      mr.Type = vtDword
    elseif e.t == "note" then
      mr.Address = "0"
      mr.Type = vtDword
    else
      mr.Type = e.vt
      mr.Address = e.sym
    end
  end
end

local function startGold()
  g_pid = getOpenedProcessID()
  g_startedAt = os.clock()
  g_stopped = false
  g_ctl = allocateMemory(64)
  if g_ctl then
    for i = 0, 7 do writeQword(g_ctl + i * 8, 0) end
    writeInteger(g_ctl + 4, 999999)   -- [★20] default gold lock value
  end
  buildEntries()
  reg(SYM.CTL, g_ctl)
  reg(SYM.SET, g_ctl and g_ctl + 4)
  reg(SYM.ADDR, g_ctl and g_ctl + 8)
  local t = createTimer(nil, false)
  t.Interval = 60
  t.OnTimer = function()
    if g_stopped then return end
    if getOpenedProcessID() ~= g_pid then g_stopped = true t.destroy() return end
    if not g_ctl then return end
    writeInteger(g_ctl, 2)          -- ctl+0 = status (script writes)
    local set = rdi(g_ctl + 4) or 0 -- ctl+4 = user setpoint
    -- manual override: if [G3] holds an address, use it directly
    local manual = rdi(g_ctl + 8) or 0
    manual = manual + ((rdi(g_ctl + 12) or 0) * 0x100000000)
    if manual > 0x10000 then
      local d = goldDecode(manual)
      if d and d >= 0 and d < 1000000000 then
        if g_goldAddr ~= manual then
          g_goldAddr, g_goldKey = manual, rdi(manual + 4)
          reg(SYM.GOLD, manual)
          log("manual wallet address " .. string.format("%X", manual) .. " gold=" .. tostring(d))
        end
      end
    end
    -- resolve with retries: the JSON anchor is a TRANSIENT string and the
    -- memory scan itself takes ~15 s on a 16 GB process, so a hit can go
    -- stale before we even read it. Keep retrying; eventually one attempt
    -- lands inside a fresh window.
    if set > 0 and not g_goldAddr and (g_attempts or 0) < 3
       and os.clock() - g_lastScan > 45 then
      g_lastScan = os.clock()
      g_attempts = (g_attempts or 0) + 1
      writeInteger(g_ctl, 3)
      local okR, a, k = pcall(resolveWallet)
      if okR and a then
        g_goldAddr, g_goldKey = a, k
        reg(SYM.GOLD, g_goldAddr)
        log("wallet resolved at " .. string.format("%X", g_goldAddr)
            .. " key=" .. string.format("%016X", k) .. " (attempt " .. g_attempts .. ")")
      else
        if g_attempts >= 3 then
          log("auto-locate gave up after 3 attempts (each costs a ~15 s memory scan). "
              .. "Put the wallet address into [G3] instead - see section 11 of the ACTk notes.")
        else
          log("resolve attempt " .. g_attempts .. " failed (JSON anchor went stale?), retrying in 45s")
        end
      end
      writeInteger(g_ctl, 2)
    end
    if set > 0 and g_goldAddr then
      if goldDecode(g_goldAddr) ~= set then
        goldEncode(g_goldAddr, g_goldKey, set)
      end
    end
  end
  t.Enabled = true
  _G.DeskrawlGold_Timer = t
  log("v" .. VERSION .. " started (set gold in [G1])")
end

local function stopGold()
  g_stopped = true
  if _G.DeskrawlGold_Stop then _G.DeskrawlGold_Stop() end
end
_G.DeskrawlGold_Stop = function()
  local t = _G.DeskrawlGold_Timer
  if t then pcall(function() t.destroy() end) _G.DeskrawlGold_Timer = nil end
  if g_ctl then pcall(deAllocateMemory, g_ctl) end
  g_ctl = nil
  g_goldAddr, g_goldKey = nil, nil
  for _, k in pairs(SYM) do pcall(unregisterSymbol, k) end
  local al = getAddressList()
  for i = al.Count - 1, 0, -1 do
    local mr = al.getMemoryRecord(i)
    if mr.Description then
      for _, e in ipairs(ENTRIES) do
        if mr.Description == e.d then memoryrecord_delete(mr) break end
      end
    end
  end
end

-- entry point
if not g_ctl then
  local ok, err = pcall(function()
    startGold()
  end)
  if not ok then
    log("init FAILED: " .. tostring(err))
    _G.DeskrawlGold_Stop()
  end
end
