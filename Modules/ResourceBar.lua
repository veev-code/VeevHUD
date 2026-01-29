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

-- Get the Y offset needed to account for combo point space
-- Returns 0 if combo points not used/visible
function ResourceBar:GetComboPointLift()
    local comboPoints = addon:GetModule("ComboPoints")
    if comboPoints and comboPoints.GetTotalHeight then
        return comboPoints:GetTotalHeight()
    end
    return 0
end

function ResourceBar:CreateFrames(parent)
    local db = addon.db.profile.resourceBar

    if not db.enabled then return end

    -- Calculate Y offset - resource bar moves UP when combo points are present
    -- Combo points fill the space between resource bar and primary row (icons)
    local comboPointLift = self:GetComboPointLift()
    local barY = comboPointLift

    -- Main bar frame (resource bar is anchor at Y=0, lifted when combo points present)
    local bar = self.Utils:CreateStatusBar(parent, db.width, db.height)
    bar:SetPoint("CENTER", parent, "CENTER", 0, barY)
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
    text:SetFont(self.C.FONTS.NUMBER, db.textSize or 11, "OUTLINE")
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
    self.border = self.Utils:CreateBarBorder(bar)
end

function ResourceBar:CreateGradient(bar)
    self.gradient = self.Utils:CreateBarGradient(bar)
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
    self.text:SetText(self.Utils:FormatBarText(power, maxPower, percent, format))
end

function ResourceBar:SmoothUpdate()
    if not self.bar or not self.targetValue then return end
    
    -- Check if smoothing is still enabled (user may have disabled it)
    local animDb = addon.db.profile.animations or {}
    if not animDb.smoothBars then return end

    self.currentValue = self.Utils:SmoothBarValue(self.currentValue, self.targetValue)
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
        
        -- Resource bar moves UP when combo points are present
        local comboPointLift = self:GetComboPointLift()
        self.bar:ClearAllPoints()
        self.bar:SetPoint("CENTER", self.bar:GetParent(), "CENTER", 0, comboPointLift)
        
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
        
        -- Toggle text visibility and update font size
        if self.text then
            self.text:SetFont(self.C.FONTS.NUMBER, db.textSize or 11, "OUTLINE")
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
