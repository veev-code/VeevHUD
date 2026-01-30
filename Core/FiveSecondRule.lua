--[[
    VeevHUD - Five Second Rule Tracker
    
    Tracks the "5-second rule" for mana regeneration:
    - When you spend mana, spirit-based regen is suppressed for 5 seconds
    - After 5 seconds of not spending mana, full spirit regen resumes
    
    This module provides the 5SR state that other modules can use:
    - ResourcePrediction uses it for mana prediction rates
    - ResourceBar uses it to show/hide the mana tick indicator
]]

local ADDON_NAME, addon = ...

local FiveSecondRule = {}
addon.FiveSecondRule = FiveSecondRule

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local POWER_TYPE_MANA = 0
local FIVE_SECOND_DURATION = 5.0

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

FiveSecondRule.lastManaCastTime = 0  -- When last mana-costing spell was cast
FiveSecondRule.lastSampleMana = 0    -- For detecting actual mana spent (vs free casts)
FiveSecondRule.registered = false    -- Whether we've registered events

-------------------------------------------------------------------------------
-- Event Registration
-------------------------------------------------------------------------------

function FiveSecondRule:Initialize()
    if self.registered then return end
    
    if not self.eventFrame then
        self.eventFrame = CreateFrame("Frame")
    end
    
    self.eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    self.eventFrame:SetScript("OnEvent", function(_, event, unit, _, spellID)
        if event == "UNIT_SPELLCAST_SUCCEEDED" and unit == "player" then
            FiveSecondRule:OnSpellCastSucceeded(spellID)
        end
    end)
    
    -- Initialize mana tracking
    self.lastSampleMana = UnitPower("player", POWER_TYPE_MANA)
    
    self.registered = true
end

function FiveSecondRule:OnSpellCastSucceeded(spellID)
    -- Only trigger 5SR if mana ACTUALLY decreased (handles free casts from procs)
    local currentMana = UnitPower("player", POWER_TYPE_MANA)
    
    if currentMana < self.lastSampleMana then
        self.lastManaCastTime = GetTime()
    end
end

-- Call this periodically to keep mana sample updated
function FiveSecondRule:UpdateManaSample()
    self:Initialize()
    self.lastSampleMana = UnitPower("player", POWER_TYPE_MANA)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

-- Check if currently inside the 5-second rule
-- Also detects if mana just decreased (cast happened but event hasn't fired yet)
function FiveSecondRule:IsActive()
    self:Initialize()
    
    -- Check if mana just decreased (handles race condition with UNIT_SPELLCAST_SUCCEEDED)
    local currentMana = UnitPower("player", POWER_TYPE_MANA)
    if currentMana < self.lastSampleMana then
        -- Mana decreased since last sample - we're definitely in 5SR now
        self.lastManaCastTime = GetTime()
        self.lastSampleMana = currentMana
    end
    
    if self.lastManaCastTime == 0 then
        return false  -- Never cast a mana spell
    end
    return (GetTime() - self.lastManaCastTime) < FIVE_SECOND_DURATION
end

-- Get time remaining in the 5-second rule (0 if outside)
function FiveSecondRule:GetTimeRemaining()
    -- Call IsActive first to ensure state is up to date
    if not self:IsActive() then
        return 0
    end
    local remaining = FIVE_SECOND_DURATION - (GetTime() - self.lastManaCastTime)
    return math.max(0, remaining)
end

-- Get time since last mana-costing spell was cast
function FiveSecondRule:GetTimeSinceLastCast()
    if self.lastManaCastTime == 0 then
        return 999  -- Never cast
    end
    return GetTime() - self.lastManaCastTime
end

-- Get the 5SR duration constant
function FiveSecondRule:GetDuration()
    return FIVE_SECOND_DURATION
end
