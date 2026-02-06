--[[
    VeevHUD - Range Checker
    Centralized spell range checking with throttled updates
    
    Provides efficient range detection for spell icons without aggressive polling.
    Uses a 0.1s throttle combined with event-driven updates on target changes.
    
    Key concepts:
    - IsSpellInRange returns true/false/nil (in range, out of range, no valid target)
    - Range checks are throttled to minimize performance impact
    - Immediate updates on PLAYER_TARGET_CHANGED for responsiveness
    - Only checks range when we have a valid target
]]

local ADDON_NAME, addon = ...

local RangeChecker = {}
addon.RangeChecker = RangeChecker

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------

local RANGE_CHECK_INTERVAL = 0.1  -- Throttle interval for continuous range checking

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

RangeChecker.callbacks = {}  -- Registered callbacks for range updates

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function RangeChecker:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    
    -- Register for target changes (immediate range update)
    self.Events:RegisterEvent(self, "PLAYER_TARGET_CHANGED", self.OnTargetChanged)
    
    -- Register throttled update for continuous range checking
    self.Events:RegisterUpdate(self, RANGE_CHECK_INTERVAL, self.OnRangeUpdate)
    
    self.Utils:LogDebug("RangeChecker initialized")
end

-------------------------------------------------------------------------------
-- Event Handlers
-------------------------------------------------------------------------------

function RangeChecker:OnTargetChanged()
    self:NotifyCallbacks()
end

function RangeChecker:OnRangeUpdate()
    -- Skip if no target (no range checks needed)
    if not UnitExists("target") then
        return
    end
    
    self:NotifyCallbacks()
end

-------------------------------------------------------------------------------
-- Callback Registration
-------------------------------------------------------------------------------

-- Register a callback to be notified when range should be rechecked
function RangeChecker:RegisterCallback(owner, callback)
    self.callbacks[owner] = callback
end

-- Notify all registered callbacks
function RangeChecker:NotifyCallbacks()
    for owner, callback in pairs(self.callbacks) do
        local success, err = pcall(callback, owner)
        if not success then
            self.Utils:LogError("RangeChecker callback error:", tostring(err))
        end
    end
end

-------------------------------------------------------------------------------
-- Range Checking API
-------------------------------------------------------------------------------

-- Check if a spell is in range of a unit
-- Returns: true (in range), false (out of range), nil (no valid target or spell has no range)
function RangeChecker:IsSpellInRange(spellID, unit)
    unit = unit or "target"
    
    -- No target means no range check needed
    if not UnitExists(unit) then
        return nil
    end
    
    -- Get the effective spell ID for API calls
    local Utils = self.Utils or addon.Utils
    local effectiveSpellID = Utils:GetEffectiveSpellID(spellID)
    
    -- Try C_Spell.IsSpellInRange first (TWW+)
    if C_Spell and C_Spell.IsSpellInRange then
        local result = C_Spell.IsSpellInRange(effectiveSpellID, unit)
        return result
    end
    
    -- Fall back to classic IsSpellInRange (requires spell name)
    if IsSpellInRange then
        local spellName = GetSpellInfo(effectiveSpellID)
        if spellName then
            local result = IsSpellInRange(spellName, unit)
            -- Returns 1 (in range), 0 (out of range), nil (no range check possible)
            if result == 1 then
                return true
            elseif result == 0 then
                return false
            end
        end
    end
    
    -- Spell has no range component or API unavailable
    return nil
end
