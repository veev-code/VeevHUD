--[[
    VeevHUD - Aura Cache System
    Buff/Debuff caching for efficient aura lookups
    Scans all buffs/debuffs once per unit, cached until UNIT_AURA fires
    
    Cache is keyed by GUID for correct invalidation when UNIT_AURA fires
    for unit tokens like "party1" that may also be "targettarget"
]]

local _, addon = ...

-- Localized WoW API functions (hot path)
local UnitGUID = UnitGUID
local UnitBuff = UnitBuff
local UnitDebuff = UnitDebuff

addon.Utils = addon.Utils or {}
local Utils = addon.Utils

-------------------------------------------------------------------------------
-- Buff/Debuff Caching (by GUID)
-------------------------------------------------------------------------------

-- Cache structures: buffCache[guid][spellID] = auraData
-- Also cache by name for fallback lookups: buffCacheByName[guid][name] = auraData
Utils.buffCache = {}
Utils.debuffCache = {}
Utils.buffCacheByName = {}
Utils.debuffCacheByName = {}
Utils.auraCacheValid = {}  -- auraCacheValid[guid] = true for buffs, auraCacheValid[guid.."_debuff"] for debuffs
Utils.recentPlayerBuffs = {}  -- [spellID] = { name, icon, lastSeen } — session-only, for Custom Auras UI

local RECENT_BUFF_CAP = 50

-- Populate buff cache for a unit (scans once, stores all buffs)
function Utils:PopulateBuffCache(unit)
    local guid = UnitGUID(unit)
    if not guid then return end
    
    if self.auraCacheValid[guid] then return end
    
    self.buffCache[guid] = {}
    self.buffCacheByName[guid] = {}
    
    for i = 1, 40 do
        local name, icon, count, debuffType, duration, expirationTime, source, 
              isStealable, nameplateShowPersonal, auraSpellID = UnitBuff(unit, i)
        
        if not name then break end
        
        local auraData = {
            name = name,
            icon = icon,
            count = count or 0,
            debuffType = debuffType,
            duration = duration or 0,
            expirationTime = expirationTime or 0,
            source = source,
            isStealable = isStealable,
            nameplateShowPersonal = nameplateShowPersonal,
            spellID = auraSpellID,
        }
        
        if auraSpellID then
            self.buffCache[guid][auraSpellID] = auraData
        end
        if name then
            self.buffCacheByName[guid][name] = auraData
        end
    end
    
    self.auraCacheValid[guid] = true

    -- Record player buffs for the "Recently Seen" list in Custom Auras UI
    if unit == "player" then
        local time = GetTime()
        local recent = self.recentPlayerBuffs
        local hasNew = false
        for spellID, auraData in pairs(self.buffCache[guid]) do
            if spellID then
                local existing = recent[spellID]
                if existing then
                    existing.lastSeen = time
                else
                    hasNew = true
                    recent[spellID] = {
                        name = auraData.name,
                        icon = auraData.icon,
                        lastSeen = time,
                    }
                end
            end
        end
        -- Evict oldest entries if over cap
        if hasNew then
            local count = 0
            for _ in pairs(recent) do count = count + 1 end
            if count > RECENT_BUFF_CAP then
                local sorted = {}
                for id, data in pairs(recent) do
                    sorted[#sorted + 1] = { id = id, lastSeen = data.lastSeen }
                end
                table.sort(sorted, function(a, b) return a.lastSeen > b.lastSeen end)
                for i = RECENT_BUFF_CAP + 1, #sorted do
                    recent[sorted[i].id] = nil
                end
            end
            -- Notify AceConfig so the Custom Auras tab updates in real-time (only if open)
            local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
            if AceConfigDialog and AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames["VeevHUD"] then
                local AceConfigRegistry = LibStub("AceConfigRegistry-3.0", true)
                if AceConfigRegistry then
                    AceConfigRegistry:NotifyChange("VeevHUD")
                end
            end
        end
    end
end

-- Populate debuff cache for a unit
function Utils:PopulateDebuffCache(unit)
    local guid = UnitGUID(unit)
    if not guid then return end
    
    local cacheKey = guid .. "_debuff"
    if self.auraCacheValid[cacheKey] then return end
    
    self.debuffCache[guid] = {}
    self.debuffCacheByName[guid] = {}
    
    for i = 1, 40 do
        local name, icon, count, debuffType, duration, expirationTime, source, 
              isStealable, nameplateShowPersonal, auraSpellID = UnitDebuff(unit, i)
        
        if not name then break end
        
        local auraData = {
            name = name,
            icon = icon,
            count = count or 0,
            debuffType = debuffType,
            duration = duration or 0,
            expirationTime = expirationTime or 0,
            source = source,
            isStealable = isStealable,
            nameplateShowPersonal = nameplateShowPersonal,
            spellID = auraSpellID,
        }
        
        if auraSpellID then
            self.debuffCache[guid][auraSpellID] = auraData
        end
        if name then
            self.debuffCacheByName[guid][name] = auraData
        end
    end
    
    self.auraCacheValid[cacheKey] = true
end

-- Invalidate aura cache for a unit (by GUID)
function Utils:InvalidateAuraCacheByGUID(guid)
    if not guid then return end
    self.auraCacheValid[guid] = nil
    self.auraCacheValid[guid .. "_debuff"] = nil
    self.buffCache[guid] = nil
    self.debuffCache[guid] = nil
    self.buffCacheByName[guid] = nil
    self.debuffCacheByName[guid] = nil
end

-- Invalidate aura cache for a unit token (resolves to GUID)
function Utils:InvalidateAuraCache(unit)
    local guid = UnitGUID(unit)
    self:InvalidateAuraCacheByGUID(guid)
end

-- Invalidate all aura caches
function Utils:InvalidateAllAuraCaches()
    wipe(self.buffCache)
    wipe(self.debuffCache)
    wipe(self.buffCacheByName)
    wipe(self.debuffCacheByName)
    wipe(self.auraCacheValid)
end

-- Get cached buff by spell ID (populates cache if needed)
-- Returns: auraData table or nil
function Utils:GetCachedBuff(unit, spellID, spellName)
    self:EnsureAuraCacheInitialized()
    self:PopulateBuffCache(unit)
    
    local guid = UnitGUID(unit)
    if not guid then return nil end
    
    local cache = self.buffCache[guid]
    if cache and cache[spellID] then
        return cache[spellID]
    end
    
    -- Fallback to name lookup
    if spellName then
        local nameCache = self.buffCacheByName[guid]
        if nameCache and nameCache[spellName] then
            return nameCache[spellName]
        end
    end
    
    return nil
end

-- Get cached debuff by spell ID (populates cache if needed)
-- Returns: auraData table or nil
function Utils:GetCachedDebuff(unit, spellID, spellName)
    self:EnsureAuraCacheInitialized()
    self:PopulateDebuffCache(unit)
    
    local guid = UnitGUID(unit)
    if not guid then return nil end
    
    local cache = self.debuffCache[guid]
    if cache and cache[spellID] then
        return cache[spellID]
    end
    
    -- Fallback to name lookup
    if spellName then
        local nameCache = self.debuffCacheByName[guid]
        if nameCache and nameCache[spellName] then
            return nameCache[spellName]
        end
    end
    
    return nil
end

-- Ensure aura cache event frame is set up (lazy initialization)
function Utils:EnsureAuraCacheInitialized()
    if self.auraCacheFrame then return end
    
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("UNIT_AURA")
    frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    
    frame:SetScript("OnEvent", function(eventFrame, event, unit, ...)
        if event == "UNIT_AURA" then
            -- Invalidate by GUID - handles all unit tokens including volatile ones
            local guid = UnitGUID(unit)
            Utils:InvalidateAuraCacheByGUID(guid)
        elseif event == "PLAYER_TARGET_CHANGED" then
            -- No need to explicitly invalidate target/targettarget
            -- GUID-based caching handles this automatically
        elseif event == "PLAYER_ENTERING_WORLD" then
            Utils:InvalidateAllAuraCaches()
        end
    end)
    
    self.auraCacheFrame = frame
end
