# 挂机破坏神（Idle Diablo / Deskrawl.exe）ACTk 加密破解笔记

作者:**YC**　日期:2026-10-16　适用:ACTk (CodeStage Anti-Cheat Toolkit) 2.x + Unity IL2CPP

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

ObscuredLong/Double 32 字节:hash(4) + hiddenValue ACTkByte8(8) + key(4) +
fake(8) + oldByte4(1) + pad。8 字节 detour 与 4 字节不同,见第六节。

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

- ✅ ObscuredInt / ObscuredFloat:完整读写(CT 里 [★4] 移动速度 / [★5] 攻击速度)
- ⬜ ObscuredLong/Double(ACTkByte8):本作 BaseMaxHealth/BaseMaxMana 用它,
  8 字节 detour 算法待反汇编(Byte4 的 FNV 循环会扩成 8 字节版本,
  定位方法相同:ObscuredLong 的 op_Implicit → core)
- ⬜ ObscuredString:byte[] 引用型,另一套

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
| **当前金币** | SavedStash.Gold@0x20(权威实例=SaveContainer.LocalStash) | int | ✅ |
| Player 链 | GameManager 单例(静态+0)→+0x40→+0x20 | — | — |
