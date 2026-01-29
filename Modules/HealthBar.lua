--[[
    VeevHUD - Health Bar Module
    Displays player health bar
]]

local ADDON_NAME, addon = ...

local HealthBar = {}
addon:RegisterModule("HealthBar", HealthBar)

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function HealthBar:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants

    -- Register events
    self.Events:RegisterEvent(self, "UNIT_HEALTH", self.OnHealthUpdate)
    self.Events:RegisterEvent(self, "UNIT_MAXHEALTH", self.OnHealthUpdate)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)

    self.Utils:Debug("HealthBar initialized")
end

function HealthBar:OnPlayerEnteringWorld()
    self:UpdatePlayerBar()
end

function HealthBar:OnHealthUpdate(event, unit)
    if unit == "player" then
        self:UpdatePlayerBar()
    end
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function HealthBar:CreateFrames(parent)
    self:CreatePlayerBar(parent)
end

-- Get the Y offset needed to account for combo point space
-- Returns 0 if combo points not used/visible
function HealthBar:GetComboPointLift()
    local comboPoints = addon:GetModule("ComboPoints")
    if comboPoints and comboPoints.GetTotalHeight then
        return comboPoints:GetTotalHeight()
    end
    return 0
end

function HealthBar:CreatePlayerBar(parent)
    local db = addon.db.profile.healthBar

    if not db.enabled then return end

    -- Calculate position relative to resource bar (health bar is ABOVE resource bar)
    -- If resource bar is disabled, health bar takes its place at Y=0
    -- Also account for combo point lift (everything moves UP when combo points present)
    local resourceDb = addon.db.profile.resourceBar
    local comboPointLift = self:GetComboPointLift()
    local healthBarOffset
    if resourceDb.enabled then
        local resourceBarTop = resourceDb.height / 2
        healthBarOffset = resourceBarTop + db.height / 2 + comboPointLift
    else
        -- Resource bar disabled: health bar takes its place at center (Y=0)
        healthBarOffset = comboPointLift
    end
    
    local bar = self.Utils:CreateStatusBar(parent, db.width, db.height)
    bar:SetPoint("CENTER", parent, "CENTER", 0, healthBarOffset)
    self.playerBar = bar

    -- Border
    self:CreateBorder(bar)

    -- Gradient overlay
    if db.showGradient ~= false then
        self:CreateGradient(bar)
    end

    -- Set bar color (class color or default green)
    local r, g, b
    if db.classColored then
        r, g, b = self.Utils:GetClassColor(addon.playerClass)
    else
        r, g, b = 0.0, 0.8, 0.0  -- Default green for health
    end
    bar:SetStatusBarColor(r, g, b)
    bar.bg:SetVertexColor(r * 0.3, g * 0.3, b * 0.3)

    -- Text
    if db.showText then
        local text = bar:CreateFontString(nil, "OVERLAY")
        text:SetFont(self.C.FONTS.NUMBER, db.textSize or 10, "OUTLINE")
        text:SetPoint("CENTER")
        self.playerText = text
    end

    -- Initial update
    self:UpdatePlayerBar()

    -- Smooth updates (uses global animation setting)
    local animDb = addon.db.profile.animations or {}
    if animDb.smoothBars then
        self.Events:RegisterUpdate(self, 0.02, self.SmoothUpdatePlayer)
        self.playerTargetValue = 1
        self.playerCurrentValue = 1
    end
end

function HealthBar:CreateBorder(bar)
    self.Utils:CreateBarBorder(bar)
end

function HealthBar:CreateGradient(bar)
    self.playerGradient = self.Utils:CreateBarGradient(bar)
end

-------------------------------------------------------------------------------
-- Player Bar Updates
-------------------------------------------------------------------------------

function HealthBar:UpdatePlayerBar()
    if not self.playerBar then return end

    local health = UnitHealth("player")
    local maxHealth = UnitHealthMax("player")

    if maxHealth == 0 then maxHealth = 1 end
    local percent = health / maxHealth

    local db = addon.db.profile.healthBar

    local animDb = addon.db.profile.animations or {}
    if animDb.smoothBars then
        self.playerTargetValue = percent
    else
        self.playerBar:SetValue(percent)
    end

    if self.playerText and db.showText then
        self:UpdateText(self.playerText, health, maxHealth, percent, db.textFormat)
    end
end

function HealthBar:SmoothUpdatePlayer()
    if not self.playerBar or not self.playerTargetValue then return end
    
    -- Check if smoothing is still enabled (user may have disabled it)
    local animDb = addon.db.profile.animations or {}
    if not animDb.smoothBars then return end

    self.playerCurrentValue = self.Utils:SmoothBarValue(self.playerCurrentValue, self.playerTargetValue)
    self.playerBar:SetValue(self.playerCurrentValue)
end

-------------------------------------------------------------------------------
-- Shared
-------------------------------------------------------------------------------

function HealthBar:UpdateText(fontString, health, maxHealth, percent, format)
    fontString:SetText(self.Utils:FormatBarText(health, maxHealth, percent, format))
end

-------------------------------------------------------------------------------
-- Enable/Disable
-------------------------------------------------------------------------------

function HealthBar:Enable()
    if self.playerBar then self.playerBar:Show() end
end

function HealthBar:Disable()
    if self.playerBar then self.playerBar:Hide() end
end

function HealthBar:Refresh()
    -- Re-apply config settings to existing frames
    local db = addon.db.profile.healthBar
    local resourceDb = addon.db.profile.resourceBar
    
    if self.playerBar then
        -- Update size
        self.playerBar:SetSize(db.width, db.height)
        
        -- Calculate position relative to resource bar (health bar is ABOVE resource bar)
        -- Resource bar center is at Y=0, top edge at resourceBar.height/2
        -- If resource bar is disabled, health bar takes its place at Y=0
        -- Also account for combo point lift (everything moves UP when combo points present)
        local comboPointLift = self:GetComboPointLift()
        local healthBarOffset
        if resourceDb.enabled then
            local resourceBarTop = resourceDb.height / 2
            healthBarOffset = resourceBarTop + db.height / 2 + comboPointLift
        else
            -- Resource bar disabled: health bar takes its place at center (Y=0)
            healthBarOffset = comboPointLift
        end
        
        self.playerBar:ClearAllPoints()
        self.playerBar:SetPoint("CENTER", self.playerBar:GetParent(), "CENTER", 0, healthBarOffset)
        
        -- Toggle visibility based on enabled
        if db.enabled then
            self.playerBar:Show()
        else
            self.playerBar:Hide()
        end
        
        -- Update bar color (class color or default green)
        local r, g, b
        if db.classColored then
            r, g, b = self.Utils:GetClassColor(addon.playerClass)
        else
            r, g, b = 0.0, 0.8, 0.0  -- Default green for health
        end
        self.playerBar:SetStatusBarColor(r, g, b)
        if self.playerBar.bg then
            self.playerBar.bg:SetVertexColor(r * 0.3, g * 0.3, b * 0.3)
        end
        
        -- Toggle text visibility and update font size
        if self.playerText then
            self.playerText:SetFont(self.C.FONTS.NUMBER, db.textSize or 10, "OUTLINE")
            if db.showText then
                self.playerText:Show()
            else
                self.playerText:Hide()
            end
        end
    end
    
    self:UpdatePlayerBar()
end
