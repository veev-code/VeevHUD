--[[
    VeevHUD - Welcome Popup
    Shows a one-time welcome dialog on first load with Discord link
]]

local ADDON_NAME, addon = ...
local C = addon.Constants

addon.WelcomePopup = {}
local WelcomePopup = addon.WelcomePopup

-------------------------------------------------------------------------------
-- Dialog Creation
-------------------------------------------------------------------------------

function WelcomePopup:CreateDialog()
    if self.dialog then return self.dialog end
    
    local dialog = CreateFrame("Frame", "VeevHUDWelcomeDialog", UIParent, "BasicFrameTemplateWithInset")
    dialog:SetSize(400, 240)
    -- Position ~30% down from top (instead of center) to avoid hiding the HUD
    dialog:SetPoint("CENTER", UIParent, "CENTER", 0, UIParent:GetHeight() * 0.20)
    dialog:SetFrameStrata("DIALOG")
    dialog:SetMovable(true)
    dialog:EnableMouse(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
    dialog:Hide()
    
    -- Title (centered in the title bar area)
    local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -6)
    title:SetText("|cff00ccffVeevHUD|r")
    
    -- Message text
    local message = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    message:SetPoint("TOP", title, "BOTTOM", 0, -12)
    message:SetWidth(360)
    message:SetJustifyH("CENTER")
    message:SetText("Thanks for trying VeevHUD!\n\n" ..
                   "Type |cff00ff00/vh|r to open settings.\n\n" ..
                   "This addon is under active development.\n" ..
                   "Your feedback helps shape its future.\n\n" ..
                   "Join the |cffffffffVeev Addons Discord|r for suggestions,\n" ..
                   "bug reports, and updates:")
    
    -- URL edit box (for copy/paste)
    local editBox = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
    editBox:SetSize(300, 20)
    editBox:SetPoint("TOP", message, "BOTTOM", 0, -12)
    editBox:SetAutoFocus(false)
    editBox:SetText(C.DISCORD_URL)
    editBox:SetScript("OnEditFocusGained", function(self)
        self:HighlightText()
    end)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    editBox:SetScript("OnTextChanged", function(self)
        -- Prevent editing - always reset to the URL
        self:SetText(C.DISCORD_URL)
        self:HighlightText()
    end)
    
    -- Instructions
    local instructions = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    instructions:SetPoint("TOP", editBox, "BOTTOM", 0, -4)
    instructions:SetText("|cff888888Click the link above, then Ctrl+C to copy|r")
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
    closeBtn:SetSize(120, 24)
    closeBtn:SetPoint("BOTTOM", 0, 12)
    closeBtn:SetText("Got it!")
    closeBtn:SetScript("OnClick", function()
        VeevHUDDB.welcomeShown = true
        dialog:Hide()
    end)
    
    -- Also mark as shown when closing via X button
    dialog:SetScript("OnHide", function()
        VeevHUDDB.welcomeShown = true
    end)
    
    self.dialog = dialog
    return dialog
end

-------------------------------------------------------------------------------
-- Show Logic
-------------------------------------------------------------------------------

function WelcomePopup:Show()
    if not VeevHUDDB.welcomeShown then
        -- Delay slightly to ensure UI is fully loaded
        C_Timer.After(1, function()
            local dialog = self:CreateDialog()
            dialog:Show()
            -- Auto-select the URL for easy copying
            for i = 1, dialog:GetNumChildren() do
                local child = select(i, dialog:GetChildren())
                if child:IsObjectType("EditBox") then
                    child:SetFocus()
                    child:HighlightText()
                    break
                end
            end
        end)
    end
end
