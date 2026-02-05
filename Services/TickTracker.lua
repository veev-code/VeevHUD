--[[
    VeevHUD - Tick Tracker
    Centralized tracking of energy and mana regeneration ticks
    
    Both the Energy Tick Indicator UI and Resource Prediction features
    depend on accurate tick timing. This service provides that shared state.
    
    =========================================================================
    ENERGY TICK TRACKING REQUIREMENTS
    =========================================================================
    
    1. Energy regenerates in "ticks" every 2 seconds (20 energy per tick normally)
    2. For rogues: tick timer is continuous and never resets
    3. For druids: entering Cat Form RESETS the tick timer (powershifting mechanic)
    4. We detect ticks by observing energy increases
    5. "Phantom tick" tracking keeps timing accurate when at full energy
    6. Real ticks always resync our tracking when observed
    7. Don't show ticker until we've observed at least one real tick (hasConfirmedTick)
    8. Option to show ticker even at full energy (for druid powershifting)
    
    =========================================================================
    MANA TICK TRACKING REQUIREMENTS (Five Second Rule / "Next Full Tick")
    =========================================================================
    
    The "Next Full Tick" feature shows progress toward the first full-rate mana
    tick after casting a spell (after the 5-Second Rule ends).
    
    CORE MECHANICS:
    1. Mana regenerates in "ticks" every 2 seconds (amount based on spirit)
    2. The Five Second Rule (5SR): after spending mana, spirit-based regen is
       suppressed for 5 seconds. You still get partial regen from talents/gear.
    3. The "next full tick" is the first tick that occurs AFTER 5SR ends
    4. This tick occurs 5-7 seconds after casting (5s for 5SR + 0-2s for tick cycle)
    
    SOURCE OF TRUTH:
    1. lastManaSpendTime (from FiveSecondRule.lastManaCastTime) = when 5SR started
    2. lastManaTickTime = where we are in the 2s tick cycle
    3. Any observed tick immediately updates lastManaTickTime (no delay/window)
    4. Phantom ticks maintain the 2s cycle when no ticks are observable
    
    CALCULATION:
    1. time5SREnds = lastManaSpendTime + 5 seconds
    2. nextFullTick = lastManaTickTime + ceil((time5SREnds - lastManaTickTime) / 2) * 2
    3. progress = (now - lastManaSpendTime) / (nextFullTick - lastManaSpendTime)
    4. This gives a 5-7 second denominator, NOT a 2 second denominator
    
    BEHAVIOR:
    1. Don't show ticker until we've observed at least one real tick (hasConfirmedManaTick)
    2. Every observed tick (partial or full) recalibrates the prediction automatically
    3. If progress >= 100%, pin at 100% until we observe the full tick
    4. Only switch to normal 2s mode when we observe a tick AFTER 5SR ended
       (i.e., when lastManaTickTime >= time5SREnds)
    5. If user casts again (extends 5SR), the prediction recalculates from new anchor
    6. Anti-rewind: if recalibration predicts a LATER tick than before, keep the earlier
       prediction. Progress bar should only jump forward, never backward.
    
    FILTERING:
    1. Ignore mana gains < 0.3% of max (too small to be a tick)
    2. Ignore mana gains > 10% of max (potions, Life Tap, mana gems, etc.)
    3. Require at least 1.5s since last tick to avoid double-counting
    
    =========================================================================
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
TickTracker.hasConfirmedTick = false  -- True after we've observed at least one real tick

-- Shapeshift tracking for druids
TickTracker.lastKnownForm = 0
TickTracker.formChangeTime = 0

-------------------------------------------------------------------------------
-- Debug Logging (requires /vh debug to enable)
-------------------------------------------------------------------------------
--[[
    Debug logs are written to VeevHUDLog in SavedVariables when debug mode is on.
    
    AI-Assisted Debugging Workflow:
    1. Enable debug mode: /vh debug
    2. Play and reproduce the issue (e.g., energy tick timing drift)
    3. Reload UI: /reload (this flushes logs to SavedVariables)
    4. Point the AI model to the SavedVariables file:
       WTF/Account/<account>/SavedVariables/VeevHUD.lua
       The VeevHUDLog table contains timestamped entries the model can analyze.
    
    Log entries include:
    - TICK observed: actual energy ticks with interval timing
    - TICK resync: real tick arrived shortly after phantom, resyncing
    - FILTERED: energy gains rejected (Thistle Tea, refunds, etc.)
    - PHANTOM: inferred ticks when at full energy
    - FORM: druid shapeshift transitions (enter/leave cat form)
]]

local function TickLog(...)
    local db = addon.db
    if not (db and db.profile and db.profile.debugMode) then return end
    local Utils = addon.Utils
    if Utils and Utils.LogDebug then
        Utils:LogDebug("[TickTracker]", ...)
    end
end

-- Mana tick tracking  
TickTracker.lastManaTickTime = 0
TickTracker.lastSampleMana = 0
TickTracker.prevSampleMana = 0  -- For detecting passive vs active regen
TickTracker.hasConfirmedManaTick = false  -- True after we've observed at least one real mana tick

-- Mana spike filtering (potions, life tap, etc.)
TickTracker.manaSpikeThreshold = C.MANA_SPIKE_THRESHOLD

-- Full tick state
TickTracker.fullTickPinnedLogged = false       -- For log spam reduction when pinned at 100%
TickTracker.earliestPredictedFullTick = 0      -- Prevents progress from "rewinding" on recalibration
TickTracker.predictionAnchorTime = 0           -- The lastManaSpendTime this prediction is based on

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
    local prevTickTime = self.lastEnergyTickTime  -- For interval calculation
    
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
            self.hasConfirmedTick = true  -- We've observed a real tick
            tickObserved = true
            
            -- Debug: Log observed tick with interval
            local interval = prevTickTime > 0 and (now - prevTickTime) or 0
            TickLog(string.format("TICK observed: +%d energy, interval=%.3fs, now=%d/%d",
                gained, interval, currentEnergy, maxEnergy))
        elseif isTooSoon and (isValidAmount or isPartialTick) then
            -- This is a real tick that arrived shortly after a phantom tick fired.
            -- The phantom tick was slightly early (server ticks are ~2.01s, not exactly 2.0s).
            -- Resync to this as the authoritative tick time.
            local phantomOffset = timeSinceLastTick
            self.lastEnergyTickTime = now
            self.hasConfirmedTick = true  -- Resync also confirms we have valid tick data
            tickObserved = true
            
            -- Debug: Log resync
            local interval = prevTickTime > 0 and (now - prevTickTime) or 0
            TickLog(string.format("TICK resync: +%d energy, interval=%.3fs, phantomWas=%.3fs early, now=%d/%d",
                gained, interval, phantomOffset, currentEnergy, maxEnergy))
        else
            -- Debug: Log filtered energy gain (bad amount - probably Thistle Tea, refund, etc.)
            TickLog(string.format("FILTERED +%d energy: reason=bad_amount, timeSince=%.3fs, AR=%s",
                gained, timeSinceLastTick, tostring(hasAdrenalineRush)))
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
            local oldTickTime = self.lastEnergyTickTime
            self.lastEnergyTickTime = self.lastEnergyTickTime + (ticksMissed * C.TICK_RATE)
            
            -- Debug: Log phantom tick advancement
            TickLog(string.format("PHANTOM tick: advanced by %d ticks (%.3fs), energy=%d/%d",
                ticksMissed, now - oldTickTime, currentEnergy, maxEnergy))
        end
    end
    
    self.lastSampleEnergy = currentEnergy
end

-- Get the progress (0-1) toward the next energy tick
-- showAtFullEnergy: if true, continue tracking even at full energy (for timing openers)
function TickTracker:GetEnergyTickProgress(showAtFullEnergy)
    local currentEnergy = UnitPower("player", C.POWER_TYPE.ENERGY)
    local maxEnergy = UnitPowerMax("player", C.POWER_TYPE.ENERGY)
    local isAtMaxEnergy = currentEnergy >= maxEnergy
    
    if isAtMaxEnergy and not showAtFullEnergy then
        return 0  -- At max and not showing at full, no progress to show
    end
    
    -- Don't show ticker until we have confirmed tick data
    -- This prevents showing a meaningless ticker after UI reload, zone change, etc.
    -- We need to observe a real tick (or druid form entry) to confirm timing
    if not self.hasConfirmedTick then
        return 0  -- No confirmed tick data yet
    end
    
    if self.lastEnergyTickTime <= 0 then
        return 0  -- No tick data yet (shouldn't happen if hasConfirmedTick is true)
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
    local prevTickTime = self.lastManaTickTime  -- For interval calculation
    
    if currentMana > self.lastSampleMana then
        local gained = currentMana - self.lastSampleMana
        local percentGain = gained / maxMana
        
        -- Filter out non-tick mana gains:
        -- 1. Time filter: Real ticks are 2s apart
        --    Require at least 1.5 seconds since last tick
        -- 2. Amount filter: valid tick is between 0.3% and 10% of max mana
        --    This filters potions, Life Tap, mana gems, etc.
        
        local timeSinceLastTick = now - self.lastManaTickTime
        local minTickInterval = 1.5
        local isTooSoon = (self.lastManaTickTime > 0 and timeSinceLastTick < minTickInterval)
        
        local minTickPercent = 0.003
        local isValidAmount = percentGain >= minTickPercent and percentGain <= self.manaSpikeThreshold
        
        if not isTooSoon and isValidAmount then
            self.lastManaTickTime = now
            self.hasConfirmedManaTick = true  -- We've observed a real tick
            tickObserved = true
            
            -- Debug: Log observed tick with interval
            local interval = prevTickTime > 0 and (now - prevTickTime) or 0
            TickLog(string.format("MANA TICK observed: +%d mana (%.1f%%), interval=%.3fs, now=%d/%d",
                gained, percentGain * 100, interval, currentMana, maxMana))
        elseif isTooSoon and isValidAmount then
            -- This is a real tick that arrived shortly after a phantom tick fired.
            -- Resync to this as the authoritative tick time.
            local phantomOffset = timeSinceLastTick
            self.lastManaTickTime = now
            self.hasConfirmedManaTick = true  -- Resync also confirms we have valid tick data
            tickObserved = true
            
            -- Debug: Log resync
            local interval = prevTickTime > 0 and (now - prevTickTime) or 0
            TickLog(string.format("MANA TICK resync: +%d mana (%.1f%%), interval=%.3fs, phantomWas=%.3fs early, now=%d/%d",
                gained, percentGain * 100, interval, phantomOffset, currentMana, maxMana))
        elseif not isValidAmount and percentGain > self.manaSpikeThreshold then
            -- Debug: Log filtered mana gain (spike - probably potion, Life Tap, etc.)
            TickLog(string.format("MANA FILTERED +%d (%.1f%%): reason=spike, timeSince=%.3fs",
                gained, percentGain * 100, timeSinceLastTick))
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
            local oldTickTime = self.lastManaTickTime
            self.lastManaTickTime = self.lastManaTickTime + (ticksMissed * C.TICK_RATE)
            
            -- Debug: Log phantom tick advancement
            TickLog(string.format("MANA PHANTOM tick: advanced by %d ticks (%.3fs), mana=%d/%d",
                ticksMissed, now - oldTickTime, currentMana, maxMana))
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
    
    -- Don't show ticker until we have confirmed tick data
    -- This prevents showing a meaningless ticker after UI reload, zone change, etc.
    if not self.hasConfirmedManaTick then
        return 0  -- No confirmed tick data yet
    end
    
    if self.lastManaTickTime <= 0 then
        return 0  -- No tick data yet (shouldn't happen if hasConfirmedManaTick is true)
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
-- 
-- SIMPLIFIED APPROACH:
-- - lastManaSpendTime is the anchor (when 5SR started)
-- - lastManaTickTime is the source of truth for tick cycle timing
-- - nextFullTick = lastManaTickTime + ceil((time5SREnds - lastManaTickTime) / 2) * 2
-- - Progress = (now - lastManaSpendTime) / (nextFullTick - lastManaSpendTime)
-- - Any observed tick updates lastManaTickTime, automatically recalibrating the prediction
-- - We pin at 100% if countdown completed but tick not yet observed
-- - We only switch to normal 2s mode when we observe a tick AFTER 5SR ended
function TickTracker:GetFullTickProgress()
    local FSR = addon.FiveSecondRule
    local now = GetTime()
    
    if not FSR then
        return self:GetManaTickProgress()
    end
    
    -- Need confirmed tick data to calculate
    if not self.hasConfirmedManaTick or self.lastManaTickTime <= 0 then
        return self:GetManaTickProgress()
    end
    
    -- Get the anchor times
    local lastManaSpendTime = FSR.lastManaCastTime
    
    -- If no mana has been spent yet, use normal 2s tick progress
    if lastManaSpendTime <= 0 then
        return self:GetManaTickProgress()
    end
    
    local time5SREnds = lastManaSpendTime + C.FIVE_SECOND_RULE_DURATION
    
    -- KEY: Only switch to normal 2s mode when we've observed a tick AFTER 5SR ended
    -- This ensures we don't reset the denominator from 5-7s to 2s prematurely
    if self.lastManaTickTime >= time5SREnds then
        self.fullTickPinnedLogged = false  -- Reset for next 5SR
        self.earliestPredictedFullTick = 0  -- Reset prediction tracking
        self.predictionAnchorTime = 0
        return self:GetManaTickProgress()
    end
    
    -- If the anchor changed (user cast again), reset our prediction tracking
    if lastManaSpendTime ~= self.predictionAnchorTime then
        self.earliestPredictedFullTick = 0
        self.predictionAnchorTime = lastManaSpendTime
    end
    
    -- Calculate when the next full tick will arrive
    -- Full tick = first tick to occur AFTER 5SR ends
    local timeSinceLastTickAt5SREnd = time5SREnds - self.lastManaTickTime
    local ticksNeeded = math.ceil(timeSinceLastTickAt5SREnd / C.TICK_RATE)
    if ticksNeeded < 1 then ticksNeeded = 1 end
    
    local nextFullTickTime = self.lastManaTickTime + (ticksNeeded * C.TICK_RATE)
    
    -- Prevent "rewinding" - if recalibration predicts a LATER tick, keep the earlier prediction
    -- This avoids the progress bar jumping backwards, which looks bad
    if self.earliestPredictedFullTick > 0 then
        nextFullTickTime = math.min(self.earliestPredictedFullTick, nextFullTickTime)
    end
    self.earliestPredictedFullTick = nextFullTickTime
    
    -- Calculate progress from when mana was spent to when full tick arrives
    local totalDuration = nextFullTickTime - lastManaSpendTime
    local elapsed = now - lastManaSpendTime
    local progress = elapsed / totalDuration
    
    -- Debug log when prediction changes significantly or when entering pinned state
    if progress >= 1.0 then
        -- Pin at 100% until we observe the full tick
        if not self.fullTickPinnedLogged then
            TickLog(string.format("MANA FULLTICK: pinned at 100%%, waiting for tick (lastTick=%.3f, nextFull=%.3f)",
                self.lastManaTickTime, nextFullTickTime))
            self.fullTickPinnedLogged = true
        end
        return 1.0
    end
    
    -- Reset pinned flag when not pinned (allows re-logging if we enter pinned state again)
    self.fullTickPinnedLogged = false
    
    return math.min(1, math.max(0, progress))
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
-- Shapeshift Handling (for Druids)
-------------------------------------------------------------------------------

-- Call this when UPDATE_SHAPESHIFT_FORM fires
function TickTracker:OnShapeshiftChange()
    local form = GetShapeshiftForm()
    local now = GetTime()
    local wasInEnergyForm = (self.lastKnownForm == C.DRUID_FORM.CAT)
    local nowInEnergyForm = (form == C.DRUID_FORM.CAT)
    
    -- Leaving cat form
    if wasInEnergyForm and not nowInEnergyForm then
        TickLog(string.format("FORM left cat form (to form %d), lastTickTime was %.3f",
            form, self.lastEnergyTickTime))
        self.formChangeTime = now
    end
    
    -- Entering cat form - RESETS the energy tick timer
    -- This is the core mechanic that makes powershifting work in TBC:
    -- - Druid waits for a tick, then immediately shifts out and back in
    -- - Gets Furor/Wolfshead energy instantly
    -- - Tick timer resets, so next tick is 2s away
    -- - Net gain: got the tick + bonus energy in rapid succession
    if nowInEnergyForm and not wasInEnergyForm then
        local timeSinceFormChange = self.formChangeTime > 0 and (now - self.formChangeTime) or 0
        
        -- Reset tick timer - entering Cat Form starts a fresh 2-second cycle
        self.lastEnergyTickTime = now
        self.hasConfirmedTick = true  -- Form entry gives us confirmed timing (we know next tick is 2s away)
        
        -- Reset sample to avoid misinterpreting Furor/Wolfshead energy as a tick
        local currentEnergy = UnitPower("player", C.POWER_TYPE.ENERGY)
        self.lastSampleEnergy = currentEnergy
        
        TickLog(string.format("FORM entered cat form, timeOutOfForm=%.3fs, RESET tick timer, energy=%d (Furor/Wolfshead)",
            timeSinceFormChange, currentEnergy))
    end
    
    self.lastKnownForm = form
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
    self.hasConfirmedTick = true  -- If ResourcePrediction detected a tick, we have confirmed data
end

function TickTracker:SyncManaTickTime(time)
    self.lastManaTickTime = time or GetTime()
    self.hasConfirmedManaTick = true  -- If ResourcePrediction detected a tick, we have confirmed data
end

-- Initialize/reset tracking (call this on PLAYER_ENTERING_WORLD)
-- Resets tick confirmation since we can't trust timing across loading screens
function TickTracker:InitFormTracking()
    self.lastKnownForm = GetShapeshiftForm()
    
    -- Reset energy tick state
    self.hasConfirmedTick = false  -- Reset confirmation - need to observe a real tick
    self.lastEnergyTickTime = 0    -- Clear stale tick time
    self.lastSampleEnergy = 0      -- Clear stale energy sample
    
    -- Reset mana tick state
    self.hasConfirmedManaTick = false  -- Reset confirmation - need to observe a real tick
    self.lastManaTickTime = 0          -- Clear stale tick time
    self.lastSampleMana = 0            -- Clear stale mana sample
    self.prevSampleMana = 0
    self.fullTickPinnedLogged = false  -- Clear log spam flag
    self.earliestPredictedFullTick = 0 -- Clear prediction tracking
    self.predictionAnchorTime = 0
    
    TickLog(string.format("INIT tracking reset, current form=%d, waiting for confirmed ticks", self.lastKnownForm))
end
