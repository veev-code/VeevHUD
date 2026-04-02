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

    -- Migrate legacy config keys to current names (before AceDB wraps the table).
    self:MigrateAuraTrackerKeys()

    local AceDB = LibStub and LibStub("AceDB-3.0", true)
    if not AceDB then
        error("VeevHUD: AceDB-3.0 missing (embedded libraries not loaded)")
    end

    local defaults = self:GetAceDefaults()

    -- Use a shared global profile called "Default" (matches legacy behavior).
    addon.db = AceDB:New("VeevHUDDB", defaults, true)

    -- Initialize versioned migration system (sets dataVersion for new users).
    if addon.Migrations then
        addon.Migrations:Initialize()
    end

    -- Hook profile change events so the HUD refreshes when profiles/specializations switch.
    -- These use AceDB's standard callback mechanism (CallbackHandler dispatch).
    addon.db.RegisterCallback(addon, "OnNewProfile", "OnProfileChanged")
    addon.db.RegisterCallback(addon, "OnProfileChanged", "OnProfileChanged")
    addon.db.RegisterCallback(addon, "OnProfileCopied", "OnProfileChanged")
    addon.db.RegisterCallback(addon, "OnProfileReset", "OnProfileChanged")

    -- Safety net: some CallbackHandler-1.0 versions have a bug where
    -- db.callbacks:Fire() fails because Fire lives on the db object, not on the
    -- registry table stored as db.callbacks. When this happens, profile data is
    -- mutated but callbacks never dispatch — the HUD silently fails to refresh.
    -- Wrap profile-mutating methods to guarantee OnProfileChanged always runs.
    local function wrapProfileMethod(methodName)
        local original = addon.db[methodName]
        if not original then return end
        addon.db[methodName] = function(self, ...)
            addon._profileCallbackFired = false
            local ok, err = pcall(original, self, ...)
            if not ok then
                -- Suppress the known CallbackHandler Fire error; re-raise anything else
                if not err:find("'Fire'") then
                    error(err, 2)
                end
            end
            -- Only call manually if the AceDB callback didn't fire
            -- (this is the CallbackHandler Fire bug the safety net exists for)
            if not addon._profileCallbackFired then
                addon:OnProfileChanged()
            end
        end
    end

    wrapProfileMethod("ResetProfile")
    wrapProfileMethod("SetProfile")
    wrapProfileMethod("CopyProfile")

    -- Migrate old gap settings to unified layout.gaps (idempotent, per-profile)
    self:MigrateLayoutGaps()

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
        },
    }
end

-------------------------------------------------------------------------------
-- Layout Gap Migration
-------------------------------------------------------------------------------

--[[
    Migrate old scattered gap settings to the unified layout.gaps system.

    Old settings (now removed from defaults):
      auraTracker.gapAboveHealthBar  -> layout.gaps.healthBar
      layout.iconRowGap              -> layout.gaps.primaryRow (+ comboPoints.offsetY)
      comboPoints.offsetY            -> folded into layout.gaps.primaryRow
      icons.primarySecondaryGap      -> layout.gaps.secondaryRow (+ icons.rowSpacing)
      icons.sectionGap               -> layout.gaps.utilityRow   (+ icons.rowSpacing)

    Idempotent: only runs when old values are detected in the profile.
]]
function Database:MigrateLayoutGaps()
    local profile = addon.db and addon.db.profile
    if not profile then return end

    -- Check for any old gap values (nil means user never customized them)
    local pt = profile.auraTracker or {}
    local cp = profile.comboPoints or {}
    local ic = profile.icons or {}
    local ly = profile.layout or {}

    local oldGapAboveHealth = pt.gapAboveHealthBar
    local oldIconRowGap     = ly.iconRowGap
    local oldOffsetY        = cp.offsetY
    local oldRowSpacing     = ic.rowSpacing
    local oldPSGap          = ic.primarySecondaryGap
    local oldSectionGap     = ic.sectionGap

    -- Nothing to migrate if no old values exist
    if oldGapAboveHealth == nil and oldIconRowGap == nil and oldOffsetY == nil
       and oldPSGap == nil and oldSectionGap == nil then
        return
    end

    addon.Utils:LogInfo("Database: Migrating old gap settings to layout.gaps")

    -- Fill in defaults for any values the user didn't customize
    local gapAboveHealth = oldGapAboveHealth or 6
    local iconRowGap     = oldIconRowGap or 2
    local offsetY        = oldOffsetY or 0
    local rowSpacing     = oldRowSpacing or 1
    local psGap          = oldPSGap or 0
    local sectionGap     = oldSectionGap or 16

    -- Write new gap values
    profile.layout.gaps.healthBar    = gapAboveHealth
    profile.layout.gaps.primaryRow   = iconRowGap + offsetY
    profile.layout.gaps.secondaryRow = rowSpacing + psGap
    profile.layout.gaps.utilityRow   = rowSpacing + sectionGap

    -- Clean up old settings (no longer in defaults, would be orphaned data)
    if profile.auraTracker then profile.auraTracker.gapAboveHealthBar = nil end
    if profile.layout then profile.layout.iconRowGap = nil end
    if profile.comboPoints then profile.comboPoints.offsetY = nil end
    if profile.icons then
        profile.icons.primarySecondaryGap = nil
        profile.icons.sectionGap = nil
    end
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

-------------------------------------------------------------------------------
-- Aura Config Helpers (procs, external buffs, custom auras)
-------------------------------------------------------------------------------

-- Get the default enabled state for an aura
-- Checks: procInfo.lowPriority, then MINOR_EXTERNAL tag, then true
local function GetAuraDefaultEnabled(spellID)
    local lib = addon.LibSpellDB
    if lib then
        -- 1. Check proc lowPriority
        local procInfo = lib:GetProcInfo(spellID)
        if procInfo and procInfo.lowPriority then
            return false
        end
        -- 2. MINOR_EXTERNAL spells are disabled by default (except PVP_POWERUP)
        if lib:HasTag(spellID, "MINOR_EXTERNAL") and not lib:HasTag(spellID, "PVP_POWERUP") then
            return false
        end
    end
    -- 3. Default: enabled
    return true
end

-- Get auraConfig (profile-wide flat table of overrides)
function Database:GetAuraConfig()
    if not addon.db or not addon.db.profile then return {} end
    return addon.db.profile.auraConfig or {}
end

-- Check if an aura is enabled (respects user override, then default logic)
function Database:IsAuraEnabled(spellID)
    local cfg = addon.db and addon.db.profile and addon.db.profile.auraConfig
    if cfg then
        local override = cfg[spellID]
        if override ~= nil then
            return override
        end
    end
    return GetAuraDefaultEnabled(spellID)
end

-- Set aura enabled/disabled override (profile-wide, sparse: removed when matching default)
function Database:SetAuraEnabled(spellID, enabled)
    if not addon.db or not addon.db.profile then return end

    if enabled == GetAuraDefaultEnabled(spellID) then
        -- Matches default: remove override to keep storage sparse
        local auraConfig = addon.db.profile.auraConfig
        if auraConfig then
            auraConfig[spellID] = nil
            if next(auraConfig) == nil then
                addon.db.profile.auraConfig = nil
            end
        end
    else
        -- Differs from default: store explicit override
        if not addon.db.profile.auraConfig then
            addon.db.profile.auraConfig = {}
        end
        addon.db.profile.auraConfig[spellID] = enabled
    end
end

-- Reset all aura config overrides (re-enable all auras to defaults)
function Database:ResetAuraConfig()
    if not addon.db or not addon.db.profile then return end
    addon.db.profile.auraConfig = nil
end

-- Get the default source filter for an aura
-- MINOR_EXTERNAL spells default to "any" (commonly self-used), other externals to "notOwn"
local function GetAuraSourceFilterDefault(spellID, auraSource)
    local C = addon.Constants
    -- 1. MINOR_EXTERNAL spells default to "any" (e.g., drums — commonly self-used)
    local lib = addon.LibSpellDB
    if lib and spellID and lib:HasTag(spellID, "MINOR_EXTERNAL") then
        return C.AURA_SOURCE_ANY
    end
    -- 2. Source-type default
    if auraSource == "external" then return C.AURA_SOURCE_NOT_OWN end
    return C.AURA_SOURCE_ANY
end

-- Get aura source filter (respects user override, then default logic)
function Database:GetAuraSourceFilter(spellID, auraSource)
    local cfg = addon.db and addon.db.profile and addon.db.profile.auraSourceFilter
    if cfg then
        local override = cfg[spellID]
        if override then
            return override
        end
    end
    return GetAuraSourceFilterDefault(spellID, auraSource)
end

-- Set aura source filter override (sparse: removed when matching default)
function Database:SetAuraSourceFilter(spellID, filter, auraSource)
    if not addon.db or not addon.db.profile then return end

    if filter == GetAuraSourceFilterDefault(spellID, auraSource) then
        -- Matches default: remove override to keep storage sparse
        local cfg = addon.db.profile.auraSourceFilter
        if cfg then
            cfg[spellID] = nil
            if next(cfg) == nil then
                addon.db.profile.auraSourceFilter = nil
            end
        end
    else
        -- Differs from default: store explicit override
        if not addon.db.profile.auraSourceFilter then
            addon.db.profile.auraSourceFilter = {}
        end
        addon.db.profile.auraSourceFilter[spellID] = filter
    end
end

-------------------------------------------------------------------------------
-- Aura Glow Config
-------------------------------------------------------------------------------

-- Check if aura glow is enabled (default: true)
function Database:IsAuraGlowEnabled(spellID)
    local cfg = addon.db and addon.db.profile and addon.db.profile.auraGlowConfig
    if cfg then
        local override = cfg[spellID]
        if override ~= nil then
            return override
        end
    end
    return true
end

-- Set aura glow override (sparse: removed when matching default)
function Database:SetAuraGlowEnabled(spellID, enabled)
    if not addon.db or not addon.db.profile then return end

    if enabled == true then
        -- Matches default: remove override to keep storage sparse
        local cfg = addon.db.profile.auraGlowConfig
        if cfg then
            cfg[spellID] = nil
            if next(cfg) == nil then
                addon.db.profile.auraGlowConfig = nil
            end
        end
    else
        -- Differs from default: store explicit override
        if not addon.db.profile.auraGlowConfig then
            addon.db.profile.auraGlowConfig = {}
        end
        addon.db.profile.auraGlowConfig[spellID] = enabled
    end
end

-------------------------------------------------------------------------------
-- Aura Sound Config
-------------------------------------------------------------------------------

-- Get per-aura sound override (returns nil if no override set)
function Database:GetAuraSound(spellID)
    local cfg = addon.db and addon.db.profile and addon.db.profile.auraSoundConfig
    if cfg then
        return cfg[spellID]  -- "Sound Name" or nil
    end
    return nil
end

-- Set per-aura sound override (sparse: removed when "None" or nil)
function Database:SetAuraSound(spellID, soundName)
    if not addon.db or not addon.db.profile then return end

    if not soundName or soundName == "None" then
        -- Remove override to keep storage sparse
        local cfg = addon.db.profile.auraSoundConfig
        if cfg then
            cfg[spellID] = nil
            if next(cfg) == nil then
                addon.db.profile.auraSoundConfig = nil
            end
        end
    else
        if not addon.db.profile.auraSoundConfig then
            addon.db.profile.auraSoundConfig = {}
        end
        addon.db.profile.auraSoundConfig[spellID] = soundName
    end
end

-- Check if sound-on-refresh is enabled for an aura (default: use global setting)
function Database:GetAuraSoundOnRefresh(spellID)
    local cfg = addon.db and addon.db.profile and addon.db.profile.auraSoundRefreshConfig
    if cfg then
        local override = cfg[spellID]
        if override ~= nil then
            return override
        end
    end
    return addon.db.profile.auraTracker.soundOnRefresh
end

-- Set per-aura sound-on-refresh override (sparse: removed when matching global default)
function Database:SetAuraSoundOnRefresh(spellID, enabled)
    if not addon.db or not addon.db.profile then return end

    if enabled == addon.db.profile.auraTracker.soundOnRefresh then
        -- Matches global default: remove override
        local cfg = addon.db.profile.auraSoundRefreshConfig
        if cfg then
            cfg[spellID] = nil
            if next(cfg) == nil then
                addon.db.profile.auraSoundRefreshConfig = nil
            end
        end
    else
        if not addon.db.profile.auraSoundRefreshConfig then
            addon.db.profile.auraSoundRefreshConfig = {}
        end
        addon.db.profile.auraSoundRefreshConfig[spellID] = enabled
    end
end

-------------------------------------------------------------------------------
-- Buff Reminder Sound Config
-------------------------------------------------------------------------------

-- Get per-spell buff reminder sound override (returns nil if no override set)
function Database:GetBuffReminderSound(spellID)
    local cfg = addon.db and addon.db.profile and addon.db.profile.buffReminderSoundConfig
    if not cfg then return nil end

    local specKey = self:GetSpecKey()
    local specConfig = specKey and cfg[specKey]
    return specConfig and specConfig[spellID]
end

-- Set per-spell buff reminder sound override (sparse: removed when "None" or nil)
function Database:SetBuffReminderSound(spellID, soundName)
    if not addon.db or not addon.db.profile then return end

    local specKey = self:GetSpecKey()
    if not specKey then return end

    if not soundName or soundName == "None" then
        local cfg = addon.db.profile.buffReminderSoundConfig
        if cfg and cfg[specKey] then
            cfg[specKey][spellID] = nil
            if next(cfg[specKey]) == nil then
                cfg[specKey] = nil
            end
            if next(cfg) == nil then
                addon.db.profile.buffReminderSoundConfig = nil
            end
        end
    else
        if not addon.db.profile.buffReminderSoundConfig then
            addon.db.profile.buffReminderSoundConfig = {}
        end
        if not addon.db.profile.buffReminderSoundConfig[specKey] then
            addon.db.profile.buffReminderSoundConfig[specKey] = {}
        end
        addon.db.profile.buffReminderSoundConfig[specKey][spellID] = soundName
    end
end

-------------------------------------------------------------------------------
-- Spell Config Helpers (continued)
-------------------------------------------------------------------------------

-- Check if a spell has any overrides (for showing "modified" indicator)
function Database:IsSpellConfigModified(spellID, specKey)
    specKey = specKey or self:GetSpecKey()
    local spellConfig = addon.db and addon.db.profile and addon.db.profile.spellConfig
    if spellConfig and spellConfig[specKey] and spellConfig[specKey][spellID] then
        local cfg = spellConfig[specKey][spellID]
        return cfg.enabled ~= nil or cfg.rowIndex ~= nil or cfg.order ~= nil or cfg.druidForm ~= nil
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
-- Aura Tracker Key Migration (pre-AceDB, idempotent)
-------------------------------------------------------------------------------

-- Flatten per-spec procConfig into profile-wide auraConfig.
-- Old format: procConfig[specKey][spellID] = true/false
-- New format: auraConfig[spellID] = true/false
-- Conflicts (different values across specs) -> keep the most permissive (true).
local function FlattenProcConfig(procConfig)
    if type(procConfig) ~= "table" then return {} end

    local flat = {}
    for specKey, spells in pairs(procConfig) do
        if type(spells) == "table" then
            for spellID, value in pairs(spells) do
                if flat[spellID] == nil or value == true then
                    flat[spellID] = value
                end
            end
        end
    end

    if next(flat) == nil then return nil end
    return flat
end

local function MigrateAuraTrackerProfile(profile)
    -- 1. procTracker -> auraTracker
    if profile.procTracker and not profile.auraTracker then
        profile.auraTracker = profile.procTracker
        profile.procTracker = nil
    elseif profile.procTracker then
        profile.procTracker = nil
    end

    -- 2. procConfig -> auraConfig (flatten per-spec -> profile-wide)
    if profile.procConfig then
        if not profile.auraConfig then
            profile.auraConfig = FlattenProcConfig(profile.procConfig)
        end
        profile.procConfig = nil
    end

    -- 3. layout.elementOrder: "procTracker" -> "auraTracker"
    local layout = profile.layout
    if layout and layout.elementOrder then
        for i, key in ipairs(layout.elementOrder) do
            if key == "procTracker" then
                layout.elementOrder[i] = "auraTracker"
            end
        end
    end

    -- 4. layout.gaps.procTracker -> layout.gaps.auraTracker
    if layout and layout.gaps and layout.gaps.procTracker ~= nil then
        if layout.gaps.auraTracker == nil then
            layout.gaps.auraTracker = layout.gaps.procTracker
        end
        layout.gaps.procTracker = nil
    end
end

-- Operates on the raw VeevHUDDB table before AceDB wraps it.
-- Idempotent: safe to call even if already migrated or on a fresh DB.
function Database:MigrateAuraTrackerKeys()
    local db = VeevHUDDB
    if not db or type(db) ~= "table" then return end

    local profiles = db.profiles
    if not profiles or type(profiles) ~= "table" then return end

    for _, profileData in pairs(profiles) do
        if type(profileData) == "table" then
            MigrateAuraTrackerProfile(profileData)
        end
    end
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
    -- Note: legacy.migrationsShown intentionally not carried over.
    -- The old per-key popup system was replaced by dataVersion in Migrations.lua.

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

-------------------------------------------------------------------------------
-- Shared Cooldown Override Helpers
-------------------------------------------------------------------------------

function Database:GetSharedCooldownOverride(groupName, specKey)
    specKey = specKey or self:GetSpecKey()
    local overrides = addon.db and addon.db.profile and addon.db.profile.sharedCooldownOverrides
    if overrides and overrides[specKey] then
        return overrides[specKey][groupName]
    end
    return nil
end

-- Resolve the display spell for a shared cooldown group.
-- Returns overrideSpellID, overrideData if an override exists and is valid.
-- Returns nil, nil if no override or spellID is already the active override.
-- Cleans up stale overrides (spell removed from LibSpellDB).
function Database:ResolveSharedCooldownOverride(spellID)
    if not addon.LibSpellDB then return nil, nil end
    local groupName = addon.LibSpellDB:GetSharedCooldownGroup(spellID)
    if not groupName then return nil, nil end
    local overrideID = self:GetSharedCooldownOverride(groupName)
    if not overrideID or overrideID == spellID then return nil, nil end
    local overrideData = addon.LibSpellDB:GetSpellInfo(overrideID)
    if overrideData then
        return overrideID, overrideData
    end
    -- Stale override — clean up
    self:SetSharedCooldownOverride(groupName, nil)
    return nil, nil
end

-- Sparse with nil-cleanup (mirrors SetSpellConfigOverride pattern)
function Database:SetSharedCooldownOverride(groupName, spellID, specKey)
    specKey = specKey or self:GetSpecKey()

    if not addon.db or not addon.db.profile then return end

    addon.db.profile.sharedCooldownOverrides = addon.db.profile.sharedCooldownOverrides or {}
    addon.db.profile.sharedCooldownOverrides[specKey] = addon.db.profile.sharedCooldownOverrides[specKey] or {}

    if spellID == nil then
        addon.db.profile.sharedCooldownOverrides[specKey][groupName] = nil
        if next(addon.db.profile.sharedCooldownOverrides[specKey]) == nil then
            addon.db.profile.sharedCooldownOverrides[specKey] = nil
        end
        if next(addon.db.profile.sharedCooldownOverrides) == nil then
            addon.db.profile.sharedCooldownOverrides = nil
        end
    else
        addon.db.profile.sharedCooldownOverrides[specKey][groupName] = spellID
    end
end

function Database:ResetProfile()
    if addon.db and addon.db.ResetProfile then
        addon.db:ResetProfile()
    end

    addon.Utils:Print("Profile reset to defaults.")
end
