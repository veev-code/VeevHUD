--[[
    VeevHUD - Resource Bar Module
    Displays player resource (mana/rage/energy) bar
]]

local ADDON_NAME, addon = ...

local ResourceBar = {}
addon:RegisterModule("ResourceBar", ResourceBar)

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function ResourceBar:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants

    -- Register events
    self.Events:RegisterEvent(self, "UNIT_POWER_UPDATE", self.OnPowerUpdate)
    self.Events:RegisterEvent(self, "UNIT_MAXPOWER", self.OnPowerUpdate)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)
    self.Events:RegisterEvent(self, "UPDATE_SHAPESHIFT_FORM", self.OnShapeshiftChange)

    self.Utils:Debug("ResourceBar initialized")
end

function ResourceBar:OnPlayerEnteringWorld()
    self:UpdatePowerType()
    self:UpdateBar()
end

function ResourceBar:OnPowerUpdate(event, unit, powerType)
    if unit == "player" then
        self:UpdateBar()
    end
end

function ResourceBar:OnShapeshiftChange()
    self:UpdatePowerType()
    self:UpdateBar()
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function ResourceBar:CreateFrames(parent)
    local db = addon.db.profile.resourceBar

    if not db.enabled then return end

    -- Main bar frame
    local bar = self.Utils:CreateStatusBar(parent, db.width, db.height)
    bar:SetPoint("CENTER", parent, "CENTER", 0, db.offsetY)
    self.bar = bar

    -- Border/backdrop
    self:CreateBorder(bar)

    -- Text overlay
    local text = bar:CreateFontString(nil, "OVERLAY")
    text:SetFont(self.C.FONTS.NUMBER, 11, "OUTLINE")
    text:SetPoint("CENTER")
    self.text = text

    -- Initialize
    self:UpdatePowerType()
    self:UpdateBar()

    -- Register for smooth updates
    if db.smoothing then
        self.Events:RegisterUpdate(self, 0.02, self.SmoothUpdate)
        self.targetValue = 1
        self.currentValue = 1
    end
end

function ResourceBar:CreateBorder(bar)
    -- Clean dark border with slight padding
    local border = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    border:SetBackdropBorderColor(0, 0, 0, 1)
    border:SetFrameLevel(bar:GetFrameLevel() - 1)

    -- Outer glow/shadow for depth
    local shadow = CreateFrame("Frame", nil, border, "BackdropTemplate")
    shadow:SetPoint("TOPLEFT", -1, 1)
    shadow:SetPoint("BOTTOMRIGHT", 1, -1)
    shadow:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    shadow:SetBackdropBorderColor(0, 0, 0, 0.5)
    shadow:SetFrameLevel(border:GetFrameLevel() - 1)

    self.border = border
end

-------------------------------------------------------------------------------
-- Updates
-------------------------------------------------------------------------------

function ResourceBar:UpdatePowerType()
    self.powerType = UnitPowerType("player")

    -- Update bar color
    if self.bar then
        local db = addon.db.profile.resourceBar
        local r, g, b

        if db.classColored then
            r, g, b = self.Utils:GetClassColor(addon.playerClass)
        else
            r, g, b = self.Utils:GetPowerColor(self.powerType)
        end

        self.bar:SetStatusBarColor(r, g, b)
        self.bar.bg:SetVertexColor(r * 0.2, g * 0.2, b * 0.2)

        -- Store colors for gradient
        self.barColor = {r = r, g = g, b = b}
    end
end

function ResourceBar:UpdateBar()
    if not self.bar then return end

    local power = UnitPower("player", self.powerType)
    local maxPower = UnitPowerMax("player", self.powerType)

    if maxPower == 0 then
        maxPower = 1
    end

    local percent = power / maxPower

    local db = addon.db.profile.resourceBar

    if db.smoothing then
        self.targetValue = percent
    else
        self.bar:SetValue(percent)
    end

    -- Update text
    if self.text and db.showText then
        self:UpdateText(power, maxPower, percent, db.textFormat)
    elseif self.text then
        self.text:SetText("")
    end
end

function ResourceBar:UpdateText(power, maxPower, percent, format)
    local text

    if format == "current" then
        text = self.Utils:FormatNumber(power)
    elseif format == "percent" then
        text = string.format("%d%%", percent * 100)
    elseif format == "both" then
        text = string.format("%s (%d%%)", self.Utils:FormatNumber(power), percent * 100)
    elseif format == "full" then
        text = string.format("%s / %s", self.Utils:FormatNumber(power), self.Utils:FormatNumber(maxPower))
    else
        text = ""
    end

    self.text:SetText(text)
end

function ResourceBar:SmoothUpdate()
    if not self.bar or not self.targetValue then return end

    local diff = self.targetValue - self.currentValue
    if math.abs(diff) < 0.001 then
        self.currentValue = self.targetValue
    else
        self.currentValue = self.currentValue + diff * 0.3
    end

    self.bar:SetValue(self.currentValue)
end

-------------------------------------------------------------------------------
-- Enable/Disable
-------------------------------------------------------------------------------

function ResourceBar:Enable()
    if self.bar then
        self.bar:Show()
    end
end

function ResourceBar:Disable()
    if self.bar then
        self.bar:Hide()
    end
end

function ResourceBar:Refresh()
    self:UpdatePowerType()
    self:UpdateBar()
end
