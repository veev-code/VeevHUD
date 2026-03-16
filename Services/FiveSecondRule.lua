--[[
    VeevHUD - Five Second Rule Tracker
    
    Tracks the "5-second rule" for mana regeneration:
    - When you spend mana, spirit-based regen is suppressed for 5 seconds
    - After 5 seconds of not spending mana, full spirit regen resumes
    
    This service provides the 5SR state that other modules can use:
    - ResourcePrediction uses it for mana prediction rates
    - ResourceBar uses it to show/hide the mana tick indicator
]]

local _, addon = ...
local C = addon.Constants

local FiveSecondRule = {}
addon.FiveSecondRule = FiveSecondRule

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

FiveSecondRule.lastManaCastTime = 0  -- When last mana-costing spell was cast
FiveSecondRule.lastSampleMana = 0    -- For detecting actual mana spent (vs free casts)
FiveSecondRule.registered = false    -- Whether we've registered events

-- External mana gain tracking (Insightful Earthstorm Diamond, potions, etc.)
-- These gains arrive via SPELL_ENERGIZE and should not be counted as natural mana ticks
FiveSecondRule.pendingExternalGain = 0
FiveSecondRule.pendingExternalGainTime = 0

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
    self.lastSampleMana = UnitPower("player", C.POWER_TYPE.MANA)

    -- Track external mana gains (Insightful Earthstorm Diamond, potions, etc.)
    -- so tick detectors can filter them out
    if addon.Events then
        addon.Events:RegisterCLEU(self, "SPELL_ENERGIZE", function(self, subEvent, data)
            if data.destGUID ~= UnitGUID("player") then return end
            -- Extract suffix args: amount and powerType from end of CLEU data
            local info = {CombatLogGetCurrentEventInfo()}
            local n = #info
            local amount = info[n - 3] or 0
            local powerType = info[n - 1]
            if powerType == 0 then  -- POWER_TYPE_MANA
                local now = GetTime()
                -- Reset if previous gain has expired, otherwise accumulate
                if now - self.pendingExternalGainTime > 0.5 then
                    self.pendingExternalGain = amount
                else
                    self.pendingExternalGain = self.pendingExternalGain + amount
                end
                self.pendingExternalGainTime = now
            end
        end)
    end

    self.registered = true
end

function FiveSecondRule:OnSpellCastSucceeded(spellID)
    -- Only trigger 5SR if mana ACTUALLY decreased (handles free casts from procs)
    local currentMana = UnitPower("player", C.POWER_TYPE.MANA)
    
    if currentMana < self.lastSampleMana then
        self.lastManaCastTime = GetTime()
    end
end

-- Call this periodically to keep mana sample updated
function FiveSecondRule:UpdateManaSample()
    self:Initialize()
    self.lastSampleMana = UnitPower("player", C.POWER_TYPE.MANA)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

-- Check if currently inside the 5-second rule
-- Also detects if mana just decreased (cast happened but event hasn't fired yet)
function FiveSecondRule:IsActive()
    self:Initialize()
    
    -- Check if mana just decreased (handles race condition with UNIT_SPELLCAST_SUCCEEDED)
    local currentMana = UnitPower("player", C.POWER_TYPE.MANA)
    if currentMana < self.lastSampleMana then
        -- Mana decreased since last sample - we're definitely in 5SR now
        self.lastManaCastTime = GetTime()
        self.lastSampleMana = currentMana
    end
    
    if self.lastManaCastTime == 0 then
        return false  -- Never cast a mana spell
    end
    return (GetTime() - self.lastManaCastTime) < C.FIVE_SECOND_RULE_DURATION
end

-- Get pending external mana gain (from SPELL_ENERGIZE events like IED procs)
-- Returns the accumulated amount if recent (within 0.5s), otherwise 0
-- Tick detectors should subtract this from observed mana increases
function FiveSecondRule:GetPendingExternalGain()
    if self.pendingExternalGainTime > 0 and (GetTime() - self.pendingExternalGainTime) <= 0.5 then
        return self.pendingExternalGain
    end
    return 0
end

-- Get time remaining in the 5-second rule (0 if outside)
function FiveSecondRule:GetTimeRemaining()
    -- Call IsActive first to ensure state is up to date
    if not self:IsActive() then
        return 0
    end
    local remaining = C.FIVE_SECOND_RULE_DURATION - (GetTime() - self.lastManaCastTime)
    return math.max(0, remaining)
end
