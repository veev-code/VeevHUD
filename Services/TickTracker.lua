--[[
    VeevHUD - Tick Tracker
    Centralized tracking of energy and mana regeneration ticks
    
    Both the Energy Tick Indicator UI and Resource Prediction features
    depend on accurate tick timing. This service provides that shared state.
    
    Key concepts:
    - Energy/mana regenerate in "ticks" every 2 seconds
    - For rogues: tick timer is continuous and never resets
    - For druids: entering Cat Form RESETS the tick timer (powershifting mechanic)
    - We detect ticks by observing resource increases
    - "Phantom tick" tracking keeps timing accurate when at full resources
    - Real ticks always resync our tracking when observed
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
end

function TickTracker:SyncManaTickTime(time)
    self.lastManaTickTime = time or GetTime()
end

-- Initialize/reset tracking (call this on PLAYER_ENTERING_WORLD)
-- Resets tick confirmation since we can't trust timing across loading screens
function TickTracker:InitFormTracking()
    self.lastKnownForm = GetShapeshiftForm()
    self.hasConfirmedTick = false  -- Reset confirmation - need to observe a real tick
    self.lastEnergyTickTime = 0    -- Clear stale tick time
    self.lastSampleEnergy = 0      -- Clear stale energy sample
    TickLog(string.format("INIT tracking reset, current form=%d, waiting for confirmed tick", self.lastKnownForm))
end
