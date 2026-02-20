--[[
    VeevHUD - Buff Reminders Migration Notices

    1. buff_reminders_v1: Informs existing users about the new Buff Reminders feature.
    2. buff_reminders_per_spec_v1: Migrates flat spellConfig to per-spec format
       across ALL profiles proactively.
]]

local ADDON_NAME, addon = ...

-------------------------------------------------------------------------------
-- Migration 1: New Feature Announcement
-------------------------------------------------------------------------------

addon.MigrationManager:Register({
    id = "buff_reminders_v1",
    check = function()
        -- Show to all existing users (MigrationManager already skips fresh installs)
        return true
    end,
    title = "New Feature: Buff Reminders",
    message = "VeevHUD now includes |cff00ff00Buff Reminders|r!\n\n"
        .. "This feature shows reminder icons when long-duration buffs are missing "
        .. "or about to expire — like Inner Fire, Battle Shout, Mark of the Wild, "
        .. "and more.\n\n"
        .. "Reminders are shown only when the spell is known, usable, and you're not "
        .. "resting or mounted. Each buff can be individually configured or disabled.\n\n"
        .. "You can customize or disable this feature in the |cffffffffBuff Reminders|r tab "
        .. "of the VeevHUD settings.",
    buttons = {
        {
            text = "Open Settings",
            action = function()
                -- Open VeevHUD options to the Buff Reminders tab
                C_Timer.After(0.1, function()
                    local options = addon:GetModule("Options")
                    if options then
                        options:Open()
                        -- Select the Buff Reminders tab after opening
                        local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
                        if AceConfigDialog then
                            AceConfigDialog:SelectGroup(ADDON_NAME, "buffReminders")
                        end
                    end
                end)
            end,
        },
        {
            text = "Got It",
            action = nil,  -- Just dismiss
        },
    },
})

-------------------------------------------------------------------------------
-- Migration 2: Flat spellConfig → Per-Spec Format
-------------------------------------------------------------------------------

--[[
    Old format: buffReminders.spellConfig[spellID] = { enabled, ... }
    New format: buffReminders.spellConfig[specKey][spellID] = { enabled, ... }

    Proactively migrates ALL profiles in the SavedVariable. Flat numeric keys
    are moved under the current character's specKey. For profiles belonging to
    other characters, this is a best-effort migration — the entries are filed
    under the current specKey. If the profile is later used by a different
    class/spec, those entries simply won't match and will be ignored (the
    defaults system handles the common case).
]]

-- Scan a single profile's buffReminders.spellConfig for flat numeric keys.
-- Returns a table of {[spellID] = config} entries, or nil if none found.
local function findFlatEntries(profileData)
    local br = profileData and profileData.buffReminders
    if not br or not br.spellConfig then return nil end

    local entries = {}
    local found = false
    for k, v in pairs(br.spellConfig) do
        if type(k) == "number" then
            entries[k] = v
            found = true
        end
    end
    return found and entries or nil
end

-- Migrate flat entries in a profile's spellConfig under the given specKey.
local function migrateProfile(profileData, specKey)
    local entries = findFlatEntries(profileData)
    if not entries then return false end

    local sc = profileData.buffReminders.spellConfig
    if not sc[specKey] then sc[specKey] = {} end
    for spellID, config in pairs(entries) do
        sc[specKey][spellID] = config
        sc[spellID] = nil
    end
    return true
end

addon.MigrationManager:Register({
    id = "buff_reminders_per_spec_v1",
    silent = true,
    check = function()
        -- Need a specKey to file entries under
        local specKey = addon.Database:GetSpecKey()
        if not specKey then return false end

        local profiles = VeevHUDDB and VeevHUDDB.profiles
        if not profiles then return false end

        local migrated = false
        for profileName, profileData in pairs(profiles) do
            if migrateProfile(profileData, specKey) then
                addon.Utils:LogInfo("Migration: Migrated buffReminders.spellConfig to per-spec in profile '" .. profileName .. "' (" .. specKey .. ")")
                migrated = true
            end
        end

        return migrated
    end,
})
