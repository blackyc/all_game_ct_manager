# all_game_ct_manager

作者:**blackyc**　环境:Windows 10 企业版 22H2(10.0.19045) + Cheat Engine 7.5.0.7431

## 文件索引

| 游戏 | 版本 | 文件 | 功能 | 平台 | 感谢 |
|---|---|---|---|---|---|
| VED | 0.0.1886 | VED_YC_Trainer.exe | 12 项 | - | - |
| ForgeTax | - | ForgeTax_YC.CT | 3 项 | - | - |
| Deskrawl(挂机破坏神) | 1.0.2a | Deskrawl_YC.CT | 6 项 | - | - |
| Bloodborne(血源诅咒) | bbport 0.9.33 | Bloodborne_YC.CT<br>Bloodborne_YC_Trainer.exe | 8 项 | GitHub Releases | - |
| Probably Stolen(深空当铺) | v0.46D | ProbablyStolen_YC_Trainer.exe | 26 项 | - | - |
| Warhammer Survivors(战锤:幸存者) | Steam 11-25 构建 | WarhammerSurvivors_YC_Trainer.exe | 22 项 | - | - |
| Bayonetta 3(猎天使魔女3) | witchtime 0.9.3 / 本体 1.2.0 | Bayonetta3_YC_RECOM补丁.7z | 27 项 | - | - |
| Frontier Tale(开拓物语) | Build.26751033 (Steam) | FrontierTale_YC_Trainer.exe<br>FrontierTale_YC.CT | 21 项 | - | - |

功能明细见 `files/<游戏>/` 内文档。

> VED 早期 0.0.1865 的两个 CT 仍留在 `files/VED/`，随版本更新可能已失效。

## 使用

**CT**：Cheat Engine 7.5+ → `Open Process` 附加游戏 → `File → Load` 载入 → 勾选条目

**Trainer(exe)**：双击运行，自动连接游戏；游戏以管理员身份运行时，exe 也需右键以管理员身份运行

**RECOM 补丁**：witchtime 移植版专用（补丁已编进 `game.dll`）。压缩包内是源码级材料 + 制作笔记；玩家直接用整合包，进游戏按 **F1** 逐项开关，状态存 `config\graphics.ini`
