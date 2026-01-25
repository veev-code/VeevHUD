--[[
    VeevHUD - Options Panel
    Configuration UI (placeholder for future AceConfig integration)
]]

local ADDON_NAME, addon = ...

addon.Options = {}
local Options = addon.Options

-------------------------------------------------------------------------------
-- Simple Options (will be expanded with AceConfig later)
-------------------------------------------------------------------------------

function Options:Initialize()
    -- Create options table for AceConfig (future)
    self.optionsTable = {
        type = "group",
        name = "VeevHUD",
        args = {
            general = {
                type = "group",
                name = "General",
                order = 1,
                args = {
                    enabled = {
                        type = "toggle",
                        name = "Enable",
                        desc = "Enable or disable VeevHUD",
                        order = 1,
                        get = function() return addon.db.profile.enabled end,
                        set = function(_, val)
                            addon.db.profile.enabled = val
                        end,
                    },
                    locked = {
                        type = "toggle",
                        name = "Lock Position",
                        desc = "Lock the HUD position",
                        order = 2,
                        get = function() return addon.db.profile.locked end,
                        set = function(_, val)
                            addon.db.profile.locked = val
                        end,
                    },
                },
            },
            visibility = {
                type = "group",
                name = "Visibility",
                order = 2,
                args = {
                    hideOnFlightPath = {
                        type = "toggle",
                        name = "Hide on Flight Path",
                        desc = "Hide the HUD completely when on a flight path",
                        order = 1,
                        get = function() return addon.db.profile.visibility.hideOnFlightPath end,
                        set = function(_, val)
                            addon.db.profile.visibility.hideOnFlightPath = val
                        end,
                    },
                },
            },
        },
    }
end

function Options:Open()
    -- Will integrate with AceConfigDialog or create custom panel
    addon.Utils:Print("Configuration panel coming soon!")
    addon.Utils:Print("Use these commands for now:")
    print("  /vh lock - Toggle lock/unlock")
    print("  /vh reset - Reset to defaults")
    print("  /vh toggle - Enable/disable")
end
