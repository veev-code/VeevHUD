--[[
    VeevHUD - Swing Bar Hunter Strategy
    Hunter-specific: ranged clip zones (green/yellow/red), auto-shot tracking,
    Feign Death penalty, movement cancel detection, melee weaving support.

    Loaded before SwingBar.lua. Registers as addon.SwingBarStrategies.HUNTER.
]]

local _, addon = ...
addon.SwingBarStrategies = addon.SwingBarStrategies or {}

local GetTime = GetTime
local GetUnitSpeed = GetUnitSpeed
local UnitRangedDamage = UnitRangedDamage
local GetInventoryItemID = GetInventoryItemID
local math_max = math.max

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local AUTO_SHOT_ID = 75

-- Feign Death and Trueshot Aura reset ranged timer with +0.15s penalty
local FEIGN_DEATH_ID = 5384
local TRUESHOT_AURA_IDS = { [19506] = true, [20905] = true, [20906] = true }

-- Base auto-shot animation time (seconds)
local AUTO_CAST_TIME_BASE = 0.52

-- Client re-queue delay when auto-shot fails to fire (out of range, LoS, etc.)
local AUTO_SHOT_FAIL_DELAY = 0.5

-- Ranged clip zone thresholds (base values, before haste scaling).
-- Both cast time and weapon speed scale by the same haste factor, so boundary
-- fractions use base (unhasted) values and remain constant.
local STEADY_SHOT_CAST_TIME = 1.5   -- Yellow boundary: Steady Shot would clip
local RED_ZONE_THRESHOLD = 0.52     -- Red boundary: max(Multi-Shot 0.5s, auto-shot animation 0.52s)

-------------------------------------------------------------------------------
-- Tooltip scanning for unhasted base weapon speed
-------------------------------------------------------------------------------

local baseSpeedCache = {}  -- [itemID] = baseSpeed
local baseSpeedTooltip     -- lazily created scanning tooltip
local SPEED_PATTERN        -- "Speed X.XX" pattern, built from global SPEED string

local function UpdateRangedBaseSpeed(sb)
    local itemID = GetInventoryItemID("player", INVSLOT_RANGED)
    if not itemID then
        sb.rangedBaseSpeed = 0
        return
    end

    -- Return cached value if we've seen this weapon before
    if baseSpeedCache[itemID] then
        sb.rangedBaseSpeed = baseSpeedCache[itemID]
        return
    end

    -- Lazy-create the scanning tooltip
    if not baseSpeedTooltip then
        baseSpeedTooltip = CreateFrame("GameTooltip", "VeevHUDBaseSpeedTip", nil, "GameTooltipTemplate")
        baseSpeedTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
        -- Accept both "." and "," decimal separators — frFR/deDE render
        -- weapon speed as e.g. "3,80" and the dot-only pattern never matched
        SPEED_PATTERN = SPEED .. " (%d+[%.,]%d+)"
    end

    baseSpeedTooltip:ClearLines()
    baseSpeedTooltip:SetItemByID(itemID)

    local speed = 0
    for i = 1, baseSpeedTooltip:NumLines() do
        local fontString = _G["VeevHUDBaseSpeedTipTextRight" .. i]
        local text = fontString and fontString:GetText()
        if text then
            local match = text:match(SPEED_PATTERN)
            if match then
                speed = tonumber((match:gsub(",", ".", 1)))
                break
            end
        end
    end

    if speed and speed > 0 then
        baseSpeedCache[itemID] = speed
        sb.rangedBaseSpeed = speed
    end
end

-------------------------------------------------------------------------------
-- Internal helpers
-------------------------------------------------------------------------------

-- Compute current auto-shot animation time (scales with haste)
local function GetAutoCastTime(sb)
    if sb.rangedBaseSpeed > 0 and sb.rangedSpeed > 0 then
        return AUTO_CAST_TIME_BASE * (sb.rangedSpeed / sb.rangedBaseSpeed)
    end
    return AUTO_CAST_TIME_BASE
end

-- Reset ranged timer based on elapsed time since last shot
local function ResetRangedTimer(sb)
    local now = GetTime()
    local autoCastTime = GetAutoCastTime(sb)
    local elapsed = now - sb.lastShotTime

    if elapsed > (sb.rangedSpeed - autoCastTime) then
        sb.rangedTimer = autoCastTime
    elseif elapsed > 0 then
        sb.rangedTimer = sb.rangedSpeed - elapsed
    else
        sb.rangedTimer = sb.rangedSpeed
    end
    sb:OnSwingEvent()
end

-- Feign Death adds +0.15s penalty to ranged speed and resets timer.
local function ApplyFeignDeathReset(sb)
    sb.lastShotTime = GetTime()
    if sb.feignPenalty == 0 then
        sb.feignPenalty = 0.15
        local speed = UnitRangedDamage("player")
        if speed and speed > 0 then
            sb.rangedSpeed = speed + sb.feignPenalty
        end
    end
    ResetRangedTimer(sb)
end

-- Auto-shot failed to fire (out of range, LoS, etc.)
local function OnSpellCastFailedQuiet(sb, event, unit, castGUID, spellID)
    if unit ~= "player" then return end
    if spellID ~= AUTO_SHOT_ID then return end
    if not sb.autoRepeatActive then return end

    local now = GetTime()
    sb.lastRetryTime = now

    local isMoving = GetUnitSpeed("player") > 0
    if addon.db.profile.debugMode then
        sb.Utils:LogDebug("SwingBar", string.format(
            "FAILED_QUIET moving=%s rangedTimer=%.3f timeSinceShot=%.3f timeSinceStop=%.3f",
            tostring(isMoving), sb.rangedTimer, now - sb.lastShotTime,
            sb.moveStopTime and (now - sb.moveStopTime) or -1))
    end

    if isMoving then return end

    local autoCastTime = GetAutoCastTime(sb)
    local timeSinceShot = now - sb.lastShotTime
    if timeSinceShot > (sb.rangedSpeed - autoCastTime) then
        sb.rangedTimer = autoCastTime + AUTO_SHOT_FAIL_DELAY
    end
end

-------------------------------------------------------------------------------
-- Strategy
-------------------------------------------------------------------------------

local Hunter = {}
addon.SwingBarStrategies.HUNTER = Hunter

function Hunter:OnInitialize(sb)
    -- State fields
    sb.rangedBaseSpeed = 0
    sb.lastShotTime = 0
    sb.feignStatus = false
    sb.feignPenalty = 0
    sb.lastRetryTime = 0
    sb.wasMoving = false
    sb.moveStopTime = nil
    sb.knowsSteadyShot = false

    -- Register hunter-specific events.
    -- NOTE: Events.lua invokes callbacks as callback(owner, event, ...) — the
    -- leading owner parameter is required on anonymous closures.
    sb.Events:RegisterEvent(sb, "UNIT_SPELLCAST_FAILED_QUIET", function(owner, event, unit, castGUID, spellID)
        OnSpellCastFailedQuiet(sb, event, unit, castGUID, spellID)
    end)

    -- Detect jumping out of Feign Death
    hooksecurefunc("JumpOrAscendStart", function()
        if sb.feignStatus then
            ApplyFeignDeathReset(sb)
            sb.feignStatus = false
        end
    end)

    UpdateRangedBaseSpeed(sb)
end

function Hunter:OnUpdateSpecFeatures(sb)
    sb.knowsSteadyShot = IsPlayerSpell(34120) -- Steady Shot
end

function Hunter:OnPlayerEnteringWorld(sb)
    UpdateRangedBaseSpeed(sb)
    sb.feignStatus = false
    sb.feignPenalty = 0
    sb.lastRetryTime = 0
    sb.wasMoving = false
end

function Hunter:OnSpellCastSucceeded(sb, spellID)
    -- Feign Death / Trueshot Aura: reset ranged timer with penalty
    if spellID == FEIGN_DEATH_ID or TRUESHOT_AURA_IDS[spellID] then
        if spellID == FEIGN_DEATH_ID then
            sb.feignStatus = true
        end
        ApplyFeignDeathReset(sb)
        return true
    end

    -- Auto Shot completed: reset ranged timer
    if spellID == AUTO_SHOT_ID then
        local now = GetTime()
        if addon.db.profile.debugMode and sb.moveStopTime then
            sb.Utils:LogDebug("SwingBar", string.format(
                "AUTO_SHOT_FIRED delaySinceStop=%.3f timeSinceLastShot=%.3f speed=%.3f autoCast=%.3f",
                now - sb.moveStopTime, now - sb.lastShotTime, sb.rangedSpeed, GetAutoCastTime(sb)))
            sb.moveStopTime = nil
        end
        sb.feignPenalty = 0
        sb.lastRetryTime = 0
        sb:UpdateWeaponSpeeds()
        if sb.rangedSpeed > 0 then
            sb.rangedTimer = sb.rangedSpeed
            sb.lastShotTime = now
            sb:OnSwingEvent()
        end
        return true
    end

    -- Cast-time shots that reset the auto-shot swing (Aimed Shot — tagged
    -- RANGED_RESET in LibSpellDB). Without this, the clip zones display a
    -- stale timer during and after the cast until the next real Auto Shot.
    if addon.LibSpellDB and addon.LibSpellDB:HasTag(spellID, "RANGED_RESET") then
        sb:UpdateWeaponSpeeds()
        if sb.rangedSpeed > 0 then
            sb.rangedTimer = sb.rangedSpeed
            sb.lastShotTime = GetTime()
            sb:OnSwingEvent()
        end
        return true
    end

    return false
end

function Hunter:OnPreUpdate(sb, dt, db)
    if not sb.feignStatus and not sb.autoRepeatActive then return end

    local isMoving = GetUnitSpeed("player") > 0

    -- Moving out of Feign Death: resume auto-shot with penalty
    if sb.feignStatus and isMoving then
        ApplyFeignDeathReset(sb)
        sb.feignStatus = false
    end

    -- Track movement transitions and adjust timer on stop
    if sb.autoRepeatActive then
        local autoCastTime = GetAutoCastTime(sb)
        local debugMode = addon.db.profile.debugMode

        if isMoving and not sb.wasMoving then
            if debugMode then
                sb.Utils:LogDebug("SwingBar", string.format(
                    "MOVE_START rangedTimer=%.3f autoCast=%.3f speed=%.3f timeSinceShot=%.3f",
                    sb.rangedTimer, autoCastTime, sb.rangedSpeed,
                    GetTime() - sb.lastShotTime))
            end
        elseif not isMoving and sb.wasMoving then
            local now = GetTime()
            if debugMode then sb.moveStopTime = now end
            if sb.rangedTimer <= autoCastTime and sb.lastRetryTime > 0 then
                local timeUntilNextRetry = math_max(0, (sb.lastRetryTime + AUTO_SHOT_FAIL_DELAY) - now)
                sb.rangedTimer = timeUntilNextRetry + autoCastTime
            elseif sb.rangedTimer <= autoCastTime then
                sb.rangedTimer = autoCastTime + AUTO_SHOT_FAIL_DELAY
            end
            if debugMode then
                sb.Utils:LogDebug("SwingBar", string.format(
                    "MOVE_STOP rangedTimer=%.3f autoCast=%.3f speed=%.3f lastRetry=%.3f",
                    sb.rangedTimer, autoCastTime, sb.rangedSpeed,
                    sb.lastRetryTime > 0 and (now - sb.lastRetryTime) or -1))
            end
        end
        sb.wasMoving = isMoving

        -- Moving during auto-shot cast phase: pin at cast boundary
        if isMoving and sb.rangedTimer > 0 and sb.rangedTimer <= autoCastTime then
            sb.rangedTimer = autoCastTime
        end
    end
end

function Hunter:UpdateZoneMarkers(sb, bar, db)
    if not sb.isRanged or not sb.autoRepeatActive or not db.enableClipZones then return false end

    local barWidth = db.width
    local baseSpeed = sb.rangedBaseSpeed > 0 and sb.rangedBaseSpeed or sb.rangedSpeed

    if baseSpeed > 0 then
        local redBoundary = 1.0 - (RED_ZONE_THRESHOLD / baseSpeed)
        if redBoundary < 0 then redBoundary = 0 end

        if sb.knowsSteadyShot then
            local steadyBoundary = 1.0 - (STEADY_SHOT_CAST_TIME / baseSpeed)
            if steadyBoundary < 0 then steadyBoundary = 0 end

            sb:EnsureZoneTextures(bar, 2)
            sb:SetZoneSegment(bar, 1, steadyBoundary, redBoundary, db.cautionColor, barWidth, db.zoneAlpha)
            sb:SetZoneSegment(bar, 2, redBoundary, 1.0, db.dangerColor, barWidth, db.zoneAlpha)
        else
            sb:EnsureZoneTextures(bar, 1)
            sb:SetZoneSegment(bar, 1, redBoundary, 1.0, db.dangerColor, barWidth, db.zoneAlpha)
        end
    else
        sb:EnsureZoneTextures(bar, 0)
    end
    return true
end

function Hunter:GetFillColor(sb, progress, isOffHand, db)
    if not sb.isRanged or not sb.autoRepeatActive or sb.rangedSpeed <= 0 or not db.enableClipZones then
        return nil
    end

    local baseSpeed = sb.rangedBaseSpeed > 0 and sb.rangedBaseSpeed or sb.rangedSpeed
    local redBoundary = 1.0 - (RED_ZONE_THRESHOLD / baseSpeed)
    if redBoundary < 0 then redBoundary = 0 end

    if sb.knowsSteadyShot then
        local steadyBoundary = 1.0 - (STEADY_SHOT_CAST_TIME / baseSpeed)
        if steadyBoundary < 0 then steadyBoundary = 0 end

        if progress < steadyBoundary then return db.safeColor
        elseif progress < redBoundary then return db.cautionColor
        else return db.dangerColor end
    else
        if progress < redBoundary then return db.safeColor
        else return db.dangerColor end
    end
end

function Hunter:GetActiveTimerOverride(sb, db)
    if db.enableMeleeWeaving then
        return ((sb.rangedTimer > 0) and sb.autoRepeatActive) or (sb.mainTimer > 0)
    end
    return nil
end

function Hunter:OnAutoRepeatStart(sb)
    if not addon.db.profile.swingBar.enableMeleeWeaving then
        sb.isRanged = true
        sb:ForceContainerResize()
        addon.Layout:Refresh()
    end
end

function Hunter:OnAutoRepeatStop(sb)
    sb.wasMoving = false
    if not addon.db.profile.swingBar.enableMeleeWeaving then
        sb.isRanged = false
        sb:UpdateWeaponSpeeds()
        sb:ForceContainerResize()
        addon.Layout:Refresh()
    end
end

function Hunter:OnInventoryChanged(sb)
    UpdateRangedBaseSpeed(sb)
end

function Hunter:OnRefresh(sb, db)
    if db.enableMeleeWeaving then
        sb.isRanged = true
    end
end
