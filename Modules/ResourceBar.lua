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

    -- Main bar frame (resource bar is anchor at Y=0)
    local bar = self.Utils:CreateStatusBar(parent, db.width, db.height)
    bar:SetPoint("CENTER", parent, "CENTER", 0, 0)
    self.bar = bar

    -- Border/backdrop
    self:CreateBorder(bar)

    -- Gradient overlay (darker at bottom, lighter at top)
    if db.showGradient ~= false then
        self:CreateGradient(bar)
    end

    -- Spark texture (glowing line at fill position)
    self:CreateSpark(bar, db)

    -- Text overlay
    local text = bar:CreateFontString(nil, "OVERLAY")
    text:SetFont(self.C.FONTS.NUMBER, 11, "OUTLINE")
    text:SetPoint("CENTER")
    self.text = text

    -- Initialize
    self:UpdatePowerType()
    self:UpdateBar()

    -- Register for smooth updates (uses global animation setting)
    local animDb = addon.db.profile.animations or {}
    if animDb.smoothBars then
        self.Events:RegisterUpdate(self, 0.02, self.SmoothUpdate)
        self.targetValue = 1
        self.currentValue = 1
    end
end

function ResourceBar:CreateSpark(bar, db)
    if db.showSpark == false then return end
    
    local spark = bar:CreateTexture(nil, "OVERLAY")
    
    -- Use the casting bar spark texture (available in all WoW versions)
    spark:SetTexture([[Interface\CastingBar\UI-CastingBar-Spark]])
    spark:SetBlendMode("ADD")
    spark:SetSize(db.sparkWidth or 12, db.height + (db.sparkOverflow or 8))
    spark:SetPoint("CENTER", bar, "LEFT", 0, 0)
    spark:SetAlpha(0.9)
    
    self.spark = spark
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

function ResourceBar:CreateGradient(bar)
    -- Gradient overlay: darker on left, lighter on right
    local gradient = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    gradient:SetAllPoints(bar:GetStatusBarTexture())
    gradient:SetTexture([[Interface\Buttons\WHITE8X8]])
    
    -- Horizontal gradient: left is darker, right is lighter
    gradient:SetGradient("HORIZONTAL", 
        CreateColor(0, 0, 0, 0.35),  -- Left (darker)
        CreateColor(1, 1, 1, 0.15)   -- Right (lighter/highlight)
    )
    
    self.gradient = gradient
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

    local animDb = addon.db.profile.animations or {}
    if animDb.smoothBars then
        self.targetValue = percent
    else
        self.bar:SetValue(percent)
        self:UpdateSpark(percent)
    end

    -- Update text
    if self.text and db.showText then
        self:UpdateText(power, maxPower, percent, db.textFormat)
    elseif self.text then
        self.text:SetText("")
    end
end

function ResourceBar:UpdateSpark(percent)
    if not self.spark then return end
    
    local db = addon.db.profile.resourceBar
    
    -- Respect showSpark setting
    if db.showSpark == false then
        self.spark:Hide()
        return
    end
    
    -- Hide spark when full or empty
    if db.sparkHideFullEmpty ~= false then
        if percent <= 0 or percent >= 1 then
            self.spark:Hide()
            return
        else
            self.spark:Show()
        end
    end
    
    -- Position spark at the fill edge
    local barWidth = self.bar:GetWidth()
    local sparkX = barWidth * percent
    self.spark:SetPoint("CENTER", self.bar, "LEFT", sparkX, 0)
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
    
    -- Check if smoothing is still enabled (user may have disabled it)
    local animDb = addon.db.profile.animations or {}
    if not animDb.smoothBars then return end

    local diff = self.targetValue - self.currentValue
    if math.abs(diff) < 0.001 then
        self.currentValue = self.targetValue
    else
        self.currentValue = self.currentValue + diff * 0.3
    end

    self.bar:SetValue(self.currentValue)
    self:UpdateSpark(self.currentValue)
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
    -- Re-apply config settings to existing frames
    local db = addon.db.profile.resourceBar
    
    if self.bar then
        -- Update size
        self.bar:SetSize(db.width, db.height)
        
        -- Resource bar is the anchor at Y=0
        self.bar:ClearAllPoints()
        self.bar:SetPoint("CENTER", self.bar:GetParent(), "CENTER", 0, 0)
        
        -- Update spark visibility and size
        if db.showSpark == false then
            -- Hide spark if disabled
            if self.spark then
                self.spark:Hide()
            end
        else
            -- Show/create spark if enabled
            if not self.spark then
                self:CreateSpark(self.bar, db)
            end
            if self.spark then
                self.spark:SetSize(db.sparkWidth or 12, db.height + (db.sparkOverflow or 8))
                self.spark:Show()
            end
        end
        
        -- Toggle visibility based on enabled
        if db.enabled then
            self.bar:Show()
        else
            self.bar:Hide()
        end
        
        -- Toggle text visibility
        if self.text then
            if db.showText then
                self.text:Show()
            else
                self.text:Hide()
            end
        end
    end
    
    self:UpdatePowerType()
    self:UpdateBar()
end
