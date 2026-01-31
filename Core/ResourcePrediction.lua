--[[
    VeevHUD - Resource Prediction
    Predicts time until player can afford spells based on resource regeneration
    
    Energy: Tick-aware prediction (2-second ticks, accounts for Adrenaline Rush)
    Mana: Observed rate tracking (monitors actual regen, filters spikes)
    Rage: Not predictable (combat-generated)
]]

local ADDON_NAME, addon = ...

local ResourcePrediction = {}
addon.ResourcePrediction = ResourcePrediction

-- Debug logging helper - uses addon.Utils:LogDebug (enable with /vh debug)
local function DebugLog(category, message, ...)
    if addon.Utils then
        addon.Utils:LogDebug(string.format("[%s] " .. message, category, ...))
    end
end

-- Power type constants
local POWER_TYPE = {
    MANA = 0,
    RAGE = 1,
    ENERGY = 3,
}

-- Timing buffer to add to predictions
-- When nextTick=0 (tick imminent), the tick actually happens a few ms AFTER the prediction
-- starts counting down. Without this buffer, the prediction ends before the last tick arrives.
-- Adding 0.15s ensures the last tick has time to register before the spiral "ends".
local PREDICTION_BUFFER = 0.15

-------------------------------------------------------------------------------
-- Energy Prediction
-- Energy regenerates in predictable 2-second ticks
-------------------------------------------------------------------------------

local ADRENALINE_RUSH_SPELL_ID = 13750

-- Prediction-specific state (SYNC fix for multi-icon predictions)
ResourcePrediction.lastPredictionEnergy = 0

-- Get energy regeneration rate per tick, accounting for Adrenaline Rush
-- Returns: energyPerTick, tickRate
function ResourcePrediction:GetEnergyRegenRate()
    -- Delegate to TickTracker if available, with fallback
    local TickTracker = addon.TickTracker
    local baseEnergyPerTick = TickTracker and TickTracker:GetExpectedEnergyPerTick() or 20
    local tickRate = TickTracker and TickTracker:GetTickRate() or 2.0
    
    return baseEnergyPerTick, tickRate
end

-- Get time until next energy tick
-- Returns: secondsUntilTick (0 if at max energy or no prediction available)
function ResourcePrediction:GetTimeUntilNextEnergyTick()
    local currentEnergy = UnitPower("player", POWER_TYPE.ENERGY)
    local maxEnergy = UnitPowerMax("player", POWER_TYPE.ENERGY)
    local energyPerTick, tickRate = self:GetEnergyRegenRate()
    local TickTracker = addon.TickTracker
    
    if currentEnergy >= maxEnergy then
        self.lastPredictionEnergy = currentEnergy
        return 0
    end
    
    -- SYNC: Detect if energy increased significantly since last prediction
    -- This means a tick JUST happened but TickTracker hasn't been updated yet
    local energyGain = currentEnergy - self.lastPredictionEnergy
    local minTickDetect = energyPerTick * 0.8  -- 80% of expected tick (16 or 32 energy)
    
    if energyGain >= minTickDetect and self.lastPredictionEnergy > 0 then
        -- A tick just happened! Update the canonical tick time in TickTracker
        self.lastPredictionEnergy = currentEnergy
        if TickTracker then
            TickTracker:SyncEnergyTickTime(GetTime())
        end
        return tickRate - 0.05  -- Almost exactly 2 seconds
    end
    
    self.lastPredictionEnergy = currentEnergy
    
    -- Use centralized tick tracking from TickTracker
    if TickTracker then
        return TickTracker:GetTimeUntilNextEnergyTick()
    end
    
    -- Fallback: assume worst case (just missed a tick)
    return tickRate
end

-- Calculate time until player can afford a spell (energy)
-- Returns: timeUntilAffordable
function ResourcePrediction:GetTimeUntilEnergyAffordable(needed)
    local energyPerTick, tickRate = self:GetEnergyRegenRate()
    local timeUntilNextTick = self:GetTimeUntilNextEnergyTick()
    
    -- Calculate how many ticks needed
    local ticksNeeded = math.ceil(needed / energyPerTick)
    
    local result
    if ticksNeeded <= 1 then
        -- Will be affordable on next tick
        result = timeUntilNextTick
    else
        -- Need multiple ticks: time until next + additional ticks
        result = timeUntilNextTick + (ticksNeeded - 1) * tickRate
    end
    
    -- Add timing buffer to ensure last tick registers before prediction ends
    return result + PREDICTION_BUFFER
end

-------------------------------------------------------------------------------
-- Mana Prediction
-- Tick-aware prediction similar to energy (2-second tick rate)
-- Tracks when mana ticks occur and calculates mana-per-tick
-- Separately tracks "inside 5SR" vs "outside 5SR" regen rates
-------------------------------------------------------------------------------

local MANA_TICK_RATE = 2.0  -- Mana ticks every 2 seconds

-- Conservative buffer for 5SR transitions
-- UNIT_SPELLCAST_SUCCEEDED may fire slightly after the actual cast, and there can be
-- timing drift. By treating 5SR as ending 0.3s earlier than calculated, we avoid
-- predicting in-5SR (low rate) ticks that turn out to be out-of-5SR (high rate) ticks.
-- This makes predictions slightly longer (more conservative), which is safer.
local FIVE_SECOND_RULE_BUFFER = 0.3

-- Mana tick tracking state
ResourcePrediction.lastManaTickTime = 0  -- When the last mana tick occurred
ResourcePrediction.lastSampleMana = 0  -- Last sample mana (to detect tick moments)
ResourcePrediction.prevSampleMana = 0  -- Sample before last (to detect casting activity)
ResourcePrediction.manaSpikeThreshold = 0.10  -- Ignore gains > 10% of max mana (potions, life tap)

-- 5-second rule: delegated to FiveSecondRule module
-- ResourcePrediction no longer tracks this directly

-- Separate tick histories for inside/outside 5SR
-- "in5sr" = inside 5-second rule (only MP5 regen, typically lower)
-- "out5sr" = outside 5-second rule (full spirit regen, typically higher)
ResourcePrediction.tickHistoryIn5SR = {}  -- Tick amounts while in 5SR
ResourcePrediction.tickHistoryOut5SR = {}  -- Tick amounts while outside 5SR
ResourcePrediction.manaTickHistoryMax = 5  -- Keep last 5 ticks per category

-- Observed mana per tick for each state
ResourcePrediction.manaPerTickIn5SR = nil  -- Current calculated rate inside 5SR
ResourcePrediction.manaPerTickOut5SR = nil  -- Current calculated rate outside 5SR
ResourcePrediction.lastGoodManaPerTickIn5SR = nil  -- Remembered rate (session persistent)
ResourcePrediction.lastGoodManaPerTickOut5SR = nil  -- Remembered rate (session persistent)

-- Check if currently inside the 5-second rule
-- Delegates to the FiveSecondRule module
function ResourcePrediction:IsInFiveSecondRule()
    local FSR = addon.FiveSecondRule
    if FSR then
        return FSR:IsActive()
    end
    return false
end

-- Get time remaining in the 5-second rule
function ResourcePrediction:GetTimeRemaining5SR()
    local FSR = addon.FiveSecondRule
    if FSR then
        return FSR:GetTimeRemaining()
    end
    return 0
end

-- Record a mana sample for tick detection
-- Call this periodically (e.g., from ResourceBar OnUpdate)
function ResourcePrediction:RecordManaSample()
    -- Ensure 5SR tracking is initialized
    local FSR = addon.FiveSecondRule
    if FSR then
        FSR:Initialize()
        FSR:UpdateManaSample()
    end
    
    local currentMana = UnitPower("player", POWER_TYPE.MANA)
    local maxMana = UnitPowerMax("player", POWER_TYPE.MANA)
    local now = GetTime()
    
    -- Detect mana tick: mana increased from last sample
    if currentMana > self.lastSampleMana then
        local gained = currentMana - self.lastSampleMana
        local percentGain = gained / maxMana
        
        -- Check if we were "passively regenerating" before this tick
        -- (mana was NOT decreasing in the previous sample interval)
        -- This filters out ticks that are polluted by simultaneous casting
        local wasPassive = self.lastSampleMana >= self.prevSampleMana
        
        -- Filter out large spikes (potions, life tap, etc.)
        -- Also filter out tiny gains (could be rounding or very low spirit)
        local minTickPercent = 0.003  -- At least 0.3% of max mana to count as tick
        local isValidTick = percentGain >= minTickPercent and percentGain <= self.manaSpikeThreshold
        
        local in5SR = self:IsInFiveSecondRule()
        
        if isValidTick then
            -- Always update tick time (for timing predictions)
            self.lastManaTickTime = now
            -- Also update prediction mana to prevent double-counting
            self.lastPredictionMana = currentMana
            -- Sync with TickTracker if available
            local TickTracker = addon.TickTracker
            if TickTracker then
                TickTracker:SyncManaTickTime(now)
            end
            
            -- Only record tick AMOUNT if we were passively regenerating
            -- This ensures we get clean tick measurements, not ticks polluted by casting
            if wasPassive then
                -- Determine which history to record to based on 5SR state
                local history = in5SR and self.tickHistoryIn5SR or self.tickHistoryOut5SR
                local bucket = in5SR and "IN5SR" or "OUT5SR"
                
                table.insert(history, gained)
                
                -- Keep only recent ticks per category
                while #history > self.manaTickHistoryMax do
                    table.remove(history, 1)
                end
                
                -- Recalculate rate for the appropriate state (uses minimum for safety)
                self:CalculateObservedManaPerTick(in5SR)
                
                local rate = in5SR and self.manaPerTickIn5SR or self.manaPerTickOut5SR
                DebugLog("TICK", "+%d mana (%.1f%%) -> %s bucket [%d ticks, rate=%.0f]", 
                    gained, percentGain * 100, bucket, #history, rate or 0)
            else
                DebugLog("TICK", "+%d mana (%.1f%%) - SKIPPED (was casting, prev=%d last=%d)", 
                    gained, percentGain * 100, self.prevSampleMana, self.lastSampleMana)
            end
        elseif percentGain > self.manaSpikeThreshold then
            -- Large spike (potion, life tap) - update tick time but don't record amount
            self.lastManaTickTime = now
            -- Sync with TickTracker if available
            local TickTracker = addon.TickTracker
            if TickTracker then
                TickTracker:SyncManaTickTime(now)
            end
            DebugLog("TICK", "+%d mana (%.1f%%) - SPIKE ignored (>%.0f%% threshold)", 
                gained, percentGain * 100, self.manaSpikeThreshold * 100)
        elseif percentGain < minTickPercent then
            DebugLog("TICK", "+%d mana (%.1f%%) - TOO SMALL (<%.1f%% threshold)", 
                gained, percentGain * 100, minTickPercent * 100)
        end
    elseif currentMana >= maxMana then
        -- Track "phantom ticks" when at full mana
        -- The tick timer keeps running even when we can't see gains, so advance it
        -- This keeps our timing accurate for when mana drops and we start predicting again
        if self.lastManaTickTime > 0 and (now - self.lastManaTickTime) >= MANA_TICK_RATE then
            -- A phantom tick would have occurred - advance the tick timer
            self.lastManaTickTime = self.lastManaTickTime + MANA_TICK_RATE
            -- Keep advancing if multiple ticks have passed
            while (now - self.lastManaTickTime) >= MANA_TICK_RATE do
                self.lastManaTickTime = self.lastManaTickTime + MANA_TICK_RATE
            end
        end
    end
    
    -- Shift samples for next iteration
    self.prevSampleMana = self.lastSampleMana
    self.lastSampleMana = currentMana
end

-- Calculate average mana gained per tick from recent history
-- @param in5SR: true = calculate for inside 5SR, false = outside 5SR
-- Uses the MINIMUM observed tick to be conservative (avoids underprediction)
function ResourcePrediction:CalculateObservedManaPerTick(in5SR)
    local history = in5SR and self.tickHistoryIn5SR or self.tickHistoryOut5SR
    
    if #history < 1 then
        if in5SR then
            self.manaPerTickIn5SR = nil
        else
            self.manaPerTickOut5SR = nil
        end
        return
    end
    
    -- Find the minimum tick amount (most conservative)
    -- This prevents underprediction when individual ticks vary
    local minTick = history[1]
    for _, amount in ipairs(history) do
        if amount < minTick then
            minTick = amount
        end
    end
    
    -- Use floor of minimum to be extra safe with rounding
    local conservativeRate = math.floor(minTick)
    
    -- Store in appropriate slot and save as "last good"
    if in5SR then
        self.manaPerTickIn5SR = conservativeRate
        self.lastGoodManaPerTickIn5SR = conservativeRate
    else
        self.manaPerTickOut5SR = conservativeRate
        self.lastGoodManaPerTickOut5SR = conservativeRate
    end
end

-- Track mana for prediction-time tick detection
ResourcePrediction.lastPredictionMana = 0

-- Get time until next mana tick
-- Returns: secondsUntilTick (0 if at max mana or no data)
function ResourcePrediction:GetTimeUntilNextManaTick()
    local currentMana = UnitPower("player", POWER_TYPE.MANA)
    local maxMana = UnitPowerMax("player", POWER_TYPE.MANA)
    
    if currentMana >= maxMana then
        self.lastPredictionMana = currentMana
        return 0
    end
    
    -- CRITICAL FIX: Detect if mana increased significantly since last prediction
    -- This means a tick JUST happened but lastManaTickTime hasn't been updated yet
    -- We need to treat this as "tick just happened" not "tick is about to happen"
    local manaGain = currentMana - self.lastPredictionMana
    local minTickDetect = 15  -- Minimum gain to consider as a tick (most ticks are 26-82)
    
    if manaGain >= minTickDetect and self.lastPredictionMana > 0 then
        -- A tick just happened! The next tick is ~2s away, not imminent
        -- CRITICAL: Also update lastManaTickTime so ALL subsequent calls this frame
        -- use the correct timing (not just the first spell that triggers SYNC)
        DebugLog("SYNC", "Detected mana +%d before tick log (prev=%d, cur=%d) -> forcing nextTick=2.0s",
            manaGain, self.lastPredictionMana, currentMana)
        self.lastPredictionMana = currentMana
        self.lastManaTickTime = GetTime()  -- Update tick time for all subsequent calls
        -- Sync with TickTracker if available
        local TickTracker = addon.TickTracker
        if TickTracker then
            TickTracker:SyncManaTickTime(GetTime())
        end
        return MANA_TICK_RATE - 0.05  -- Almost exactly 2 seconds
    end
    
    self.lastPredictionMana = currentMana
    
    -- If we've tracked a tick, calculate time until next
    if self.lastManaTickTime > 0 then
        local timeSinceTick = GetTime() - self.lastManaTickTime
        local timeUntilTick = MANA_TICK_RATE - timeSinceTick
        
        -- Clamp to valid range
        if timeUntilTick <= 0 then
            return 0.1  -- Tick is imminent
        end
        return math.min(MANA_TICK_RATE, timeUntilTick)
    end
    
    -- No tick tracked yet - assume worst case
    return MANA_TICK_RATE
end

-- Calculate time until player can afford a spell (mana)
-- Uses tick-aware prediction similar to energy
-- Accounts for 5-second rule transition (rate changes after 5SR expires)
-- Uses the same intelligent 5SR + tick timing logic as the mana ticker
-- Intelligently handles:
--   - Level 1 characters with 0 in-5SR regen (only spirit regen outside 5SR)
--   - Higher level characters with MP5 gear (some regen during 5SR)
-- Returns: timeUntilAffordable
function ResourcePrediction:GetTimeUntilManaAffordable(needed, maxPower, spellID)
    local TickTracker = addon.TickTracker
    local spellName = spellID and C_Spell.GetSpellName(spellID) or "Unknown"
    
    -- Get observed rates for in-5SR and out-of-5SR
    -- These are intelligently calculated from actual mana gains
    -- A level 1 priest will have rateIn5SR = 0 or nil (no MP5)
    -- A geared priest might have rateIn5SR = 20+ (from MP5 gear)
    local rateIn5SR = self.manaPerTickIn5SR or self.lastGoodManaPerTickIn5SR or 0
    local rateOut5SR = self.manaPerTickOut5SR or self.lastGoodManaPerTickOut5SR
    
    -- Check current 5SR state
    local in5SR = self:IsInFiveSecondRule()
    local timeLeft5SR = 0
    if in5SR then
        timeLeft5SR = self:GetTimeRemaining5SR() - FIVE_SECOND_RULE_BUFFER
        if timeLeft5SR < 0 then timeLeft5SR = 0 end
    end
    
    -- Fallback if no out-of-5SR rate data yet
    if not rateOut5SR or rateOut5SR <= 0 then
        -- Use rough estimate based on max mana
        local estimatedPerTick = maxPower * 0.02
        if estimatedPerTick <= 0 then estimatedPerTick = 1 end
        
        local timeUntilFirstTick
        if TickTracker and in5SR then
            timeUntilFirstTick = TickTracker:GetTimeUntilFullTick()
        else
            timeUntilFirstTick = self:GetTimeUntilNextManaTick()
        end
        
        local ticksNeeded = math.ceil(needed / estimatedPerTick)
        local result = timeUntilFirstTick + (ticksNeeded - 1) * MANA_TICK_RATE + PREDICTION_BUFFER
        
        DebugLog("PRED", "[%s] Need %d, NO RATE DATA, fallback=%.0f/tick, ticks=%d -> %.1fs",
            spellName, needed, estimatedPerTick, ticksNeeded, result)
        return result
    end
    
    -- Get tick timing
    local timeUntilNextTick = self:GetTimeUntilNextManaTick()
    local timeUntilFirstFullTick
    if TickTracker and in5SR then
        timeUntilFirstFullTick = TickTracker:GetTimeUntilFullTick()
    else
        timeUntilFirstFullTick = timeUntilNextTick
    end
    
    -- Calculate mana gained during 5SR (using observed in-5SR rate, which may be 0)
    local manaGainedIn5SR = 0
    local ticksDuring5SR = 0
    local timeElapsed = 0
    
    if in5SR and rateIn5SR > 0 then
        -- We have some in-5SR regen (MP5 gear, etc.)
        -- Count ticks and mana gained during 5SR
        if timeUntilNextTick < timeLeft5SR then
            manaGainedIn5SR = rateIn5SR
            timeElapsed = timeUntilNextTick
            ticksDuring5SR = 1
            
            while timeElapsed + MANA_TICK_RATE < timeLeft5SR and manaGainedIn5SR < needed do
                timeElapsed = timeElapsed + MANA_TICK_RATE
                manaGainedIn5SR = manaGainedIn5SR + rateIn5SR
                ticksDuring5SR = ticksDuring5SR + 1
            end
        end
        
        -- Check if we got enough during 5SR alone
        if manaGainedIn5SR >= needed then
            local safetyBuffer = rateIn5SR * 0.05
            local ticksNeeded = math.ceil((needed + safetyBuffer) / rateIn5SR)
            local result = timeUntilNextTick + (ticksNeeded - 1) * MANA_TICK_RATE + PREDICTION_BUFFER
            
            local logKey = string.format("%s_%d_%d_in5sr", spellName, needed, ticksNeeded)
            if self.lastPredLogKey ~= logKey then
                self.lastPredLogKey = logKey
                DebugLog("PRED", "[%s] Need %d, IN5SR rate=%.0f, ticks=%d -> %.1fs (all within 5SR)",
                    spellName, needed, rateIn5SR, ticksNeeded, result)
            end
            return result
        end
    end
    -- If rateIn5SR is 0, manaGainedIn5SR stays 0 and ticksDuring5SR stays 0
    -- This correctly handles level 1 characters with no MP5
    
    -- Calculate remaining mana needed after 5SR
    local stillNeeded = needed - manaGainedIn5SR
    local safetyBuffer = rateOut5SR * 0.05
    local ticksAfter5SR = math.ceil((stillNeeded + safetyBuffer) / rateOut5SR)
    
    -- Time until we have enough mana:
    -- First full tick at timeUntilFirstFullTick, then additional ticks every 2s
    local result = timeUntilFirstFullTick + (ticksAfter5SR - 1) * MANA_TICK_RATE + PREDICTION_BUFFER
    
    -- Logging
    local logKey
    if in5SR then
        if ticksDuring5SR > 0 then
            logKey = string.format("%s_%d_%d_%d_hybrid", spellName, needed, ticksDuring5SR, ticksAfter5SR)
            if self.lastPredLogKey ~= logKey then
                self.lastPredLogKey = logKey
                DebugLog("PRED", "[%s] Need %d, IN5SR: %d ticks @%.0f = %.0f mana, then %d ticks @%.0f -> %.1fs",
                    spellName, needed, ticksDuring5SR, rateIn5SR, manaGainedIn5SR, 
                    ticksAfter5SR, rateOut5SR, result)
            end
        else
            logKey = string.format("%s_%d_%d_after5sr", spellName, needed, ticksAfter5SR)
            if self.lastPredLogKey ~= logKey then
                self.lastPredLogKey = logKey
                DebugLog("PRED", "[%s] Need %d, IN5SR (0 regen), wait for 5SR end, %d ticks @%.0f -> %.1fs",
                    spellName, needed, ticksAfter5SR, rateOut5SR, result)
            end
        end
    else
        logKey = string.format("%s_%d_%d_out5sr", spellName, needed, ticksAfter5SR)
        if self.lastPredLogKey ~= logKey then
            self.lastPredLogKey = logKey
            DebugLog("PRED", "[%s] Need %d, OUT5SR, %d ticks @%.0f -> %.1fs",
                spellName, needed, ticksAfter5SR, rateOut5SR, result)
        end
    end
    
    return result
end

-------------------------------------------------------------------------------
-- Main API
-------------------------------------------------------------------------------

-- Calculate time until player can afford a spell
-- Uses tick-aware calculation for energy, observed rate for mana
-- Returns: timeUntilAffordable (0 if already affordable or unpredictable)
function ResourcePrediction:GetTimeUntilAffordable(spellID)
    local Utils = addon.Utils
    if not Utils then return 0 end
    
    local cost, currentPower, maxPower, powerType = Utils:GetSpellPowerInfo(spellID)
    
    -- No cost = always affordable
    if not cost or cost == 0 then
        return 0
    end
    
    -- Already have enough = affordable now
    if currentPower >= cost then
        return 0
    end
    
    local needed = cost - currentPower
    
    -- Energy: tick-based regeneration (highly accurate)
    if powerType == POWER_TYPE.ENERGY then
        return self:GetTimeUntilEnergyAffordable(needed)
    end
    
    -- Mana: observed rate (adapts to player's regen)
    if powerType == POWER_TYPE.MANA then
        -- Log spell info for debugging (only when prediction is needed)
        local spellName = C_Spell.GetSpellName(spellID) or tostring(spellID)
        local logKey = string.format("%s_%d_%d", spellName, cost, currentPower)
        if self.lastCostLogKey ~= logKey then
            self.lastCostLogKey = logKey
            DebugLog("COST", "[%s] Cost=%d, Current=%d, Need=%d", 
                spellName, cost, currentPower, needed)
        end
        return self:GetTimeUntilManaAffordable(needed, maxPower, spellID)
    end
    
    -- Rage: not predictable (combat-generated)
    -- Return 0 to indicate "use standard display"
    if powerType == POWER_TYPE.RAGE then
        return 0
    end
    
    -- Unknown power type: return 0
    return 0
end
