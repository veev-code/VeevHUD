--[[
    VeevHUD - Icon State Engine Module
    Pure state computation for cooldown icons.

    Queries WoW APIs (cooldowns, buffs, usability, charges) and produces
    a state table consumed by CooldownIcons for rendering. Display code
    NEVER queries game state directly — it reads this engine's output.

    Follows the WeakAuras architectural pattern: complete separation
    between state production (triggers) and state consumption (display).
]]

local ADDON_NAME, addon = ...
local C = addon.Constants

-- Localized WoW API functions (hot path)
local GetTime = GetTime
local GetSpellInfo = GetSpellInfo
local UnitExists = UnitExists
local UnitCanAttack = UnitCanAttack
local UnitIsFriend = UnitIsFriend
local UnitAffectingCombat = UnitAffectingCombat
local IsResting = IsResting
local IsUsableSpell = IsUsableSpell
local IsCurrentSpell = IsCurrentSpell
local GetActionInfo = GetActionInfo
local GetActionCooldown = GetActionCooldown
local GetItemCount = GetItemCount
local UnitGUID = UnitGUID
local HasAction = HasAction
local GetActionTexture = GetActionTexture
local GetItemIcon = GetItemIcon
local GetSpellTexture = GetSpellTexture

local IconStateEngine = {}
addon:RegisterModule("IconStateEngine", IconStateEngine)

-- Pre-allocated reusable state table (zero alloc per tick)
IconStateEngine._state = {}

-- Per-target dodge expiration times for dodge-reactive abilities (e.g., Overpower)
-- Keyed by destGUID → expiry time. Entries expire naturally.
IconStateEngine.dodgeWindows = {}

-- Cached GetTime() value, set once per tick via SetTime()
IconStateEngine.now = 0

function IconStateEngine:Initialize()
    self.Utils = addon.Utils
    self.C = addon.Constants
    self.Database = addon.Database

    -- Module references (cached for hot path)
    self.auraState = addon:GetModule("AuraState")
    self.totemBar = addon:GetModule("TotemTracker")
    self.glowManager = addon:GetModule("GlowManager")
end

-------------------------------------------------------------------------------
-- Public API: Time Management
-------------------------------------------------------------------------------

function IconStateEngine:SetTime(now)
    self.now = now
end

-------------------------------------------------------------------------------
-- Public API: Dodge Window Management
-------------------------------------------------------------------------------

function IconStateEngine:RecordDodge(targetGUID, expirationTime)
    self.dodgeWindows[targetGUID] = expirationTime
end

-------------------------------------------------------------------------------
-- Action bar cooldown fallback for item-based cooldowns (e.g., Soulstone)
-- GetItemCooldown() fails when the item is consumed. GetActionCooldown()
-- works like the native action bar: it returns the cooldown even without
-- the item in bags, and survives /reload.
-------------------------------------------------------------------------------

local function FindActionBarSlotForSpell(spellID, spellData)
    local LibSpellDB = addon.LibSpellDB
    if not LibSpellDB then return nil end

    local rankSet = LibSpellDB:GetAllRankIDs(spellID)

    -- Build item set for matching item-type action bar slots
    local itemSet
    if spellData and spellData.cooldownItemIDs then
        itemSet = {}
        for _, id in ipairs(spellData.cooldownItemIDs) do
            itemSet[id] = true
        end
    end

    -- Pass 1: Match by GetActionInfo type + ID.
    -- Prefer the slot with an active cooldown (the spell "Create Soulstone" has no
    -- cooldown, but the item does — if both are on the bar, pick the right one).
    local fallbackSlot
    for slot = 1, 120 do
        local actionType, id = GetActionInfo(slot)
        local isMatch = false
        if actionType == "spell" and id and rankSet and rankSet[id] then
            isMatch = true
        elseif actionType == "item" and id and itemSet and itemSet[id] then
            isMatch = true
        end
        if isMatch then
            local start, dur = GetActionCooldown(slot)
            if start and start > 0 and dur > 1.5 then
                return slot  -- Has active cooldown — this is the one we want
            end
            fallbackSlot = fallbackSlot or slot
        end
    end

    -- Pass 2: Match by icon texture (handles consumed items where GetActionInfo
    -- may not return the expected type/id, but the slot still has the icon + cooldown).
    -- Check both the spell icon and the item icons since they may differ.
    local textures = {}
    local spellTexture = GetSpellTexture(spellID)
    if spellTexture then textures[spellTexture] = true end
    if spellData and spellData.cooldownItemIDs then
        for _, itemID in ipairs(spellData.cooldownItemIDs) do
            local itemTexture = GetItemIcon(itemID)
            if itemTexture then textures[itemTexture] = true end
        end
    end
    for slot = 1, 120 do
        if HasAction(slot) then
            local texture = GetActionTexture(slot)
            if texture and textures[texture] then
                local start, dur = GetActionCooldown(slot)
                if start and start > 0 and dur > 1.5 then
                    return slot
                end
                fallbackSlot = fallbackSlot or slot
            end
        end
    end

    return fallbackSlot
end

-------------------------------------------------------------------------------
-- Public API: Spell Query Helpers
-- Used by state computation and by external callers (range indicator, events)
-------------------------------------------------------------------------------

-- Check if a buff is active on the player (for shared CD abilities like Reck/Retal/SWall)
-- Returns: isActive, remaining, duration, stacks
function IconStateEngine:GetPlayerBuff(spellID)
    local spellName = GetSpellInfo(spellID)
    local aura = self.Utils:GetCachedBuff("player", spellID, spellName)

    if aura then
        local remaining = 0
        if aura.expirationTime and aura.expirationTime > 0 then
            remaining = aura.expirationTime - self.now
            if remaining < 0 then remaining = 0 end
        end
        return true, remaining, aura.duration or 0, aura.count or 0
    end

    return false, 0, 0, 0
end

-- Check if a buff is active on the relevant unit (fallback for when AuraState doesn't track)
-- Used for shared CD abilities and other buffs that need direct scanning
--
-- When checkSelfOnly is true: always checks player
-- When checkSelfOnly is false: follows target context (ally if targeting ally, else self)
-- spellData (optional): if provided and has appliesBuff, checks those buff IDs instead
--
-- Filters out buffs cast by other players (source is a known non-player unit like
-- "party1", "raid5"). This prevents another priest's Renew from showing as active
-- on your Renew icon. Accepts source == "player", "pet", or nil (totems, items,
-- permanent buffs like Shadowform where source may not be reported).
--
-- Returns: isActive, remaining, duration, stacks
function IconStateEngine:GetRelevantBuff(spellID, checkSelfOnly, spellData)
    -- Determine which unit to check
    local unit = "player"

    if not checkSelfOnly then
        local db = addon.db.profile.icons
        local useTargettarget = db.auraTargettargetSupport

        local targetExists = UnitExists("target")
        local targetIsEnemy = targetExists and UnitCanAttack("player", "target")
        local targetIsFriend = targetExists and UnitIsFriend("player", "target")

        if targetIsFriend then
            -- Targeting an ally - check them for the buff
            unit = "target"
        elseif targetIsEnemy then
            -- Targeting an enemy (including neutral mobs) - check targettarget if friendly (and enabled), else self
            if useTargettarget and UnitExists("targettarget") and UnitIsFriend("player", "targettarget") then
                unit = "targettarget"
            end
            -- else: fallback to self (already set)
        end
        -- No target or neutral: fallback to self (already set)
    end

    -- If spell has appliesBuff (buff IDs differ from cast spell, e.g., Soulstone),
    -- check those buff IDs on the unit instead of the cast spell name
    if spellData and spellData.appliesBuff then
        for _, buffID in ipairs(spellData.appliesBuff) do
            local buffName = GetSpellInfo(buffID)
            if buffName then
                local aura = self.Utils:GetCachedBuff(unit, buffID, buffName)
                local src = aura and aura.source
                if aura and (not src or src == "player" or src == "pet") then
                    local remaining = 0
                    if aura.expirationTime and aura.expirationTime > 0 then
                        remaining = aura.expirationTime - self.now
                        if remaining < 0 then remaining = 0 end
                    end
                    return true, remaining, aura.duration or 0, aura.count or 0
                end
            end
        end
        return false, 0, 0, 0
    end

    local spellName = GetSpellInfo(spellID)
    if not spellName then return false, 0, 0, 0 end

    local aura = self.Utils:GetCachedBuff(unit, spellID, spellName)

    local src = aura and aura.source
    if aura and (not src or src == "player" or src == "pet") then
        local remaining = 0
        if aura.expirationTime and aura.expirationTime > 0 then
            remaining = aura.expirationTime - self.now
            if remaining < 0 then remaining = 0 end
        end
        return true, remaining, aura.duration or 0, aura.count or 0
    end

    return false, 0, 0, 0
end

-- Check for target lockout debuff (e.g., Weakened Soul for PWS, Forbearance for Paladin spells)
-- Checks the unit the spell would actually land on (same target context as GetRelevantBuff):
--   Targeting friendly → check them. Targeting enemy → check self (auto-self-cast). No target → check self.
-- Returns: isActive, remaining, duration, expirationTime
-- Note: Lockout debuffs are checked regardless of who applied them (any priest's Weakened Soul blocks your PWS)
function IconStateEngine:GetTargetLockoutDebuff(debuffSpellID, isSelfOnly)
    if not debuffSpellID then return false, 0, 0, 0 end

    local debuffName = GetSpellInfo(debuffSpellID)
    if not debuffName then return false, 0, 0, 0 end

    -- Determine which unit to check using the same logic as helpful effects
    local unit = "player"

    if not isSelfOnly then
        local db = addon.db.profile.icons
        local useTargettarget = db.auraTargettargetSupport

        local targetExists = UnitExists("target")
        local targetIsEnemy = targetExists and UnitCanAttack("player", "target")
        local targetIsFriend = targetExists and UnitIsFriend("player", "target")

        if targetIsFriend then
            unit = "target"
        elseif targetIsEnemy then
            if useTargettarget and UnitExists("targettarget") and UnitIsFriend("player", "targettarget") then
                unit = "targettarget"
            end
        end
    end

    -- Check target-context unit (the unit the spell would actually land on)
    local aura = self.Utils:GetCachedDebuff(unit, debuffSpellID, debuffName)

    if aura then
        local remaining = 0
        if aura.expirationTime and aura.expirationTime > 0 then
            remaining = aura.expirationTime - self.now
            if remaining < 0 then remaining = 0 end
        end
        return true, remaining, aura.duration or 0, aura.expirationTime or 0
    end

    return false, 0, 0, 0
end

function IconStateEngine:IsSpellUsable(spellID)
    -- Get effective spell ID (action bar rank, or highest known rank)
    -- This ensures we check usability for the same rank used for cost calculations
    local effectiveSpellID = self.Utils:GetEffectiveSpellID(spellID)

    if C_Spell and C_Spell.IsSpellUsable then
        local isUsable, notEnoughMana = C_Spell.IsSpellUsable(effectiveSpellID)
        return isUsable, notEnoughMana
    elseif IsUsableSpell then
        -- Try spell NAME first (like WeakAuras does), then fall back to ID
        local spellName = GetSpellInfo(effectiveSpellID)
        if spellName then
            local usable, noMana = IsUsableSpell(spellName)
            if usable ~= nil then
                return usable, noMana
            end
        end
        return IsUsableSpell(effectiveSpellID)
    end
    return true, false
end

function IconStateEngine:GetSpellCharges(spellID)
    if GetSpellCharges then
        local charges, maxCharges, start, duration = GetSpellCharges(spellID)
        return charges, maxCharges, start, duration
    end
    return nil, nil
end

-------------------------------------------------------------------------------
-- Public API: Main State Computation
-------------------------------------------------------------------------------

function IconStateEngine:ComputeIconState(frame, db)
    local spellID = frame.spellID
    local actualSpellID = frame.actualSpellID or spellID
    if not spellID then
        wipe(self._state)
        return self._state
    end

    -- Reusable state table (pre-allocated, zero alloc per tick)
    local s = self._state

    -- Seed identity fields
    s.spellID = spellID
    s.actualSpellID = actualSpellID
    s.spellData = frame.spellData

    -- 1. Compute aura state (buff/debuff detection, BuffGroup swap, totem suppression)
    self:_ComputeAuraState(frame, db, s)

    -- 2. Compute cooldown state (raw CD, item CD, GCD override, lockout, usability, charges)
    self:_ComputeCooldownState(frame, db, s)

    -- 3. Compute prediction state (resource timer spiral, fallback)
    self:_ComputePredictionState(frame, db, s)

    -- 4. Compute visual flags (alpha, desaturate, showSpinner, showText, showGlow)
    self:_ComputeVisualFlags(frame, db, s)

    -- 5. Derive ready-glow parameters for the orchestrator
    s.isReactive = frame.isReactive or false
    s.predictionIsLimitingFactor = s.showPredictionSpiral and s.predictionRemaining > 0

    -- 6. Dodge-reactive glow override
    s.dodgeGlowOverride = false
    if frame.dodgeReactive then
        local targetGUID = UnitGUID("target")
        local dodgeExpires = targetGUID and self.dodgeWindows[targetGUID]
        if dodgeExpires then
            if self.now >= dodgeExpires then
                self.dodgeWindows[targetGUID] = nil
            else
                local isOffRealCooldown = not self.Utils:IsOnRealCooldown(s.remaining, s.duration)
                if isOffRealCooldown and s.canAfford then
                    s.dodgeGlowOverride = true
                end
            end
        end
    end

    -- 7. Queued spell state
    s.isQueued = db.showQueuedHighlight and IsCurrentSpell and IsCurrentSpell(s.actualSpellID) or false

    -- 8. Copy frame-persistent field for orchestrator
    s.gcdContinueText = frame.gcdContinueText

    return s
end

-------------------------------------------------------------------------------
-- Internal: Aura State
-- Detects active buffs/debuffs, handles BuffGroup target-aware swaps,
-- suppresses totem auras when TotemTracker is active.
-------------------------------------------------------------------------------

function IconStateEngine:_ComputeAuraState(frame, db, s)
    local spellID = s.spellID
    local actualSpellID = s.actualSpellID
    local spellData = s.spellData

    s.auraActive = false
    s.auraRemaining = 0
    s.auraDuration = 0
    s.auraStacks = 0
    s.swapTexture = nil

    -- Pre-compute spell targeting behavior
    s.checkSelfOnly = true
    if addon.LibSpellDB then
        s.checkSelfOnly = addon.LibSpellDB:IsSelfOnly(spellData)
    end

    if db.showAuraTracking then
        local auraTracker = self.auraState
        if auraTracker and auraTracker.GetAuraState then
            s.auraActive, s.auraRemaining, s.auraDuration, s.auraStacks = auraTracker:GetAuraState(spellID)
        end

        -- Also check buffs directly for shared CD abilities (Reck/Retal/SWall)
        local isBuffActive, buffRemaining, buffDuration, buffStacks = self:GetRelevantBuff(actualSpellID, s.checkSelfOnly, spellData)
        if isBuffActive then
            if buffDuration == 0 or not s.auraActive then
                s.auraActive = true
                s.auraRemaining = buffRemaining
                s.auraDuration = buffDuration
                s.auraStacks = buffStacks or 0
            end
        end
    end

    -- Exclusive BuffGroup target-aware swap
    if not s.auraActive and db.showAuraTracking and addon.LibSpellDB then
        local groupName, groupInfo = addon.LibSpellDB:GetBuffGroup(spellID)
        if groupName and groupInfo and groupInfo.relationship == "exclusive" then
            local myAuraTarget = addon.LibSpellDB:GetAuraTarget(spellID) or "self"
            local auraTracker = self.auraState
            for _, memberID in ipairs(groupInfo.spells) do
                local memberAuraTarget = addon.LibSpellDB:GetAuraTarget(memberID) or "self"
                if memberID ~= spellID and memberAuraTarget == myAuraTarget then
                    local mActive, mRemaining, mDuration, mStacks
                    if auraTracker and auraTracker.GetAuraState then
                        mActive, mRemaining, mDuration, mStacks = auraTracker:GetAuraState(memberID)
                    end
                    if not mActive then
                        local mData = addon.LibSpellDB:GetSpellInfo(memberID)
                        if mData then
                            local mActualID = self.Utils:GetEffectiveSpellID(memberID) or memberID
                            local mCheckSelf = addon.LibSpellDB:IsSelfOnly(mData)
                            mActive, mRemaining, mDuration, mStacks = self:GetRelevantBuff(mActualID, mCheckSelf, mData)
                        end
                    end
                    if mActive then
                        local mData = addon.LibSpellDB:GetSpellInfo(memberID)
                        if mData then
                            local mActualID = self.Utils:GetEffectiveSpellID(memberID) or memberID
                            s.swapTexture = mData.icon or self.Utils:GetSpellTexture(mActualID)
                            s.spellID = memberID
                            s.actualSpellID = mActualID
                            s.spellData = mData
                            s.checkSelfOnly = addon.LibSpellDB:IsSelfOnly(mData)
                            s.auraActive = true
                            s.auraRemaining = mRemaining
                            s.auraDuration = mDuration
                            s.auraStacks = mStacks or 0
                            break
                        end
                    end
                end
            end
        end
    end

    -- Reagent count (e.g., Soul Shards) — show as stack count when no aura stacks active
    if s.auraStacks == 0 and addon.LibSpellDB then
        local reagentItemID = addon.LibSpellDB:GetReagentItemID(spellID)
        if reagentItemID then
            s.auraStacks = GetItemCount(reagentItemID)
        end
    end

    -- Suppress aura display for element-tagged TOTEM spells when totem element slots are active
    if frame.isTotem then
        local totemBarMod = self.totemBar
        if totemBarMod and totemBarMod.IsActive and totemBarMod:IsActive() then
            s.auraActive = false
            s.auraRemaining = 0
            s.auraDuration = 0
            s.auraStacks = 0
        end
    end
end

-------------------------------------------------------------------------------
-- Internal: Cooldown State
-- Raw cooldown, item cooldown fallback, GCD override, actionable time,
-- target lockout, usability, reactive window, power info, charges.
-------------------------------------------------------------------------------

function IconStateEngine:_ComputeCooldownState(frame, db, s)
    local spellID = s.spellID
    local actualSpellID = s.actualSpellID
    local spellData = s.spellData
    local now = self.now

    -- Get cooldown info
    local remaining, duration, cdEnabled, cdStartTime = self.Utils:GetSpellCooldown(actualSpellID)

    -- Item cooldown fallback (3-tier: GetItemCooldown → GetActionCooldown → frame cache)
    if spellData and spellData.cooldownItemIDs and not self.Utils:IsOnRealCooldown(remaining, duration) then
        local foundCooldown = false

        -- Tier 1: Direct item cooldown query
        if addon.LibSpellDB then
            local itemRemaining, itemDuration, itemStartTime = addon.LibSpellDB:GetItemCooldown(spellData)
            if itemRemaining then
                remaining = itemRemaining
                duration = itemDuration
                cdStartTime = itemStartTime
                frame.itemCdStart = itemStartTime
                frame.itemCdDuration = itemDuration
                foundCooldown = true
            end
        end

        -- Tier 2: Action bar cooldown
        if not foundCooldown then
            local slot = frame.actionBarSlot
            if slot then
                local start, dur = GetActionCooldown(slot)
                if start and start > 0 and dur > self.C.GCD_THRESHOLD then
                    local actionRemaining = (start + dur) - now
                    if actionRemaining > 0 then
                        remaining = actionRemaining
                        duration = dur
                        cdStartTime = start
                        frame.itemCdStart = start
                        frame.itemCdDuration = dur
                        foundCooldown = true
                    end
                end
            end

            if not foundCooldown and (not frame.actionBarSlotNextScan or now >= frame.actionBarSlotNextScan) then
                local newSlot = FindActionBarSlotForSpell(spellID, spellData)
                if newSlot then
                    frame.actionBarSlot = newSlot
                    local start, dur = GetActionCooldown(newSlot)
                    if start and start > 0 and dur > self.C.GCD_THRESHOLD then
                        local actionRemaining = (start + dur) - now
                        if actionRemaining > 0 then
                            remaining = actionRemaining
                            duration = dur
                            cdStartTime = start
                            frame.itemCdStart = start
                            frame.itemCdDuration = dur
                            foundCooldown = true
                        end
                    end
                end
                frame.actionBarSlotNextScan = now + 1
            end
        end

        -- Populate cache from active aura timing
        if not foundCooldown and not frame.itemCdStart
            and s.auraActive and s.auraDuration > 0 and s.auraRemaining > 0 then
            frame.itemCdStart = now - (s.auraDuration - s.auraRemaining)
            frame.itemCdDuration = s.auraDuration
        end

        -- Tier 3: Frame cache
        if not foundCooldown and frame.itemCdStart and frame.itemCdDuration then
            local cachedRemaining = (frame.itemCdStart + frame.itemCdDuration) - now
            if cachedRemaining > 0 then
                remaining = cachedRemaining
                duration = frame.itemCdDuration
                cdStartTime = frame.itemCdStart
            else
                frame.itemCdStart = nil
                frame.itemCdDuration = nil
            end
        end
    end

    -- Item availability and consumption detection
    if spellData and spellData.cooldownItemIDs then
        local itemAvailable = false
        for _, itemID in ipairs(spellData.cooldownItemIDs) do
            if GetItemCount(itemID) > 0 then
                itemAvailable = true
                break
            end
        end

        if spellData.itemCooldown
            and frame.itemWasAvailable and not itemAvailable
            and not self.Utils:IsOnRealCooldown(remaining, duration) then
            frame.itemCdStart = now
            frame.itemCdDuration = spellData.itemCooldown
            remaining = spellData.itemCooldown
            duration = spellData.itemCooldown
            cdStartTime = now
        end

        frame.itemWasAvailable = itemAvailable

        if itemAvailable
            and not s.auraActive
            and not self.Utils:IsOnRealCooldown(remaining, duration) then
            s.auraActive = true
            s.auraDuration = 0
            s.auraRemaining = 0
        end
    end

    -- GCD override protection
    local GCD_THRESHOLD = self.C.GCD_THRESHOLD
    if duration > GCD_THRESHOLD and cdStartTime > 0 then
        frame.actualCdStart = cdStartTime
        frame.actualCdDuration = duration
    elseif duration > 0 and duration <= GCD_THRESHOLD and frame.actualCdStart and frame.actualCdDuration then
        local trackedRemaining = (frame.actualCdStart + frame.actualCdDuration) - now
        if trackedRemaining > GCD_THRESHOLD then
            cdStartTime = frame.actualCdStart
            duration = frame.actualCdDuration
            remaining = trackedRemaining
        else
            frame.actualCdStart = nil
            frame.actualCdDuration = nil
        end
    elseif remaining <= 0 then
        frame.actualCdStart = nil
        frame.actualCdDuration = nil
    end

    -- Store timing results
    s.remaining = remaining
    s.duration = duration
    s.cdStartTime = cdStartTime

    -- Derived cooldown state
    s.isOnGCD = self.Utils:IsOnGCD(remaining, duration)
    s.isOnActualCooldown = self.Utils:IsOnRealCooldown(remaining, duration)
    s.hasCooldownPriority = spellData and spellData.cooldownPriority
    s.isPermanentBuffActive = s.auraActive and s.auraDuration == 0 and s.auraRemaining == 0

    -- Actionable time for dynamic sorting
    local effectiveCooldownRemaining = s.isOnActualCooldown and remaining or 0
    if s.isPermanentBuffActive then
        frame.actionableTime = 999999
    elseif s.hasCooldownPriority then
        frame.actionableTime = effectiveCooldownRemaining
    else
        frame.actionableTime = math.max(effectiveCooldownRemaining, s.auraRemaining or 0)
    end

    -- Target lockout debuff
    s.lockoutIsLimitingFactor = false
    if spellData and spellData.targetLockoutDebuff then
        local tlActive, tlRemaining, tlDuration, tlExpiration =
            self:GetTargetLockoutDebuff(spellData.targetLockoutDebuff, s.checkSelfOnly)

        if tlActive and tlRemaining > 0 then
            if tlRemaining > remaining then
                s.lockoutIsLimitingFactor = true
                remaining = tlRemaining
                duration = tlDuration
                cdStartTime = tlExpiration - tlDuration
                s.remaining = remaining
                s.duration = duration
                s.cdStartTime = cdStartTime
                -- Recompute: lockout overrode remaining/duration after initial computation
                s.isOnGCD = self.Utils:IsOnGCD(remaining, duration)
                s.isOnActualCooldown = self.Utils:IsOnRealCooldown(remaining, duration)
            end
            if not s.isPermanentBuffActive then
                frame.actionableTime = math.max(frame.actionableTime, tlRemaining)
            end
        end

    end

    -- GCD/cooldown classification
    local readyGlowThreshold = db.readyGlowThreshold
    s.almostReady = remaining > 0 and remaining <= readyGlowThreshold and s.isOnActualCooldown

    -- Usability (IsUsableSpell doesn't check reagents in Classic, so check separately)
    s.isUsable = self:IsSpellUsable(actualSpellID)
    if s.isUsable and frame.reagentItemID then
        s.isUsable = GetItemCount(frame.reagentItemID) > 0
    end

    -- Update actionableTime for conditional spells
    if not s.isPermanentBuffActive and frame.actionableTime == 0 and not s.isUsable then
        frame.actionableTime = 60
    end

    -- Reactive window tracking
    if frame.reactiveWindow then
        local wasUsableForWindow = frame.reactiveWindowWasUsable or false
        if s.isUsable and not wasUsableForWindow then
            frame.reactiveWindowStart = now
            frame.reactiveWindowExpires = now + frame.reactiveWindow
        end
        if not s.isUsable and wasUsableForWindow then
            frame.reactiveWindowStart = nil
            frame.reactiveWindowExpires = nil
        end
        if frame.reactiveWindowExpires and now >= frame.reactiveWindowExpires then
            frame.reactiveWindowStart = nil
            frame.reactiveWindowExpires = nil
        end
        frame.reactiveWindowWasUsable = s.isUsable
    end

    -- Spell activation overlay
    s.hasOverlay = self.glowManager:HasSpellActivationOverlay(actualSpellID)

    -- Power/resource info
    local powerCost, currentPower, maxPower, powerType, powerColor = self.Utils:GetSpellPowerInfo(actualSpellID)
    s.hasResourceCost = powerCost and powerCost > 0
    s.resourcePercent = s.hasResourceCost and math.min(1, currentPower / powerCost) or 1
    s.canAfford = s.resourcePercent >= 1
    s.powerColor = powerColor
    s.currentPower = currentPower

    -- Charges
    local charges, maxCharges = self:GetSpellCharges(spellID)
    s.charges = charges
    s.hasCharges = maxCharges and maxCharges > 1
    s.noChargesLeft = s.hasCharges and charges == 0

end

-------------------------------------------------------------------------------
-- Internal: Prediction State
-- Resource timer spiral, fallback detection, GCD text continuation.
-------------------------------------------------------------------------------

function IconStateEngine:_ComputePredictionState(frame, db, s)
    s.predictionRemaining = 0
    s.predictionDuration = 0
    s.predictionStartTime = 0
    s.showPredictionSpiral = false
    s.inPredictionFallback = false
    local now = self.now

    local displayMode = db.resourceDisplayMode
    local displayRows = db.resourceDisplayRows
    local rowIndex = frame.rowIndex or 1
    local isPredictionMode = displayMode == C.RESOURCE_DISPLAY_MODE.PREDICTION
    local resourceEnabledForRow = self.Database:IsRowSettingEnabled(displayRows, rowIndex)

    -- Skip prediction when aura display takes precedence
    local auraBlocksPrediction = s.auraActive and s.auraRemaining > 0 and not s.hasCooldownPriority
    local skipPrediction = auraBlocksPrediction or s.isPermanentBuffActive or not resourceEnabledForRow

    if isPredictionMode and s.hasResourceCost and not skipPrediction then
        if s.canAfford then
            -- Can afford — clear prediction state
            if frame.predictionActive and self.Utils:IsOnGCD(s.remaining, s.duration) then
                frame.gcdContinueText = true
            end
            if frame.predictionActive then
                frame.readyGlowShown = false
            end
            frame.predictionActive = false
            frame.predictionStartTime = nil
            frame.predictionDuration = nil
            frame.predictionFallback = false
            frame.predictionLastPower = nil
        else
            frame.gcdContinueText = nil
            local timeUntilAffordable = 0
            local ResourcePrediction = addon.ResourcePrediction
            if ResourcePrediction then
                timeUntilAffordable = ResourcePrediction:GetTimeUntilAffordable(s.spellID)
            end

            if timeUntilAffordable > 0 and timeUntilAffordable < 0.1 then
                timeUntilAffordable = 0.1
            end

            local isOffCooldown = self.Utils:IsOffCooldown(s.remaining, s.duration)
            local cdRemaining = isOffCooldown and 0 or s.remaining

            local effectiveWait = math.max(cdRemaining, timeUntilAffordable)
            if timeUntilAffordable > 0 and s.remaining and s.remaining > 0 then
                effectiveWait = math.max(effectiveWait, s.remaining)
            end

            local resourcesDecreased = frame.predictionActive and frame.predictionLastPower and s.currentPower < frame.predictionLastPower

            if frame.predictionFallback and not resourcesDecreased then
                s.inPredictionFallback = true
            elseif effectiveWait > 0 then
                if not frame.predictionActive or resourcesDecreased then
                    frame.predictionActive = true
                    frame.predictionStartTime = now
                    frame.predictionDuration = effectiveWait
                    frame.predictionFallback = false
                    if not resourcesDecreased then
                        frame.readyGlowShown = false
                    end
                end

                frame.predictionLastPower = s.currentPower

                local elapsed = now - frame.predictionStartTime
                s.predictionRemaining = math.max(0, frame.predictionDuration - elapsed)
                s.predictionDuration = frame.predictionDuration
                s.predictionStartTime = frame.predictionStartTime

                if s.predictionRemaining < 0.05 then
                    frame.predictionFallback = true
                    s.inPredictionFallback = true
                else
                    s.showPredictionSpiral = true
                end
            else
                frame.predictionFallback = true
                s.inPredictionFallback = true
            end
        end
    elseif not isPredictionMode then
        frame.predictionActive = false
        frame.predictionStartTime = nil
        frame.predictionDuration = nil
        frame.predictionFallback = false
    end

    -- Clear GCD text continuation flag when no longer on GCD
    if frame.gcdContinueText and not self.Utils:IsOnGCD(s.remaining, s.duration) then
        frame.gcdContinueText = nil
    end
end

-------------------------------------------------------------------------------
-- Internal: Visual Flags
-- Alpha, desaturation, showSpinner, showText, showGlow computation.
-- Handles: timed aura, permanent buff, no-dim, dim-on-cooldown states.
-------------------------------------------------------------------------------

function IconStateEngine:_ComputeVisualFlags(frame, db, s)
    local rowIndex = frame.rowIndex or 1
    local now = self.now

    -- Initialize visual output
    s.alpha = db.readyAlpha
    s.desaturate = false
    s.showSpinner = false
    s.showText = false
    s.showGlow = false
    s.showAuraActive = false
    s.auraDisplayRemaining = 0
    s.auraDisplayDuration = 0

    -- Reactive window: inject synthetic aura data
    if frame.reactiveWindow and frame.reactiveWindowExpires then
        local rwRemaining = frame.reactiveWindowExpires - now
        if rwRemaining > 0 then
            s.auraActive = true
            s.auraRemaining = rwRemaining
            s.auraDuration = frame.reactiveWindow
        end
    end

    -- Timed effect: inject synthetic aura data (Flamestrike, Distract, Consecration)
    if frame.timedEffectExpires then
        local teRemaining = frame.timedEffectExpires - now
        if teRemaining > 0 then
            s.auraActive = true
            s.auraRemaining = teRemaining
            s.auraDuration = frame.timedEffectDuration
        else
            frame.timedEffectStart = nil
            frame.timedEffectExpires = nil
        end
    end

    local dimOnCooldown = self.Database:IsRowSettingEnabled(db.dimOnCooldown, rowIndex)
    local showGCDForThisRow = self.Database:IsRowSettingEnabled(db.showGCDOn, rowIndex)

    -- Usability indicators (suppressed when resting + out of combat)
    local inCombat = UnitAffectingCombat("player")
    local isResting = IsResting()
    local showUsabilityIndicators = inCombat or not isResting

    -- Aura suppression for cooldownPriority spells
    local suppressAura = s.hasCooldownPriority and (s.isOnActualCooldown or s.hasResourceCost)

    if s.auraActive and s.auraRemaining > 0 and not suppressAura then
        -- TIMED AURA ACTIVE
        s.showAuraActive = true
        s.auraDisplayRemaining = s.auraRemaining
        s.auraDisplayDuration = s.auraDuration
        s.alpha = db.readyAlpha
        s.showGlow = true
        s.showSpinner = true
        s.showText = true

    elseif s.isPermanentBuffActive then
        -- PERMANENT BUFF ACTIVE
        s.showAuraActive = true
        s.alpha = db.readyAlpha
        s.showGlow = true

    elseif not dimOnCooldown then
        -- NO DIM ON COOLDOWN (Primary row)
        s.alpha = db.readyAlpha

        if showUsabilityIndicators then
            if s.noChargesLeft or not s.isUsable then
                s.desaturate = true
            end
        end

        if s.isOnGCD then
            s.showSpinner = true
        elseif s.isOnActualCooldown then
            s.showSpinner = true
            s.showText = s.duration >= 2
        end

        if s.almostReady then
            s.showGlow = true
        end

        if s.hasOverlay then
            s.showGlow = true
            s.desaturate = false
        end

    else
        -- DIM ON COOLDOWN (Secondary/Utility rows)
        local isRealCooldown = self.Utils:IsOnRealCooldown(s.remaining, s.duration)

        if isRealCooldown then
            s.showSpinner = true
            s.showText = s.duration >= 2

            if frame.readyGlowActive then
                s.alpha = db.readyAlpha
                s.showGlow = true
            else
                s.alpha = db.cooldownAlpha
                s.desaturate = true
            end
        elseif s.isOnGCD and showGCDForThisRow then
            s.showSpinner = true
            s.alpha = db.readyAlpha
        elseif s.noChargesLeft then
            s.alpha = db.cooldownAlpha
            s.desaturate = true
            s.showSpinner = true
            s.showText = true
        else
            s.alpha = db.readyAlpha
            if showUsabilityIndicators and not s.isUsable and db.desaturateNoResources then
                s.desaturate = true
            end
        end
    end

end
