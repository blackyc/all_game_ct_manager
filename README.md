# all_game_ct_manager

作者:**blackyc**　环境:Windows 10 企业版 22H2(10.0.19045) + Cheat Engine 7.5.0.7431

## 目录结构

```
files/<游戏>/
  <游戏>_YC_*.CT            Cheat Engine 表
  <游戏>_YC_Trainer.exe     独立修改器（有则提供，不依赖 Cheat Engine）
  <游戏>_YC_制作笔记.md      内存定位思路、结构偏移、踩坑记录
```

有独立修改器的游戏优先用 exe；没有的用 CT。

## 文件索引

| 游戏 | 版本 | 文件 | 说明 | 发布平台 | 感谢 |
|---|---|---|---|---|---|
| VED | 0.0.1865 | VED_YC_CheatTable.CT | 完整版:无限格挡 / 敌人定身 / 商店无限刷新 / 动作速度倍率 | Game Cheats Manager | 社区作者 **ELYSIUM** |
| VED | 0.0.1865 | VED_YC_Lite.CT | 精简版:仅上述新增功能 | Game Cheats Manager | 社区作者 **ELYSIUM** |
| ForgeTax | - | ForgeTax_YC.CT | 敲击结果控制:强制大成功(剑永不损坏、价值只增不减) + 剑价值/等级/界面概率显示 | - | - |
| Deskrawl(挂机破坏神) | 1.0.2a | Deskrawl_YC.CT | 稳定版:状态显示+数值修改——实时生命/法力、等级/经验/天赋点/基础属性、移速/攻速直写、锁血/MP无限/一击必杀/无CD | - | - |
| Bloodborne(血源诅咒) | PC 移植版 bbport 0.9.33 (eboot 1.09) | Bloodborne_YC_VialsBullets.CT<br>Bloodborne_YC_Trainer.exe | 数值:水银弹/血瓶/血之回响/洞察/等级/六项属性 可直接改 + 无限血瓶/无限水银弹/无限体力/锁血(读图/重启自动跟随)；等级与属性需一起改；仅适用 bbport 移植版, PS4 模拟器不通用 | GitHub Releases | - |

## 使用

**CT**：Cheat Engine 7.5+ → `Open Process` 附加游戏 → `File → Load` 载入 → 勾选条目

**Trainer(exe)**：直接双击运行，检测到游戏进程后自动连接；`F1` 锁血 / `F2` 无限血瓶 / `F3` 无限水银弹 / `F4` 停止全部。
若游戏以管理员身份运行，exe 也需要右键「以管理员身份运行」。

## 注意

- 数值会写进角色存档，改动前请先备份；仅用于单人离线。
- 修改器需要与游戏版本匹配；游戏大更新后偏移可能失效，等表格更新。
