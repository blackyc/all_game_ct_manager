-- =============================================================================
--  Deskrawl / 挂机破坏神 —— 角色状态查看 + 数值修改
--  作者：YC          版本：v1.0.0          日期：2026-10-15
--  适用：Deskrawl.exe（Unity **IL2CPP** 运行时）      Cheat Engine 7.5 或更新
-- =============================================================================
--  【功能一览】
--   [1] 当前生命 / 当前法力        战斗中的实时数值，改动立即生效（可在条目上
--                                  右键 Freeze 锁定）
--   [2] 等级/经验/最大生命/基础伤害/最大法力/主属性/可用天赋点/累计金币
--                                  存档数据（明文），改动需回主菜单重新读档生效；
--                                  脚本每秒把主副本同步到镜像副本，两份都会更新
--   [★9] 脚本状态                 0未启动 1运行中 2部分就绪 3失联(自动重试)
--
--  【使用方法】
--   1) Cheat Engine → Open Process → 附加到 Deskrawl.exe
--   2) 勾选最上面的 [★0] 启动/重新定位
--      （进游戏读档后再勾，全部条目立刻有数字；在主菜单勾选时存档组会先显示 ?）
--   3) 每次重开游戏 / 读档后，重新勾选一次 [★0] 即可（脚本会自动清理旧条目重建）
--   4) 关闭：取消勾选 [★0]，或执行 Deskrawl_Stop()
--
--  【工作原理】
--   本游戏是 Unity IL2CPP（没有 Mono），脚本改为调用 GameAssembly.dll 的
--   il2cpp 官方导出函数：domain → 程序集 → Assembly-CSharp → 类 → 字段偏移，
--   全部在运行期解析，不写死任何地址/偏移，游戏小版本更新不受影响。
--   · 实时生命/法力：Player(基类 Character) 实例的明文字段
--     （GameManager 单例 → PlayerCombatController → Player，逐级类校验）
--   · 存档数据：SaveData 实例（按类指针扫描 + 数值语义校验）
--   · 注意：角色面板中的智力/暴击/攻速等基础属性受 ACTk 反作弊加密保护，
--     本脚本刻意不写这些字段，避免触发游戏的反作弊检测。
-- =============================================================================

local VERSION = "1.5.0"
local ENTRY_TAG = "FXD"
local SYM = {GM="FXD_GM", PCC="FXD_PCC", PLAYER="FXD_PLAYER", SAVE="FXD_SAVE",
  SAVE2="FXD_SAVE2", CTL="FXD_CTL", HP="FXD_HP", MANA="FXD_MANA",
  LEVEL="FXD_LEVEL", XP="FXD_XP", MAXHP="FXD_MAXHP", DMG="FXD_DMG",
  MAXMANA="FXD_MAXMANA", PSTAT="FXD_PSTAT", TALENT="FXD_TALENT",

  MSSHOW="FXD_MSSHOW", ASSHOW="FXD_ASSHOW",
  GOD="FXD_GOD", MPI="FXD_MPI", KILL="FXD_KILL", MPSET="FXD_MPSET", NOCD="FXD_NOCD"}

-- fallback offsets (game v-current verified; used only when heuristic ambiguous)
local FB = {hp = 0x118, mana = 0x120}

local g_pid = nil
local g_timer = nil
local g_ctl = nil          -- control block in target (status byte)
local g_stopped = false
local g_fails = 0
local g_cls = {}           -- class pointers
local g_foff = {}          -- SaveData field offsets (name -> off)
local g_save = nil         -- primary SaveData instance
local g_save2 = nil        -- mirror instance
local g_player = nil
local g_gm, g_pcc = nil, nil
local g_hpOff, g_manaOff = nil, nil
local g_pccOff, g_plOff = nil, nil   -- cached chain offsets
local g_lastSaveScan = 0             -- throttle for save-instance rescans
local g_startedAt = nil               -- tool start time (skip heavy scans early)
local g_killList = {}                -- Enemy instances for one-hit-kill
local g_lastKillScan = 0             -- throttle for enemy rescan
local g_charOff = {}                 -- Character field offsets (BaseMoveSpeed etc)
local g_lastMs, g_lastAs = nil, nil  -- last applied setpoints
local g_godHP, g_godMP = nil, nil    -- locked values for god/mp
local g_godOn, g_mpOn, g_killOn = false, false, false
local g_noCDOn = false                    -- no-CD toggle
local g_fastTimer = nil               -- 60ms combat pin timer
local g_tmpMem = nil                 -- scratch memory for float<->bits
local g_tgtSnap = {}                 -- addr -> {t=TotalGameTime, c=os.clock()} for liveness
local g_savePicked = false           -- live instance confirmed by delta detection
local registerAll, resolveHpMana     -- forward declarations

local function log(msg)
  print("[DeskrawlYC v" .. VERSION .. "] " .. tostring(msg))
  pcall(function()
    local f = io.open(os.getenv("TEMP") .. "\\deskrawl_yc.log", "a")
    if f then f:write("[" .. os.date("%H:%M:%S") .. "] " .. tostring(msg) .. "\n") f:close() end
  end)
end
_G.FXD_STOP_ALL = _G.FXD_STOP_ALL or {}

local function rdq(a) local ok, v = pcall(readQword, a) if ok then return v end return nil end
local function rdi(a) local ok, v = pcall(readInteger, a) if ok then return v end return nil end
local function rds(a, n)
  if not a or a < 0x10000 then return nil end
  local ok, s = pcall(readString, a, n or 64, false)
  if ok then return s end
  return nil
end
local function klassName(k)
  if not k or k < 0x10000 then return nil end
  local s = rds(rdq(k + 0x10), 48)
  if s and s:match("^[%a_][%w_`%d]*$") then return s end
  return nil
end

local function unreg(sym) pcall(unregisterSymbol, sym) end
local function reg(sym, addr)
  if addr and addr > 0x10000 then
    pcall(registerSymbol, sym, string.format("%X", addr), true)
  else
    pcall(unregisterSymbol, sym)
  end
end


-- ---------------------------------------------------------------- ACTk codec
-- ObscuredInt: value = (hidden - key) ^ key        ; hidden = (value ^ key) + key
-- ObscuredFloat: bits = swap_b1_b2(hidden) ^ key   ; hidden = swap_b1_b2(bits ^ key)
-- hash = FNV'(value)|1 (basis 0x811C9DC6, prime 0x01000192); fake mirrors plaintext
local function actkHash(value)
  local b0 = value & 0xFF
  local b1 = (value >> 8) & 0xFF
  local b2 = (value >> 16) & 0xFF
  local b3 = (value >> 24) & 0xFF
  local h = b0 ~ 0x811C9DC6
  h = (h * 0x01000192) % 0x100000000
  h = h ~ b1
  h = (h * 0x01000192) % 0x100000000
  h = h ~ b2
  h = (h * 0x01000192) % 0x100000000
  h = h ~ b3
  h = (h * 0x01000192) % 0x100000000
  return (h | 1) % 0x100000000
end

local function bitsToF(bits)
  if not g_tmpMem then return nil end
  writeInteger(g_tmpMem, bits)
  local ok, v = pcall(readFloat, g_tmpMem)
  if ok then return v end
  return nil
end

local function fToBits(f)
  if not g_tmpMem then return nil end
  writeFloat(g_tmpMem, f)
  local ok, v = pcall(readInteger, g_tmpMem)
  if ok then return v end
  return nil
end

local function decObscuredFloat(addr)
  local hidden = rdi(addr + 4)
  local key = rdi(addr + 8)
  if not hidden or not key then return nil end
  local b = readBytes(addr + 4, 4, true)
  if not b then return nil end
  local swapped = b[4] * 0x1000000 + b[2] * 0x10000 + b[3] * 0x100 + b[1]
  local bits = swapped ~ key
  return bitsToF(bits)
end

local function encObscuredFloat(addr, value)
  local key = rdi(addr + 8)
  local bits = fToBits(value)
  if not key or not bits then return false end
  local x = bits ~ key
  local m0 = x & 0xFF
  local m1 = (x >> 8) & 0xFF
  local m2 = (x >> 16) & 0xFF
  local m3 = (x >> 24) & 0xFF
  writeBytes(addr + 4, m0, m2, m1, m3)          -- swap bytes 1,2
  writeInteger(addr, actkHash(bits))
  writeFloat(addr + 0xC, value)                  -- honeypot mirror
  return true
end

local function decObscuredInt(addr)
  local hidden = rdi(addr + 4)
  local key = rdi(addr + 8)
  if not hidden or not key then return nil end
  return toU(hidden - key) ~ key
end

local function encObscuredInt(addr, value)
  local key = rdi(addr + 8)
  if not key then return false end
  local v = value % 0x100000000
  writeInteger(addr + 4, (v ~ key) + key)
  writeInteger(addr, actkHash(v))
  writeInteger(addr + 0xC, v)
  return true
end

-- ---------------------------------------------------------------- class resolve
-- class pointer cache: resolveClasses walks ~2000 classes with one remote
-- call each (seconds). Class pointers are stable for a game process, so cache
-- them on disk keyed by the GameAssembly base address.
local function loadClassCache()
  local path = os.getenv("TEMP") .. "\\deskrawl_yc_klass.txt"
  local f = io.open(path, "r")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  if not line then return nil end
  local base, rest = line:match("^(%x+)%s+(.*)$")
  if not base then return nil end
  local modBase = getAddressSafe("GameAssembly.dll")
  if not modBase or tonumber(base, 16) ~= modBase then return nil end
  local map = {}
  for k, v in rest:gmatch("(%w+)=(%x+)") do map[k] = tonumber(v, 16) end
  -- spot-check: every cached pointer must still carry its class name
  for name, ptr in pairs(map) do
    if not ptr or ptr < 0x10000 then return nil end
    if rds(rdq(ptr + 0x10), 48) ~= name then return nil end
  end
  return map
end

local function saveClassCache()
  local path = os.getenv("TEMP") .. "\\deskrawl_yc_klass.txt"
  local modBase = getAddressSafe("GameAssembly.dll")
  if not modBase then return end
  local parts = {}
  for k, v in pairs(g_cls) do parts[#parts+1] = k .. "=" .. string.format("%X", v) end
  local f = io.open(path, "w")
  if f then
    f:write(string.format("%X %s\n", modBase, table.concat(parts, " ")))
    f:close()
  end
end

local function resolveClasses()
  local cached = loadClassCache()
  if cached and cached.Player and cached.GameManager and cached.SaveData
     and cached.Character and cached.PlayerCombatController and cached.Enemy then
    g_cls = cached
    return
  end
  local fnDomain = getAddress("GameAssembly.il2cpp_domain_get")
  local fnAsms = getAddress("GameAssembly.il2cpp_domain_get_assemblies")
  local fnCnt = getAddress("GameAssembly.il2cpp_image_get_class_count")
  local fnClass = getAddress("GameAssembly.il2cpp_image_get_class")
  if not (fnDomain and fnAsms and fnCnt and fnClass) then
    error("GameAssembly il2cpp exports not found (not an IL2CPP game?)")
  end
  local domain = executeCodeEx(0, 3000, fnDomain)
  if not domain or domain < 0x10000 then error("il2cpp_domain_get failed") end
  local sizeBuf = allocateMemory(8)
  local asms = executeCodeEx(0, 3000, fnAsms, domain, sizeBuf)
  local count = readInteger(sizeBuf) or 0
  pcall(deAllocMemory, sizeBuf)
  if not asms or asms < 0x10000 or count == 0 then error("domain_get_assemblies failed") end

  local acs = nil
  for i = 0, count - 1 do
    local aptr = rdq(asms + 8 * i)
    if aptr and aptr > 0x10000 then
      local image = rdq(aptr + 0)
      if image and image > 0x10000 then
        local s = rds(rdq(image + 0), 32)
        if s and s:sub(1, 19) == "Assembly-CSharp.dll" then acs = image break end
      end
    end
  end
  if not acs then error("Assembly-CSharp.dll not found") end

  local cnt = executeCodeEx(0, 3000, fnCnt, acs)
  if not cnt or cnt == 0 then error("image_get_class_count failed") end
  local want = {SaveData=1, GameManager=1, PlayerCombatController=1, Player=1,
    Character=1, Enemy=1}
  local found = {}
  for i = 0, cnt - 1 do
    local cls = executeCodeEx(0, 3000, fnClass, acs, i)
    if cls and cls > 0x10000 then
      local nm = rds(rdq(cls + 0x10), 64)
      if nm and want[nm] then found[nm] = cls end
    end
  end
  for k in pairs(want) do
    if not found[k] then error("class not found in Assembly-CSharp: " .. k) end
  end
  g_cls = found
  saveClassCache()
end

-- ---------------------------------------------------------------- field offsets
local function fieldOffsets(cls, names)
  local fnFields = getAddress("GameAssembly.il2cpp_class_get_fields")
  if not fnFields then error("il2cpp_class_get_fields missing") end
  local buf = allocateMemory(8)
  local map = {}
  if buf and buf > 0x10000 then
    writeQword(buf, 0)
    while true do
      local f = executeCodeEx(0, 3000, fnFields, cls, buf)
      if not f or f < 0x10000 then break end
      local nm = rds(rdq(f + 0), 80)
      local off = rdi(f + 0x18)
      if nm and off and names[nm] then map[nm] = off end
    end
    pcall(deAllocMemory, buf)
  end
  return map
end

-- ---------------------------------------------------------------- SaveData scan
local function validSave(a)
  if not a or a < 0x10000 then return false end
  if rdq(a + 0) ~= g_cls.SaveData then return false end
  local o = g_foff
  local lvl = rdi(a + o.Level)
  local maxhp = rdi(a + o.BaseMaxHealth)
  local hp = rdi(a + o.CurrentHP)
  local tal = rdi(a + o.TalentOutstandingPoints)
  local gold = rdi(a + o.TotalEarnedGold)
  if not (lvl and maxhp and hp and tal and gold) then return false end
  if lvl < 1 or lvl > 10000 then return false end
  if maxhp < 1 or maxhp > 10000000 then return false end
  if hp < 0 or hp > maxhp then return false end
  if tal < 0 or tal > 1000000 then return false end
  if gold < 0 or gold > 1000000000000 then return false end
  -- game time sanity: unix-timestamp-sized values are stale/dummy slots
  local gt = rdi(a + o.TotalGameTime)
  if not gt or gt < 0 or gt > 100000000 then return false end
  return true
end

local function findSaveInstances()
  local hx = string.format("%016X", g_cls.SaveData)
  local pat = {}
  for i = 8, 1, -1 do pat[#pat+1] = hx:sub(i * 2 - 1, i * 2) end
  local sl = AOBScan(table.concat(pat, " "), "+W-C")
  local res = {}
  if sl then
    for i = 0, sl.Count - 1 do
      local a = tonumber(sl[i], 16)
      if validSave(a) then res[#res+1] = a end
      if #res >= 4 then break end
    end
    sl.destroy()
  end
  -- initial pick: the one with the largest TotalGameTime is most likely the active slot
  if #res > 1 and g_foff.TotalGameTime then
    table.sort(res, function(a, b)
      return (rdi(a + g_foff.TotalGameTime) or 0) > (rdi(b + g_foff.TotalGameTime) or 0)
    end)
  end
  for _, a in ipairs(res) do
    g_tgtSnap[a] = {t = rdi(a + (g_foff.TotalGameTime or 0)), c = os.clock()}
  end
  return res
end

-- liveness: an instance whose TotalGameTime increases between ticks is the live one
local function detectLiveSave()
  if not g_foff.TotalGameTime then return end
  local now = os.clock()
  local live = nil
  for a, snap in pairs(g_tgtSnap) do
    local t = rdi(a + g_foff.TotalGameTime)
    if t and snap.t and t > snap.t then
      live = a
    end
    snap.t = t
    snap.c = now
  end
  if live then
    if live ~= g_save then
      log("live SaveData identified: " .. string.format("%X", live))
      g_save = live
      g_savePicked = true
      if g_player then g_hpOff, g_manaOff = resolveHpMana(g_save, g_player) end
      registerAll()
    else
      g_savePicked = true
    end
  end
end

-- ---------------------------------------------------------------- live chain
-- full resolve (start only): also caches chain offsets so tick never re-enumerates
local function resolveLive()
  local gmCls = g_cls.GameManager
  local sp = nil
  for off = 0x90, 0xE0, 8 do
    local p = rdq(gmCls + off)
    if p and p > 0x10000 then
      local inst = rdq(p + 0)
      if inst and inst > 0x10000 and rdq(inst + 0) == gmCls then sp = p break end
    end
  end
  if not sp then error("GameManager singleton (static) not found") end
  local gm = rdq(sp + 0)

  local gmF = fieldOffsets(gmCls, {PlayerCombatController = 1})
  local pccOff = gmF.PlayerCombatController
  if not pccOff or pccOff == 0 then error("GameManager.PlayerCombatController offset missing") end
  local pccF = fieldOffsets(g_cls.PlayerCombatController, {Player = 1})
  local plOff = pccF.Player
  if not plOff or plOff == 0 then error("PCC.Player offset missing") end
  g_pccOff, g_plOff = pccOff, plOff

  local pcc = rdq(gm + pccOff)
  if not pcc or pcc < 0x10000 or rdq(pcc + 0) ~= g_cls.PlayerCombatController then
    error("PlayerCombatController instance invalid (not in game yet?)")
  end
  local player = rdq(pcc + plOff)
  if not player or player < 0x10000 or rdq(player + 0) ~= g_cls.Player then
    error("Player instance invalid")
  end
  return gm, pcc, player
end

-- cheap revalidate (tick): uses cached offsets, no field enumeration
local function revalidateLive()
  if not (g_gm and g_pccOff and g_plOff) then return nil end
  local pcc = rdq(g_gm + g_pccOff)
  if not pcc or pcc < 0x10000 or rdq(pcc + 0) ~= g_cls.PlayerCombatController then return nil end
  local player = rdq(pcc + g_plOff)
  if not player or player < 0x10000 or rdq(player + 0) ~= g_cls.Player then return nil end
  return player
end


-- hp/mana offsets: plain-int heuristic inside Character tail region
function resolveHpMana(save, player)
  local o = g_foff
  local maxHP = rdi(save + o.BaseMaxHealth) or 0
  local maxMana = rdi(save + o.BaseMaxMana) or 0
  local cands = {}
  for off = 0x104, 0x134, 4 do
    local v = rdi(player + off)
    if v and v > 0 and v <= math.max(maxHP, maxMana) then
      cands[#cands+1] = {off = off, v = v}
    end
  end
  local manaOff, hpOff = nil, nil
  for _, c in ipairs(cands) do
    if c.v == maxMana and maxMana ~= maxHP then manaOff = c.off break end
  end
  for _, c in ipairs(cands) do
    if c.off ~= manaOff and c.v <= maxHP then hpOff = c.off break end
  end
  if not hpOff then hpOff = FB.hp end
  if not manaOff then manaOff = FB.mana end
  if hpOff == manaOff then
    -- ambiguous (e.g. maxHP == maxMana or wrong save context): fall back to verified layout
    hpOff, manaOff = FB.hp, FB.mana
  end
  return hpOff, manaOff
end

-- scan all live Enemy instances (klass header match + sane HP) for one-hit-kill
local function refreshKillList()
  if not g_cls.Enemy then return nil end
  local hx = string.format("%016X", g_cls.Enemy)
  local pat = {}
  for i = 8, 1, -1 do pat[#pat+1] = hx:sub(i * 2 - 1, i * 2) end
  local sl = AOBScan(table.concat(pat, " "), "+W-C")
  local res = {}
  if sl then
    for i = 0, sl.Count - 1 do
      local a = tonumber(sl[i], 16)
      if a and a ~= g_player and rdq(a + 0) == g_cls.Enemy then
        local hp = rdi(a + (g_hpOff or FB.hp))
        if hp and hp >= 0 and hp < 10000000 then res[#res+1] = a end
        if #res >= 64 then break end
      end
    end
    sl.destroy()
  end
  return res
end

-- ---------------------------------------------------------------- entries
local ENTRIES = {
  {t = "header", d = "═══ 挂机破坏神 辅助脚本 —— 角色状态 + 数值修改 ═══"},
  {t = "note",   d = "    作者 YC      版本 v" .. VERSION .. "      适用 Deskrawl.exe（Unity IL2CPP） / CE 7.5+"},
  {t = "note",   d = "    用法：附加 Deskrawl.exe → 勾选最上面的 [★0]（进游戏读档后再勾更佳）"},
  {t = "note",   d = "    ② 「实时数据」直接读写内存，改动立即生效"},
  {t = "note",   d = "    ③ 「存档数据」显示 ?? 属正常：存档对象只在读档/存档瞬间存在，勾一次 [★21] 扫描存档即可读出"},
  {t = "note",   d = "    ④ 属性/战斗/金币类开关直接改写加密字段（已破解 ACTk 算法）；填 0 或取消勾选即还原"},
  {t = "header", d = "────────── 实时数据（[3] 金币需勾 [★G0] 金币模块）──────────"},
  {t = "value",  d = "[1] 当前生命", sym = SYM.HP, vt = vtDword},
  {t = "value",  d = "[2] 当前法力", sym = SYM.MANA, vt = vtDword},
  {t = "header", d = "────────── 存档数据（显示 ?? 时勾 [★21] 扫描存档）──────────"},
  {t = "value",  d = "[4] 等级", sym = SYM.LEVEL, vt = vtDword},
  {t = "value",  d = "[5] 当前经验", sym = SYM.XP, vt = vtDword},
  {t = "value",  d = "[6] 最大生命（基础）", sym = SYM.MAXHP, vt = vtDword},
  {t = "value",  d = "[7] 基础伤害", sym = SYM.DMG, vt = vtDword},
  {t = "value",  d = "[8] 最大法力（基础）", sym = SYM.MAXMANA, vt = vtDword},
  {t = "value",  d = "[9] 主属性（智力/力量）", sym = SYM.PSTAT, vt = vtSingle},
  {t = "value",  d = "[10] 可用天赋点", sym = SYM.TALENT, vt = vtDword},
  {t = "header", d = "────────── 属性修改（立即生效）──────────"},
  {t = "value",  d = "[★12] 移动速度设定（默认 8，0=不修改）", sym = SYM.MSSET, vt = vtSingle},
  {t = "value",  d = "[13] 移动速度当前值", sym = SYM.MSSHOW, vt = vtSingle},
  {t = "value",  d = "[★14] 攻击速度设定（默认 2，0=不修改）", sym = SYM.ASSET, vt = vtSingle},
  {t = "value",  d = "[15] 攻击速度当前值", sym = SYM.ASSHOW, vt = vtSingle},
  {t = "header", d = "────────── 战斗开关（进入战斗后勾选）──────────"},
  {t = "value",  d = "[★16] 锁血（1=开，0=关）", sym = SYM.GOD, vt = vtByte},
  {t = "value",  d = "[★17] MP 无限（1=开，0=关）", sym = SYM.MPI, vt = vtByte},
  {t = "value",  d = "[★17s] MP 设定值（默认 100，0=自动棘轮）", sym = SYM.MPSET, vt = vtDword},
  {t = "value",  d = "[★18] 一击必杀（1=开，0=关）", sym = SYM.KILL, vt = vtByte},
  {t = "value",  d = "[★19] 无CD（1=开，0=关）", sym = SYM.NOCD, vt = vtByte},
  {t = "value",  d = "[★21] 扫描存档（勾一下等数秒；存档对象为瞬态，平时可能搜不到）", sym = SYM.SAVESCAN, vt = vtByte},
  {t = "header", d = "────────── 脚本状态 ──────────"},
  {t = "value",  d = "[★0] 主脚本运行状态（1=运行 2=就绪 3=失联重试）", sym = SYM.CTL, vt = vtByte},
}

local function deleteOwnEntries()
  local al = getAddressList()
  for i = al.Count - 1, 0, -1 do
    local mr = al.getMemoryRecord(i)
    local d = mr.Description
    if d then
      for _, e in ipairs(ENTRIES) do
        if d == e.d then
          memoryrecord_delete(mr)
          break
        end
      end
    end
  end
end

local function buildEntries()
  deleteOwnEntries()
  local al = getAddressList()
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

-- ---------------------------------------------------------------- register
function registerAll()
  reg(SYM.GM, g_gm)
  reg(SYM.PCC, g_pcc)
  reg(SYM.PLAYER, g_player)
  reg(SYM.SAVE, g_save)
  reg(SYM.SAVE2, g_save2)
  reg(SYM.CTL, g_ctl)
  if g_ctl then
    reg(SYM.MSSET, g_ctl + 4)
    reg(SYM.ASSET, g_ctl + 8)
    reg(SYM.MSSHOW, g_ctl + 12)
    reg(SYM.ASSHOW, g_ctl + 16)
    reg(SYM.GOD, g_ctl + 28)
    reg(SYM.MPI, g_ctl + 32)
    reg(SYM.KILL, g_ctl + 36)
    reg(SYM.MPSET, g_ctl + 40)
    reg(SYM.NOCD, g_ctl + 44)
    reg(SYM.SAVESCAN, g_ctl + 52)
  end
  local o = g_foff
  if g_player and g_hpOff then reg(SYM.HP, g_player + g_hpOff) else unreg(SYM.HP) end
  if g_player and g_manaOff then reg(SYM.MANA, g_player + g_manaOff) else unreg(SYM.MANA) end
  if g_save and o.Level then reg(SYM.LEVEL, g_save + o.Level) else unreg(SYM.LEVEL) end
  if g_save and o.CurrentXP then reg(SYM.XP, g_save + o.CurrentXP) else unreg(SYM.XP) end
  if g_save and o.BaseMaxHealth then reg(SYM.MAXHP, g_save + o.BaseMaxHealth) else unreg(SYM.MAXHP) end
  if g_save and o.BaseDamage then reg(SYM.DMG, g_save + o.BaseDamage) else unreg(SYM.DMG) end
  if g_save and o.BaseMaxMana then reg(SYM.MAXMANA, g_save + o.BaseMaxMana) else unreg(SYM.MAXMANA) end
  if g_save and o.BasePrimaryStat then reg(SYM.PSTAT, g_save + o.BasePrimaryStat) else unreg(SYM.PSTAT) end
  if g_save and o.TalentOutstandingPoints then reg(SYM.TALENT, g_save + o.TalentOutstandingPoints) else unreg(SYM.TALENT) end
end

-- ---------------------------------------------------------------- tick
local SYNC_FIELDS = {"Level", "CurrentXP", "BaseMaxHealth", "BaseDamage",
  "BaseMaxMana", "BasePrimaryStat", "TalentOutstandingPoints", "TotalEarnedGold"}

local function tick()
  if g_stopped then return end
  if getOpenedProcessID() ~= g_pid then
    -- game restarted: stop silently
    g_fails = g_fails + 1
    if g_fails > 3 then
      log("target process changed, auto stop")
      stopTool()
    end
    return
  end
  local status = 1
  -- validate player chain (cheap revalidate first, full resolve as fallback)
  local okPlayer = g_player and rdq(g_player + 0) == g_cls.Player
  if not okPlayer then
    local player = revalidateLive()
    if player then
      g_player = player
      okPlayer = true
    elseif os.clock() - (g_lastLiveTry or 0) > 3 then
      g_lastLiveTry = os.clock()
      local ok, gm, pcc, pl = pcall(resolveLive)
      if ok then
        g_gm, g_pcc, g_player = gm, pcc, pl
        if g_save then g_hpOff, g_manaOff = resolveHpMana(g_save, g_player) end
        reg(SYM.GM, g_gm) reg(SYM.PCC, g_pcc) reg(SYM.PLAYER, g_player)
        reg(SYM.HP, g_player + (g_hpOff or FB.hp))
        reg(SYM.MANA, g_player + (g_manaOff or FB.mana))
        okPlayer = true
      else
        status = 3
      end
    else
      status = 3
    end
  end
  -- validate save: NEVER auto-scan (full-memory AOB = ~15 s on a 16 GB
  -- process and it would stall CE every few seconds). Rescanning happens
  -- only when the user ticks [★21] 扫描存档 (handled further below).
  local okSave = g_save and validSave(g_save)
  if not okSave then
    if (rdi(g_ctl + 52) or 0) == 1 and os.clock() - g_lastSaveScan > 5 then
      g_lastSaveScan = os.clock()
      local list = findSaveInstances()
      if list[1] then
        g_save = list[1]
        g_save2 = nil
        for _, a in ipairs(list) do
          if a ~= g_save then
            -- same-slot mirror candidate: same level/xp/gold
            if rdi(a + g_foff.Level) == rdi(g_save + g_foff.Level)
               and rdi(a + g_foff.CurrentXP) == rdi(g_save + g_foff.CurrentXP)
               and rdi(a + g_foff.TotalEarnedGold) == rdi(g_save + g_foff.TotalEarnedGold) then
              g_save2 = a
            end
          end
        end
        if g_player then g_hpOff, g_manaOff = resolveHpMana(g_save, g_player) end
        registerAll()
        okSave = true
      else
        status = 2
      end
    else
      status = 2
    end
  end
  if okSave then
    -- refresh snapshots for liveness detection
    local t = rdi(g_save + g_foff.TotalGameTime)
    local snap = g_tgtSnap[g_save] or {}
    snap.t, snap.c = t, os.clock()
    g_tgtSnap[g_save] = snap
    detectLiveSave()
  end
  -- mirror primary -> secondary (only if still the same slot)
  if okSave and g_save2 and validSave(g_save2) then
    local o = g_foff
    if rdi(g_save2 + o.Level) == rdi(g_save + o.Level)
       and rdi(g_save2 + o.CurrentXP) == rdi(g_save + o.CurrentXP) then
      for _, k in ipairs(SYNC_FIELDS) do
        local off = o[k]
        if off then
          local v = readInteger(g_save + off)
          if v then writeInteger(g_save2 + off, v) end
        end
      end
    end
  end
  -- setpoints: apply changed values to encrypted Character fields
  if g_player and rdq(g_player + 0) == g_cls.Player and g_tmpMem then
    local function applyFloat(fieldOff, setOff, lastVar, origVar, showOff)
      local sp = readFloat(g_ctl + setOff)
      local last = _G[lastVar]
      if sp and sp > 0 and sp < 100000 then
        -- capture original on first apply (revert anchor)
        if not _G[origVar] then
          _G[origVar] = decObscuredFloat(g_player + fieldOff)
        end
        if not last or math.abs(sp - last) > 0.0001 then
          encObscuredFloat(g_player + fieldOff, sp)
          _G[lastVar] = sp
        end
      elseif sp and sp == 0 and last and last > 0 then
        -- setpoint 0 = revert to original captured value
        local orig = _G[origVar]
        if orig and orig > 0 then
          encObscuredFloat(g_player + fieldOff, orig)
        end
        _G[lastVar] = nil
        _G[origVar] = nil
      end
      local cur = decObscuredFloat(g_player + fieldOff)
      if cur then writeFloat(g_ctl + showOff, cur) end
    end
    if g_charOff.BaseMoveSpeed then
      applyFloat(g_charOff.BaseMoveSpeed, 4, "FXD_LASTMS", "FXD_ORIG_MS", 12)
    end
    if g_charOff.BaseAttackSpeed then
      applyFloat(g_charOff.BaseAttackSpeed, 8, "FXD_LASTAS", "FXD_ORIG_AS", 16)
    end
  end
  -- battle toggles: edge detection only (pins run in the 60ms fast timer)
  if g_player and rdq(g_player + 0) == g_cls.Player then
    local god = rdi(g_ctl + 28) or 0
    local mpi = rdi(g_ctl + 32) or 0
    local kill = rdi(g_ctl + 36) or 0
    if god == 1 and not g_godOn then
      g_godOn = true
      g_godHP = rdi(g_player + (g_hpOff or FB.hp))
    elseif god == 0 and g_godOn then
      g_godOn = false
      g_godHP = nil
    end
    if mpi == 1 and not g_mpOn then
      g_mpOn = true
      g_godMP = rdi(g_player + (g_manaOff or FB.mana))
    elseif mpi == 0 and g_mpOn then
      g_mpOn = false
      g_godMP = nil
    end
    if kill == 1 and not g_killOn then
      g_killOn = true
    elseif kill == 0 and g_killOn then
      g_killOn = false
    end
  end
  -- no-CD toggle (independent of player validity)
  do
    local ncd = g_ctl and (rdi(g_ctl + 44) or 0) or 0
    if ncd == 1 and not g_noCDOn then
      g_noCDOn = true
    elseif ncd == 0 and g_noCDOn then
      g_noCDOn = false
    end
  end

  -- SaveData instances: FULL-MEMORY AOB (seconds on a 16GB process) ->
  -- user-triggered only via [★21] 扫描存档 (ctl+52), then auto-off.
  local wantSave = rdi(g_ctl + 52) or 0
  if wantSave == 1 and os.clock() - g_lastSaveScan > 5 then
    g_lastSaveScan = os.clock()
    writeInteger(g_ctl + 52, 0)
    local list = findSaveInstances()
    if list[1] then
      g_save, g_save2 = list[1], list[2]
      registerAll()
    end
  end

  -- one-hit-kill: throttled full-enemy rescan while enabled
  if g_killOn and os.clock() - g_lastKillScan > 30 then
    g_lastKillScan = os.clock()
    local okK, list = pcall(refreshKillList)
    if okK and list then g_killList = list end
  end

  if g_ctl then writeBytes(g_ctl, status) end
end

-- ---------------------------------------------------------------- start/stop
-- NOTE: must stay LOCAL. A global stopper gets overwritten by the next CT
-- load, so old instances' auto-stop would kill the NEW instance instead of
-- themselves (seen live: zombies deleting fresh entries every second).
local function stopTool()
  g_stopped = true
  if g_timer then
    local t = g_timer
    g_timer = nil
    t.destroy()
  end
  if g_fastTimer then
    local t = g_fastTimer
    g_fastTimer = nil
    t.destroy()
  end
  deleteOwnEntries()
  for _, k in pairs(SYM) do pcall(unregisterSymbol, k) end
  if g_ctl then pcall(deAllocMemory, g_ctl) g_ctl = nil end
  g_save, g_save2, g_player, g_gm, g_pcc = nil, nil, nil, nil, nil
  g_lastMs, g_lastAs = nil, nil
  g_godHP, g_godMP = nil, nil
  g_godOn, g_mpOn, g_killOn, g_noCDOn = false, false, false, false
  -- revert modified base stats on stop (一键还原)
  pcall(function()
    local player = g_player
    if not player then return end
    if _G.FXD_ORIG_MS and g_charOff.BaseMoveSpeed then
      encObscuredFloat(player + g_charOff.BaseMoveSpeed, _G.FXD_ORIG_MS)
    end
    if _G.FXD_ORIG_AS and g_charOff.BaseAttackSpeed then
      encObscuredFloat(player + g_charOff.BaseAttackSpeed, _G.FXD_ORIG_AS)
    end
    _G.FXD_ORIG_MS, _G.FXD_ORIG_AS = nil, nil
    _G.FXD_LASTMS, _G.FXD_LASTAS = nil, nil
  end)
  g_tgtSnap = {}
  g_savePicked = false
  log("stopped, entries removed")
end

local function startTool()
  -- stop leftovers from any previous load of this tool
  for _, fn in ipairs(_G.FXD_STOP_ALL) do pcall(fn) end
  _G.FXD_STOP_ALL = {}
  if g_timer or g_fastTimer then return end  -- already running
  g_stopped = false
  g_fails = 0
  g_pid = getOpenedProcessID()
  g_startedAt = os.clock()
  if not g_pid or g_pid == 0 then error("no process attached") end

  -- clean leftovers from a previous run
  deleteOwnEntries()
  for _, k in pairs(SYM) do pcall(unregisterSymbol, k) end

  resolveClasses()

  -- SaveData field offsets (all resolved by name, no hardcoding)
  local need = {"Level", "CurrentXP", "BaseMaxHealth", "BaseDamage", "CurrentHP",
    "BaseMaxMana", "CurrentMana", "BasePrimaryStat", "TalentOutstandingPoints",
    "TotalEarnedGold", "TotalGameTime"}
  local want = {}
  for _, k in ipairs(need) do want[k] = 1 end
  g_foff = fieldOffsets(g_cls.SaveData, want)
  for _, k in ipairs(need) do
    if not g_foff[k] then error("SaveData field offset missing: " .. k) end
  end

  -- Character field offsets (encrypted base stats)
  local cneed = {BaseMoveSpeed = 1, BaseAttackSpeed = 1}
  g_charOff = fieldOffsets(g_cls.Character, cneed)
  for k in pairs(cneed) do
    if not g_charOff[k] then error("Character field offset missing: " .. k) end
  end

  -- NOTE: SaveData instance scan is a full-memory AOB (1-3s) and usually
  -- finds nothing at the main menu -> deferred to the slow tick.

  -- live chain (soft: may not exist at main menu)
  local okLive, gm, pcc, player = pcall(resolveLive)
  if okLive then
    g_gm, g_pcc, g_player = gm, pcc, player
  end

  -- hp/mana offsets
  if g_save and g_player then
    g_hpOff, g_manaOff = resolveHpMana(g_save, g_player)
  else
    g_hpOff, g_manaOff = FB.hp, FB.mana
  end

  -- control block: status@0 msset@4 asset@8 msshow@12 asshow@16 lastms@20 lastas@24
  --                god@28 mpi@32 kill@36
  g_ctl = allocateMemory(64)
  -- allocateMemory returns DIRTY memory: zero the WHOLE block, otherwise the
  -- toggle/setpoint slots (god@28 mpi@32 kill@36 mpset@40 nocd@44 save@52)
  -- may start non-zero and fire heavy work (gold sweep) on the very first tick.
  if g_ctl then
    for i = 0, 7 do writeQword(g_ctl + i * 8, 0) end
    -- sensible defaults so users can just tick the checkbox
    writeFloat(g_ctl + 4, 8)     -- [★12] move speed setpoint
    writeFloat(g_ctl + 8, 2)     -- [★14] attack speed setpoint
    writeInteger(g_ctl + 40, 100) -- [★17s] MP lock value
  end
  g_tmpMem = allocateMemory(16)

  registerAll()
  buildEntries()

  -- worker timer (locked pid, soft-retry, self-stop on hard failure)
  g_timer = createTimer(nil, false)
  g_timer.Interval = 1000
  g_timer.OnTimer = function()
    if g_stopped then return end
    local ok, err = pcall(tick)
    if not ok then
      g_fails = g_fails + 1
      if g_fails % 5 == 1 then log("tick error: " .. tostring(err)) end
      if g_fails > 30 then
        log("too many tick errors, auto stop")
        stopTool()
      end
    end
  end
  g_timer.Enabled = true

  -- fast timer: combat pins every 60 ms (1s tick too coarse for real-time combat)
  g_fastTimer = createTimer(nil, false)
  g_fastTimer.Interval = 60
  g_fastTimer.OnTimer = function()
    if g_stopped then return end
    if getOpenedProcessID() ~= g_pid then return end
    if not (g_godOn or g_mpOn or g_killOn or g_noCDOn) then return end
    -- no-CD: zero GCD + skill CD + state timer (works even without player pin)
    if g_noCDOn and g_pcc and rdq(g_pcc + 0) == g_cls.PlayerCombatController then
      local pac = rdq(g_pcc + 0x70)
      if pac and pac > 0x10000 then
        pcall(writeFloat, pac + 0x68, 0)   -- GCD remaining
        pcall(writeFloat, pac + 0xB4, 0)   -- skill CD remaining
        local o = rdq(pac + 0x60)
        if o and o > 0x10000 then
          pcall(writeFloat, o + 0x24, 0)   -- cast state timer
        end
      end
    end
    if not g_player then return end
    -- revalidate player cheaply
    if rdq(g_player + 0) ~= g_cls.Player then return end
    -- ratchet: lock value only rises (peak tracking), so MP climbs to max
    -- and god locks the highest HP seen instead of the value at toggle time
    if g_godOn then
      local cur = rdi(g_player + (g_hpOff or FB.hp))
      if cur and cur > (g_godHP or 0) then g_godHP = cur end
      if g_godHP and g_godHP > 0 then
        writeInteger(g_player + (g_hpOff or FB.hp), g_godHP)
      end
    end
    if g_mpOn then
      local sp = g_ctl and (rdi(g_ctl + 40) or 0) or 0
      if sp > 0 then
        g_godMP = sp  -- explicit setpoint wins over ratchet
      else
        local cur = rdi(g_player + (g_manaOff or FB.mana))
        if cur and cur > (g_godMP or 0) then g_godMP = cur end
      end
      if g_godMP and g_godMP > 0 then
        writeInteger(g_player + (g_manaOff or FB.mana), g_godMP)
      end
    end
    if g_killOn and g_gm then
      local pcc2 = rdq(g_gm + g_pccOff)
      if pcc2 and pcc2 > 0x10000 then
        local e = rdq(pcc2 + 0x40)
        if e and e > 0x10000 and rdq(e + 0) == g_cls.Enemy then
          local hp = rdi(e + (g_hpOff or FB.hp))
          if hp and hp > 1 then writeInteger(e + (g_hpOff or FB.hp), 1) end
        end
      end
      local wm = rdq(g_gm + 0x68)
      if wm and wm > 0x10000 then
        local e2 = rdq(wm + 0xC0)
        if e2 and e2 > 0x10000 and rdq(e2 + 0) == g_cls.Enemy then
          local hp2 = rdi(e2 + (g_hpOff or FB.hp))
          if hp2 and hp2 > 1 then writeInteger(e2 + (g_hpOff or FB.hp), 1) end
        end
      end
      -- full enemy list (refreshed every 2s by slow tick)
      for i = 1, #g_killList do
        local e3 = g_killList[i]
        if e3 and rdq(e3 + 0) == g_cls.Enemy then
          local hp3 = rdi(e3 + (g_hpOff or FB.hp))
          if hp3 and hp3 > 1 then writeInteger(e3 + (g_hpOff or FB.hp), 1) end
        end
      end
    end
  end
  g_fastTimer.Enabled = true

  log("v" .. VERSION .. " ready"
    .. " | save=" .. (g_save and string.format("%X", g_save) or "menu?")
    .. " | player=" .. (g_player and string.format("%X", g_player) or "menu?")
    .. " | hpOff=" .. string.format("%X", g_hpOff or 0)
    .. " manaOff=" .. string.format("%X", g_manaOff or 0))
  table.insert(_G.FXD_STOP_ALL, function() if g_timer or g_ctl then stopTool() end end)
end

-- entry point (called from [ENABLE])
local ok, err = pcall(function()
  if g_timer then stopTool() end
  startTool()
end)
if not ok then
  log("init FAILED: " .. tostring(err))
  log("make sure Deskrawl.exe is attached and a save is loaded")
  if g_timer then stopTool() else
    deleteOwnEntries()
    for _, k in pairs(SYM) do pcall(unregisterSymbol, k) end
  end
end

-- public stopper (unique name: old zombie instances from earlier CT loads may
-- still call the old global name; that one is a deliberate no-op so they can
-- only "shoot blanks" instead of killing the running instance)
_G.Deskrawl_Stop = stopTool
_G.StopDeskrawlTool = function() end
