--[[
    VeevHUD - Database Management
    
    Migrated to AceDB-3.0 for profile support (including LibDualSpec).
    We keep backwards compatibility by migrating the legacy
    VeevHUDDB.overrides format into an AceDB "Default" profile on first run.
]]

local ADDON_NAME, addon = ...

addon.Database = {}
local Database = addon.Database

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function Database:Initialize()
    VeevHUDDB = type(VeevHUDDB) == "table" and VeevHUDDB or {}

    -- One-time migration from legacy sparse overrides format -> AceDB profile.
    self:UpgradeLegacyDBIfNeeded()

    local AceDB = LibStub and LibStub("AceDB-3.0", true)
    if not AceDB then
        error("VeevHUD: AceDB-3.0 missing (embedded libraries not loaded)")
    end

    local defaults = self:GetAceDefaults()

    -- Use a shared global profile called "Default" (matches legacy behavior).
    addon.db = AceDB:New("VeevHUDDB", defaults, true)

    -- Ensure expected global tables exist even if user DB is missing them.
    addon.db.global = addon.db.global or {}
    addon.db.global.migrationsShown = addon.db.global.migrationsShown or {}

    -- Hook profile change events so the HUD refreshes when profiles/specializations switch.
    addon.db.RegisterCallback(addon, "OnNewProfile", "OnProfileChanged")
    addon.db.RegisterCallback(addon, "OnProfileChanged", "OnProfileChanged")
    addon.db.RegisterCallback(addon, "OnProfileCopied", "OnProfileChanged")
    addon.db.RegisterCallback(addon, "OnProfileReset", "OnProfileChanged")

    -- LibDualSpec: auto-switch profiles on spec change (optional but embedded).
    local LibDualSpec = LibStub and LibStub("LibDualSpec-1.0", true)
    if LibDualSpec then
        LibDualSpec:EnhanceDatabase(addon.db, ADDON_NAME)
    end
end

-------------------------------------------------------------------------------
-- Defaults
-------------------------------------------------------------------------------

function Database:GetAceDefaults()
    -- Keep existing default profile structure.
    -- Add global defaults for one-time screens and migration notices.
    return {
        profile = addon.Constants.DEFAULTS.profile,
        global = {
            welcomeShown = false,
            migrationsShown = {},
        },
    }
end

-------------------------------------------------------------------------------
-- Settings Value Helpers
-------------------------------------------------------------------------------

-- Get the default value for a path
function Database:GetDefaultValue(path)
    local defaults = addon.Constants.DEFAULTS and addon.Constants.DEFAULTS.profile or {}
    return self:GetValueAtPath(defaults, path)
end

-- Get the current value for a path
function Database:GetSettingValue(path)
    local profile = addon.db and addon.db.profile or {}
    return self:GetValueAtPath(profile, path)
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

-- Set a spellConfig override (profile-scoped in AceDB)
function Database:SetSpellConfigOverride(spellID, field, value, specKey)
    specKey = specKey or self:GetSpecKey()

    if not addon.db or not addon.db.profile then return end

    addon.db.profile.spellConfig = addon.db.profile.spellConfig or {}
    addon.db.profile.spellConfig[specKey] = addon.db.profile.spellConfig[specKey] or {}
    addon.db.profile.spellConfig[specKey][spellID] = addon.db.profile.spellConfig[specKey][spellID] or {}

    if value == nil then
        addon.db.profile.spellConfig[specKey][spellID][field] = nil
        if next(addon.db.profile.spellConfig[specKey][spellID]) == nil then
            addon.db.profile.spellConfig[specKey][spellID] = nil
        end
        if next(addon.db.profile.spellConfig[specKey]) == nil then
            addon.db.profile.spellConfig[specKey] = nil
        end
        if next(addon.db.profile.spellConfig) == nil then
            addon.db.profile.spellConfig = nil
        end
    else
        addon.db.profile.spellConfig[specKey][spellID][field] = value
    end
end

-- Clear all spellConfig overrides for a specific spell
function Database:ClearSpellConfigOverride(spellID, specKey)
    specKey = specKey or self:GetSpecKey()

    if not addon.db or not addon.db.profile or not addon.db.profile.spellConfig then return end

    if addon.db.profile.spellConfig[specKey] then
        addon.db.profile.spellConfig[specKey][spellID] = nil
        if next(addon.db.profile.spellConfig[specKey]) == nil then
            addon.db.profile.spellConfig[specKey] = nil
        end
        if next(addon.db.profile.spellConfig) == nil then
            addon.db.profile.spellConfig = nil
        end
    end
end

-- Check if a spell has any overrides (for showing "modified" indicator)
function Database:IsSpellConfigModified(spellID, specKey)
    specKey = specKey or self:GetSpecKey()
    local spellConfig = addon.db and addon.db.profile and addon.db.profile.spellConfig
    if spellConfig and spellConfig[specKey] and spellConfig[specKey][spellID] then
        local cfg = spellConfig[specKey][spellID]
        return cfg.enabled ~= nil or cfg.rowIndex ~= nil or cfg.order ~= nil
    end
    return false
end

-------------------------------------------------------------------------------
-- Path Helpers (used by AceConfig get/set)
-------------------------------------------------------------------------------

function Database:GetValueAtPath(root, path)
    local current = root
    for _, key in ipairs({ strsplit(".", path) }) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[addon.Utils:ToKeyType(key)]
    end
    return current
end

function Database:SetValueAtPath(root, path, value)
    if type(root) ~= "table" then return end

    local keys = { strsplit(".", path) }
    local current = root

    for i = 1, #keys - 1 do
        local key = addon.Utils:ToKeyType(keys[i])
        if type(current[key]) ~= "table" then
            current[key] = {}
        end
        current = current[key]
    end

    local finalKey = addon.Utils:ToKeyType(keys[#keys])
    current[finalKey] = value
end

-------------------------------------------------------------------------------
-- Legacy Migration
-------------------------------------------------------------------------------

function Database:UpgradeLegacyDBIfNeeded()
    if type(VeevHUDDB) == "table" and VeevHUDDB.global and VeevHUDDB.global.dbVersion then
        return
    end

    local legacy = VeevHUDDB or {}

    -- Legacy format:
    --   VeevHUDDB.overrides = { ...sparse... }
    --   VeevHUDDB.welcomeShown = boolean
    --   VeevHUDDB.migrationsShown = { [id]=true, ... }
    local legacyOverrides = type(legacy.overrides) == "table" and legacy.overrides or {}

    local migrated = {
        profileKeys = {},
        profiles = {
            Default = legacyOverrides,
        },
        global = {},
    }

    if legacy.welcomeShown ~= nil then
        migrated.global.welcomeShown = legacy.welcomeShown
    end
    if type(legacy.migrationsShown) == "table" then
        migrated.global.migrationsShown = legacy.migrationsShown
    end

    migrated.global.dbVersion = "ace3"

    VeevHUDDB = migrated
end

-------------------------------------------------------------------------------
-- Convenience wrappers (kept for backward compatibility with existing code)
-------------------------------------------------------------------------------

function Database:SetOverride(path, value)
    if not addon.db or not addon.db.profile then return end
    self:SetValueAtPath(addon.db.profile, path, value)
end

function Database:ClearOverride(path)
    if not addon.db or not addon.db.profile then return end
    -- With AceDB, "clearing" means resetting to the default value.
    -- We cannot set keys to nil because AceDB copies scalar defaults
    -- directly into the profile table (no metatable fallback).
    -- AceDB's removeDefaults() handles sparseness at save time.
    local defaultValue = self:GetDefaultValue(path)
    self:SetValueAtPath(addon.db.profile, path, defaultValue)
end

function Database:ResetProfile()
    if addon.db and addon.db.ResetProfile then
        addon.db:ResetProfile()
    end

    addon.Utils:Print("Profile reset to defaults.")
end
