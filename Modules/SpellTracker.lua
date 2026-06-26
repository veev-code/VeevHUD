--[[
    VeevHUD - Spell Tracker
    
    Determines which spells to display based on:
    1. Player's spec (via LibSpellDB)
    2. Whether the spell is known (learned)
    3. Whether the spell matches enabled row tags
    4. User overrides (force show/hide)
    
    No action bar scanning - spells are shown based on spec relevance.
]]

local _, addon = ...

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

    -- Season of Discovery: rune engraving grants/removes abilities (Lava Burst,
    -- Earth Shield, etc.). RUNE_UPDATED fires on engrave; PLAYER_EQUIPMENT_CHANGED
    -- catches swapping to a differently-engraved item (which RUNE_UPDATED misses).
    -- C_Engraving exists only on Classic Era / SoD clients (nil on TBC/Anniversary),
    -- so this is a no-op everywhere else.
    if C_Engraving and C_Engraving.IsEngravingEnabled and C_Engraving.IsEngravingEnabled() then
        self.Events:RegisterEvent(self, "RUNE_UPDATED", self.OnSpellsChanged)
        self.Events:RegisterEvent(self, "PLAYER_EQUIPMENT_CHANGED", self.OnSpellsChanged)
    end

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
    
    -- Re-detect spec and update addon.playerSpec
    if self.LibSpellDB then
        local oldSpec = self.LibSpellDB:GetPlayerSpec()
        local newSpec = self.LibSpellDB:DetectPlayerSpec()
        if oldSpec ~= newSpec then
            self.Utils:LogInfo("SpellTracker: Spec changed from", oldSpec, "to", newSpec)
            addon.playerSpec = newSpec
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
        self.Utils:LogInfo("SpellTracker: Spec switched from", oldSpec or "Unknown", "to", newSpec or "Unknown")
        addon.playerSpec = newSpec
    end
    
    self:FullRescan()
end

function SpellTracker:OnSpellsChanged()
    -- SPELLS_CHANGED fires in bursts (login, stance changes) — debounce so a
    -- burst triggers a single rescan instead of one per event.
    if self._rescanPending then return end
    self._rescanPending = true
    C_Timer.After(0.2, function()
        self._rescanPending = nil
        self.Utils:LogDebug("SpellTracker: Spells changed")
        self:InvalidateSpellbookCache()
        self:FullRescan()
    end)
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

    -- Refresh the set of currently-equipped SoD rune abilities before filtering.
    self:RefreshActiveRunes()

    local playerClass = addon.playerClass
    local playerSpec = LibSpellDB:GetPlayerSpec()

    self.Utils:LogInfo("SpellTracker: Scanning for", playerClass or "Unknown", "/", playerSpec or "Unknown")

    -- Get all spells relevant for current spec
    local relevantSpells = LibSpellDB:GetSpellsForCurrentSpec(playerClass)
    local relevantCount = self:TableCount(relevantSpells)

    self.Utils:LogInfo("SpellTracker: Found", relevantCount, "spec-relevant spells")

    -- Also include spells explicitly enabled via spellConfig (even if not spec-relevant)
    -- This allows users to enable off-spec abilities like Rend for a Fury Warrior
    local spellCfg = addon:GetSpellConfig()
    local userEnabledCount = 0
    
    for spellID, cfg in pairs(spellCfg) do
        if cfg.enabled == true and not relevantSpells[spellID] then
            -- User explicitly enabled this spell, add it to the scan list
            local spellData = LibSpellDB:GetSpellInfo(spellID)
            if spellData then
                relevantSpells[spellID] = spellData
                userEnabledCount = userEnabledCount + 1
            end
        end
    end
    
    if userEnabledCount > 0 then
        self.Utils:LogInfo("SpellTracker: Added", userEnabledCount, "user-enabled spells")
    end

    -- Auto-include known off-tree talents (e.g., Death Wish for Arms warriors)
    -- Talent spells represent deliberate player investment — if trained, always show.
    -- Only base (non-talent) spells are filtered strictly by the specs array.
    local allClassSpells = LibSpellDB:GetSpellsByClass(playerClass)
    local offTreeCount = 0
    for spellID, spellData in pairs(allClassSpells) do
        if spellData.talent and not relevantSpells[spellID] then
            if self:IsSpellKnown(spellID, spellData) then
                relevantSpells[spellID] = spellData
                offTreeCount = offTreeCount + 1
            end
        end
    end
    if offTreeCount > 0 then
        self.Utils:LogInfo("SpellTracker: Added", offTreeCount, "known off-tree talents")
    end

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
            -- Get the ACTUAL spell ID the player knows (may differ from LibSpellDB canonical ID)
            -- e.g., LibSpellDB has Blood Fury 20572, but Shaman knows 33697
            -- We store by CANONICAL ID for consistency, but keep actualSpellID for WoW API calls
            local actualSpellID = self:GetActualSpellID(spellID, spellData)
            
            self.trackedSpells[spellID] = {
                spellData = spellData,
                actualSpellID = actualSpellID,  -- For GetSpellCooldown, IsSpellKnown, etc.
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
    
    -- Notify AuraState module
    local auraState = addon:GetModule("AuraState")
    if auraState and auraState.OnTrackedSpellsChanged then
        auraState:OnTrackedSpellsChanged()
    end
end

function SpellTracker:ShouldTrackSpell(spellID, spellData, enabledTags)
    -- Check per-spec spellConfig
    local spellCfgEnabled = self:GetSpellConfigEnabled(spellID)
    if spellCfgEnabled == false then
        return false, "disabled_by_user"
    end
    
    -- If user explicitly enabled via spellConfig, skip tag/exclusion checks
    -- (but still require spell to be known)
    if spellCfgEnabled == true then
        if not self:IsSpellKnown(spellID, spellData) then
            return false, "not_known"
        end
        return true, "enabled_by_user"
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
    local isRotational = false
    local hasTrackableDuration = false

    for _, tag in ipairs(spellData.tags) do
        if tag == "FILLER" then
            isFiller = true
        elseif tag == "OUT_OF_COMBAT" then
            isOutOfCombat = true
        elseif tag == "LONG_BUFF" then
            isLongBuff = true
        elseif tag == "ROTATIONAL" or tag == "CORE_ROTATION" then
            isRotational = true
        elseif tag == "PROC" then
            return true  -- Procs belong in AuraTracker, not CooldownIcons
        elseif tag == "DEBUFF" or tag == "HOT" or tag == "BUFF" or tag == "HAS_BUFF" or tag == "HAS_DEBUFF" then
            hasTrackableDuration = true
        end
    end

    -- Always exclude OUT_OF_COMBAT abilities (resurrects, etc.)
    if isOutOfCombat then
        return true
    end

    -- Exclude LONG_BUFF (30+ min buffs cast out of combat), unless also ROTATIONAL
    -- (e.g., Earth Shield is a long-duration buff but actively consumed in combat)
    if isLongBuff and not isRotational then
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

    -- Final fallback: name-based match for class-specific spells.
    -- Anniversary Edition may use different spell IDs than TBC Classic for the same
    -- spell (e.g., Kick rank 5 is 27613 in TBC but 38768 in Anniversary). If all
    -- rank IDs fail but the spell name IS in the player's spellbook, accept it.
    -- Restricted to class spells (not SHARED) to avoid name collisions like
    -- Blood Fury (20572/33697/33702) or Arcane Torrent (28730/25046).
    if spellData.class and spellData.class ~= "SHARED" and spellData.class == addon.playerClass then
        if not self.spellbookCache then
            self:BuildSpellbookCache()
        end
        local name = spellData.name or GetSpellInfo(spellID)
        if name and self.spellbookCache[name] then
            self.Utils:LogInfo("SpellKnown FALLBACK Tier4 (name match) used for:", name, spellID, "-> actual:", self.spellbookCache[name])
            return true
        end
    end

    return false
end

function SpellTracker:CheckSpellKnown(spellID)
    -- SoD runes: an ability granted by a rune on currently-equipped gear is usable
    -- now. Checked first because some engraved abilities are passive-component
    -- spells that IsSpellKnown returns false for, and this set already reflects
    -- equipped-only state (built in RefreshActiveRunes).
    if self.activeRuneSpells and self.activeRuneSpells[spellID] then
        return true
    end

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
        local knownSpellID = self.spellbookCache[name]
        
        -- Must be the EXACT spell ID, not just same name
        -- This prevents false positives for class-specific variants like:
        -- - Blood Fury: 20572 (AP), 33697 (AP+SP), 33702 (SP) - all named "Blood Fury"
        -- - Arcane Torrent: 28730 (mana), 25046 (energy), etc. - all named "Arcane Torrent"
        if knownSpellID == spellID then
            self.Utils:LogInfo("SpellKnown FALLBACK Tier3 (spellbook cache) used for:", name, spellID)
            return true
        end
        
        -- Also check if they're in the same rank chain (different rank of same spell)
        if self.LibSpellDB then
            local knownCanonical = self.LibSpellDB:GetCanonicalSpellID(knownSpellID)
            local queryCanonical = self.LibSpellDB:GetCanonicalSpellID(spellID)
            if knownCanonical and queryCanonical and knownCanonical == queryCanonical then
                self.Utils:LogInfo("SpellKnown FALLBACK Tier3 (spellbook cache, rank match) used for:", name, spellID)
                return true
            end
        end
    end

    return false
end

-- Build a set of spell IDs granted by runes engraved on currently-equipped gear
-- (Season of Discovery). nil on non-SoD clients (C_Engraving absent / disabled).
-- Gives "usable now" semantics: a rune ability is only included while its engraved
-- item is equipped, which is exactly when the spell is castable.
function SpellTracker:RefreshActiveRunes()
    self.activeRuneSpells = nil
    if not (C_Engraving and C_Engraving.IsEngravingEnabled and C_Engraving.IsEngravingEnabled()) then
        return
    end
    if C_Engraving.RefreshRunesList then
        C_Engraving.RefreshRunesList()
    end
    local active = {}
    -- Iterate equipment slots (INVSLOT_HEAD..INVSLOT_TABARD); non-engravable slots
    -- return nil. GetRuneForEquipmentSlot reflects the item currently equipped.
    for slot = 1, 19 do
        local rune = C_Engraving.GetRuneForEquipmentSlot(slot)
        if rune and rune.learnedAbilitySpellIDs then
            for _, sid in ipairs(rune.learnedAbilitySpellIDs) do
                active[sid] = true
            end
        end
    end
    self.activeRuneSpells = active
end

-- Build a cache of all spells in the player's spellbook
-- Stores spell name -> actual spell ID (not just boolean)
function SpellTracker:BuildSpellbookCache()
    self.spellbookCache = {}
    
    local i = 1
    while true do
        local spellName, spellRank = GetSpellBookItemName(i, BOOKTYPE_SPELL)
        if not spellName then break end
        
        -- Get the actual spell ID from the spellbook slot
        local skillType, spellID = GetSpellBookItemInfo(i, BOOKTYPE_SPELL)
        
        if spellID and skillType == "SPELL" then
            -- Store by name -> actual spell ID
            -- For spells with multiple ranks, this will store the last one scanned
            -- (which is typically the highest rank in the spellbook order)
            self.spellbookCache[spellName] = spellID
        end
        
        i = i + 1
    end
    
    self.Utils:LogDebug("SpellTracker: Built spellbook cache with", i - 1, "entries")
end

-- Get the actual spell ID the player knows for a given library spell ID
-- This handles cases where LibSpellDB has spell ID 20572 but the player knows 33697
-- (both are "Blood Fury" but different class-specific versions)
function SpellTracker:GetActualSpellID(librarySpellID, spellData)
    -- Check ranks first (highest to lowest) so we return the highest known rank,
    -- not the base rank. This matters for per-rank reagent lookups.
    if spellData and spellData.ranks then
        for i = #spellData.ranks, 1, -1 do
            local rankID = spellData.ranks[i]
            if IsSpellKnown and IsSpellKnown(rankID) then
                return rankID
            end
            if IsPlayerSpell and IsPlayerSpell(rankID) then
                return rankID
            end
        end
    end

    -- No ranks or no rank matched — check if the exact library spell ID is known
    if IsSpellKnown and IsSpellKnown(librarySpellID) then
        return librarySpellID
    end
    if IsPlayerSpell and IsPlayerSpell(librarySpellID) then
        return librarySpellID
    end
    
    -- Fallback: Look up by name in spellbook cache
    -- This returns the ACTUAL spell ID the player knows, not the library ID
    if not self.spellbookCache then
        self:BuildSpellbookCache()
    end
    
    local name = GetSpellInfo(librarySpellID)
    if name and self.spellbookCache[name] then
        local actualID = self.spellbookCache[name]
        if actualID ~= librarySpellID then
            self.Utils:LogInfo("SpellTracker: Mapped library spell", librarySpellID, "(" .. name .. ") to actual spell ID", actualID)
        end
        return actualID
    end
    
    -- Not found - return original ID (will likely fail IsSpellKnown check)
    return librarySpellID
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
    local rowConfigs = addon.db.profile.rows

    -- Include tags from ALL rows, not just enabled ones.
    -- This ensures spells are tracked and ready if a user re-enables a row.
    for _, rowConfig in ipairs(rowConfigs) do
        for _, tag in ipairs(rowConfig.tags) do
            enabledTags[tag] = true
        end
    end

    return enabledTags
end

-------------------------------------------------------------------------------
-- Spell Config API
-------------------------------------------------------------------------------

-- Get enabled state from per-spec spellConfig
function SpellTracker:GetSpellConfigEnabled(spellID)
    local cfg = addon:GetSpellConfigForSpell(spellID)
    if cfg.enabled ~= nil then
        return cfg.enabled
    end
    return nil  -- No override, use default
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

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------

function SpellTracker:TableCount(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do count = count + 1 end
    return count
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

function SpellTracker:Refresh()
    self:FullRescan()
end
