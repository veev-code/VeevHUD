--[[
    VeevHUD - Anchor/Positioning UI
    Shows visual anchor when HUD is unlocked
]]

local ADDON_NAME, addon = ...

addon.Anchor = {}
local Anchor = addon.Anchor

-------------------------------------------------------------------------------
-- Anchor Frame
-------------------------------------------------------------------------------

function Anchor:Create(parent)
    if self.frame then return end

    local frame = CreateFrame("Frame", "VeevHUDAnchor", parent)
    frame:SetSize(200, 30)
    frame:SetPoint("CENTER", parent, "CENTER", 0, 50)
    frame:Hide()

    -- Background
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.7)

    -- Text
    local text = frame:CreateFontString(nil, "OVERLAY")
    text:SetFont(addon.Constants.FONTS.DEFAULT, 12, "OUTLINE")
    text:SetPoint("CENTER")
    text:SetText("|cff00ccffVeevHUD|r - Drag to move")
    frame.text = text

    -- Border
    local border = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", 2, -2)
    border:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
    })
    border:SetBackdropBorderColor(0, 0.8, 1, 1)

    self.frame = frame
    return frame
end

function Anchor:Show()
    if self.frame then
        self.frame:Show()
    end
end

function Anchor:Hide()
    if self.frame then
        self.frame:Hide()
    end
end

function Anchor:Toggle()
    if self.frame then
        if self.frame:IsShown() then
            self:Hide()
        else
            self:Show()
        end
    end
end
