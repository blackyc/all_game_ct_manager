# 猎天使魔女3（witchtime 重编译版）金手指制作笔记 · DLL 补丁手法

适用：witchtime 移植版 **v0.9.3**（本体 1.2.0，主程序 BuildID `b47cc79b88b7091ea514b2b725c50ae01c6f00df`）。
**不适用** Switch 模拟器 / 真机 —— 那边是 Atmosphère DMNT，运行时读 `cheats/<BID>.txt`，与本文的手法完全不同。

**版本：v1.0**（2026-11-13）　作者：YC

---

## 一、为什么这里的补丁必须是「DLL 补丁」，CT / 数值修改器做不了

| 事实 | 证据 | 后果 |
|---|---|---|
| guest 的 ARM64 被**静态翻译**成 C，再编译成 x86 塞进 `build\game.dll`（142 MB / 409 个对象） | `build\logs\link.log`：`game.dll: exit 0 in 0s, 409 objects` | 运行时**不再执行 ARM 指令** |
| guest 镜像仍映射在 `0x7100000000`（只读），但只是数据/占位 | `build\run\witch-time-game.log`：`image mapped at 0x7100000000 … lifted functions: 55103` | 往 `0x7100000000+偏移` 写指令**不会改变任何行为** |
| 运行时里搜 `cheat`/`pchtxt`/`mods_elf` **零命中**（只有启动器的 `mods_rebuild`） | `witch-time-game.exe` 字符串表 | 没有运行时金手指引擎，只有 romfs 数据替换（`nnfs.c` LayeredFS） |

所以：**能改的只有"翻译后的 x86"，而这只有构建期能做。** 做法是把每条补丁点从「烧死的替换」改成「运行时判定」：

```c
/* 补丁前：无敌（guest 0x004FE1F4 被写成  mov w22, #1） */
L_71004fe1f4: c->x[22] = (uint32_t)(0x1ULL);

/* 补丁后：同一处，运行时读开关 */
L_71004fe1f4: if (wt_cheat_flags[23]) { c->x[22] = (uint32_t)(0x1ULL); }
              else                    { c->x[22] = (uint32_t)(0U | 0U); }   /* 原语句：mov w22, wzr */
```

跑起来的 x86 每帧执行这行 → **游戏内一按就生效，不用重建、不用重开**。

---

## 二、pchtxt 方言（实测，和 Atmosphère 的不同）

```
@nsobid-b47cc79b88b7091ea514b2b725c50ae01c6f00df   ← 完整 BuildID（48 位 hex），不是 16 位前缀
@enabled                                            ← 必须，否则算 "no enabled patches"
004FE2F4 36008052                                   ← 偏移 = 金手指镜像偏移 + 0x100；8 位 hex 无 0x 前缀；值是小端字节
```

三条都是踩出来的（构建器报错原文）：

| 现象 | 报错 | 修法 |
|---|---|---|
| 只写 16 位 BuildID | `is for build ID b47cc79b88b7091e, but your main is b47cc79b88b7091ea514b2b725c50ae01c6f00df` | 写满 48 位 |
| 没写 `@enabled` | `1 mod file(s), no enabled patches`（静默不报错） | 加 `@enabled` |
| 用原金手指偏移 | 报告里地址差 0x100（写 `004FE1F4` 实际落到 `0x004FE0F4`） | 偏移 +0x100 |
| 带 `0x` 前缀 | `expected "<hex offset> <hex bytes>" or <hex offset> "string": '0x004FE1F4 36008052'` | 去掉 `0x` |

**自证方法**：写 `004FE2F4 36008052`（值 = `52800036` 小端），日志应打印
`0x004fe1f4 f6031f2a -> 36008052` —— `f6031f2a` 正是原金手指「无敌 关」的 `2A1F03F6`，字节对上就说明偏移与字节序都对了。

---

## 三、27 项功能一览（39 处补丁点）

| # | 功能 | guest 补丁点（镜像偏移） | 判定标志 |
|---|---|---|---|
| 0 | 生命不减 | 0x00447990 | `wt_cheat_flags[0]` |
| 1 | 魔力无限 | 0x0042F9FC<br>0x0079E96C | `wt_cheat_flags[1]` |
| 2 | 无限跳跃 | 0x0044EFCC | `wt_cheat_flags[2]` |
| 3 | 道具不减 | 0x00716180 | `wt_cheat_flags[3]` |
| 4 | 素材不减 | 0x0071626C | `wt_cheat_flags[4]` |
| 5 | 全货币不减 | 0x0071F658<br>0x00A0BA28 | `wt_cheat_flags[5]` |
| 6 | 宝晶8倍 | 0x007A1508<br>0x007A150C | `wt_cheat_flags[6]` |
| 7 | 光环8倍 | 0x003FF720 | `wt_cheat_flags[7]` |
| 8 | 胚胎结晶8倍 | 0x00503564 | `wt_cheat_flags[8]` |
| 9 | 服装全解锁 | 0x00A58988 | `wt_cheat_flags[9]` |
| 10 | 武器全解锁 | 0x00A537B8 | `wt_cheat_flags[10]` |
| 11 | 饰品全解锁 | 0x00A53B7C<br>0x00A53D5C | `wt_cheat_flags[11]` |
| 12 | 召唤兽全解锁 | 0x00A0A0C8<br>0x00A4B3D8 | `wt_cheat_flags[12]` |
| 13 | 魔力瞬间恢复 | 0x00430EE0 | `wt_cheat_flags[13]` |
| 14 | 自动魔女时间 | 0x004E803C | `wt_cheat_flags[14]` |
| 15 | 魔女之心不减 | 0x00722B28<br>0x00722B6C | `wt_cheat_flags[15]` |
| 16 | 月之珍珠不减 | 0x00722BC0 | `wt_cheat_flags[16]` |
| 17 | 子弹/弓箭无限 | 0x004F3CC8<br>0x004F421C | `wt_cheat_flags[17]` |
| 18 | 攻击BUFF不减 | 0x00423434 | `wt_cheat_flags[18]` |
| 19 | 战斗时间不增加 | 0x007C6B3C | `wt_cheat_flags[19]` |
| 20 | 怒火/觉醒槽无限 | 0x00423F14 | `wt_cheat_flags[20]` |
| 21 | 技能学习限制解除 | 0x00A0D6EC<br>0x00A0D700<br>0x00A0D70C<br>0x00A0D718 | `wt_cheat_flags[21]` |
| 22 | 试炼挑战直接通关 开启 | 0x007A15E0<br>0x009169A4 | `wt_cheat_flags[22]` |
| 23 | 无敌 开 | 0x004FE1F4 | `wt_cheat_flags[23]` |
| 24 | 2倍伤害 | 0x000D0780 | `wt_cheat_flags[24]` |
| 25 | 魔女机关停止计时 | 0x003AEAFC<br>0x0073EDD8 | `wt_cheat_flags[25]` |
| 26 | 挑战模式停止计时 | 0x00916664 | `wt_cheat_flags[26]` |

判定标志 `wt_cheat_flags[i]` 定义在 game.dll 并 `__declspec(dllexport)` 导出，exe 侧用
`GetProcAddress(GetModuleHandleA("game.dll"), "wt_cheat_flags")` 取地址（**不能靠导入库**，见踩坑 2）。

---

## 四、★ 踩坑记录（每条都是实测撞出来的）

### 1. 面板字体是 523 字的**子集**，新文案全是豆腐块

`runtime\third_party\NotoSansSC-GAMER520.COM.otf` 只覆盖 523 个码位（解析 cmap 得到），
打包时按原有文案裁的。新加的 27 行标签里 `无敌`、`伤害`、`宝晶` 等大量字不在其中。
**修法**：换成 launcher 自带的完整 `NotoSansCJKsc-Regular.otf`（15.7 MB，SIL OFL 1.1）。
它是 **CFF 轮廓**（sfntVersion `OTTO`），stb_truetype 1.26+ 才支持 —— 老版本会整页无字。
三个字体名用 `#define` 指向同一个 `#embed`，避免同一份 15.7 MB 被打进 exe 三次。

### 2. `game.def` 是 wtbuild **硬编码**的导出清单，dllexport 的新符号进不了导入库

exe 引用 `wt_cheat_flags` 时链接报 `undefined symbol: __declspec(dllimport) wt_cheat_flags`，
而 `build\game.def`（wtbuild 每次 link 重写）里只有 `game_cutscene_fps` 等固定十几个符号。
**修法**：exe 侧不要 dllimport，改成运行时 `GetProcAddress`（数据符号也能取到地址），
头文件里对 host 侧用 `#if !defined(WT_CHEAT_HOST)` 屏蔽 extern 声明。

### 3. `lift` 每次都会重跑，并**覆盖**手改的 gen_eh

`source_fp` 与实际 runtime 源码指纹不一致（整合包被本地化过），所以每次 `setup` 都打印
`Witch Time itself changed since the last build (an update): tables, lift, compile run again`。
**所以必须四段分开跑**（见第五节），`--only compile` 不会触发 lift，是唯一安全的插入点。

### 4. 代码洞补丁被构建器拒收（移速 1.5/2.0、连击 8 倍）

这三条把代码写到 `0x1323400`~，那是 `.text` 文件长度（0x1323400）**之外**、最后一页之内的填充区。
真机/模拟器里是合法可执行内存，但 wtbuild 按文件打补丁：
`image offset 0x1323400 (+4 bytes) is outside the program's code and data in the file (offset_shift wrong, or the patch is for another program)`。
→ 本次**未覆盖**这三条。（要做得先在 .text 内找新洞并改 BL 位移，且要让 lifter 翻译那段代码。）

### 5. `convert` / `book` 步骤固定报 `os error 32`

对任何文件都报「另一个程序正在使用此文件」，与文件锁无关（PowerShell 能以任意模式打开同一文件）。
本体的构建不依赖它们：`mods` 步自己会从 NSO 重新生成干净的 ELF。
绕过办法：把 `setup_state.json` 里对应步骤标记为已完成，`--only/--from` 就会跳过。

### 6. **事故**：PowerShell `File::Open` 三参重载会截断文件

探测「文件是否被占用」时写了 `[System.IO.File]::Open($p, $access, $share)` —— 只有 3 个参数时
PowerShell 匹配到 `(path, FileMode, FileAccess)`，把 `FileAccess.Write`(=2) 隐式转成
`FileMode.Create`(=2)，于是 16.9 MB 的 `targets\exefs\main` 被清成 0 字节。
**教训**：探测占用一定写满 4 个参数并显式指定枚举类型：
`[System.IO.File]::Open($p,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)`。

### 7. 构建器 link 时会**先删再建** `wt_glslang.dll`

失败的那次会把工作用的静态版删掉。包里 `build\program1\wt_glslang.dll` 是同一份（3,531,776 字节），
构建后必须 `copy /y` 恢复，否则运行时缺这个 DLL。

### 8. 编译链需要五个 dev 包（发布物不需要，但重建需要）

| 组件 | 版本 | 用途 |
|---|---|---|
| llvm-mingw | 20261020（LLVM 23.1.4，与包内 clang 同版） | 编译器 |
| SDL3 devel | **3.4.18**（必须与 `build\SDL3.dll` 同版） | `SDL3/SDL.h` + `libSDL3.dll.a` |
| Vulkan-Headers | main | `vulkan/vulkan.h` |
| FFmpeg 源码 | **n7.1.5**（与 `avcodec-61 / avformat-61` 同版） | 头文件；导入库用 `llvm-dlltool` 从包里 DLL 的导出表现生成 |
| glslang | MSYS2 `mingw-w64-x86_64-glslang` | `glslang/Include/glslang_c_interface.h` + 导入库（**用 .dll.a，别用 .a**，静态库是 GCC/libstdc++ 编的，和 libc++ 的 llvm-mingw 链不上） |

另外 `libavutil/avconfig.h` 是 configure 生成的，源码包里没有，要自己补：
`#define AV_HAVE_BIGENDIAN 0` + `#define AV_HAVE_FAST_UNALIGNED 1`（x86_64 小端）。

---

## 五、重建流程（**四段分开**，顺序不能变）

```bat
set CPATH=<sdl3内include>;<vulkan include>;<ffmpeg根>;<glslang内include>
set LIBRARY_PATH=<自建导入库目录>;<sdl3内lib>;<glslang内lib>
set WTBUILD_SKIP_LIB_CHECK=1

1) wtbuild setup --llvm <工具链> --only lift      :: 重新生成 gen_eh（会覆盖手改，所以必须放第一步）
2) 把 gating-sources\ 覆盖回 build\gen_eh\ 与 runtime\  :: 19 个 gated *.c + cheats.h/pcmenu.c/boot.c/runtime.h
3) wtbuild setup --llvm <工具链> --only compile   :: --only compile 不会触发 lift
4) wtbuild setup --llvm <工具链> --only link      :: 产物 game.dll + witch-time-game.exe
5) copy /y build\program1\wt_glslang.dll build\wt_glslang.dll
```

首次全量编译约 2.5 分钟（409 个文件）；只改补丁时 lift 1.2s + compile（仅受影响文件）+ link 4s。

---

## 六、发布物与默认值

| 文件 | 大小 | 作用 |
|---|---|---|
| `build\game.dll` | 142.13 MB | 39 处补丁点已改为运行时判定 + 导出 `wt_cheat_flags` |
| `build\witch-time-game.exe` | 23.17 MB | F1 电脑设置面板多出 27 行「金手指」页 |
| `build\wt_glslang.dll` | 3.37 MB | 保持包内静态版 |
| `config\graphics.ini` | — | 27 条 `cheat_xxx = on`（默认全开，玩家改完即时生效并持久化） |

开关状态存在 `config\graphics.ini`（`gfx_option_set` 写、`wt_cheats_load()` 启动时读回），
**不需要重建**即可在游戏内切换。

---

## 附录 A：补丁材料清单（本压缩包内）

```
wt-cheats\                 原始 pchtxt（4 个生效文件 + 4 个 .off），含中文说明
gating-sources\
  gen_eh\*.c               19 个已改写成运行时判定的 lifted 源码
  cheats.h                 27 项枚举 + 标志数组声明
  pcmenu.c                 面板 27 行 + GetProcAddress 绑定 + wt_cheats_load
  boot.c                   启动时加载开关状态
  runtime.h                引入 cheats.h
```

## 附录 B：本次未覆盖的功能（想做要另开工）

| 功能 | 原因 |
|---|---|
| 移速 1.5 / 2.0 倍 | 需要代码洞（见踩坑 4） |
| 连击数 8 倍 | 同上 |
| 伤害 4 倍 | 与「伤害 2 倍」同偏移（`0x000D0780`）互斥，本次只做了 2 倍 |
