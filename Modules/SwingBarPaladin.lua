--[[
    VeevHUD - Swing Bar Paladin Strategy
    Ret Paladin seal twist zones: prep (yellow) → twist (green) → impossible (red).

    Loaded before SwingBar.lua. Registers as addon.SwingBarStrategies.PALADIN.
]]

local _, addon = ...
addon.SwingBarStrategies = addon.SwingBarStrategies or {}

local GetTime = GetTime
local GetSpellCooldown = GetSpellCooldown
local GetSpellInfo = GetSpellInfo
local math_max = math.max
local C = addon.Constants

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

-- Seal twist window (seconds before swing to cast Blood)
local TWIST_WINDOW = 0.4

-- Standard Paladin GCD (no haste reduction in TBC)
local GCD_DURATION = 1.5

-- Reference spell for GCD polling: Seal of Righteousness (no cooldown, GCD-only)
local GCD_SPELL_ID = 20154

-- Seal of Command base spell ID (for twist prep detection via localized name)
local SEAL_OF_COMMAND_ID = 20375

-------------------------------------------------------------------------------
-- Strategy
-------------------------------------------------------------------------------

local Paladin = {}
addon.SwingBarStrategies.PALADIN = Paladin

function Paladin:OnInitialize(sb)
    sb.commandSealName = nil
    sb.hasCommandSeal = false
    sb.gcdRemaining = 0
    sb.twistImpossible = false
end

function Paladin:OnUpdateSpecFeatures(sb)
    sb.hasTwistWindow = (addon.playerClass == C.CLASS.PALADIN and addon.playerSpec == C.SPEC.RETRIBUTION)

    -- Resolve localized Seal of Command name (once) for twist prep detection
    if sb.hasTwistWindow and not sb.commandSealName then
        sb.commandSealName = GetSpellInfo(SEAL_OF_COMMAND_ID)
    end
end

function Paladin:UpdateZoneMarkers(sb, bar, db)
    if not sb.hasTwistWindow or not db.enableTwistWindow then return false end

    local barWidth = db.width

    if sb.mainSpeed > 0 then
        local twistThreshold = 1.0 - (TWIST_WINDOW / sb.mainSpeed)
        if twistThreshold < 0 then twistThreshold = 0 end

        local prepThreshold = 1.0 - ((TWIST_WINDOW + GCD_DURATION) / sb.mainSpeed)
        if prepThreshold < 0 then prepThreshold = 0 end

        sb:EnsureZoneTextures(bar, 2)
        sb:SetZoneSegment(bar, 1, prepThreshold, twistThreshold, db.cautionColor, barWidth, db.zoneAlpha)
        sb:SetZoneSegment(bar, 2, twistThreshold, 1.0, db.safeColor, barWidth, db.zoneAlpha)
    else
        sb:EnsureZoneTextures(bar, 0)
    end
    return true
end

function Paladin:GetFillColor(sb, progress, isOffHand, db)
    if not sb.hasTwistWindow or sb.mainSpeed <= 0 or not db.enableTwistWindow then return nil end

    -- Sticky impossible flag: once set, bar stays red until next swing cycle
    if sb.twistImpossible then
        return db.dangerColor
    end

    local twistThreshold = 1.0 - (TWIST_WINDOW / sb.mainSpeed)
    if twistThreshold < 0 then twistThreshold = 0 end

    local prepThreshold = 1.0 - ((TWIST_WINDOW + GCD_DURATION) / sb.mainSpeed)
    if prepThreshold < 0 then prepThreshold = 0 end

    if progress >= prepThreshold then
        local timer = (1.0 - progress) * sb.mainSpeed

        -- GCD extends past the swing: can't cast anything before it lands
        if sb.gcdRemaining > 0 and sb.gcdRemaining >= timer then
            sb.twistImpossible = true
            return db.dangerColor
        end

        -- In twist zone without Command active: too late to prep
        if progress >= twistThreshold then
            if not sb.hasCommandSeal then
                sb.twistImpossible = true
                return db.dangerColor
            end
            return db.safeColor
        end

        -- In prep zone
        return db.cautionColor
    end

    return nil  -- Fall through to neutral
end

function Paladin:OnPostTimerUpdate(sb)
    if not sb.hasTwistWindow or sb.mainTimer <= 0 then return end

    -- GCD remaining via reference spell (Seal of Righteousness, no real cooldown)
    local start, duration = GetSpellCooldown(GCD_SPELL_ID)
    if start and start > 0 and duration > 0 and duration <= GCD_DURATION then
        sb.gcdRemaining = math_max(0, (start + duration) - GetTime())
    else
        sb.gcdRemaining = 0
    end

    -- Seal of Command active check
    if sb.commandSealName then
        sb.hasCommandSeal = addon.Utils:GetCachedBuff("player", SEAL_OF_COMMAND_ID, sb.commandSealName) ~= nil
    end
end

function Paladin:OnSwingReset(sb)
    sb.twistImpossible = false
end
