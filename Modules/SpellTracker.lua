--[[
    VeevHUD - Spell Tracker
    
    Determines which spells to display based on:
    1. Player's spec (via LibSpellDB)
    2. Whether the spell is known (learned)
    3. Whether the spell matches enabled row tags
    4. User overrides (force show/hide)
    
    No action bar scanning - spells are shown based on spec relevance.
]]

local ADDON_NAME, addon = ...

local SpellTracker = {}
addon:RegisterModule("SpellTracker", SpellTracker)

-- Tracked spells database
SpellTracker.trackedSpells = {}

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function SpellTracker:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.LibSpellDB = addon.LibSpellDB

    -- Register for talent/spell changes
    self.Events:RegisterEvent(self, "CHARACTER_POINTS_CHANGED", self.OnTalentsChanged)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)
    self.Events:RegisterEvent(self, "SPELLS_CHANGED", self.OnSpellsChanged)
    
    -- Dual spec support - fires when player switches active spec
    self.Events:RegisterEvent(self, "ACTIVE_TALENT_GROUP_CHANGED", self.OnSpecSwitched)
    self.Events:RegisterEvent(self, "PLAYER_TALENT_UPDATE", self.OnTalentsChanged)

    self.Utils:LogInfo("SpellTracker initialized")
end

function SpellTracker:OnPlayerEnteringWorld()
    self.Utils:LogInfo("SpellTracker: PLAYER_ENTERING_WORLD")
    
    -- Invalidate spellbook cache for fresh start
    self:InvalidateSpellbookCache()
    
    -- Delay to ensure everything is loaded
    if C_Timer and C_Timer.After then
        C_Timer.After(1, function()
            self:FullRescan()
        end)
    else
        self:FullRescan()
    end
end

function SpellTracker:OnTalentsChanged()
    self.Utils:LogInfo("SpellTracker: Talents changed, rescanning...")
    
    -- Invalidate spellbook cache (talents may add new spells)
    self:InvalidateSpellbookCache()
    
    -- Re-detect spec
    if self.LibSpellDB then
        local oldSpec = self.LibSpellDB:GetPlayerSpec()
        local newSpec = self.LibSpellDB:DetectPlayerSpec()
        if oldSpec ~= newSpec then
            self.Utils:LogInfo("SpellTracker: Spec changed from", oldSpec, "to", newSpec)
        end
    end
    
    self:FullRescan()
end

function SpellTracker:OnSpecSwitched()
    self.Utils:LogInfo("SpellTracker: Active talent group changed (dual spec switch)")
    
    -- Invalidate spellbook cache (different spec may have different spells)
    self:InvalidateSpellbookCache()
    
    -- Re-detect spec after switching
    if self.LibSpellDB then
        local oldSpec = self.LibSpellDB:GetPlayerSpec()
        local newSpec = self.LibSpellDB:DetectPlayerSpec()
        self.Utils:LogInfo("SpellTracker: Spec switched from", oldSpec, "to", newSpec)
        addon.playerSpec = newSpec
    end
    
    self:FullRescan()
end

function SpellTracker:OnSpellsChanged()
    self.Utils:LogDebug("SpellTracker: Spells changed")
    self:InvalidateSpellbookCache()
    self:FullRescan()
end

-------------------------------------------------------------------------------
-- Main Filtering Logic
-------------------------------------------------------------------------------

function SpellTracker:FullRescan()
    local LibSpellDB = self.LibSpellDB
    if not LibSpellDB then
        self.Utils:LogError("LibSpellDB not available")
        return
    end

    local playerClass = addon.playerClass
    local playerSpec = LibSpellDB:GetPlayerSpec()

    self.Utils:LogInfo("SpellTracker: Scanning for", playerClass, "/", playerSpec)

    -- Get all spells relevant for current spec
    local relevantSpells = LibSpellDB:GetSpellsForCurrentSpec(playerClass)
    local relevantCount = self:TableCount(relevantSpells)

    self.Utils:LogInfo("SpellTracker: Found", relevantCount, "spec-relevant spells")

    -- Build enabled tags from row config
    local enabledTags = self:GetEnabledTags()

    -- Filter by tags and known status
    wipe(self.trackedSpells)
    local tracked = 0
    local skippedUnknown = 0
    local skippedTags = 0
    local skippedFillers = 0

    for spellID, spellData in pairs(relevantSpells) do
        local shouldTrack, reason = self:ShouldTrackSpell(spellID, spellData, enabledTags)
        
        if shouldTrack then
            self.trackedSpells[spellID] = {
                spellData = spellData,
                reason = reason,
            }
            tracked = tracked + 1
        else
            if reason == "not_known" then
                skippedUnknown = skippedUnknown + 1
            elseif reason == "no_matching_tags" then
                skippedTags = skippedTags + 1
            elseif reason == "excluded" then
                skippedFillers = skippedFillers + 1
            end
        end
    end

    self.Utils:LogInfo("SpellTracker: Tracking", tracked, "spells (skipped:", skippedUnknown, "unknown,", skippedTags, "tags,", skippedFillers, "fillers)")

    -- Log details in debug mode
    if addon.db and addon.db.profile and addon.db.profile.debugMode then
        local count = 0
        for spellID, data in pairs(self.trackedSpells) do
            if count < 10 then
                local name = data.spellData.name or GetSpellInfo(spellID) or "?"
                self.Utils:LogDebug("  Tracking:", spellID, name, "(" .. data.reason .. ")")
            end
            count = count + 1
        end
        if count > 10 then
            self.Utils:LogDebug("  ... and", count - 10, "more")
        end
    end

    -- Notify CooldownIcons module
    local cooldownIcons = addon:GetModule("CooldownIcons")
    if cooldownIcons and cooldownIcons.OnTrackedSpellsChanged then
        cooldownIcons:OnTrackedSpellsChanged()
    end
    
    -- Notify AuraTracker module
    local auraTracker = addon:GetModule("AuraTracker")
    if auraTracker and auraTracker.OnTrackedSpellsChanged then
        auraTracker:OnTrackedSpellsChanged()
    end
end

function SpellTracker:ShouldTrackSpell(spellID, spellData, enabledTags)
    -- Check user override first
    local override = self:GetOverride(spellID)
    if override == true then
        return true, "override_show"
    elseif override == false then
        return false, "override_hide"
    end

    -- Check if spell matches any enabled row tag
    local hasMatchingTag = false
    local matchedTag = nil
    for _, tag in ipairs(spellData.tags) do
        if enabledTags[tag] then
            hasMatchingTag = true
            matchedTag = tag
            break
        end
    end
    if not hasMatchingTag then
        return false, "no_matching_tags"
    end

    -- Exclude spells that shouldn't be on the combat HUD
    -- (fillers, out-of-combat abilities, long buffs, spammable utility)
    if self:ShouldExcludeSpell(spellData) then
        return false, "excluded"
    end

    -- Check if spell is known
    if not self:IsSpellKnown(spellID, spellData) then
        return false, "not_known"
    end

    return true, matchedTag
end

-- Check if spell should be excluded from HUD
-- Returns true if spell should NOT be shown
function SpellTracker:ShouldExcludeSpell(spellData)
    if not spellData.tags then return false end
    
    local isFiller = false
    local isOutOfCombat = false
    local isLongBuff = false
    local hasTrackableDuration = false
    
    for _, tag in ipairs(spellData.tags) do
        if tag == "FILLER" then
            isFiller = true
        elseif tag == "OUT_OF_COMBAT" then
            isOutOfCombat = true
        elseif tag == "LONG_BUFF" then
            isLongBuff = true
        elseif tag == "DEBUFF" or tag == "HOT" or tag == "BUFF" or tag == "TRACK_BUFF" then
            hasTrackableDuration = true
        end
    end
    
    -- Always exclude OUT_OF_COMBAT abilities (resurrects, etc.)
    if isOutOfCombat then
        return true
    end
    
    -- Exclude LONG_BUFF (30+ min buffs cast out of combat)
    if isLongBuff then
        return true
    end
    
    -- Check FILLER exclusion
    if isFiller then
        -- Has a meaningful cooldown? Worth tracking
        local cooldown = spellData.cooldown or 0
        if cooldown > 0 then
            return false  -- Has CD, worth tracking
        end
        
        -- Has a short duration to track?
        if spellData.duration and spellData.duration > 0 and spellData.duration < 300 then
            if hasTrackableDuration then
                return false  -- Has trackable duration, worth showing
            end
        end
        
        -- FILLER with no CD and no short trackable duration = exclude
        return true
    end
    
    return false
end

-------------------------------------------------------------------------------
-- Spell Known Detection
-------------------------------------------------------------------------------

function SpellTracker:IsSpellKnown(spellID, spellData)
    -- Check primary spell ID
    if self:CheckSpellKnown(spellID) then
        return true
    end

    -- Check all ranks
    if spellData.ranks then
        for _, rankID in ipairs(spellData.ranks) do
            if self:CheckSpellKnown(rankID) then
                return true
            end
        end
    end

    return false
end

function SpellTracker:CheckSpellKnown(spellID)
    -- Method 1: IsSpellKnown (most reliable)
    if IsSpellKnown and IsSpellKnown(spellID) then
        return true
    end

    -- Method 2: IsPlayerSpell (fallback)
    if IsPlayerSpell and IsPlayerSpell(spellID) then
        local name = GetSpellInfo(spellID) or spellID
        self.Utils:LogInfo("SpellKnown FALLBACK Tier2 (IsPlayerSpell) used for:", name, spellID)
        return true
    end

    -- Method 3: Check spellbook cache (Classic/Anniversary fallback)
    if not self.spellbookCache then
        self:BuildSpellbookCache()
    end
    
    local name = GetSpellInfo(spellID)
    if name and self.spellbookCache[name] then
        self.Utils:LogInfo("SpellKnown FALLBACK Tier3 (spellbook cache) used for:", name, spellID)
        return true
    end

    return false
end

-- Build a cache of all spells in the player's spellbook
function SpellTracker:BuildSpellbookCache()
    self.spellbookCache = {}
    
    local i = 1
    while true do
        local spellName, spellRank = GetSpellBookItemName(i, BOOKTYPE_SPELL)
        if not spellName then break end
        
        -- Store by name (handles all ranks)
        self.spellbookCache[spellName] = true
        
        i = i + 1
    end
    
    self.Utils:LogDebug("SpellTracker: Built spellbook cache with", i - 1, "entries")
end

-- Invalidate cache when spells change
function SpellTracker:InvalidateSpellbookCache()
    self.spellbookCache = nil
end

-------------------------------------------------------------------------------
-- Tag Configuration
-------------------------------------------------------------------------------

function SpellTracker:GetEnabledTags()
    local enabledTags = {}
    local rowConfigs = addon.db and addon.db.profile and addon.db.profile.rows or {}

    for _, rowConfig in ipairs(rowConfigs) do
        if rowConfig.enabled then
            for _, tag in ipairs(rowConfig.tags) do
                enabledTags[tag] = true
            end
        end
    end

    return enabledTags
end

-------------------------------------------------------------------------------
-- User Overrides
-------------------------------------------------------------------------------

function SpellTracker:GetOverride(spellID)
    local overrides = addon.db and addon.db.profile and addon.db.profile.spellOverrides
    if overrides and overrides[spellID] ~= nil then
        return overrides[spellID]
    end
    return nil
end

function SpellTracker:SetOverride(spellID, enabled)
    if not addon.db or not addon.db.profile then return end
    
    if not addon.db.profile.spellOverrides then
        addon.db.profile.spellOverrides = {}
    end

    if enabled == nil then
        addon.db.profile.spellOverrides[spellID] = nil
    else
        addon.db.profile.spellOverrides[spellID] = enabled
    end

    self:FullRescan()
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

function SpellTracker:GetTrackedSpells()
    return self.trackedSpells
end

function SpellTracker:IsSpellTracked(spellID)
    return self.trackedSpells[spellID] ~= nil
end

function SpellTracker:GetTrackedCount()
    return self:TableCount(self.trackedSpells)
end

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------

function SpellTracker:TableCount(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do count = count + 1 end
    return count
end

-------------------------------------------------------------------------------
-- Enable/Disable
-------------------------------------------------------------------------------

function SpellTracker:Enable()
    self:FullRescan()
end

function SpellTracker:Disable()
    wipe(self.trackedSpells)
end

function SpellTracker:Refresh()
    self:FullRescan()
end
