# VED 修改器脚本源码（Auto Assemble）

> 作者:**blackyc** / **YC**　适用游戏:**VED 0.0.1865**(buildID 1880)

本目录保存 `VED_YC_CheatTable.CT` 内三个脚本的**源码**,方便阅读、学习与二次修改。
全部脚本均为 **AOB 特征码 + 代码注入**,不含任何硬编码地址。

---

## 1. `autoblock_player_update.aa` — 无限格挡 / 自动弹反 + 动作速度倍率

**注入点**:`PlayerController.Update`(玩家每帧必跑的函数)

```asm
newmem:
  mov [pPlayerController],rcx           ; 记录玩家对象
  cmp byte ptr [blockOn],00             ; 开关
  je skipBlock
  mov byte ptr [rcx+000001A4],01        ; m_inDefence = 1 → 每帧强制"处于格挡状态"
skipBlock:
  mov rax,[rcx+00000078]                ; m_animController (ActionAnimController)
  movss xmm0,[animSpeedMul]             ; 倍率(默认 2.0)
  movss [rax+00000050],xmm0             ; m_curPlaySpeed
```

| 字段 | 偏移 | 说明 |
|---|---|---|
| `PlayerController.m_inDefence` | 0x1A4 | 是否处于格挡状态(直接锁状态,而不是和冷却计时器赛跑) |
| `ActionAnimController.m_curPlaySpeed` | 0x50 | 动画/动作播放速度(也可写作 `[[pPlayerController]+0x78]+0x50`) |

**注册符号**:`pPlayerController`、`blockOn`、`animSpeedMul`

---

## 2. `enemy_freeze.aa` — 敌人定身 / 不再攻击

**注入点**:`EnemyController.Update`(每个敌人每帧都跑 → 一次钩住**全部敌人**)

```asm
newmem2:
  mov [pEnemyController],rcx
  cmp qword ptr [enemyKlass],00
  jne klassOk
  mov rax,[rcx]                         ; 捕获敌人类型指针(供取消勾选时还原使用)
  mov [enemyKlass],rax
klassOk:
  cmp byte ptr [enemyFreeze],00
  je noAct
  mov byte ptr [rcx+000001C3],00        ; m_attackAble = 0
  mov rax,[rcx+00000048]                ; EnemyAnimController
  movss xmm0,[enemyAnimSpeed]           ; 默认 0.0
  movss [rax+00000048],xmm0             ; m_curPlaySpeed = 0 → 动画冻结
  mov dword ptr [rax+0000005C],0        ; m_rmPosFactor  = 0 → 停止根运动位移
  mov dword ptr [rax+00000060],0        ; m_rmRotFactor  = 0 → 停止根运动旋转
  mov dword ptr [rax+00000064],0        ; m_tempAgentSpeed = 0 → 寻路代理停走
```

| 字段 | 偏移 | 说明 |
|---|---|---|
| `EnemyController.m_attackAble` | 0x1C3 | 是否可攻击 |
| `EnemyAnimController.m_curPlaySpeed` | 0x48 | 动画播放速度 |
| `EnemyAnimController.m_rmPosFactor` | 0x5C | 根运动位移系数 |
| `EnemyAnimController.m_rmRotFactor` | 0x60 | 根运动旋转系数 |
| `EnemyAnimController.m_tempAgentSpeed` | 0x64 | 寻路代理速度 |

**⚠️ 重要**:`[DISABLE]` 段会自动做**数据还原** —— 用运行时捕获的 `enemyKlass` 扫描全场敌人,
把 `m_curPlaySpeed / m_rmPosFactor / m_rmRotFactor` 恢复为 `1.0`、`m_attackAble` 恢复为 `1`,
否则敌人会因为动画停摆而永久卡死(v1.0.1 修复)。

**注册符号**:`pEnemyController`、`enemyKlass`、`enemyFreeze`、`enemyAnimSpeed`

---

## 3. `shop_free_refresh.aa` — 商店无限刷新

**注入点**:`WindowEquipShop.CanRefreshShop`(返回 bool,判断能否刷新商店)

原逻辑:
```asm
cmp byte ptr [rcx+0x140],00     ; 标志位
je  检查冷却
xor al,al / ret                 ; return false
检查冷却:
comiss xmm0,[rbx+0x13C]         ; 当前时间 vs 冷却结束时间
setae al / ret                  ; return 当前时间 >= 冷却
```

补丁(**强制返回 true**):
```asm
CRS:
  mov al,1
  ret
  nop / nop / nop
```

**注册符号**:`CRS`

---

## 使用方式

- **推荐**:直接在 `CT/VED/VED_YC_CheatTable.CT` 中勾选对应条目(脚本已内置)
- **单独使用**:把这些 `.aa` 内容粘贴到 CE 的 `Memory View → Tools → Auto Assemble`(或 `Ctrl+Alt+A`)中执行
