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
    
    self.playerGUID = UnitGUID("player")

    self.eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    -- Keep the mana sample fresh independently of which module drives
    -- per-frame sampling. Without this, lastSampleMana goes stale whenever
    -- per-frame sampling isn't running (e.g. shifted druids — the main bar's
    -- power type isn't MANA, so ResourceBar stops calling UpdateManaSample)
    -- and 5SR detection silently misses mana spends.
    self.eventFrame:RegisterEvent("UNIT_POWER_UPDATE")
    self.eventFrame:SetScript("OnEvent", function(_, event, unit, arg2, spellID)
        if event == "UNIT_SPELLCAST_SUCCEEDED" and unit == "player" then
            FiveSecondRule:OnSpellCastSucceeded(spellID)
        elseif event == "UNIT_POWER_UPDATE" and unit == "player" and arg2 == "MANA" then
            local currentMana = UnitPower("player", C.POWER_TYPE.MANA)
            if currentMana < FiveSecondRule.lastSampleMana then
                FiveSecondRule.lastManaCastTime = GetTime()
            end
            FiveSecondRule.lastSampleMana = currentMana
        end
    end)

    -- Initialize mana tracking
    self.lastSampleMana = UnitPower("player", C.POWER_TYPE.MANA)

    -- Track external mana gains (Insightful Earthstorm Diamond, potions, etc.)
    -- so tick detectors can filter them out
    if addon.Events then
        addon.Events:RegisterCLEU(self, "SPELL_ENERGIZE", function(self, subEvent, data)
            if data.destGUID ~= self.playerGUID then return end
            -- Suffix shape differs by client: modern = (amount, overEnergize,
            -- powerType, alternatePowerType), legacy = (amount, powerType)
            local amount = data.s1 or 0
            local powerType = data.s3 ~= nil and data.s3 or data.s2
            if powerType == 0 then  -- mana
                local now = GetTime()
                -- Reset if previous gain has expired, otherwise accumulate
                if now - self.pendingExternalGainTime > 0.5 then
                    self.pendingExternalGain = amount
                else
                    self.pendingExternalGain = self.pendingExternalGain + amount
                end
                self.pendingExternalGainTime = now
                self.pendingExternalConsumedAt = nil
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
    self.lastSampleMana = currentMana
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
-- Tick detectors should subtract this from observed mana increases, then call
-- ConsumePendingExternalGain once the gain has been matched against an
-- observed increase.
function FiveSecondRule:GetPendingExternalGain()
    -- Expired by consumption in an EARLIER frame (GetTime is frame-constant,
    -- so both tick detectors sampling in the same OnUpdate still see it)
    if self.pendingExternalConsumedAt and GetTime() > self.pendingExternalConsumedAt then
        return 0
    end
    if self.pendingExternalGainTime > 0 and (GetTime() - self.pendingExternalGainTime) <= 0.5 then
        return self.pendingExternalGain
    end
    return 0
end

-- Consume the pending external gain after a tick detector has matched it
-- against an observed mana increase. Without this, a REAL tick landing within
-- the 0.5s window after a proc computed (gained - pending) <= 0 and was
-- silently dropped — one missed tick per proc. Expiry is deferred to the next
-- frame so the other detector (same OnUpdate pass) still sees the amount.
function FiveSecondRule:ConsumePendingExternalGain()
    self.pendingExternalConsumedAt = GetTime()
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
