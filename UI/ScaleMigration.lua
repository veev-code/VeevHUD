--[[
    VeevHUD - Scale Migration
    
    One-time notice for users affected by the UI scale auto-compensation feature.
    This affects anyone not at 65% UI scale, as VeevHUD was designed at that scale.
]]

local ADDON_NAME, addon = ...
local C = addon.Constants

-------------------------------------------------------------------------------
-- Migration Registration
-------------------------------------------------------------------------------

addon.MigrationManager:Register({
    id = "ui_scale_compensation_v1",
    
    -- Check if user needs to see this migration
    -- Returns: shouldShow, extraData
    check = function()
        local uiScale = UIParent:GetScale()
        local referenceScale = C.REFERENCE_UI_SCALE  -- 0.65
        
        -- Check if user has a scale override
        local overrides = VeevHUDDB.overrides
        local hasScaleOverride = overrides and overrides.icons and overrides.icons.scale
        local userScale = hasScaleOverride and overrides.icons.scale or 1.0
        
        -- If UI scale is close to reference (within 10%), no significant change
        local scaleDifference = math.abs(uiScale - referenceScale)
        if scaleDifference < 0.08 then
            return false
        end
        
        -- Anyone at significantly different UI scale will see a change
        return true, {
            uiScale = uiScale,
            userScale = userScale,
            hasOverride = hasScaleOverride,
        }
    end,
    
    title = "Scaling Update",
    
    getMessage = function(data)
        if data.hasOverride and data.userScale < 1.0 then
            -- User had manually scaled down - now it's compounding!
            local effectivePercent = math.floor(data.userScale * (C.REFERENCE_UI_SCALE / data.uiScale) * 100 + 0.5)
            return "VeevHUD now |cff00ff00automatically adjusts|r for your UI scale.\n\n" ..
                   "You previously set Global Scale below 100%, likely to\n" ..
                   "compensate for your high UI scale. With auto-compensation,\n" ..
                   "this now |cffff6666stacks|r — your HUD is |cffff6666" .. effectivePercent .. "%|r of intended size!\n\n" ..
                   "Open settings (|cff00ff00/vh|r) to reset Global Scale to 100%."
        else
            -- User at high UI scale with default settings - HUD is now smaller
            return "VeevHUD now |cff00ff00automatically adjusts|r for your UI scale.\n\n" ..
                   "Since you use a higher UI scale, the HUD will now appear\n" ..
                   "|cffffcc00smaller|r than before (to match how it was designed).\n\n" ..
                   "If you preferred the larger size, increase |cffffcc00Global Scale|r\n" ..
                   "in the settings (|cff00ff00/vh|r)."
        end
    end,
    
    getExtraInfo = function(data)
        local uiPercent = math.floor(data.uiScale * 100 + 0.5)
        if data.hasOverride then
            local scalePercent = math.floor(data.userScale * 100 + 0.5)
            return string.format("Your UI Scale: |cffffcc00%d%%|r  •  Global Scale: |cffffcc00%d%%|r", uiPercent, scalePercent)
        else
            return string.format("Your UI Scale: |cffffcc00%d%%|r", uiPercent)
        end
    end,
    
    buttons = {
        {
            text = "Got it",
            action = nil  -- Just dismiss
        }
    }
})
