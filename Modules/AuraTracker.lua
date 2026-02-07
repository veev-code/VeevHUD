--[[
    VeevHUD - Aura Tracker Module
    Tracks buffs/debuffs applied by player spells
    
    Used to show "active" state on icons when their associated 
    aura is active on a target (debuff) or self (buff).
]]

local ADDON_NAME, addon = ...

local AuraTracker = {}
addon:RegisterModule("AuraTracker", AuraTracker)

local SUMMON_TAG = "PET_SUMMON_TEMP"
local TOTEM_TAG = "TOTEM"

-- Active auras: auraSpellID -> {targetGUID -> expirationTime}
AuraTracker.activeAuras = {}

-- Mapping: auraSpellID -> sourceSpellID (reverse lookup)
AuraTracker.auraToSpellMap = {}

-- Mapping: sourceSpellID -> auraSpellID
AuraTracker.spellToAuraMap = {}

-- Mapping: rankSpellID -> baseSpellID (for looking up tracked spell from any rank)
AuraTracker.rankToBaseMap = {}

-- Temporary pet summon tracking
AuraTracker.summonSpells = {}
AuraTracker.summonPetToSpell = {}
AuraTracker.summonPetsBySpell = {}

-- Totem element exclusivity: element tag -> currently active baseSpellID
-- Only one totem per element can be active at a time
AuraTracker.totemElementToSpell = {}

-- Totem element tags (for resolving element from spell tags)
local TOTEM_ELEMENT_TAGS = {
    "TOTEM_EARTH", "TOTEM_FIRE", "TOTEM_WATER", "TOTEM_AIR",
}

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function AuraTracker:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.LibSpellDB = addon.LibSpellDB
    
    self.playerGUID = UnitGUID("player")
    
    -- Build aura mappings from spell database
    self:BuildAuraMappings()
    
    -- Register for combat log aura events
    self.Events:RegisterCLEU(self, "SPELL_AURA_APPLIED", self.OnAuraEvent)
    self.Events:RegisterCLEU(self, "SPELL_AURA_REMOVED", self.OnAuraEvent)
    self.Events:RegisterCLEU(self, "SPELL_AURA_REFRESH", self.OnAuraEvent)
    self.Events:RegisterCLEU(self, "SPELL_AURA_APPLIED_DOSE", self.OnAuraStackEvent)
    self.Events:RegisterCLEU(self, "SPELL_AURA_REMOVED_DOSE", self.OnAuraStackEvent)

    -- Register for summon tracking (temporary pets/guardians)
    self.Events:RegisterCLEU(self, "SPELL_SUMMON", self.OnSummonEvent)
    self.Events:RegisterCLEU(self, "UNIT_DIED", self.OnSummonUnitRemoved)
    self.Events:RegisterCLEU(self, "UNIT_DESTROYED", self.OnSummonUnitRemoved)
    self.Events:RegisterCLEU(self, "UNIT_DISSIPATES", self.OnSummonUnitRemoved)
    
    -- Periodic cleanup of expired auras
    self.cleanupTicker = C_Timer.NewTicker(1, function()
        self:CleanupExpiredAuras()
    end)
    
    self.Utils:LogDebug("AuraTracker initialized")
end

function AuraTracker:BuildAuraMappings()
    local spellTracker = addon:GetModule("SpellTracker")
    if not spellTracker then return end
    
    wipe(self.auraToSpellMap)
    wipe(self.spellToAuraMap)
    wipe(self.rankToBaseMap)
    
    local trackedSpells = spellTracker:GetTrackedSpells()
    local count = 0
    local rankCount = 0
    
    for spellID, data in pairs(trackedSpells) do
        local spellData = data.spellData
        
        -- Get canonical (base) spell ID for consistent keying
        local canonicalID = spellID
        if self.LibSpellDB then
            canonicalID = self.LibSpellDB:GetCanonicalSpellID(spellID) or spellID
        end
        
        -- Build rank-to-base mapping for all tracked spells
        -- This allows us to look up tracked spell from any rank ID in combat log
        self.rankToBaseMap[spellID] = canonicalID  -- Map tracked ID to canonical
        self.rankToBaseMap[canonicalID] = canonicalID  -- Canonical maps to itself
        if spellData.ranks then
            for _, rankID in ipairs(spellData.ranks) do
                self.rankToBaseMap[rankID] = canonicalID
                rankCount = rankCount + 1
            end
        end
        
        -- Only pre-map spells with explicit triggersAuras definition (different aura ID than spell ID)
        -- Same-ID auras are detected dynamically in OnAuraEvent
        if spellData.triggersAuras then
            for _, triggeredAura in ipairs(spellData.triggersAuras) do
                if triggeredAura.spellID then
                    local auraType = triggeredAura.type or "DEBUFF"
                    local auraInfo = {
                        spellID = triggeredAura.spellID,
                        type = auraType,
                        onTarget = triggeredAura.onTarget,
                        isBuff = (auraType == "BUFF"),  -- Explicit flag for buff scanning
                        duration = triggeredAura.duration,  -- Can be nil, will detect dynamically
                        tags = triggeredAura.tags or {},    -- Tags specific to this triggered aura
                    }
                    
                    local auraID = auraInfo.spellID
                    self.auraToSpellMap[auraID] = canonicalID  -- Map to canonical ID
                    self.spellToAuraMap[canonicalID] = self.spellToAuraMap[canonicalID] or {}
                    table.insert(self.spellToAuraMap[canonicalID], auraInfo)
                    self.activeAuras[auraID] = self.activeAuras[auraID] or {}
                    
                    local spellName = GetSpellInfo(spellID) or tostring(spellID)
                    self.Utils:LogInfo("AuraTracker: Pre-mapped aura for", spellName, "->", auraID, auraInfo.type)
                    count = count + 1
                end
            end
        end
    end

    -- Build summon mappings (temporary pet/guardian tracking)
    self:BuildSummonMappings(trackedSpells)
    
    if count > 0 then
        self.Utils:LogInfo("AuraTracker: Pre-mapped", count, "spells with different aura IDs")
    end
    if rankCount > 0 then
        self.Utils:LogInfo("AuraTracker: Built rank mapping for", rankCount, "spell ranks")
    end
    self.Utils:LogInfo("AuraTracker: Same-ID auras will be detected dynamically from combat log")
end

function AuraTracker:BuildSummonMappings(trackedSpells)
    wipe(self.summonSpells)
    wipe(self.summonPetToSpell)
    wipe(self.summonPetsBySpell)
    wipe(self.totemElementToSpell)

    if not self.LibSpellDB then return end

    local summonTag = (self.LibSpellDB.Categories and self.LibSpellDB.Categories.PET_SUMMON_TEMP) or SUMMON_TAG
    local totemTag = (self.LibSpellDB.Categories and self.LibSpellDB.Categories.TOTEM) or TOTEM_TAG
    local count = 0

    for spellID, data in pairs(trackedSpells or {}) do
        local spellData = data.spellData
        if spellData and (self.LibSpellDB:HasTag(spellID, summonTag) or self.LibSpellDB:HasTag(spellID, totemTag)) then
            local duration = spellData.duration
            if duration and duration > 0 then
                local canonicalID = self.LibSpellDB:GetCanonicalSpellID(spellID) or spellID
                -- Resolve totem element from tags (nil for non-totems)
                local elementTag = nil
                for _, tag in ipairs(TOTEM_ELEMENT_TAGS) do
                    if self.LibSpellDB:HasTag(spellID, tag) then
                        elementTag = tag
                        break
                    end
                end
                self.summonSpells[canonicalID] = {
                    duration = duration,
                    spellID = canonicalID,
                    totemElementTag = elementTag,  -- nil for non-totems
                }
                count = count + 1
            end
        end
    end

    if count > 0 then
        self.Utils:LogInfo("AuraTracker: Tracking", count, "temporary pet/totem summons")
    end
end

-------------------------------------------------------------------------------
-- Combat Log Processing
-------------------------------------------------------------------------------

-- CLEU callback for aura events
-- data contains: timestamp, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, spellID, spellName, spellSchool
function AuraTracker:OnAuraEvent(subEvent, data)
    local spellID = data.spellID
    local spellName = data.spellName
    local sourceGUID = data.sourceGUID
    local destGUID = data.destGUID
    local destName = data.destName
    
    -- Must be from us (we only track our own auras)
    if sourceGUID ~= self.playerGUID then return end
    
    -- Check if this aura is explicitly mapped (different aura ID than spell ID)
    local sourceSpellID = self.auraToSpellMap[spellID]
    local auraInfo = nil
    
    -- spellToAuraMap is an array of aura infos - find the one matching this aura spell ID
    if sourceSpellID then
        local auraInfos = self.spellToAuraMap[sourceSpellID]
        if auraInfos then
            for _, info in ipairs(auraInfos) do
                if info.spellID == spellID then
                    auraInfo = info
                    break
                end
            end
        end
    end
    
    -- If not explicitly mapped, check if this spell ID (or its base spell) is one we're tracking
    -- This enables auto-detection for spells where aura ID = spell ID (including ranks)
    if not sourceSpellID then
        -- First check if this is a rank of a tracked spell
        local baseSpellID = self.rankToBaseMap[spellID]
        
        if baseSpellID then
            -- Check if this spell has ignoreAura set (e.g., Bloodthirst buff is longer than CD)
            local spellData = self.LibSpellDB and self.LibSpellDB:GetSpellInfo(baseSpellID)
            
            -- Skip auto-tracking if ignoreAura is set
            if spellData and spellData.ignoreAura then
                return
            end
            
            -- This spell (or its base) is tracked and applies an aura
            -- Determine aura type based on spell tags and target
            sourceSpellID = baseSpellID
            local isSelfBuff = (destGUID == self.playerGUID)
            
            -- Check if this is a healing/buff spell (applies buff) or damage spell (applies debuff)
            local isBuff = isSelfBuff  -- Default: self = buff
            
            if spellData and spellData.tags then
                -- Check tags to determine if this is a buff-type spell
                for _, tag in ipairs(spellData.tags) do
                    if tag == "HOT" or tag == "HAS_HOT" or tag == "HEAL_SINGLE" or tag == "HEAL_AOE" 
                       or tag == "BUFF" or tag == "HAS_BUFF" or tag == "EXTERNAL_DEFENSIVE"
                       or tag == SUMMON_TAG or tag == TOTEM_TAG then
                        isBuff = true
                        break
                    end
                end
            end
            
            auraInfo = {
                spellID = spellID,  -- Use actual aura ID (rank ID) for tracking
                type = isBuff and "BUFF" or "DEBUFF",
                onTarget = not isSelfBuff,
                isBuff = isBuff,  -- Explicit buff flag for scanning
                duration = spellData and spellData.duration or nil,
                baseSpellID = baseSpellID,  -- Store base ID for lookup
            }
        end
    end
    
    if not sourceSpellID or not auraInfo then return end
    
    -- Determine if this is a buff (on self or ally) or debuff (on enemy)
    -- Use explicit isBuff flag if available, otherwise infer from onTarget
    local isBuff = auraInfo.isBuff
    if isBuff == nil then
        isBuff = not auraInfo.onTarget
    end
    
    -- All auras we track must be from us (already checked above via sourceGUID)
    
    -- Store by AURA spell ID so multiple triggered auras from same source don't overwrite each other
    -- (e.g., Pounce triggers both a stun and a bleed - they need separate storage)
    -- Also store sourceSpellID in the data for icon overlay lookups
    local storageID = spellID  -- Use actual aura spell ID for storage
    
    -- Process the event
    if subEvent == "SPELL_AURA_APPLIED" or subEvent == "SPELL_AURA_REFRESH" then
        -- Aura applied or refreshed - get actual duration from the unit
        local expiration = nil
        local duration = 0
        local stacks = 0
        
        -- Try to get actual duration and stacks from the unit
        local unit = self:GetUnitFromGUID(destGUID)
        if unit then
            local actualDuration, actualExpiration, actualStacks = self:GetAuraDurationOnUnit(unit, spellID, spellName, isBuff)
            if actualExpiration and actualExpiration > 0 then
                expiration = actualExpiration
                duration = actualDuration or 0
                stacks = actualStacks or 0
            end
        end
        
        -- Fallback to estimated duration if we couldn't get actual
        if not expiration or expiration <= GetTime() then
            -- Try to get duration from LibSpellDB first
            duration = auraInfo.duration
            if not duration and self.LibSpellDB then
                local spellData = self.LibSpellDB:GetSpellInfo(sourceSpellID)
                if spellData and spellData.duration then
                    duration = spellData.duration
                end
            end
            -- Final fallback: try GetSpellInfo for spell description parsing isn't reliable,
            -- so use a reasonable default based on spell type
            if not duration then
                duration = 15  -- More reasonable default than 10
            end
            expiration = GetTime() + duration
        end
        
        if not self.activeAuras[storageID] then
            self.activeAuras[storageID] = {}
        end
        -- Store expiration, duration, stacks, and source spell ID for icon lookup
        self.activeAuras[storageID][destGUID] = {
            expiration = expiration,
            duration = duration,
            stacks = stacks,
            sourceSpellID = sourceSpellID,  -- For icon overlay lookup
        }
        
        local stackInfo = stacks > 0 and (" (" .. stacks .. " stacks)") or ""
        self.Utils:LogInfo("AuraTracker: Aura applied", spellName, "(", spellID, "->", storageID, ") on", destName, "expires in", string.format("%.1f", expiration - GetTime()) .. stackInfo)
        
        -- Notify CooldownIcons
        self:NotifyAuraChange(sourceSpellID, true)
        
    elseif subEvent == "SPELL_AURA_REMOVED" then
        -- Aura removed (storageID is the aura spell ID)
        if self.activeAuras[storageID] then
            self.activeAuras[storageID][destGUID] = nil
        end
        
        self.Utils:LogDebug("AuraTracker: Aura removed", spellName, "from", destName)
        
        -- Notify CooldownIcons - check if ANY aura for this source spell is still active
        self:NotifyAuraChange(sourceSpellID, self:IsAuraActiveForSourceSpell(sourceSpellID))
    end
end

-- CLEU callback for aura stack changes
function AuraTracker:OnAuraStackEvent(subEvent, data)
    local spellID = data.spellID
    local spellName = data.spellName
    local sourceGUID = data.sourceGUID
    local destGUID = data.destGUID
    local destName = data.destName
    
    -- Must be from us
    if sourceGUID ~= self.playerGUID then return end
    
    -- Find the source spell ID (canonical)
    local sourceSpellID = self.auraToSpellMap[spellID]
    if not sourceSpellID then
        local baseSpellID = self.rankToBaseMap[spellID]
        if baseSpellID then
            sourceSpellID = baseSpellID
        end
    end
    
    if not sourceSpellID then return end
    
    -- Storage is keyed by AURA spell ID (not source spell ID)
    -- This matches OnAuraEvent storage
    local storageID = spellID
    
    -- Determine if this is a buff based on spell data
    local isBuff = (destGUID == self.playerGUID)  -- Default: self = buff
    local spellData = self.LibSpellDB and self.LibSpellDB:GetSpellInfo(sourceSpellID)
    if spellData and spellData.tags then
        for _, tag in ipairs(spellData.tags) do
            if tag == "HOT" or tag == "HAS_HOT" or tag == "HEAL_SINGLE" or tag == "HEAL_AOE" 
               or tag == "BUFF" or tag == "HAS_BUFF" or tag == "EXTERNAL_DEFENSIVE"
               or tag == SUMMON_TAG or tag == TOTEM_TAG then
                isBuff = true
                break
            end
        end
    end
    
    -- Update stack count from the unit
    local unit = self:GetUnitFromGUID(destGUID)
    if unit and self.activeAuras[storageID] and self.activeAuras[storageID][destGUID] then
        local _, _, stacks = self:GetAuraDurationOnUnit(unit, spellID, spellName, isBuff)
        self.activeAuras[storageID][destGUID].stacks = stacks or 0
        
        self.Utils:LogInfo("AuraTracker: Stacks changed", spellName, "->", stacks or 0)
        
        -- Notify for UI update
        self:NotifyAuraChange(sourceSpellID, true)
    end
end

-- Clear all tracking for a summon spell (pseudo-aura, pet GUIDs)
function AuraTracker:ClearSummonTracking(baseSpellID)
    -- Remove pseudo-aura
    if self.activeAuras[baseSpellID] and self.activeAuras[baseSpellID][self.playerGUID] then
        self.activeAuras[baseSpellID][self.playerGUID] = nil
    end

    -- Remove all pet GUIDs
    local pets = self.summonPetsBySpell[baseSpellID]
    if pets then
        for petGUID in pairs(pets) do
            self.summonPetToSpell[petGUID] = nil
        end
        self.summonPetsBySpell[baseSpellID] = nil
    end
end

-- Clear totem element tracking for a given spell ID
function AuraTracker:ClearTotemElementForSpell(baseSpellID)
    for element, spellID in pairs(self.totemElementToSpell) do
        if spellID == baseSpellID then
            self.totemElementToSpell[element] = nil
            return
        end
    end
end

-- CLEU callback for pet/guardian summons
function AuraTracker:OnSummonEvent(subEvent, data)
    local spellID = data.spellID
    local spellName = data.spellName
    local sourceGUID = data.sourceGUID
    local destGUID = data.destGUID

    -- Must be from us
    if sourceGUID ~= self.playerGUID then return end
    if not spellID then return end

    -- Resolve to canonical/base spell ID
    local baseSpellID = self.rankToBaseMap[spellID] or spellID
    if self.LibSpellDB then
        baseSpellID = self.LibSpellDB:GetCanonicalSpellID(baseSpellID) or baseSpellID
    end

    local summonInfo = self.summonSpells[baseSpellID]
    if not summonInfo then return end

    local duration = summonInfo.duration
    if not duration or duration <= 0 then return end

    local totemElementTag = summonInfo.totemElementTag

    -- Totem element exclusivity: only 1 totem per element
    if totemElementTag then
        local existingSpellID = self.totemElementToSpell[totemElementTag]
        if existingSpellID then
            -- Clear old totem (same spell recast or different totem of same element)
            self:ClearSummonTracking(existingSpellID)
            if existingSpellID ~= baseSpellID then
                self:NotifyAuraChange(existingSpellID, false)
            end
        end
        self.totemElementToSpell[totemElementTag] = baseSpellID
    end

    local expiration = GetTime() + duration
    local targetGUID = self.playerGUID

    -- Store as a pseudo-aura on the player
    self.activeAuras[baseSpellID] = self.activeAuras[baseSpellID] or {}

    if not totemElementTag then
        -- Non-totem summons: keep later expiration for multi-summon spells (Force of Nature)
        local existing = self.activeAuras[baseSpellID][targetGUID]
        if existing and existing.expiration and existing.expiration > expiration then
            expiration = existing.expiration
        end
    end

    self.activeAuras[baseSpellID][targetGUID] = {
        expiration = expiration,
        duration = duration,
        stacks = 0,
        sourceSpellID = baseSpellID,
        isSummon = true,
    }

    -- Track pet/totem GUIDs for early cleanup on death/destroy
    if destGUID then
        self.summonPetToSpell[destGUID] = baseSpellID
        self.summonPetsBySpell[baseSpellID] = self.summonPetsBySpell[baseSpellID] or {}
        self.summonPetsBySpell[baseSpellID][destGUID] = true

        if not totemElementTag then
            -- Non-totem summons: update stacks to reflect number of living pets
            -- (Force of Nature spawns 3 treants, Shadowfiend = 1)
            local petCount = 0
            for _ in pairs(self.summonPetsBySpell[baseSpellID]) do
                petCount = petCount + 1
            end
            self.activeAuras[baseSpellID][targetGUID].stacks = petCount
        end
        -- Totems: stacks stay at 0 (only 1 per element)
    end

    self.Utils:LogInfo("AuraTracker: Summon active", spellName or baseSpellID, "for", duration, "seconds, pets:", self.activeAuras[baseSpellID][targetGUID].stacks or 0)
    self:NotifyAuraChange(baseSpellID, true)
end

-- CLEU callback for summon despawns/deaths
function AuraTracker:OnSummonUnitRemoved(subEvent, data)
    local destGUID = data.destGUID
    if not destGUID then return end

    local baseSpellID = self.summonPetToSpell[destGUID]
    if not baseSpellID then return end

    self.summonPetToSpell[destGUID] = nil

    local pets = self.summonPetsBySpell[baseSpellID]
    if pets then
        pets[destGUID] = nil
        if not next(pets) then
            -- All pets/totems dead - remove the pseudo-aura
            self.summonPetsBySpell[baseSpellID] = nil
            local targets = self.activeAuras[baseSpellID]
            if targets and targets[self.playerGUID] then
                targets[self.playerGUID] = nil
            end
            -- Clear totem element tracking
            self:ClearTotemElementForSpell(baseSpellID)
            self:NotifyAuraChange(baseSpellID, false)
        else
            -- Some pets still alive - update stack count
            local petCount = 0
            for _ in pairs(pets) do
                petCount = petCount + 1
            end
            local targets = self.activeAuras[baseSpellID]
            if targets and targets[self.playerGUID] then
                targets[self.playerGUID].stacks = petCount
            end
            self:NotifyAuraChange(baseSpellID, true)
        end
    end
end

-------------------------------------------------------------------------------
-- Cleanup
-------------------------------------------------------------------------------

function AuraTracker:CleanupExpiredAuras()
    local now = GetTime()
    local changed = false
    
    for auraID, targets in pairs(self.activeAuras) do
        for targetGUID, auraData in pairs(targets) do
            local expiration = type(auraData) == "table" and auraData.expiration or auraData
            if expiration <= now then
                targets[targetGUID] = nil
                changed = true

                -- Clear summon tracking if this was a pseudo-aura on the player
                if targetGUID == self.playerGUID and self.summonPetsBySpell[auraID] then
                    for petGUID in pairs(self.summonPetsBySpell[auraID]) do
                        self.summonPetToSpell[petGUID] = nil
                    end
                    self.summonPetsBySpell[auraID] = nil
                end

                -- Clear totem element tracking if this was a totem
                if targetGUID == self.playerGUID then
                    self:ClearTotemElementForSpell(auraID)
                end
            end
        end
    end
    
    if changed then
        -- Update UI
        local cooldownIcons = addon:GetModule("CooldownIcons")
        if cooldownIcons then
            cooldownIcons:UpdateAllIcons()
        end
    end
end

-------------------------------------------------------------------------------
-- Unit/Aura Helpers
-------------------------------------------------------------------------------

-- Get unit token from GUID
function AuraTracker:GetUnitFromGUID(guid)
    if not guid then return nil end
    
    -- Check common units
    if guid == UnitGUID("player") then return "player" end
    if guid == UnitGUID("target") then return "target" end
    if guid == UnitGUID("targettarget") then return "targettarget" end
    if guid == UnitGUID("focus") then return "focus" end
    if guid == UnitGUID("pet") then return "pet" end
    
    -- Check party/raid
    for i = 1, 4 do
        if guid == UnitGUID("party" .. i) then return "party" .. i end
        if guid == UnitGUID("party" .. i .. "target") then return "party" .. i .. "target" end
    end
    
    -- Check nameplates
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and guid == UnitGUID(unit) then
            return unit
        end
    end
    
    -- Check arena (if applicable)
    for i = 1, 5 do
        if guid == UnitGUID("arena" .. i) then return "arena" .. i end
    end
    
    return nil
end

-- Get aura duration, expiration, and stack count from a unit
function AuraTracker:GetAuraDurationOnUnit(unit, spellID, spellName, isBuff)
    if not unit or not UnitExists(unit) then return nil, nil, nil end
    
    local scanFunc = isBuff and UnitBuff or UnitDebuff
    local filter = isBuff and "HELPFUL" or "HARMFUL"
    
    -- Scan auras on the unit
    for i = 1, 40 do
        local name, icon, count, debuffType, duration, expirationTime, source, 
              isStealable, nameplateShowPersonal, auraSpellID = scanFunc(unit, i, filter)
        
        if not name then break end
        
        -- Match by spell ID or name
        if (auraSpellID and auraSpellID == spellID) or name == spellName then
            -- For debuffs, make sure it's ours
            if not isBuff and source and source ~= "player" then
                -- Not our debuff, keep scanning
            else
                return duration, expirationTime, count or 0
            end
        end
    end
    
    return nil, nil, nil
end

-------------------------------------------------------------------------------
-- Target Resolution
-------------------------------------------------------------------------------

-- Determine the aura type for targeting logic based on the SOURCE spell ID
-- Returns: isHelpful, isSelfOnly, isCC, isRotational
-- isHelpful: true for buffs/heals, false for hostile debuffs
-- isSelfOnly: true for self-only buffs (Recklessness, etc.)
-- isCC: true for CC spells (track across all targets)
-- isRotational: true for ROTATIONAL spells (follow target context for buffs)
function AuraTracker:GetAuraType(spellID)
    local isHelpful = false
    local isSelfOnly = true  -- Default to self-only, will be overridden by IsSelfOnly
    local isCC = false
    local isRotational = false
    
    -- Resolve to canonical ID for consistent lookup
    local canonicalID = spellID
    if self.LibSpellDB then
        canonicalID = self.LibSpellDB:GetCanonicalSpellID(spellID) or spellID
    end
    
    -- Use LibSpellDB's centralized logic
    if self.LibSpellDB then
        if self.LibSpellDB.IsSelfOnly then
            isSelfOnly = self.LibSpellDB:IsSelfOnly(canonicalID)
        end
        if self.LibSpellDB.IsRotational then
            isRotational = self.LibSpellDB:IsRotational(canonicalID)
        end
    end
    
    -- Check spellToAuraMap for explicit type info from triggersAuras
    local auraInfos = self.spellToAuraMap[canonicalID]
    if auraInfos and auraInfos[1] then
        local auraInfo = auraInfos[1]
        isHelpful = auraInfo.type == "BUFF"
    end
    
    -- Check LibSpellDB for spell data and tags (using canonical ID)
    if self.LibSpellDB then
        local spellData = self.LibSpellDB:GetSpellInfo(canonicalID)
        if spellData then
            -- Check tags for CC and helpful indicators
            if spellData.tags then
                for _, tag in ipairs(spellData.tags) do
                    -- Only hard CC tracks across all targets (stuns, polymorphs, fears)
                    if tag == "CC_HARD" then
                        isCC = true
                    end
                    -- Helpful tags (if not already determined from auraInfos)
                    if not auraInfos then
                        if tag == "HOT" or tag == "HAS_HOT" or tag == "HEAL_SINGLE" or tag == "HEAL_AOE" 
                           or tag == "BUFF" or tag == "HAS_BUFF" or tag == "EXTERNAL_DEFENSIVE"
                           or tag == SUMMON_TAG or tag == TOTEM_TAG then
                            isHelpful = true
                        end
                    end
                end
            end
        end
    end
    
    return isHelpful, isSelfOnly, isCC, isRotational
end

-- Determine the aura type for targeting logic based on the AURA spell ID
-- This is used when we have the aura ID from combat log and need to check its specific tags
-- Returns: isHelpful, isSelfOnly, isCC, isRotational, sourceSpellID
function AuraTracker:GetAuraTypeForAuraID(auraSpellID)
    local isHelpful = false
    local isSelfOnly = true  -- Default to self-only, will be overridden
    local isCC = false
    local isRotational = false
    local sourceSpellID = nil
    
    -- First, check if this aura ID has specific tag info from LibSpellDB
    if self.LibSpellDB and self.LibSpellDB.GetAuraInfo then
        local auraInfo = self.LibSpellDB:GetAuraInfo(auraSpellID)
        if auraInfo then
            sourceSpellID = auraInfo.sourceSpellID
            isHelpful = auraInfo.type == "BUFF"
            
            -- Use centralized logic based on source spell
            if sourceSpellID then
                if self.LibSpellDB.IsSelfOnly then
                    isSelfOnly = self.LibSpellDB:IsSelfOnly(sourceSpellID)
                end
                if self.LibSpellDB.IsRotational then
                    isRotational = self.LibSpellDB:IsRotational(sourceSpellID)
                end
            end
            
            -- Check aura-specific tags
            if auraInfo.tags then
                for _, tag in ipairs(auraInfo.tags) do
                    if tag == "CC_HARD" then
                        isCC = true
                    end
                    if tag == "HOT" or tag == "HAS_HOT" or tag == "HEAL_SINGLE" or tag == "HEAL_AOE" 
                       or tag == "BUFF" or tag == "HAS_BUFF" or tag == "EXTERNAL_DEFENSIVE"
                       or tag == SUMMON_TAG or tag == TOTEM_TAG then
                        isHelpful = true
                    end
                end
            end
            
            return isHelpful, isSelfOnly, isCC, isRotational, sourceSpellID
        end
    end
    
    -- Fall back to checking auraToSpellMap (local cache)
    sourceSpellID = self.auraToSpellMap[auraSpellID]
    if sourceSpellID then
        -- Get the source spell's aura type
        isHelpful, isSelfOnly, isCC, isRotational = self:GetAuraType(sourceSpellID)
        return isHelpful, isSelfOnly, isCC, isRotational, sourceSpellID
    end
    
    -- If not found as a triggered aura, try as a regular spell (same-ID aura)
    local canonicalID = auraSpellID
    if self.LibSpellDB then
        canonicalID = self.LibSpellDB:GetCanonicalSpellID(auraSpellID) or auraSpellID
    end
    
    isHelpful, isSelfOnly, isCC, isRotational = self:GetAuraType(canonicalID)
    return isHelpful, isSelfOnly, isCC, isRotational, canonicalID
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

-- Get all triggered aura IDs for a source spell (cached lookup)
-- Returns array of aura spell IDs
-- Includes BOTH explicitly triggered auras (from triggersAuras) AND same-ID auras (source + ranks)
-- This is important for spells like Intimidating Shout that apply:
--   - A different aura ID (20511 Cower) on the main target
--   - The same spell ID (5246 Fear) on secondary targets
function AuraTracker:GetTriggeredAuraIDs(sourceSpellID)
    -- First resolve to canonical (base) spell ID for lookup
    local canonicalID = sourceSpellID
    if self.LibSpellDB then
        canonicalID = self.LibSpellDB:GetCanonicalSpellID(sourceSpellID) or sourceSpellID
    end
    
    -- Use a set to avoid duplicates
    local idSet = {}
    local ids = {}
    
    local function addID(id)
        if not idSet[id] then
            idSet[id] = true
            table.insert(ids, id)
        end
    end
    
    -- Add explicitly triggered auras (different IDs from triggersAuras)
    local auraInfos = self.spellToAuraMap[canonicalID]
    if auraInfos then
        for _, info in ipairs(auraInfos) do
            addID(info.spellID)
        end
    end
    
    -- Also add source spell ID and all ranks for same-ID auras
    -- A spell can trigger BOTH explicit auras AND same-ID auras
    addID(sourceSpellID)
    if canonicalID ~= sourceSpellID then
        addID(canonicalID)
    end
    
    -- Get all rank IDs from LibSpellDB
    if self.LibSpellDB then
        local spellData = self.LibSpellDB:GetSpellInfo(sourceSpellID)
        if spellData and spellData.ranks then
            for _, rankID in ipairs(spellData.ranks) do
                addID(rankID)
            end
        end
    end
    
    return ids
end

-- Check if ANY of a source spell's auras is currently active
-- Used by icon overlay to know if any effect is up
function AuraTracker:IsAuraActiveForSourceSpell(sourceSpellID)
    local auraIDs = self:GetTriggeredAuraIDs(sourceSpellID)
    local now = GetTime()
    
    for _, auraID in ipairs(auraIDs) do
        local targets = self.activeAuras[auraID]
        if targets then
            -- Get targeting logic for THIS specific aura
            local relevantGUID, checkAllTargets = self:GetRelevantTargetGUIDForAura(auraID)
            
            if checkAllTargets then
                -- CC or non-rotational helpful spells: check any target
                for targetGUID, auraData in pairs(targets) do
                    local expiration = type(auraData) == "table" and auraData.expiration or auraData
                    if expiration > now then
                        return true
                    end
                end
            else
                -- Rotational spells: check only the relevant target
                if relevantGUID and targets[relevantGUID] then
                    local auraData = targets[relevantGUID]
                    local expiration = type(auraData) == "table" and auraData.expiration or auraData
                    if expiration > now then
                        return true
                    end
                end
            end
        end
    end
    
    return false
end

-- Get relevant target GUID for a specific AURA (using aura-specific tags)
-- Returns: relevantGUID, shouldCheckAllTargets
-- shouldCheckAllTargets: true for CC and non-rotational helpful buffs (Pain Suppression, Fear Ward)
function AuraTracker:GetRelevantTargetGUIDForAura(auraSpellID)
    local isHelpful, isSelfOnly, isCC, isRotational = self:GetAuraTypeForAuraID(auraSpellID)
    local playerGUID = self.playerGUID
    
    -- CC spells track across all targets - return nil to signal this
    if isCC then
        return nil, true  -- nil GUID, checkAllTargets = true
    end
    
    -- For helpful spells (buffs/heals), check selfOnly and rotational status
    if isHelpful then
        -- Self-only buffs always check self (Recklessness, Shadowform)
        if isSelfOnly then
            return playerGUID, false
        end
        
        -- Non-rotational helpful spells (Pain Suppression, Fear Ward) track across all targets
        -- This ensures major cooldowns are always visible regardless of current target
        if not isRotational then
            return nil, true  -- nil GUID, checkAllTargets = true
        end
    end
    
    -- Rotational spells follow target context (heals check friendly target, DoTs check enemy target)
    -- Check if targettarget support is enabled
    local db = addon.db.profile.icons
    local useTargettarget = db.auraTargettargetSupport
    
    local targetGUID = UnitGUID("target")
    local targetExists = UnitExists("target")
    local targetIsEnemy = targetExists and UnitIsEnemy("player", "target")
    local targetIsFriend = targetExists and UnitIsFriend("player", "target")
    
    -- Only check targettarget if the setting is enabled
    local targettargetGUID, targettargetIsEnemy, targettargetIsFriend = nil, false, false
    if useTargettarget then
        targettargetGUID = UnitGUID("targettarget")
        local targettargetExists = UnitExists("targettarget")
        targettargetIsEnemy = targettargetExists and UnitIsEnemy("player", "targettarget")
        targettargetIsFriend = targettargetExists and UnitIsFriend("player", "targettarget")
    end
    
    if targetIsEnemy then
        if isHelpful then
            if useTargettarget and targettargetIsFriend then
                return targettargetGUID, false
            else
                return playerGUID, false
            end
        else
            return targetGUID, false
        end
    elseif targetIsFriend then
        if isHelpful then
            return targetGUID, false
        else
            if useTargettarget and targettargetIsEnemy then
                return targettargetGUID, false
            else
                return nil, false
            end
        end
    else
        return playerGUID, false
    end
end

-- Check if a spell's aura is currently active (legacy API - uses source spell ID)
-- Uses same smart target resolution as GetAuraRemaining for consistency
function AuraTracker:IsAuraActive(spellID)
    return self:IsAuraActiveForSourceSpell(spellID)
end

-- Get aura priority for sorting (higher = more important)
-- CC_HARD > CC_SOFT > other auras, then by array order
function AuraTracker:GetAuraPriority(auraSpellID, arrayIndex)
    local basePriority = 1000 - (arrayIndex or 0)  -- Array order as tiebreaker
    
    if self.LibSpellDB and self.LibSpellDB.GetAuraInfo then
        local auraInfo = self.LibSpellDB:GetAuraInfo(auraSpellID)
        if auraInfo and auraInfo.tags then
            for _, tag in ipairs(auraInfo.tags) do
                if tag == "CC_HARD" then
                    return 3000 + basePriority  -- Highest priority
                elseif tag == "CC_SOFT" or tag == "ROOT" then
                    return 2000 + basePriority  -- Medium priority
                end
            end
        end
    end
    
    return basePriority  -- Default priority (DOTs, buffs, etc.)
end

-- Get the remaining duration for a SOURCE spell (checks all its triggered auras)
-- Priority: CC_HARD > CC_SOFT > array order. Among same priority, uses longest duration.
function AuraTracker:GetAuraRemaining(sourceSpellID)
    local auraIDs = self:GetTriggeredAuraIDs(sourceSpellID)
    local now = GetTime()
    
    -- Collect all active auras with their priority and remaining time
    local activeAuras = {}
    
    for arrayIndex, auraID in ipairs(auraIDs) do
        local targets = self.activeAuras[auraID]
        if targets then
            -- Get targeting logic for THIS specific aura
            local relevantGUID, checkAllTargets = self:GetRelevantTargetGUIDForAura(auraID)
            local priority = self:GetAuraPriority(auraID, arrayIndex)
            
            if checkAllTargets then
                -- CC or non-rotational helpful spells: check all targets, use longest remaining
                for targetGUID, auraData in pairs(targets) do
                    local expiration = type(auraData) == "table" and auraData.expiration or auraData
                    local remaining = expiration - now
                    if remaining > 0 then
                        table.insert(activeAuras, {
                            priority = priority,
                            remaining = remaining,
                            duration = type(auraData) == "table" and auraData.duration or 0,
                            stacks = type(auraData) == "table" and auraData.stacks or 0,
                        })
                    end
                end
            else
                -- Rotational spells: check only relevant target for this aura
                if relevantGUID and targets[relevantGUID] then
                    local auraData = targets[relevantGUID]
                    local expiration = type(auraData) == "table" and auraData.expiration or auraData
                    local remaining = expiration - now
                    if remaining > 0 then
                        table.insert(activeAuras, {
                            priority = priority,
                            remaining = remaining,
                            duration = type(auraData) == "table" and auraData.duration or 0,
                            stacks = type(auraData) == "table" and auraData.stacks or 0,
                        })
                    end
                end
            end
        end
    end
    
    -- No active auras
    if #activeAuras == 0 then
        return 0, 0, 0
    end
    
    -- Sort by priority (desc), then by remaining time (desc)
    table.sort(activeAuras, function(a, b)
        if a.priority ~= b.priority then
            return a.priority > b.priority
        end
        return a.remaining > b.remaining
    end)
    
    -- Return the highest priority aura's info
    local best = activeAuras[1]
    return best.remaining, best.duration, best.stacks
end

-- Notify that an aura changed (for icon updates)
function AuraTracker:NotifyAuraChange(spellID, isActive)
    local cooldownIcons = addon:GetModule("CooldownIcons")
    if cooldownIcons then
        cooldownIcons:UpdateAllIcons()
    end
end

-- Rebuild mappings when tracked spells change
function AuraTracker:OnTrackedSpellsChanged()
    self:BuildAuraMappings()
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

function AuraTracker:Refresh()
    self:BuildAuraMappings()
end
