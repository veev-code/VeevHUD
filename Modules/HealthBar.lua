--[[
    VeevHUD - Health Bar Module
    Displays player health bar with heal prediction
]]

local _, addon = ...

local HealthBar = {}
addon:RegisterModule("HealthBar", HealthBar)

-- Cache API functions (may be nil on some game versions)
local UnitGetIncomingHeals = UnitGetIncomingHeals

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function HealthBar:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants

    -- Register with layout system
    addon.Layout:RegisterElement("healthBar", self)

    -- Register events
    self.Events:RegisterEvent(self, "UNIT_HEALTH", self.OnHealthUpdate)
    self.Events:RegisterEvent(self, "UNIT_MAXHEALTH", self.OnHealthUpdate)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)

    -- Heal prediction events
    if UnitGetIncomingHeals then
        self.Events:RegisterEvent(self, "UNIT_HEAL_PREDICTION", self.OnHealPredictionUpdate)
    end

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

function HealthBar:OnHealPredictionUpdate(event, unit)
    if unit == "player" then
        self:UpdateOverlays()
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

-- Position this element at the given Y offset.
-- Uses topY: bar starts 1px below allocation top (room for full border's top edge).
function HealthBar:SetLayoutPosition(centerY, topY)
    if not self.playerBar then return end

    self.playerBar:ClearAllPoints()
    self.playerBar:SetPoint("TOP", self.playerBar:GetParent(), "CENTER", 0, topY - 1)
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
    local appearanceDb = addon.db.profile.appearance
    if appearanceDb.showGradient then
        self:CreateGradient(bar)
    end

    -- Set bar color (class color or custom color)
    local r, g, b
    if db.classColored then
        r, g, b = self.Utils:GetClassColor(addon.playerClass)
    else
        local c = db.color
        r, g, b = c.r, c.g, c.b
    end
    bar:SetStatusBarColor(r, g, b)
    bar.bg:SetVertexColor(r * 0.3, g * 0.3, b * 0.3)

    -- Heal prediction overlay
    self:CreateHealPrediction(bar)

    -- Text (create if any text format is enabled, above overlays)
    if db.textFormat and db.textFormat ~= self.C.TEXT_FORMAT.NONE then
        local text = bar:CreateFontString(nil, "OVERLAY")
        text:SetFont(addon:GetFont(), db.textSize, "OUTLINE")
        text:SetPoint("CENTER")
        self.playerText = text
    end

    -- Initial update
    self:UpdatePlayerBar()

    -- Smooth updates (uses global animation setting)
    -- Frame OnUpdate for frame-rate synced smooth animation
    local animDb = addon.db.profile.animations
    if animDb.smoothBars then
        self.playerTargetValue = 1
        self.playerCurrentValue = 1
        self.playerBar:SetScript("OnUpdate", function()
            self:SmoothUpdatePlayer()
        end)
    end
end

function HealthBar:CreateBorder(bar)
    self.Utils:CreateBarBorder(bar)
end

function HealthBar:CreateGradient(bar)
    self.playerGradient = self.Utils:CreateBarGradient(bar)
end

-------------------------------------------------------------------------------
-- Heal Prediction Overlay
-------------------------------------------------------------------------------

-- Heal prediction: lighter version of health bar color, shows incoming heals
function HealthBar:CreateHealPrediction(bar)
    local barTexture = (addon.GetBarTexture and addon:GetBarTexture()) or self.C.TEXTURES.STATUSBAR

    local healPredict = bar:CreateTexture(nil, "ARTWORK", nil, 2)
    healPredict:SetTexture(barTexture)
    healPredict:Hide()
    self.healPrediction = healPredict

    -- Set initial color (health bar color at 0.4 alpha)
    self:UpdateHealPredictionColor()
end

-- Set heal prediction color to match health bar color at reduced alpha
function HealthBar:UpdateHealPredictionColor()
    if not self.healPrediction or not self.playerBar then return end
    local r, g, b = self.playerBar:GetStatusBarColor()
    self.healPrediction:SetVertexColor(r, g, b, 0.4)
end

-------------------------------------------------------------------------------
-- Overlay Update Logic
-------------------------------------------------------------------------------

-- Master update for heal prediction overlay
-- Projection never exceeds 100% of bar width
function HealthBar:UpdateOverlays()
    if not self.playerBar then return end

    local db = addon.db.profile.healthBar

    local health = UnitHealth("player")
    local maxHealth = UnitHealthMax("player")
    if maxHealth == 0 then maxHealth = 1 end

    local healthPercent = health / maxHealth
    local barWidth = self.playerBar:GetWidth()
    if barWidth <= 0 then return end

    -- Available space to the right of the health fill (never exceed 100%)
    local availablePercent = 1 - healthPercent

    -- Incoming heals
    local healPercent = 0
    if db.showHealPrediction and UnitGetIncomingHeals then
        local incomingHeals = UnitGetIncomingHeals("player") or 0
        if incomingHeals > 0 then
            healPercent = incomingHeals / maxHealth
            healPercent = math.min(healPercent, availablePercent)
        end
    end
    self:PositionHealPrediction(healthPercent, healPercent, barWidth)
end

-- Position the heal prediction texture (starts right after health fill)
function HealthBar:PositionHealPrediction(healthPercent, healPercent, barWidth)
    if not self.healPrediction then return end

    if healPercent <= 0 then
        self.healPrediction:Hide()
        return
    end

    local healWidth = healPercent * barWidth
    if healWidth < 1 then
        self.healPrediction:Hide()
        return
    end

    local startX = healthPercent * barWidth

    self.healPrediction:ClearAllPoints()
    self.healPrediction:SetPoint("TOPLEFT", self.playerBar, "TOPLEFT", startX, 0)
    self.healPrediction:SetPoint("BOTTOMLEFT", self.playerBar, "BOTTOMLEFT", startX, 0)
    self.healPrediction:SetWidth(healWidth)
    self.healPrediction:Show()
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

    local animDb = addon.db.profile.animations
    if animDb.smoothBars then
        self.playerTargetValue = percent
    else
        self.playerBar:SetValue(percent)
    end

    if self.playerText and db.textFormat and db.textFormat ~= self.C.TEXT_FORMAT.NONE then
        self.playerText:SetText(self.Utils:FormatBarText(health, maxHealth, percent, db.textFormat, db.numberFormat))
    end

    -- Update heal prediction overlay (position depends on health %)
    self:UpdateOverlays()
end

function HealthBar:SmoothUpdatePlayer()
    if not self.playerBar or not self.playerTargetValue then return end
    
    -- Check if smoothing is still enabled (user may have disabled it)
    local animDb = addon.db.profile.animations
    if not animDb.smoothBars then return end

    self.playerCurrentValue = self.Utils:SmoothBarValue(self.playerCurrentValue, self.playerTargetValue)
    self.playerBar:SetValue(self.playerCurrentValue)
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

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
        
        -- Update bar texture
        local barTexture = addon:GetBarTexture()
        self.playerBar:SetStatusBarTexture(barTexture)
        if self.playerBar.bg then
            self.playerBar.bg:SetTexture(barTexture)
        end
        
        -- Update bar color (class color or custom color)
        local r, g, b
        if db.classColored then
            r, g, b = self.Utils:GetClassColor(addon.playerClass)
        else
            local c = db.color
            r, g, b = c.r, c.g, c.b
        end
        self.playerBar:SetStatusBarColor(r, g, b)
        if self.playerBar.bg then
            self.playerBar.bg:SetVertexColor(r * 0.3, g * 0.3, b * 0.3)
        end
        
        -- Toggle gradient
        local appearanceDb = addon.db.profile.appearance
        if appearanceDb.showGradient then
            if not self.playerGradient then
                self:CreateGradient(self.playerBar)
            end
            if self.playerGradient then
                self.playerGradient:Show()
            end
        else
            if self.playerGradient then
                self.playerGradient:Hide()
            end
        end
        
        -- Toggle text visibility and update font size
        if db.textFormat and db.textFormat ~= self.C.TEXT_FORMAT.NONE then
            if not self.playerText then
                local text = self.playerBar:CreateFontString(nil, "OVERLAY")
                text:SetPoint("CENTER")
                self.playerText = text
            end
            self.playerText:SetFont(addon:GetFont(), db.textSize, "OUTLINE")
            self.playerText:Show()
        elseif self.playerText then
            self.playerText:Hide()
        end

        -- Update overlay textures to match bar texture
        if self.healPrediction then
            self.healPrediction:SetTexture(barTexture)
        end
        -- Update heal prediction color to match bar color
        self:UpdateHealPredictionColor()
    end
    
    self:UpdatePlayerBar()
    
    -- Notify layout system (our height/visibility may have changed)
    addon.Layout:Refresh()
end
