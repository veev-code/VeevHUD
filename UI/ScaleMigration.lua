--[[
    VeevHUD - Scale Migration
    
    One-time notice for users who may have manually adjusted Global Scale
    to compensate for using 100% UI scale (before auto-compensation was added).
]]

local ADDON_NAME, addon = ...

-------------------------------------------------------------------------------
-- Migration Registration
-------------------------------------------------------------------------------

addon.MigrationManager:Register({
    id = "ui_scale_compensation_v1",
    
    -- Check if user needs to see this migration
    -- Returns: shouldShow, extraData
    check = function()
        -- Check if user has a scale override
        local overrides = VeevHUDDB.overrides
        if not overrides or not overrides.icons or not overrides.icons.scale then
            return false
        end
        
        local userScale = overrides.icons.scale
        
        -- Only warn if they had scaled DOWN (below 100%)
        if userScale >= 1.0 then
            return false
        end
        
        -- Check if they're at high UI scale (where manual compensation would've been needed)
        local uiScale = UIParent:GetScale()
        if uiScale < 0.8 then
            -- They're at low UI scale, so their manual adjustment was likely intentional
            return false
        end
        
        -- User had scaled down + is at high UI scale = likely needs migration notice
        return true, { userScale = userScale }
    end,
    
    title = "Scaling Update",
    
    message = "VeevHUD now |cff00ff00automatically adjusts|r for your UI scale,\n" ..
              "so the HUD looks the same size regardless of your\n" ..
              "in-game UI Scale setting.\n\n" ..
              "You previously set |cffffcc00Global Scale|r below 100%.\n" ..
              "If you did this to compensate for using a high UI scale,\n" ..
              "you may want to reset it to 100% now.\n\n" ..
              "If you intentionally wanted a smaller HUD, keep your setting.",
    
    getExtraInfo = function(data)
        local scalePercent = math.floor((data.userScale or 0.65) * 100 + 0.5)
        return string.format("Your current Global Scale: |cffffcc00%d%%|r", scalePercent)
    end,
    
    buttons = {
        {
            text = "Reset to 100%",
            action = function(data)
                addon:ClearOverride("icons.scale")
                addon:UpdateHUDScale()
                -- Refresh the slider in Options if it exists
                addon.Options:RefreshWidgetValue("icons.scale")
                addon.Utils:Print("Global Scale reset to 100%.")
            end
        },
        {
            text = "Keep my setting",
            action = nil  -- Just dismiss
        }
    }
})
