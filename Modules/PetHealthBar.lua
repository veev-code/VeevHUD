--[[
    VeevHUD - Pet Health Bar Module
    Displays pet health bar, auto-hides when no pet is active
]]

local ADDON_NAME, addon = ...

local PetHealthBar = {}
addon:RegisterModule("PetHealthBar", PetHealthBar)

-- Cache API functions (may be nil on some game versions)
local UnitGetIncomingHeals = UnitGetIncomingHeals

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function PetHealthBar:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants

    self.hasPet = false

    -- Register with layout system
    addon.Layout:RegisterElement("petHealthBar", self)

    -- Pet existence events
    self.Events:RegisterEvent(self, "UNIT_PET", self.OnUnitPet)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)

    -- Pet health events
    self.Events:RegisterEvent(self, "UNIT_HEALTH", self.OnHealthUpdate)
    self.Events:RegisterEvent(self, "UNIT_MAXHEALTH", self.OnHealthUpdate)

    -- Heal prediction events
    if UnitGetIncomingHeals then
        self.Events:RegisterEvent(self, "UNIT_HEAL_PREDICTION", self.OnHealPredictionUpdate)
    end

    self.Utils:Debug("PetHealthBar initialized")
end

function PetHealthBar:OnPlayerEnteringWorld()
    self:CheckPetStatus()
end

function PetHealthBar:OnUnitPet()
    self:CheckPetStatus()
end

function PetHealthBar:OnHealthUpdate(event, unit)
    if unit == "pet" then
        -- Pet dying doesn't fire UNIT_PET, so recheck status on health changes
        self:CheckPetStatus()
    end
end

function PetHealthBar:OnHealPredictionUpdate(event, unit)
    if unit == "pet" then
        self:UpdateOverlays()
    end
end

-------------------------------------------------------------------------------
-- Pet Status
-------------------------------------------------------------------------------

function PetHealthBar:CheckPetStatus()
    local hadPet = self.hasPet
    self.hasPet = UnitExists("pet") and not UnitIsDead("pet")

    if self.hasPet ~= hadPet then
        local db = addon.db.profile.petHealthBar
        if self.bar and db.enabled then
            if self.hasPet then
                self.bar:Show()
            else
                self.bar:Hide()
            end
        end
        addon.Layout:Refresh()
    end

    if self.hasPet then
        self:UpdateBar()
    end
end

-------------------------------------------------------------------------------
-- Layout System Integration
-------------------------------------------------------------------------------

function PetHealthBar:GetLayoutHeight()
    local db = addon.db.profile.petHealthBar
    if not db.enabled then return 0 end
    if not self.hasPet then return 0 end
    if not self.bar or not self.bar:IsShown() then return 0 end

    -- skipTop border: only 1px bottom border contributes to height
    return db.height + 1
end

function PetHealthBar:SetLayoutPosition(centerY, topY)
    if not self.bar then return end

    self.bar:ClearAllPoints()
    -- skipTop border: bar starts at allocation top (no top border extending above)
    self.bar:SetPoint("TOP", self.bar:GetParent(), "CENTER", 0, topY)
end

function PetHealthBar:SetTopBorderShown(show)
    if self.border and self.border.SetTopEdgeShown then
        self.border:SetTopEdgeShown(show)
    end
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function PetHealthBar:CreateFrames(parent)
    local db = addon.db.profile.petHealthBar

    if not db.enabled then return end

    local bar = self.Utils:CreateStatusBar(parent, db.width, db.height)
    bar:SetPoint("CENTER", parent, "CENTER", 0, 0)  -- Temporary, layout will reposition
    self.bar = bar

    -- Border (skipTop for adjacency)
    self.border = self.Utils:CreateBarBorder(bar, true)

    -- Gradient overlay
    local appearanceDb = addon.db.profile.appearance
    if appearanceDb.showGradient then
        self.gradient = self.Utils:CreateBarGradient(bar)
    end

    -- Bar color
    local c = db.color
    bar:SetStatusBarColor(c.r, c.g, c.b)
    bar.bg:SetVertexColor(c.r * 0.3, c.g * 0.3, c.b * 0.3)

    -- Heal prediction overlay
    self:CreateHealPrediction(bar)

    -- Text
    if db.textFormat and db.textFormat ~= self.C.TEXT_FORMAT.NONE then
        local text = bar:CreateFontString(nil, "OVERLAY")
        text:SetFont(addon:GetFont(), db.textSize, "OUTLINE")
        text:SetPoint("CENTER")
        self.text = text
    end

    -- Start hidden if no pet
    if not self.hasPet then
        bar:Hide()
    end

    -- Smooth animation support
    local animDb = addon.db.profile.animations
    if animDb.smoothBars then
        self.targetValue = 1
        self.currentValue = 1
        self.bar:SetScript("OnUpdate", function()
            self:SmoothUpdate()
        end)
    end

    -- Initial update
    self:CheckPetStatus()
end

-------------------------------------------------------------------------------
-- Heal Prediction
-------------------------------------------------------------------------------

function PetHealthBar:CreateHealPrediction(bar)
    local barTexture = (addon.GetBarTexture and addon:GetBarTexture()) or self.C.TEXTURES.STATUSBAR

    local healPredict = bar:CreateTexture(nil, "ARTWORK", nil, 2)
    healPredict:SetTexture(barTexture)
    healPredict:Hide()
    self.healPrediction = healPredict

    self:UpdateHealPredictionColor()
end

function PetHealthBar:UpdateHealPredictionColor()
    if not self.healPrediction or not self.bar then return end
    local r, g, b = self.bar:GetStatusBarColor()
    self.healPrediction:SetVertexColor(r, g, b, 0.4)
end

function PetHealthBar:UpdateOverlays()
    if not self.bar then return end

    local db = addon.db.profile.petHealthBar

    local health = UnitHealth("pet")
    local maxHealth = UnitHealthMax("pet")
    if maxHealth == 0 then maxHealth = 1 end

    local healthPercent = health / maxHealth
    local barWidth = self.bar:GetWidth()
    if barWidth <= 0 then return end

    local availablePercent = 1 - healthPercent

    local healPercent = 0
    if db.showHealPrediction and UnitGetIncomingHeals then
        local incomingHeals = UnitGetIncomingHeals("pet") or 0
        if incomingHeals > 0 then
            healPercent = incomingHeals / maxHealth
            healPercent = math.min(healPercent, availablePercent)
        end
    end
    self:PositionHealPrediction(healthPercent, healPercent, barWidth)
end

function PetHealthBar:PositionHealPrediction(healthPercent, healPercent, barWidth)
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
    self.healPrediction:SetPoint("TOPLEFT", self.bar, "TOPLEFT", startX, 0)
    self.healPrediction:SetPoint("BOTTOMLEFT", self.bar, "BOTTOMLEFT", startX, 0)
    self.healPrediction:SetWidth(healWidth)
    self.healPrediction:Show()
end

-------------------------------------------------------------------------------
-- Bar Updates
-------------------------------------------------------------------------------

function PetHealthBar:UpdateBar()
    if not self.bar then return end
    if not self.hasPet then return end

    local health = UnitHealth("pet")
    local maxHealth = UnitHealthMax("pet")

    if maxHealth == 0 then maxHealth = 1 end
    local percent = health / maxHealth

    local db = addon.db.profile.petHealthBar

    local animDb = addon.db.profile.animations
    if animDb.smoothBars then
        self.targetValue = percent
    else
        self.bar:SetValue(percent)
    end

    if self.text and db.textFormat and db.textFormat ~= self.C.TEXT_FORMAT.NONE then
        self.text:SetText(self.Utils:FormatBarText(health, maxHealth, percent, db.textFormat, db.numberFormat))
    end

    -- Update heal prediction overlay
    self:UpdateOverlays()
end

function PetHealthBar:SmoothUpdate()
    if not self.bar or not self.targetValue then return end

    local animDb = addon.db.profile.animations
    if not animDb.smoothBars then return end

    self.currentValue = self.Utils:SmoothBarValue(self.currentValue, self.targetValue)
    self.bar:SetValue(self.currentValue)
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

function PetHealthBar:Refresh()
    local db = addon.db.profile.petHealthBar

    -- Create frames if they don't exist and we should have them
    if not self.bar and db.enabled and addon.hudFrame then
        self:CreateFrames(addon.hudFrame)
    end

    if self.bar then
        -- Update size
        self.bar:SetSize(db.width, db.height)

        -- Toggle visibility
        if db.enabled and self.hasPet then
            self.bar:Show()
        else
            self.bar:Hide()
        end

        -- Update bar texture
        local barTexture = addon:GetBarTexture()
        self.bar:SetStatusBarTexture(barTexture)
        if self.bar.bg then
            self.bar.bg:SetTexture(barTexture)
        end

        -- Update color
        local c = db.color
        self.bar:SetStatusBarColor(c.r, c.g, c.b)
        if self.bar.bg then
            self.bar.bg:SetVertexColor(c.r * 0.3, c.g * 0.3, c.b * 0.3)
        end

        -- Toggle gradient
        local appearanceDb = addon.db.profile.appearance
        if appearanceDb.showGradient then
            if not self.gradient then
                self.gradient = self.Utils:CreateBarGradient(self.bar)
            end
            if self.gradient then
                self.gradient:Show()
            end
        else
            if self.gradient then
                self.gradient:Hide()
            end
        end

        -- Update heal prediction overlay
        if self.healPrediction then
            self.healPrediction:SetTexture(barTexture)
        end
        self:UpdateHealPredictionColor()

        -- Toggle text and update font
        if db.textFormat and db.textFormat ~= self.C.TEXT_FORMAT.NONE then
            if not self.text then
                local text = self.bar:CreateFontString(nil, "OVERLAY")
                text:SetPoint("CENTER")
                self.text = text
            end
            self.text:SetFont(addon:GetFont(), db.textSize, "OUTLINE")
            self.text:Show()
        elseif self.text then
            self.text:Hide()
        end
    end

    self:CheckPetStatus()

    addon.Layout:Refresh()
end
