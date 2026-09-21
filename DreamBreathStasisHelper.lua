--==========================================================================
-- 绿喷管家 (DreamBreathStasisHelper)
-- 塑焰恩护唤魔师 - 梦境吐息(绿喷)与静滞冷却配合监测
-- 核心目的: 告诉玩家什么时候不能再使用绿喷,必须停手
--
-- 判断逻辑:
--   预测 "如果现在再用一次绿喷, 静滞CD好时手里还有几层"
--     < 2层     -> 红灯: 停手!
--     = 2层且CD<40s -> 黄灯: 注意,再用1次就到极限
--     >= 2层    -> 绿灯: 放心喷
--   另有静滞使用次数计数器作为辅助参考
--
-- 作者: 炸鱼奶龙  版本: 1.37.0
--==========================================================================

local AddonName = ...

-- 版本检查: 仅支持 Midnight (12.0+)
local buildVersion = select(4, GetBuildInfo())
if buildVersion and buildVersion < 120000 then
    print("|cFF7F77DD[绿喷管家]|r 仅支持 Midnight(12.0+), 当前版本不兼容, 插件未加载")
    return
end

local FSH = CreateFrame("Frame")
-- 不调用 Hide(): 让 OnUpdate 永远触发 (WoW 中 hidden frame 的 OnUpdate
-- 在某些更新中可能不被调度, 不安全)

--==========================================================================
-- 常量与配置
--==========================================================================

-- Dream Breath (梦境吐息 / 绿喷) 基础 spell ID (用于读充能)
-- 塑焰专精通过 Legacy of the Lifebinder 天赋获得 2 层充能
local DREAM_BREATH_SPELL_ID = 355936

-- 【v1.32.10 机制修正 —— 推翻 v1.32.9 的错误结论】
--   心流状态**确实加速绿喷充能**。Warcraft Wiki "Flow State" 原文:
--     "Empower spells cause time to flow 5/10% faster for you, increasing movement
--      speed, **cooldown recharge rate**, and cast speed."
--   2026-02-19 官方 hotfix 还专门修过:
--     "Fixed an issue where Flow State was not properly increasing the cooldown
--      recharge rate of Fire Breath, **Dream Breath**, and Verdant Embrace."
--   → 窗口内绿喷充能等效时长 = 30/1.1 = 27.272s (2点), 由 TickFlowAcceleration 逐帧积分实现。
--   本常量只作"基准时长": 心流窗口内 API 会返回被加速过的瞬时值(27.272),
--   必须乘回 chargeModRate 还原成基准再缓存, 否则基准会被永久污染。
local DREAM_BREATH_CHARGE_BASE = 30

-- Dream Breath 所有 spell ID (用于检测施放完成, empowered skill 有多个 rank ID)
-- 参考 PreservationStasisTracker: 355936, 382614
local DREAM_BREATH_IDS = { [355936] = true, [382614] = true }

-- Stasis (静滞) spell ID
-- 90秒冷却, 激活后存储接下来3个helpful spell, 30秒内可再激活释放
local STASIS_SPELL_ID = 370537

-- 静滞施放相关 spell ID (用于施法事件追踪)
-- 370537 = Stasis (激活存spell = 第一次按; 释放 = 再次按同一个按钮)
-- 370564 = Stasis 的数据库 rank/显示 ID, 事件里实际不出现, 仅作兜底
-- 关键: 静滞"释放"不是独立按钮, 是再次按 370537 → 用 stasisState.phase 区分激活/释放
local STASIS_IDS = { [370537] = true, [370564] = true }

-- Stasis 激活后的 "待释放" buff spell ID (玩家身上有这个aura = 处于激活窗口)
local STASIS_ACTIVE_AURA_ID = 370562

-- 静滞能存储的治疗技能白名单 (spellId -> 名称)
-- 关键: 静滞"存满"= 数满3个白名单治疗技能, 这是战斗中唯一可靠的做法
-- (aura/CD数值全被12.1加密, 现成插件 Evoker Stasis Tracker 也是数施法事件)
-- v1.34.2: 对照 PreservationStasisTracker 实测白名单补齐缺失技能 ——
--   此前缺"麦琳瑟拉的祝福(1256581)"等, 导致第3个存的技能不计数,
--   storedCount 永远到不了3, 静滞进不了 ARMED/30秒倒计时 (不只是图标不亮!)
-- v1.34.3: 白名单**完全照抄** PreservationStasisTracker 的 spellList,
--   不加自己的东西; 老板确认红喷非治疗技能不存静滞, 剔除(红喷只开心流窗口不计数)。
--   绿喷(355936/382614)保留 —— PST 老板实机截图确认绿喷会被存入(走 SUCCEEDED 计数)。
local STASIS_STORABLE_SPELLS = {
    [355936] = true,  -- 梦境吐息 (绿喷, empowered; PST 实机确认会被静滞存入)
    [382614] = true,  -- 梦境吐息 (绿喷, empowered 变体)
    [361509] = true,  -- 活化烈焰 (Living Flame)
    [364343] = true,  -- 回响 (Echo)
    [360995] = true,  -- 翡翠之拥 (Verdant Embrace)
    [366155] = true,  -- 逆转 (Reversion)
    [1256581] = true, -- 麦琳瑟拉的祝福 (Merithra's Blessing)
    [355913] = true,  -- 翡翠花 (Emerald Blossom)
    [374251] = true,  -- 烧灼之焰 (Cauterizing Flame)
    [360823] = true,  -- 化身自然 (Naturalize)
    [373861] = true,  -- 时空畸体 (Temporal Anomaly)
    [1291636] = true, -- 时光屏障 (Temporal Barrier)
}

-- Temporal Anomaly (时空畸体) spell ID - 静滞后第3个固定存的绿喷前置 (讲义触发减CD)
local TEMPORAL_ANOMALY_SPELL_ID = 373861

-- 心流状态 (Flow State) 天赋: 释放任意蓄力技能后10s内时间流速加快 5%*层数
-- 【v1.32.10 作用范围(最终定版)】心流加速 **绿喷充能 + 静滞 CD**(外加移速/施法速度)。
--   Wiki 原文: "increasing movement speed, cooldown recharge rate, and cast speed";
--   2026-02-19 官方 hotfix 专门修过 Dream Breath 的 cooldown recharge rate。
--   (v1.32.9 曾误判"绿喷充能不受心流影响"并删掉这段加速 —— 本轮已回滚)
-- 按名字/ID 识别天赋 (兼容中英文客户端), 层数运行时检测并缓存 (见 RefreshFlowStateRank)
-- 【ID 来源】2026-09-12 老板天赋面板截图: 心流状态, 等级 2/2, 被动, SpellID = 385696, IconID = 4622479
--   描述: 蓄力法术使你的时间流动速度加快10%, 提高移动速度/冷却充能速率/施法速度, 持续10秒。
--   → 2 点 = 加速 10%, 印证每层 5% (FLOW_RATE_PER_RANK)
-- 【为什么加 ID 判据】v1.32.6 实测: 名字表里写的"心流状态"与面板显示完全一致, 却仍识别为 0 层
--   → 说明失败点不在词表, 而在"遍历拿到的 spellID 查不到名字"或"根本查不到名字 API"。
--   ID 匹配不依赖任何取名字的 API, 是更硬的判据; 名字匹配降级为兜底。
local FLOW_STATE_ID = 385696                 -- 天赋本体 spellID (面板实测)
-- 【v1.36.10 真机实测: 天赋 ID != buff aura ID, 两者都要留着】
--   2026-09-21 00:31 老板 `/DBSH flow` 真机输出:
--     GetPlayerAuraBySpellID(385696) → 查不到
--     同一次遍历 helpful aura 第 [11] 条 → id=390148 name="心流状态" dur=10 剩余=7.4s (明文可读)
--   → 385696 是**天赋节点** ID(用来查天赋树点没点), 390148 才是挂在身上的**光环** ID。
--   要读"buff 还剩几秒"必须用 390148。FLOW_STATE_IDS 里只放天赋 ID, 别混入 aura ID。
local FLOW_AURA_ID = 390148                  -- 心流状态 buff aura ID (真机实测, 脱战明文可读)
local FLOW_STATE_NAMES = { ["心流状态"] = true, ["Flow State"] = true }
local FLOW_STATE_IDS = { [FLOW_STATE_ID] = true }
local FLOW_RATE_PER_RANK = 0.05   -- 每层冷却加速 5%
local FLOW_WINDOW = 10            -- 增益持续 10s

-- 所有蓄力(empower)技能统一表: 施放成功即触发心流移位 (含静滞存储/释放时的重施放)
local EMPOWER_SPELL_IDS = {
    [355936] = true,  -- 梦境吐息 (绿喷)
    [382614] = true,  -- 梦境吐息 (绿喷)
    [357208] = true,  -- 火焰吐息 (红喷)
    [382266] = true,  -- 火焰吐息 (红喷)
}

-- 心流状态天赋缓存 (登录/天赋/专精变化时由 RefreshFlowStateRank 重算)
local flowState = { rank = 0, spellID = nil }
local flowUntil = 0  -- 心流状态buff到期时刻(GetTime基准), buff不叠层只刷新窗口

-- 静滞打开阶段(按下后)的时间轴:
--   0-6s:   顶部小图标队列(绿喷·绿喷·时空畸体, 20x20) + 下方"已存技能"大图标排(44x44,
--           StasisTracker式: 存入=真实技能图标, 待存=问号半透明)  [v1.34]
--   7-15s:  显示 心灵之火 logo + "剩余X秒" 文字 (buff 持续15秒), 已存技能大图标保持显示
--   15s+:   回到主绿喷判断模式
local STASIS_OPENING_QUEUE_DURATION = 6   -- 前6秒显示队列
local STASIS_OPENING_TOTAL_DURATION = 15  -- 整个打开阶段15秒
local STASIS_COOLDOWN_DURATION = 90       -- 静滞CD总时长(秒), 老板确认固定90s
local STASIS_CD_START_OFFSET = 1.3        -- v1.18: 游戏静滞CD在"第3技能施法开始+1.3s(GCD)"起算, 非"读条完成"
local INNERFIRE_SPELL_ID = 1242747        -- 心灵之火 (buff)

-- 心灵之火 (Inner Fire) 天赋本体 spell ID
-- 【实测来源】2026-09-12 老板天赋面板截图: 天赋节点 SpellID = 1242745 (等级0/1, 被动)
--   1242747 = 同一天赋的法术/buff 形态 (原有 INNERFIRE_SPELL_ID)
-- 两者都是正向匹配: 任一命中即算"已点", 避免因客户端形态差异漏判
local INNERFIRE_TALENT_IDS = { 1242745, 1242747 }
-- 心灵之火 天赋树节点名 (兼容中英文客户端; 仅作兜底, 主判据是 spellID)
local INNERFIRE_NAMES = { ["心灵之火"] = true, ["Inner Fire"] = true }
-- 心灵之火 天赋树节点判据: 与 INNERFIRE_TALENT_IDS 同源, 供 GetTalentRankByName 的 ID 通道用
local INNERFIRE_ID_SET = { [1242745] = true, [1242747] = true }
local QUEUE_ITEMS = { "DREAM_BREATH", "DREAM_BREATH", "TEMPORAL_ANOMALY" }

-- 默认配置
local defaults = {
    enabled       = true,     -- 总开关(显示UI)
    locked        = false,     -- UI是否锁定(锁定后不可拖动)
    scale         = 1.0,      -- UI缩放
    alpha         = 0.82,     -- UI整体透明度(0.1-1.0, 作用于背景+logo+文字)
    point         = "CENTER", -- 锚点
    relPoint      = "CENTER",
    relFrame      = "UIParent",
    x             = 0,
    y             = -180,
    customRecharge = nil,     -- 自定义绿喷充能总时间(秒), nil=自动读取
    -- (红灯声音已删除; 计数器默认开, 不再暴露开关)
}

local db -- 配置数据, ADDON_LOADED 时赋值

-- 状态枚举
local STATE = {
    SAFE      = "SAFE",      -- 绿灯: 放心喷
    WARNING   = "WARNING",   -- 黄灯: 注意
    STOP      = "STOP",       -- 红灯: 停手!
    STASIS_READY  = "STASIS_READY", -- 静滞可用未开
    STASIS_OPENING = "STASIS_OPENING", -- 静滞打开阶段: 显示技能队列
    OFFLINE   = "OFFLINE",   -- 不是塑焰恩护唤魔师
}

-- 颜色
local COLOR = {
    SAFE    = { r = 0.22, g = 0.78, b = 0.33 },  -- 绿
    WARNING = { r = 0.94, g = 0.69, b = 0.13 },  -- 黄
    STOP    = { r = 0.86, g = 0.18, b = 0.18 },  -- 红
    READY   = { r = 0.20, g = 0.65, b = 0.55 },  -- 青绿(静滞可用)
    OPENING = { r = 0.95, g = 0.78, b = 0.20 },  -- 金色(静滞打开阶段)
    OFFLINE = { r = 0.50, g = 0.50, b = 0.50 },  -- 灰
    BG      = { r = 0.06, g = 0.06, b = 0.09 },
    SUBTEXT = { r = 0.75, g = 0.75, b = 0.78 },
    USED    = { r = 0.30, g = 0.30, b = 0.35 },  -- 已用的图标: 暗灰
}

-- 静滞打开阶段的图标队列 (FIFO, 头部先弹出)
local openingQueue = {}            -- 当前待放的技能类型列表
local openingQueueEndTime = 0      -- 打开阶段结束时间 (GetTime + 10)
local openingLastIndex = 0         -- 上次已经"消耗"到的索引 (用于图标显示已用 / 未用)

--==========================================================================
-- 工具函数: 兼容新旧 API
--==========================================================================

-- 获取法术充能信息 (兼容 GetSpellCharges 和 C_Spell.GetSpellCharges)
-- 返回: currentCharges, maxCharges, nextChargeIn(秒), rechargeTotal(秒)
-- 12.1 缴械机制: 战斗中 currentCharges 等是 secret number, 一比较就抛错
-- 整体 pcall: 抛错 = 数据被加密, 返回 {secret=true} 让上层走本地充能模型
local function GetSpellChargeInfo(spellID)
    if not spellID then return nil end

    local ok, result = pcall(function()
        local currentCharges, maxCharges, cooldownStart, cooldownDuration, chargeModRate

        if C_Spell and C_Spell.GetSpellCharges then
            local info = C_Spell.GetSpellCharges(spellID)
            if info then
                currentCharges = info.currentCharges
                maxCharges = info.maxCharges
                -- 【v1.32.15 字段名修复】12.x 的 C_Spell.GetSpellCharges 返回表里字段叫
                --   `cooldownStartTime`(不是老 API 的 `cooldownStart`)。旧代码只读 `cooldownStart`
                --   -> 永远 nil -> nextChargeIn 永远算不出(恒 0) -> 脱战对账 API 侧"下一层 0.0s"
                --   其实是"读不到"的假 0, 时间校准从未生效。这里两名字都试, 优先取非 nil。
                cooldownStart = info.cooldownStartTime
                if cooldownStart == nil then cooldownStart = info.cooldownStart end
                cooldownDuration = info.cooldownDuration
                chargeModRate = info.chargeModRate
            end
        end

        if currentCharges == nil and GetSpellCharges then
            currentCharges, maxCharges, cooldownStart, cooldownDuration, chargeModRate = GetSpellCharges(spellID)
        end

        if currentCharges == nil then return nil end

        -- 计算下一层充能剩余秒数
        -- 【v1.32.12 修正】chargeModRate 是"UI 更新速率"(充能变快时 = 1/加速倍率),
        --   不是"加速倍率", 本地模型**不该除以它**。cooldownDuration/cooldownStart 本身
        --   就已经是游戏实时值(心流加速后时长=27.272), raw 就是真实的剩余秒。
        --   旧代码 raw/chargeModRate 会除以 0.909 = 放大 1.1 倍 -> 剩余时间虚增 10%。
        -- 【v1.32.15】cooldownStartTime 语义: 充能激活时 = 最近一次充能开始的时刻; 未激活(满层
        --   或刚放完还没开始充能) = 0。所以必须用 `cooldownStartTime > 0` 判"正在充能",
        --   而不是 truthy(0 在 Lua 里是 truthy, 但语义是"未激活")。
        local nextChargeIn = 0
        if currentCharges < maxCharges and cooldownStart and cooldownStart > 0 and cooldownDuration then
            local now = GetTime()
            local raw = (cooldownStart + cooldownDuration) - now
            if raw < 0 then raw = 0 end
            nextChargeIn = raw
        end

        return {
            currentCharges = currentCharges,
            maxCharges = maxCharges or 1,
            nextChargeIn = nextChargeIn,
            rechargeTotal = cooldownDuration or 30,
            -- v1.32.9: 原始字段一并带出, 供"充能时长还原"和 /DBSH charge 探针使用
            chargeModRate = chargeModRate,
            cooldownStart = cooldownStart,
            cooldownDuration = cooldownDuration,
        }
    end)

    if not ok then return { secret = true } end
    return result
end

-- 【v1.32.11 新增】secret number "去密" —— **只为诊断服务, 不喂给本地模型**。
--   12.1 战斗中 API 字段被加密: 参与 +-*/ 或比较会抛错, 但 tostring 仍可用,
--   于是 tostring -> tonumber 就能还原成普通数字。
--   ⚠️ 还原值只用于 /DBSH charge|secret 的"对账显示", 不参与 chargeModel ——
--      万一某个版本 tostring 也被拦(返回 "secret"/空), UnsecretNumber 会返回 nil,
--      自动退化回"读不到", 绝不污染功能。
local function UnsecretNumber(v)
    if v == nil then return nil end
    local okA, nA = pcall(function() return v + 0 end)
    if okA and type(nA) == "number" then return nA end
    -- 【v1.32.16 修复】12.x 里 cooldownStartTime 等字段战斗/某些状态会被加密成
    --   "secret string value"。tostring(secret) 返回的**还是 secret string**(不是解密数字),
    --   于是下面 `s ~= ""` 拿 secret 跟普通串比较 -> 在 tainted 环境直接抛
    --   "attempt to compare local 's' (a secret string value)"。整个比较/转换必须包进
    --   pcall: secret 比较/tonumber 抛错就被捕获, 退化回 nil(=读不到), 绝不崩诊断。
    local okB, s = pcall(tostring, v)
    if okB then
        local okC, n = pcall(function()
            if type(s) == "string" and s ~= "" then
                return tonumber(s)
            end
            return nil
        end)
        if okC and n then return n end
    end
    return nil
end

-- 字段描述串 (探针用): 类型(值)→还原值
local function FieldDesc(v)
    if v == nil then return "nil" end
    local okT, t = pcall(type, v)
    local okS, s = pcall(tostring, v)
    local n = UnsecretNumber(v)
    -- 【v1.32.16】s 可能是 secret string, 再 tostring 也用 pcall 护住(某些版本会抛)
    local okF, sf = pcall(tostring, s)
    local sShow = (okS and okF and s ~= nil) and sf or "<err>"
    return string.format("%s(%s)%s",
        okT and tostring(t) or "?",
        sShow,
        n and ("→" .. tostring(n)) or "")
end

-- 诊断用: 读原始充能字段 + 尝试去密
-- 返回: info{currentCharges,maxCharges,cooldownStart,cooldownDuration,chargeModRate}, 字段明细串
local function ProbeChargeRaw(spellID)
    if not spellID then return nil, "无 spellID" end
    local raw
    local ok0 = pcall(function()
        if C_Spell and C_Spell.GetSpellCharges then
            raw = C_Spell.GetSpellCharges(spellID)
        end
        if raw == nil and GetSpellCharges then
            local a, b, c, d, e = GetSpellCharges(spellID)
            if a ~= nil then
                raw = { currentCharges = a, maxCharges = b, cooldownStart = c,
                        cooldownDuration = d, chargeModRate = e }
            end
        end
    end)
    if not ok0 or raw == nil then return nil, "读不到 (API 返回空)" end

    -- v1.32.15: 12.x 新 API 字段名是 cooldownStartTime(老 API 才叫 cooldownStart), 两名字都试
    local startRaw = raw.cooldownStartTime
    if startRaw == nil then startRaw = raw.cooldownStart end

    local info = {
        currentCharges   = UnsecretNumber(raw.currentCharges),
        maxCharges       = UnsecretNumber(raw.maxCharges),
        cooldownStart    = UnsecretNumber(startRaw),
        cooldownDuration = UnsecretNumber(raw.cooldownDuration),
        chargeModRate    = UnsecretNumber(raw.chargeModRate),
    }
    local detail = string.format("cur=%s max=%s start=%s dur=%s rate=%s",
        FieldDesc(raw.currentCharges), FieldDesc(raw.maxCharges),
        FieldDesc(startRaw), FieldDesc(raw.cooldownDuration),
        FieldDesc(raw.chargeModRate))
    return info, detail
end

-- 由原始字段算"下一层剩余秒" (探针用)
-- 【v1.32.12】chargeModRate 是 UI 更新速率, 不参与剩余时间计算(见 GetSpellChargeInfo 注释)
local function RawNextChargeIn(info)
    if info and info.currentCharges and info.maxCharges
       and info.currentCharges < info.maxCharges
       and info.cooldownStart and info.cooldownDuration then
        local r = (info.cooldownStart + info.cooldownDuration) - GetTime()
        if r < 0 then r = 0 end
        return r
    end
    return 0
end

-- 获取法术冷却剩余秒数 (静滞等单充能技能用)
-- 返回: remaining(秒), total(秒), onCooldown(布尔)
local function GetSpellCooldownInfo(spellID)
    if not spellID then return nil end

    -- 同上: 战斗中 startTime/duration 可能是 secret number, pcall 兜底
    local ok, result = pcall(function()
        local start, duration, enabled, modRate

        if C_Spell and C_Spell.GetSpellCooldown then
            local info = C_Spell.GetSpellCooldown(spellID)
            if info then
                start = info.startTime
                duration = info.duration
                enabled = info.enabled
                modRate = info.modRate
            end
        end

        if not start and GetSpellCooldown then
            start, duration, enabled, modRate = GetSpellCooldown(spellID)
        end

        if not start then return nil end

        local now = GetTime()
        local remaining = 0
        if duration and duration > 0 and start then
            remaining = (start + duration) - now
            if remaining < 0 then remaining = 0 end
        end

        return {
            remaining = remaining,
            total = duration or 0,
            -- onCooldown 用 remaining 判断 (12.1 静滞某些状态下 duration 可能=0 但 remaining 还在倒计时)
            onCooldown = (remaining > 1.5),
        }
    end)

    if not ok then return { secret = true } end
    return result
end

--==========================================================================
-- 本地充能模型 (12.1 缴械机制: 战斗中充能API返回secret值, 用本地推算代替)
-- 数据源全本地: 出战斗用真API校准, 绿喷施法事件扣层, 时空畸体减5s充能, 30s时钟充能
-- v1.17 重构: 用"剩余充能绝对时间戳"精确倒计时, 支持时空畸体减CD
--==========================================================================

-- 前向声明: Trace 定义在静滞状态机段, 这里先声明让本段函数(校准/减CD)也能引用
-- (v1.32 修复: 此前本段的 Trace 调用实际引用的是不存在的全局 Trace)
local Trace

local chargeModel = {
    currentCharges = nil,  -- 当前层数 (nil=尚未校准, 无法推算)
    maxCharges = 2,
    rechargeTotal = 30,    -- 单层充能总时间 (有API真值就更新缓存)
    nextChargeAt = nil,    -- 下一层充好的绝对时间戳 (GetTime()) — 满层时为 nil
}

-- v1.32.9 诊断: 绿喷充能"记账流水" + v1.36.36 起纳入**静滞状态变迁**。
--   绿喷层数=API校准+施放扣层+到期结算三者叠加, 出问题时肉眼很难复现, 这里把事件按时间记下来,
--   /DBSH charge 一键导出; 战斗中用 /DBSH next 也能看到最近几条(**纯本地记录, 不碰 API**)。
--   ⚠️ 容量 10 -> 20 (v1.36.36): 静滞一轮要占 3 条(激活/存满起算/释放), 而"蓄力取消"很频繁,
--      10 条会被绿喷记录挤满, 静滞那 3 条活不到你看的时候。
local CHARGE_DIAG_MAX = 20
local chargeDiag = { events = {} }
local function ChargeDiag(msg)
    local log = chargeDiag.events
    log[#log + 1] = string.format("[%.1fs] %s", GetTime(), msg)
    if #log > CHARGE_DIAG_MAX then table.remove(log, 1) end
end

-- 时空畸体给绿喷充能减的秒数 (**仅当点了"诺兹多姆的讲义"天赋时才生效**)
local TEMPORAL_ANOMALY_CD_REDUCTION = 5

-- 【v1.32.10 真凶修正】"诺兹多姆的讲义" (Nozdormu's Teachings, spellID 376237)
--   效果: 施放时空畸体时, 使你的蓄力技能(绿喷/红喷)冷却减少 5 秒。
--   ⚠️ 它与"时光屏障"(Temporal Barrier) 是**互斥的选择节点** (Patch 12.0.5 起;
--      来源: warcraft.wiki.gg/wiki/Nozdormu's_Teachings)。
--   → 没点这个天赋时, 溜溜球**根本不减绿喷CD**!
--     旧版无条件每次减 5s, 一场战斗凭空多减几十秒 -> 插件绿喷充能虚快,
--     实机表现正是老板报的"游戏0/2, 插件1/2"。而静滞CD不吃溜溜球, 所以能对上。
--   未知(nil)时按"不生效"处理: 宁可少减也不虚快 (检测结果见 /DBSH charge)。
local NOZDORMU_TEACHINGS_SPELL_ID = 376237
local hasNozdormuTeachings = nil

-- 用真实API数据校准 (secret/nil 不动模型)
-- 出战斗时 API 可信, 精确校准: 层数 + 下一层充好时间
-- 校验一个值是否是"安全的普通数字"(非 secret, 可参与算术)。
-- 12.1 战斗中 secret number 的 tostring 正常, 但一参与 +-*/ 就抛错。
-- 用 pcall 做 +0 探测: 抛错即 secret。
local function IsSafeNumber(v)
    if v == nil then return false end
    local ok = pcall(function() return v + 0 end)
    return ok
end

-- v1.36.26: 诊断采样期间"暂停一切官方值校准"的总开关。
--   ⚠️ **必须声明在 SyncChargeModel 之前** —— Lua 是词法作用域, 函数体只捕获**声明在它前面**的 local;
--   若声明在后面, 函数体里读到的会是**全局变量**(nil), 守卫静默失效(这个坑真实踩到过)。
--   声明点在这里; 1489 行附近只做赋值(=false), 不再重复写 local(否则会创建**第二个**变量)。
local probeSuspendSync = false

local function SyncChargeModel(dreamInfo)
    -- v1.36.26 守卫必须放在**函数体内**, 不能只加在事件分支上 ——
    --   老板 2026-09-21 指出: "脱战永远测不出差异"。根因 = EvaluateState() 每帧调
    --   SyncChargeModel(1921 行), 而 UpdateUI 每帧跑 → 采样期间模型被官方值**每帧拉平**。
    --   表现: 绿喷差永远 0.00s(假象); 而静滞因为 SyncStasisCooldownFromAPI 的守卫在函数内(1492),
    --   所以静滞测得出 -4.5s 那种真偏差 —— 两者行为不一致正说明绿喷这条被漏掉了。
    --   注: /DBSH time 的"起点对齐"在 probeSuspendSync=true **之前**调用, 不受影响。
    if probeSuspendSync then return end
    if dreamInfo and not dreamInfo.secret and dreamInfo.currentCharges then
        -- v1.30: currentCharges/maxCharges 本身也可能是 secret(战斗中 API 透出的值),
        --   一比较就抛错。这里直接跳过校准(等出战斗再校准), 不污染本地模型。
        if not IsSafeNumber(dreamInfo.currentCharges) or not IsSafeNumber(dreamInfo.maxCharges or 2) then
            Trace("校准跳过: currentCharges/maxCharges 疑似 secret")
            return
        end
        local maxCharges = dreamInfo.maxCharges or 2
        local prevCharges = chargeModel.currentCharges
        local prevRecharge = chargeModel.rechargeTotal
        chargeModel.maxCharges = maxCharges
        chargeModel.currentCharges = dreamInfo.currentCharges
        -- 【v1.32.12 重构】rechargeTotal 一律锁定基准 30, **不采用** API 的实时 cooldownDuration。
        --   原因: 心流加速期间 API 会给出 27.272(=30/1.1) 这种"被加速后的时长"。
        --   若把它写进 rechargeTotal, 涨层结算(nextChargeAt += recharge)会自动按短时长走,
        --   而 TickFlowAcceleration 又在逐帧 nextChargeAt -= delta —— **两条加速路径叠加会双重加速**。
        --   正确设计(二选一, 选本地积分): rechargeTotal 固定 30, 心流加速**只**由逐帧积分实现;
        --   脱战校准靠下面 nextChargeIn(已修正为不除 chargeModRate)精确对齐 nextChargeAt 即可。
        chargeModel.rechargeTotal = DREAM_BREATH_CHARGE_BASE
        -- 精确校准下一层充好时间
        if dreamInfo.currentCharges < maxCharges then
            local nextIn = dreamInfo.nextChargeIn
            -- 【v1.32.14 根因修复】nextChargeIn 有两种语义, 靠 cooldownStart 区分:
            --   (a) cooldownStart 有值: nextIn = 真实剩余秒(可能被 clamp 到 0 = "那层刚充好")。
            --       旧代码 `nextIn > 0` 把 0 当"读不到"走 elseif 兜底 -> 若模型 nextChargeAt
            --       恰已过期, 被硬重置 now+30, 丢掉"那层已充好"事实, 凭空多算 30s
            --       -> 脱战对账"模型1层/24.7s vs API1层/0.0s"差一整层。
            --       修复: cooldownStart 有值就信任 nextIn(含 0), nextChargeAt = now + nextIn;
            --       nextIn=0 时 nextChargeAt=now, 下轮 GetLocalChargeInfo 的 while 立即 +1 层。
            --   (b) cooldownStart = nil: 不在充能(刚放完绿喷/满层过渡), nextIn 恒 0 无意义,
            --       走兜底(仅当原时钟过期/丢失才 now+recharge), 不能动 nextChargeAt。
            local hasStart = (dreamInfo.cooldownStart ~= nil)
                and (not IsSafeNumber(dreamInfo.cooldownStart) or dreamInfo.cooldownStart > 0)
            if hasStart and IsSafeNumber(nextIn) then
                chargeModel.nextChargeAt = GetTime() + nextIn
            elseif not chargeModel.nextChargeAt or chargeModel.nextChargeAt < GetTime() then
                -- nextChargeIn 读不到/cooldownStart 无效时才兜底, 不粗暴 now+30,
                --   仅当原时钟已过期/丢失才重设。
                chargeModel.nextChargeAt = GetTime() + chargeModel.rechargeTotal
            end
        else
            -- 满层, 无下一层充能
            chargeModel.nextChargeAt = nil
        end
        -- v1.32.9 诊断: 层数/时长被 API 改动时记流水 (排查"模型与游戏对不上"的关键证据)
        if prevCharges ~= chargeModel.currentCharges or prevRecharge ~= chargeModel.rechargeTotal then
            ChargeDiag(string.format("API校准 层%s->%s, 时长%s->%s (API dur=%s rate=%s)",
                tostring(prevCharges), tostring(chargeModel.currentCharges),
                tostring(prevRecharge), tostring(chargeModel.rechargeTotal),
                tostring(dreamInfo.cooldownDuration), tostring(dreamInfo.chargeModRate)))
        end
    end
end

-- v1.36.37 🔴 统一的"下一层充能时长" —— **必须与 ChargeModelConsume 的折算口径一致**
--   为什么(老板 2026-09-21 长战斗数据, 脱战对账 `模型1层/6.5s vs API2层/0.0s 差-1层/+6.5s`):
--     "某一层充能完成"那一刻, **新一轮充能的时长也应按当时的 rate 折算** ——
--     这和"施放扣层起算"是完全同一个物理场景(一次新的充能开始)。
--     但旧代码在完成分支里写死 `+recharge(=30)`, 而 `ChargeModelConsume` 会折成 27.27
--     → **两条路径口径不一致**: 窗口开着时每完成一层, 模型就比游戏慢 2.73s,
--       长战斗里叠十几层就是"整整一层"的滞后(正是长战斗漂移的来源)。
--   注: 折的是"起算时长"; 之后窗口开/关的变化由 FlowConvertRemaining 换算接手(与扣层路径同构)。
local function LocalRechargeDuration()
    local base = (db and db.customRecharge) or chargeModel.rechargeTotal
    if not IsSafeNumber(base) then base = DREAM_BREATH_CHARGE_BASE end
    if (flowState.rank or 0) > 0 and flowUntil > GetTime() then
        base = base / (1 + FLOW_RATE_PER_RANK * flowState.rank)
    end
    return base
end

-- 本地推算当前充能 (战斗中 dreamInfo 的替身)
-- 核心: 用 nextChargeAt 绝对时间戳倒计时, 支持时空畸体减CD
local function GetLocalChargeInfo()
    if chargeModel.currentCharges == nil then return nil end
    -- v1.30: rechargeTotal 若已被 secret 污染, 直接回退到安全默认 30s,
    --   否则后续 nextChargeAt+recharge 会把 nextChargeAt 也污染成 secret。
    local recharge = (db and db.customRecharge) or chargeModel.rechargeTotal
    if not IsSafeNumber(recharge) then
        recharge = 30
        chargeModel.rechargeTotal = 30
    end

    -- v1.22: 未满层但 nextChargeAt 丢失(nil)时, 主动开始充能,
    --   否则战斗中绿喷永远不涨层(卡在"绿喷1/2"不更新)。
    --   场景: 1层进战斗, 进战斗校准因 secret 失败, nextChargeAt 停在 nil,
    --   导致绿喷实际涨到2层了但本地模型还显示1层。
    if chargeModel.currentCharges < chargeModel.maxCharges
       and not chargeModel.nextChargeAt then
        -- v1.36.37: 用 LocalRechargeDuration()(含心流折算) 而不是写死的 recharge
        chargeModel.nextChargeAt = GetTime() + LocalRechargeDuration()
    end

    -- 先把到期充能结算进层数 (可能连充多层)
    while chargeModel.currentCharges < chargeModel.maxCharges
          and chargeModel.nextChargeAt
          and GetTime() >= chargeModel.nextChargeAt do
        chargeModel.currentCharges = chargeModel.currentCharges + 1
        if chargeModel.currentCharges >= chargeModel.maxCharges then
            chargeModel.nextChargeAt = nil
        else
            -- v1.36.37 🔴 关键修复: 这里原本是 `+ recharge`(写死 30), 与 ChargeModelConsume 的
            --   折算口径不一致 -> 窗口开着时每完成一层模型慢 2.73s -> 长战斗累积成一整层。
            chargeModel.nextChargeAt = chargeModel.nextChargeAt + LocalRechargeDuration()
        end
        -- v1.32.10 诊断: 涨层是最直观的对照点 (游戏图标 +1 的瞬间), 必须留痕
        -- v1.36.37: 顺带打出**推进后的下一层时钟** —— 长战斗里"模型为什么慢一层"就靠这行判
        ChargeDiag(string.format("充能完成 -> %s/%s 层 (下一层 %s)",
            tostring(chargeModel.currentCharges), tostring(chargeModel.maxCharges),
            chargeModel.nextChargeAt and string.format("%.1fs后", chargeModel.nextChargeAt - GetTime())
                or "满层"))
    end

    local nextIn = 0
    if chargeModel.currentCharges < chargeModel.maxCharges and chargeModel.nextChargeAt then
        nextIn = math.max(0, chargeModel.nextChargeAt - GetTime())
    end

    return {
        currentCharges = chargeModel.currentCharges,
        maxCharges = chargeModel.maxCharges,
        nextChargeIn = nextIn,
        rechargeTotal = recharge,
    }
end

-- 施放绿喷: 本地扣一层
-- 若原本满层, 扣后进入充能 (下一层要完整 rechargeTotal 秒)
local function ChargeModelConsume(spellID)
    if chargeModel.currentCharges == nil then return end
    local wasFull = chargeModel.currentCharges >= chargeModel.maxCharges
    local before = chargeModel.currentCharges
    chargeModel.currentCharges = math.max(0, chargeModel.currentCharges - 1)
    -- v1.19 修复: 扣层后若没在充能(如1层时nextChargeAt=nil), 必须立即开始充能,
    --   否则0层永远不涨层(卡死0/2)。原来只在 wasFull 时设置 nextChargeAt,
    --   导致"1层放绿喷→0层"后 nextChargeAt 仍是 nil, 充能时钟丢失。
    -- v1.36.16 心流折算: 新一层充能"起算"时, 若心流窗口开着, 游戏把总时长折算(30 → 30/1.1 = 27.27)。
    --   实测(01:08): 新层剩余 26.7s ≈ 27.27 − 流逝 ✓ (若是 30 则该是 29.4 ✗)。
    --   → 绿喷改用与静滞相同的"折算"模型, **不再逐年逐帧积分**(引擎 Δ 恒为 -1.0 已证, 见 TickFlowAcceleration)。
    --   前提: 无天赋时 rank=0 / 窗口没开 → dur 就是 rechargeTotal(30), 与"不点心流时准"的既有行为一致 ✓
    local dur = chargeModel.rechargeTotal
    local discounted = false
    if (flowState.rank or 0) > 0 and flowUntil > GetTime() then
        dur = dur / (1 + FLOW_RATE_PER_RANK * flowState.rank)
        discounted = true
    end
    if wasFull then
        chargeModel.nextChargeAt = GetTime() + dur
    elseif chargeModel.currentCharges < chargeModel.maxCharges
           and (not chargeModel.nextChargeAt or chargeModel.nextChargeAt < GetTime()) then
        -- 非满层且没在充能: 立即开始充下一层
        chargeModel.nextChargeAt = GetTime() + dur
    end
    -- v1.32.9 诊断流水
    -- v1.36.20: 打印**本次实际采用**的充能时长(dur), 并标注是否折算过心流 ——
    --   /DBSH track 只能看到"结果差多少", 看不到"折算有没有真的发生", 靠这条流水补上。
    ChargeDiag(string.format("绿喷施放 spellID=%s: 层%s->%s/%s, 本次充能%.2fs(基准%.1f)%s",
        tostring(spellID), tostring(before), tostring(chargeModel.currentCharges),
        tostring(chargeModel.maxCharges), dur, chargeModel.rechargeTotal,
        discounted and " [已折算心流]" or ""))
end

-- 时空畸体施放: 绿喷充能减CD —— **仅当点了"诺兹多姆的讲义"天赋时才生效**
-- 【v1.32.10 真凶】v1.32.9 以为"减CD量被心流放大"是主因, 其实不是:
--   真正的问题是**这个天赋压根没点时插件也在减**。Nozdormu's Teachings 与
--   Temporal Barrier 是互斥选择节点, 老板点的是"时光屏障" -> 游戏里溜溜球不减
--   绿喷CD, 插件却每次硬减 5s, 一场战斗多减几十秒 -> 充能虚快(游戏0/2 插件1/2)。
--   (减CD量固定 5s、不随心流放大 —— 这点 v1.32.9 的结论保留正确)
-- 只在"未满层且正在充能"时有效 (满层减CD无意义)
local function TemporalAnomalyReduceCD()
    if chargeModel.currentCharges == nil then return end
    -- 【只拦"确认未点"】检测拿不到数据(nil)时**仍然减**, 保持既有行为不误伤。
    --   (老板 2026-09-12 截图确认已点: 等级1/1, SpellID 376237)
    if hasNozdormuTeachings == false then
        ChargeDiag("溜溜球减CD跳过: 确认未点'诺兹多姆的讲义'")
        return
    end
    local reduction = TEMPORAL_ANOMALY_CD_REDUCTION
    -- v1.30: 整体 pcall 兜底。nextChargeAt 可能被 secret number 污染(见 GetLocalChargeInfo
    --   的 recharge 加法), 减法一执行就抛错, 会中断溜溜球的 SUCCEEDED 处理导致计数失败。
    --   减CD失败不应阻断主流程(计数), 静默跳过即可。
    local ok = pcall(function()
        -- 【v1.32.13 根因修复】减 CD 前**必须先结算已到期的层数**。
        --   GetLocalChargeInfo 内部有 while 结算循环: 若 nextChargeAt 已经 <= now(那层
        --   其实早已充好、只差结算), 会就地 +1 层并把 nextChargeAt 顺延 +recharge。
        --   旧代码跳过结算直接 nextChargeAt-5, 会把"已到期的时钟"拨到更远的过去(-0.8s),
        --   结算后又 +30 -> 29.2s, 相当于对游戏**已满的那层**凭空多减 5s(游戏端那层早满,
        --   减CD对它毫无影响), 一场战斗多次溜溜球 -> 逐次累积 -> 脱战对账虚快十几秒。
        --   (实机 40959.8s 流水: "减充能->下一层提前到-0.8s" 与 "API校准层1->2" 同帧出现,
        --    正是"已充好仍被减"的铁证)
        local settled = GetLocalChargeInfo()
        -- 结算后若已满层, 减 CD 对游戏毫无意义(游戏端充能本已停住), 直接跳过。
        if settled and settled.currentCharges >= settled.maxCharges then
            ChargeDiag("溜溜球减CD跳过: 结算后已满层, 减CD无效")
            return
        end
        if chargeModel.nextChargeAt and chargeModel.currentCharges < chargeModel.maxCharges then
            chargeModel.nextChargeAt = chargeModel.nextChargeAt - reduction
            Trace(string.format("时空畸体减绿喷充能%.1fs, 下一层充好提前到%.0fs", reduction, chargeModel.nextChargeAt))
            ChargeDiag(string.format("时空畸体减充能%.1fs -> 下一层提前到+%.1fs",
                reduction, chargeModel.nextChargeAt - GetTime()))
        end
    end)
    if not ok then
        Trace("时空畸体减CD失败(疑似secret污染), 已跳过")
    end
end

-- 静滞按钮当前是否可用 (存满3技能后按钮高亮 = true, STORING期间按钮灰 = false)
-- v1.31: 用这个作为"存满"信号 (老板23:40实机验证: STORING期间=false, 存满瞬间跳=true)
-- pcall 包裹: 战斗中若某版本此 API 也抛错/加密, 返回 nil 让调用方走兜底
local function IsStasisUsable()
    local ok, usable = pcall(function()
        if C_Spell and C_Spell.IsSpellUsable then
            return C_Spell.IsSpellUsable(STASIS_SPELL_ID)
        end
        if IsUsableSpell then
            return IsUsableSpell("Stasis") or IsUsableSpell(STASIS_SPELL_ID)
        end
        return nil
    end)
    if ok then return usable end
    return nil
end

-- 获取法术图标纹理路径 (pcall 兜底: 战斗中纹理API万一也被加密, 返回nil不让UI冻结)
local function GetSpellIconPath(spellID)
    if not spellID then return nil end
    local ok, p = pcall(function()
        if C_Spell and C_Spell.GetSpellTexture then
            return C_Spell.GetSpellTexture(spellID)
        end
        if GetSpellTexture then
            return GetSpellTexture(spellID)
        end
        return nil
    end)
    if ok and p then return p end
    return nil
end

--==========================================================================
-- 资格门槛检测 (v1.32 功能二)
-- 本插件只对"点了静滞天赋的塑焰恩护唤魔师"有用。其他职业/专精/英雄天赋
-- 的玩家装了它应该自动禁用(隐藏UI、不处理施法事件), 避免干扰。
-- 职业/专精/天赋属于角色配置API, 不受12.1战斗加密影响, 但仍全部 pcall + nil 兜底。
--==========================================================================

-- 前向声明: UpdateUI / frame / RefreshConfigPanel 定义在后面的 UI 段,
-- RefreshEligibility 需要在资格翻转时调用/操作它们 (风格同 Trace 的前向声明)
local UpdateUI
local frame
local RefreshConfigPanel

-- 资格缓存: eligible=nil 表示尚未检测 (此时不拦截施法事件, 避免登录初期丢事件)
--   true=已确认合格(启用) / false=已确认不合格(禁用) / nil=未知(不拦, 等事件重检)
local eligibility = { eligible = nil, reason = "", checks = nil }

-- 手动强制显示标志 (v1.32.3)
--   资格不合格被自动隐藏后, 老板可在控制台点"启用"强制显示 (覆盖资格拦截)。
--   仅内存级、不持久化(重启回归自动托管); 资格恢复合格时自动清零。
local forceEnabled = false

-- 主 UI 的三态 (v1.32.3): closed=用户关了 / blocked=资格不符自动禁用 / shown=正常显示
-- 控制台文字与按钮点击行为都以此为准
-- 注意: 本函数必须定义在 `local eligibility` 之后, 否则闭包引用到的是全局 eligibility(nil)
local function GetUIStatus()
    if not db or not db.enabled then return "closed" end
    if eligibility.eligible == false and not forceEnabled then return "blocked" end
    return "shown"
end

-- 前向声明: GetTalentRankByName 定义在心流状态段(靠后), 本段查英雄天赋节点要用它
local GetTalentRankByName

-- 塑焰者英雄天赋名字 (兼容中英文客户端)
local FLAMESHAPER_HERO_NAMES = { ["塑焰者"] = true, ["Flameshaper"] = true }

-- 塑焰者英雄天赋 spec ID 兜底表
-- 【实测来源】2026-09-12 老板切到塑焰奶龙时 /DBSH status 探针显示
--   GetActiveHeroTalentSpec() -> a=37(number) b=nil(nil)
--   即 12.x 该 API 只返回数字 ID, 且 GetHeroTalentSpecInfo 拿不到名字。
-- 【安全设计】只做正向匹配: 命中才判"是塑焰者"; 不命中一律保持"未知(不拦)",
--   绝不置 false -> 即使此表有误也只是漏判, 不会误杀合格玩家。
local FLAMESHAPER_HERO_SPEC_IDS = { [37] = true }

-- 通用: 检测玩家是否已学某法术/天赋 (多 API 兜底, 兼容 12.0 API 变动)
--   ids = 候选 spellID 数组, 任一命中即算已学 (正向匹配, 宁松勿杀)
--   返回 true=已学 / false=确定未学(所有尝试都明确返回 false) / nil=拿不到数据(未知)
--   注意: 只有"所有尝试都明确 false"才敢判 false —— 任何拿不到数据的 API 都不算数
local function CheckSpellKnownAny(ids)
    if type(ids) ~= "table" then return nil end
    local sawFalse = false
    for _, id in ipairs(ids) do
        if IsPlayerSpell then
            local ok1, v1 = pcall(IsPlayerSpell, id)
            if ok1 and v1 ~= nil then
                if v1 == true then return true end
                sawFalse = true
            end
        end
        if C_SpellBook and C_SpellBook.IsSpellKnown then
            local ok2, v2 = pcall(C_SpellBook.IsSpellKnown, id)
            if ok2 and v2 ~= nil then
                if v2 == true then return true end
                sawFalse = true
            end
        end
        if IsSpellKnown then
            local ok3, v3 = pcall(IsSpellKnown, id)
            if ok3 and v3 ~= nil then
                if v3 == true then return true end
                sawFalse = true
            end
        end
    end
    if sawFalse then return false end
    return nil
end

-- 五项检查: 职业 / 恩护专精 / 塑焰者英雄天赋 / 静滞天赋 / 心灵之火天赋
-- 返回: (bool eligible, string reason); 各项明细存入 eligibility.checks (供 /DBSH status)
local function CheckEligibility()
    local d = {}
    local function done(elig, reason)
        eligibility.checks = d
        return elig, reason
    end

    -- a. 职业: 必须是唤魔师
    local okClass, classFile = pcall(function()
        if not UnitClass then return nil end
        return select(2, UnitClass("player"))
    end)
    if not (okClass and classFile == "EVOKER") then
        d.class = "✗"
        return done(false, "非唤魔师")
    end
    d.class = "✓"

    -- b. 专精: 必须是恩护 (Preservation, spec ID 1468)
    --    12.0 起 GetSpecialization/GetSpecializationInfo 已移除, 改用 PlayerUtil.GetCurrentSpecID()
    local okSpec, specId = pcall(function()
        if PlayerUtil and PlayerUtil.GetCurrentSpecID then
            return PlayerUtil.GetCurrentSpecID()
        end
        if GetSpecialization and GetSpecializationInfo then
            local idx = GetSpecialization()
            if idx == nil then return nil end
            return GetSpecializationInfo(idx)
        end
        return nil
    end)
    if not okSpec or specId == nil then
        -- 数据未就绪: 有缓存用缓存, 无缓存返回 nil(未知=不拦也不固化), 等事件重检
        d.spec = "未就绪"
        if eligibility.eligible ~= nil then
            return done(eligibility.eligible, "数据未就绪")
        end
        return done(nil, "数据未就绪")
    end
    if specId ~= 1468 then
        d.spec = "✗"
        return done(false, "非恩护专精")
    end
    d.spec = "✓"

    -- c. 英雄天赋: 必须是塑焰者 (Flameshaper)
    --    主判据: 天赋树里找"塑焰者"节点 (复用 GetTalentRankByName, 与心流状态同一套机制)
    --    兜底:   C_ClassTalents.GetActiveHeroTalentSpec (12.x 返回形态不定, 多形态兼容)
    --    【v1.32.1 修复】拿不到信息时**绝不能提前 return 放行** —— 那样会把后面的静滞
    --    检查整段短路掉, 门槛形同虚设 (老板没点静滞却被判"已启用"就是这么来的)
    local unknown = false
    local heroState = nil          -- true=是塑焰者 / false=不是 / nil=拿不到
    if GetTalentRankByName then
        local heroRank = GetTalentRankByName(FLAMESHAPER_HERO_NAMES)
        if heroRank and heroRank > 0 then heroState = true end
    end
    if heroState == nil and C_ClassTalents and C_ClassTalents.GetActiveHeroTalentSpec then
        local okHero, heroName, heroID = pcall(function()
            local a, b = C_ClassTalents.GetActiveHeroTalentSpec()
            local name, id = nil, nil
            if type(a) == "table" then
                name = a.name or a.Name or a.heroTalentSpecName
                id   = a.ID or a.id or a.heroTalentSpecID
                if not name and id and C_ClassTalents.GetHeroTalentSpecInfo then
                    local info = C_ClassTalents.GetHeroTalentSpecInfo(id)
                    if info then name = info.name or info.Name end
                end
            elseif type(a) == "number" then
                -- 12.x 实测形态: 只返回数字 ID (老板 2026-09-12 探针 a=37)
                id = a
                if C_ClassTalents.GetHeroTalentSpecInfo then
                    local info = C_ClassTalents.GetHeroTalentSpecInfo(a)
                    if info then name = info.name or info.Name end
                end
            end
            if not name and type(b) == "string" then name = b end
            return name, id
        end)
        if okHero then
            if heroName ~= nil then
                heroState = (FLAMESHAPER_HERO_NAMES[heroName] == true)
            elseif heroID ~= nil and FLAMESHAPER_HERO_SPEC_IDS[heroID] then
                -- 名字拿不到时用 ID 兜底 (只正向匹配, 见常量处注释)
                heroState = true
            end
        end
        -- 存原始解析结果供 /DBSH status 探针展示
        d.heroName = heroName
        d.heroID   = heroID
    end
    if heroState == true then
        d.hero = "✓"
    elseif heroState == false then
        d.hero = "✗"
        return done(false, "非塑焰者英雄天赋")
    else
        -- 拿不到就不拦(避免误杀合格玩家), 但下面静滞检查必须继续跑
        d.hero = "未识别(不拦)"
        unknown = true
    end

    -- d. 静滞天赋: 必须已学 370537 —— 硬门槛之一
    local stasisKnown = CheckSpellKnownAny({ STASIS_SPELL_ID })
    if stasisKnown == true then
        d.stasis = "✓"
    elseif stasisKnown == false then
        d.stasis = "✗"
        return done(false, "未点静滞天赋")
    else
        d.stasis = "未识别(不拦)"
        unknown = true
    end

    -- e. 心灵之火 (Inner Fire) 天赋: 必须已点 —— 硬门槛之二 (老板 2026-09-12 要求)
    --    主判据: spellID 检测 (1242745 天赋本体 / 1242747 法术形态, 任一命中即算已点)
    --    兜底:   天赋树节点名匹配 (与心流状态/英雄天赋同一套机制)
    --    判 false 必须两个通道都明确否定才对, 否则一律"未知不拦"(绝不误杀)
    local innerFire = CheckSpellKnownAny(INNERFIRE_TALENT_IDS)
    if innerFire ~= true and GetTalentRankByName then
        local fireRank = GetTalentRankByName(INNERFIRE_NAMES, INNERFIRE_ID_SET)
        if fireRank and fireRank > 0 then innerFire = true end
    end
    if innerFire == true then
        d.innerfire = "✓"
    elseif innerFire == false then
        d.innerfire = "✗"
        return done(false, "未点心灵之火天赋")
    else
        d.innerfire = "未识别(不拦)"
        unknown = true
    end

    -- f. 诺兹多姆的讲义 (Nozdormu's Teachings, 376237) —— **不是资格门槛**, 只缓存状态。
    --    它决定"时空畸体是否减绿喷充能CD"(与时光屏障互斥, 见常量处注释)。
    --    刻意不并入 unknown 判定: 拿不到数据也不该影响插件可用性。
    hasNozdormuTeachings = CheckSpellKnownAny({ NOZDORMU_TEACHINGS_SPELL_ID })
    d.teachings = (hasNozdormuTeachings == true and "✓")
               or (hasNozdormuTeachings == false and "✗") or "未识别"

    if unknown then
        return done(nil, "数据未就绪")
    end
    return done(true, "OK")
end

-- 数据未就绪时的自补重试计数 (上限 3 次, 防死循环)
local eligibilityRetries = 0

-- 刷新资格缓存, 状态翻转时静默隐藏/恢复UI (v1.34.1: 不再打聊天提示, 防刷屏)
local function RefreshEligibility()
    local oldEligible = eligibility.eligible
    local ok, newEligible, reason = pcall(CheckEligibility)
    if not ok then
        -- 检测本身异常: 保持旧状态不翻转
        Trace("资格检测异常, 保持原状态")
        return
    end
    eligibility.eligible = newEligible
    eligibility.reason = reason or ""
    Trace(string.format("资格检测: eligible=%s reason=%s", tostring(newEligible), tostring(reason)))

    -- 【v1.32.2】未确定(天赋数据尚未就绪, 常见于登录/切专精的瞬间): 1 秒后自补一次。
    -- 解决"切回塑焰时 UI 没有第一时间显示" —— 首次事件来时数据还没到, 只靠事件会一直等。
    if newEligible == nil then
        if eligibilityRetries < 3 and C_Timer and C_Timer.After then
            eligibilityRetries = eligibilityRetries + 1
            C_Timer.After(1, function() pcall(RefreshEligibility) end)
        end
    else
        eligibilityRetries = 0
    end

    if oldEligible == newEligible then return end

    if newEligible == false then
        -- 有资格->没资格, 或首次检测不合格(旧值nil): 静默隐藏主UI
        -- v1.34.1: 删掉聊天 print —— 换天赋/洗点会反复触发, 刷屏; 隐藏/显示本身就是可见反馈
        if frame then frame:Hide() end
    elseif newEligible == true and oldEligible == false then
        -- 没资格->有资格: 静默恢复 + 刷新UI (首次检测合格旧值nil时不触发)
        forceEnabled = false   -- v1.32.3: 资格恢复合格, 清掉手动强制标记, 回归自动托管
        if db and UpdateUI then pcall(UpdateUI) end
    end
    -- v1.32.3: 控制台状态文字同步 (含"未启用(资格不符)"态)
    if RefreshConfigPanel then pcall(RefreshConfigPanel) end
end

-- v1.32.3: 天赋类事件的防抖重检
--   在天赋界面里连续增删天赋点会触发多次事件, 且天赋数据可能还没落地。
--   防抖 0.4s: 期间只排队一次(已有排队则不重复排队), 等数据稳定后再判, 避免误判/闪烁。
local eligibilityDebouncePending = false
local function RefreshEligibilityDebounced()
    if eligibilityDebouncePending then return end
    if not (C_Timer and C_Timer.After) then
        pcall(RefreshEligibility)
        return
    end
    eligibilityDebouncePending = true
    C_Timer.After(0.4, function()
        eligibilityDebouncePending = false
        pcall(RefreshEligibility)
    end)
end

--==========================================================================
-- 核心算法
--==========================================================================

-- 模拟: 从当前状态起, 经过 seconds 秒后, 绿喷会有几层
-- currentCharges: 当前层数 (0/1/2)
-- nextChargeIn:   下一层充好还需多少秒 (满层时传 0)
-- rechargeTotal:  充能所需总秒数 (约30)
-- 返回: 预测层数 (上限 maxCharges, 默认2)
local function SimulateCharges(seconds, currentCharges, nextChargeIn, rechargeTotal, maxCharges)
    maxCharges = maxCharges or 2
    local charges = currentCharges
    local timeLeft = seconds

    -- 满层直接返回
    if charges >= maxCharges then return maxCharges end

    -- 如果当前没在充能(nextChargeIn==0)但不满, 说明刚刚用掉, 下次充能需要 rechargeTotal 秒
    local nextIn = (nextChargeIn and nextChargeIn > 0) and nextChargeIn or rechargeTotal

    while charges < maxCharges do
        if nextIn <= timeLeft then
            charges = charges + 1
            timeLeft = timeLeft - nextIn
            nextIn = rechargeTotal -- 之后再充需要完整时间
        else
            break
        end
    end

    if charges > maxCharges then charges = maxCharges end
    return charges
end

--==========================================================================
-- 预测: 如果现在用一次绿喷, 静滞CD好时绿喷会有几层
-- 老板需求: 只用绿喷实时30s充能, 不考虑时空畸体减CD
-- 这是核心判断: <2 则不能再喷
--==========================================================================
local function ProjectChargesAfterCast(dreamInfo, stasisInfo)
    if not dreamInfo or not stasisInfo then return nil end

    local afterCast = dreamInfo.currentCharges - 1
    if afterCast < 0 then return 0 end

    -- 用掉一层后:
    -- 如果原本满层(2), 用掉变1层, 下次充能用 rechargeTotal (满层用掉需要完整充能时间)
    -- 如果原本1层, 用掉变0层, 下次充能按实际读出的 nextChargeIn 计
    local rechargeTotal = dreamInfo.rechargeTotal
    local nextIn
    if dreamInfo.currentCharges >= dreamInfo.maxCharges then
        nextIn = rechargeTotal
    else
        nextIn = dreamInfo.nextChargeIn
    end

    return SimulateCharges(
        stasisInfo.remaining,
        afterCast,
        nextIn,
        rechargeTotal,
        dreamInfo.maxCharges
    )
end

-- 计算静滞使用次数计数器上限
-- 静滞CD总时间(约90s)内, 绿喷可用次数 = 起始层 + 充能次数 - 下次静滞需要的2层
-- 返回: 已用次数, 上限, 提示文字
local usageCounter = { used = 0, stasisCDEndTime = 0 }

--==========================================================================
-- 静滞状态机 (用施法事件 + aura 370562 驱动, 不依赖 GetSpellCooldown)
-- 解决 "卡在3s" 和 API 与客户端不一致的问题
--
-- 正确机制 (NGA实锤 + v1.11重构):
--   静滞 370537 第一次按 -> 3层"静滞"buff(370537), 进入 STORING 存技能, 不进CD
--   存满第3个治疗技能 -> buff变30s"待释放"(370562), 静滞开始90s CD (ARMED)
--   30s内再按 370537 -> 释放3个技能 (CD继续走)
--   30s超时未释放 -> 自动释放, 继续走CD
--   关键: 进入冷却的触发点 = aura 370562 出现, 不是"按释放"
--==========================================================================
local stasisState = {
    phase = "READY",       -- READY / STORING / ARMED / COOLDOWN
    activeStartTime = 0,   -- STORING 开始时间 (首次按静滞)
    armedStartTime = 0,    -- ARMED 开始时间 (存满3技能)
    cooldownEndTime = 0,   -- COOLDOWN 预计结束时间 (存满3技能时 +90s)
    storedCount = 0,       -- STORING 阶段已存的白名单治疗技能数 (存满3 -> ARMED)
    innerfireEndTime = 0,  -- 心灵之火15s buff 的结束时间 (按下静滞立刻开始, 独立倒计时)
    thirdCastStartTime = 0, -- 第3个技能"施法开始"时刻 (CD起算锚点, 见 OnStasisArmed)
    cdAnchoredAt = 0,       -- v1.36.11: 本轮 CD **实际采用**的起算时刻 (供"模型锚点 vs 游戏 startTime"对比)
    storedTemporalAnomalies = 0, -- v1.20: STORING阶段存入的时空畸体(溜溜球)数量, 释放时补算减CD
    stasisReleaseTime = 0,  -- v1.20: 静滞释放时刻, 用于去重(释放的溜溜球不再重复减CD)
}

-- 状态机轨迹 (轻量日志, 供未来排查时序问题; /DBSH debug 展示入口已随清理移除, 保留记录以备后用)
local traceLog = {}
-- v1.32: 改为赋值给前向声明的 local Trace (见充能模型段), 让定义点之前的函数也能引用
Trace = function(msg)
    traceLog[#traceLog + 1] = string.format("[%.0fs] %s", GetTime(), msg)
    if #traceLog > 20 then table.remove(traceLog, 1) end
end

-- 去重版: 连续相同消息只记一次 (每帧调用的路径用这个)
local function TraceOnce(msg)
    local last = traceLog[#traceLog]
    if not last or last:sub(-#msg) ~= msg then Trace(msg) end
end

--==========================================================================
-- 心流状态 (Flow State) 天赋支持 (v1.32)
-- 机制: 释放任意蓄力技能后获得10s增益, 所有技能冷却恢复加快 5%*层数
--   注意: 该buff不叠层 —— 10s窗口内再次施放只把窗口刷新为10s, 加速效果不叠加
-- 实现(移位法): 检测到蓄力施放成功, 把正在倒计时的冷却时间戳往前拨,
--   拨的量 = 本次施放新增的加速覆盖时长(相对旧窗口的增量, 0~10s) * FLOW_RATE_PER_RANK * 层数
--==========================================================================

-- 名字清洗: 去掉 WoW 颜色码 (|cAARRGGBB...|r) 与首尾空白
local function CleanSpellName(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    name = name:match("^%s*(.-)%s*$")
    if name == "" then return nil end
    return name
end

-- 天赋名匹配: 先精确, 再退化为"双向子串包含"
-- 【为什么放宽】v1.32.6 实测: 老板点满 2 点"心流状态"仍识别为 0 层 —— 天赋节点上取到的
--   法术名与我们在表里写的字面量可能有出入 (客户端叫法/后缀/带颜色码), 精确相等会直接漏判。
--   放宽为"表里的词出现在名字里, 或名字出现在表里的词里"即可覆盖 "心流" vs "心流状态" 这类差异。
--   风险可控: 词表都是完整天赋名 (心流状态/心灵之火/塑焰者), 不会退化成单字误匹配。
local function TalentNameMatches(namesTable, name)
    if not namesTable or not name then return false end
    if namesTable[name] then return true end
    for key in pairs(namesTable) do
        if type(key) == "string" and #key >= 2
           and (name:find(key, 1, true) or key:find(name, 1, true)) then
            return true
        end
    end
    return false
end

-- 兼容调用 C_Traits 系列 API: 同一 API 在不同版本里参数个数可能不同
-- 【v1.32.7 实机血泪】`C_Traits.GetTreeInfo` 的签名是 (configID, treeID), 而旧代码只传了 treeID
--   -> 直接抛 "bad argument #2 (Usage: local treeInfo = C_Traits.GetTreeInfo(configID, treeID))"
--   -> 该错误被 GetTalentRankByName 外层 pcall 吞掉 -> 整个函数静默返回 0
--   -> 心流状态 / 塑焰者英雄天赋 / 心灵之火 三条链路**全部**识别失败 (英雄天赋之前是靠 ID 兜底表蒙对的)
-- 本函数: 先按 (configID, id) 调, 拿到非 nil 结果就用; 否则退回 (id); 都拿不到返回 nil (绝不抛错)
-- 注: 必须用"结果非 nil 才算成功"来判定 —— 因为 1 参数版本的 API 收到 (configID, id) 时,
--     第一个参数会被当成真正的 id, 往往**不报错只返回 nil**; 只判 ok 会误以为成功而卡死。
--     只有 GetDefinitionInfo 不适用 (它的第一个参数就是 definitionID, 不是 configID), 单独直调。
local function TraitsCall(fn, configID, id)
    -- 注意: 这里**不能**用 `type(fn) ~= "function"` 过滤 —— lupa 测试环境里 python 可调用对象
    -- 在 Lua 侧是 userdata(带 __call), type() 返回 "userdata" 而不是 "function", 会被误杀。
    -- 兜底交给 pcall: 非可调用值调用会抛错 -> 两次都失败 -> 返回 nil, 同样是安全的。
    if fn == nil then return nil end
    local ok, r = pcall(fn, configID, id)
    if ok and r ~= nil then return r end
    local ok2, r2 = pcall(fn, id)
    if ok2 and r2 ~= nil then return r2 end
    return nil
end

-- 【v1.32.8 实机血泪】上面那个"先塞 configID 再退 id"的兼容层, 对 GetTreeNodes 是**致命**的:
--   `C_Traits.GetTreeNodes(treeID)` 只吃 1 个参数 —— 塞了 configID 进去, treeID 位就变成 configID,
--   查不到该树 -> 返回**空表**(非 nil!) -> 兼容层把"空表"当成成功 -> 永不退到 (treeID) -> 节点数恒为 0。
--   教训: "空表/0" 也是有效返回, 不能用 `~= nil` 判断"这个签名对不对"。
-- 所以凡是**只吃 1 个 id** 的 C_Traits API(GetTreeNodes / GetDefinitionInfo), 一律用本函数直调。
local function TraitsCall1(fn, id)
    if fn == nil then return nil end
    local ok, r = pcall(fn, id)
    if ok then return r end
    return nil
end

-- 按名字 或 spellID 检测天赋层数 (兼容中英文客户端 + 取不到名字的客户端)
-- 参数: namesTable = 天赋名集合(可 nil) / idsSet = 天赋 spellID 集合(可 nil)
-- 遍历激活天赋树: config -> tree -> node -> entry -> definition -> spellID
--   ① 树名匹配 (英雄天赋树名 = 英雄天赋名)
--   ② 节点 spellID 命中 idsSet  -> 最硬判据, 不依赖任何"取名字"的 API
--   ③ 节点 spellID 的名字命中 namesTable -> 兜底判据
-- 返回: activeRank, spellID; 找不到或缺API返回 0, nil (mock环境这些API是nil, 必须兜底)
-- 注: 用赋值式而非 local function, 因为前面资格检测段已前向声明了它
GetTalentRankByName = function(namesTable, idsSet)
    if not namesTable and not idsSet then return 0, nil end
    if not C_ClassTalents or not C_Traits then
        return 0, nil
    end
    -- 取名字的能力是可选的: 没有 C_Spell.GetSpellName 时只是关掉"名字兜底", ID 判据照常跑
    local canName = (namesTable ~= nil) and (C_Spell ~= nil) and (C_Spell.GetSpellName ~= nil)
    local ok, rank, foundSpellID = pcall(function()
        local configID = C_ClassTalents.GetActiveConfigID()
        if not configID then return 0, nil end
        local configInfo = C_Traits.GetConfigInfo(configID)
        if not configInfo or not configInfo.treeIDs then return 0, nil end
        for _, treeID in ipairs(configInfo.treeIDs) do
            -- ① 先比树名: 英雄天赋树的树名就等于英雄天赋名 (如"塑焰者"/"Flameshaper"),
            --    而英雄天赋的"节点"往往匹配不到 -> 这条是英雄天赋的主判据
            if namesTable then
                -- GetTreeInfo(configID, treeID) 返回的 TraitTreeInfo **没有 name 字段** (12.x 起叫 titleText),
                -- 所以以前拿 treeInfo.name 恒为 nil, 树名匹配这条路其实一直是死的(英雄天赋靠 ID 兜底蒙对)
                local treeInfo = TraitsCall(C_Traits.GetTreeInfo, configID, treeID)
                local treeName = treeInfo and (treeInfo.name or treeInfo.titleText)
                if treeName and TalentNameMatches(namesTable, CleanSpellName(treeName)) then
                    return 1, nil
                end
            end
            -- v1.32.8: GetTreeNodes 只吃 (treeID); 走 TraitsCall 会把 configID 当前 treeID -> 恒返回空表
            local nodes = TraitsCall1(C_Traits.GetTreeNodes, treeID)
            if nodes then
                for _, nodeID in ipairs(nodes) do
                    local nodeInfo = TraitsCall(C_Traits.GetNodeInfo, configID, nodeID)
                    if nodeInfo and nodeInfo.activeRank and nodeInfo.activeRank > 0
                       and nodeInfo.entryIDs then
                        for _, entryID in ipairs(nodeInfo.entryIDs) do
                            local entryInfo = TraitsCall(C_Traits.GetEntryInfo, configID, entryID)
                            if entryInfo then
                                -- v1.32.6 兜底: definitionID 链断了, 有些版本 entry 自己就带 spellID
                                local defInfo = entryInfo.definitionID
                                                and TraitsCall1(C_Traits.GetDefinitionInfo, entryInfo.definitionID)
                                local spellID = (defInfo and defInfo.spellID) or entryInfo.spellID
                                if spellID then
                                    -- ② ID 判据 (最硬: 不依赖客户端能否取到名字)
                                    if idsSet and idsSet[spellID] then
                                        return nodeInfo.activeRank, spellID
                                    end
                                    -- ③ 名字判据 (兜底)
                                    if canName then
                                        local name = CleanSpellName(C_Spell.GetSpellName(spellID))
                                        if TalentNameMatches(namesTable, name) then
                                            return nodeInfo.activeRank, spellID
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        return 0, nil
    end)
    if ok and rank then return rank, foundSpellID end
    return 0, nil
end

-- v1.36.10: 直接读"心流状态"光环的剩余秒 —— 比"事件 + 10s"推算更硬
--   为什么更硬: ① 不怕漏收施法事件; ② 现在的推算从 `SUCCEEDED` 起算, 而 `SUCCEEDED` 在
--   **开始蓄力**那一刻就发了(见 CAST_PROBE 段注释), aura 却是蓄力**完成**才刷 ——
--   真机实测两者的窗口结束时刻差 0.8s(模型偏早), 读 aura 能把这 0.8s 修掉。
-- 返回: remain(秒, 可能 nil), state("OK"/"secret"/"noapi"/"noaura")
-- 注意: 必须用 FLOW_AURA_ID(390148), **不是**天赋 ID(385696) —— 两者不同, 见常量处注释
local function ReadFlowAuraRemain()
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil, "noapi" end
    local ok, d = pcall(C_UnitAuras.GetPlayerAuraBySpellID, FLOW_AURA_ID)
    if not ok or type(d) ~= "table" then return nil, "noaura" end
    local remain, state = nil, "OK"
    local ok2 = pcall(function()
        local e = d.expirationTime
        if issecretvalue and issecretvalue(e) then state = "secret" return end
        if type(e) == "number" and e > 0 then
            remain = e - GetTime()
        else
            state = "noaura"
        end
    end)
    if not ok2 then return nil, "secret" end
    return remain, state
end

-- v1.36.32 心流"速率换算" —— 把两个计时器的**剩余时间**按当前 rate 比值缩放。
--   机制(真机铁证 02:40, 详见 TickFlowAcceleration 上方说明): 游戏内部是"剩余进度 ÷ 当前速率",
--   所以速率一变, 剩余时间就要按比例换算:
--     · 开窗(速率 1.0→1.1): mul = 1/factor < 1 → 剩余**变短**
--     · 过期(速率 1.1→1.0): mul = factor  > 1 → 剩余**变长**
--   **必须在状态变化的那一刻当场换算**(不能拖到下一帧) —— 否则中间若发生"溜溜球减CD"等事件,
--   会按错误的基准参与运算(行为测试 F 用例当场抓出: 期望 22.27, 延迟换算会得到 22.73)。
-- ⚠️ 这个标志声明必须在 OnFlowWindowRefresh / TickFlowAcceleration **之前**（Lua 词法作用域，
--   声明写在后面的话函数体读到的是全局 nil —— v1.36.26 就栽过一次）。
local flowWasActive = false
-- v1.36.35: 记下"刚刚发生的速率换算" —— 采样行上直接标注, 回答"模型为什么突然跳了 ±8s"。
--   为什么需要: 战斗中读不到心流 aura, "这次换算是该发生还是误触发"没法当场核对;
--   但至少要让"发生了什么、换了多少"看得见 —— 否则数字一跳就只剩猜。
local lastFlowConv = nil   -- { t=, tag=, mul=, dCharge=, dStasis= }

local function FlowConvertRemaining(mul)
    local now = GetTime()
    local dC, dS = 0, 0
    pcall(function()
        -- 绿喷"下一层"
        if chargeModel.currentCharges and chargeModel.nextChargeAt
           and chargeModel.currentCharges < (chargeModel.maxCharges or 2)
           and chargeModel.nextChargeAt > now then
            local rem = chargeModel.nextChargeAt - now
            chargeModel.nextChargeAt = now + rem * mul
            dC = rem * mul - rem
            ChargeDiag(string.format("心流换算 绿喷下一层: 剩余%.1fs -> %.1fs (x%.3f)", rem, rem * mul, mul))
        end
        -- 静滞 CD (ARMED 阶段 CD 已在跑, 同样要算)
        if (stasisState.phase == "ARMED" or stasisState.phase == "COOLDOWN")
           and stasisState.cooldownEndTime and stasisState.cooldownEndTime > now then
            local remS = stasisState.cooldownEndTime - now
            stasisState.cooldownEndTime = now + remS * mul
            dS = remS * mul - remS
            ChargeDiag(string.format("心流换算 静滞CD: 剩余%.1fs -> %.1fs (x%.3f)", remS, remS * mul, mul))
        end
    end)
    if math.abs(dC) > 0.05 or math.abs(dS) > 0.05 then
        lastFlowConv = { t = now, tag = (mul < 1 and "开窗" or "过期"), mul = mul,
                         dCharge = dC, dStasis = dS }
    end
end

-- 心流窗口开启/刷新: 蓄力施放成功时调用 (v1.32.5 起只管窗口, 不再当场一次性移位)
-- buff 不叠层, 重复施放只把窗口刷新成"从现在起 10s"
local function OnFlowWindowRefresh()
    if (flowState.rank or 0) <= 0 then return end
    local now = GetTime()
    local wasActive = (flowUntil > now)
    flowUntil = now + FLOW_WINDOW
    -- v1.36.14 开窗折算静滞CD: 游戏在"心流窗口从关→开"的那一瞬间, 把静滞 CD 的**剩余时间按 rate 折算**。
    --   实测(01:08, 窗口在采样中途开启): API 剩余 74.9s →(开窗)→ 67.1s ≈ 74.9/1.1 再流逝 1s;
    --   之后按**真实秒** -1.0/秒 递减(引擎 Δ 恒为 -1.0) —— 所以不是"逐帧加速", 而是"开窗瞬间折算一次"。
    --   旧实现只在「CD 起算那一刻窗口已开」才折算(v1.36.12), 漏了"起算后才开窗"这种最常见的战斗情况。
    --   注: 只在"关→开"时折算; 窗口已开着再刷新(wasActive=true)不折, 免得重复缩水。
    -- v1.36.17 折算的第一道锁: **每周期只折一次** —— 游戏把 duration 折一次后就不再变
    --   (即使窗口过期/再刷新); "每次开窗都折"会重复缩水 → 模型偏快(危险方向)。
    -- ⚠️ v1.36.37: 上面那段"每周期只折一次"的锁(以及配套的 flowDiscounted 标志)**已整体删除** ——
    --   v1.36.32 起改为"成对换算"(开窗 ÷factor / 过期 ×factor), 天然对称、不需要一次性锁;
    --   标志只写不读, 会误导后来读代码的人, 按项目惯例清掉。
    -- v1.36.32: 窗口**从关→开**的这一帧**当场**换算(剩余 ÷factor)。
    --   为什么必须当场(不能拖到下一帧的 TickFlowAcceleration): 中间可能夹着"溜溜球减CD"等事件,
    --   会按错误的基准参与运算 —— 行为测试 F 用例实测: 当场换算 22.27 ✓ / 延迟换算 22.73 ✗。
    --   反向的"过期"没有事件可挂, 只能靠 TickFlowAcceleration 每帧检测(延迟 ≤1 帧, 可忽略)。
    --   ⚠️ 旧实现**只在开窗时折、过期后不还原** → "窗口只覆盖充能一部分"时模型**偏快**(危险方向)。
    --   真机铁证(2026-09-21 02:40): 窗口期内差恒 0.0s, 但**过期那一刻引擎剩余 +1.2s**(Δ引擎=+0.2),
    --   而模型继续 -1.0 → 差跳到 -1.2s 并保持。
    local factor = 1 + FLOW_RATE_PER_RANK * flowState.rank
    if (not wasActive) and factor > 0 then
        FlowConvertRemaining(1 / factor)
    end
    flowWasActive = true
    Trace(string.format("心流状态%d层: 窗口%s, 持续%.0fs",
        flowState.rank, wasActive and "刷新" or "开启", FLOW_WINDOW))
end

-- 【v1.36.32 定版】心流加速的真实机制 = **"剩余进度 ÷ 当前速率"** ——
--   真机铁证(2026-09-21 02:40 `/DBSH time`, 一次采样同时给出两个关键现象):
--     ① **窗口期内**引擎 Δ 恒为 **-1.0**(不是 -1.1) —— 看着"完全没加速";
--     ② **窗口过期那一瞬间**引擎剩余**反而 +1.2s**(Δ引擎=+0.2) —— 倒计时不可能自己变长。
--   只有一种模型能同时解释这两条:
--     · 游戏维护的是"剩余**进度**"(以 1.0 速率计), 心流 = **进度推进快 10%**;
--     · 而**对外给出的"剩余时间" = 剩余进度 ÷ 当前速率**。
--   → 窗口内: 进度每秒 -1.1, 剩余时间 = 进度/1.1 → **每秒 -1.0** ✓
--     (加速被除法抵消 —— 这就是历次把它误判成"没加速/不逐帧"的根源)
--   → 窗口过期: 速率 1.1→1.0, **同一份进度除以更小的数** → 剩余时间**跳升** ✓
--   → 手算核对(#12→#13): `12.1 →(过期)→ 12.3` = (12.1-0.3)×1.1-0.7 ≈ 12.28 ✓
--   实现: 不引入"进度"变量, 而在**窗口状态切换的那一帧**按 factor 换算剩余
--        (开窗 ÷factor, 过期 ×factor —— **对称**, 所以反复开关也不会累积偏差)。
--   ⚠️ 这同时推翻了 v1.36.17 的"每周期只折一次"锁: 单向折算必然漂, 必须成对。
local flowRankRetryAt = 0   -- 心流天赋重算的限流时间戳 (登录时天赋数据未就绪 -> 补算用)

local function TickFlowAcceleration()
    -- v1.36.32: 本函数只负责"窗口**过期**"这一侧 —— 开窗已在 OnFlowWindowRefresh **当场**换算。
    --   过期没有对应的游戏事件可挂, 只能每帧检测(延迟 ≤1 帧 ≈16ms, 可忽略)。
    if not flowWasActive then return end
    local rank = flowState.rank or 0
    if rank > 0 and flowUntil > GetTime() then return end    -- 窗口还开着 -> 不动
    flowWasActive = false
    local factor = 1 + FLOW_RATE_PER_RANK * rank
    if factor > 0 then FlowConvertRemaining(factor) end
end

-- 重算心流状态层数缓存 (登录/天赋/专精变化时调用)
local function RefreshFlowStateRank()
    -- v1.32.7: 先按 spellID(385696) 硬匹配, 名字降级为兜底 —— ID 判据不依赖"取名字"的 API
    local rank, spellID = GetTalentRankByName(FLOW_STATE_NAMES, FLOW_STATE_IDS)
    flowState.rank = rank or 0
    flowState.spellID = spellID
    if flowState.rank <= 0 then
        flowUntil = 0  -- 天赋被洗掉: 重置buff到期时刻, 防止重新点出时沿用过期窗口
    end
    Trace(string.format("心流状态天赋: %d层 (spellID=%s)", flowState.rank, tostring(spellID)))
end

-- 静滞激活 (第一次按: 进入 STORING 存技能, 此时不进CD)
local function OnStasisStore()
    stasisState.phase = "STORING"
    stasisState.activeStartTime = GetTime()
    stasisState.armedStartTime = 0
    stasisState.cooldownEndTime = 0
    stasisState.storedCount = 0   -- 重置存技能计数
    stasisState.storedTemporalAnomalies = 0  -- 重置溜溜球计数 (v1.20)
    stasisState.storedSpellIDs = {}  -- v1.34: 清空"已存技能"图标列表 (大图标排下帧显示空槽位)
    stasisState.thirdCastStartTime = 0  -- v1.25: 重置第3技能施法开始时刻 (防跨轮残留旧值, 瞬发第3技能时CD锚定错误)
    stasisState.cdAnchoredAt = 0        -- v1.36.13: 同步重置锚点记录 (防跨轮残留旧值污染诊断)
    stasisState.innerfireEndTime = GetTime() + STASIS_OPENING_TOTAL_DURATION  -- 心火15s独立倒计时
    Trace("静滞激活 370537 -> STORING (存3技能, 未进CD)")
    -- v1.36.36: 静滞的三次状态变迁也进"记账流水" —— 战斗中 /DBSH charge//DBSH next 能直接核对
    --   起算时刻与时长(90 / 81.8), 否则只能靠 Trace(那条通道不进流水, 战斗中无法自证)。
    ChargeDiag("静滞激活 -> 存储中(未进CD)")
    -- 激活时也重置计数器 (新一轮)
    usageCounter.used = 0
    usageCounter.stasisCDEndTime = 0
    -- 启动"打开阶段"图标队列
    -- 0-6s: 显示 绿喷·绿喷·时空畸体 三队列
    -- 7-15s: 显示 心灵之火 logo + "剩余X秒"
    openingQueue = {}
    for i, item in ipairs(QUEUE_ITEMS) do
        openingQueue[i] = item
    end
    openingLastIndex = 0  -- 还没用
    openingQueueEndTime = GetTime() + STASIS_OPENING_QUEUE_DURATION  -- 队列结束时间(6秒)
    stasisState.openingTotalEndTime = GetTime() + STASIS_OPENING_TOTAL_DURATION  -- 整个打开阶段结束(15秒)
end

-- 静滞进入 ARMED (存满第3个治疗技能, 静滞按钮高亮, 开始90s CD)
-- v1.14: 触发点改为 IsUsableSpell 从 false->true (存满信号), 不再依赖 aura
local function OnStasisArmed()
    stasisState.phase = "ARMED"
    stasisState.armedStartTime = GetTime()
    -- v1.18 关键修复: 游戏里静滞CD从"第3技能施法开始+1.3s(GCD)"起算, 不是"读条完成"。
    --   实测(21:51战斗外): 游戏CD startTime=44393.6s, 插件SUCCEEDED触发=44395.7s, 晚了2.0s。
    --   第3技能(时空畸体读条1.5s)施法开始=44392.3s, +1.3s=44393.6s 精确对齐游戏startTime。
    --   所以 cooldownEndTime 锚定 thirdCastStartTime + 1.3s, 而不是 SUCCEEDED 的 GetTime()。
    local cdStart = stasisState.thirdCastStartTime
    if (not cdStart) or cdStart <= 0 then
        -- 兜底: 没记录到施法开始(如/reload), 退回当前时刻
        cdStart = GetTime()
    else
        cdStart = cdStart + STASIS_CD_START_OFFSET
    end
    -- ⛔ 【v1.36.33 推翻本条】旧结论"起算时不折算"(v1.36.15)**已作废**:
    --   它的论据是"01:08 起算时窗口开着(flowUntil > cdStart), 游戏 duration 仍 90" ——
    --   但那次 API 明写 `rate=1.000`, **窗口根本没开**; 而 `flowUntil > cdStart` 只说明"窗口**结束**晚于起算",
    --   完全可能是"起算**之后**才开窗" → 论据不成立。正确定性见下方 v1.36.33 注释。
    --   （仍成立的结论: **不逐帧加速** —— 改为"窗口状态变化时按比值换算"）
    -- v1.36.33 🔴 **起算那一刻若心流窗口确实已经开着 → 按当前 rate 折算总时长**(90 → 81.8)。
    --   02:51 实测铁证: 老板连续放技能 → 我们起算那一刻窗口**已经开着**(buff 还剩 9.7s),
    --   而模型写死 90, 游戏却是 81.8 → **整整偏慢 8.2s**(红灯晚亮)。流水: #5 起 API=81.1 / 模型=90.6, 差恒 +9.5s。
    --   ⚠️ 判据必须精确到"**起算那一刻**窗口是否已开": `flowUntil - FLOW_WINDOW <= cdStart < flowUntil`。
    --      · v1.36.12 曾只判 `flowUntil > cdStart`(窗口**结束**晚于起算) → 把"起算**之后**才开窗"也误判成"起算时已开"
    --        而多折一次(模型偏快, 危险方向);
    --      · v1.36.15 据此回滚成"起算不折" —— 但**那次实测的 rate 是 1.000, 窗口根本就没开**,
    --        论据本身是误读。两条路现在的分工: 起算时已开 → 这里折; 起算后才开 → OnFlowWindowRefresh 换算。
    local durStasis = STASIS_COOLDOWN_DURATION
    local fRankStasis = flowState.rank or 0
    if fRankStasis > 0 and flowUntil > cdStart and (flowUntil - FLOW_WINDOW) <= cdStart then
        durStasis = durStasis / (1 + FLOW_RATE_PER_RANK * fRankStasis)
    end
    stasisState.cooldownEndTime = cdStart + durStasis
    stasisState.cdAnchoredAt = cdStart   -- v1.36.11: 记下本轮实际锚点, 供 /DBSH charge 与游戏 startTime 对比
    Trace(string.format("静滞存满3技能(按钮高亮) -> ARMED, 90sCD锚定施法开始+1.3s, 结束于%.0fs(提前%.1fs)",
        stasisState.cooldownEndTime, GetTime() - cdStart))
    -- v1.36.36: 这行是"静滞 CD 到底算多少"的唯一自证 —— 直接打出**实际采用的时长**与是否折算。
    --   战斗中读不到游戏的 startTime/duration, 所以只能靠它留下证据(90.0 = 没折 / 81.8 = 折了)。
    ChargeDiag(string.format("静滞存满 -> 起算CD %.2fs%s (锚=第3技能开始+%.1fs, 模型剩余%.1fs)",
        durStasis, (durStasis < STASIS_COOLDOWN_DURATION - 0.01) and " [已折算心流]" or "",
        STASIS_CD_START_OFFSET, stasisState.cooldownEndTime - GetTime()))
    -- 新CD开始, 重置计数器
    usageCounter.used = 0
    usageCounter.stasisCDEndTime = stasisState.cooldownEndTime
end

-- 静滞释放 (再次按 370537: 释放存储的3个技能, CD继续走, 不重置)
-- v1.9: 彻底放弃读 API CD (战斗中 startTime/duration 是 secret number)
--       CD 由 OnStasisArmed 在存满时已本地计时, 这里只切阶段
local function OnStasisRelease()
    stasisState.phase = "COOLDOWN"
    stasisState.activeStartTime = 0
    stasisState.armedStartTime = 0
    -- 清空打开阶段残留
    openingQueue = {}
    openingQueueEndTime = 0
    openingLastIndex = 0
    stasisState.openingTotalEndTime = 0
    stasisState.storedSpellIDs = {}  -- v1.34: 释放 -> 已存技能大图标清空 (下帧随非OPENING状态隐藏)
    -- 若 CD 终点还没设(极端情况: 没经过ARMED直接释放), 兜底设为+90
    if not stasisState.cooldownEndTime or stasisState.cooldownEndTime <= GetTime() then
        stasisState.cooldownEndTime = GetTime() + STASIS_COOLDOWN_DURATION
    end
    -- v1.20: 静滞释放 = 重新施放存的技能(fresh cast)。存的每个溜溜球(时空畸体)
    --   释放时会再次触发 Nozdormu's Teachings 天赋, 再减绿喷充能5秒。
    --   存时已减过1次(SUCCEEDED事件), 释放时补算第2次。
    --   (spiritbloom.pro 权威机制: 存N个溜溜球, 释放时每个再减5秒)
    local taCount = stasisState.storedTemporalAnomalies or 0
    if taCount > 0 then
        for _ = 1, taCount do
            TemporalAnomalyReduceCD()
        end
        ChargeDiag(string.format("静滞释放: 补算溜溜球减CD x%d", taCount))
        Trace(string.format("静滞释放补算溜溜球减CD x%d (释放重施放)", taCount))
    end
    stasisState.storedTemporalAnomalies = 0  -- 清空, 防重复补算
    stasisState.stasisReleaseTime = GetTime()  -- v1.20: 记录释放时刻, 去重用
    Trace(string.format("静滞释放(370537二次按下) -> COOLDOWN (CD结束于%.0fs)",
        stasisState.cooldownEndTime))
    -- v1.36.36: 释放也留一条 —— 这样一轮静滞在流水里能看到完整三件套
    --   (激活 -> 存满起算 -> 释放), 战斗中可核对"起算时刻/时长/释放时刻"是否与体感一致。
    ChargeDiag(string.format("静滞释放 -> CD继续, 模型剩余%.1fs", stasisState.cooldownEndTime - GetTime()))
end

-- 更新静滞状态 (v1.14 核心重构: 用 IsUsableSpell 布尔信号驱动, 完全放弃 aura)
-- 12.1 实锤: 战斗中 C_UnitAuras 全部失效(GetPlayerAuras返回空, 逐个探测nil),
--   aura 方案(v1.11)彻底废掉。战斗中唯一可靠可读的 = 施法事件 + IsUsableSpell 布尔。
-- 机制: 按静滞 -> 按钮灰(IsUsableSpell=false) STORING; 存满3技能 -> 按钮高亮(IsUsableSpell=true) ARMED 开始90sCD
-- 返回: 当前 phase
local function UpdateStasisState()
    if stasisState.phase == "STORING" then
        -- v1.31 核心: "存满"信号改用 IsStasisUsable() (游戏原生"按钮高亮"信号)。
        --   老板23:40实机验证: STORING期间(存1/2技能) IsUsable=false(按钮灰),
        --   存满第3技能瞬间 IsUsable 跳 true(按钮高亮)。这个信号不依赖"数技能",
        --   溜溜球(时空畸体)事件不可靠/用晚了也不会影响判定, 彻底绕开 storedCount 漏洞。
        --   保留 storedCount>=3 作为兜底(万一某环境 IsUsable 读不到 nil)。
        local usable = IsStasisUsable()
        -- 去抖: STORING 刚开始 0.5s 内不信任 IsUsable=true (防止"按下静滞"瞬间
        --   按钮还没变灰, 读到残留的 true 误判存满)。0.5s 后按钮已稳定变灰。
        local storingElapsed = GetTime() - stasisState.activeStartTime
        if usable == true and storingElapsed >= 0.5 then
            OnStasisArmed()
        elseif stasisState.storedCount >= 3 then
            OnStasisArmed()
        -- 兜底: STORING 超过30s还没存满3个 -> 静滞失败回 READY
        -- (30s是静滞存技能的上限, 老板没放够3个治疗技能)
        elseif GetTime() - stasisState.activeStartTime > 30 then
            stasisState.phase = "READY"
            stasisState.activeStartTime = 0
            stasisState.openingTotalEndTime = 0
            stasisState.storedCount = 0
            stasisState.storedSpellIDs = {}  -- v1.34: 静滞失败, 已存图标一并清空
            openingQueue = {}
            openingQueueEndTime = 0
            openingLastIndex = 0
            Trace("STORING 30s超时未存满3技能 -> READY (静滞失败)")
        end
    elseif stasisState.phase == "ARMED" then
        -- 30s 待释放窗口。v1.35.0: 释放检测(ISUsable自愈/重放检测)已全部移除 ——
        --   老板实锤用宏 cancelaura 释放, 该路径既不发 SUCCEEDED(370537), 也采不到
        --   可用的轮询信号 (实机多版验证均未触发), 统一改由下面 30s 超时清掉存储排。
        --   (正常按按钮释放仍走事件: SUCCEEDED(370537) -> 事件分支调 OnStasisRelease)
        if GetTime() - stasisState.armedStartTime > 30 then
            stasisState.phase = "COOLDOWN"
            -- v1.34.3: 超时=自动释放, 与手动释放同待遇: 清已存技能排 + 记释放时刻
            stasisState.storedSpellIDs = {}
            stasisState.stasisReleaseTime = GetTime()
            Trace("ARMED 30s超时未释放 -> COOLDOWN (自动释放, 已存技能排清空)")
        end
    elseif stasisState.phase == "COOLDOWN" then
        local remaining = stasisState.cooldownEndTime - GetTime()
        if remaining <= 0 then
            stasisState.phase = "READY"
            Trace("COOLDOWN结束 -> READY")
            -- CD结束, 重置计数器
            usageCounter.used = 0
            usageCounter.stasisCDEndTime = 0
        end
    end
    return stasisState.phase
end

-- 获取静滞CD剩余 (v1.11: ARMED/COOLDOWN 阶段都返回本地计时剩余)
-- ARMED 时静滞已进CD(存满3技能), COOLDOWN 时继续走CD, 两者都返回 cooldownEndTime - now
local function GetStasisCDRemaining()
    if stasisState.phase == "ARMED" or stasisState.phase == "COOLDOWN" then
        local r = stasisState.cooldownEndTime - GetTime()
        if r > 0 then return r end
    end
    return 0
end

local function UpdateUsageCounter(dreamInfo, stasisInfo)
    -- 静滞刚进入CD时重置计数 (检测CD从0->有)
    if stasisInfo and stasisInfo.onCooldown then
        local cdEnd = GetTime() + stasisInfo.remaining
        -- 如果静滞CD结束时间变化大(说明刚开新一轮), 重置
        if usageCounter.stasisCDEndTime == 0
           or math.abs(cdEnd - usageCounter.stasisCDEndTime) > 5 then
            usageCounter.used = 0
            usageCounter.stasisCDEndTime = cdEnd
        end
    else
        -- 静滞不在CD, 清空
        usageCounter.stasisCDEndTime = 0
        usageCounter.used = 0
    end
end

-- v1.36.6: 静滞 CD —— API 可读时校准 (补上绿喷同款的"对齐官方值")
-- 【作用】只要 `C_Spell.GetSpellCooldown` 读得到**非 secret** 的剩余秒, 就用官方值覆盖模型。
-- 【定位 = 安全网, 不是主算法】战斗中时间值是 secret → `IsSafeNumber` 判否 → **自动跳过**;
--   战斗内准确性完全由本地模型负责(v1.36.17 的折算模型), 这里只负责"读得到时清零残余误差"。
-- 【v1.36.15 校正】下面这段旧注释里"静滞 CD 从按下激活就开始"**已作废**(是误读):
--   静滞 CD 从"存满第 3 个技能(进 ARMED)"起算, 代码锚 `thirdCastStartTime + 1.3s` 正确;
--   v1.36.6 当时以为的"+5.7s = 锚点晚"也不对 —— 真凶是"固定90s基准 + 窗口内逐帧积分"(v1.36.15 已修)。
local lastStasisSyncAt = 0      -- v1.36.6: 静滞 CD 官方对齐的限流时间戳
-- v1.36.7: 诊断采样期间**暂停**所有官方值校准 —— 否则会把模型的真实漂移抹平, 看不到机制差
-- v1.36.26: ⚠️ **只赋值, 不写 local** —— 真实声明已前移到 SyncChargeModel 之前(约 452 行)。
--   这里若再写 local 会创建**第二个变量**: 本函数(1504)捕获到新的, 而 SyncChargeModel(454)
--   捕获到的还是旧的那个 → 绿喷的守卫静默失效(正是老板发现的"脱战永远测不出差异")。
probeSuspendSync = false

local function SyncStasisCooldownFromAPI()
    if probeSuspendSync then return false end
    if not (C_Spell and C_Spell.GetSpellCooldown) then return false end
    -- v1.36.18: 放宽到 ARMED —— 静滞 CD 从"存满进 ARMED"就在跑, 只认 COOLDOWN 会整整漏掉一个阶段。
    --   (ARMED 期间 API 若不可读/为 secret, 下面的 IsSafeNumber 会挡住 → 放宽是安全的)
    if stasisState.phase ~= "COOLDOWN" and stasisState.phase ~= "ARMED" then return false end
    local ok, cd = pcall(C_Spell.GetSpellCooldown, STASIS_SPELL_ID)
    if not ok or type(cd) ~= "table" then return false end
    local rem = cd.timeUntilEndOfStartRecovery
    if not IsSafeNumber(rem) or rem <= 0 then return false end
    local before = (stasisState.cooldownEndTime or 0) - GetTime()
    stasisState.cooldownEndTime = GetTime() + rem
    -- 只在"纠正量明显"时写记账流水(ring 20 条, 仍别把有用的施放/静滞记录挤掉)
    if math.abs(before - rem) > 0.5 then
        ChargeDiag(string.format("静滞CD校准(API官方剩余): %.1fs -> %.1fs (模型原来偏%+.1fs)",
            before, rem, before - rem))
    end
    return true
end

--==========================================================================
-- v1.36.19 /DBSH track — 长时程(战斗+脱战)精度追踪
--==========================================================================
-- 【为什么这么做】战斗中引擎的**连续时间值**(剩余秒/充能秒)全是 secret, 读不到数字。
--   但暴雪没加密**布尔信号**, 所以可以拿"状态翻转的真实时刻"当真值锚点:
--     ① 绿喷**满层**:  C_Spell.GetSpellCharges(绿喷).isActive 由 true→false
--     ② 静滞**CD结束**: C_Spell.IsSpellUsable(静滞) 由 false→true (仅在 COOLDOWN 阶段)
--   把这两个事件的**真实发生时刻**与"模型在事件前一帧预测的时刻"相减 → 得到该时刻的误差。
--   这样**战斗中也能量化模型精度**(不必等脱战读 API)。
-- 【局限(要跟老板说清)】绿喷只能捕捉"满 2 层"这一跳(1 层时 isActive 仍为 true, 无翻转);
--   静滞只能捕捉"CD 结束"。所以是**离散锚点对比**, 不是连续曲线。
--==========================================================================
local trackOn, trackStart, trackLog = false, 0, {}
local trackPrevPredCharge, trackPrevPredStasis = nil, nil
local trackPrevChargesActive, trackPrevStasisUsable = nil, nil
-- v1.36.21: 信号可读性统计 —— 用来回答"为什么没捕捉到锚点"(是没发生? 还是信号读不到?)
local trackStat = {}
local function TrackStatReset()
    trackStat = { chCN = 0, chCO = 0, chPN = 0, chPO = 0,   -- 绿喷 isActive: 战斗/脱战 × 读不到/可读
                  suCN = 0, suCO = 0, suPN = 0, suPO = 0,   -- 静滞 IsSpellUsable: 同上
                  phase = {} }
end
TrackStatReset()

local function TrackReset()
    trackOn, trackStart, trackLog = false, 0, {}
    trackPrevPredCharge, trackPrevPredStasis = nil, nil
    trackPrevChargesActive, trackPrevStasisUsable = nil, nil
    TrackStatReset()
end

-- 每帧调用: 检测布尔翻转 -> 记一条锚点
local function TrackTick()
    if not trackOn then return end
    local now = GetTime()
    local inCombat = (UnitAffectingCombat and UnitAffectingCombat("player")) and true or false
    local flowOpen = (flowUntil > now)

    -- ① 绿喷满层 (isActive: true -> false)
    local isActive = nil
    pcall(function()
        local ch = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(DREAM_BREATH_SPELL_ID)
        if type(ch) == "table" then
            local v = ch.isActive
            if not (issecretvalue and issecretvalue(v)) then isActive = v end
        end
    end)
    if trackPrevChargesActive == true and isActive == false and trackPrevPredCharge then
        trackLog[#trackLog + 1] = { kind = "绿喷满层", at = now, pred = trackPrevPredCharge,
            diff = trackPrevPredCharge - now, combat = inCombat, flow = flowOpen }
    end
    trackPrevChargesActive = isActive

    -- ② 静滞 CD 结束 (IsSpellUsable: false -> true, 仅 COOLDOWN 阶段)
    local usable = nil
    pcall(function()
        if C_Spell and C_Spell.IsSpellUsable then
            local u = C_Spell.IsSpellUsable(STASIS_SPELL_ID)
            if not (issecretvalue and issecretvalue(u)) then usable = u and true or false end
        end
    end)
    if stasisState.phase == "COOLDOWN" and trackPrevStasisUsable == false and usable == true
       and trackPrevPredStasis then
        trackLog[#trackLog + 1] = { kind = "静滞CD好", at = now, pred = trackPrevPredStasis,
            diff = trackPrevPredStasis - now, combat = inCombat, flow = flowOpen }
    end
    trackPrevStasisUsable = usable

    -- v1.36.21: 统计信号可读性(定性"没锚点"的原因)
    if inCombat then
        if isActive == nil then trackStat.chCN = trackStat.chCN + 1 else trackStat.chCO = trackStat.chCO + 1 end
        if usable == nil then trackStat.suCN = trackStat.suCN + 1 else trackStat.suCO = trackStat.suCO + 1 end
    else
        if isActive == nil then trackStat.chPN = trackStat.chPN + 1 else trackStat.chPO = trackStat.chPO + 1 end
        if usable == nil then trackStat.suPN = trackStat.suPN + 1 else trackStat.suPO = trackStat.suPO + 1 end
    end
    trackStat.phase[stasisState.phase or "?"] = (trackStat.phase[stasisState.phase or "?"] or 0) + 1

    -- 帧末缓存(给下一帧的对比用 —— 本帧模型可能已结算过, 所以取上一帧的值)
    trackPrevPredCharge = chargeModel.nextChargeAt
    trackPrevPredStasis = stasisState.cooldownEndTime
end

--==========================================================================
-- v1.33 引擎句柄 (DurationObject) — 战斗中零本地计算的官方通道
--==========================================================================
-- 【背景】战斗中暴雪把冷却/充能的时间数字全部加密(secret), 没有任何 API 能
--   读到普通数字 —— 冷却管理器(CooldownViewer)也一样: 它的
--   GetCooldownViewerCooldownInfo 只有 spellID/isKnown/charges有无 等身份字段,
--   根本没有时间字段 (2026-09-12 查证 warcraft.wiki.gg + TellMeWhen/
--   EllesmereUICooldownManager 源码: TMW 本体不用冷却管理器, EUI 的 CDM 才用)。
-- 【通道】11.1.5+ 的 DurationObject 句柄:
--   C_Spell.GetSpellChargeDuration(sid)   = 绿喷"下一层充能"句柄
--   C_Spell.GetSpellCooldownDuration(sid) = 静滞 CD 句柄
--   句柄由客户端引擎驱动, 实时跟踪心流加速/溜溜球减CD; GetRemainingDuration()
--   返回 secret number —— 禁止比较/算术, 但 FontString:SetFormattedText(fmt,..)
--   是暴雪白名单, 能直接渲染引擎算好的精确值 (EUI 冷却管理器同原理)。
-- 【分工】显示(倒计时/层数数字) -> 引擎句柄, 精度=游戏本体;
--         状态逻辑/预测/脱战对账 -> 本地模型 (不变)。
-- 【secret 安全守则】任何值必须先 issecretvalue() 再做比较/算术 ——
--   secret 与 nil 比较都会抛错, 顺序反了就是 v1.32.16 那种崩溃。
--==========================================================================
local Engine = {
    charge = nil, chargeT = 0,   -- 绿喷下一层充能句柄 (nil=未取过, false=取过且当前无)
    stasis = nil, stasisT = 0,   -- 静滞CD句柄
    REVALIDATE = 1.0,            -- 句柄重取间隔(秒): 新充能/新CD开始后最多1s内刷新
}

local function EngineInvalidate()
    Engine.charge = nil
    Engine.stasis = nil
end

local function EngineSupported()
    return C_Spell ~= nil
       and (C_Spell.GetSpellChargeDuration ~= nil
            or C_Spell.GetSpellCooldownDuration ~= nil)
end

-- 取绿喷"下一层充能"句柄 (缓存1s; 返回 DurationObject 或 nil=当前无充能)
local function EngineChargeHandle()
    if not (C_Spell and C_Spell.GetSpellChargeDuration) then return nil end
    local now = GetTime()
    if Engine.charge == nil or (now - Engine.chargeT) > Engine.REVALIDATE then
        local ok, obj = pcall(C_Spell.GetSpellChargeDuration, DREAM_BREATH_SPELL_ID)
        Engine.charge = (ok and obj) or false
        Engine.chargeT = now
    end
    return Engine.charge or nil
end

-- 取静滞CD句柄 (仅状态机认为 COOLDOWN 时才有意义, 避免 GCD 污染读成 1.5s)
local function EngineStasisHandle()
    if not (C_Spell and C_Spell.GetSpellCooldownDuration) then return nil end
    if stasisState.phase ~= "COOLDOWN" then return nil end
    local now = GetTime()
    if Engine.stasis == nil or (now - Engine.stasisT) > Engine.REVALIDATE then
        local ok, obj = pcall(C_Spell.GetSpellCooldownDuration, STASIS_SPELL_ID)
        Engine.stasis = (ok and obj) or false
        Engine.stasisT = now
    end
    return Engine.stasis or nil
end

-- 读句柄剩余秒。
-- 返回: rem(number 或 secret number), isSecret(boolean)
--   isSecret=false: rem 是普通 number, 可比较/算术
--   isSecret=true : rem 是 secret number, 只能进 FontString:SetFormattedText
--   rem=nil       : 句柄读不到 (已就绪/异常)
local function EngineRemaining(handle)
    if not handle then return nil, false end
    local ok, rem = pcall(function() return handle:GetRemainingDuration() end)
    if not ok then return nil, false end
    if issecretvalue and issecretvalue(rem) then
        return rem, true
    elseif type(rem) == "number" then
        return rem, false
    end
    return nil, false
end

-- 引擎层数读取 (战斗中可用的 clean 信号 + secret-safe 的显示值)
-- 返回表: { max=2, recharging=true/false/nil, cur=1, curSecret=<secret> }
--   recharging 来自 isActive (官方 clean 布尔, 语义 false=已满层); 战斗中也可读
--   cur 可能 secret (战斗中) -> curSecret 即其原值 (只能进 SetFormattedText)
local function EngineChargesInfo()
    if not (C_Spell and C_Spell.GetSpellCharges) then return nil end
    local ok, ch = pcall(C_Spell.GetSpellCharges, DREAM_BREATH_SPELL_ID)
    if not ok or type(ch) ~= "table" then return nil end
    local out = {}
    local mx = ch.maxCharges
    if issecretvalue and issecretvalue(mx) then
        -- 理论上 max 不加密, 保险起见不取
    elseif type(mx) == "number" and mx > 0 then
        out.max = math.floor(mx + 0.5)
    end
    local act = ch.isActive
    if (issecretvalue and issecretvalue(act)) or act == nil then
        out.recharging = nil    -- 加密/无该字段(老API回退/mock), 不判断
    else
        out.recharging = act and true or false
    end
    local cur = ch.currentCharges
    if issecretvalue and issecretvalue(cur) then
        out.curSecret = cur
    elseif type(cur) == "number" then
        out.cur = math.floor(cur + 0.5)
    end
    return out
end

-- v1.33: line1 的引擎渲染 (v1.35.1: 层数从这行拆出, 独立成大字号贴在大字右侧)。
-- 用引擎句柄/引擎层数直接 SetFormattedText —— secret/clean 数值都能渲染,
-- 显示值 = 游戏引擎真值 (含心流加速/溜溜球减CD), 不再经过本地模型。
--   fs       = 右上角 CD 行 ("静滞CD Xs")
--   chargeFs = 大字右侧的层数徽标 ("X/X", 绿色); 传 nil 则只渲染 CD 行
-- 返回 true=已接管 (调用方不要再 SetText); false=引擎无数据, 走原路径。
local function RenderEngineCDLine(fs, data, chargeFs)
    if not EngineSupported() then return false end

    -- 静滞部分: 仅状态机认为 COOLDOWN 时用句柄
    local stasisOnCD = (stasisState.phase == "COOLDOWN")
    local stasisArg = nil
    if stasisOnCD then
        local h = EngineStasisHandle()
        if h then
            local rem = EngineRemaining(h)
            if rem then stasisArg = rem end   -- clean 或 secret, 都能渲染
        end
    end

    -- 绿喷层数部分
    local eCh = EngineChargesInfo()
    local hasChargeInfo = eCh ~= nil
        and (eCh.max ~= nil or eCh.cur ~= nil
             or eCh.curSecret ~= nil or eCh.recharging ~= nil)

    if stasisArg == nil and not hasChargeInfo then
        return false    -- 引擎完全没数据, 走原路径
    end

    local stasisPart = stasisArg
    if stasisPart == nil then
        stasisPart = (data and data.stasisCD) or 0   -- 模型兜底 (clean)
    end

    local curArg, maxArg
    if hasChargeInfo then
        maxArg = eCh.max or (data and data.dreamMax) or 2
        if eCh.recharging == false then
            curArg = maxArg                    -- 官方 clean 信号: 已满层
        elseif eCh.cur ~= nil then
            curArg = eCh.cur
        elseif eCh.curSecret ~= nil then
            curArg = eCh.curSecret             -- secret, 只能进 SetFormattedText
        else
            curArg = (data and data.dreamCharges) or 0
        end
    else
        curArg = (data and data.dreamCharges) or 0
        maxArg = (data and data.dreamMax) or 2
    end

    fs:SetFormattedText("静滞CD %.0fs", stasisPart)
    if chargeFs then
        chargeFs:SetFormattedText("%d/%d", curArg, maxArg)
    end
    return true
end

-- 当玩家施放绿喷时累加计数
local function OnDreamBreathCast(spellID)
    usageCounter.used = (usageCounter.used or 0) + 1
    ChargeModelConsume(spellID)   -- 本地充能模型同步扣层 (战斗中这是唯一层数来源)
    EngineInvalidate()            -- v1.33: 新一轮充能开始, 引擎句柄下帧重取
    Trace(string.format("绿喷施放 spellID=%s (模型扣层), 累计=%d", tostring(spellID), usageCounter.used))
end

--==========================================================================
-- v1.36.1 探针: 蓄力(empower)施法事件原始参数
--   背景: 老板反馈"绿喷蓄力被取消, 本地模型仍算作释放(扣层/计数)"。
--   改逻辑之前先拿真机数据, 要看清三件事:
--     ① 取消时游戏到底发不发 SUCCEEDED(绿喷) —— 发, 就是误判源头;
--     ② EMPOWER_STOP 的 complete 标志在战斗中能否读到 (还是 secret);
--     ③ 事件能否用 castGUID / castBarID 配对 (官方标注 castBarID 为 NeverSecret)。
--   只记录, 不参与任何业务判断; 用 /DBSH cast 打印。
--   所有参数读取都包 pcall —— secret 值参与 tostring/比较会抛错。
--==========================================================================
local CAST_PROBE_MAX = 40
local castProbe = {}

-- v1.36.2: 探针/帮助里显示的版本号从插件元数据读 —— 避免"代码已升级、文案没跟"的误会
--   (上一次就是这个坑: 探针标题硬写 v1.36.1, 实际跑的已是 v1.36.2)
local ADDON_VERSION = "?"
pcall(function()
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        ADDON_VERSION = C_AddOns.GetAddOnMetadata(AddonName, "Version") or "?"
    elseif GetAddOnMetadata then
        ADDON_VERSION = GetAddOnMetadata(AddonName, "Version") or "?"
    end
end)

local function CastProbeArgDesc(v)
    local ok, s = pcall(function()
        if issecretvalue and issecretvalue(v) then return "secret" end
        local t = type(v)
        if t == "string" then return "str=" .. v end
        if t == "number" then return "num=" .. tostring(v) end
        if t == "boolean" then return "bool=" .. tostring(v) end
        if t == "nil" then return "nil" end
        return t
    end)
    if not ok then return "<读参数抛错>" end
    return s
end

-- 记录一条事件 (先把 args 存表 —— 存 secret 是安全的, 比较/算术才抛错)
local function CastProbeLog(event, ...)
    local n = select("#", ...)
    local args = { ... }
    local ok = pcall(function()
        local parts = {}
        for i = 1, n do
            parts[#parts + 1] = string.format("a%d[%s]", i, CastProbeArgDesc(args[i]))
        end
        castProbe[#castProbe + 1] = string.format("[%.1fs] %-30s %s | 模型层=%s/%s used=%s",
            GetTime(), event, table.concat(parts, " "),
            tostring(chargeModel.currentCharges), tostring(chargeModel.maxCharges),
            tostring(usageCounter.used))
        if #castProbe > CAST_PROBE_MAX then table.remove(castProbe, 1) end
    end)
    if not ok then
        castProbe[#castProbe + 1] = string.format("[%.1fs] %-30s <记录异常>", GetTime(), event)
        if #castProbe > CAST_PROBE_MAX then table.remove(castProbe, 1) end
    end
end

-- 消费队列的一个技能 (FIFO): 头部弹出, openingLastIndex++
-- 只有队列还有对应类型的技能时才消耗
local function ConsumeQueueItem(itemType)
    if not openingQueue or #openingQueue == 0 then return end
    -- 检查头部是不是这个类型 (FIFO)
    if openingQueue[openingLastIndex + 1] == itemType then
        openingLastIndex = openingLastIndex + 1
    end
end

--==========================================================================
-- 主状态判断
--==========================================================================

-- 核心绿喷判断 (v1.11 抽出复用: ARMED 和 COOLDOWN 两个阶段都走这里)
-- 静滞CD = T, 绿喷层数 = N; 预测"现在再用1次绿喷, 静滞CD好时还剩几层"
-- T >= 50s:        任意层数放心喷 (50s内时空畸体可用2次, 充能红利充足)
-- 40 <= T < 50s:   N>=1 就能用 (40-50s够充回1层)
-- 20 <= T < 40s:   至少保留1层 (projected >= 1) 才算安全
-- T < 20s:         完全停手 (时空畸体都用不了, 充能来不及)
local function EvaluateCoreStasis(dreamInfo, stasisRemaining)
    local stasisInfo = { remaining = stasisRemaining, total = STASIS_COOLDOWN_DURATION, onCooldown = true }

    local projected = ProjectChargesAfterCast(dreamInfo, stasisInfo)
    if not projected then
        return STATE.SAFE, {
            dreamCharges = dreamInfo.currentCharges,
            dreamMax = dreamInfo.maxCharges,
            dreamNextIn = dreamInfo.nextChargeIn,
            stasisCD = stasisRemaining,
            projected = 2,
            message = "放心喷",
        }
    end

    local data = {
        dreamCharges = dreamInfo.currentCharges,
        dreamMax = dreamInfo.maxCharges,
        dreamNextIn = dreamInfo.nextChargeIn,
        stasisCD = stasisRemaining,
        projected = projected,
        usedCount = usageCounter.used,
    }

    local T = stasisRemaining
    local N = dreamInfo.currentCharges

    if T >= 50 then
        data.message = "放心喷 (CD长, 充能来得及)"
        return STATE.SAFE, data
    elseif T < 20 then
        data.message = "停手! CD<20s 充能来不及"
        return STATE.STOP, data
    elseif T >= 40 then
        -- 40-50s段: 修正 - 只要手里有1层就能喷 (40-50s够充回)
        if N >= 1 then
            data.message = "放心喷 (40-50s段, 1层够充回)"
            return STATE.SAFE, data
        else
            data.message = "停手! 40-50s段没绿喷"
            return STATE.STOP, data
        end
    else
        -- 20-40s段: 至少保留1层, 文案细分显示实际剩余层数
        if projected >= 1 then
            data.message = string.format("注意! 再喷只留%d层 (极限)", projected)
            return STATE.WARNING, data
        else
            data.message = "停手! 20-40s段, 再喷0层"
            return STATE.STOP, data
        end
    end
end

local function EvaluateState()
    -- 1. 资格门槛 (v1.32: 读事件驱动缓存, 不每帧重算。
    --    注: 旧函数 IsFlameshaperPreservation 已于 v1.32.2 删除——它是死代码,
    --        且内部用了 12.0 已移除的 GetSpecialization(), 留着是隐患。
    --    nil=尚未检测不拦截, false=已确认不合格)
    if eligibility.eligible == false then
        return STATE.OFFLINE, nil
    end

    -- 2. 读取绿喷和静滞状态
    -- 战斗中充能API可能返回secret值 -> 用本地充能模型顶上
    local dreamInfo = GetSpellChargeInfo(DREAM_BREATH_SPELL_ID)
    SyncChargeModel(dreamInfo)
    if (not dreamInfo) or dreamInfo.secret then
        dreamInfo = GetLocalChargeInfo()
    end
    local stasisInfo = GetSpellCooldownInfo(STASIS_SPELL_ID)

    -- v1.17: 模型从未校准(进战斗前没读到真实层数)时, 假设满层兜底,
    -- 而不是返回 OFFLINE (旧逻辑会让战斗中绿喷判断直接失效)
    if not dreamInfo then
        chargeModel.currentCharges = chargeModel.maxCharges
        chargeModel.nextChargeAt = nil
        dreamInfo = GetLocalChargeInfo()
    end

    if not dreamInfo then return STATE.OFFLINE, nil end

    -- 2.5 更新使用次数计数器 (检测静滞新一轮CD)
    -- stasisInfo 是 secret 时跳过 (计数器由 OnStasisRelease/UpdateStasisState 本地维护)
    if not stasisInfo or not stasisInfo.secret then
        UpdateUsageCounter(dreamInfo, stasisInfo)
    end

    -- 3. 静滞状态判断 (用本地施法事件驱动的状态机, 不依赖 GetSpellCooldown 避免卡3s)
    local phase = UpdateStasisState()

    -- 3.0 自我同步 (v1.9 重构): 仅在"非战斗"时用真实 CD 兜底校准
    -- 战斗中: 完全信任本地状态机 (施法序列 370537/370564 + 本地90s计时)
    --   因为战斗中 GetSpellCooldown 是 secret number, actualRem 必为 nil,
    --   旧逻辑会跳过校验 → 锁死 READY → 显示"静滞好了"但实际还在冷却 (核心bug)
    -- v1.36.26: + `not probeSuspendSync` —— 这条也是"脱战自动取系统值"的路径, 且在 EvaluateState 里每帧跑。
    --   它的触发条件恰好是「模型认为 CD 好了、官方说还在 CD」= **模型偏快(危险方向)**,
    --   不拦住的话, 最该被抓到的偏差会被它当场抹平。(老板 2026-09-21 指出"脱战永远测不出差异")
    if phase == "READY" and not InCombatLockdown() and not probeSuspendSync then
        local realCD = GetSpellCooldownInfo(STASIS_SPELL_ID)
        local actualRem = (realCD and not realCD.secret) and realCD.remaining or nil
        if actualRem and actualRem > 1.5 then
            -- 出战斗且API可信: 说明本地状态机漏了释放事件(如/reload), 强制同步
            stasisState.phase = "COOLDOWN"
            stasisState.cooldownEndTime = GetTime() + actualRem
            phase = "COOLDOWN"
            Trace("自我同步(非战斗): API在CD -> 强制COOLDOWN (剩余" .. string.format("%.0f", actualRem) .. "s)")
            usageCounter.used = 0
            usageCounter.stasisCDEndTime = stasisState.cooldownEndTime
        end
    end

    -- 3a. STORING 阶段: 已按静滞, 正在存3个技能 (尚未进CD)
    --   0-6s: 显示队列图标; 6s后仍在存: 显示"存技能中"文字 (不显示心火, 因为还没存满)
    if phase == "STORING" then
        local elapsed = GetTime() - stasisState.activeStartTime
        local data = {
            dreamCharges = dreamInfo.currentCharges,
            dreamMax = dreamInfo.maxCharges,
            dreamNextIn = dreamInfo.nextChargeIn,
            message = string.format("静滞存储中 %d/3, 存满进CD", stasisState.storedCount or 0),
            queue = (elapsed < STASIS_OPENING_QUEUE_DURATION) and openingQueue or nil,
            usedIndex = openingLastIndex,
            innerfire = false,  -- STORING 阶段不显示心火 (还没存满)
        }
        return STATE.STASIS_OPENING, data
    end

    -- 3b. ARMED 阶段: 存满3技能, 静滞已进入90s冷却, 30s内可释放
    if phase == "ARMED" then
        -- 心火窗口: 按下静滞后15s内, 若已存满, 显示心火+剩余倒计时 (跟随真实心火buff)
        if stasisState.innerfireEndTime > GetTime() then
            local remaining = stasisState.innerfireEndTime - GetTime()
            local data = {
                dreamCharges = dreamInfo.currentCharges,
                dreamMax = dreamInfo.maxCharges,
                dreamNextIn = dreamInfo.nextChargeIn,
                message = "心灵之火",
                innerfire = true,
                innerfireRemaining = remaining,
            }
            return STATE.STASIS_OPENING, data
        end
        -- 心火已过(15s+), 静滞在CD, 走核心判断
        -- v1.34.3: 未释放 -> 已存技能排持续显示 (直到释放才清)
        local stasisRemaining = GetStasisCDRemaining()
        local state, data = EvaluateCoreStasis(dreamInfo, stasisRemaining)
        data.message = data.message .. " (静滞可释放)"
        if #(stasisState.storedSpellIDs or {}) > 0 then
            data.keepStoredIcons = true
        end
        return state, data
    end

    -- 3b.5 (v1.34.3): 心火15s内就释放了静滞 -> 只显示心火buff倒计时, 不再显示已存技能排
    --   (COOLDOWN 且仍处心火窗口 = 刚释放; ARMED 30s超时不可能落在按下后15s内)
    --   存储信息已在 OnStasisRelease 清空, 这里只是让心火倒计时继续走完
    if phase == "COOLDOWN" and (stasisState.innerfireEndTime or 0) > GetTime() then
        local data = {
            dreamCharges = dreamInfo.currentCharges,
            dreamMax = dreamInfo.maxCharges,
            dreamNextIn = dreamInfo.nextChargeIn,
            message = "心灵之火",
            innerfire = true,
            innerfireRemaining = stasisState.innerfireEndTime - GetTime(),
            hideStoredIcons = true,  -- 已释放, 存储排隐藏
        }
        return STATE.STASIS_OPENING, data
    end

    -- 3c. 静滞可用: 本地状态READY (静滞不在CD, 可开)
    if phase == "READY" then
        -- 自我同步已经把"实际在CD但本地是READY"的情况纠正成COOLDOWN
        -- 走到这里说明 phase 真的是 READY, 显示静滞可用
        local data = {
            dreamCharges = dreamInfo.currentCharges,
            dreamMax = dreamInfo.maxCharges,
            dreamNextIn = dreamInfo.nextChargeIn,
            message = "静滞可用! 准备开",
        }
        return STATE.STASIS_READY, data
    end

    -- 4. 静滞冷却中 -> 核心判断 (用本地状态算remaining, 不依赖 GetSpellCooldown)
    local stasisRemaining = GetStasisCDRemaining()
    if stasisRemaining <= 0 then
        -- CD刚结束本地还没切到READY, 强制切
        stasisState.phase = "READY"
        TraceOnce("step4: CD剩余0 -> 强制READY (显示可用)")
        local data = {
            dreamCharges = dreamInfo.currentCharges,
            dreamMax = dreamInfo.maxCharges,
            dreamNextIn = dreamInfo.nextChargeIn,
            message = "静滞可用! 准备开",
        }
        return STATE.STASIS_READY, data
    end
    -- 构造 stasisInfo 给核心判断用
    return EvaluateCoreStasis(dreamInfo, stasisRemaining)
end

--==========================================================================
-- UI 创建
--==========================================================================

-- frame 的前向声明已上移到资格检测段 (RefreshEligibility 禁用时要 Hide 主UI)
local statusText, dataText1, dataText2, counterText
local dataCharges          -- v1.35.1: 绿喷层数独立大字 (贴在大字右侧, 绿色, 比大字小一号)
-- v1.35.1 层数徽标字号 (比对应状态的大字小 4pt)
local CHARGE_TEXT_SIZE       = 22   -- 常态大字 26pt
local CHARGE_TEXT_SIZE_ARMED = 18   -- 存满待释放 (大字压到 22pt)
local CHARGE_TEXT_SIZE_READY = 20   -- v1.35.2: 静滞就绪时右下角单独一行 (无大字陪衬, 独立放大)
local border, indicator
-- 静滞打开阶段的图标队列 (3个槽位: 绿喷·绿喷·时空畸体)
-- queueIcons/Labels 表上移到 file-scope 早期, 这样后面定义的 UpdateUI 能用到
-- v1.34: 队列图标缩小成 20x20 挪到顶部, 与下方"已存技能"大图标逐列对齐
local queueIcons = {}      -- { [1]=texture, [2]=texture, [3]=texture }
local queueLabels = {}     -- { [1]=fontstring, [2]=fontstring, [3]=fontstring }

-- v1.34: StasisTracker 式"已存技能"大图标 (3槽位)
--   STORING 阶段每个白名单技能施放成功 -> 按顺序填入真实图标 (仿 PreservationStasisTracker)
--   已存槽位 = 真实技能图标(原色), 待存槽位 = 问号半透明
local storedIcons = {}     -- { [1]=texture, [2]=texture, [3]=texture }

-- 心灵之火 (7-15s 阶段): 大图标 + "剩余X秒" 文字
local innerfireIcon       -- 心灵之火图标 Texture
local innerfireLabel      -- "剩余X.X秒" 文字 FontString

-- 前向声明(让 UpdateUI 可以安全调用)
local UpdateQueueIcons
local HideQueueIcons
local UpdateInnerfire
local HideInnerfire
local UpdateStoredIcons
local HideStoredIcons

-- 更新图标队列显示: queue = { 类型1, 类型2, 类型3 }, usedIndex = 已用到第几个(0=没用)
local function _UpdateQueueIcons(queue, usedIndex)
    if not queue or not queueIcons or #queueIcons == 0 then return end
    local TYPE_TO_SPELL = {
        DREAM_BREATH     = DREAM_BREATH_SPELL_ID,
        TEMPORAL_ANOMALY = TEMPORAL_ANOMALY_SPELL_ID,
    }
    local cache = {}
    local function getIcon(itemType)
        if cache[itemType] then return cache[itemType] end
        local sid = TYPE_TO_SPELL[itemType]
        cache[itemType] = GetSpellIconPath(sid) or "Interface\\Icons\\INV_Misc_QuestionMark"
        return cache[itemType]
    end

    for i = 1, 3 do
        local icon = queueIcons[i]
        local label = queueLabels[i]
        local item = queue[i]
        if not item then
            icon:Hide()
            label:Hide()
        else
            icon:Show()
            label:Show()
            icon:SetTexture(getIcon(item))
            -- 图标保持原色 (不染色, 用 alpha 区分状态)
            icon:SetVertexColor(1, 1, 1, 1)
            local isUsed = (i <= (usedIndex or 0))
            if isUsed then
                -- 已用: 原色 + alpha 降低 (看起来变暗)
                icon:SetAlpha(0.35)
                label:SetText("已用")
                label:SetTextColor(COLOR.USED.r, COLOR.USED.g, COLOR.USED.b)
            else
                -- 未用: 原色 + 全亮
                icon:SetAlpha(1.0)
                local posInQueue = i - (usedIndex or 0)
                label:SetText(posInQueue == 1 and "→ 接下来"
                              or posInQueue == 2 and "第2"
                              or posInQueue == 3 and "第3" or "")
                label:SetTextColor(COLOR.SUBTEXT.r, COLOR.SUBTEXT.g, COLOR.SUBTEXT.b)
            end
        end
    end
end

local function _HideQueueIcons()
    if not queueIcons then return end
    for i = 1, 3 do
        if queueIcons[i] then queueIcons[i]:Hide() end
        if queueLabels[i] then queueLabels[i]:Hide() end
    end
end

UpdateQueueIcons = _UpdateQueueIcons
HideQueueIcons = _HideQueueIcons

-- v1.34: 更新"已存技能"大图标 (StasisTracker 式)
--   直接读 stasisState.storedSpellIDs (真实 spellID 列表, 最多3个)
--   已存 -> 真实技能图标原色; 未存 -> 问号半透明 (134400, 仿 PreservationStasisTracker)
local function _UpdateStoredIcons()
    if not storedIcons or #storedIcons == 0 then return end
    local list = stasisState.storedSpellIDs or {}
    for i = 1, 3 do
        local icon = storedIcons[i]
        local sid = list[i]
        if sid then
            icon:SetTexture(GetSpellIconPath(sid) or "Interface\\Icons\\INV_Misc_QuestionMark")
            icon:SetAlpha(1.0)
        else
            icon:SetTexture(134400)  -- 问号图标 (PreservationStasisTracker 同款)
            icon:SetAlpha(0.30)
        end
        icon:Show()
    end
end

local function _HideStoredIcons()
    if not storedIcons then return end
    for i = 1, 3 do
        if storedIcons[i] then storedIcons[i]:Hide() end
    end
end

UpdateStoredIcons = _UpdateStoredIcons
HideStoredIcons = _HideStoredIcons

-- v1.34: STORING 阶段存入一个白名单技能 -> 填进大图标槽位 (实时反馈, 不等下一帧)
local function AddStoredSpellIcon(spellId)
    local list = stasisState.storedSpellIDs or {}
    if #list >= 3 then return end
    list[#list + 1] = spellId
    stasisState.storedSpellIDs = list
    if UpdateStoredIcons then UpdateStoredIcons() end
end

-- 心灵之火 (7-15s 阶段): 单一图标 + "剩余X秒" 文字
local function _UpdateInnerfire(remainingSeconds)
    if not innerfireIcon or not innerfireLabel then return end
    innerfireIcon:Show()
    innerfireLabel:Show()
    innerfireLabel:SetText(string.format("剩余 %.1f 秒", remainingSeconds))
end

local function _HideInnerfire()
    if innerfireIcon then innerfireIcon:Hide() end
    if innerfireLabel then innerfireLabel:Hide() end
end

UpdateInnerfire = _UpdateInnerfire
HideInnerfire = _HideInnerfire

local function CreateUI()
    frame = CreateFrame("Frame", "DreamBreathStasisHelperFrame", UIParent, "BackdropTemplate")
    -- v1.34: 高度 144 -> 176 (底部多一排"已存技能"大图标区)
    frame:SetSize(260, 176)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")

    -- 半透明黑底 (背景自身不透明, 整体透明度由 frame:SetAlpha 控制)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropColor(COLOR.BG.r, COLOR.BG.g, COLOR.BG.b, 1)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.6)
    -- v1.27: 整体透明度用 SetAlpha(作用于 frame+所有子元素: 背景+logo+文字), 不再只调背景
    frame:SetAlpha(db.alpha or 0.82)

    -- 拖动
    frame:SetScript("OnDragStart", function(self)
        if not db.locked then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, relP, x, y = self:GetPoint()
        db.point = p
        db.relPoint = relP
        db.x = x
        db.y = y
    end)

    -- 边框高亮层 (状态颜色)
    border = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    border:SetAllPoints(true)
    border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    border:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.6)

    -- 主区域: 大图标 + 大字 (状态) — 撑满 80% 区域
    -- 区域范围: x[0, 260]  y[44, 144], 即 260x100 中央偏下
    -- 大图标 64x64 在中心偏左
    indicator = frame:CreateTexture(nil, "ARTWORK")
    indicator:SetSize(64, 64)
    indicator:SetPoint("LEFT", frame, "LEFT", 14, 16)
    indicator:SetTexture("Interface\\Buttons\\WHITE8x8")
    indicator:SetVertexColor(0.5, 0.5, 0.5, 1)

    -- 大状态文字 (大字: "可用" / "放心喷" / "注意" / "停手!" 等)
    statusText = frame:CreateFontString(nil, "OVERLAY")
    statusText:SetFont(STANDARD_TEXT_FONT, 26, "OUTLINE")
    statusText:SetPoint("LEFT", indicator, "RIGHT", 12, 0)
    statusText:SetText("...")
    statusText:SetTextColor(1, 1, 1)

    -- 右上角: 静滞CD + 绿喷层数 (小字辅助)
    dataText1 = frame:CreateFontString(nil, "OVERLAY")
    dataText1:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
    dataText1:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -6)
    dataText1:SetTextColor(COLOR.SUBTEXT.r, COLOR.SUBTEXT.g, COLOR.SUBTEXT.b)
    dataText1:SetText("")

    -- 主区域下方: 预测结果文字
    dataText2 = frame:CreateFontString(nil, "OVERLAY")
    dataText2:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    dataText2:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 50)
    dataText2:SetTextColor(COLOR.SUBTEXT.r, COLOR.SUBTEXT.g, COLOR.SUBTEXT.b)
    dataText2:SetText("")

    -- 计数器文字(右下角)
    counterText = frame:CreateFontString(nil, "OVERLAY")
    counterText:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
    counterText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 6)
    counterText:SetTextColor(COLOR.SUBTEXT.r, COLOR.SUBTEXT.g, COLOR.SUBTEXT.b)
    counterText:SetText("")

    -- v1.35.1: 绿喷层数独立大字 (玩家反馈右上角 11pt 太小)
    --   位置 = 紧贴大字右侧, 绿色, 比大字小 4pt; 只由 STOP/WARNING/SAFE 三态显示
    dataCharges = frame:CreateFontString(nil, "OVERLAY")
    dataCharges:SetFont(STANDARD_TEXT_FONT, CHARGE_TEXT_SIZE, "OUTLINE")
    dataCharges:SetPoint("LEFT", statusText, "RIGHT", 10, 0)
    dataCharges:SetTextColor(COLOR.SAFE.r, COLOR.SAFE.g, COLOR.SAFE.b)
    dataCharges:SetText("")
    dataCharges:Hide()

    -- 静滞打开阶段: 3个图标队列 (绿喷·绿喷·时空畸体)
    -- v1.34: 缩小成 20x20 挪到顶部 (TOP 锚点), xOffset 与下方大图标相同 = 逐列一一对应
    --   小图标(20) 至少是大图标(44)的一半以下, 满足"喷喷球图标要小一倍"
    for i = 1, 3 do
        local xOffset = (i - 2) * 72  -- i=1:-72, i=2:0, i=3:+72
        -- 图标 Texture
        local icon = frame:CreateTexture(nil, "ARTWORK")
        icon:SetSize(20, 20)
        icon:SetPoint("TOP", frame, "TOP", xOffset, -26)
        icon:Hide()
        queueIcons[i] = icon
        -- 图标下方标签 (顺序号 / 已用提示)
        local label = frame:CreateFontString(nil, "OVERLAY")
        label:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
        label:SetPoint("TOP", icon, "BOTTOM", 0, 1)
        label:SetTextColor(COLOR.SUBTEXT.r, COLOR.SUBTEXT.g, COLOR.SUBTEXT.b)
        label:Hide()
        queueLabels[i] = label
    end

    -- v1.34: StasisTracker 式"已存技能"大图标 (3槽位, 占据原队列图标的下半区位置)
    --   已存槽位 = 真实技能图标(原色), 待存槽位 = 问号半透明 (仿 PreservationStasisTracker)
    --   上方小图标(计划队列) 与本排逐列一一对应
    for i = 1, 3 do
        local xOffset = (i - 2) * 72
        local icon = frame:CreateTexture(nil, "ARTWORK")
        icon:SetSize(44, 44)
        icon:SetPoint("BOTTOM", frame, "BOTTOM", xOffset, 40)
        icon:SetTexture(134400)  -- 问号图标
        icon:SetAlpha(0.30)
        icon:Hide()
        storedIcons[i] = icon
    end

    -- ===== 心灵之火 (7-15s 阶段) =====
    -- 大图标(60x60, 跟绿喷那个差不多大) + 右侧"剩余X秒"文字
    -- v1.34: y 上移到 +26 (下方让位给"已存技能"大图标排)
    innerfireIcon = frame:CreateTexture(nil, "ARTWORK")
    innerfireIcon:SetSize(60, 60)
    innerfireIcon:SetPoint("CENTER", frame, "CENTER", -36, 26)  -- 偏左偏上, 让位置给右侧文字和下方图标排
    innerfireIcon:SetTexture(GetSpellIconPath(INNERFIRE_SPELL_ID) or "Interface\\Icons\\INV_Misc_QuestionMark")
    innerfireIcon:Hide()

    innerfireLabel = frame:CreateFontString(nil, "OVERLAY")
    innerfireLabel:SetFont(STANDARD_TEXT_FONT, 18, "OUTLINE")
    innerfireLabel:SetPoint("LEFT", innerfireIcon, "RIGHT", 10, 0)
    innerfireLabel:SetTextColor(1, 0.85, 0.4)  -- 金色
    innerfireLabel:Hide()

    -- 红灯闪烁动画(只闪边框, 不染图标)
    local flashTime = 0
    frame:SetScript("OnUpdate", function(self, elapsed)
        flashTime = flashTime + elapsed
        if frame.flashState == STATE.STOP then
            local alpha = 0.5 + 0.4 * math.sin(flashTime * 6)
            border:SetBackdropBorderColor(COLOR.STOP.r, COLOR.STOP.g, COLOR.STOP.b, alpha)
            -- indicator 保持原色, 不染红
        end
    end)

    -- 应用位置/缩放
    frame:ClearAllPoints()
    frame:SetPoint(db.point, db.relFrame or UIParent, db.relPoint, db.x, db.y)
    frame:SetScale(db.scale or 1.0)
end

-- 更新UI显示
UpdateUI = function()
    if not frame then return end

    if not db.enabled then
        frame:Hide()
        return
    end
    -- v1.32 功能二: 资格不合格时隐藏主UI, 不渲染 (nil=未检测不拦)
    -- v1.32.3: 老板在控制台手动强制启用(forceEnabled)时不受资格拦截
    if eligibility.eligible == false and not forceEnabled then
        if frame then frame:Hide() end
        return
    end
    frame:Show()

    local state, data = EvaluateState()

    -- 默认数据兜底
    data = data or {}

    -- v1.33: 引擎满层校正 —— isActive 是 clean 布尔("false=已满层"), 战斗中可读。
    --   模型层数有秒级漂移时, 用官方信号把"其实已满"纠正过来 (只纠"已满"方向,
    --   反方向需要具体层数数字, 战斗中是 secret, 留给模型/引擎显示)。
    local _eCh0 = EngineChargesInfo()
    if _eCh0 and _eCh0.recharging == false and _eCh0.max then
        data.dreamCharges = _eCh0.max
        if not data.dreamMax then data.dreamMax = _eCh0.max end
    end

    local color
    local statusMsg = ""
    local line1 = ""
    local line2 = ""
    local counter = ""
    local mainIconPath = nil  -- 主图标纹理路径 (spell 图标)
    -- v1.35.1: 层数徽标是否显示 (只有 STOP/WARNING/SAFE 三态显示, 其余状态大字/右下角已有层数)
    local showCharges = false

    -- 非STASIS_OPENING状态: 还原主区域布局 (大图标 + 大字)
    if state ~= STATE.STASIS_OPENING then
        indicator:ClearAllPoints()
        indicator:SetSize(64, 64)
        indicator:SetPoint("LEFT", frame, "LEFT", 14, 16)  -- 齿轮按钮已删, 回到原位
        statusText:ClearAllPoints()
        statusText:SetFont(STANDARD_TEXT_FONT, 26, "OUTLINE")
        statusText:SetPoint("LEFT", indicator, "RIGHT", 12, 0)
        -- v1.35.1: 层数徽标跟着大字走 (常态字号)
        dataCharges:SetFont(STANDARD_TEXT_FONT, CHARGE_TEXT_SIZE, "OUTLINE")
        dataCharges:ClearAllPoints()
        dataCharges:SetPoint("LEFT", statusText, "RIGHT", 10, 0)
        dataText2:ClearAllPoints()
        dataText2:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 50)
    end

    -- 非STASIS_OPENING状态: 确保图标队列隐藏 (兜底)
    -- v1.34.3: 已存技能排未释放时持续显示 (ARMED心火过后走核心判断也要看得到存储信息)
    if state ~= STATE.STASIS_OPENING then
        HideQueueIcons()
        HideInnerfire()
        if data.keepStoredIcons then
            UpdateStoredIcons()
        else
            HideStoredIcons()
        end
    end

    -- v1.34.9: 核心判断 + 已存技能排并存 (ARMED心火过后未释放) ->
    --   绿喷判断(大图标+大字)上移到存储排上方居中并放大 (用户指定: 判断放存储排上面, 弄大点)
    --   存储排 44x44 占 y40-84, 判断区放 y94-142 (48x48 图标 + 22pt 大字), 不再压缩塞左下角
    if data.keepStoredIcons
       and (state == STATE.STOP or state == STATE.WARNING or state == STATE.SAFE) then
        indicator:ClearAllPoints()
        indicator:SetSize(48, 48)
        indicator:SetPoint("CENTER", frame, "CENTER", -30, 30)
        statusText:ClearAllPoints()
        statusText:SetFont(STANDARD_TEXT_FONT, 22, "OUTLINE")
        statusText:SetPoint("LEFT", indicator, "RIGHT", 10, 0)
        -- v1.35.1: 层数徽标同步缩小 (与 22pt 大字配)
        dataCharges:SetFont(STANDARD_TEXT_FONT, CHARGE_TEXT_SIZE_ARMED, "OUTLINE")
        dataCharges:ClearAllPoints()
        dataCharges:SetPoint("LEFT", statusText, "RIGHT", 8, 0)
        dataText2:ClearAllPoints()
        dataText2:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 24)
    end

    if state == STATE.OFFLINE then
        color = COLOR.OFFLINE
        statusMsg = "未启用"
        line1 = "非塑焰恩护唤魔师"
        line2 = ""
        frame.flashState = nil
        mainIconPath = nil  -- 主区域留空
        indicator:Hide()
    elseif state == STATE.STASIS_READY then
        -- v1.21: 静滞好了后, 醒目确认绿喷是否满2层(老板起手必须2层才开静滞)
        local charges = data.dreamCharges or 0
        local maxCharges = data.dreamMax or 2
        mainIconPath = GetSpellIconPath(STASIS_SPELL_ID)
        if charges >= maxCharges then
            -- 绿喷已满2层 -> 绿灯大字"可以开"
            color = COLOR.READY
            statusMsg = "静滞准备ok!"
            -- v1.35.2: 层数从右上角挪到右下角并放大 (老板指定: 绿喷 X/2, 字体放大)
            line1 = ""
            dataCharges:SetFont(STANDARD_TEXT_FONT, CHARGE_TEXT_SIZE_READY, "OUTLINE")
            dataCharges:ClearAllPoints()
            dataCharges:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 22)
            dataCharges:SetText(string.format("绿喷 %d/%d", charges, maxCharges))
            showCharges = true
            line2 = "绿喷已满，可以开静滞"
        else
            -- 绿喷没满 -> 橙/红警示, 大字显示具体层数
            local missing = maxCharges - charges
            if missing >= 2 then
                color = COLOR.STOP
            else
                color = COLOR.WARNING
            end
            statusMsg = string.format("绿喷 %d/%d", charges, maxCharges)
            line1 = string.format("静滞可用 差%d层", missing)
            line2 = string.format("还差%d层，别开静滞", missing)
        end
        frame.flashState = nil
        indicator:Show()
        -- 图标队列隐藏
        HideQueueIcons()
    elseif state == STATE.STASIS_OPENING then
        color = COLOR.OPENING

        if data.innerfire then
            -- 心灵之火阶段: 心火图标 + 剩余秒数, 隐藏队列图标
            HideQueueIcons()
            if data.hideStoredIcons then
                -- v1.34.3: 心火15s内已释放静滞 -> 只显示心火倒计时, 存储排隐藏
                HideStoredIcons()
            else
                UpdateStoredIcons()  -- v1.34: 心火阶段继续显示已存技能大图标 (存满3个)
            end
            indicator:Hide()  -- 主区域大图标隐藏(让位给 innerfire)
            -- 状态文字保留(只在右下角提示"绿喷 1/2"等)
            dataText2:ClearAllPoints()
            dataText2:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 8)
            dataText2:SetText(string.format("绿喷 %d/%d", data.dreamCharges or 0, data.dreamMax or 2))
            dataText2:SetTextColor(0.8, 0.8, 0.8)
            -- 心灵之火图标 + 剩余秒数 (优先用 data.innerfireRemaining, 回退到 openingTotalEndTime)
            local remaining = data.innerfireRemaining
                or math.max(0, (stasisState.innerfireEndTime or 0) - GetTime())
                or 0
            UpdateInnerfire(remaining)
        else
            -- 0-6s 阶段: 队列大图标(原逻辑)
            HideInnerfire()
            -- 把主图标缩成小图标放到底部左侧
            indicator:ClearAllPoints()
            indicator:SetSize(22, 22)
            indicator:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 8)
            -- 状态文字缩小, 放到小图标右边
            statusText:ClearAllPoints()
            statusText:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
            statusText:SetPoint("LEFT", indicator, "RIGHT", 6, 0)
            statusText:SetText(data.message or "打开阶段")
            statusText:SetTextColor(color.r, color.g, color.b)
            -- 把 dataText2(预测) 临时复用成打开阶段提示
            dataText2:ClearAllPoints()
            dataText2:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 12)
            mainIconPath = GetSpellIconPath(STASIS_SPELL_ID)
            line1 = string.format("绿喷 %d/%d", data.dreamCharges or 0, data.dreamMax or 2)
            line2 = ""
            frame.flashState = nil
            indicator:Show()
            -- 渲染队列图标 (顶部小图标排)
            UpdateQueueIcons(data.queue, data.usedIndex)
            -- v1.34: 渲染"已存技能"大图标排 (存入=真实图标, 待存=问号半透明)
            UpdateStoredIcons()
        end
    elseif state == STATE.STOP then
        color = COLOR.STOP
        statusMsg = "停手!"
        mainIconPath = GetSpellIconPath(DREAM_BREATH_SPELL_ID)
        line1 = string.format("静滞CD %.0fs", data.stasisCD or 0)
        line2 = string.format("喷后静滞好时剩%d层", data.projected or 0)
        frame.flashState = STATE.STOP
        indicator:Show()
    elseif state == STATE.WARNING then
        color = COLOR.WARNING
        statusMsg = "注意"
        mainIconPath = GetSpellIconPath(DREAM_BREATH_SPELL_ID)
        line1 = string.format("静滞CD %.0fs", data.stasisCD or 0)
        line2 = string.format("再喷1次剩 %d 层", data.projected or 0)
        frame.flashState = nil
        indicator:Show()
    else -- SAFE
        color = COLOR.SAFE
        statusMsg = "随便喷"
        mainIconPath = GetSpellIconPath(DREAM_BREATH_SPELL_ID)
        if data.stasisCD then
            line1 = string.format("静滞CD %.0fs", data.stasisCD or 0)
        else
            line1 = ""    -- v1.35.1: 层数改由大字右侧的徽标显示, 这里不再重复
        end
        line2 = string.format("喷后静滞好时剩%d层", data.projected or 2)
        frame.flashState = nil
        indicator:Show()
    end

    -- v1.35.1: 层数徽标的三态门控 (STOP/WARNING/SAFE -> 挂在大字右侧)
    -- v1.35.2: 改成"条件置位", 这样 STASIS_READY 分支自己设的 true (右下角放大) 不会被覆盖
    if state == STATE.STOP or state == STATE.WARNING or state == STATE.SAFE then
        showCharges = true
    end

    -- 计数器: 默认始终显示, 静滞CD中且用过绿喷时显示 "已用X"
    if data.usedCount and usageCounter.stasisCDEndTime > 0 then
        counter = string.format("已用%d", data.usedCount)
    end

    -- 应用主图标 (保持原色, 不染色; 染色交给边框表达状态)
    if mainIconPath and indicator:IsShown() then
        indicator:SetTexture(mainIconPath)
        indicator:SetVertexColor(1, 1, 1, 1)  -- 全白 = 原色不染色
    end

    -- 应用颜色
    border:SetBackdropBorderColor(color.r, color.g, color.b, 0.85)
    statusText:SetText(statusMsg)
    statusText:SetTextColor(color.r, color.g, color.b)
    -- v1.33: CD 行优先走引擎句柄 (战斗中 secret-safe, 显示=引擎真值含加速/减CD)
    -- v1.35.1: 层数已拆成独立徽标 (大字右侧, 绿色) -> 一起交给引擎渲染
    -- 仅限这三个状态; pcall 双保险: 引擎路径任何意外抛错 -> 回退原 SetText, UI 不冻帧
    local _engTaken = false
    if state == STATE.STOP or state == STATE.WARNING or state == STATE.SAFE then
        local _engOK, taken = pcall(RenderEngineCDLine, dataText1, data, dataCharges)
        _engTaken = _engOK and taken
    end
    if not _engTaken then
        dataText1:SetText(line1)
        -- 引擎不可用 -> 层数徽标走本地模型 (clean 明文, 不涉及 secret)
        -- v1.35.2: STASIS_READY 分支已自己写好 "绿喷 X/2" (带前缀 + 右下角锚点), 不能覆盖
        if state ~= STATE.STASIS_READY then
            dataCharges:SetFormattedText("%d/%d", data.dreamCharges or 0, data.dreamMax or 2)
        end
    end
    -- v1.35.1: 仅 STOP/WARNING/SAFE 三态显示层数徽标
    --   (STASIS_READY 大字本身就是"绿喷 1/2"; 打开阶段右下角已有层数, 避免重复)
    if showCharges then
        dataCharges:SetTextColor(COLOR.SAFE.r, COLOR.SAFE.g, COLOR.SAFE.b)
        dataCharges:Show()
    else
        dataCharges:Hide()
    end
    dataText2:SetText(line2 or "")
    counterText:SetText(counter)

    -- 边框闪烁状态
    if state ~= STATE.STOP then
        frame.flashState = nil
    end
end

--==========================================================================
-- 事件处理
--==========================================================================

FSH:RegisterEvent("ADDON_LOADED")
FSH:RegisterEvent("PLAYER_LOGIN")
FSH:RegisterEvent("PLAYER_ENTERING_WORLD")  -- v1.32 功能二: 进世界时检测资格门槛
FSH:RegisterEvent("SPELL_UPDATE_COOLDOWN")
FSH:RegisterEvent("PLAYER_TALENT_UPDATE")
FSH:RegisterEvent("CHARACTER_POINTS_CHANGED")
FSH:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
FSH:RegisterEvent("TRAIT_CONFIG_UPDATED")         -- v1.32.3: 天赋界面内增删天赋点(11.0+ 事件名)
FSH:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")  -- v1.32.3: 切换天赋方案
FSH:RegisterEvent("SPELLS_CHANGED")               -- v1.32.3: 学/忘法术(含天赋赋予的技能, 如静滞)
FSH:RegisterEvent("PLAYER_REGEN_DISABLED")  -- 进战斗: 强制最后一次校准绿喷充能模型
FSH:RegisterEvent("PLAYER_REGEN_ENABLED")   -- 出战斗: 校准绿喷充能模型

-- 检测施法: UNIT_SPELLCAST_SUCCEEDED (普通施法如时空畸体 + 绿喷等 empowered 完成;
--   12.1 战斗中该事件透出 clean 的 spellId, 是唯一可靠的施法通道)
FSH:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
FSH:RegisterEvent("UNIT_SPELLCAST_START")  -- 记录第3技能施法开始时刻 (静滞90sCD的起算锚点)

-- v1.36.1 探针: 蓄力相关事件全量监听 (只为诊断, 不参与业务逻辑; 见 CastProbeLog)
FSH:RegisterEvent("UNIT_SPELLCAST_EMPOWER_START")
FSH:RegisterEvent("UNIT_SPELLCAST_EMPOWER_STOP")
FSH:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
FSH:RegisterEvent("UNIT_SPELLCAST_FAILED")
FSH:RegisterEvent("UNIT_SPELLCAST_STOP")

-- 高频刷新: 每帧调一次 (WoW 默认 ~60fps, 文字立即更新)
-- 用 pcall 防异常吞噬后续刷新 (这是过去 "CD卡死"的根因之一)
-- 前向声明: UpdateConfigDrag / CreateConfigPanel 定义在文件后面, 但闭包(OnUpdate/OnEvent/C_Timer)
-- 在这里引用它们, 必须在此处先 local 声明(否则闭包引用到的是全局变量, 报 nil)
local UpdateConfigDrag
local CreateConfigPanel
FSH:SetScript("OnUpdate", function(self, elapsed)
    -- 控制台滑块拖动 (独立于 db.enabled, 即使UI隐藏也能拖动)
    UpdateConfigDrag()
    -- v1.32.5: 心流加速按真实时间积分 (独立于 UI 开关, 关掉UI时计时依然准确)
    pcall(TickFlowAcceleration)
    pcall(TrackTick)   -- v1.36.19: 长时程追踪(未开启时立即返回, 开销可忽略)
    -- v1.36.6: 静滞 CD 定期对齐官方剩余 (限流 2s; 战斗中值加密 / 不在 ARMED·COOLDOWN 时函数内部自己跳过)
    if GetTime() - lastStasisSyncAt > 2 then
        lastStasisSyncAt = GetTime()
        pcall(SyncStasisCooldownFromAPI)
    end
    if not db or not db.enabled then return end
    local ok, err = pcall(UpdateUI)
    if not ok and not FSH._updateErrored then
        FSH._updateErrored = true
        print("|cFF7F77DD[绿喷管家]|r OnUpdate错误(已吞): " .. tostring(err))
    end
end)

-- C_Timer 兜底: 即使 OnUpdate 因意外被禁, 也能每0.2秒刷新一次
local fallbackTimer = nil

local function StartFallbackTimer()
    if fallbackTimer then return end
    fallbackTimer = C_Timer.NewTicker(0.2, function()
        if not FSH:IsVisible() then FSH:Show() end
        pcall(TickFlowAcceleration)  -- v1.32.5: OnUpdate 万一不触发时的兜底积分
        local ok = pcall(UpdateUI)
        if not ok and not FSH._fallbackErrored then
            FSH._fallbackErrored = true
            print("|cFF7F77DD[绿喷管家]|r fallback刷新错误(已吞)")
        end
    end)
end

--==========================================================================
-- v1.36.2: 蓄力施法"取消回滚" —— 修"蓄力取消仍被算作释放"
--   真机数据 (2026-09-20 老板探针流水): 绿喷蓄力时游戏发事件的顺序是
--     EMPOWER_START(bar=N) -> SUCCEEDED(355936) -> EMPOWER_STOP(bar=N, complete=false/true)
--   即 **SUCCEEDED 在"开始蓄力"那一刻就发了, 取消也照发** —— 这就是误扣层的根因
--   (v1.29 把施放检测从 EMPOWER_STOP 挪到 SUCCEEDED 时并不知道这一点)。
--   而 EMPOWER_STOP 的 `complete` 是 clean 布尔(false=取消/true=真放出去), spellID 也是明文,
--   castBarID 官方标注 NeverSecret —— 三者可用来精确判定 + 配对。
--
--   方案: **乐观记账 + 取消回滚** —— SUCCEEDED 时照旧立刻扣层/计数/开窗(保证层数实时、
--   充能计时不变、对真实施放零回归), 同时存一份快照; 若随后收到 complete=false 的
--   EMPOWER_STOP, 就把这些状态原样恢复。
--   读不到 complete(某些场景可能被加密)时按"已放出"处理 = 保守, 不会比修前更差。
--==========================================================================
local EMPOWER_STOP_WINDOW = 3.0     -- SUCCEEDED 之后等 STOP 的窗口(秒), 超时不再回滚
local empowerPending = nil          -- { spellID, bar, t, snap }
local lastEmpowerBar = nil          -- 最近一次 EMPOWER_START 的 castBarID
local lastEmpowerSpell = nil
local empowerRollbackCount = 0      -- 回滚次数 (诊断/测试用)

local function EmpowerSnapshot()
    local st = stasisState or {}
    local list = st.storedSpellIDs
    return {
        charges      = chargeModel.currentCharges,
        nextChargeAt = chargeModel.nextChargeAt,
        used         = usageCounter.used,
        lastIndex    = openingLastIndex,
        flowUntil    = flowUntil,
        phase        = st.phase,
        storedCount  = st.storedCount,
        storedN      = list and #list or 0,
        thirdCast    = st.thirdCastStartTime,
        anomalies    = st.storedTemporalAnomalies,
    }
end

local function EmpowerRollback(pending, spID, barID)
    if not pending or not pending.snap then return end
    local s = pending.snap
    local dt = GetTime() - (pending.t or GetTime())
    local hadCharges, hadUsed = chargeModel.currentCharges, usageCounter.used
    -- 1) 层数 / 充能时钟 / 已用计数 / 队列游标 / 心流窗口
    chargeModel.currentCharges = s.charges
    chargeModel.nextChargeAt = s.nextChargeAt
    usageCounter.used = s.used
    openingLastIndex = s.lastIndex
    flowUntil = s.flowUntil
    -- 2) 静滞存储: 绿喷在白名单里, 取消不该占一个存入位
    local st = stasisState
    if st and st.storedCount ~= s.storedCount then
        st.storedCount = s.storedCount
        local list = st.storedSpellIDs
        while list and #list > s.storedN do table.remove(list) end
        st.thirdCastStartTime = s.thirdCast
        st.storedTemporalAnomalies = s.anomalies
        if UpdateStoredIcons then UpdateStoredIcons() end
        if st.phase ~= s.phase then
            -- 极罕见: 取消的这次刚好是"第3个", 状态机已推进 —— 不撤状态机, 只留痕
            ChargeDiag(string.format("!! 蓄力取消回滚: 存满推进已发生(%s->%s), 未撤状态机",
                tostring(s.phase), tostring(st.phase)))
        end
    end
    empowerRollbackCount = empowerRollbackCount + 1
    ChargeDiag(string.format("绿喷蓄力取消 -> 已回滚(未扣层) spellID=%s bar=%s 距SUCCEEDED %.2fs: 层 %s -> %s(已恢复), used %s -> %s(已恢复)",
        tostring(spID), tostring(barID), dt,
        tostring(hadCharges), tostring(chargeModel.currentCharges),
        tostring(hadUsed), tostring(usageCounter.used)))
end

FSH:SetScript("OnEvent", function(self, event, ...)
    -- v1.36.1 探针: 先原样记一条 (只读, 不改任何状态); 报错也不影响下面业务逻辑
    if event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_EMPOWER_START"
       or event == "UNIT_SPELLCAST_EMPOWER_STOP" or event == "UNIT_SPELLCAST_INTERRUPTED"
       or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_STOP" then
        local u = select(1, ...)
        local okU, isPlayer = pcall(function() return u == "player" end)
        if (not okU) or isPlayer then CastProbeLog(event, ...) end
    end

    -- v1.36.2: 蓄力取消回滚 —— START 记 castBarID(用于和 STOP 配对); STOP 按 complete 判定
    if event == "UNIT_SPELLCAST_EMPOWER_START" then
        local a1, a2, a3, a4 = ...
        pcall(function()
            lastEmpowerSpell = a3
            lastEmpowerBar = a4
            -- 上一个 pending 超时没等到 STOP -> 视为已放出, 丢弃快照
            if empowerPending and (GetTime() - (empowerPending.t or 0)) > EMPOWER_STOP_WINDOW then
                -- v1.36.31 兜底: 开窗已移到 STOP 分支, 万一 STOP 没到, 这里**补开窗**
                --   (否则这一次的心流窗口会整场漏掉 -> 后续折算全失效)
                pcall(OnFlowWindowRefresh)
                empowerPending = nil
            end
        end)
        return
    elseif event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        local a1, a2, a3, a4, a5, a6 = ...
        local spID, complete, barID = a3, a4, a6
        local pending = empowerPending
        if pending then
            local recent = pending.t and (GetTime() - pending.t) <= EMPOWER_STOP_WINDOW
            local matched = false
            local okM = pcall(function()
                if barID ~= nil and pending.bar ~= nil then
                    matched = (barID == pending.bar)      -- 优先 castBarID 精确配对
                else
                    matched = (spID == pending.spellID)
                end
            end)
            if recent and okM and matched then
                local cancelled = false
                local okC = pcall(function() cancelled = (complete == false) end)
                if okC and cancelled then
                    EmpowerRollback(pending, spID, barID)
                else
                    -- v1.36.31: **这才是开窗时机** —— `complete=true`(读不到时也按"已放出"处理) 才开窗,
                    --   与游戏的"心流 buff 上身时刻"对齐(窗口比原来晚约 1 秒, 修掉"边界少折一层")。
                    pcall(OnFlowWindowRefresh)
                end
                empowerPending = nil
            end
        end
        return
    end

    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded == AddonName then
            -- 加载配置
            if not DreamBreathStasisHelperDB then
                DreamBreathStasisHelperDB = {}
            end
            -- 合并默认值
            db = {}
            for k, v in pairs(defaults) do
                db[k] = (DreamBreathStasisHelperDB[k] ~= nil) and DreamBreathStasisHelperDB[k] or v
            end
            -- 创建UI
            CreateUI()
            -- 创建控制台面板 (延迟到加载后, 避免依赖未就绪)
            C_Timer.After(0.5, function()
                CreateConfigPanel()
            end)
            -- 启动 C_Timer 兜底刷新 (防止 OnUpdate 因任何原因不触发)
            StartFallbackTimer()
            print("|cFF7F77DD[绿喷管家]|r 已加载! 输入 /DBSH 打开控制台, /DBSH help 查看命令. 作者: 炸鱼奶龙")
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        RefreshFlowStateRank()  -- v1.32: 登录时识别心流状态天赋层数
        -- v1.32 功能二: 资格门槛检测 (延迟0.5s等天赋数据就绪; C_Timer不可用则直接调)
        if C_Timer and C_Timer.After then
            C_Timer.After(0.5, RefreshEligibility)
        else
            RefreshEligibility()
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        -- v1.32 功能二: 进世界时检测资格 (延迟0.5s等天赋数据就绪; C_Timer不可用则直接调)
        if C_Timer and C_Timer.After then
            C_Timer.After(0.5, RefreshEligibility)
        else
            RefreshEligibility()
        end
        return
    end

    if event == "PLAYER_REGEN_DISABLED" then
        -- 进战斗: 战斗数据即将被加密, 强制最后一次校准绿喷充能模型
        -- (用真实 API 数据, 确保进战斗后本地模型的起点是对的)
        local ok, info = pcall(function() return GetSpellChargeInfo(DREAM_BREATH_SPELL_ID) end)
        if ok and info and not info.secret then
            SyncChargeModel(info)
            Trace(string.format("进战斗校准绿喷: 层数=%s/%s", tostring(chargeModel.currentCharges), tostring(chargeModel.maxCharges)))
        else
            -- v1.22: 校准失败(API已加密), 兜底保证充能时钟有效,
            --   否则1层进战斗后绿喷涨层本地模型不跟上(卡"绿喷1/2")。
            if chargeModel.currentCharges ~= nil
               and chargeModel.currentCharges < chargeModel.maxCharges
               and not chargeModel.nextChargeAt then
                chargeModel.nextChargeAt = GetTime() + chargeModel.rechargeTotal
                Trace("进战斗校准失败(secret), 兜底: 绿喷充能时钟重设")
            end
        end
        if db then UpdateUI() end
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        -- 出战斗: API 可读, 校准绿喷充能模型
        local ok, info = pcall(function() return GetSpellChargeInfo(DREAM_BREATH_SPELL_ID) end)
        if ok and info and not info.secret then
            -- v1.32.11: 先记"对账"再校准 —— 这条流水反映战斗期间模型漂移了多少,
            --   是排查"CD 对不上"最直接的证据 (脱战瞬间: 模型 vs API 真值)
            local mC = chargeModel.currentCharges
            local mNext = 0
            if chargeModel.nextChargeAt and mC and mC < chargeModel.maxCharges then
                mNext = math.max(0, chargeModel.nextChargeAt - GetTime())
            end
            ChargeDiag(string.format("脱战对账: 模型%s层/%.1fs vs API%s层/%.1fs  差%+.0f层/%+.1fs",
                tostring(mC), mNext, tostring(info.currentCharges), info.nextChargeIn or 0,
                (mC or 0) - info.currentCharges, mNext - (info.nextChargeIn or 0)))
            SyncChargeModel(info)
            Trace(string.format("出战斗校准绿喷: 层数=%s/%s", tostring(chargeModel.currentCharges), tostring(chargeModel.maxCharges)))
        end
        -- v1.36.6: 静滞 CD 也趁机对齐官方剩余 (这是判断里的 T, 偏了就会红灯晚亮)
        SyncStasisCooldownFromAPI()
        if db then UpdateUI() end
        return
    end

    if event == "SPELL_UPDATE_COOLDOWN" then
        EngineInvalidate()  -- v1.33: 充能/CD 状态可能变化, 引擎句柄下帧重取
        -- 充能/CD 变化: 若 API 可读(出战斗), 趁机校准绿喷充能模型
        -- v1.36.14: 诊断采样期间**同样暂停绿喷校准** —— 否则 API 会实时把模型拉平,
        --   测出来的"差 0.00s"是校准的功劳, 不是模型算法准。2026-09-21 01:08 实测踩到:
        --   窗口开着时模型 Δ 仍显示 -1.0(理论上该 -1.1), 就是被这里持续覆盖的。
        if not probeSuspendSync then
            local ok, info = pcall(function() return GetSpellChargeInfo(DREAM_BREATH_SPELL_ID) end)
            if ok and info and not info.secret then
                SyncChargeModel(info)
            end
        end
        -- v1.36.6: 静滞 CD 同步对齐 (不可读时函数内部自己跳过)
        SyncStasisCooldownFromAPI()
        if db then UpdateUI() end
        return
    end

    if event == "UNIT_SPELLCAST_START" then
        -- v1.32 功能二: 资格不合格时不处理施法事件 (nil=未检测不拦, 避免登录初期丢事件)
        if eligibility.eligible == false then return end
        -- 探针用: 记录 STORING 阶段白名单技能的施法开始时刻 (不改状态机, 仅对比延迟)
        local unit, _, spellId = ...
        if unit ~= "player" then return end
        if stasisState.phase == "STORING" and spellId
           and STASIS_STORABLE_SPELLS[spellId] then
            -- 这是即将存入的技能, 若当前是第2个(即将存成第3个), 记录施法开始
            if (stasisState.storedCount or 0) == 2 then
                stasisState.thirdCastStartTime = GetTime()
            end
        end
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- v1.32 功能二: 资格不合格时不处理施法事件 (nil=未检测不拦, 避免登录初期丢事件)
        if eligibility.eligible == false then return end
        -- 静滞(施法事件驱动状态机) + 时空畸体(队列消费)
        local unit, _, spellId = ...
        if unit ~= "player" then return end
        if STASIS_IDS[spellId] then
            -- v1.11 关键修复: 静滞"释放"=再次按同一个 370537 按钮, 不是独立 370564
            -- 用状态区分: 已在 STORING/ARMED 状态再收到 370537 = 释放; 否则 = 激活
            if spellId == 370537 then
                if stasisState.phase == "STORING" or stasisState.phase == "ARMED" then
                    local okR, errR = pcall(OnStasisRelease)  -- 已激活, 再按 = 释放
                    if not okR then print("|cFF7F77DD[绿喷管家]|r 静滞释放处理错误: " .. tostring(errR)) end
                else
                    local okS, errS = pcall(OnStasisStore)    -- 否则 = 激活存spell
                    if not okS then print("|cFF7F77DD[绿喷管家]|r 静滞激活处理错误: " .. tostring(errS)) end
                end
            elseif spellId == 370564 then
                -- 兜底: 万一某些版本真的发 370564, 仍按释放处理
                local okR, errR = pcall(OnStasisRelease)
                if not okR then print("|cFF7F77DD[绿喷管家]|r 静滞释放处理错误: " .. tostring(errR)) end
            end
        elseif spellId == TEMPORAL_ANOMALY_SPELL_ID then
            -- 时空畸体施放 -> 消费队列里的时空畸体(FIFO)
            ConsumeQueueItem("TEMPORAL_ANOMALY")
            -- v1.20: 静滞释放后2秒内收到的溜溜球, 是"释放重施放"的, 已在OnStasisRelease补算,
            --   这里跳过减CD避免重复。其余情况(主动施放)正常减。
            local justReleased = (stasisState.stasisReleaseTime or 0) > 0
                                 and (GetTime() - stasisState.stasisReleaseTime) < 2.0
            if not justReleased then
                TemporalAnomalyReduceCD()
            else
                -- v1.32.10 诊断: 把"被跳过的重放"也留痕, 方便核对减CD次数有没有重复
                ChargeDiag(string.format("溜溜球(静滞重放, 释后%.1fs): 跳过减CD(已补算)",
                    GetTime() - stasisState.stasisReleaseTime))
            end
            -- v1.20: 若在 STORING 阶段, 记录存入的溜溜球数 (释放时补算减CD)
            if stasisState.phase == "STORING" then
                stasisState.storedTemporalAnomalies = (stasisState.storedTemporalAnomalies or 0) + 1
            end
        end

        -- v1.32: 蓄力技能统一判断一次 (绿喷/红喷), 供下面心流移位用
        local isEmpowerCast = spellId and EMPOWER_SPELL_IDS[spellId]

        -- v1.36.2: 蓄力技能先存一份状态快照 —— 随后若收到 EMPOWER_STOP(complete=false)
        --   说明这次蓄力被取消, 把下面乐观扣掉的东西原样回滚 (见 EmpowerRollback)
        if isEmpowerCast then
            empowerPending = {
                spellID = spellId,
                bar     = lastEmpowerBar,
                t       = GetTime(),
                snap    = EmpowerSnapshot(),
            }
        end

        -- v1.36.31 🔴 **开窗时机修正: 从"按下蓄力"(SUCCEEDED) 延后到"释放确认"(EMPOWER_STOP complete=true)** ——
        --   原因(2026-09-21 02:26 老板实测): 心流 buff 是**蓄力完成**才给的, 而我们在**按下那一刻**就开窗
        --   → 窗口比真实 buff **早约 1 秒**。后果不止"早 1 秒": 在"窗口刚好过期"的边界上,
        --   游戏认为窗口还开着(新层按 27.27 折), 我们的窗口已关 → **少折一层 → 模型偏慢 2.7s**。
        --   铁证: `脱战对账 模型1层/20.0s vs API1层/17.4s 差+2.6s` —— 20.0=起算30, 17.4≈起算27.27。
        --   顺带好处: 取消蓄力(complete=false)时**不会再误开窗**(以前要先开窗再回滚, 采样会抓到中间态)。
        --   兜底: STOP 万一没到(START 时发现上一个 pending 超时), 在 START 分支补开窗(见下)。
        --   ⚠️ 这里**只保留"补算 rank"** —— 扣层(OnDreamBreathCast)仍要用 rank 才能算折算。
        if isEmpowerCast then
            -- v1.32.5 兜底: 登录/进世界时天赋数据常常还没就绪, RefreshFlowStateRank 会读到 0,
            --   导致心流整场静默失效 (表现: 游戏里绿喷已被加速, 插件却按原速倒计时 -> "CD 对不上")。
            --   这里在首次蓄力技能时补算一次 (限流 3s, 避免高频重算)。
            if (flowState.rank or 0) <= 0 then
                local nowR = GetTime()
                if nowR - (flowRankRetryAt or 0) > 3 then
                    flowRankRetryAt = nowR
                    RefreshFlowStateRank()
                end
            end
            -- v1.36.31: 开窗**已移除** (改到 EMPOWER_STOP 分支)。这里不再调 OnFlowWindowRefresh。
        end

        -- v1.29: 绿喷施放检测移到 SUCCEEDED (原在 EMPOWER_STOP, 但12.1战斗中 EMPOWER_STOP
        --   参数被加密只透出 unit, spellId=complete=nil, 导致绿喷计数/扣层/队列消费全失效)
        -- v1.36.31: 扣层仍在 SUCCEEDED(乐观记账, 保证层数显示实时); 但**心流窗口不再在这里开**
        --   (延后到 EMPOWER_STOP 的"释放确认")。效果 = 连续施放时用上一轮窗口折、隔久了则等 STOP 开窗后折剩余,
        --   两条路都与游戏"按起算时的真实 rate"等价。
        if DREAM_BREATH_IDS[spellId] then
            OnDreamBreathCast(spellId)
            ConsumeQueueItem("DREAM_BREATH")
        end

        -- v1.15 核心: STORING 阶段数白名单治疗技能, 存满3个 -> ARMED (进90s CD)
        -- 这是检测"静滞存满"的唯一可靠做法 (aura/CD数值战斗中全加密, 现成插件也这么干)
        -- v1.29: 去掉 not STASIS_EMPOWER_SPELLS 排除——绿喷等 empowered 技能战斗中
        --   EMPOWER_STOP 参数被加密计数不到, 统一改在 SUCCEEDED 里数 (SUCCEEDED 战斗中透出 spellId)
        if stasisState.phase == "STORING" and spellId
           and STASIS_STORABLE_SPELLS[spellId] then
            stasisState.storedCount = (stasisState.storedCount or 0) + 1
            AddStoredSpellIcon(spellId)  -- v1.34: 实时填进"已存技能"大图标槽位
            if stasisState.storedCount == 3 then
                -- v1.25: 瞬发技能(活化烈焰/回响/逆转/焚身等)不触发 UNIT_SPELLCAST_START,
                --   thirdCastStartTime 会是 0(或已重置), 这里用当前时刻兜底锚定CD起算点
                if not stasisState.thirdCastStartTime or stasisState.thirdCastStartTime <= 0 then
                    stasisState.thirdCastStartTime = GetTime()
                end
            end
            Trace(string.format("静滞存入技能 %s, 已存%d/3", tostring(spellId), stasisState.storedCount))
        end

        -- v1.35.0: 释放重放检测(v1.34.7/v1.34.8)已移除 —— 实机验证宏 cancelaura 释放后
        --   1.5s/5s 两种窗口都测不出稳定的重放事件流, 老板拍板不再追查, 统一靠
        --   ARMED 的 30s 超时清理存储排 (见 UpdateStasisState)。
        -- 不 return: 让 OnUpdate 接管刷新
        return
    end

    -- v1.35.0: UNIT_SPELLCAST_EMPOWER_STOP 监听已移除 —— 12.1 战斗中该事件参数被加密
    --   (只透出 unit), 绿喷计数/扣层/队列消费早已迁移到 UNIT_SPELLCAST_SUCCEEDED。
    --   保留监听却什么都不做纯属负担, 直接注销。

    -- v1.32.3: 学/忘法术(天赋赋予的技能如静滞被换掉时触发) -> 只重检资格, 不重算心流
    if event == "SPELLS_CHANGED" then
        if db then RefreshEligibilityDebounced() end
        return
    end

    -- v1.32: 天赋/专精变化 -> 重算心流状态层数缓存, 再走原有刷新
    if event == "PLAYER_TALENT_UPDATE"
       or event == "CHARACTER_POINTS_CHANGED"
       or event == "PLAYER_SPECIALIZATION_CHANGED"
       or event == "TRAIT_CONFIG_UPDATED"             -- v1.32.3: 天赋界面内增删天赋点
       or event == "ACTIVE_TALENT_GROUP_CHANGED" then -- v1.32.3: 切换天赋方案
        -- v1.32.3: 改防抖重检(0.4s), 等天赋数据落地, 避免连续事件下误判/UI闪烁
        RefreshEligibilityDebounced()
        RefreshFlowStateRank()
        if db then UpdateUI() end
        return
    end

    -- 其余事件触发刷新
    if db then UpdateUI() end
end)

--==========================================================================
-- 命令系统
--==========================================================================

local function SaveDB()
    for k, v in pairs(db) do
        DreamBreathStasisHelperDB[k] = v
    end
end

local function PrintHelp()
    print("|cFF7F77DD==== 绿喷管家 命令 ====")
    print("|cFF7F77DD/DBSH|r 或 |cFF7F77DD/绿喷管家|r  - 打开控制台(开关/缩放/透明度)")
    print("|cFF7F77DD/DBSH help|r      - 显示此帮助")
    print("|cFF7F77DD/DBSH lock|r     - 锁定UI(不可拖动)")
    print("|cFF7F77DD/DBSH unlock|r   - 解锁UI(可拖动)")
    print("|cFF7F77DD/DBSH toggle|r   - 显示/隐藏主UI")
    print("|cFF7F77DD/DBSH scale 1.0|r- 设置缩放(0.5-2.0)")
    print("|cFF7F77DD/DBSH reset|r    - 重置位置")
    print("|cFF7F77DD/DBSH recharge 30|r - 手动设置绿喷充能总时间(秒, 0=自动)")
    print("|cFF7F77DD/DBSH flow|r     - 心流状态天赋调试(层数/spellID/冷却倒计时状态)")
    print("|cFF7F77DD/DBSH charge|r   - 绿喷充能诊断(**脱战后敲**: API真值 vs 本地模型 + 【对账】差异 + 事件流水)")
    print("|cFF7F77DD/DBSH secret|r   - secret 字段探测(战斗中能读到什么: type/tostring/去密, 一次给结论)")
    print("|cFF7F77DD/DBSH talents|r  - 天赋树探针(API链路/各树节点/已点天赋名+spellID, 排查识别失败)")
    print("|cFF7F77DD/DBSH cast|r     - 蓄力施法事件探针(查蓄力取消是否被误算成释放; 含当前版本号)")
    print("|cFF7F77DD/DBSH track|r    - 长时程精度追踪(仅脱战段有效, 战斗中信号读不到)")
    print("|cFF7F77DD/DBSH next|r     - 一行式模型值(战斗中随时敲, 与游戏技能栏人工对比)")
    print("|cFF7F77DD/DBSH time|r     - 充能计时对账(**脱战+充能中**敲: 引擎剩余 vs 模型剩余, 连续采样给误差)")
    print("|cFF7F77DD/DBSH status|r   - 资格门槛检测状态(职业/专精/英雄天赋/静滞)")
    print("|cFF7F77DD别名|r: /DBSH  /绿喷管家  全部通用")
end

SLASH_DBSH1 = "/DBSH"
SLASH_DBSH2 = "/绿喷管家"

--==========================================================================
-- 控制台面板 (设置: UI开关 / 缩放 / 透明度)
-- 手画控件, 不用 InterfaceOptions* 标准模板 (坑#2: 标准模板会触发权限弹窗)
--==========================================================================
local configFrame
local configToggleBtn, configToggleText
local configLockBtn, configLockText
local configScaleThumb, configScaleBar, configScaleLabel, configScaleHit
local configAlphaThumb, configAlphaBar, configAlphaLabel, configAlphaHit
local configDragging = nil  -- nil / "scale" / "alpha"

-- 刷新控制台各控件显示 (同步 db 值)
-- 注: 用赋值式而非 local function —— 前面资格检测段已前向声明了它 (同 GetTalentRankByName)
RefreshConfigPanel = function()
    if not configFrame then return end
    -- UI 开关按钮文字 (v1.32.3 三态, 与主UI真实可见性保持一致)
    if configToggleText then
        local st = GetUIStatus()
        if st == "closed" then
            configToggleText:SetText("UI: 已关闭")
            configToggleText:SetTextColor(0.8, 0.8, 0.8)
        elseif st == "blocked" then
            configToggleText:SetText("UI: 未启用(资格不符)")
            configToggleText:SetTextColor(0.95, 0.72, 0.2)
        else
            configToggleText:SetText(forceEnabled and "UI: 显示中(手动)" or "UI: 显示中")
            configToggleText:SetTextColor(0.22, 0.78, 0.33)
        end
    end
    -- 锁定按钮文字
    if configLockText then
        configLockText:SetText(db.locked and "UI: 已锁定" or "UI: 可拖动")
        configLockText:SetTextColor(db.locked and 0.8 or 0.22,
                                    db.locked and 0.8 or 0.78,
                                    db.locked and 0.8 or 0.33)
    end
    -- 缩放滑块位置 + 文字
    if configScaleThumb and configScaleHit then
        local w = configScaleHit:GetWidth()
        local ratio = (db.scale - 0.5) / 1.5  -- 0.5~2.0 -> 0~1
        configScaleThumb:SetPoint("LEFT", configScaleHit, "LEFT", w * ratio, 0)
        if configScaleLabel then
            configScaleLabel:SetText(string.format("缩放 %.2f", db.scale))
        end
    end
    -- 透明度滑块位置 + 文字
    if configAlphaThumb and configAlphaHit then
        local w = configAlphaHit:GetWidth()
        local ratio = (db.alpha - 0.1) / 0.9  -- 0.1~1.0 -> 0~1
        configAlphaThumb:SetPoint("LEFT", configAlphaHit, "LEFT", w * ratio, 0)
        if configAlphaLabel then
            configAlphaLabel:SetText(string.format("透明度 %.0f%%", db.alpha * 100))
        end
    end
end

-- 应用透明度到整个主UI (背景 + logo + 文字一起, 用 SetAlpha 而非只调背景)
local function ApplyAlpha()
    if not frame then return end
    frame:SetAlpha(db.alpha or 0.82)
end

-- 手画滑块: 返回 bar(轨道纹理) 和 thumb(把手) 和 hit(可点击/拖动的frame); dragTag 标记拖动的是哪个滑块
-- 注意: bar 是 Texture(无 GetLeft), 只有 hit 是 Frame(有 GetLeft/GetWidth), 拖动计算必须用 hit
local function CreateSlider(parent, yOffset, minVal, maxVal, dragTag)
    local bar = parent:CreateTexture(nil, "ARTWORK")
    bar:SetTexture("Interface\\Buttons\\WHITE8x8")
    bar:SetVertexColor(0.4, 0.4, 0.45, 1)
    bar:SetSize(150, 6)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 70, yOffset)

    -- 可点击的隐形 frame 覆盖轨道 (宽度=轨道, 用于拖动 + 计算位置)
    local hit = CreateFrame("Frame", nil, parent)
    hit:SetSize(150, 26)
    hit:SetPoint("CENTER", bar, "CENTER", 0, 0)
    hit:EnableMouse(true)

    local thumb = parent:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture("Interface\\Buttons\\WHITE8x8")
    thumb:SetVertexColor(0.22, 0.78, 0.33, 1)
    thumb:SetSize(14, 18)
    thumb:SetPoint("CENTER", hit, "LEFT", 0, 0)

    hit:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            configDragging = dragTag
        end
    end)
    hit:SetScript("OnMouseUp", function()
        configDragging = nil
        SaveDB()
    end)
    return bar, thumb, hit
end

-- 计算某个滑块当前鼠标位置对应的 ratio (0~1)
-- 参数必须是 Frame(有 GetLeft), 不能传 Texture(GetLeft 为 nil, 会报错)
local function SliderRatio(hitFrame)
    if not hitFrame or not hitFrame:GetLeft() or not hitFrame:GetWidth() or hitFrame:GetWidth() <= 0 then
        return nil
    end
    local x = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    if not s or s <= 0 then return nil end
    local r = (x / s - hitFrame:GetLeft()) / hitFrame:GetWidth()
    if r < 0 then r = 0 end
    if r > 1 then r = 1 end
    return r
end

CreateConfigPanel = function()
    if configFrame then return end
    configFrame = CreateFrame("Frame", "DreamBreathStasisHelperConfigFrame", UIParent, "BackdropTemplate")
    configFrame:SetSize(240, 220)
    configFrame:SetPoint("CENTER")
    configFrame:SetClampedToScreen(true)
    configFrame:EnableMouse(true)
    configFrame:SetMovable(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    configFrame:SetBackdropColor(0.06, 0.06, 0.09, 0.95)
    configFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    configFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    configFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    configFrame:Hide()

    -- 标题
    local title = configFrame:CreateFontString(nil, "OVERLAY")
    title:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
    title:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 12, -10)
    title:SetText("绿喷管家 设置")
    title:SetTextColor(1, 1, 1)

    -- 关闭按钮
    local closeBtn = CreateFrame("Button", nil, configFrame)
    closeBtn:SetSize(18, 18)
    closeBtn:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -6, -6)
    closeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    closeBtn:SetScript("OnClick", function() configFrame:Hide() end)

    -- 1. UI 开关按钮 (手画, 不用标准模板)
    configToggleBtn = CreateFrame("Button", nil, configFrame, "BackdropTemplate")
    configToggleBtn:SetSize(180, 26)
    configToggleBtn:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 14, -38)
    configToggleBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    configToggleBtn:SetBackdropColor(0.15, 0.15, 0.18, 1)
    configToggleBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    configToggleText = configToggleBtn:CreateFontString(nil, "OVERLAY")
    configToggleText:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
    configToggleText:SetPoint("CENTER", configToggleBtn, "CENTER", 0, 0)
    configToggleText:SetText("UI: 显示中")
    configToggleBtn:SetScript("OnClick", function()
        -- v1.32.3 三态点击: 已关闭->打开 / 资格不符->手动强制启用 / 显示中->关闭
        local st = GetUIStatus()
        if st == "closed" then
            db.enabled = true
            if frame then frame:Show() end
        elseif st == "blocked" then
            -- 手动强制启用: 覆盖资格自动禁用
            -- (仅本次会话有效, 资格恢复合格后自动清零回归托管)
            forceEnabled = true
            if frame then frame:Show() end
            print("|cFF7F77DD[绿喷管家]|r 已手动强制显示 (资格检测仍为不合格; 换合格角色或点回静滞天赋后自动回归托管)")
        else
            db.enabled = false
            forceEnabled = false
            if frame then frame:Hide() end
        end
        RefreshConfigPanel()
        SaveDB()
    end)

    -- 2. 锁定/解锁按钮 (等价 /DBSH lock / unlock, 免记命令)
    configLockBtn = CreateFrame("Button", nil, configFrame, "BackdropTemplate")
    configLockBtn:SetSize(180, 26)
    configLockBtn:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 14, -68)
    configLockBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    configLockBtn:SetBackdropColor(0.15, 0.15, 0.18, 1)
    configLockBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    configLockText = configLockBtn:CreateFontString(nil, "OVERLAY")
    configLockText:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
    configLockText:SetPoint("CENTER", configLockBtn, "CENTER", 0, 0)
    configLockText:SetText("UI: 可拖动")
    configLockBtn:SetScript("OnClick", function()
        db.locked = not db.locked
        RefreshConfigPanel()
        SaveDB()
    end)

    -- 3. 缩放滑块
    local scaleTitle = configFrame:CreateFontString(nil, "OVERLAY")
    scaleTitle:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    scaleTitle:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 14, -108)
    scaleTitle:SetText("大小")
    scaleTitle:SetTextColor(0.8, 0.8, 0.8)
    configScaleLabel = configFrame:CreateFontString(nil, "OVERLAY")
    configScaleLabel:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    configScaleLabel:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -14, -108)
    configScaleLabel:SetText("缩放 1.00")
    configScaleLabel:SetTextColor(0.8, 0.8, 0.8)
    configScaleBar, configScaleThumb, configScaleHit = CreateSlider(configFrame, -108, 0.5, 2.0, "scale")

    -- 4. 透明度滑块
    local alphaTitle = configFrame:CreateFontString(nil, "OVERLAY")
    alphaTitle:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    alphaTitle:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 14, -158)
    alphaTitle:SetText("透明度")
    alphaTitle:SetTextColor(0.8, 0.8, 0.8)
    configAlphaLabel = configFrame:CreateFontString(nil, "OVERLAY")
    configAlphaLabel:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    configAlphaLabel:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -14, -158)
    configAlphaLabel:SetText("透明度 82%")
    configAlphaLabel:SetTextColor(0.8, 0.8, 0.8)
    configAlphaBar, configAlphaThumb, configAlphaHit = CreateSlider(configFrame, -158, 0.1, 1.0, "alpha")

    RefreshConfigPanel()
end

-- 控制台拖动更新 (OnUpdate 里每帧处理滑块拖动)
UpdateConfigDrag = function()
    if not configDragging or not configFrame or not configFrame:IsShown() then
        return
    end
    -- 兜底: 鼠标左键已松开但 OnMouseUp 没触发(移出 hit 区域松手)时, 结束拖动并保存
    if not IsMouseButtonDown("LeftButton") then
        configDragging = nil
        SaveDB()
        return
    end
    if configDragging == "scale" then
        local r = SliderRatio(configScaleHit)
        if r then
            db.scale = 0.5 + r * 1.5
            if frame then frame:SetScale(db.scale) end
            RefreshConfigPanel()
        end
    elseif configDragging == "alpha" then
        local r = SliderRatio(configAlphaHit)
        if r then
            db.alpha = 0.1 + r * 0.9
            ApplyAlpha()
            RefreshConfigPanel()
        end
    end
end

SlashCmdList["DBSH"] = function(msg)
    if not db then
        print("|cFF7F77DD[绿喷管家]|r 插件尚未加载完成")
        return
    end
    local args = {}
    for word in string.gmatch(msg or "", "%S+") do
        table.insert(args, string.lower(word))
    end
    local cmd = args[1] or "config"

    if cmd == "help" then
        PrintHelp()
    elseif cmd == "config" or cmd == "设置" or cmd == "set" then
        -- 打开控制台面板
        CreateConfigPanel()
        RefreshConfigPanel()
        configFrame:Show()
    elseif cmd == "lock" then
        db.locked = true
        SaveDB()
        print("|cFF7F77DD[绿喷管家]|r UI已锁定")
    elseif cmd == "unlock" then
        db.locked = false
        SaveDB()
        print("|cFF7F77DD[绿喷管家]|r UI已解锁, 可拖动. 输入 /DBSH lock 锁定")
    elseif cmd == "scale" then
        local s = tonumber(args[2] or "")
        if s and s >= 0.5 and s <= 2.0 then
            db.scale = s
            frame:SetScale(s)
            SaveDB()
            print("|cFF7F77DD[绿喷管家]|r 缩放设为 " .. s)
        else
            print("|cFF7F77DD[绿喷管家]|r 用法: /DBSH scale 1.0 (范围 0.5-2.0)")
        end
    elseif cmd == "reset" then
        db.point = defaults.point
        db.relPoint = defaults.relPoint
        db.x = defaults.x
        db.y = defaults.y
        db.scale = defaults.scale
        frame:ClearAllPoints()
        frame:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
        frame:SetScale(db.scale)
        SaveDB()
        print("|cFF7F77DD[绿喷管家]|r 位置已重置")
    elseif cmd == "toggle" then
        -- v1.32.3 三态, 与控制台按钮行为一致
        local st = GetUIStatus()
        if st == "closed" then
            db.enabled = true
            if frame then frame:Show() end
        elseif st == "blocked" then
            -- 资格不符时手动强制启用 (仅本次会话)
            forceEnabled = true
            if frame then frame:Show() end
        else
            db.enabled = false
            forceEnabled = false
            if frame then frame:Hide() end
        end
        RefreshConfigPanel()
        SaveDB()
        local st2 = GetUIStatus()
        print("|cFF7F77DD[绿喷管家]|r 当前状态: "
              .. (st2 == "shown" and (forceEnabled and "已显示(手动强制)" or "已显示")
                  or (st2 == "blocked" and "未启用(资格不符)" or "已隐藏")))
    elseif cmd == "recharge" then
        local v = tonumber(args[2] or "")
        if v and v >= 0 then
            db.customRecharge = (v > 0) and v or nil
            SaveDB()
            print("|cFF7F77DD[绿喷管家]|r 绿喷充能时间: " .. (db.customRecharge and (db.customRecharge.."秒(手动)") or "自动"))
        else
            print("|cFF7F77DD[绿喷管家]|r 用法: /DBSH recharge 30 (0=自动)")
        end
    elseif cmd == "talents" then
        -- v1.32.6 诊断: 打印天赋树遍历全链路 (定位"心流识别不到"到底断在哪一环)
        print("|cFF7F77DD[绿喷管家]|r 天赋树探针:")
        local function h(t) return t and "ok" or "nil" end
        print(string.format("  API: C_ClassTalents=%s C_Traits=%s GetTreeNodes=%s GetNodeInfo=%s GetEntryInfo=%s GetDefInfo=%s GetSpellName=%s",
            h(C_ClassTalents), h(C_Traits),
            h(C_Traits and C_Traits.GetTreeNodes), h(C_Traits and C_Traits.GetNodeInfo),
            h(C_Traits and C_Traits.GetEntryInfo), h(C_Traits and C_Traits.GetDefinitionInfo),
            h(C_Spell and C_Spell.GetSpellName)))
        local okP, errP = pcall(function()
            if not (C_ClassTalents and C_Traits) then
                print("  (C_ClassTalents 或 C_Traits 缺失, 无法继续)")
                return
            end
            local configID = C_ClassTalents.GetActiveConfigID()
            print("  configID=" .. tostring(configID))
            if not configID then return end
            local configInfo = C_Traits.GetConfigInfo(configID)
            local treeIDs = configInfo and configInfo.treeIDs
            print("  configInfo: name=" .. tostring(configInfo and configInfo.name)
                  .. " type=" .. tostring(configInfo and configInfo.type)
                  .. " ID=" .. tostring(configInfo and configInfo.ID))
            local idList = {}
            if treeIDs then
                for _, v in ipairs(treeIDs) do idList[#idList + 1] = tostring(v) end
            end
            print("  treeIDs=" .. tostring(treeIDs and #treeIDs or "nil") .. " [" .. table.concat(idList, ",") .. "]")
            if not treeIDs then return end
            local KEYWORDS = { "心流", "Flow", "静滞", "Stasis", "心灵之火", "Inner Fire", "塑焰", "Flameshaper", "梦境吐息", "Dream Breath" }
            local hits, allNodes = {}, {}
            local flowHit, nameFail = nil, 0
            for _, treeID in ipairs(treeIDs) do
                local tname, nodeCount, activeCount = "?", 0, 0
                -- GetTreeInfo(configID, treeID): TraitTreeInfo 里没有 name, 12.x 用 titleText
                local ti = TraitsCall(C_Traits.GetTreeInfo, configID, treeID)
                if ti then
                    tname = tostring(ti.name or ti.titleText or "?")
                    print("    treeInfo(" .. tostring(treeID) .. "): ID=" .. tostring(ti.ID)
                          .. " titleText=" .. tostring(ti.titleText)
                          .. " rootNodeID=" .. tostring(ti.rootNodeID)
                          .. " uiTextureKit=" .. tostring(ti.uiTextureKit))
                else
                    print("    treeInfo(" .. tostring(treeID) .. "): nil")
                end
                -- v1.32.8: GetTreeNodes 只吃 (treeID), 必须走 TraitsCall1
                local nodes = TraitsCall1(C_Traits.GetTreeNodes, treeID)
                if nodes then
                    nodeCount = #nodes
                    for _, nodeID in ipairs(nodes) do
                        local ni = TraitsCall(C_Traits.GetNodeInfo, configID, nodeID)
                        if ni and (ni.activeRank or 0) > 0 then
                            activeCount = activeCount + 1
                            local sname, sid, idDef, idEntry, defID, dfields = "?", nil, nil, nil, nil, ""
                            if ni.entryIDs then
                                for _, eid in ipairs(ni.entryIDs) do
                                    local ei = TraitsCall(C_Traits.GetEntryInfo, configID, eid)
                                    if ei then
                                        defID   = defID or ei.definitionID
                                        idEntry = idEntry or ei.spellID
                                        local di = ei.definitionID and TraitsCall1(C_Traits.GetDefinitionInfo, ei.definitionID)
                                        if di then
                                            idDef = idDef or di.spellID
                                            sid = sid or di.spellID or ei.spellID
                                            if dfields == "" then
                                                local p = {}
                                                for k, v in pairs(di) do
                                                    if type(v) ~= "table" and #p < 6 then
                                                        p[#p + 1] = tostring(k) .. "=" .. tostring(v)
                                                    end
                                                end
                                                dfields = table.concat(p, ",")
                                            end
                                        else
                                            sid = sid or ei.spellID
                                        end
                                    end
                                end
                            end
                            if sid and C_Spell and C_Spell.GetSpellName then
                                sname = tostring(C_Spell.GetSpellName(sid) or "?")
                            end
                            -- v1.32.7: 把 ID 链每一环都打出来 (面板 SpellID 到底挂在哪一环)
                            local line = string.format("[%s] node=%s rank=%s | idDef=%s idEntry=%s defID=%s | name=%s",
                                tname, tostring(nodeID), tostring(ni.activeRank),
                                tostring(idDef), tostring(idEntry), tostring(defID), sname)
                            allNodes[#allNodes + 1] = line
                            -- 反查心流状态(385696): 任意一环出现该 ID 都算命中
                            if idDef == FLOW_STATE_ID or idEntry == FLOW_STATE_ID or sid == FLOW_STATE_ID then
                                flowHit = line
                            end
                            for _, kw in ipairs(KEYWORDS) do
                                if sname:find(kw, 1, true) then
                                    hits[#hits + 1] = line .. "  | def: " .. dfields
                                    break
                                end
                            end
                        end
                    end
                end
                print(string.format("  tree %s: name=%s nodes=%s active=%s",
                    tostring(treeID), tname, tostring(nodeCount), tostring(activeCount)))
            end
            print("  --- 反查心流状态 SpellID " .. tostring(FLOW_STATE_ID) .. " ---")
            if flowHit then
                print("  找到: " .. flowHit)
            else
                print("  没找到 (无节点的 idDef/idEntry/spellID 命中 " .. tostring(FLOW_STATE_ID) .. ")")
            end
            print("  --- 命中关键词的已点节点 (" .. tostring(#hits) .. ") ---")
            for _, l in ipairs(hits) do print("  " .. l) end
            print("  --- 全部已点节点 (" .. tostring(#allNodes) .. "), 其中名字取不到 " .. tostring(nameFail) .. " 个 ---")
            for _, l in ipairs(allNodes) do print("  " .. l) end
        end)
        if not okP then print("|cFFFF0000[绿喷管家]|r 探针异常: " .. tostring(errP)) end
    elseif cmd == "next" then
        -- v1.36.22: 一行式"模型值" —— 战斗/脱战都能敲, 用来跟**游戏技能栏**做人工对比。
        --   为什么需要: 战斗中引擎真值全是 secret, 插件读不到"系统值";
        --   但**游戏技能栏上的倒计时是肉眼可见的** → "模型值 vs 技能栏"是战斗中唯一可行的验证手段。
        local nowN = GetTime()
        local chTxt
        if chargeModel.currentCharges and chargeModel.nextChargeAt
           and chargeModel.currentCharges < (chargeModel.maxCharges or 2) then
            chTxt = string.format("%.1fs", math.max(0, chargeModel.nextChargeAt - nowN))
        else
            chTxt = "已满/无充能"
        end
        local stTxt
        if (stasisState.phase == "ARMED" or stasisState.phase == "COOLDOWN")
           and (stasisState.cooldownEndTime or 0) > nowN then
            stTxt = string.format("%.1fs", stasisState.cooldownEndTime - nowN)
        else
            stTxt = "不在CD(" .. tostring(stasisState.phase) .. ")"
        end
        print(string.format("|cFF7F77DD[绿喷管家]|r 模型值: 绿喷下一层 |cFFFFFF00%s|r | 静滞CD |cFFFFFF00%s|r | 层 %s/%s | 心流 %s",
            chTxt, stTxt, tostring(chargeModel.currentCharges), tostring(chargeModel.maxCharges),
            ((flowState.rank or 0) > 0 and flowUntil > nowN)
                and (tostring(flowState.rank) .. "层/窗口开") or "窗口关"))
        print("  (对照: ① 游戏技能栏倒计时; ② 插件右上角'静滞CD Xs'=引擎真值渲染, 与上面模型值的差就是模型误差)")
        -- v1.36.30: 附最近 3 条记账流水 —— **纯本地记录, 战斗中照常可用**。
        --   这样一条命令就能同时看到"模型值"和"折算/回滚有没有真的发生"(不用再敲 /DBSH charge)。
        --   战斗中这是验证"折算机制在战斗里生效"最直接的证据(引擎/API 值读不到, 但流水读得到)。
        local ev = chargeDiag.events
        local n = #ev
        if n > 0 then
            print("  --- 最近记账 (本地记录, 战斗中也能看) ---")
            for i = math.max(1, n - 2), n do
                print("    " .. tostring(ev[i]))
            end
        end
    elseif cmd == "track" then
        -- v1.36.19: 长时程追踪 (战斗+脱战) —— 用"布尔翻转的真实时刻"当锚点, 战斗中也能量化误差
        if not trackOn then
            TrackReset()
            trackOn = true
            trackStart = GetTime()
            print("|cFF7F77DD[绿喷管家]|r 长时程追踪已开始 —— 去打吧")
            print("  建议: 进战斗打 45s -> 脱战再打 45s, 中间不定期放红喷/绿喷续心流")
            print("  再敲一次 |cFF7F77DD/DBSH track|r 结束并输出结果")
        else
            trackOn = false
            local dur = GetTime() - trackStart
            print(string.format("|cFF7F77DD[绿喷管家]|r 长时程追踪结果 (共 %.1fs, %d 个锚点)", dur, #trackLog))
            if #trackLog == 0 then
                print("  没捕捉到任何锚点 —— 检查: 绿喷有没有满过 2 层? 静滞有没有转完一轮 CD?")
            end
            print("  --- 明细 (差 = 模型预测时刻 - 真实时刻; 正=模型偏慢, 负=模型偏快[危险]) ---")
            local sumC, nC, sumS, nS = 0, 0, 0, 0
            local mnC, mxC, mnS, mxS = nil, nil, nil, nil
            for _, e in ipairs(trackLog) do
                print(string.format("    [%6.1fs] %-10s 引擎 t=%6.1f  模型预测 t=%6.1f  差 %+5.2fs   %s|心流%s",
                    e.at - trackStart, e.kind, e.at, e.pred, e.diff,
                    e.combat and "战斗" or "脱战", e.flow and "开" or "关"))
                if e.kind == "绿喷满层" then
                    nC = nC + 1; sumC = sumC + e.diff
                    if mnC == nil or e.diff < mnC then mnC = e.diff end
                    if mxC == nil or e.diff > mxC then mxC = e.diff end
                else
                    nS = nS + 1; sumS = sumS + e.diff
                    if mnS == nil or e.diff < mnS then mnS = e.diff end
                    if mxS == nil or e.diff > mxS then mxS = e.diff end
                end
            end
            local function trackLine(tag, n, sum, mn, mx)
                if n > 0 then
                    print(string.format("  --- %s: %d 次 | 平均 %+.2fs | 范围 %+.2f ~ %+.2f", tag, n, sum / n, mn, mx))
                else
                    print(string.format("  --- %s: 0 次(没捕捉到)", tag))
                end
            end
            trackLine("绿喷满层", nC, sumC, mnC, mxC)
            trackLine("静滞CD好", nS, sumS, mnS, mxS)
            -- v1.36.21: 信号可读性 —— 直接回答"为什么没锚点"(是没发生, 还是信号读不到?)
            print("  --- 信号可读性 (帧计数) ---")
            print(string.format("    绿喷 isActive:  战斗[可读 %d / 读不到 %d]   脱战[可读 %d / 读不到 %d]",
                trackStat.chCO, trackStat.chCN, trackStat.chPO, trackStat.chPN))
            print(string.format("    静滞 IsUsable:  战斗[可读 %d / 读不到 %d]   脱战[可读 %d / 读不到 %d]",
                trackStat.suCO, trackStat.suCN, trackStat.suPO, trackStat.suPN))
            local ph = {}
            for k, v in pairs(trackStat.phase or {}) do ph[#ph + 1] = string.format("%s=%d", tostring(k), v) end
            print("    静滞 phase 分布: " .. ((#ph > 0) and table.concat(ph, "  ") or "无"))
            print("  判读: |差|<=1s 准 / 1~2s 可接受 / >3s 漂了; 重点看带'战斗'的行(那才是模型自己算的)")
        end
    elseif cmd == "flow" then
        -- v1.32: 心流状态调试 (强制重算一次再显示)
        RefreshFlowStateRank()
        local chargeActive = (chargeModel.currentCharges ~= nil and chargeModel.nextChargeAt ~= nil)
        local stasisActive = false
        pcall(function()
            stasisActive = (stasisState.phase == "ARMED" or stasisState.phase == "COOLDOWN")
                           and stasisState.cooldownEndTime ~= nil
                           and stasisState.cooldownEndTime > GetTime()
        end)
        print("|cFF7F77DD[绿喷管家]|r 心流状态层数: " .. tostring(flowState.rank) .. " (0/1/2)")
        print("|cFF7F77DD[绿喷管家]|r 天赋spellID: " .. (flowState.spellID and tostring(flowState.spellID) or "未识别"))
        -- v1.32.5: 窗口剩余 + 加速率 (判断"此刻是否真的在加速")
        local okW1, errW1 = pcall(function()
            local nowT = GetTime()
            local winLeft = (flowUntil > nowT) and (flowUntil - nowT) or 0
            print(string.format("|cFF7F77DD[绿喷管家]|r 心流窗口剩余: %.1fs (加速 %.0f%%)",
                winLeft, FLOW_RATE_PER_RANK * (flowState.rank or 0) * 100))
        end)
        if not okW1 then print("|cFFFF0000[绿喷管家]|r flow诊断1异常: " .. tostring(errW1)) end
        -- v1.32.5: 绿喷本地模型明细 (和游戏里绿喷图标上的倒计时直接对比)
        local okW2, errW2 = pcall(function()
            local cur  = chargeModel.currentCharges
            local maxC = chargeModel.maxCharges
            local nextIn = 0
            if chargeModel.nextChargeAt and cur and cur < maxC then
                nextIn = math.max(0, chargeModel.nextChargeAt - GetTime())
            end
            print(string.format("|cFF7F77DD[绿喷管家]|r 绿喷模型: %s/%s 层, 下一层%.1fs, 单层充能%s秒",
                tostring(cur), tostring(maxC), nextIn, tostring(chargeModel.rechargeTotal)))
        end)
        if not okW2 then print("|cFFFF0000[绿喷管家]|r flow诊断2异常: " .. tostring(errW2)) end
        print("|cFF7F77DD[绿喷管家]|r 绿喷充能倒计时: " .. (chargeActive and "激活" or "未激活")
              .. ", 静滞CD倒计时: " .. (stasisActive and "激活" or "未激活"))
        -- v1.36.9: 游戏侧 aura 探针 —— 能不能**直接读**到心流 buff 的剩余时间?
        --   老板思路: 心流 buff 由绿喷/红喷"施法成功"刷新到 10s。现在模型靠"事件+10s"**推算**窗口;
        --   若 aura 剩余在战斗中可读, 就能改用它驱动加速窗口 —— 漏刷/延迟都不怕, 长战斗里更准。
        local okA, errA = pcall(function()
            local nowA = GetTime()
            print(string.format("|cFF7F77DD[绿喷管家]|r 加速窗口(模型推算): 剩余 %.1fs (flowUntil=%.1f)",
                (flowUntil > nowA) and (flowUntil - nowA) or 0, flowUntil or 0))
            if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
                print("  C_UnitAuras.GetAuraDataByIndex 不可用, 读不到 aura")
                return
            end
            -- v1.36.10: 两个 ID 都查 —— 真机已证 天赋ID(385696) != 光环ID(390148)
            if C_UnitAuras.GetPlayerAuraBySpellID then
                for _, idq in ipairs({ FLOW_STATE_ID, FLOW_AURA_ID }) do
                    local ok1, d1 = pcall(C_UnitAuras.GetPlayerAuraBySpellID, idq)
                    if ok1 and type(d1) == "table" then
                        local rem = "?"
                        pcall(function()
                            if type(d1.expirationTime) == "number" and d1.expirationTime > 0 then
                                rem = string.format("%.1fs", d1.expirationTime - nowA)
                            end
                        end)
                        print(string.format("  直查 id=%s: 命中! name=%s dur=%s 剩余=%s 层数=%s",
                            tostring(idq), CastProbeArgDesc(d1.name), CastProbeArgDesc(d1.duration),
                            rem, CastProbeArgDesc(d1.applications)))
                    else
                        print(string.format("  直查 id=%s: 没有该 aura (ok=%s)", tostring(idq), tostring(ok1)))
                    end
                end
            end
            -- ★ 这一行是"改用 aura 驱动"值不值的直接读数:
            --   差>0 = 模型窗口比真实 buff 早结束(少补加速); 差<0 = 模型窗口偏长(多补)
            local remAb, stAb = ReadFlowAuraRemain()
            local winAb = (flowUntil > nowA) and (flowUntil - nowA) or 0
            if remAb then
                print(string.format("  ★ 窗口对比: 模型推算=%.1fs  buff真实=%.1fs  差=%+.2fs  (%s)",
                    winAb, remAb, winAb - remAb,
                    (remAb > 0.05) and "buff在身, 可作驱动源" or "buff已过期/将尽"))
            else
                print(string.format("  ★ 窗口对比: 模型推算=%.1fs  buff读不到(%s) -> 只能靠事件推算",
                    winAb, tostring(stAb)))
            end
            print("  --- 身上 helpful aura (找 duration≈10s 的那个, 很可能就是心流 buff) ---")
            local n = 0
            for i = 1, 40 do
                local ok2, d2 = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
                if not ok2 or d2 == nil then break end
                local rem2 = "?"
                pcall(function()
                    if type(d2.expirationTime) == "number" and d2.expirationTime > 0 then
                        rem2 = string.format("%.1fs", d2.expirationTime - nowA)
                    end
                end)
                print(string.format("    [%d] id=%s name=%s dur=%s 剩余=%s",
                    i, CastProbeArgDesc(d2.spellId), CastProbeArgDesc(d2.name),
                    CastProbeArgDesc(d2.duration), rem2))
                n = n + 1
            end
            print(string.format("  共 %d 个 helpful aura (若值为 secret 说明战斗中读不到)", n))
        end)
        if not okA then print("|cFF7F77DD[绿喷管家]|r aura 探针异常: " .. tostring(errA)) end
    elseif cmd == "time" then
        -- v1.36.3: 充能计时对账 —— 连续采样"引擎剩余 vs 模型剩余", 量化绿喷充能计时误差
        --   原理: 引擎句柄(DurationObject)是游戏自己的剩余秒; 模型是自己推的。两者同帧取数做差。
        --   限制: 战斗中引擎剩余是 secret(不能算术), 所以必须在**脱战**下测; 且要"正在充能(不满层)"。
        print("|cFF7F77DD[绿喷管家]|r 计时对账 —— 绿喷充能 + 静滞CD (每 1s 采一次):")
        print("  前提: ① 脱战(战斗中引擎剩余与 API 都是 secret, 算不出差); ② 绿喷要'正在充能'(满层没有'下一层'可比)")
        print("       测绿喷: **敲完命令后、采样期间**放一口绿喷(2->1) —— 这样才有'★层数变化'标记,")
        print("               看得出'新层起算'用的时长对不对(折算=27.27 / 没折=30)。")
        print("               (只在敲命令前放, 会被'起点对齐'掩盖 —— 对齐后按真实秒走, 差恒 0 看不出折算错)")
        print("       测静滞: 静滞在 CD 中, 且最好刚放过技能(心流窗口内)")
        print("       采样期间暂停**所有**官方值校准(含每帧校准), 所以'模型'列是它自己走的原始值")
        print("       最有价值的一次: 让采样**跨过心流窗口过期**(放一口技能后第 5-7 秒开测), 就能看出引擎速率是否跟着变")
        -- v1.36.5: 静滞 API 原始字段 —— 用引擎自己的 rate 判定"静滞CD 到底吃不吃心流加速"
        --   (rate<1 表示游戏认为它在加速; 若恒为 1 而我们却在加速, 就是我们在多算)
        pcall(function()
            local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(STASIS_SPELL_ID)
            if type(cd) == "table" then
                local p = {}
                for k, v in pairs(cd) do
                    if type(v) ~= "table" then
                        p[#p + 1] = tostring(k) .. "=" .. CastProbeArgDesc(v)
                    end
                end
                print("  静滞API原始字段: " .. table.concat(p, " "))
            else
                print("  静滞API原始字段: 取不到 (C_Spell.GetSpellCooldown 返回 " .. tostring(cd) .. ")")
            end
        end)
        local N = 20   -- v1.36.23: 8 -> 20 秒, 拉长观察窗才看得出漂移
        local flowOpenCnt = 0   -- v1.36.25: 统计有几个采样点落在心流窗口内 —— 判读必需
        -- v1.36.28: 心流 buff 直读统计(脱战) + 模型窗口与 buff 真实的偏差累计
        local auraOpenCnt, auraDiffSum, auraDiffN = 0, 0, 0
        local combatSampleCnt = 0   -- v1.36.35: 有几个采样点落在战斗中(aura 读不到是正常的, 不是"没心流")
        --   (没有这一项就会像 01:51 那轮: 差全是 0.00s 看着完美, 其实全程**没有心流窗口**, 什么也没测到)
        local idx = 0
        -- v1.36.23: 采样前**强制对齐一次起点**(用官方值), 然后才暂停校准 ——
        --   这样之后模型是"从与游戏一致的起点"自己往下走(折算照做, 因为那才是它的真实行为);
        --   **差值一旦漂移, 就是纯粹的算法偏差**(排除了起点差与校准残留)。
        pcall(SyncStasisCooldownFromAPI)
        pcall(function()
            local inf = GetSpellChargeInfo(DREAM_BREATH_SPELL_ID)
            if inf and not inf.secret then SyncChargeModel(inf) end
        end)
        print("  (已把模型起点对齐官方值, 然后暂停校准 —— 之后看它自己走得准不准)")
        probeSuspendSync = true      -- v1.36.7/23: 起点已对齐, 采样期间暂停校准
        -- 上一采样值, 用于算"每秒走了多少秒"(Δ) —— 差值是绝对值, Δ 才能看出谁走得快
        local pGEng, pGMod, pSEng, pSMod, pApi = nil, nil, nil, nil, nil
        -- v1.36.26: 上一采样的绿喷层数 —— 用来标记"★层数变化"(= 模型刚经历一次新层起算)。
        --   为什么必需: 采样前的"起点对齐"会把模型拉到与官方一致, 于是"**起算折算算错**"这类偏差
        --   会被起点对齐掩盖(对齐后按真实秒走, 差恒为 0 看着完美)。只有在采样**期间**发生一次起算,
        --   才能看出新层用的时长对不对(折算=27.27 / 没折=30)。
        local pGChg = nil
        local sawChargeChange = false   -- v1.36.26: 采样期间是否发生过"新层起算"(没有的话测不到折算)
        -- v1.36.8: 速率统计 —— 直接回答"引擎会不会跟着 rate 变"(定性游戏怎么处理心流加速)
        local rateN, rateApiN, rateEng, rateMod, rateApi = 0, 0, 0, 0, 0
        -- 绿喷充能 (G) 与 静滞 CD (S) 两组统计
        local gSum, gMn, gMx, gFirst, gLast, gN = 0, nil, nil, nil, nil, 0
        local sSum, sMn, sMx, sFirst, sLast, sN = 0, nil, nil, nil, nil, 0
        local function sampleOnce()
            idx = idx + 1
            -- v1.36.28: 先让**模型自己走一步** —— 脱战时 EvaluateState 走的是 API 分支, 不会调用
            --   `GetLocalChargeInfo()`(模型的推进器) → 采样期间模型卡住、永不涨层
            --   (02:03 实测: #15 之后模型显示 -0.9s 并一路 -1.0/秒, 就是涨层结算没跑)。
            --   它是纯本地计算(不碰 API), 主动推一次即可, 不影响"暂停校准"。
            pcall(GetLocalChargeInfo)
            local t = GetTime()
            -- v1.36.28: 直读心流 aura (脱战可读, ID 390148) —— 老板要求"看得出来这次到底有没有心流";
            --   顺便量化"模型窗口 vs buff 真实剩余"的偏差(模型窗口从 SUCCEEDED 起算, 天然偏早)。
            local auraRem, auraState = ReadFlowAuraRemain()
            local flowWindowRem = (flowUntil > t) and (flowUntil - t) or nil
            -- v1.36.35: 上一次采样到这一次之间若发生过"心流速率换算", 在行尾标注原因与幅度。
            --   直接回答"模型为什么突然跳了 ±8s" —— 战斗中读不到 aura, 换算该不该发生没法当场核对,
            --   但至少"发生了什么"要看得见(否则一跳就只剩猜)。采样间隔 1s, 取 1.2s 覆盖。
            local _inCombat = false
            local okCb, cb = pcall(function() return InCombatLockdown and InCombatLockdown() end)
            if okCb and cb then _inCombat = true end
            if _inCombat then combatSampleCnt = combatSampleCnt + 1 end
            local convNote = nil
            if lastFlowConv and (t - (lastFlowConv.t or 0)) <= 1.2 then
                local bits = {}
                if math.abs(lastFlowConv.dStasis or 0) > 0.05 then
                    bits[#bits + 1] = string.format("静滞%+.1fs", lastFlowConv.dStasis)
                end
                if math.abs(lastFlowConv.dCharge or 0) > 0.05 then
                    bits[#bits + 1] = string.format("绿喷%+.1fs", lastFlowConv.dCharge)
                end
                if #bits > 0 then
                    convNote = string.format(" ‹心流%s换算 x%.3f: %s›",
                        lastFlowConv.tag, lastFlowConv.mul, table.concat(bits, " "))
                end
            end
            local modelRem, engRem, engSecret, hasHandle = nil, nil, false, false
            local modelStasis, engStasis, engStasisSecret, hasStasis = nil, nil, false, false
            -- v1.36.26: 检出"本次采样期间模型刚起算过新层"(层数变化) -> 打 ★ 标记
            local chgNow = chargeModel.currentCharges
            local chgMark = ""
            if pGChg ~= nil and tostring(chgNow) ~= tostring(pGChg) then
                chgMark = string.format(" ★层数%s->%s(新层起算! 看这行之下的差)", tostring(pGChg), tostring(chgNow))
                sawChargeChange = true
            end
            pGChg = chgNow
            -- v1.36.7: 静滞的官方 API 值(可读时) —— 用来定性"游戏怎么处理心流加速"
            local apiRem, apiRate, apiDur, apiActive = nil, nil, nil, nil
            pcall(function()
                if chargeModel.currentCharges and chargeModel.nextChargeAt
                   and chargeModel.currentCharges < (chargeModel.maxCharges or 2) then
                    modelRem = chargeModel.nextChargeAt - t
                end
                -- v1.36.13 门控放宽到 ARMED: 静滞"存满进 ARMED"时 cooldownEndTime 就已设好、CD 已在跑,
                --   只认 COOLDOWN 会把 ARMED 阶段误报成"模型不在CD/锚点偏晚"(2026-09-21 01:03 实测踩到)。
                if (stasisState.phase == "ARMED" or stasisState.phase == "COOLDOWN")
                   and (stasisState.cooldownEndTime or 0) > t then
                    modelStasis = stasisState.cooldownEndTime - t
                end
            end)
            pcall(function()
                local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(STASIS_SPELL_ID)
                if type(cd) == "table" then
                    if IsSafeNumber(cd.timeUntilEndOfStartRecovery) then apiRem = cd.timeUntilEndOfStartRecovery end
                    if IsSafeNumber(cd.modRate) then apiRate = cd.modRate end
                    if IsSafeNumber(cd.duration) then apiDur = cd.duration end
                    if type(cd.isActive) == "boolean" then apiActive = cd.isActive end
                end
            end)
            pcall(function()
                EngineInvalidate()          -- 关键: 句柄有 1s 缓存, 不失效会拿旧值 -> 假漂移
                local h = EngineChargeHandle()
                if h then
                    hasHandle = true
                    engRem, engSecret = EngineRemaining(h)
                end
                local hs = EngineStasisHandle()
                if hs then
                    hasStasis = true
                    engStasis, engStasisSecret = EngineRemaining(hs)
                end
            end)
            local parts = {}
            -- ① 绿喷充能
            if engSecret then
                parts[#parts + 1] = "绿喷: 引擎=secret(战斗中读不到)"
            elseif engRem and modelRem then
                local d = modelRem - engRem
                gN = gN + 1; gSum = gSum + d
                if gMn == nil or d < gMn then gMn = d end
                if gMx == nil or d > gMx then gMx = d end
                if gN == 1 then gFirst = d end
                gLast = d
                local spd = ""
                if pGEng and pGMod then
                    spd = string.format(" [Δ引擎%+.1f Δ模型%+.1f]", engRem - pGEng, modelRem - pGMod)
                end
                pGEng, pGMod = engRem, modelRem
                parts[#parts + 1] = string.format("绿喷: 引擎=%.1fs 模型=%.1fs 差=%+.1fs%s%s", engRem, modelRem, d, spd, chgMark)
            elseif not hasHandle then
                parts[#parts + 1] = string.format("绿喷: 引擎无句柄(满层/没在充能) 模型=%s%s",
                    modelRem and string.format("%.1fs", modelRem) or "无", chgMark)
            else
                parts[#parts + 1] = "绿喷: 引擎剩余读不到"
            end
            -- ② 静滞 CD (判断公式里的 T)
            local sApi = ""
            if apiRem then
                sApi = string.format("API=%.1fs(rate=%.3f dur=%.1f)", apiRem, apiRate or 0, apiDur or 0)
            end
            if engStasisSecret then
                parts[#parts + 1] = "静滞CD: 引擎=secret(战斗中读不到) " .. sApi
            elseif engStasis and modelStasis then
                local d = modelStasis - engStasis
                sN = sN + 1; sSum = sSum + d
                if sMn == nil or d < sMn then sMn = d end
                if sMx == nil or d > sMx then sMx = d end
                if sN == 1 then sFirst = d end
                sLast = d
                local spd = ""
                if pSEng and pSMod then
                    local dE, dM = engStasis - pSEng, modelStasis - pSMod
                    spd = string.format(" [Δ引擎%+.1f Δ模型%+.1f]", dE, dM)
                    -- 累计"每秒走掉多少秒"(取正): 引擎 vs 模型 vs API
                    if dE < 0 then rateEng = rateEng - dE end
                    if dM < 0 then rateMod = rateMod - dM end
                    rateN = rateN + 1
                    if apiRem and pApi and (pApi - apiRem) > 0 then
                        rateApi = rateApi + (pApi - apiRem)
                        rateApiN = rateApiN + 1
                    end
                end
                pSEng, pSMod = engStasis, modelStasis
                pApi = apiRem
                parts[#parts + 1] = string.format("静滞CD: 引擎=%.1fs %s 模型=%.1fs 差=%+.1fs%s",
                    engStasis, sApi, modelStasis, d, spd)
            elseif modelStasis then
                parts[#parts + 1] = string.format("静滞CD: 引擎无数据 %s 模型=%.1fs", sApi, modelStasis)
            elseif apiRem then
                -- v1.36.13: 修掉门控后, 走到这里只剩一种情况 —— 模型还没设 cooldownEndTime
                --   (静滞仍在 STORING 存技能中, OnStasisArmed 未触发)。别再喊"锚点偏晚"(那是误报)。
                parts[#parts + 1] = string.format("静滞CD: 模型尚在存技能(未起算) | 官方 %s", sApi)
            else
                parts[#parts + 1] = "静滞CD: 不在CD中(想测它就先开一次静滞, 脱战后再敲本命令)"
            end
            if flowUntil > GetTime() then flowOpenCnt = flowOpenCnt + 1 end   -- v1.36.25
            -- v1.36.28: 心流 buff 直读(脱战可读) —— 一眼看出"这次有没有心流", 并与模型窗口对账
            if auraRem then
                auraOpenCnt = auraOpenCnt + 1
                if flowWindowRem then
                    local wd = flowWindowRem - auraRem
                    auraDiffSum = auraDiffSum + wd; auraDiffN = auraDiffN + 1
                    parts[#parts + 1] = string.format("心流buff=%.1fs 模型窗口=%.1fs (差%+.1fs)", auraRem, flowWindowRem, wd)
                else
                    parts[#parts + 1] = string.format("心流buff=%.1fs **[模型窗口已关!]**", auraRem)
                end
            elseif auraState == "secret" then
                parts[#parts + 1] = "心流buff=secret(战斗中)"
            elseif auraState == "noaura" and _inCombat then
                -- v1.36.35: 战斗中 aura 整条通道被屏蔽(遍历返回 0 个), 以前这里打"无(noaura)"
                --   会被读成"身上没有心流 buff" —— 其实只是**读不到**。战斗中请只看上面的"模型窗口"。
                parts[#parts + 1] = "心流buff=战斗中读不到(看'模型窗口')"
            else
                parts[#parts + 1] = "心流buff=无(" .. tostring(auraState) .. ")"
            end
            if convNote then parts[#parts + 1] = convNote end
            print(string.format("  #%d %s", idx, table.concat(parts, " | ")))
        end
        local function summarize(tag, n, sum, mn, mx, first, last)
            if n > 0 then
                local avg = sum / n
                local trend = (last and first) and (last - first) or 0
                print(string.format("  --- %s 小结: 有效 %d/%d | 平均差 %+.2fs | 范围 %+.2fs ~ %+.2fs | 末-首 %+.2fs",
                    tag, n, idx, avg, mn, mx, trend))
            else
                print(string.format("  --- %s 小结: 没有有效样本(原因见上面各行)", tag))
            end
        end
        local function finish()
            probeSuspendSync = false     -- 采样结束, 恢复正常校准
            summarize("绿喷充能", gN, gSum, gMn, gMx, gFirst, gLast)
            summarize("静滞CD", sN, sSum, sMn, sMx, sFirst, sLast)
            -- v1.36.25: 窗口覆盖率 —— 没有它, "差全 0"可能是"根本没开窗", 会误判为"完美"
            print(string.format("  心流窗口(模型推算): 采样期 %d/%d 个点落在窗口内 %s",
                flowOpenCnt, idx,
                (flowOpenCnt > 0) and "(含加速场景 ✓)" or "!! 全程无窗口 —— 这次测不到心流影响, 请放一口红喷/绿喷后 10 秒内重测"))
            -- v1.36.28: 直读 aura 的统计(脱战可读) —— 老板要求"能看出有没有心流"; 顺便量化窗口偏差
            if auraOpenCnt > 0 or auraDiffN > 0 then
                print(string.format("  心流buff(直读aura): %d/%d 个采样点在 buff 内 %s",
                    auraOpenCnt, idx,
                    (auraOpenCnt > 0) and "✓ 这次确实测到了心流场景" or "!! 但窗口推算说有 —— 两者不一致, 查开窗时机"))
                if auraDiffN > 0 then
                    print(string.format("  窗口精度: 模型窗口 - buff真实 = 平均 %+.2fs (%d 样本; 正=模型窗口偏长, 负=偏短)",
                        auraDiffSum / auraDiffN, auraDiffN))
                end
            elseif combatSampleCnt > 0 then
                -- v1.36.35: 战斗中 aura 整条通道被屏蔽 -> 不能据此说"没有心流"。
                --   战斗中的窗口中状态**只能**看上面那行"模型推算"(事件驱动, 战斗中可用)。
                print(string.format("  心流buff(直读aura): %d/%d 个采样点在战斗中 —— **战斗中 aura 读不到是正常现象**" ..
                    "(暴雪屏蔽整条通道: 脱战 12 个 / 战斗 0 个)", combatSampleCnt, idx))
                print("      → 战斗中心流**只能靠'模型推算'那行**(事件驱动); 直读仅脱战可用")
            else
                print("  心流buff(直读aura): 全程没有 buff —— 这次**没测到心流场景**(需在采样期间放一口红喷/绿喷)")
            end
            -- v1.36.26: "有没有发生新层起算" —— 没有的话, 折算对不对根本测不到(会被起点对齐掩盖)
            if sawChargeChange then
                print("  ✓ 采样期间发生过新层起算(★) —— 起算折算对不对, 看 ★ 之后那几行的'差'是否仍接近 0")
            else
                print("  ⚠ 采样期间**没有**新层起算(无 ★ 标记) —— 本次测不出'起算折算'对不对!")
                print("     正确测法: **敲完本命令后**、采样进行中, 放一口绿喷(2->1), 让模型起算一次新层")
            end
            -- v1.36.13: 顺带报"锚点差"(游戏 startTime vs 模型 cdStart) —— 脱战可读, 一眼看出锚点有没有偏
            pcall(function()
                local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(STASIS_SPELL_ID)
                if type(cd) ~= "table" then return end
                local gStart = cd.startTime or cd.startRecoveryTime
                if issecretvalue and issecretvalue(gStart) then return end
                if type(gStart) ~= "number" or gStart <= 0 then return end
                local a = stasisState.cdAnchoredAt or 0
                if a <= 0 then return end
                local diff = a - gStart
                print(string.format("  静滞锚点: 游戏start=%.1f | 模型cdStart=%.1f | 差=%+.2fs (%s)",
                    gStart, a, diff, (math.abs(diff) <= 1.0) and "<=1s 可接受" or "偏大, 需查 thirdCastStartTime 记录"))
            end)
            -- v1.36.8: 速率结论 —— 这是"游戏怎么处理心流加速"的定性依据
            if rateN > 0 then
                print(string.format("  速率实测(每秒走掉多少秒): 引擎 %.2f | 模型 %.2f | API %.2f  (静滞 %d 次, API %d 次)",
                    rateEng / rateN, rateMod / rateN, rateApiN > 0 and (rateApi / rateApiN) or 0, rateN, rateApiN))
                print("  判读: 若 rate<1(有加速)时引擎仍走 1.00 -> 游戏是「CD开始时按当时rate折算总时长, 之后按真实秒倒数」")
                print("        -> 模型机制要改成'起算时折算'; 若引擎跟着走 1.10 -> 游戏按实时rate递减, 机制对, 只需修锚点")
            else
                print("  速率实测: 静滞样本不足(需连续采样中有静滞在 CD)")
            end
            print("  判读: |差|<=1s = 准; 1~2s = 可接受(点心流时容易到这档); >3s = 模型漂了, 把上面几行发我")
            print("       '末-首'偏向一边 = 系统性漂移; 正差=模型偏慢(倒计时比游戏晚), 负差=模型偏快(危险: 会提前说随便喷)")
        end
        sampleOnce()
        if C_Timer and C_Timer.NewTicker then
            local ticker
            ticker = C_Timer.NewTicker(1, function()
                sampleOnce()
                if idx >= N then
                    if ticker then pcall(function() ticker:Cancel() end) end
                    finish()
                end
            end)
        else
            finish()
        end
    elseif cmd == "cast" then
        -- v1.36.1: 蓄力施法事件探针 (排查"蓄力被取消却仍算作释放")
        print("|cFF7F77DD[绿喷管家]|r 蓄力施法事件探针 (v" .. tostring(ADDON_VERSION) .. "):")
        print("  复现: 绿喷满2层 -> 按住绿喷蓄力 -> 按 Esc 取消 -> 回聊天框敲 /DBSH cast")
        print("  看什么: ① 取消那一下有没有 SUCCEEDED(355936/382614); ② EMPOWER_STOP 的 a4[complete] 是真值还是 secret")
        local okP, errP = pcall(function()
            local nextIn = 0
            if chargeModel.nextChargeAt and chargeModel.currentCharges
               and chargeModel.currentCharges < chargeModel.maxCharges then
                nextIn = math.max(0, chargeModel.nextChargeAt - GetTime())
            end
            print(string.format("  当前: 模型层=%s/%s, 下一层%.1fs | used=%s | 资格=%s",
                tostring(chargeModel.currentCharges), tostring(chargeModel.maxCharges), nextIn,
                tostring(usageCounter.used), tostring(eligibility.eligible)))
        end)
        if not okP then print("|cFFFF0000[绿喷管家]|r 状态读取异常: " .. tostring(errP)) end
        print("  --- 事件记录 (最近 " .. tostring(#castProbe) .. " 条, 最早在上) ---")
        if #castProbe == 0 then
            print("    (空: 还没记到事件 —— 先做一次'蓄力→取消'再敲本命令)")
        else
            for _, l in ipairs(castProbe) do print("    " .. l) end
        end
        print("  ↳ 参数: a1[unit] a2[castGUID] a3[spellID] a4[complete] a5[interruptedBy] a6[castBarID]; secret=被加密读不到")
    elseif cmd == "charge" then
        -- v1.32.9: 绿喷充能记账诊断 —— "本地模型 vs 游戏API" 逐项对比 + 最近事件流水
        print("|cFF7F77DD[绿喷管家]|r 绿喷充能诊断:")
        local okC, errC = pcall(function()
            -- 1) API 原始值 (战斗中可能是 secret) —— v1.32.11 加"去密"尝试, 战斗中也想读到真值
            local api = GetSpellChargeInfo(DREAM_BREATH_SPELL_ID)
            local apiRaw, apiDetail = ProbeChargeRaw(DREAM_BREATH_SPELL_ID)
            local apiCharge, apiNext = nil, 0
            if api and not api.secret then
                apiCharge = api.currentCharges
                apiNext = api.nextChargeIn or 0
                print(string.format("  API真值: %s/%s 层, 下一层%.2fs | dur=%s rate=%s (普通可读)",
                    tostring(api.currentCharges), tostring(api.maxCharges), apiNext,
                    tostring(api.cooldownDuration), tostring(api.chargeModRate)))
            elseif apiRaw and apiRaw.currentCharges then
                apiCharge = apiRaw.currentCharges
                apiNext = RawNextChargeIn(apiRaw)
                print(string.format("  API真值(去密): %s/%s 层, 下一层%.2fs | dur=%s rate=%s",
                    tostring(apiRaw.currentCharges), tostring(apiRaw.maxCharges), apiNext,
                    tostring(apiRaw.cooldownDuration), tostring(apiRaw.chargeModRate)))
            else
                print("  API真值: secret (去密也失败 -> 全靠本地模型)")
            end
            if apiDetail then print("  原始字段: " .. apiDetail) end
            -- 2) 本地模型
            local nextIn = 0
            if chargeModel.nextChargeAt and chargeModel.currentCharges
               and chargeModel.currentCharges < chargeModel.maxCharges then
                nextIn = math.max(0, chargeModel.nextChargeAt - GetTime())
            end
            print(string.format("  本地模型: %s/%s 层, 下一层%.1fs, 单层充能%.3fs (基准%d)",
                tostring(chargeModel.currentCharges), tostring(chargeModel.maxCharges),
                nextIn, chargeModel.rechargeTotal, DREAM_BREATH_CHARGE_BASE))
            -- 【对账】能读到 API 就直接给差异 —— 老板要的"本地跑的数据 vs 实际能取到的数据"
            if apiCharge then
                local dC = (chargeModel.currentCharges or 0) - apiCharge
                local dN = nextIn - apiNext
                local dir = (dC > 0 and "模型偏快") or (dC < 0 and "模型偏慢") or "层数相同"
                local same = (dC == 0) and (math.abs(dN) <= 0.5)
                print(string.format("  【对账】层数差=%+d 层, 下一层时间差=%+.2fs  %s (%s)",
                    dC, dN, same and "✓ 一致" or "✗ 不一致", dir))
            end
            print(string.format("  心流: %d层, 窗口剩余%.1fs (绿喷充能 + 静滞CD 都吃心流加速)",
                flowState.rank or 0,
                (flowUntil > GetTime()) and (flowUntil - GetTime()) or 0))
            -- v1.32.10: "诺兹多姆的讲义"是溜溜球减CD的开关, 必须一眼能看到
            print(string.format("  讲义天赋: 诺兹多姆的讲义(376237)=%s -> 溜溜球减CD %s",
                (hasNozdormuTeachings == true and "✓已点")
                or (hasNozdormuTeachings == false and "✗确认未点") or "未识别(按已点处理)",
                (hasNozdormuTeachings == false) and "不生效" or "生效"))
            -- 静滞 CD 剩余 (对照组: 它才是真正吃心流加速的那条)
            local sLeft = 0
            if stasisState.cooldownEndTime and stasisState.cooldownEndTime > GetTime() then
                sLeft = stasisState.cooldownEndTime - GetTime()
            end
            print(string.format("  静滞CD: phase=%s, 剩余%.2fs (吃心流加速)",
                tostring(stasisState.phase), sLeft))
            -- v1.36.11 锚点对比: 游戏 CD 的**真实起点** vs 模型锚点 —— 定性"静滞CD从哪一刻起算"
            --   游戏侧 startTime (GetTime 基准真值, 脱战可读): 若 ≈"按下静滞"时刻 → 按下即CD;
            --   若 ≈"第3技能开始+1.3s" → 存满才CD。这一行决定锚点要不要提前。
            pcall(function()
                local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(STASIS_SPELL_ID)
                if type(cd) ~= "table" then return end
                local gStart = cd.startTime or cd.startRecoveryTime
                if issecretvalue and issecretvalue(gStart) then
                    print("  静滞CD锚点对比: 游戏startTime=secret(战斗中读不到) -> 脱战后敲")
                    return
                end
                if type(gStart) ~= "number" or gStart <= 0 then return end
                local anchor = stasisState.cdAnchoredAt or 0
                local press  = stasisState.activeStartTime or 0
                local third  = stasisState.thirdCastStartTime or 0
                if anchor <= 0 and press <= 0 then return end
                -- v1.36.37: **加打"游戏 duration 与结束时刻"** —— 判断灯色真正依赖的是"CD 什么时候结束",
                --   而它 = start + duration。只看"锚点差"会被"起点差"和"时长差"互相抵消搞糊涂
                --   (2026-09-21 长战斗实测: 锚点差 +5.0s, 但模型剩余只比游戏多 0.6s —— 两者抵消了)。
                local gDur = cd.duration
                local gEnd = (type(gDur) == "number" and gDur > 0) and (gStart + gDur) or nil
                local mEnd = stasisState.cooldownEndTime
                print(string.format("  静滞CD锚点对比: 游戏start=%.1f dur=%s end=%s | 模型锚点=%.1f end=%s | 端差=%s",
                    gStart,
                    (type(gDur) == "number") and string.format("%.1f", gDur) or "?",
                    gEnd and string.format("%.1f", gEnd) or "?",
                    anchor,
                    mEnd and string.format("%.1f", mEnd) or "?",
                    (gEnd and mEnd) and string.format("%+.1fs (这才是判断依据!)", mEnd - gEnd) or "?"))
                print(string.format("    参考: 按下静滞=%.1f (游戏start%+.1fs) | 第3技能开始%s",
                    press, press - gStart,
                    (third > 0) and string.format("=%.1f (%+.1fs)", third, third - gStart) or "未记录"))
                print("    判读: **看'端差'**(模型CD结束 vs 游戏CD结束) —— 它≈0 就说明判断依据是对的;")
                print("          锚点差与 dur 差只要互相抵消, 端差仍可≈0 (锚点语义不必强行对齐)")
            end)
            -- v1.33: 引擎句柄通道 (战斗中 secret-safe 的官方显示源)
            local okE, errE = pcall(function()
                if not EngineSupported() then
                    print("  引擎句柄: 客户端不支持 (需 11.1.5+ 的 C_Spell.GetSpellChargeDuration)")
                    return
                end
                local hC = EngineChargeHandle()
                local hS = EngineStasisHandle()
                print(string.format("  引擎句柄: 绿喷下一层=%s | 静滞=%s",
                    hC and "在充能" or "无(满层/未充能)",
                    hS and "CD中" or (stasisState.phase == "COOLDOWN" and "读不到" or "非CD阶段")))
                local eCh = EngineChargesInfo()
                if eCh then
                    print(string.format("  引擎层数: isActive=%s (clean, false=满层), cur明文=%s, max=%s",
                        tostring(eCh.recharging), tostring(eCh.cur), tostring(eCh.max)))
                end
                print("  (引擎剩余秒若为secret只能由UI渲染, 打印到聊天会被拒 —— UI上的数字就是引擎真值)")
            end)
            if not okE then print("|cFFFF0000[绿喷管家]|r 引擎句柄诊断异常: " .. tostring(errE)) end
            -- 3) 记账流水
            print("  --- 记账流水 (最近 " .. tostring(#chargeDiag.events) .. " 条) ---")
            if #chargeDiag.events == 0 then
                print("    (空: 还没发生过扣层/校准)")
            else
                for _, l in ipairs(chargeDiag.events) do print("    " .. l) end
            end
            print("  ↳ 排查: ① 把'充能完成'时刻与游戏图标 +1 的瞬间对齐 -> 定位模型快/慢在哪一段;")
            print("     ② 若'溜溜球减CD'条数 > 实际施放次数 -> 查静滞重放是否重复补算;")
            print("     ③ 心流窗口内模型倒计时应比游戏图标略快(每层约少走2.7s)")
        end)
        if not okC then print("|cFFFF0000[绿喷管家]|r 充能诊断异常: " .. tostring(errC)) end
    elseif cmd == "secret" then
        -- v1.32.11: 看"战斗中到底能读到什么" —— 逐字段打印 type/tostring/去密结果
        print("|cFF7F77DD[绿喷管家]|r secret 字段探测 (战斗中直接敲本命令):")
        local okS0, errS0 = pcall(function()
            local inC = false
            pcall(function() inC = UnitAffectingCombat and UnitAffectingCombat("player") end)
            print("  是否战斗中: " .. tostring(inC))

            local i1, d1 = ProbeChargeRaw(DREAM_BREATH_SPELL_ID)
            print("  [绿喷充能 355936]")
            print("    " .. tostring(d1))
            if i1 and i1.currentCharges then
                print(string.format("    -> 去密可读: %s/%s 层, 下一层%.2fs",
                    tostring(i1.currentCharges), tostring(i1.maxCharges), RawNextChargeIn(i1)))
            else
                print("    -> 去密失败: 拿不到普通数字")
            end

            print("  [静滞冷却 370537]")
            local rawS = nil
            pcall(function()
                if C_Spell and C_Spell.GetSpellCooldown then
                    rawS = C_Spell.GetSpellCooldown(STASIS_SPELL_ID)
                end
            end)
            if rawS then
                local st, du = nil, nil
                pcall(function() st = rawS.startTime; du = rawS.duration end)
                print("    start=" .. FieldDesc(st) .. "  dur=" .. FieldDesc(du))
            else
                print("    读不到 (API 返回空)")
            end

            local hasSecretApi = false
            pcall(function() hasSecretApi = (issecretvalue ~= nil) end)
            print("  issecretvalue 可用: " .. tostring(hasSecretApi))
            print("  ↳ 若上面打出数字 -> 战斗中也能实时对账;")
            print("     若全是 <err>/nil   -> 本版本把 tostring 也拦了, 只能靠脱战校准")
        end)
        if not okS0 then print("|cFFFF0000[绿喷管家]|r secret 探测异常: " .. tostring(errS0)) end
    elseif cmd == "status" then
        -- v1.32 功能二: 资格门槛检测状态 (强制重检一次再展示)
        RefreshEligibility()
        local c = eligibility.checks or {}
        print("|cFF7F77DD[绿喷管家]|r 资格检测明细:")
        print("  职业=唤魔师: " .. (c.class or "未检测"))
        print("  专精=恩护(1468): " .. (c.spec or "未检测"))
        print("  英雄天赋=塑焰者: " .. (c.hero or "未检测"))
        print("  静滞天赋(370537): " .. (c.stasis or "未检测"))
        print("  心灵之火天赋(1242745): " .. (c.innerfire or "未检测"))
        if c.hero and c.hero ~= "✓" then
            -- 英雄天赋探针: 打印原始 API 返回值 + 名字解析链, 便于定位识别失败原因
            local raw = "API不可用"
            if C_ClassTalents and C_ClassTalents.GetActiveHeroTalentSpec then
                local okr, a, b = pcall(C_ClassTalents.GetActiveHeroTalentSpec)
                if okr then
                    raw = string.format("a=%s(%s) b=%s(%s)", tostring(a), type(a), tostring(b), type(b))
                    if type(a) == "number" then
                        local infoStr = "API不存在(12.x 已移除?)"
                        if C_ClassTalents.GetHeroTalentSpecInfo then
                            local ok2, info = pcall(C_ClassTalents.GetHeroTalentSpecInfo, a)
                            if ok2 and type(info) == "table" then
                                local parts, n = {}, 0
                                for k, v in pairs(info) do
                                    if type(v) ~= "table" then
                                        n = n + 1
                                        if n <= 8 then parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
                                    end
                                end
                                infoStr = (n > 0) and table.concat(parts, ", ") or "空表"
                            else
                                infoStr = "返回 " .. tostring(info)
                            end
                        end
                        raw = raw .. " | GetHeroTalentSpecInfo(" .. tostring(a) .. "): " .. infoStr
                    end
                else
                    raw = "调用报错"
                end
            end
            print("  [探针] GetActiveHeroTalentSpec: " .. raw)
            print("  [探针] 解析结果: name=" .. tostring(c.heroName) .. "  id=" .. tostring(c.heroID))
        end
        if eligibility.eligible == true then
            print("  最终状态: 已启用 (五项检测全部通过)")
        elseif eligibility.eligible == false then
            print("  最终状态: 已禁用 (" .. tostring(eligibility.reason) .. ")")
        else
            print("  最终状态: 未确定, 暂不拦截 (" .. tostring(eligibility.reason) .. ")")
        end
    else
        PrintHelp()
    end
end

--==========================================================================
-- 全局暴露 (方便其他插件/WeakAura调用)
--==========================================================================

_G.DreamBreathStasisHelper = {
    EvaluateState = EvaluateState,
    GetSpellChargeInfo = GetSpellChargeInfo,
    GetSpellCooldownInfo = GetSpellCooldownInfo,
    ProjectChargesAfterCast = ProjectChargesAfterCast,
    SimulateCharges = SimulateCharges,
    -- v1.33: 引擎句柄通道 (战斗中 secret-safe 显示) — 暴露供测试/调试
    EngineSupported = EngineSupported,
    EngineChargeHandle = EngineChargeHandle,
    EngineStasisHandle = EngineStasisHandle,
    EngineRemaining = EngineRemaining,
    EngineChargesInfo = EngineChargesInfo,
    EngineInvalidate = EngineInvalidate,
    -- v1.36.2: 蓄力取消回滚 —— 暴露给测试/调试 (读本地模型层数/已用, 与回滚次数)
    GetChargeModelState = function() return chargeModel.currentCharges, chargeModel.maxCharges, usageCounter.used end,
    GetCancelRollbackCount = function() return empowerRollbackCount end,
    Constants = {
        DREAM_BREATH_SPELL_ID = DREAM_BREATH_SPELL_ID,
        STASIS_SPELL_ID = STASIS_SPELL_ID,
        STASIS_ACTIVE_AURA_ID = STASIS_ACTIVE_AURA_ID,
    },
}
