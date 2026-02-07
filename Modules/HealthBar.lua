--[[
    VeevHUD - Health Bar Module
    Displays player health bar with heal prediction and absorb shields
]]

local ADDON_NAME, addon = ...

local HealthBar = {}
addon:RegisterModule("HealthBar", HealthBar)

-- Cache API functions (may be nil on some game versions)
local UnitGetIncomingHeals = UnitGetIncomingHeals
local UnitGetTotalAbsorbs = UnitGetTotalAbsorbs
local UnitAura = UnitAura

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

    -- Heal prediction events
    if UnitGetIncomingHeals then
        self.Events:RegisterEvent(self, "UNIT_HEAL_PREDICTION", self.OnHealPredictionUpdate)
    end

    -- Absorb shield events
    if UnitGetTotalAbsorbs then
        -- Modern API available (Retail/Mists+): use native event
        self.Events:RegisterEvent(self, "UNIT_ABSORB_AMOUNT_CHANGED", self.OnAbsorbUpdate)
    elseif UnitAura then
        -- TBC/Anniversary fallback: scan UnitAura for absorb values
        -- UNIT_AURA fires when auras are applied/removed/refreshed
        self.Events:RegisterEvent(self, "UNIT_AURA", self.OnAbsorbUpdate)
        -- SPELL_ABSORBED fires when a shield absorbs damage (aura value changes but UNIT_AURA doesn't fire)
        self.Events:RegisterCLEU(self, "SPELL_ABSORBED", self.OnSpellAbsorbed)
        self.useAuraAbsorbFallback = true
    end

    self.Utils:Debug("HealthBar initialized")
end

function HealthBar:OnPlayerEnteringWorld()
    -- Seed the absorb cache so overlays show immediately (before first UNIT_AURA)
    if self.useAuraAbsorbFallback then
        self.cachedAbsorbs = self:ScanAuraAbsorbs("player")
    end
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

function HealthBar:OnAbsorbUpdate(event, unit)
    if unit == "player" then
        -- When using UnitAura fallback, cache the scan result so UpdateOverlays
        -- (which also runs on health/heal events) doesn't re-scan unnecessarily
        if self.useAuraAbsorbFallback then
            self.cachedAbsorbs = self:ScanAuraAbsorbs("player")
        end
        self:UpdateOverlays()
    end
end

-- CLEU handler: SPELL_ABSORBED fires when a shield absorbs damage.
-- UNIT_AURA doesn't fire for partial absorb depletion, so we need this
-- to keep the cached absorb value accurate as shields take hits.
function HealthBar:OnSpellAbsorbed(subEvent, info)
    if info.destGUID == UnitGUID("player") then
        self.cachedAbsorbs = self:ScanAuraAbsorbs("player")
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

    -- Heal prediction and absorb overlays
    self:CreateHealPrediction(bar)
    self:CreateAbsorbShield(bar)
    self:CreateOverAbsorbGlow(bar)

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
    local animDb = addon.db.profile.animations
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
-- Absorb Amount Query
-------------------------------------------------------------------------------

-- Scans UnitAura for buffs with absorb values (17th return).
-- Used as fallback on TBC Classic / Anniversary Edition where UnitGetTotalAbsorbs doesn't exist.
function HealthBar:ScanAuraAbsorbs(unit)
    if not UnitAura then return 0 end
    local total = 0
    for i = 1, 40 do
        local name, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, absorb = UnitAura(unit, i, "HELPFUL")
        if not name then break end
        if absorb and absorb > 0 then
            total = total + absorb
        end
    end
    return total
end

-- Returns total absorb shield amount on the given unit.
-- Uses UnitGetTotalAbsorbs (Retail/Mists+) if available,
-- otherwise returns the cached UnitAura scan result (updated on UNIT_AURA).
function HealthBar:GetTotalAbsorbs(unit)
    if UnitGetTotalAbsorbs then
        return UnitGetTotalAbsorbs(unit) or 0
    end
    -- Fallback: return cached value from last UNIT_AURA scan
    -- Cache is populated by OnAbsorbUpdate, which fires on every UNIT_AURA event
    return self.cachedAbsorbs or 0
end

-------------------------------------------------------------------------------
-- Heal Prediction & Absorb Shield Overlays
-------------------------------------------------------------------------------

-- Absorb shield: tiled shield texture showing total absorb amount (guaranteed protection)
-- Positioned starting at right edge of health fill, growing right into missing health
-- Shown before heal prediction because absorbs are certain, heals are speculative
function HealthBar:CreateAbsorbShield(bar)
    -- Use Blizzard's built-in shield fill texture for visual consistency
    -- ARTWORK sublevel 2: above StatusBar fill (sublevel 0)
    local absorbBar = bar:CreateTexture(nil, "ARTWORK", nil, 2)
    absorbBar:SetTexture([[Interface\RaidFrame\Shield-Fill]])
    absorbBar:SetVertexColor(1, 1, 1, 0.5)
    absorbBar:Hide()
    self.absorbShield = absorbBar

    -- Tiled overlay on top of the fill for the hatched shield look
    local absorbOverlay = bar:CreateTexture(nil, "ARTWORK", nil, 3)
    absorbOverlay:SetTexture([[Interface\RaidFrame\Shield-Overlay]], true, true)
    absorbOverlay:SetHorizTile(true)
    absorbOverlay:SetVertTile(true)
    absorbOverlay:Hide()
    self.absorbOverlay = absorbOverlay
end

-- Heal prediction: lighter version of health bar color, shows incoming heals (speculative)
-- Positioned after absorb shield because heals may not land
function HealthBar:CreateHealPrediction(bar)
    local barTexture = (addon.GetBarTexture and addon:GetBarTexture()) or self.C.TEXTURES.STATUSBAR

    -- ARTWORK sublevel 4: above absorb shield
    local healPredict = bar:CreateTexture(nil, "ARTWORK", nil, 4)
    healPredict:SetTexture(barTexture)
    healPredict:Hide()
    self.healPrediction = healPredict

    -- Set initial color (health bar color at 0.4 alpha)
    self:UpdateHealPredictionColor()
end

-- Glow at the right edge of the bar when absorb shield exceeds missing health
function HealthBar:CreateOverAbsorbGlow(bar)
    local glow = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    glow:SetTexture([[Interface\RaidFrame\Shield-Overshield]])
    glow:SetBlendMode("ADD")
    glow:SetWidth(8)
    glow:SetAlpha(0.6)
    glow:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 4, 0)
    glow:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 4, 0)
    glow:Hide()
    self.overAbsorbGlow = glow
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

-- Master update for heal prediction + absorb overlays
-- Total projection never exceeds 100% of bar width
-- Respects per-overlay toggle settings
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

    -- 1. Absorb shield (guaranteed, already active — shown first after health)
    local totalAbsorbs = 0
    local absorbPercent = 0
    if db.showAbsorbs then
        totalAbsorbs = self:GetTotalAbsorbs("player")
        if totalAbsorbs > 0 then
            absorbPercent = totalAbsorbs / maxHealth
            -- Clamp to available space
            absorbPercent = math.min(absorbPercent, availablePercent)
        end
    end
    self:PositionAbsorbShield(healthPercent, absorbPercent, barWidth)

    -- 2. Incoming heals (speculative — shown after absorbs)
    local healPercent = 0
    if db.showHealPrediction and UnitGetIncomingHeals then
        local incomingHeals = UnitGetIncomingHeals("player") or 0
        if incomingHeals > 0 then
            healPercent = incomingHeals / maxHealth
            local remainingPercent = availablePercent - absorbPercent
            -- Clamp to remaining space (absorb already used some)
            healPercent = math.min(healPercent, math.max(0, remainingPercent))
        end
    end
    self:PositionHealPrediction(healthPercent, absorbPercent, healPercent, barWidth)

    -- 3. Over-absorb glow (show only when absorb shields exceed missing health)
    local showGlow = false
    if db.showAbsorbs and db.showOverAbsorbGlow then
        -- Glow only when absorbs alone overflow the bar (heals overflowing is just overheal, not noteworthy)
        if totalAbsorbs > 0 and (health + totalAbsorbs) > maxHealth then
            showGlow = true
        end
    end
    if self.overAbsorbGlow then
        if showGlow then
            self.overAbsorbGlow:Show()
        else
            self.overAbsorbGlow:Hide()
        end
    end
end

-- Position the absorb shield texture (starts right after health fill)
function HealthBar:PositionAbsorbShield(healthPercent, absorbPercent, barWidth)
    if not self.absorbShield then return end

    if absorbPercent <= 0 then
        self.absorbShield:Hide()
        if self.absorbOverlay then self.absorbOverlay:Hide() end
        return
    end

    local absorbWidth = absorbPercent * barWidth
    if absorbWidth < 1 then
        self.absorbShield:Hide()
        if self.absorbOverlay then self.absorbOverlay:Hide() end
        return
    end

    local startX = healthPercent * barWidth

    self.absorbShield:ClearAllPoints()
    self.absorbShield:SetPoint("TOPLEFT", self.playerBar, "TOPLEFT", startX, 0)
    self.absorbShield:SetPoint("BOTTOMLEFT", self.playerBar, "BOTTOMLEFT", startX, 0)
    self.absorbShield:SetWidth(absorbWidth)
    self.absorbShield:Show()

    -- Tiled overlay tracks the fill exactly
    if self.absorbOverlay then
        self.absorbOverlay:SetAllPoints(self.absorbShield)
        self.absorbOverlay:Show()
    end
end

-- Position the heal prediction texture (starts after absorb shield)
function HealthBar:PositionHealPrediction(healthPercent, absorbPercent, healPercent, barWidth)
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

    local startX = (healthPercent + absorbPercent) * barWidth

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
        self:UpdateText(self.playerText, health, maxHealth, percent, db.textFormat)
    end

    -- Update heal prediction and absorb overlays (positions depend on health %)
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
-- Shared
-------------------------------------------------------------------------------

function HealthBar:UpdateText(fontString, health, maxHealth, percent, format)
    fontString:SetText(self.Utils:FormatBarText(health, maxHealth, percent, format))
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
        if self.playerText then
            self.playerText:SetFont(addon:GetFont(), db.textSize, "OUTLINE")
            if db.textFormat and db.textFormat ~= self.C.TEXT_FORMAT.NONE then
                self.playerText:Show()
            else
                self.playerText:Hide()
            end
        end

        -- Update overlay textures to match bar texture
        if self.healPrediction then
            self.healPrediction:SetTexture(barTexture)
        end
        -- Absorb shield uses Blizzard's Shield-Fill (unchanged by bar texture)
        -- but update heal prediction color to match bar color
        self:UpdateHealPredictionColor()
    end
    
    self:UpdatePlayerBar()
    
    -- Notify layout system (our height/visibility may have changed)
    addon.Layout:Refresh()
end
