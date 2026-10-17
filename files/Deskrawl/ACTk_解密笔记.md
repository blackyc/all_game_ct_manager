# 挂机破坏神（Idle Diablo / Deskrawl.exe）ACTk 加密破解笔记

作者:**YC**　日期:2026-10-16 / 10-17 增补　适用:ACTk (CodeStage Anti-Cheat Toolkit) 2.x + Unity IL2CPP

本文记录在本作中完全破解 ACTk 2.x 内存加密的完整过程:结构布局、加解密算法、
校验 hash 算法、写入流程,以及定位方法(可复用到任何使用 ACTk 的 Unity 游戏)。
配套可运行的 Lua 实现见同目录 `Deskrawl_YC_tool.lua`。

---

## 一、识别 ACTk 与加密字段

1. 游戏模块列表出现 `ACTk.Runtime.dll`(或 Assembly-CSharp 内嵌)。
2. 内存里"该是数值的地方"读到高熵垃圾:
   - int 位置读出 0x5F05CAEB 之类的"随机"值
   - float 位置读出 1e±30 / -9.8e+15 之类的乱数
3. 但同一个对象里**部分字段是明文**(本作:当前生命/当前法力明文,基础属性密文)
   ——这是 ACTk 的典型使用方式:只加密长期存活的字段,短期运算用普通类型。

## 二、定位加密类型定义(运行期,不写死)

通过 il2cpp 导出函数枚举 `ACTk.Runtime.dll` 的 148 个类,核心类型名是干净的:

```
ObscuredInt / ObscuredFloat / ObscuredLong / ObscuredDouble / ObscuredBool ...
FloatIntBytesUnion / DoubleLongBytesUnion / ACTkByte4 / ACTkByte8 / ACTkByte16
ObscuredCheatingDetector / InjectionDetector / SpeedHackDetector ...
```

内部方法名被混淆(kej/kek/kez/kcv...),但 **`op_Implicit` 隐式转换算子不能改名**
——它就是解密/加密入口,是整个破解的抓手。

## 三、结构布局(实测,64 位 IL2CPP)

### ObscuredFloat(20 字节,内联在宿主对象的字段位置)

| 偏移 | 大小 | 字段 | 说明 |
|---|---|---|---|
| +0x00 | 4 | hash | 完整性校验 = FNV'(明文 bits) \| 1 |
| +0x04 | 4 | hiddenValue (ACTkByte4) | 加密后的 float bits |
| +0x08 | 4 | currentCryptoKey | 每实例随机密钥 |
| +0x0C | 4 | fakeValue | 蜜罐:存明文副本,用于篡改检测 |
| +0x10 | 1 | hiddenValueOldByte4 | 遗留字节,置 0 |

### ObscuredInt(16 字节)

| 偏移 | 大小 | 字段 |
|---|---|---|
| +0x00 | 4 | hash |
| +0x04 | 4 | hiddenValue |
| +0x08 | 4 | currentCryptoKey |
| +0x0C | 4 | fakeValue |

### ObscuredLong / ObscuredDouble(32 字节,ACTkByte8)

| 偏移 | 大小 | 字段 | 说明 |
|---|---|---|---|
| +0x00 | 4 | hash | 完整性校验(算法见下,8 字节版仍未还原) |
| +0x04 | 4 | pad | 恒 0 |
| +0x08 | 8 | hiddenValue (ACTkByte8) | 加密后的 64 位值 |
| +0x10 | 8 | currentCryptoKey | 每实例随机 64 位密钥 |
| +0x18 | 8 | fakeValue | **实测恒 0**——Long/Double 的蜜罐未启用 |

### 已破解:ObscuredLong 的 8 字节 detour(2026-10-17)

```
明文 value = (hidden - key) XOR key          ; 64 位无符号运算 (mod 2^64)
加密 hidden = (value XOR key) + key          ; 与 4 字节 Int 完全同形!
```

验证:BaseMaxMana@D8 解出**恰好 100** = 面板最大法力 100。
其余 BaseMaxHealth / 交易金币等 64 位字段同构。

**8 字节 hash 算法仍未还原**(4 字节 FNV 循环的 8 字节扩展版,
sweep 了 basis/prime/字节序组合均不中,存的是 0xDA03B3E9 这样的值)。
影响:无法用 hash-hunt 定位 Long 字段,定位靠结构遍历或差分;
写入时保留原 hash 即可——**ACTk 只在读取时校验 hash 是否与明文匹配,
不重算的话把原 hash 原样留着也能过**(前提:明文写入后游戏会用它重算并覆盖 hash,
或该字段未启用校验,写入后观察即可)。

## 四、加解密算法(反汇编 op_Implicit 核心函数得出)

### ObscuredInt

```
明文 value = (hidden - key) XOR key          ; 32 位无符号运算
加密 hidden = (value XOR key) + key
```

### ObscuredFloat

```
bits = swap_bytes_1_2(hidden) XOR key        ; hidden 的第 1、2 字节(0 起)互换后按
明文 float = bits 解释为 float                ; 小端序与 key 异或
加密 hidden = swap_bytes_1_2(bits XOR key)    ; 交换是自反运算,加解密同形
```

### 校验 hash(FNV-1a 变体,常数被 ACTk 改过 ±1)

```
b0..b3 = value 的 4 个字节(小端序)
h  = b0 XOR 0x811C9DC6                    ; FNV offset basis + 1
h  = (h * 0x01000192) XOR b1              ; 0x01000192 = FNV prime - 1
h  = (h * 0x01000192) XOR b2
h  = (h * 0x01000192) XOR b3
h  = (h * 0x01000192)
hash = h | 1                              ; 强制 bit0=1
```

### 写入流程(绕过蜜罐检测)

1. `hidden' = 加密(newValue, 保留原 key)` —— 不改 key,免得游戏侧失配
2. `hash' = actkHash(newValue)`
3. `fakeValue' = newValue` —— 蜜罐同步,检测分支直接跳过
4. hiddenValueOldByte4 保持 0

三处不同步任何一个都会触发 ObscuredCheatingDetector(本作为单机老版本未启用回调,
但正确写法可以通吃所有 ACTk 游戏)。

## 五、实测验证数据

| 字段 | 密文 hidden | key | 解密值 | 期望 |
|---|---|---|---|---|
| _level | 0xD440DB58 | 0x6A206DAA | 4 | 等级 4 ✓ |
| BaseMoveSpeed | 0x3BA01F85 | 0x7B5FA085 | 3.0 | 面板 3.2(基础+加成) ✓ |
| BaseCritChance | 0x599A1318 | 0x645F56D5 | 0.05 | 暴击几率 5% ✓ |
| BaseCritDamage | 0x0461FA59 | 0x3BA1FA59 | 1.5 | 暴击伤害 150% ✓ |
| BasePrimaryStat | 0x00212695 | 0x41062195 | 10.0 | 智力 15(基础 10+装备 5) ✓ |

写入回读:移速 3.0 → 6.0,解密回显 6.0,hash 一致,游戏内生效 ✓

## 六、已破解范围与未完成

- ✅ ObscuredInt / ObscuredFloat:完整读写(CT 里 [★12] 移动速度 / [★14] 攻击速度)
- ✅ ObscuredLong/Double(ACTkByte8):detour 已破解(见第三节),
  BaseMaxHealth/BaseMaxMana 等 64 位字段可解密;写入时保留原 hash
- ✅ **紧凑版 ObscuredInt(8 字节,无 hash/fake)** —— 本作金币钱包用的就是它:
  `hidden@X, key@X+4`,detour 与 4 字节同款。定位法见第十一节
- ⬜ 8 字节版 hash 算法(反汇编定位见下,写入暂不需要——游戏自己重算)
- ⬜ ObscuredString:byte[] 引用型,另一套

### 6.1 hash 例程的二进制定位法(通用)

ACTk 的 hash 是 FNV 变体,乘数常数 `0x01000192` 以 `imul r32, imm32`
(`69 C0 92 01 00 01`)形式出现在代码里——**扫这个立即数,10 处以内即是全部候选**,
反汇编即可读出算法。4 字节版结构与本文第四节完全一致;8 字节候选例程是
两条独立 4 字节链,尾声 `xor r8d, eax`(形式 `(FNV4(low)>>2) ^ ((FNV4(high)*P)|1)`),
但与本作活体样本不符(可能属于别的 ACTk 类型),**故 8 字节 hash 仍未最终确认**。

黑盒 sweep(500+ 常数/顺序/字节序组合)全灭后直接上反汇编才拿到确定信息——
遇到"看起来是 FNV 但怎么试都不对"时,别继续猜,去扫常数立即数。

## 七、定位方法(通用流程,换游戏可复用)

1. il2cpp 域 → 程序集 → `ACTk.Runtime.dll` → 按类名拿到 ObscuredXxx 类指针
2. 枚举方法找 `op_Implicit`(每个类型两个:明文→密文、密文→明文)
3. 解密版 op_Implicit 是个短包装:`sub rsp,28; xor edx,edx; call <core>; add rsp,28; ret`
   ——第二个指令是 `xor edx,edx` 是它的特征
4. 反汇编 core:
   - Int 版:`mov edi,[rbx+04]; sub edi,[rbx+08]; xor edi,[rbx+08]` 开头
   - Float 版:对 [rbx+04] 做 `movzx ecx,byte [rsp+A1] / mov [rsp+A1],al` 字节交换
   - 两版尾部都是同一个 FNV 变体 hash 循环(常数 0x811C9DC6 / 0x01000192)
5. 用已知明文(角色面板数值)验证算法,再实现加密(逆运算)
6. **不要用 runtime_invoke 从外部线程调游戏函数**——GC 线程表会崩游戏
   (本作实测崩溃一次),纯算法实现零风险

## 八、Lua 参考实现(节选自 Deskrawl_YC_tool.lua,完整版见同目录)

```lua
-- ObscuredFloat 解密
local function decObscuredFloat(addr)
  local b = readBytes(addr + 4, 4, true)          -- hidden 4 字节
  local swapped = b[4]*0x1000000 + b[2]*0x10000 + b[3]*0x100 + b[1]  -- 交换 b1/b2
  local key = readInteger(addr + 8)
  local bits = swapped ~ key
  writeInteger(tmp, bits)                          -- bits -> float
  return readFloat(tmp)
end

-- ObscuredFloat 加密写回
local function encObscuredFloat(addr, value)
  local key = readInteger(addr + 8)
  writeFloat(tmp, value)
  local bits = readInteger(tmp)
  local x = bits ~ key
  writeBytes(addr + 4, x & 0xFF, (x >> 16) & 0xFF, (x >> 8) & 0xFF, (x >> 24) & 0xFF)
  writeInteger(addr, actkHash(bits))
  writeFloat(addr + 0xC, value)
end

-- ObscuredInt 解密
local function decObscuredInt(addr)
  local hidden = readInteger(addr + 4)
  local key = readInteger(addr + 8)
  return (hidden - key) % 0x100000000 ~ key
end
```

## 九、本作数据位置速查

| 数据 | 位置 | 类型 | 明文? |
|---|---|---|---|
| 当前生命 | Player(基类 Character)+0x118 | int | ✅ |
| 当前法力 | Player+0x120 | int | ✅ |
| 移动/攻击速度/暴击等基础 | Character@0x70/0xAC/... | ObscuredFloat | ❌ 已破解 |
| 等级(基础) | Character+0x20 | ObscuredInt | ❌ 已破解 |
| 等级/经验/累计金币(存档) | SaveData@0x10/0x18/0x170 | int | ✅ |
| 可用天赋点(存档) | SaveData@0x98 | int | ✅ |
| **当前金币** | **未定位!** SavedStash.Gold@0x20 是误定位(仓库只存物品) | 疑似加密 | ❌ |
| 最大生命/最大法力(基础) | Character@0x30/0xD8 | ObscuredLong | ❌ 已破解(明文 100) |
| Player 链 | GameManager 单例(静态+0)→+0x40→+0x20 | — | — |
| 技能 CD | PlayerAbilityController(=PCC+0x70):GCD@+0x68、技能CD@+0xB4、施法状态对象+0x60→+0x24 | float | ✅(压 0 = 无CD) |

---

## 十、外部情报(2026-10-17 情报收集,别的 ACTk 游戏直接可用)

### 10.1 ObscuredPrefs 离线解密(PlayerPrefs 路线,比内存扫描稳)

仓库:`NotHyper-474/CodeStage-ObscuredPrefs-Decrypter`(C# 开源)

- **cryptokey 存在注册表**:键名 = `MD2("ElonShotMarsWithACar")` =
  `9978e9f39c218d674463dab9dc728bd6`,值为 base64,解码即密钥
- 注册表位置:`HKCU\SOFTWARE\<公司名>\<游戏名>`(本作 = First Day Games\Deskrawl)
- **老版 ACTk(≤1.x)密钥恒为 `e806f6`**
- 原始数据格式:base64 解码后,**类型字节在 `bytes[len-7]`,版本字节在 `bytes[len-6]`**
  (version > 10 即格式不识别);数据本体与密钥做逐字符 XOR
- 该工具源码 `EncrypterDecrypter.cs` 可直接抄加解密逻辑

### 10.2 官方 API 文档要点(docs.codestage.net/actk/api)

- `ObscuredInt.Encrypt(value, key)` / `Decrypt(value, key)` 是公开静态方法——
  IL2CPP 游戏里这两个方法名是干净的,可直接定位核心算法
- `DecryptFromV0(value, key)`:**ACTk 2024.0 起加密格式变更**,
  旧数据(V0)用此方法解——遇到解不开的老存档先试 V0 格式
- `Hash` 属性 = "对解密后明文计算的稳定 hash,与加密数据同存储"
  ——证实 hash 是对**明文**算的,不是对密文
- `RandomizeCryptoKey()`:**不改明文、只换随机密钥**,
  官方建议开发者定期调用以反制"未知值搜索"——
  差分扫描时若发现 hidden 变了但值没变,就是这个原因;
  也意味着**key 不是会话常量**,差分验证时要容忍 key 轮换

### 10.3 方法论避坑清单(本项目血泪换来的,次次适用)

1. **验证写入存活性前,先停掉自己所有会写该地址的定时器**——
   "写入被弹回"最大的嫌疑是自己的 pin 在写回(本作锁血事件),
   而不是游戏回填镜像
2. **每帧被写的热地址禁止下调试器断点**——命中风暴会卡死 CE 桥接 worker
   (管道 231 全占,须重载桥接 Lua);找写入者用差分扫描
3. **明文扫描不中 = 有加密**。ACTk 字段定位法:actkHash(候选明文) 做 AOB,
   命中处验证四元组 (hash|hidden|key|fake) 自洽——前提是 hash 算法已知
4. **差分扫描对"每帧抖动的易变值"不收敛**——用 changed / unchanged
   **交替过滤**(变化轮抓金币事件,静置轮甩掉动画/计时器),
   最后在 CE 内部遍历结果集做数学验证,别把几十万行拉回 CLI
5. **先做结构直读,再考虑全内存扫描**——从 Manager 单例链一层层 deref
   (本作技能 CD 就在 PCC+0x70 的 PlayerAbilityController 里),
   比全内存省一个数量级的时间
6. **已知明文验证 detour**:列 5-6 个候选公式
   ((h-k)^k、h^k、swap 后^k、(h^k)-k...),找一个解出"干净数"(如 100/10.0)的;
   一个样本不够就用第二个结构交叉验证
7. **CE Lua 陷阱**:`1 << 64` == 0(移位溢出);readQword 对 >2^53 的值走 double
   丢精度——64 位运算用两个 readInteger 拼 int64;脚本里严禁 busy-wait
8. **找字段先枚举类定义**:`il2cpp_class_get_fields` 全程序集遍历,
   字段名(Gold/Cost/XP/CD...)常直接暴露答案,比盲扫快得多

---

## 十一、紧凑版 ObscuredInt —— 金币钱包定位法(可复用)

本作金币不是 16 字节 ObscuredInt,也不是 ACTkByte8,而是**去掉 hash/fake 的
8 字节紧凑变体**:`hidden@X, key@X+4`,detour `(h-k)^k mod 2^32`。
它藏在**原始状态缓冲区**里(无 klass 头、±0x600 内找不到任何对象头),
因此不能用类链解析。定位流程(全程在 CE 内完成):

1. **制造多次变化**:全内存 unknown-initial-value 快照 → 每次购买后跑
   `changed` → 静置 6s 跑 `unchanged`,重复 3 轮(幸存约 130 万)
2. **绕过 16MB 传输上限**:桥的 `cmd_persistent_scan_get_results` 是**全局函数**,
   `evaluate_lua` 里直接调用即可拿到结果表,不必经 JSON 管道
3. **数学验证**:对每个候选地址,枚举
   8 字节布局(hidden_low/hidden_high/struct_start)× i64/double/float32 解释
   + 4 字节紧凑布局(int32_next/int32_prev),凡 `((h-k)^k) == 当前金币` 者即真身
   ——随机数据 2^-64 概率误命中,**命中即真身,零误报**
4. **写入**:`hidden = (新值 ^ key) + key`,key 保持不变(不动 key 免得游戏失配)

配套的 JSON 锚点:内存里有解密后的存档 JSON 字符串(UTF-16 IL2CPP),
特征 `{"Version":5`,内含 `"Gold":N`——它随金币实时更新,**可作重定位锚点**:
解析 N 后在同堆区 ±2MB 扫解码相等的紧凑对,自校验重定位(CT v1.4.0 已采用)。

注意:该 JSON 缓存是**序列化输出**,不是输入——直接改它会在下次存档时被
活对象重新序列化的值覆盖(踩过)。

---

## 十二、本次会话未完成项(如实记录,供续做)

### 12.1 ACTk 8 字节 hash(ACTkByte8)算法 —— 未最终确认
- 已完成:二进制定位。乘数立即数 `imul r32, 0x01000192`(`69 C0 92 01 00 01`)
  在 GameAssembly 仅 10 处;4 字节例程结构 = 本文第四节算法,活体双样本验证通过
  (Level 13 → 0x32468AB1、MoveSpeed float bits 0x40400000 → 0x6BC34DE1)
- 8 字节候选例程(0x7FF9D517B870 区段)结构:两条独立 4 字节链,低链结果右移 2 位后
  与高链(末尾 `|1`)异或,即形式 `(FNV4(low)>>2) ^ ((FNV4(high)*P)|1)`
- **但与活体样本不符**(100 → 0xDA03B3E9、292 → 0xC40606DB),该例程可能属于
  别的 ACTk 类型;黑盒 sweep 500+ 组合亦全部未命中 → **仍未破解**
- 影响:无。写 ACTk-Long 字段保留原 hash 即可(游戏自己重算);
  仅当要做"最大生命/法力基础值直改"时才需要
- 续做建议:从 MaxHealth/MaxMana 的 setter(op_Implicit 重载)入手,顺着
  调用找到写入 hash 的那处例程,比扫常数更精准

### 12.2 存档离线解密(save.json, magic "DDS2")—— 未完成
- 文件在 `E:/.../Deskrawl/data/save.json`,熵 7.98(真块加密,非压缩/XOR),
  10688 字节 16 对齐,668 块无重复 → 疑似 AES-CBC;备份在 `data_backup\`
- metadata 里存在 "DDS1"/"DDS2" 相邻字面量,但字面量表按字母排序,无法邻接定位密钥
- 续做建议:反汇编写档函数(找 "DDS2" UTF-16 引用点),从调用链里取
  AesManaged/key/IV 的来源
