--[[
    VeevHUD - Database Management
    
    Philosophy: Only save user customizations, not entire profile.
    This way users always get the latest addon defaults unless they
    explicitly changed a specific setting.
    
    VeevHUDDB.overrides contains ONLY user-customized settings.
    Everything else comes from Constants.DEFAULTS.
]]

local ADDON_NAME, addon = ...

addon.Database = {}
local Database = addon.Database

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function Database:Initialize()
    -- Initialize overrides table (stores only user-customized settings)
    VeevHUDDB.overrides = VeevHUDDB.overrides or {}
    
    -- Build the live profile by layering overrides on top of defaults
    self:RebuildLiveProfile()
end

-------------------------------------------------------------------------------
-- Profile Building
-------------------------------------------------------------------------------

-- Rebuild the live profile from defaults + overrides
function Database:RebuildLiveProfile()
    local defaults = addon.Constants.DEFAULTS.profile
    local overrides = VeevHUDDB.overrides or {}
    
    -- Create a proxy table that reads from overrides first, then defaults
    addon.db = {
        profile = self:MergeWithDefaults(overrides, defaults)
    }
end

-- Deep merge: overrides take precedence over defaults
function Database:MergeWithDefaults(overrides, defaults)
    -- Just deep copy defaults (DeepCopy handles arrays correctly now)
    local result = self:DeepCopy(defaults)
    
    -- Then apply overrides on top
    self:ApplyOverrides(result, overrides)
    
    return result
end

-- Apply overrides recursively
function Database:ApplyOverrides(target, overrides)
    for k, v in pairs(overrides) do
        if type(v) == "table" and type(target[k]) == "table" then
            self:ApplyOverrides(target[k], v)
        else
            target[k] = v
        end
    end
end

function Database:DeepCopy(orig)
    local copy
    if type(orig) == "table" then
        copy = {}
        -- Use ipairs first for arrays to preserve order
        for i, v in ipairs(orig) do
            copy[i] = self:DeepCopy(v)
        end
        -- Then copy any non-numeric keys
        for k, v in pairs(orig) do
            if type(k) ~= "number" then
                copy[k] = self:DeepCopy(v)
            end
        end
    else
        copy = orig
    end
    return copy
end

-------------------------------------------------------------------------------
-- Override Management
-------------------------------------------------------------------------------

-- Save a user override (only saves the specific changed value)
function Database:SetOverride(path, value)
    local overrides = VeevHUDDB.overrides
    local keys = {strsplit(".", path)}
    
    -- Navigate to the parent table, creating as needed
    for i = 1, #keys - 1 do
        local key = addon.Utils:ToKeyType(keys[i])
        if not overrides[key] then
            overrides[key] = {}
        end
        overrides = overrides[key]
    end
    
    -- Set the value
    overrides[addon.Utils:ToKeyType(keys[#keys])] = value
    
    -- Rebuild live profile
    self:RebuildLiveProfile()
end

-- Clear a specific override (revert to default)
function Database:ClearOverride(path)
    local overrides = VeevHUDDB.overrides
    local keys = {strsplit(".", path)}
    
    -- Navigate to the parent
    for i = 1, #keys - 1 do
        local key = addon.Utils:ToKeyType(keys[i])
        if not overrides[key] then
            return -- Path doesn't exist, nothing to clear
        end
        overrides = overrides[key]
    end
    
    -- Clear the value
    overrides[addon.Utils:ToKeyType(keys[#keys])] = nil
    
    -- Rebuild live profile
    self:RebuildLiveProfile()
end

-- Reset entire profile to defaults
function Database:ResetProfile()
    -- Clear all overrides - user gets fresh defaults
    VeevHUDDB.overrides = {}
    self:RebuildLiveProfile()

    -- Refresh all modules
    for name, module in pairs(addon.modules) do
        if module.Refresh then
            module:Refresh()
        end
    end

    addon.Utils:Print("Profile reset to defaults. Type /reload to apply all changes.")
end

-------------------------------------------------------------------------------
-- Settings Value Helpers
-------------------------------------------------------------------------------

-- Get the default value for a path
function Database:GetDefaultValue(path)
    local defaults = addon.Constants.DEFAULTS.profile
    local keys = {strsplit(".", path)}
    
    local current = defaults
    for i, key in ipairs(keys) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[addon.Utils:ToKeyType(key)]
    end
    
    return current
end

-- Get the current value for a path
function Database:GetSettingValue(path)
    local profile = addon.db and addon.db.profile or {}
    local keys = {strsplit(".", path)}
    
    local current = profile
    for i, key in ipairs(keys) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[addon.Utils:ToKeyType(key)]
    end
    
    return current
end

-- Check if a setting path is overridden by user
function Database:IsSettingOverridden(path)
    local currentValue = self:GetSettingValue(path)
    local defaultValue = self:GetDefaultValue(path)
    return currentValue ~= defaultValue
end

-- Check if a row-based setting is enabled for a specific row index
-- settingValue: one of C.ROW_SETTING values ("none", "primary", "all", etc.)
-- rowIndex: 1 = Primary, 2 = Secondary, 3+ = Utility
function Database:IsRowSettingEnabled(settingValue, rowIndex)
    local RS = addon.Constants.ROW_SETTING
    
    if settingValue == RS.NONE then
        return false
    elseif settingValue == RS.PRIMARY then
        return rowIndex == 1
    elseif settingValue == RS.PRIMARY_SECONDARY then
        return rowIndex == 1 or rowIndex == 2
    elseif settingValue == RS.SECONDARY_UTILITY then
        return rowIndex >= 2
    elseif settingValue == RS.UTILITY then
        return rowIndex >= 3
    elseif settingValue == RS.ALL then
        return true
    end
    
    -- Backwards compatibility: treat boolean true as "all"
    return settingValue == true
end

-------------------------------------------------------------------------------
-- Spell Config Helpers
-------------------------------------------------------------------------------

-- Get the specKey for the current player (e.g., "WARRIOR_FURY")
function Database:GetSpecKey()
    local class = addon.playerClass or "UNKNOWN"
    local spec = addon.playerSpec or "UNKNOWN"
    return class .. "_" .. spec
end

-- Get spellConfig for current spec (read from live profile, safe nil handling)
function Database:GetSpellConfig(specKey)
    specKey = specKey or self:GetSpecKey()
    local spellCfgAll = addon.db and addon.db.profile and addon.db.profile.spellConfig or {}
    return spellCfgAll[specKey] or {}
end

-- Get spellConfig override for a specific spell
function Database:GetSpellConfigForSpell(spellID, specKey)
    local spellCfg = self:GetSpellConfig(specKey)
    return spellCfg[spellID] or {}
end

-- Set a spellConfig override (writes to VeevHUDDB.overrides and rebuilds profile)
function Database:SetSpellConfigOverride(spellID, field, value, specKey)
    specKey = specKey or self:GetSpecKey()
    
    -- Initialize nested tables in overrides
    VeevHUDDB.overrides.spellConfig = VeevHUDDB.overrides.spellConfig or {}
    VeevHUDDB.overrides.spellConfig[specKey] = VeevHUDDB.overrides.spellConfig[specKey] or {}
    VeevHUDDB.overrides.spellConfig[specKey][spellID] = VeevHUDDB.overrides.spellConfig[specKey][spellID] or {}
    
    if value == nil then
        -- Remove override
        VeevHUDDB.overrides.spellConfig[specKey][spellID][field] = nil
        -- Clean up empty tables
        if next(VeevHUDDB.overrides.spellConfig[specKey][spellID]) == nil then
            VeevHUDDB.overrides.spellConfig[specKey][spellID] = nil
        end
        if next(VeevHUDDB.overrides.spellConfig[specKey]) == nil then
            VeevHUDDB.overrides.spellConfig[specKey] = nil
        end
        if next(VeevHUDDB.overrides.spellConfig) == nil then
            VeevHUDDB.overrides.spellConfig = nil
        end
    else
        VeevHUDDB.overrides.spellConfig[specKey][spellID][field] = value
    end
    
    -- Rebuild live profile
    self:RebuildLiveProfile()
end

-- Clear all spellConfig overrides for a specific spell
function Database:ClearSpellConfigOverride(spellID, specKey)
    specKey = specKey or self:GetSpecKey()
    
    if VeevHUDDB.overrides.spellConfig and VeevHUDDB.overrides.spellConfig[specKey] then
        VeevHUDDB.overrides.spellConfig[specKey][spellID] = nil
        if next(VeevHUDDB.overrides.spellConfig[specKey]) == nil then
            VeevHUDDB.overrides.spellConfig[specKey] = nil
        end
        if VeevHUDDB.overrides.spellConfig and next(VeevHUDDB.overrides.spellConfig) == nil then
            VeevHUDDB.overrides.spellConfig = nil
        end
    end
    
    self:RebuildLiveProfile()
end

-- Check if a spell has any overrides (for showing "modified" indicator)
function Database:IsSpellConfigModified(spellID, specKey)
    specKey = specKey or self:GetSpecKey()
    local overrides = VeevHUDDB.overrides.spellConfig
    if overrides and overrides[specKey] and overrides[specKey][spellID] then
        local cfg = overrides[specKey][spellID]
        return cfg.enabled ~= nil or cfg.rowIndex ~= nil or cfg.order ~= nil
    end
    return false
end
