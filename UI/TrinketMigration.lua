--[[
    VeevHUD - Trinket Tracking Migration Notice

    Informs existing users about the new Trinket Tracking feature.
]]

local ADDON_NAME, addon = ...

addon.MigrationManager:Register({
    id = "trinket_tracking_v1",
    check = function()
        -- Show to all existing users (MigrationManager already skips fresh installs)
        return true
    end,
    title = "New Feature: Trinket Tracking",
    message = "VeevHUD now tracks your |cff00ff00equipped trinkets|r!\n\n"
        .. "Trinkets with on-use or proc effects automatically appear "
        .. "in your ability rows.\n\n"
        .. "|cffffffffOn-Use Trinkets|r — Shows the active buff with duration, "
        .. "then the cooldown spiral until ready again.\n\n"
        .. "|cffffffffProc Trinkets|r — Glows when the proc is active with "
        .. "duration text, then shows time until it can proc again.\n\n"
        .. "Trinkets appear in the |cffffffffSecondary|r row by default. "
        .. "You can move or disable them in the |cffffffffSpells|r config.",
    buttons = {
        {
            text = "Open Spells Config",
            action = function()
                C_Timer.After(0.1, function()
                    local spellsOptions = addon:GetModule("SpellsOptions")
                    if spellsOptions and spellsOptions.Open then
                        spellsOptions:Open()
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
