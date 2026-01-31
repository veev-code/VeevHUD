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

    -- Register with layout system (priority 40, no gap below)
    addon.Layout:RegisterElement("healthBar", self, 40, 0)

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
-- Layout System Integration
-------------------------------------------------------------------------------

-- Returns the height this element needs in the layout stack
function HealthBar:GetLayoutHeight()
    local db = addon.db.profile.healthBar
    if not db or not db.enabled then
        return 0
    end
    if not self.playerBar or not self.playerBar:IsShown() then
        return 0
    end
    
    -- Include border in visual height (1px top + 1px bottom = 2px total)
    return db.height + 2
end

-- Position this element at the given Y offset (center of element)
function HealthBar:SetLayoutPosition(centerY)
    if not self.playerBar then return end
    
    self.playerBar:ClearAllPoints()
    self.playerBar:SetPoint("CENTER", self.playerBar:GetParent(), "CENTER", 0, centerY)
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

    -- Create bar (position will be set by layout system)
    local bar = self.Utils:CreateStatusBar(parent, db.width, db.height)
    bar:SetPoint("CENTER", parent, "CENTER", 0, 0)  -- Temporary, layout will reposition
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

    -- Text (create if any text format is enabled)
    if db.textFormat and db.textFormat ~= "none" then
        local text = bar:CreateFontString(nil, "OVERLAY")
        text:SetFont(addon:GetFont(), db.textSize or 10, "OUTLINE")
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

    if self.playerText and db.textFormat and db.textFormat ~= "none" then
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
    
    -- Create frames if they don't exist and we should have them
    if not self.playerBar and db.enabled and addon.hudFrame then
        self:CreatePlayerBar(addon.hudFrame)
    end
    
    if self.playerBar then
        -- Update size (position handled by layout system)
        self.playerBar:SetSize(db.width, db.height)
        
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
            self.playerText:SetFont(addon:GetFont(), db.textSize or 10, "OUTLINE")
            if db.textFormat and db.textFormat ~= "none" then
                self.playerText:Show()
            else
                self.playerText:Hide()
            end
        end
    end
    
    self:UpdatePlayerBar()
    
    -- Notify layout system (our height/visibility may have changed)
    addon.Layout:Refresh()
end
