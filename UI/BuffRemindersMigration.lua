--[[
    VeevHUD - Buff Reminders Migration Notice
    
    Shows a one-time popup to existing users informing them about the new
    Buff Reminders feature and how to configure or disable it.
]]

local ADDON_NAME, addon = ...

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
