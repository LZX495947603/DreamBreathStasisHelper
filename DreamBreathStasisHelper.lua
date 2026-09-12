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
-- 作者: 炸鱼奶龙  版本: 1.35.0
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

-- v1.32.9 诊断: 绿喷充能"记账流水"(最近10条)。绿喷层数=API校准+施放扣层+到期结算三者叠加,
--   出问题时肉眼很难复现, 这里把三类事件按时间记下来, /DBSH charge 一键导出。
--   只在"层数真的变化"时记录, 避免每帧刷屏。
local chargeDiag = { events = {} }
local function ChargeDiag(msg)
    local log = chargeDiag.events
    log[#log + 1] = string.format("[%.1fs] %s", GetTime(), msg)
    if #log > 10 then table.remove(log, 1) end
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

local function SyncChargeModel(dreamInfo)
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
        chargeModel.nextChargeAt = GetTime() + recharge
    end

    -- 先把到期充能结算进层数 (可能连充多层)
    while chargeModel.currentCharges < chargeModel.maxCharges
          and chargeModel.nextChargeAt
          and GetTime() >= chargeModel.nextChargeAt do
        chargeModel.currentCharges = chargeModel.currentCharges + 1
        if chargeModel.currentCharges >= chargeModel.maxCharges then
            chargeModel.nextChargeAt = nil
        else
            chargeModel.nextChargeAt = chargeModel.nextChargeAt + recharge
        end
        -- v1.32.10 诊断: 涨层是最直观的对照点 (游戏图标 +1 的瞬间), 必须留痕
        ChargeDiag(string.format("充能完成 -> %s/%s 层",
            tostring(chargeModel.currentCharges), tostring(chargeModel.maxCharges)))
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
    if wasFull then
        chargeModel.nextChargeAt = GetTime() + chargeModel.rechargeTotal
    elseif chargeModel.currentCharges < chargeModel.maxCharges
           and (not chargeModel.nextChargeAt or chargeModel.nextChargeAt < GetTime()) then
        -- 非满层且没在充能: 立即开始充下一层
        chargeModel.nextChargeAt = GetTime() + chargeModel.rechargeTotal
    end
    -- v1.32.9 诊断流水
    ChargeDiag(string.format("绿喷施放 spellID=%s: 层%s->%s/%s, 单层充能%.1fs",
        tostring(spellID), tostring(before), tostring(chargeModel.currentCharges),
        tostring(chargeModel.maxCharges), chargeModel.rechargeTotal))
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

-- 心流窗口开启/刷新: 蓄力施放成功时调用 (v1.32.5 起只管窗口, 不再当场一次性移位)
-- buff 不叠层, 重复施放只把窗口刷新成"从现在起 10s"
local function OnFlowWindowRefresh()
    if (flowState.rank or 0) <= 0 then return end
    local now = GetTime()
    local wasActive = (flowUntil > now)
    flowUntil = now + FLOW_WINDOW
    Trace(string.format("心流状态%d层: 窗口%s, 持续%.0fs",
        flowState.rank, wasActive and "刷新" or "开启", FLOW_WINDOW))
end

-- 心流加速: 按真实时间积分累加到冷却计时器 (v1.32.5 逐帧积分, v1.32.10 恢复作用范围)
-- 【v1.32.10 作用范围(最终定版)】心流**同时**作用于绿喷充能和静滞 CD ——
--   Wiki 原文 "increasing ... cooldown recharge rate", 且官方 hotfix 专门修过 Dream Breath。
--   v1.32.9 曾误删绿喷充能加速(当时误信"绿喷固定30s不受影响"), 实机"还是对不上"后
--   回查 Wiki 才确认: 真凶是溜溜球在**没点诺兹多姆讲义**时也减CD, 与心流无关。
-- 【为什么用逐帧积分】按 dt 累积到绝对时间戳, 只在"窗口有效 且 该计时器确实在倒计时"
--   时累加, 天然处理"满层空转""只剩几秒就完成"等边界(旧的施放瞬间移位法做不到)。
-- 【防重复积分】dt 由时间戳差算出(不依赖 elapsed 参数), 故 OnUpdate 与 C_Timer 兜底
--   同时调用也不会重复累计。
local lastFlowTick = 0
local flowTickErr1, flowTickErr2 = false, false
local flowRankRetryAt = 0   -- 心流天赋重算的限流时间戳 (登录时天赋数据未就绪 -> 补算用)
local function TickFlowAcceleration()
    if (flowState.rank or 0) <= 0 then
        lastFlowTick = 0
        return
    end
    local now = GetTime()
    if lastFlowTick == 0 then
        lastFlowTick = now
        return
    end
    local dt = now - lastFlowTick
    lastFlowTick = now
    if dt <= 0 then return end
    if dt > 3 then return end           -- 读条/加载导致的异常 dt: 本轮跳过, 下轮自然接上
    if flowUntil <= now then return end -- 窗口已过期, 不加速
    local delta = dt * FLOW_RATE_PER_RANK * flowState.rank
    -- v1.32.10 恢复: 绿喷充能**确实吃心流加速** (Wiki 铁证见 DREAM_BREATH_CHARGE_BASE 处)。
    --   v1.32.9 曾把它整个删掉(当时误信"绿喷固定30s不受影响"), 属于把作用范围砍错了 ——
    --   老板实机"还是对不上"后回查 Wiki 才确认。
    --   充能速度 ×1.1 = nextChargeAt 每帧前移 dt×10%; 只在"未满层且时钟在走"时积分
    --   (满层时游戏端充能本就停住, 加了会多减)。
    if chargeModel.currentCharges ~= nil
       and chargeModel.currentCharges < chargeModel.maxCharges
       and chargeModel.nextChargeAt then
        local ok1 = pcall(function()
            chargeModel.nextChargeAt = chargeModel.nextChargeAt - delta
        end)
        if not ok1 and not flowTickErr1 then
            flowTickErr1 = true
            Trace("心流加速: 绿喷充能积分失败(疑似secret污染), 已跳过")
        end
    end
    -- 静滞CD: 仅 ARMED/COOLDOWN 且仍在倒计时才加速
    if (stasisState.phase == "ARMED" or stasisState.phase == "COOLDOWN")
       and stasisState.cooldownEndTime and stasisState.cooldownEndTime > now then
        local ok2 = pcall(function()
            stasisState.cooldownEndTime = stasisState.cooldownEndTime - delta
        end)
        if not ok2 and not flowTickErr2 then
            flowTickErr2 = true
            Trace("心流加速: 静滞CD积分失败(疑似secret污染), 已跳过")
        end
    end
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
    stasisState.innerfireEndTime = GetTime() + STASIS_OPENING_TOTAL_DURATION  -- 心火15s独立倒计时
    Trace("静滞激活 370537 -> STORING (存3技能, 未进CD)")
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
    stasisState.cooldownEndTime = cdStart + STASIS_COOLDOWN_DURATION
    Trace(string.format("静滞存满3技能(按钮高亮) -> ARMED, 90sCD锚定施法开始+1.3s, 结束于%.0fs(提前%.1fs)",
        stasisState.cooldownEndTime, GetTime() - cdStart))
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

--==========================================================================
-- v1.33 引擎句柄 (DurationObject) — 战斗中显示零本地计算的官方通道
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

-- v1.33: line1 ("静滞CD Xs 绿喷 X/X") 的引擎渲染。
-- 用引擎句柄/引擎层数直接 SetFormattedText —— secret/clean 数值都能渲染,
-- 显示值 = 游戏引擎真值 (含心流加速/溜溜球减CD), 不再经过本地模型。
-- 返回 true=已接管 (调用方不要再 SetText); false=引擎无数据, 走原路径。
local function RenderEngineCDLine(fs, data)
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

    fs:SetFormattedText("静滞CD %.0fs  绿喷 %d/%d", stasisPart, curArg, maxArg)
    return true
end

-- 当玩家施放绿喷时累加计数
local function OnDreamBreathCast(spellID)
    usageCounter.used = (usageCounter.used or 0) + 1
    ChargeModelConsume(spellID)   -- 本地充能模型同步扣层 (战斗中这是唯一层数来源)
    EngineInvalidate()            -- v1.33: 新一轮充能开始, 引擎句柄下帧重取
    Trace(string.format("绿喷施放 spellID=%s (模型扣层), 累计=%d", tostring(spellID), usageCounter.used))
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
    if phase == "READY" and not InCombatLockdown() then
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

    -- 非STASIS_OPENING状态: 还原主区域布局 (大图标 + 大字)
    if state ~= STATE.STASIS_OPENING then
        indicator:ClearAllPoints()
        indicator:SetSize(64, 64)
        indicator:SetPoint("LEFT", frame, "LEFT", 14, 16)  -- 齿轮按钮已删, 回到原位
        statusText:ClearAllPoints()
        statusText:SetFont(STANDARD_TEXT_FONT, 26, "OUTLINE")
        statusText:SetPoint("LEFT", indicator, "RIGHT", 12, 0)
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
            line1 = string.format("绿喷 %d/%d 已满", charges, maxCharges)
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
        line1 = string.format("静滞CD %.0fs  绿喷 %d/%d",
                              data.stasisCD or 0, data.dreamCharges or 0, data.dreamMax or 2)
        line2 = string.format("喷后静滞好时剩%d层", data.projected or 0)
        frame.flashState = STATE.STOP
        indicator:Show()
    elseif state == STATE.WARNING then
        color = COLOR.WARNING
        statusMsg = "注意"
        mainIconPath = GetSpellIconPath(DREAM_BREATH_SPELL_ID)
        line1 = string.format("静滞CD %.0fs  绿喷 %d/%d",
                              data.stasisCD or 0, data.dreamCharges or 0, data.dreamMax or 2)
        line2 = string.format("再喷1次剩 %d 层", data.projected or 0)
        frame.flashState = nil
        indicator:Show()
    else -- SAFE
        color = COLOR.SAFE
        statusMsg = "随便喷"
        mainIconPath = GetSpellIconPath(DREAM_BREATH_SPELL_ID)
        if data.stasisCD then
            line1 = string.format("静滞CD %.0fs  绿喷 %d/%d",
                                  data.stasisCD or 0, data.dreamCharges or 0, data.dreamMax or 2)
        else
            line1 = string.format("绿喷 %d/%d", data.dreamCharges or 0, data.dreamMax or 2)
        end
        line2 = string.format("喷后静滞好时剩%d层", data.projected or 2)
        frame.flashState = nil
        indicator:Show()
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
    -- v1.33: CD/层数行优先走引擎句柄 (战斗中 secret-safe, 显示=引擎真值含加速/减CD)
    -- 仅限这三个状态 (line1 都是"静滞CD Xs 绿喷 X/X"格式); pcall 双保险:
    -- 引擎路径任何意外抛错 -> 回退原 SetText, UI 不冻帧
    local _engTaken = false
    if state == STATE.STOP or state == STATE.WARNING or state == STATE.SAFE then
        local _engOK, taken = pcall(RenderEngineCDLine, dataText1, data)
        _engTaken = _engOK and taken
    end
    if not _engTaken then
        dataText1:SetText(line1)
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

FSH:SetScript("OnEvent", function(self, event, ...)
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
        if db then UpdateUI() end
        return
    end

    if event == "SPELL_UPDATE_COOLDOWN" then
        EngineInvalidate()  -- v1.33: 充能/CD 状态可能变化, 引擎句柄下帧重取
        -- 充能/CD 变化: 若 API 可读(出战斗), 趁机校准绿喷充能模型
        local ok, info = pcall(function() return GetSpellChargeInfo(DREAM_BREATH_SPELL_ID) end)
        if ok and info and not info.secret then
            SyncChargeModel(info)
        end
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

        -- v1.29: 绿喷施放检测移到 SUCCEEDED (原在 EMPOWER_STOP, 但12.1战斗中 EMPOWER_STOP
        --   参数被加密只透出 unit, spellId=complete=nil, 导致绿喷计数/扣层/队列消费全失效)
        if DREAM_BREATH_IDS[spellId] then
            OnDreamBreathCast(spellId)
            ConsumeQueueItem("DREAM_BREATH")
        end

        -- v1.32.5: 任意蓄力技能施放成功 -> 只"开窗/刷新窗口";
        --   真正的冷却加速由 TickFlowAcceleration 逐帧积分 (见心流状态段注释)
        --   绿喷本身也在 EMPOWER_SPELL_IDS 里, 统一在这里开窗一次, 不重复;
        --   红喷(357208/382266)不扣层不计数, 只开窗
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
            OnFlowWindowRefresh()
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
    Constants = {
        DREAM_BREATH_SPELL_ID = DREAM_BREATH_SPELL_ID,
        STASIS_SPELL_ID = STASIS_SPELL_ID,
        STASIS_ACTIVE_AURA_ID = STASIS_ACTIVE_AURA_ID,
    },
}
