--[[
    VeevHUD - Aura Cache System
    Buff/Debuff caching for efficient aura lookups
    Scans all buffs/debuffs once per unit, cached until UNIT_AURA fires
]]

local ADDON_NAME, addon = ...

addon.Utils = addon.Utils or {}
local Utils = addon.Utils

-------------------------------------------------------------------------------
-- Buff/Debuff Caching
-------------------------------------------------------------------------------

-- Cache structures: buffCache[unit][spellID] = auraData, debuffCache[unit][spellID] = auraData
-- Also cache by name for fallback lookups: buffCacheByName[unit][name] = auraData
Utils.buffCache = {}
Utils.debuffCache = {}
Utils.buffCacheByName = {}
Utils.debuffCacheByName = {}
Utils.auraCacheValid = {}  -- auraCacheValid[unit] = true when cache is populated

-- Populate buff cache for a unit (scans once, stores all buffs)
function Utils:PopulateBuffCache(unit)
    if self.auraCacheValid[unit] then return end
    
    self.buffCache[unit] = {}
    self.buffCacheByName[unit] = {}
    
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
            self.buffCache[unit][auraSpellID] = auraData
        end
        if name then
            self.buffCacheByName[unit][name] = auraData
        end
    end
    
    self.auraCacheValid[unit] = true
end

-- Populate debuff cache for a unit
function Utils:PopulateDebuffCache(unit)
    local cacheKey = unit .. "_debuff"
    if self.auraCacheValid[cacheKey] then return end
    
    self.debuffCache[unit] = {}
    self.debuffCacheByName[unit] = {}
    
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
            self.debuffCache[unit][auraSpellID] = auraData
        end
        if name then
            self.debuffCacheByName[unit][name] = auraData
        end
    end
    
    self.auraCacheValid[cacheKey] = true
end

-- Invalidate aura cache for a unit
function Utils:InvalidateAuraCache(unit)
    self.auraCacheValid[unit] = nil
    self.auraCacheValid[unit .. "_debuff"] = nil
    self.buffCache[unit] = nil
    self.debuffCache[unit] = nil
    self.buffCacheByName[unit] = nil
    self.debuffCacheByName[unit] = nil
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
    
    local cache = self.buffCache[unit]
    if cache and cache[spellID] then
        return cache[spellID]
    end
    
    -- Fallback to name lookup
    if spellName then
        local nameCache = self.buffCacheByName[unit]
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
    
    local cache = self.debuffCache[unit]
    if cache and cache[spellID] then
        return cache[spellID]
    end
    
    -- Fallback to name lookup
    if spellName then
        local nameCache = self.debuffCacheByName[unit]
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
            Utils:InvalidateAuraCache(unit)
        elseif event == "PLAYER_TARGET_CHANGED" then
            Utils:InvalidateAuraCache("target")
            Utils:InvalidateAuraCache("targettarget")
        elseif event == "PLAYER_ENTERING_WORLD" then
            Utils:InvalidateAllAuraCaches()
        end
    end)
    
    self.auraCacheFrame = frame
end
