# 绿喷管家 (DreamBreathStasisHelper)

> **塑焰恩护唤魔师专用** —— 实时告诉你"什么时候不能再喷绿喷，必须留层给静滞"。
> A combat helper for **Preservation Evoker (Flameshaper)** in World of Warcraft: Midnight (12.0+).

---

## 它解决什么问题

静滞开了之后要等 90 秒，期间你会忍不住一直喷绿喷（梦境吐息）。**喷爽了的结果，就是静滞转好时手里没层，静滞等于白开。**

本插件实时算一件事：**如果我现在再喷一口，等静滞 CD 好的时候手里还剩几层？** 剩不下就红灯叫你停手。

---

## 核心功能

### 1. 红绿灯判断（六态）

| 状态 | 颜色 | 大字 | 触发条件 | 你该做什么 |
|------|------|------|----------|-----------|
| 静滞准备ok | 🟢 绿 | `静滞准备ok!` | 静滞CD好了 + 绿喷满2层 | 开静滞 |
| 层不够 | 🟡/🔴 黄红 | `绿喷 1/2` | 静滞CD好了但绿喷没满 | 别开，等充能 |
| 随便喷 | 🟢 绿 | `随便喷` | CD≥50s，或40~50s段手里≥1层 | 放心输出 |
| 注意 | 🟡 黄 | `注意` | CD 20~40s，喷完还剩≥1层 | 再喷一口就到极限 |
| **停手！** | 🔴 红 + 边框闪烁 | `停手!` | CD<20s / 40~50s段0层 / 20~40s段喷完0层 | **立刻停手留层** |
| 未启用 | ⚪ 自动隐藏 | — | 不是塑焰恩护 / 没点静滞 | 不用管 |

**判断公式**（T = 静滞CD剩余，P = 再喷一口后静滞好时剩几层）：

```
T ≥ 50s      →  绿灯（50s够充回，随便喷）
40 ≤ T < 50s →  有≥1层 = 绿灯 / 0层 = 红灯
20 ≤ T < 40s →  P≥1 = 黄灯（极限） / P=0 = 红灯
T < 20s      →  红灯（充能来不及，完全停手）
```

### 2. 绿喷层数：大字级显示，一眼可读

层数不用再眯着眼找：

- **状态大字右侧**：绿色大字（`1/2`），比状态文字小一号，跟随状态色变化一起显示
- **静滞就绪时**：`绿喷 X/2` 移到**右下角放大显示**，开静滞前一眼确认手里是不是满层

### 3. 静滞助手：双排图标

按下静滞后，界面切换为存储模式，上下两排**逐列一一对应**：

```
[绿喷] [绿喷] [溜溜球]   ← 上排 20×20：计划队列（接下来 / 第2 / 第3 / 已用）
[回响] [绿喷] [祝福  ]   ← 下排 44×44：真正存进去的技能（待存 = 问号半透明）
```

时间轴：存储中(0-6s，图标实时填入) → 心灵之火(按下后15s倒计时) → 存满待释放(回到绿喷判断，存储排持续显示) → 已释放(清空)。

存入白名单 12 个治疗技能，与 PreservationStasisTracker 完全一致（红喷不会被静滞存储）。

### 4. 数字精度：显示走官方引擎

UI 上那行 `静滞CD 62s` **就是暴雪自己算的值** —— 走官方 `DurationObject` 句柄直出，实时跟踪心流加速与溜溜球减CD，跟你游戏技能栏上的数字一模一样，零漂移。

### 5. 资格自动托管

只对"点了静滞的塑焰恩护唤魔师"有用，所以装了之后它自己判断：

**唤魔师 → 恩护专精 → 塑焰者英雄天赋 → 静滞天赋 → 心灵之火天赋**

任何一项不符就**自动隐藏，不刷屏不报错**。切小号、切专精都不用管它。天赋改动自动重检。

### 6. 控制台与命令

`/DBSH` 打开控制台：**UI 开关 · 锁定/拖动 · 缩放(0.5-2.0) · 透明度(10-100%)**，拖动主界面位置自动保存。

```
/DBSH            打开控制台            /DBSH lock      锁定界面
/绿喷管家        中文别名              /DBSH unlock    解锁可拖动
/DBSH toggle     显示/隐藏             /DBSH reset     位置重置
/DBSH scale 1.5  缩放(0.5-2.0)         /DBSH recharge 30  手动指定充能时长
/DBSH status     资格五项检测结果       /DBSH flow      心流天赋层数
```

---

## 安装

1. 从 [Releases](../../releases) 下载 zip
2. 解压到 WoW 插件目录，结构应为：

```
World of Warcraft/_retail_/Interface/AddOns/
└── DreamBreathStasisHelper/
    ├── DreamBreathStasisHelper.toc
    └── DreamBreathStasisHelper.lua
```

3. 重启游戏或 `/reload`

---

## 更新日志

### v1.37.0
- **修复：取消蓄力不再被算作已释放** —— 按住绿喷蓄力后按 `Esc` 取消，插件不会再误扣一层，也不会多记一次"已用"
- **心流状态下冷却更准** —— 点了心流状态天赋时，绿喷充能与静滞冷却的读秒和判断基准都更贴近游戏本体（原先在加速窗口开始／结束的瞬间会有偏差，长时间战斗会累积）
- **长战斗稳定性** —— 连续战斗数分钟、反复起停充能的情况下，层数与冷却时间不再随时间累积偏移

### v1.36.0
- **绿喷层数显示优化**：层数从右上角小字改成**状态大字右侧的绿色大字**，跟着状态一起看，不用再眯眼找
- **静滞就绪时**：`绿喷 X/2` 在右下角**放大显示**，开静滞前一眼确认手里满不满层

### v1.34.x
- **双排图标**：顶部 20×20 计划队列 + 底部 44×44 真实存入技能（StasisTracker 式）
- 存储信息持续显示到释放；心灵之火 15s 内释放只显示心火倒计时
- 未释放时绿喷判断整体上移放大，不再与存储排挤在一起

### v1.33.0
- **接入官方引擎通道**：UI 冷却/层数数字改由 `DurationObject` 句柄直出，与游戏本体完全一致

### v1.32.x
- 资格门槛自动检测（五项）与自动隐藏
- 心流状态天赋支持（绿喷充能 + 静滞CD 双加速）
- 充能读秒精度对齐游戏本体

---

## English summary

A combat helper for **Preservation Evoker (Flameshaper)** in WoW Midnight (12.0+). It answers one question in real time: **"Is it still safe to cast Dream Breath right now?"**

- **Traffic-light verdict** — predicts how many Dream Breath charges you'll hold when Stasis comes off cooldown: red (stop) / yellow (limit) / green (safe).
- **Charges at a glance** — the charge counter sits next to the status text as a large green readout, and moves to the bottom-right corner (enlarged) whenever Stasis is ready.
- **Stasis tracker** — two rows of icons showing your planned queue and the spells actually stored.
- **Blizzard-accurate numbers** — the cooldown readout comes from the official `DurationObject` handle, identical to your action bar.
- **Accurate under Flow State** — Dream Breath recharge and Stasis cooldown stay aligned with the client while the Flow State window opens and expires; the verdict stays right through long fights.
- **Auto eligibility** — hidden automatically unless you're a Flameshaper Preservation Evoker with Stasis talented.
- Commands: `/DBSH` (config panel), `/DBSH status`, `/DBSH lock`, `/DBSH scale`.

---

## License

All Rights Reserved. You may download and use this addon freely, but redistribution, modification, or derivative works require the author's explicit written permission.

Copyright (c) 2026 炸鱼奶龙 (ZhaYuNaiLong)
