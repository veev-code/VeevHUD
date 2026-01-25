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

function HealthBar:CreatePlayerBar(parent)
    local db = addon.db.profile.healthBar

    if not db.enabled then return end

    -- Calculate position relative to resource bar (health bar is ABOVE resource bar)
    -- If resource bar is disabled, health bar takes its place at Y=0
    local resourceDb = addon.db.profile.resourceBar
    local healthBarOffset
    if resourceDb.enabled then
        local resourceBarTop = resourceDb.height / 2
        healthBarOffset = resourceBarTop + db.height / 2
    else
        -- Resource bar disabled: health bar takes its place at center (Y=0)
        healthBarOffset = 0
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
    local border = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    border:SetBackdropBorderColor(0, 0, 0, 1)
    border:SetFrameLevel(bar:GetFrameLevel() - 1)

    -- Outer shadow for depth
    local shadow = CreateFrame("Frame", nil, border, "BackdropTemplate")
    shadow:SetPoint("TOPLEFT", -1, 1)
    shadow:SetPoint("BOTTOMRIGHT", 1, -1)
    shadow:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    shadow:SetBackdropBorderColor(0, 0, 0, 0.5)
    shadow:SetFrameLevel(border:GetFrameLevel() - 1)
end

function HealthBar:CreateGradient(bar)
    -- Gradient overlay: darker on left, lighter on right
    local gradient = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    gradient:SetAllPoints(bar:GetStatusBarTexture())
    gradient:SetTexture([[Interface\Buttons\WHITE8X8]])
    
    -- Horizontal gradient: left is darker, right is lighter
    gradient:SetGradient("HORIZONTAL", 
        CreateColor(0, 0, 0, 0.35),  -- Left (darker)
        CreateColor(1, 1, 1, 0.15)   -- Right (lighter/highlight)
    )
    
    self.playerGradient = gradient
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

    local diff = self.playerTargetValue - self.playerCurrentValue
    if math.abs(diff) < 0.001 then
        self.playerCurrentValue = self.playerTargetValue
    else
        self.playerCurrentValue = self.playerCurrentValue + diff * 0.3
    end

    self.playerBar:SetValue(self.playerCurrentValue)
end

-------------------------------------------------------------------------------
-- Shared
-------------------------------------------------------------------------------

function HealthBar:UpdateText(fontString, health, maxHealth, percent, format)
    local text

    if format == "current" then
        text = self.Utils:FormatNumber(health)
    elseif format == "percent" then
        text = string.format("%d%%", percent * 100)
    elseif format == "both" then
        text = string.format("%s (%d%%)", self.Utils:FormatNumber(health), percent * 100)
    elseif format == "deficit" then
        local deficit = maxHealth - health
        if deficit > 0 then
            text = "-" .. self.Utils:FormatNumber(deficit)
        else
            text = ""
        end
    else
        text = ""
    end

    fontString:SetText(text)
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
        local healthBarOffset
        if resourceDb.enabled then
            local resourceBarTop = resourceDb.height / 2
            healthBarOffset = resourceBarTop + db.height / 2
        else
            -- Resource bar disabled: health bar takes its place at center (Y=0)
            healthBarOffset = 0
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
