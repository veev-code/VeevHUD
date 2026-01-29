--[[
    VeevHUD - Aura Tracker Module
    Tracks buffs/debuffs applied by player spells
    
    Used to show "active" state on icons when their associated 
    aura is active on a target (debuff) or self (buff).
]]

local ADDON_NAME, addon = ...

local AuraTracker = {}
addon:RegisterModule("AuraTracker", AuraTracker)

-- Active auras: auraSpellID -> {targetGUID -> expirationTime}
AuraTracker.activeAuras = {}

-- Mapping: auraSpellID -> sourceSpellID (reverse lookup)
AuraTracker.auraToSpellMap = {}

-- Mapping: sourceSpellID -> auraSpellID
AuraTracker.spellToAuraMap = {}

-- Mapping: rankSpellID -> baseSpellID (for looking up tracked spell from any rank)
AuraTracker.rankToBaseMap = {}

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
        
        -- Build rank-to-base mapping for all tracked spells
        -- This allows us to look up tracked spell from any rank ID in combat log
        self.rankToBaseMap[spellID] = spellID  -- Base ID maps to itself
        if spellData.ranks then
            for _, rankID in ipairs(spellData.ranks) do
                self.rankToBaseMap[rankID] = spellID
                rankCount = rankCount + 1
            end
        end
        
        -- Only pre-map spells with explicit appliesAura definition (different aura ID than spell ID)
        -- Same-ID auras are detected dynamically in OnAuraEvent
        if spellData.appliesAura then
            local auraInfo = {
                spellID = spellData.appliesAura.spellID,
                type = spellData.appliesAura.type or "DEBUFF",
                onTarget = spellData.appliesAura.onTarget,
                duration = spellData.appliesAura.duration,  -- Can be nil, will detect dynamically
            }
            
            local auraID = auraInfo.spellID
            self.auraToSpellMap[auraID] = spellID
            self.spellToAuraMap[spellID] = auraInfo
            self.activeAuras[auraID] = self.activeAuras[auraID] or {}
            
            local spellName = GetSpellInfo(spellID) or tostring(spellID)
            self.Utils:LogInfo("AuraTracker: Pre-mapped aura for", spellName, "->", auraID, auraInfo.type)
            count = count + 1
        end
    end
    
    if count > 0 then
        self.Utils:LogInfo("AuraTracker: Pre-mapped", count, "spells with different aura IDs")
    end
    if rankCount > 0 then
        self.Utils:LogInfo("AuraTracker: Built rank mapping for", rankCount, "spell ranks")
    end
    self.Utils:LogInfo("AuraTracker: Same-ID auras will be detected dynamically from combat log")
end

function AuraTracker:HasTag(tags, tagName)
    for _, tag in ipairs(tags) do
        if tag == tagName then
            return true
        end
    end
    return false
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
    local auraInfo = sourceSpellID and self.spellToAuraMap[sourceSpellID]
    
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
                       or tag == "BUFF" or tag == "HAS_BUFF" or tag == "EXTERNAL_DEFENSIVE" then
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
    
    -- Use the base spell ID for storage so icon lookups work correctly
    -- (e.g., Hamstring rank 3 is stored under base ID 1715, not rank ID 7373)
    local storageID = sourceSpellID
    
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
        -- Store expiration, duration, and stacks for display
        self.activeAuras[storageID][destGUID] = {
            expiration = expiration,
            duration = duration,
            stacks = stacks,
        }
        
        local stackInfo = stacks > 0 and (" (" .. stacks .. " stacks)") or ""
        self.Utils:LogInfo("AuraTracker: Aura applied", spellName, "(", spellID, "->", storageID, ") on", destName, "expires in", string.format("%.1f", expiration - GetTime()) .. stackInfo)
        
        -- Notify CooldownIcons
        self:NotifyAuraChange(sourceSpellID, true)
        
    elseif subEvent == "SPELL_AURA_REMOVED" then
        -- Aura removed
        if self.activeAuras[storageID] then
            self.activeAuras[storageID][destGUID] = nil
        end
        
        self.Utils:LogDebug("AuraTracker: Aura removed", spellName, "from", destName)
        
        -- Notify CooldownIcons
        self:NotifyAuraChange(sourceSpellID, self:IsAuraActive(sourceSpellID))
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
    
    -- Find the source spell ID
    local sourceSpellID = self.auraToSpellMap[spellID]
    if not sourceSpellID then
        local baseSpellID = self.rankToBaseMap[spellID]
        if baseSpellID then
            sourceSpellID = baseSpellID
        end
    end
    
    if not sourceSpellID then return end
    
    local storageID = sourceSpellID
    
    -- Determine if this is a buff based on spell data
    local isBuff = (destGUID == self.playerGUID)  -- Default: self = buff
    local spellData = self.LibSpellDB and self.LibSpellDB:GetSpellInfo(sourceSpellID)
    if spellData and spellData.tags then
        for _, tag in ipairs(spellData.tags) do
            if tag == "HOT" or tag == "HAS_HOT" or tag == "HEAL_SINGLE" or tag == "HEAL_AOE" 
               or tag == "BUFF" or tag == "HAS_BUFF" or tag == "EXTERNAL_DEFENSIVE" then
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

-- Determine the aura type for targeting logic
-- Returns: isHelpful, isSelfOnly, isCC
-- isHelpful: true for buffs/heals, false for hostile debuffs
-- isSelfOnly: true for self-only buffs (Recklessness, etc.)
-- isCC: true for CC spells (track across all targets)
function AuraTracker:GetAuraType(spellID)
    local isHelpful = false
    local isSelfOnly = false
    local isCC = false
    
    -- Check spellToAuraMap first (has explicit type info)
    local auraInfo = self.spellToAuraMap[spellID]
    if auraInfo then
        isHelpful = auraInfo.isBuff or auraInfo.type == "BUFF"
        isSelfOnly = auraInfo.onTarget == false
    end
    
    -- Check LibSpellDB for spell data and tags
    if self.LibSpellDB then
        local spellData = self.LibSpellDB:GetSpellInfo(spellID)
        if spellData then
            -- Check appliesAura config (if not already determined)
            if not auraInfo and spellData.appliesAura then
                isHelpful = spellData.appliesAura.type == "BUFF"
                isSelfOnly = spellData.appliesAura.onTarget == false
            end
            
            -- Check tags for CC and helpful indicators
            if spellData.tags then
                for _, tag in ipairs(spellData.tags) do
                    -- Only hard CC tracks across all targets (stuns, polymorphs, fears)
                    -- Soft CC (snares like Hamstring) are spammable and follow normal target rules
                    if tag == "CC_HARD" then
                        isCC = true
                    end
                    -- Helpful tags (if not already determined)
                    if not auraInfo then
                        if tag == "HOT" or tag == "HAS_HOT" or tag == "HEAL_SINGLE" or tag == "HEAL_AOE" 
                           or tag == "BUFF" or tag == "HAS_BUFF" or tag == "EXTERNAL_DEFENSIVE" then
                            isHelpful = true
                        end
                    end
                end
            end
        end
    end
    
    return isHelpful, isSelfOnly, isCC
end

-- Get the appropriate GUID to check for an aura based on targeting logic
-- Returns: GUID to check, or nil for "check all targets" (CC spells)
--
-- Rules:
-- 1. CC spells (CC_HARD, CC_SOFT): return nil to signal "check all targets"
-- 2. Self-only buffs (Recklessness): always check self
-- 3. Targeting enemy:
--    - Hostile effects -> only that enemy
--    - Helpful effects -> targettarget if friendly (and setting enabled), else self
-- 4. Targeting ally:
--    - Hostile effects -> targettarget if hostile (and setting enabled)
--    - Helpful effects -> that ally
-- 5. No target: same as targeting self
function AuraTracker:GetRelevantTargetGUID(spellID)
    local isHelpful, isSelfOnly, isCC = self:GetAuraType(spellID)
    local playerGUID = self.playerGUID
    
    -- CC spells track across all targets - return nil to signal this
    if isCC then
        return nil, true  -- nil GUID, isCC = true
    end
    
    -- Self-only buffs always check self
    if isSelfOnly then
        return playerGUID, false
    end
    
    -- Check if targettarget support is enabled
    local db = addon.db and addon.db.profile and addon.db.profile.icons or {}
    local useTargettarget = db.auraTargettargetSupport or false
    
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
        -- Targeting an enemy
        if isHelpful then
            -- Helpful effect: check targettarget if friendly (and enabled), else self
            if useTargettarget and targettargetIsFriend then
                return targettargetGUID, false
            else
                return playerGUID, false
            end
        else
            -- Hostile effect: only check this enemy
            return targetGUID, false
        end
    elseif targetIsFriend then
        -- Targeting an ally
        if isHelpful then
            -- Helpful effect: check this ally
            return targetGUID, false
        else
            -- Hostile effect: check targettarget if hostile (and enabled)
            if useTargettarget and targettargetIsEnemy then
                return targettargetGUID, false
            else
                return nil, false  -- No valid hostile target
            end
        end
    else
        -- No target: same as targeting self
        if isHelpful then
            return playerGUID, false
        else
            return nil, false  -- No valid hostile target
        end
    end
end

-- Get the longest aura duration across all targets (for CC spells)
function AuraTracker:GetLongestAuraRemaining(spellID)
    local targets = self.activeAuras[spellID]
    if not targets then return 0, 0, 0 end
    
    local now = GetTime()
    local maxRemaining = 0
    local maxDuration = 0
    local maxStacks = 0
    
    for guid, auraData in pairs(targets) do
        local expiration = type(auraData) == "table" and auraData.expiration or auraData
        local duration = type(auraData) == "table" and auraData.duration or 0
        local stacks = type(auraData) == "table" and auraData.stacks or 0
        local remaining = expiration - now
        if remaining > maxRemaining then
            maxRemaining = remaining
            maxDuration = duration
            maxStacks = stacks
        end
    end
    
    return maxRemaining, maxDuration, maxStacks
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

-- Check if a spell's aura is currently active
-- Uses same smart target resolution as GetAuraRemaining for consistency
function AuraTracker:IsAuraActive(spellID)
    local targets = self.activeAuras[spellID]
    if not targets then return false end
    
    -- Get the relevant target based on aura type and current targeting
    local relevantGUID, isCC = self:GetRelevantTargetGUID(spellID)
    local now = GetTime()
    
    -- CC spells: check any target
    if isCC then
        for targetGUID, auraData in pairs(targets) do
            local expiration = type(auraData) == "table" and auraData.expiration or auraData
            if expiration > now then
                return true
            end
        end
        return false
    end
    
    -- Non-CC: check only the relevant target
    if not relevantGUID then
        return false
    end
    
    if targets[relevantGUID] then
        local auraData = targets[relevantGUID]
        local expiration = type(auraData) == "table" and auraData.expiration or auraData
        if expiration > now then
            return true
        end
    end
    
    return false
end

-- Get the remaining duration, total duration, and stacks of a spell's aura
-- Uses smart target resolution based on aura type and current targeting
function AuraTracker:GetAuraRemaining(spellID)
    -- Active auras are stored by sourceSpellID
    local targets = self.activeAuras[spellID]
    if not targets then return 0, 0, 0 end
    
    -- Get the relevant target based on aura type and current targeting
    local relevantGUID, isCC = self:GetRelevantTargetGUID(spellID)
    
    -- CC spells: track across all targets (longest duration)
    if isCC then
        return self:GetLongestAuraRemaining(spellID)
    end
    
    -- No valid target for this aura type
    if not relevantGUID then
        return 0, 0, 0
    end
    
    -- Check specific target
    local now = GetTime()
    if targets[relevantGUID] then
        local auraData = targets[relevantGUID]
        local expiration = type(auraData) == "table" and auraData.expiration or auraData
        local remaining = expiration - now
        if remaining > 0 then
            local duration = type(auraData) == "table" and auraData.duration or 0
            local stacks = type(auraData) == "table" and auraData.stacks or 0
            return remaining, duration, stacks
        end
    end
    
    -- No valid aura on relevant target
    return 0, 0, 0
end

-- Get count of targets with this aura active
function AuraTracker:GetAuraTargetCount(spellID)
    -- Active auras are stored by sourceSpellID
    local targets = self.activeAuras[spellID]
    if not targets then return 0 end
    
    local now = GetTime()
    local count = 0
    
    for targetGUID, auraData in pairs(targets) do
        local expiration = type(auraData) == "table" and auraData.expiration or auraData
        if expiration > now then
            count = count + 1
        end
    end
    
    return count
end

-- Get stack count for a spell's aura
-- Uses smart target resolution based on aura type and current targeting
function AuraTracker:GetAuraStacks(spellID)
    local targets = self.activeAuras[spellID]
    if not targets then return 0 end
    
    -- Get the relevant target based on aura type and current targeting
    local relevantGUID, isCC = self:GetRelevantTargetGUID(spellID)
    
    -- CC spells: get stacks from longest aura
    if isCC then
        local _, _, stacks = self:GetLongestAuraRemaining(spellID)
        return stacks
    end
    
    -- No valid target for this aura type
    if not relevantGUID then
        return 0
    end
    
    -- Check specific target
    local now = GetTime()
    if targets[relevantGUID] then
        local auraData = targets[relevantGUID]
        if type(auraData) == "table" then
            local expiration = auraData.expiration or 0
            if expiration > now then
                return auraData.stacks or 0
            end
        end
    end
    
    -- No valid aura on relevant target
    return 0
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
-- Enable/Disable
-------------------------------------------------------------------------------

function AuraTracker:Enable()
    self.playerGUID = UnitGUID("player")
    self:BuildAuraMappings()
end

function AuraTracker:Disable()
    wipe(self.activeAuras)
end

function AuraTracker:Refresh()
    self:BuildAuraMappings()
end
