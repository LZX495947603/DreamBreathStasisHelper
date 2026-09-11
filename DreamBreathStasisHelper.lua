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
-- 作者: 炸鱼奶龙  版本: 1.31.0
--==========================================================================

local AddonName, ns = ...

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
-- empowered技能(绿喷355936/382614, 翡翠花)走 EMPOWER_STOP 去重; 普通技能走 SUCCEEDED
local STASIS_STORABLE_SPELLS = {
    [355936] = true,  -- 梦境吐息 (绿喷, empowered)
    [382614] = true,  -- 梦境吐息 (绿喷, empowered)
    [373861] = true,  -- 时空畸体
    [361195] = true,  -- 活化烈焰 (Living Flame)
    [366155] = true,  -- 回响 (Echo) — 待确认ID
    [355913] = true,  -- 翡翠花 (Emerald Blossom, 瞬发)
    [367979] = true,  -- 翡翠花 learn spell 变体
    [373766] = true,  -- 翡翠花 变体
    [366644] = true,  -- 逆转 (Reversion)
    [359816] = true,  -- 焚身 (Engulf) — 待确认ID
    [355941] = true,  -- 精神花 (Spiritbloom, empowered)
}

-- empowered 技能 (这些走 EMPOWER_STOP 事件, 且可能触发多次需去重)
-- 注意: 翡翠花是瞬发, 不走 empowered; 这里只列真正需要蓄力的技能
local STASIS_EMPOWER_SPELLS = {
    [355936] = true,  -- 绿喷
    [382614] = true,  -- 绿喷
    [355941] = true,  -- 精神花
}

-- Temporal Anomaly (时空畸体) spell ID - 静滞后第3个固定存的绿喷前置 (讲义触发减CD)
local TEMPORAL_ANOMALY_SPELL_ID = 373861

-- 时空畸体也算 DREAM_BREATH_IDS 一样的施放检测? 否, 单独列出
local TIMELINE_SPELL_IDS = {
    [355936] = "DREAM_BREATH",  -- 梦境吐息 (绿喷)
    [382614] = "DREAM_BREATH",
    [373861] = "TEMPORAL_ANOMALY",
}

-- 静滞打开阶段(按下后)的时间轴:
--   0-6s:   显示 绿喷·绿喷·时空畸体 三个图标队列
--   7-15s:  显示 心灵之火 logo + "剩余X秒" 文字 (buff 持续15秒)
--   15s+:   回到主绿喷判断模式
local STASIS_OPENING_QUEUE_DURATION = 6   -- 前6秒显示队列
local STASIS_OPENING_TOTAL_DURATION = 15  -- 整个打开阶段15秒
local STASIS_COOLDOWN_DURATION = 90       -- 静滞CD总时长(秒), 老板确认固定90s
local STASIS_CD_START_OFFSET = 1.3        -- v1.18: 游戏静滞CD在"第3技能施法开始+1.3s(GCD)"起算, 非"读条完成"
local INNERFIRE_SPELL_ID = 1242747        -- 心灵之火 (buff)
local QUEUE_ITEMS = { "DREAM_BREATH", "DREAM_BREATH", "TEMPORAL_ANOMALY" }
local QUEUE_TEXTS = {
    DREAM_BREATH     = "梦境吐息",
    TEMPORAL_ANOMALY = "时空畸体",
}

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
    customStasisCD = nil,    -- 自定义静滞CD总时间(秒), nil=自动读取
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
    TEXT    = { r = 1.00, g = 1.00, b = 1.00 },
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
                cooldownStart = info.cooldownStart
                cooldownDuration = info.cooldownDuration
                chargeModRate = info.chargeModRate
            end
        end

        if currentCharges == nil and GetSpellCharges then
            currentCharges, maxCharges, cooldownStart, cooldownDuration, chargeModRate = GetSpellCharges(spellID)
        end

        if currentCharges == nil then return nil end

        -- 计算下一层充能剩余秒数
        local nextChargeIn = 0
        if currentCharges < maxCharges and cooldownStart and cooldownDuration then
            local now = GetTime()
            local raw = (cooldownStart + cooldownDuration) - now
            if raw < 0 then raw = 0 end
            nextChargeIn = raw / (chargeModRate or 1.0)
        end

        return {
            currentCharges = currentCharges,
            maxCharges = maxCharges or 1,
            nextChargeIn = nextChargeIn,
            rechargeTotal = cooldownDuration or 30,
        }
    end)

    if not ok then return { secret = true } end
    return result
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
local chargeModel = {
    currentCharges = nil,  -- 当前层数 (nil=尚未校准, 无法推算)
    maxCharges = 2,
    rechargeTotal = 30,    -- 单层充能总时间 (有API真值就更新缓存)
    nextChargeAt = nil,    -- 下一层充好的绝对时间戳 (GetTime()) — 满层时为 nil
}

-- 时空畸体给绿喷充能减的秒数 (老板确认: 每用一次减5秒)
local TEMPORAL_ANOMALY_CD_REDUCTION = 5

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
        chargeModel.maxCharges = maxCharges
        chargeModel.currentCharges = dreamInfo.currentCharges
        -- v1.30: rechargeTotal 若被 secret 污染, 后续 nextChargeAt+recharge 会连带污染
        --   nextChargeAt, 最终溜溜球减CD抛错。写入前用 IsSafeNumber 拦截。
        if dreamInfo.rechargeTotal and dreamInfo.rechargeTotal > 0
           and IsSafeNumber(dreamInfo.rechargeTotal) then
            chargeModel.rechargeTotal = dreamInfo.rechargeTotal
        end
        -- 精确校准下一层充好时间
        if dreamInfo.currentCharges < maxCharges then
            local nextIn = dreamInfo.nextChargeIn
            if nextIn and nextIn > 0 and IsSafeNumber(nextIn) then
                chargeModel.nextChargeAt = GetTime() + nextIn
            elseif not chargeModel.nextChargeAt or chargeModel.nextChargeAt < GetTime() then
                -- v1.22: nextChargeIn 读不到(0/nil, cooldownStart 可能异常)时,
                --   不要粗暴重置 now+30(会丢掉已走过的充能进度)。
                --   仅当原时钟已过期/丢失时才兜底重设。
                chargeModel.nextChargeAt = GetTime() + chargeModel.rechargeTotal
            end
        else
            -- 满层, 无下一层充能
            chargeModel.nextChargeAt = nil
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
local function ChargeModelConsume()
    if chargeModel.currentCharges == nil then return end
    local wasFull = chargeModel.currentCharges >= chargeModel.maxCharges
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
end

-- 时空畸体施放: 绿喷充能减 5 秒
-- 只在"未满层且正在充能"时有效 (满层减CD无意义)
local function TemporalAnomalyReduceCD()
    if chargeModel.currentCharges == nil then return end
    -- v1.30: 整体 pcall 兜底。nextChargeAt 可能被 secret number 污染(见 GetLocalChargeInfo
    --   的 recharge 加法), 减法一执行就抛错, 会中断溜溜球的 SUCCEEDED 处理导致计数失败。
    --   减CD失败不应阻断主流程(计数), 静默跳过即可。
    local ok = pcall(function()
        if chargeModel.nextChargeAt and chargeModel.currentCharges < chargeModel.maxCharges then
            chargeModel.nextChargeAt = chargeModel.nextChargeAt - TEMPORAL_ANOMALY_CD_REDUCTION
            Trace(string.format("时空畸体减绿喷充能5s, 下一层充好提前到%.0fs", chargeModel.nextChargeAt))
        end
    end)
    if not ok then
        Trace("时空畸体减CD失败(疑似secret污染), 已跳过")
    end
end

-- 检查玩家身上是否有指定 spell ID 的 aura (兼容多版本)
local function HasAura(spellID)
    if not spellID then return false end
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        return C_UnitAuras.GetPlayerAuraBySpellID(spellID) ~= nil
    end
    -- fallback: 遍历 UnitBuff
    if UnitBuff then
        local i = 1
        while true do
            local _, _, _, _, _, _, _, _, _, sid = UnitBuff("player", i)
            if not sid then break end
            if sid == spellID then return true end
            i = i + 1
        end
    end
    return false
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

-- 判断当前是否为塑焰恩护唤魔师
-- 恩护 = Preservation (spec ID 1468), 塑焰 = Flameshaper (hero talent)
-- 简单判断: 是唤魔师 + 恩护专精 + 学过绿喷
local function IsFlameshaperPreservation()
    local _, class = UnitClass("player")
    if class ~= "EVOKER" then return false end

    local specId = GetSpecialization and GetSpecializationInfo(GetSpecialization() or 0)
    -- Preservation Evoker spec ID = 1468
    if specId ~= 1468 then return false end

    -- 检查是否学过 Dream Breath (塑焰恩护一定有): 尝试读取绿喷充能, 能读到说明学过
    local info = GetSpellChargeInfo(DREAM_BREATH_SPELL_ID)
    if info and info.maxCharges and info.maxCharges >= 1 then
        -- 塑焰给2层, 普通1层; 都算恩护, 但只有塑焰才需要这个插件
        -- 这里直接返回 true, 非塑焰玩家插件只是显示1层也能用
        return true
    end

    -- fallback: 用 spell name 查找
    local altId
    if C_Spell and C_Spell.GetSpellIDForSpellIdentifier then
        altId = C_Spell.GetSpellIDForSpellIdentifier("梦境吐息") or C_Spell.GetSpellIDForSpellIdentifier("Dream Breath")
    end
    if altId then
        DREAM_BREATH_SPELL_ID = altId
        return GetSpellChargeInfo(altId) ~= nil
    end

    return false
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
    sawStasisAura = false, -- 本周期是否已检测到 370562 (防重复触发)
    storedCount = 0,       -- STORING 阶段已存的白名单治疗技能数 (存满3 -> ARMED)
    innerfireEndTime = 0,  -- 心灵之火15s buff 的结束时间 (按下静滞立刻开始, 独立倒计时)
    thirdCastStartTime = 0, -- 第3个技能"施法开始"时刻 (CD起算锚点, 见 OnStasisArmed)
    storedTemporalAnomalies = 0, -- v1.20: STORING阶段存入的时空畸体(溜溜球)数量, 释放时补算减CD
    stasisReleaseTime = 0,  -- v1.20: 静滞释放时刻, 用于去重(释放的溜溜球不再重复减CD)
}

-- 状态机轨迹 (轻量日志, 供未来排查时序问题; /DBSH debug 展示入口已随清理移除, 保留记录以备后用)
local traceLog = {}
local function Trace(msg)
    traceLog[#traceLog + 1] = string.format("[%.0fs] %s", GetTime(), msg)
    if #traceLog > 20 then table.remove(traceLog, 1) end
end

-- 去重版: 连续相同消息只记一次 (每帧调用的路径用这个)
local function TraceOnce(msg)
    local last = traceLog[#traceLog]
    if not last or last:sub(-#msg) ~= msg then Trace(msg) end
end

-- 静滞激活 (第一次按: 进入 STORING 存技能, 此时不进CD)
local function OnStasisStore()
    stasisState.phase = "STORING"
    stasisState.activeStartTime = GetTime()
    stasisState.armedStartTime = 0
    stasisState.cooldownEndTime = 0
    stasisState.sawStasisAura = false
    stasisState.storedCount = 0   -- 重置存技能计数
    stasisState.storedTemporalAnomalies = 0  -- 重置溜溜球计数 (v1.20)
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
    stasisState.sawStasisAura = true
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
            openingQueue = {}
            openingQueueEndTime = 0
            openingLastIndex = 0
            Trace("STORING 30s超时未存满3技能 -> READY (静滞失败)")
        end
    elseif stasisState.phase == "ARMED" then
        -- 30s 待释放窗口: 释放(再按370537, 事件里切COOLDOWN) 或 30s超时自动释放
        -- 30s超时: 用本地计时检测 (armedStartTime + 30s)
        if GetTime() - stasisState.armedStartTime > 30 then
            stasisState.phase = "COOLDOWN"
            Trace("ARMED 30s超时未释放 -> COOLDOWN (自动释放)")
        end
    elseif stasisState.phase == "COOLDOWN" then
        local remaining = stasisState.cooldownEndTime - GetTime()
        if remaining <= 0 then
            stasisState.phase = "READY"
            stasisState.sawStasisAura = false
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

-- 当玩家施放绿喷时累加计数
local function OnDreamBreathCast()
    usageCounter.used = (usageCounter.used or 0) + 1
    ChargeModelConsume()   -- 本地充能模型同步扣层 (战斗中这是唯一层数来源)
    Trace("绿喷施放(模型扣层), 累计=" .. usageCounter.used)
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

-- 静滞打开阶段是否仍激活 (用于判断 STASIS_OPENING 状态)
local function IsOpeningActive()
    -- 整个打开阶段(0-15秒) 都视为 active, 不只是队列窗口的 0-6s
    -- 否则 6s 一到, 队列结束, IsOpeningActive 返回 false, 会跳到主判断, 看不到心灵之火阶段
    return (stasisState.openingTotalEndTime or 0) > 0
       and GetTime() < (stasisState.openingTotalEndTime or 0)
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
    -- 1. 职业检查
    if not IsFlameshaperPreservation() then
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
    local hasAura = HasAura(STASIS_ACTIVE_AURA_ID)

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
        local stasisRemaining = GetStasisCDRemaining()
        local state, data = EvaluateCoreStasis(dreamInfo, stasisRemaining)
        data.message = data.message .. " (静滞可释放)"
        return state, data
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
        stasisState.sawStasisAura = false
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
    stasisInfo = { remaining = stasisRemaining, total = STASIS_COOLDOWN_DURATION, onCooldown = true }
    return EvaluateCoreStasis(dreamInfo, stasisRemaining)
end

--==========================================================================
-- UI 创建
--==========================================================================

local frame, statusText, dataText1, dataText2, counterText
local border, indicator
-- 静滞打开阶段的图标队列 (3个槽位: 绿喷·绿喷·时空畸体)
-- queueIcons/Labels 表上移到 file-scope 早期, 这样后面定义的 UpdateUI 能用到
local queueIcons = {}      -- { [1]=texture, [2]=texture, [3]=texture }
local queueLabels = {}     -- { [1]=fontstring, [2]=fontstring, [3]=fontstring }

-- 心灵之火 (7-15s 阶段): 大图标 + "剩余X秒" 文字
local innerfireIcon       -- 心灵之火图标 Texture
local innerfireLabel      -- "剩余X.X秒" 文字 FontString

-- 前向声明(让 UpdateUI 可以安全调用)
local UpdateQueueIcons
local HideQueueIcons
local UpdateInnerfire
local HideInnerfire

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
    -- 高度: 100(主判断) + 44(图标队列区)
    frame:SetSize(260, 144)
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
    -- 用 CENTER 锚点水平居中, 避开 TOPLEFT 锚点的 y 方向混淆
    -- 3*48 + 2*24间距 = 192, 间距72; frame 宽260居中足够
    for i = 1, 3 do
        local xOffset = (i - 2) * 72  -- i=1:-72, i=2:0, i=3:+72
        -- 图标 Texture
        local icon = frame:CreateTexture(nil, "ARTWORK")
        icon:SetSize(48, 48)
        icon:SetPoint("CENTER", frame, "CENTER", xOffset, 10)
        icon:Hide()
        queueIcons[i] = icon
        -- 图标下方标签 (顺序号 / 已用提示)
        local label = frame:CreateFontString(nil, "OVERLAY")
        label:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
        label:SetPoint("TOP", icon, "BOTTOM", 0, -2)
        label:SetTextColor(COLOR.SUBTEXT.r, COLOR.SUBTEXT.g, COLOR.SUBTEXT.b)
        label:Hide()
        queueLabels[i] = label
    end

    -- ===== 心灵之火 (7-15s 阶段) =====
    -- 大图标(60x60, 跟绿喷那个差不多大) + 右侧"剩余X秒"文字
    innerfireIcon = frame:CreateTexture(nil, "ARTWORK")
    innerfireIcon:SetSize(60, 60)
    innerfireIcon:SetPoint("CENTER", frame, "CENTER", -36, 0)  -- 偏左, 让位置给右侧文字
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
local function UpdateUI()
    if not frame then return end

    if not db.enabled then
        frame:Hide()
        return
    end
    frame:Show()

    local state, data = EvaluateState()

    -- 默认数据兜底
    data = data or {}
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
    if state ~= STATE.STASIS_OPENING then
        HideQueueIcons()
        HideInnerfire()
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
            -- 渲染队列图标 (居中大图标)
            UpdateQueueIcons(data.queue, data.usedIndex)
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
    dataText1:SetText(line1)
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
FSH:RegisterEvent("SPELL_UPDATE_COOLDOWN")
FSH:RegisterEvent("PLAYER_TALENT_UPDATE")
FSH:RegisterEvent("CHARACTER_POINTS_CHANGED")
FSH:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
FSH:RegisterEvent("PLAYER_REGEN_DISABLED")  -- 进战斗: 强制最后一次校准绿喷充能模型
FSH:RegisterEvent("PLAYER_REGEN_ENABLED")   -- 出战斗: 校准绿喷充能模型

-- 检测施法: UNIT_SPELLCAST_SUCCEEDED(普通施法,如时空畸体) + UNIT_SPELLCAST_EMPOWER_STOP(绿喷等empowered完成)
FSH:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
FSH:RegisterEvent("UNIT_SPELLCAST_EMPOWER_STOP")
FSH:RegisterEvent("UNIT_SPELLCAST_START")  -- 探针用: 记录第3技能施法开始时刻, 对比存满延迟

-- 高频刷新: 每帧调一次 (WoW 默认 ~60fps, 文字立即更新)
-- 用 pcall 防异常吞噬后续刷新 (这是过去 "CD卡死"的根因之一)
-- 前向声明: UpdateConfigDrag / CreateConfigPanel 定义在文件后面, 但闭包(OnUpdate/OnEvent/C_Timer)
-- 在这里引用它们, 必须在此处先 local 声明(否则闭包引用到的是全局变量, 报 nil)
local UpdateConfigDrag
local CreateConfigPanel
FSH:SetScript("OnUpdate", function(self, elapsed)
    -- 控制台滑块拖动 (独立于 db.enabled, 即使UI隐藏也能拖动)
    UpdateConfigDrag()
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
        -- 职业检查在 EvaluateState 里做, 这里不阻断
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
            SyncChargeModel(info)
            Trace(string.format("出战斗校准绿喷: 层数=%s/%s", tostring(chargeModel.currentCharges), tostring(chargeModel.maxCharges)))
        end
        if db then UpdateUI() end
        return
    end

    if event == "SPELL_UPDATE_COOLDOWN" then
        -- 充能/CD 变化: 若 API 可读(出战斗), 趁机校准绿喷充能模型
        local ok, info = pcall(function() return GetSpellChargeInfo(DREAM_BREATH_SPELL_ID) end)
        if ok and info and not info.secret then
            SyncChargeModel(info)
        end
        if db then UpdateUI() end
        return
    end

    if event == "UNIT_SPELLCAST_START" then
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
            end
            -- v1.20: 若在 STORING 阶段, 记录存入的溜溜球数 (释放时补算减CD)
            if stasisState.phase == "STORING" then
                stasisState.storedTemporalAnomalies = (stasisState.storedTemporalAnomalies or 0) + 1
            end
        end

        -- v1.29: 绿喷施放检测移到 SUCCEEDED (原在 EMPOWER_STOP, 但12.1战斗中 EMPOWER_STOP
        --   参数被加密只透出 unit, spellId=complete=nil, 导致绿喷计数/扣层/队列消费全失效)
        if DREAM_BREATH_IDS[spellId] then
            OnDreamBreathCast()
            ConsumeQueueItem("DREAM_BREATH")
        end

        -- v1.15 核心: STORING 阶段数白名单治疗技能, 存满3个 -> ARMED (进90s CD)
        -- 这是检测"静滞存满"的唯一可靠做法 (aura/CD数值战斗中全加密, 现成插件也这么干)
        -- v1.29: 去掉 not STASIS_EMPOWER_SPELLS 排除——绿喷/精神花等 empowered 技能战斗中
        --   EMPOWER_STOP 参数被加密计数不到, 统一改在 SUCCEEDED 里数 (SUCCEEDED 战斗中透出 spellId)
        if stasisState.phase == "STORING" and spellId
           and STASIS_STORABLE_SPELLS[spellId] then
            stasisState.storedCount = (stasisState.storedCount or 0) + 1
            if stasisState.storedCount == 3 then
                -- v1.25: 瞬发技能(活化烈焰/回响/逆转/焚身等)不触发 UNIT_SPELLCAST_START,
                --   thirdCastStartTime 会是 0(或已重置), 这里用当前时刻兜底锚定CD起算点
                if not stasisState.thirdCastStartTime or stasisState.thirdCastStartTime <= 0 then
                    stasisState.thirdCastStartTime = GetTime()
                end
            end
            Trace(string.format("静滞存入技能 %s, 已存%d/3", tostring(spellId), stasisState.storedCount))
        end
        -- 不 return: 让 OnUpdate 接管刷新
        return
    end

    if event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        -- v1.29: 此事件在 12.1 战斗中参数被加密(实机只透出 unit, spellID/complete 全 nil),
        --   绿喷计数/扣层/队列消费已统一迁移到 UNIT_SPELLCAST_SUCCEEDED (那里战斗中透出 spellId)。
        --   这里保留事件监听但不再做任何绿喷逻辑, 避免战斗外 EMPOWER_STOP 参数完整时重复计数。
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
local function RefreshConfigPanel()
    if not configFrame then return end
    -- UI 开关按钮文字
    if configToggleText then
        configToggleText:SetText(db.enabled and "UI: 显示中" or "UI: 已隐藏")
        configToggleText:SetTextColor(db.enabled and 0.22 or 0.8,
                                      db.enabled and 0.78 or 0.8,
                                      db.enabled and 0.33 or 0.8)
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
        db.enabled = not db.enabled
        if db.enabled and frame then frame:Show() end
        if not db.enabled and frame then frame:Hide() end
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
        db.enabled = not db.enabled
        if db.enabled and frame then frame:Show() end
        if not db.enabled and frame then frame:Hide() end
        SaveDB()
        print("|cFF7F77DD[绿喷管家]|r " .. (db.enabled and "已显示" or "已隐藏"))
    elseif cmd == "recharge" then
        local v = tonumber(args[2] or "")
        if v and v >= 0 then
            db.customRecharge = (v > 0) and v or nil
            SaveDB()
            print("|cFF7F77DD[绿喷管家]|r 绿喷充能时间: " .. (db.customRecharge and (db.customRecharge.."秒(手动)") or "自动"))
        else
            print("|cFF7F77DD[绿喷管家]|r 用法: /DBSH recharge 30 (0=自动)")
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
    Constants = {
        DREAM_BREATH_SPELL_ID = DREAM_BREATH_SPELL_ID,
        STASIS_SPELL_ID = STASIS_SPELL_ID,
        STASIS_ACTIVE_AURA_ID = STASIS_ACTIVE_AURA_ID,
    },
}
