--[[
    VeevHUD - Tick Tracker
    Centralized tracking of energy and mana regeneration ticks
    
    Both the Energy Tick Indicator UI and Resource Prediction features
    depend on accurate tick timing. This service provides that shared state.
    
    Key concepts:
    - Energy/mana regenerate in "ticks" every 2 seconds
    - The tick timer is continuous and never resets (even when casting)
    - We detect ticks by observing resource increases
    - "Phantom tick" tracking keeps timing accurate when at full resources
]]

local ADDON_NAME, addon = ...
local C = addon.Constants

local TickTracker = {}
addon.TickTracker = TickTracker

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

-- Energy tick tracking
TickTracker.lastEnergyTickTime = 0
TickTracker.lastSampleEnergy = 0

-- Mana tick tracking  
TickTracker.lastManaTickTime = 0
TickTracker.lastSampleMana = 0
TickTracker.prevSampleMana = 0  -- For detecting passive vs active regen

-- Mana spike filtering (potions, life tap, etc.)
TickTracker.manaSpikeThreshold = C.MANA_SPIKE_THRESHOLD

-- Full tick countdown state (for seamless "next full tick" progress)
TickTracker.fullTickTargetTime = 0     -- When the first full tick will arrive
TickTracker.fullTickStartTime = 0      -- When we started the countdown
TickTracker.fullTickDuration = 0       -- Total duration of the countdown

-------------------------------------------------------------------------------
-- Energy Tick Tracking
-------------------------------------------------------------------------------

-- Get expected energy per tick (20 normally, 40 with Adrenaline Rush)
function TickTracker:GetExpectedEnergyPerTick()
    local baseEnergyPerTick = C.ENERGY_PER_TICK
    
    -- Check for Adrenaline Rush
    local Utils = addon.Utils
    if Utils and Utils.GetCachedBuff then
        local adrenalineRush = Utils:GetCachedBuff("player", C.SPELL_ID_ADRENALINE_RUSH, "Adrenaline Rush")
        if adrenalineRush then
            return baseEnergyPerTick * 2
        end
    end
    
    return baseEnergyPerTick
end

-- Record an energy sample for tick detection
-- Call this periodically (e.g., from OnUpdate)
function TickTracker:RecordEnergySample()
    local currentEnergy = UnitPower("player", C.POWER_TYPE.ENERGY)
    local maxEnergy = UnitPowerMax("player", C.POWER_TYPE.ENERGY)
    local now = GetTime()
    local expectedTick = self:GetExpectedEnergyPerTick()
    local tickObserved = false
    
    if currentEnergy > self.lastSampleEnergy then
        local gained = currentEnergy - self.lastSampleEnergy
        
        -- Filter out non-tick energy gains using two checks:
        -- 1. Time filter: Real ticks are 2s apart, refunds (dodge/parry/miss) are instant
        --    Require at least 1.5 seconds since last tick
        -- 2. Amount filter: Expect ~20 energy (or ~40 with AR) with some tolerance
        --    This filters Thistle Tea (40), weird procs, and partial refunds
        
        local timeSinceLastTick = now - self.lastEnergyTickTime
        local minTickInterval = 1.5
        local isTooSoon = (self.lastEnergyTickTime > 0 and timeSinceLastTick < minTickInterval)
        
        -- Amount check: 15-25 normally, 35-45 with Adrenaline Rush
        local hasAdrenalineRush = (expectedTick == C.ENERGY_PER_TICK_ADRENALINE)
        local isValidAmount
        if hasAdrenalineRush then
            isValidAmount = (gained >= 35 and gained <= 45)
        else
            isValidAmount = (gained >= 15 and gained <= 25)
        end
        
        -- Also accept partial ticks when near max energy (last tick before full)
        local isPartialTick = (currentEnergy >= maxEnergy and gained > 0 and gained < 15)
        
        if not isTooSoon and (isValidAmount or isPartialTick) then
            self.lastEnergyTickTime = now
            tickObserved = true
        end
    end
    
    -- Track "phantom ticks" whenever we don't observe an actual tick
    -- Ticks occur every 2 seconds regardless of whether we can see energy gains
    -- (e.g., at full energy, or spending faster than regenerating)
    if not tickObserved and self.lastEnergyTickTime > 0 then
        local timeSinceLastTick = now - self.lastEnergyTickTime
        if timeSinceLastTick >= C.TICK_RATE then
            -- Advance by whole tick intervals to stay synchronized
            local ticksMissed = math.floor(timeSinceLastTick / C.TICK_RATE)
            self.lastEnergyTickTime = self.lastEnergyTickTime + (ticksMissed * C.TICK_RATE)
        end
    end
    
    self.lastSampleEnergy = currentEnergy
end

-- Get the progress (0-1) toward the next energy tick
function TickTracker:GetEnergyTickProgress()
    local currentEnergy = UnitPower("player", C.POWER_TYPE.ENERGY)
    local maxEnergy = UnitPowerMax("player", C.POWER_TYPE.ENERGY)
    
    if currentEnergy >= maxEnergy then
        return 0  -- At max, no progress to show
    end
    
    if self.lastEnergyTickTime <= 0 then
        return 0  -- No tick data yet
    end
    
    local timeSinceTick = GetTime() - self.lastEnergyTickTime
    local progress = timeSinceTick / C.TICK_RATE
    
    return math.min(1, math.max(0, progress))
end

-- Get time until next energy tick (for predictions)
function TickTracker:GetTimeUntilNextEnergyTick()
    local currentEnergy = UnitPower("player", C.POWER_TYPE.ENERGY)
    local maxEnergy = UnitPowerMax("player", C.POWER_TYPE.ENERGY)
    
    if currentEnergy >= maxEnergy then
        return 0
    end
    
    if self.lastEnergyTickTime > 0 then
        local timeSinceTick = GetTime() - self.lastEnergyTickTime
        local timeUntilTick = C.TICK_RATE - timeSinceTick
        
        if timeUntilTick <= 0 then
            return 0.1  -- Tick is imminent
        end
        return math.min(C.TICK_RATE, timeUntilTick)
    end
    
    -- Fallback: assume worst case
    return C.TICK_RATE
end

-------------------------------------------------------------------------------
-- Mana Tick Tracking
-------------------------------------------------------------------------------

-- Record a mana sample for tick detection
-- Call this periodically (e.g., from OnUpdate)
function TickTracker:RecordManaSample()
    local currentMana = UnitPower("player", C.POWER_TYPE.MANA)
    local maxMana = UnitPowerMax("player", C.POWER_TYPE.MANA)
    local now = GetTime()
    local tickObserved = false
    
    if currentMana > self.lastSampleMana then
        local gained = currentMana - self.lastSampleMana
        local percentGain = gained / maxMana
        
        -- Filter: valid tick is between 0.3% and 10% of max mana
        local minTickPercent = 0.003
        local isValidTick = percentGain >= minTickPercent and percentGain <= self.manaSpikeThreshold
        
        if isValidTick then
            self.lastManaTickTime = now
            tickObserved = true
        end
    end
    
    -- Track "phantom ticks" whenever we don't observe an actual tick
    -- Ticks occur every 2 seconds regardless of whether we can see mana gains
    -- (e.g., at full mana, or during 5SR with minimal regen)
    if not tickObserved and self.lastManaTickTime > 0 then
        local timeSinceLastTick = now - self.lastManaTickTime
        if timeSinceLastTick >= C.TICK_RATE then
            -- Advance by whole tick intervals to stay synchronized
            local ticksMissed = math.floor(timeSinceLastTick / C.TICK_RATE)
            self.lastManaTickTime = self.lastManaTickTime + (ticksMissed * C.TICK_RATE)
        end
    end
    
    -- Shift samples for next iteration
    self.prevSampleMana = self.lastSampleMana
    self.lastSampleMana = currentMana
end

-- Get the progress (0-1) toward the next mana tick
function TickTracker:GetManaTickProgress()
    local currentMana = UnitPower("player", C.POWER_TYPE.MANA)
    local maxMana = UnitPowerMax("player", C.POWER_TYPE.MANA)
    
    if currentMana >= maxMana then
        return 0  -- At max, no progress to show
    end
    
    if self.lastManaTickTime <= 0 then
        return 0  -- No tick data yet
    end
    
    local timeSinceTick = GetTime() - self.lastManaTickTime
    local progress = timeSinceTick / C.TICK_RATE
    
    return math.min(1, math.max(0, progress))
end

-- Get time until next mana tick (for predictions)
function TickTracker:GetTimeUntilNextManaTick()
    local currentMana = UnitPower("player", C.POWER_TYPE.MANA)
    local maxMana = UnitPowerMax("player", C.POWER_TYPE.MANA)
    
    if currentMana >= maxMana then
        return 0
    end
    
    if self.lastManaTickTime > 0 then
        local timeSinceTick = GetTime() - self.lastManaTickTime
        local timeUntilTick = C.TICK_RATE - timeSinceTick
        
        if timeUntilTick <= 0 then
            return 0.1  -- Tick is imminent
        end
        return math.min(C.TICK_RATE, timeUntilTick)
    end
    
    -- Fallback: assume worst case
    return C.TICK_RATE
end

-- Get progress toward the first full-rate mana tick (after 5SR ends)
-- Returns progress 0-1 where 1 = full tick is imminent
-- Uses state tracking for seamless countdown (no jumps when 5SR ends)
function TickTracker:GetFullTickProgress()
    local FSR = addon.FiveSecondRule
    local now = GetTime()
    
    if not FSR then
        return self:GetManaTickProgress()
    end
    
    local timeRemaining5SR = FSR:GetTimeRemaining()
    
    -- Check if we have an active countdown
    if self.fullTickTargetTime > 0 then
        local timeRemaining = self.fullTickTargetTime - now
        
        -- Countdown completed - reset and switch to normal tick progress
        if timeRemaining <= 0 then
            self.fullTickTargetTime = 0
            self.fullTickStartTime = 0
            self.fullTickDuration = 0
            return self:GetManaTickProgress()
        end
        
        -- Check if 5SR was reset (user cast again) - need to recalculate
        -- If we're in 5SR and the new target would be later than current, recalc
        if timeRemaining5SR > 0 then
            local time5SREnds = now + timeRemaining5SR
            if time5SREnds > self.fullTickTargetTime then
                -- 5SR was extended past our target - recalculate
                self.fullTickTargetTime = 0
                self.fullTickStartTime = 0
                self.fullTickDuration = 0
                -- Fall through to recalculate below
            else
                -- Continue the seamless countdown
                local progress = 1 - (timeRemaining / self.fullTickDuration)
                return math.min(1, math.max(0, progress))
            end
        else
            -- Outside 5SR but countdown still active - continue it
            local progress = 1 - (timeRemaining / self.fullTickDuration)
            return math.min(1, math.max(0, progress))
        end
    end
    
    -- No active countdown - check if we should start one
    if timeRemaining5SR <= 0 then
        -- Outside 5SR with no countdown - use normal tick progress
        return self:GetManaTickProgress()
    end
    
    -- Inside 5SR - start a new countdown
    -- (This also handles recasting - if we get here with 5SR active but no countdown,
    -- it means the user cast again and we need to recalculate)
    if self.lastManaTickTime <= 0 then
        return 0  -- No tick data yet
    end
    
    -- Calculate when the first full tick will occur
    local time5SREnds = now + timeRemaining5SR
    local timeSinceLastTick = time5SREnds - self.lastManaTickTime
    local ticksNeeded = math.ceil(timeSinceLastTick / C.TICK_RATE)
    if ticksNeeded < 1 then ticksNeeded = 1 end
    
    local firstFullTickTime = self.lastManaTickTime + (ticksNeeded * C.TICK_RATE)
    local duration = firstFullTickTime - now
    
    -- Store countdown state
    self.fullTickTargetTime = firstFullTickTime
    self.fullTickStartTime = now
    self.fullTickDuration = duration
    
    -- Return initial progress (0%)
    return 0
end

-- Get time until the first full-rate mana tick (after 5SR ends)
function TickTracker:GetTimeUntilFullTick()
    local FSR = addon.FiveSecondRule
    
    if not FSR then
        return self:GetTimeUntilNextManaTick()
    end
    
    local timeRemaining5SR = FSR:GetTimeRemaining()
    
    if timeRemaining5SR <= 0 then
        return self:GetTimeUntilNextManaTick()
    end
    
    local now = GetTime()
    local time5SREnds = now + timeRemaining5SR
    
    if self.lastManaTickTime <= 0 then
        return timeRemaining5SR + C.TICK_RATE  -- Worst case
    end
    
    local timeSinceLastTick = time5SREnds - self.lastManaTickTime
    local ticksNeeded = math.ceil(timeSinceLastTick / C.TICK_RATE)
    if ticksNeeded < 1 then ticksNeeded = 1 end
    
    local firstFullTickTime = self.lastManaTickTime + (ticksNeeded * C.TICK_RATE)
    return firstFullTickTime - now
end

-------------------------------------------------------------------------------
-- Utility
-------------------------------------------------------------------------------

function TickTracker:GetTickRate()
    return C.TICK_RATE
end

-- Sync the tick time (called when a tick is detected elsewhere, e.g., SYNC fix)
function TickTracker:SyncEnergyTickTime(time)
    self.lastEnergyTickTime = time or GetTime()
end

function TickTracker:SyncManaTickTime(time)
    self.lastManaTickTime = time or GetTime()
end
