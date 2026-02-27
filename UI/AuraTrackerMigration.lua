--[[
    VeevHUD - Aura Tracker Migration

    Handles the rename of "Proc Tracker" → "Aura Tracker":
      1. Early key migration (runs before AceDB:New in Database:Initialize):
         - profile.procTracker → profile.auraTracker
         - profile.procConfig  → profile.auraConfig
         - layout.elementOrder: "procTracker" → "auraTracker"
         - layout.gaps.procTracker → layout.gaps.auraTracker
      2. User-facing popup explaining the change (MigrationManager).
      3. Silent migration to flatten per-spec procConfig → profile-wide auraConfig.
]]

local ADDON_NAME, addon = ...

addon.AuraTrackerMigration = {}
local Migration = addon.AuraTrackerMigration

-------------------------------------------------------------------------------
-- Early Key Migration (called from Database:Initialize before AceDB:New)
-------------------------------------------------------------------------------
-- Operates on the raw VeevHUDDB saved-variable table, not on AceDB proxies.
-- Must be idempotent: safe to call even if already migrated or on a fresh DB.

function Migration:MigrateRawKeys()
    local db = VeevHUDDB
    if not db or type(db) ~= "table" then return end

    local profiles = db.profiles
    if not profiles or type(profiles) ~= "table" then return end

    for profileName, profileData in pairs(profiles) do
        if type(profileData) == "table" then
            self:MigrateProfile(profileData)
        end
    end
end

function Migration:MigrateProfile(profile)
    -- 1. procTracker → auraTracker
    if profile.procTracker and not profile.auraTracker then
        profile.auraTracker = profile.procTracker
        profile.procTracker = nil
    elseif profile.procTracker then
        -- Both exist (shouldn't happen, but be safe) — keep auraTracker, discard old
        profile.procTracker = nil
    end

    -- 2. procConfig → auraConfig (flatten per-spec → profile-wide)
    if profile.procConfig then
        if not profile.auraConfig then
            profile.auraConfig = self:FlattenProcConfig(profile.procConfig)
        end
        profile.procConfig = nil
    end

    -- 3. layout.elementOrder: "procTracker" → "auraTracker"
    local layout = profile.layout
    if layout and layout.elementOrder then
        for i, key in ipairs(layout.elementOrder) do
            if key == "procTracker" then
                layout.elementOrder[i] = "auraTracker"
            end
        end
    end

    -- 4. layout.gaps.procTracker → layout.gaps.auraTracker
    if layout and layout.gaps and layout.gaps.procTracker ~= nil then
        if layout.gaps.auraTracker == nil then
            layout.gaps.auraTracker = layout.gaps.procTracker
        end
        layout.gaps.procTracker = nil
    end
end

-- Flatten per-spec procConfig into profile-wide auraConfig.
-- Old format: procConfig[specKey][spellID] = true/false
-- New format: auraConfig[spellID] = true/false
-- Conflicts (different values across specs) → keep the most permissive (true).
function Migration:FlattenProcConfig(procConfig)
    if type(procConfig) ~= "table" then return {} end

    local flat = {}
    for specKey, spells in pairs(procConfig) do
        if type(spells) == "table" then
            for spellID, value in pairs(spells) do
                -- If any spec had it enabled, keep it enabled
                if flat[spellID] == nil or value == true then
                    flat[spellID] = value
                end
            end
        end
    end

    -- Return nil-equivalent empty table if nothing was overridden
    if next(flat) == nil then return nil end
    return flat
end

-------------------------------------------------------------------------------
-- User-Facing Migration Popup (runs via MigrationManager, ~2s after login)
-------------------------------------------------------------------------------

addon.MigrationManager:Register({
    id = "aura_tracker_v1",
    check = function()
        -- Show for all existing users (MigrationManager already skips fresh installs)
        return true
    end,
    title = "Aura Tracker",
    message = "The |cff00ff00Proc Tracker|r has been upgraded to the |cff00ff00Aura Tracker|r!\n\n"
        .. "What's new:\n"
        .. "|cffffffffExternal Buffs|r — Tracks important buffs from other players: "
        .. "Bloodlust, Power Infusion, Innervate, Drums, and more.\n\n"
        .. "|cffffffffCustom Auras|r — Add your own auras by spell ID or name.\n\n"
        .. "All your existing proc settings have been preserved.\n\n"
        .. "|cff888888Note: Some self-activated CDs were removed (already on ability rows). "
        .. "Re-add them as custom auras if needed.|r",
    buttons = {
        {
            text = "Open Settings",
            action = function()
                C_Timer.After(0.1, function()
                    local options = addon:GetModule("Options")
                    if options then
                        options:Open()
                        local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
                        if AceConfigDialog then
                            AceConfigDialog:SelectGroup(ADDON_NAME, "procs")
                        end
                    end
                end)
            end,
        },
        {
            text = "Got It",
            action = nil,
        },
    },
})
