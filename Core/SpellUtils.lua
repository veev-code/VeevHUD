--[[
    VeevHUD - Spell Utilities
    Spell cooldowns, effective spell ID resolution, and spell power info
]]

local _, addon = ...

addon.Utils = addon.Utils or {}
local Utils = addon.Utils
local C = addon.Constants

-------------------------------------------------------------------------------
-- Spell Cooldown Utilities
-------------------------------------------------------------------------------

-- Get spell cooldown info
-- Returns: remaining, duration, enabled, startTime (actual API start time for SetCooldown)
function Utils:GetSpellCooldown(spellID)
    local start, duration, enabled
    
    -- Try by spell ID first
    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(spellID)
        if info then
            start = info.startTime
            duration = info.duration
            enabled = info.isEnabled
        end
    else
        start, duration, enabled = GetSpellCooldown(spellID)
    end

    -- If the ID query returned nothing at all, retry by spell name (rare API
    -- gap for a few abilities). start == 0 is the normal "ready" answer and
    -- must NOT trigger the fallback — that would pay GetSpellInfo plus a
    -- second GetSpellCooldown for every ready spell on every update tick.
    if start == nil and GetSpellInfo then
        local spellName = GetSpellInfo(spellID)
        if spellName then
            local nameStart, nameDuration, nameEnabled = GetSpellCooldown(spellName)
            if nameStart and nameStart > 0 then
                start, duration, enabled = nameStart, nameDuration, nameEnabled
            end
        end
    end

    if start and duration and start > 0 and duration > 0 then
        local remaining = (start + duration) - GetTime()
        -- Return remaining, duration, enabled, and the actual start time for SetCooldown
        return remaining > 0 and remaining or 0, duration, true, start
    end

    return 0, 0, enabled ~= 0, 0
end

-- Check if ability is on a real cooldown (not just GCD)
-- Returns true if remaining > 0 AND duration exceeds GCD threshold
function Utils:IsOnRealCooldown(remaining, duration)
    return remaining and remaining > 0 and duration and duration > C.GCD_THRESHOLD
end

-- Check if ability is only on GCD (not a real cooldown)
-- Returns true if remaining > 0 but duration is at or below GCD threshold
function Utils:IsOnGCD(remaining, duration)
    return remaining and remaining > 0 and duration and duration <= C.GCD_THRESHOLD
end

-- Check if ability is off cooldown (ready to use, ignoring GCD)
-- Returns true if not on cooldown, OR only on GCD
function Utils:IsOffCooldown(remaining, duration)
    return not remaining or remaining <= 0 or not duration or duration <= C.GCD_THRESHOLD
end

-- Convenience variants that take spellID directly (for when you only need the boolean)
-- Use these when you don't need the remaining/duration values for other purposes

function Utils:IsSpellOnRealCooldown(spellID)
    local remaining, duration = self:GetSpellCooldown(spellID)
    return self:IsOnRealCooldown(remaining, duration)
end

function Utils:IsSpellOnGCD(spellID)
    local remaining, duration = self:GetSpellCooldown(spellID)
    return self:IsOnGCD(remaining, duration)
end

function Utils:IsSpellOffCooldown(spellID)
    local remaining, duration = self:GetSpellCooldown(spellID)
    return self:IsOffCooldown(remaining, duration)
end

-- Get spell texture/icon
function Utils:GetSpellTexture(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID)
    elseif GetSpellTexture then
        return GetSpellTexture(spellID)
    end
    return nil
end

-------------------------------------------------------------------------------
-- Effective Spell ID Resolution (with caching)
-- Determines the actual spell rank to use for costs, based on action bar placement
-------------------------------------------------------------------------------

-- Cache for effective spell IDs
Utils.effectiveSpellCache = {}

-- Find if any rank of a spell is on the player's action bars
-- Returns the spell ID found on action bar, or nil if not found
function Utils:FindSpellOnActionBar(spellID)
    local LibSpellDB = LibStub and LibStub("LibSpellDB-1.0", true)
    if not LibSpellDB then return nil end

    local rankSet = LibSpellDB:GetAllRankIDs(spellID)

    -- Scan all action bar slots (1-120 covers all bars)
    for slot = 1, 120 do
        local actionType, id, subType = GetActionInfo(slot)
        if actionType == "spell" and id then
            if rankSet[id] then
                return id
            end
        end
    end

    return nil
end

-- Find an action bar slot for an item-cooldown spell (Soulstone, Healthstone).
-- Active-CD slot wins; otherwise a type/ID match wins over a texture-only match
-- (texture catches consumed items whose GetActionInfo no longer reports the ID).
function Utils:FindActionBarSlotForSpellOrItem(spellID, spellData)
    local LibSpellDB = LibStub and LibStub("LibSpellDB-1.0", true)
    if not LibSpellDB then return nil end

    local rankSet = LibSpellDB:GetAllRankIDs(spellID)

    local itemSet
    if spellData and spellData.cooldownItemIDs then
        itemSet = {}
        for _, id in ipairs(spellData.cooldownItemIDs) do
            itemSet[id] = true
        end
    end

    local textures = {}
    local spellTexture = self:GetSpellTexture(spellID)
    if spellTexture then textures[spellTexture] = true end
    if spellData and spellData.cooldownItemIDs then
        for _, itemID in ipairs(spellData.cooldownItemIDs) do
            local itemTexture = GetItemIcon(itemID)
            if itemTexture then textures[itemTexture] = true end
        end
    end

    local primaryFallback, textureFallback
    for slot = 1, 120 do
        local actionType, id = GetActionInfo(slot)
        local primaryMatch = (actionType == "spell" and id and rankSet and rankSet[id])
            or (actionType == "item" and id and itemSet and itemSet[id])

        local textureMatch = false
        if not primaryMatch and HasAction(slot) then
            local texture = GetActionTexture(slot)
            textureMatch = texture and textures[texture] or false
        end

        if primaryMatch or textureMatch then
            local start, dur = GetActionCooldown(slot)
            if start and start > 0 and dur > C.GCD_THRESHOLD then
                return slot
            end
            if primaryMatch then
                primaryFallback = primaryFallback or slot
            else
                textureFallback = textureFallback or slot
            end
        end
    end

    return primaryFallback or textureFallback
end

-- Ensure the cache invalidation event frame is set up (lazy initialization)
function Utils:EnsureCacheInitialized()
    if self.effectiveSpellCacheFrame then return end
    
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
    frame:RegisterEvent("PLAYER_LEVEL_UP")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("SPELLS_CHANGED")
    frame:RegisterEvent("CHARACTER_POINTS_CHANGED")  -- Talent changes (TBC)
    
    frame:SetScript("OnEvent", function(eventFrame, event, ...)
        Utils:InvalidateEffectiveSpellCache()
    end)
    
    self.effectiveSpellCacheFrame = frame
end

-- Invalidate the effective spell cache
-- Called when action bars or spells change
function Utils:InvalidateEffectiveSpellCache()
    wipe(self.effectiveSpellCache)
end

-- Get the effective spell ID for a spell, with caching
-- Priority: 1) Spell rank on action bar, 2) Highest known rank
function Utils:GetEffectiveSpellID(spellID)
    -- Lazy initialize the cache event frame
    self:EnsureCacheInitialized()
    
    local LibSpellDB = LibStub and LibStub("LibSpellDB-1.0", true)
    if not LibSpellDB then return spellID end
    
    local canonicalID = LibSpellDB:GetCanonicalSpellID(spellID) or spellID
    
    -- Check cache first
    local cached = self.effectiveSpellCache[canonicalID]
    if cached then
        return cached
    end
    
    -- Not cached, compute it
    local result
    
    -- First, check if any rank is on the action bar
    local actionBarSpellID = self:FindSpellOnActionBar(spellID)
    if actionBarSpellID then
        result = actionBarSpellID
    else
        -- Fallback to highest known rank from LibSpellDB
        result = LibSpellDB:GetHighestKnownRank(spellID)
    end
    
    -- Cache and return
    self.effectiveSpellCache[canonicalID] = result
    return result
end

-------------------------------------------------------------------------------
-- Spell Power Info
-------------------------------------------------------------------------------

-- Static power color tables. GetSpellPowerInfo runs per icon per update tick,
-- so colors are resolved once per power type and reused. Returned tables are
-- read-only by contract.
local POWER_COLOR_FALLBACK = {
    [0] = {0, 0.5, 1},      -- Mana
    [1] = {1, 0, 0},        -- Rage
    [2] = {1, 0.5, 0.25},   -- Focus
    [3] = {1, 1, 0},        -- Energy
    [6] = {0, 0.82, 1},     -- Runic Power
}
local POWER_COLOR_DEFAULT = {1, 1, 1}
local powerColorCache = {}  -- powerType -> {r, g, b} resolved from PowerBarColor

-- Get spell power cost and current power
-- Returns: cost, currentPower, maxPower, powerType, powerColor (read-only table)
function Utils:GetSpellPowerInfo(spellID)
    local cost = 0
    local powerType = nil
    
    -- Get effective spell ID: action bar rank first, then highest known rank
    local effectiveSpellID = self:GetEffectiveSpellID(spellID)
    
    -- Try to get power cost from spell info
    if GetSpellPowerCost then
        local costTable = GetSpellPowerCost(effectiveSpellID)
        if costTable and costTable[1] then
            cost = costTable[1].cost or 0
            powerType = costTable[1].type
        end
    end
    
    -- If no cost found, spell is free
    if cost == 0 then
        return 0, 0, 0, nil, nil
    end
    
    -- Get current and max power for that power type
    local currentPower = UnitPower("player", powerType) or 0
    local maxPower = UnitPowerMax("player", powerType) or 1
    
    -- Get power color (cached per power type; PowerBarColor is static)
    local powerColor = powerType ~= nil and powerColorCache[powerType]
    if not powerColor then
        local powerInfo = PowerBarColor[powerType]
        if powerInfo then
            powerColor = {powerInfo.r or 1, powerInfo.g or 1, powerInfo.b or 1}
        else
            powerColor = POWER_COLOR_FALLBACK[powerType] or POWER_COLOR_DEFAULT
        end
        if powerType ~= nil then
            powerColorCache[powerType] = powerColor
        end
    end

    return cost, currentPower, maxPower, powerType, powerColor
end
