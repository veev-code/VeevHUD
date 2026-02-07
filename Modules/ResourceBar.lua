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

    -- Register with layout system (priority 30)
    -- Gap is 0 by default, increases when energy ticker is visible (hangs below bar)
    addon.Layout:RegisterElement("resourceBar", self, 30, 0)

    -- Register events
    self.Events:RegisterEvent(self, "UNIT_POWER_UPDATE", self.OnPowerUpdate)
    self.Events:RegisterEvent(self, "UNIT_MAXPOWER", self.OnPowerUpdate)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)
    self.Events:RegisterEvent(self, "UPDATE_SHAPESHIFT_FORM", self.OnShapeshiftChange)

    -- Register cast/channel events for predicted cost overlay
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_START", self.OnCastStart)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_STOP", self.OnCastEnd)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_SUCCEEDED", self.OnCastEnd)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_FAILED", self.OnCastEnd)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_INTERRUPTED", self.OnCastEnd)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_CHANNEL_START", self.OnChannelStart)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_CHANNEL_STOP", self.OnChannelEnd)
    self.Events:RegisterEvent(self, "CURRENT_SPELL_CAST_CHANGED", self.OnCurrentSpellChanged)

    self.Utils:Debug("ResourceBar initialized")
end

function ResourceBar:OnPlayerEnteringWorld()
    self:UpdatePowerType()
    self:UpdateBar()
    
    -- Initialize form tracking for druids
    local TickTracker = addon.TickTracker
    if TickTracker and TickTracker.InitFormTracking then
        TickTracker:InitFormTracking()
    end
end

function ResourceBar:OnPowerUpdate(event, unit, powerType)
    if unit == "player" then
        self:UpdateBar()
    end
end

function ResourceBar:OnShapeshiftChange()
    self:UpdatePowerType()
    self:UpdateBar()
    
    -- Notify TickTracker of form change (for druid powershifting support)
    local TickTracker = addon.TickTracker
    if TickTracker and TickTracker.OnShapeshiftChange then
        TickTracker:OnShapeshiftChange()
    end
end

-------------------------------------------------------------------------------
-- Layout System Integration
-------------------------------------------------------------------------------

-- Returns the height this element needs in the layout stack
function ResourceBar:GetLayoutHeight()
    local db = addon.db.profile.resourceBar
    if not db or not db.enabled then
        return 0
    end
    if not self.bar or not self.bar:IsShown() then
        return 0
    end
    
    -- Include border in visual height (1px top + 1px bottom = 2px total)
    return db.height + 2
end

-- Position this element at the given Y offset (center of element)
function ResourceBar:SetLayoutPosition(centerY)
    if not self.bar then return end
    
    self.bar:ClearAllPoints()
    self.bar:SetPoint("CENTER", self.bar:GetParent(), "CENTER", 0, centerY)
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function ResourceBar:CreateFrames(parent)
    local db = addon.db.profile.resourceBar

    if not db.enabled then return end

    -- Main bar frame (position will be set by layout system)
    local bar = self.Utils:CreateStatusBar(parent, db.width, db.height)
    bar:SetPoint("CENTER", parent, "CENTER", 0, 0)  -- Temporary, layout will reposition
    self.bar = bar

    -- Border/backdrop
    self:CreateBorder(bar)

    -- Gradient overlay (darker at bottom, lighter at top)
    local appearanceDb = addon.db.profile.appearance
    if appearanceDb.showGradient then
        self:CreateGradient(bar)
    end

    -- Spark texture (glowing line at fill position)
    self:CreateSpark(bar, db)

    -- Text overlay
    local text = bar:CreateFontString(nil, "OVERLAY")
    text:SetFont(addon:GetFont(), db.textSize, "OUTLINE")
    text:SetPoint("CENTER")
    self.text = text

    -- Energy ticker bar (shows progress to next energy tick)
    self:CreateEnergyTicker(bar, db)

    -- Mana ticker (shows progress to next mana tick, only in 5SR)
    self:CreateManaTicker(bar, db)

    -- Predicted cost overlay (darkened section showing pending resource deduction)
    self:CreateCostOverlay(bar)

    -- Initialize
    self:UpdatePowerType()
    self:UpdateBar()

    -- Register for updates (smooth bars and/or energy ticker)
    self.targetValue = 1
    self.currentValue = 1
    self:RegisterUpdateIfNeeded()
end

function ResourceBar:RegisterUpdateIfNeeded()
    local animDb = addon.db.profile.animations
    local db = addon.db.profile.resourceBar
    local tickerDb = db.energyTicker
    local manaTickerDb = db.manaTicker
    local iconsDb = addon.db.profile.icons
    
    -- Need updates if smooth bars enabled OR if ticker is enabled and we have energy/mana
    local needsSmoothUpdate = animDb.smoothBars
    local isEnergy = self.powerType == self.C.POWER_TYPE.ENERGY
    local isMana = self.powerType == self.C.POWER_TYPE.MANA
    local energyTickerEnabled = tickerDb and tickerDb.enabled
    local manaTickerEnabled = manaTickerDb and manaTickerDb.enabled
    local needsEnergyTicker = energyTickerEnabled and isEnergy
    local needsManaTicker = manaTickerEnabled and isMana
    
    -- Also need updates for mana rate tracking when prediction mode is enabled
    local isPredictionMode = iconsDb.resourceDisplayMode == self.C.RESOURCE_DISPLAY_MODE.PREDICTION
    local needsManaTracking = isPredictionMode and isMana
    
    if needsSmoothUpdate or needsEnergyTicker or needsManaTicker or needsManaTracking then
        self.Events:RegisterUpdate(self, 0.02, self.OnUpdate)
        self.updateRegistered = true
    elseif self.updateRegistered then
        self.Events:UnregisterUpdate(self)
        self.updateRegistered = false
    end
end

function ResourceBar:CreateSpark(bar, db)
    if not db.showSpark then return end
    
    local spark = bar:CreateTexture(nil, "OVERLAY")
    
    -- Use the casting bar spark texture (available in all WoW versions)
    spark:SetTexture([[Interface\CastingBar\UI-CastingBar-Spark]])
    spark:SetBlendMode("ADD")
    spark:SetSize(db.sparkWidth, db.height + db.sparkOverflow)
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

function ResourceBar:CreateEnergyTicker(bar, db)
    local tickerDb = db.energyTicker
    if not tickerDb or not tickerDb.enabled then return end

    if tickerDb.style == self.C.TICKER_STYLE.BAR then
        self:CreateEnergyTickerBar(bar, db, tickerDb)
    elseif tickerDb.style == self.C.TICKER_STYLE.SPARK then
        self:CreateEnergyTickerSpark(bar, db, tickerDb)
    end
end

-- "bar" style: Separate bar below resource bar (attached sub-element)
function ResourceBar:CreateEnergyTickerBar(bar, db, tickerDb)
    -- Create ticker bar as child of resource bar, positioned below it
    -- The layout system accounts for this via ResourceBar's gap
    local ticker = self.Utils:CreateStatusBar(bar, db.width, tickerDb.height)
    ticker:SetPoint("TOP", bar, "BOTTOM", 0, tickerDb.offsetY)
    ticker:SetMinMaxValues(0, 1)
    ticker:SetValue(0)
    self.ticker = ticker

    -- Use custom color or default energy yellow for the ticker
    local tickerColor = tickerDb.color
    ticker:SetStatusBarColor(tickerColor.r, tickerColor.g, tickerColor.b)
    ticker.bg:SetVertexColor(tickerColor.r * 0.15, tickerColor.g * 0.15, tickerColor.b * 0.15)

    -- Border for ticker (matches resource bar style)
    self:CreateTickerBorder(ticker)

    -- Gradient overlay (matches resource bar style)
    local appearanceDb = addon.db.profile.appearance
    if appearanceDb.showGradient then
        self:CreateTickerGradient(ticker)
    end

    -- Spark texture (glowing line at fill position, matches resource bar)
    self:CreateTickerBarSpark(ticker, tickerHeight)

    -- Hide initially (will show when player has energy)
    ticker:Hide()
end

function ResourceBar:CreateTickerBarSpark(ticker, tickerHeight)
    local db = addon.db.profile.resourceBar
    if not db.showSpark then return end

    local spark = ticker:CreateTexture(nil, "OVERLAY")
    spark:SetTexture([[Interface\CastingBar\UI-CastingBar-Spark]])
    spark:SetBlendMode("ADD")
    -- Scale spark for the thinner ticker bar (smaller width, height extends above/below)
    spark:SetSize(8, tickerHeight + 6)
    spark:SetPoint("CENTER", ticker, "LEFT", 0, 0)
    spark:SetAlpha(0.9)
    
    self.tickerSpark = spark
end

-- "spark" style: Elegant spark overlay on the resource bar itself
function ResourceBar:CreateEnergyTickerSpark(bar, db, tickerDb)
    local sparkWidth = tickerDb.sparkWidth
    local sparkHeightMult = tickerDb.sparkHeight
    local sparkHeight = db.height * sparkHeightMult

    -- Create the spark overlay
    local spark = bar:CreateTexture(nil, "OVERLAY", nil, 2)  -- Higher sublevel than normal spark
    spark:SetTexture([[Interface\CastingBar\UI-CastingBar-Spark]])
    spark:SetBlendMode("ADD")
    spark:SetSize(sparkWidth, sparkHeight)
    spark:SetPoint("CENTER", bar, "LEFT", 0, 0)
    spark:SetAlpha(0.9)
    
    self.tickerOverlaySpark = spark
    
    -- Hide initially (will show when player has energy and not at max)
    spark:Hide()
end

-------------------------------------------------------------------------------
-- Mana Ticker (5-Second Rule Indicator)
-- Shows progress to next mana tick when inside 5SR (not at full spirit regen)
-------------------------------------------------------------------------------

function ResourceBar:CreateManaTicker(bar, db)
    local manaTickerDb = db.manaTicker
    if not manaTickerDb or not manaTickerDb.enabled then return end
    local style = manaTickerDb.style

    local sparkWidth = manaTickerDb.sparkWidth
    local sparkHeightMult = manaTickerDb.sparkHeight
    local sparkHeight = db.height * sparkHeightMult

    -- Create the spark overlay (similar to energy ticker spark style)
    local spark = bar:CreateTexture(nil, "OVERLAY", nil, 3)  -- Higher sublevel for visibility
    spark:SetTexture([[Interface\CastingBar\UI-CastingBar-Spark]])
    spark:SetBlendMode("ADD")
    spark:SetSize(sparkWidth, sparkHeight)
    spark:SetPoint("CENTER", bar, "LEFT", 0, 0)
    spark:SetAlpha(1.0)
    
    -- Use bright white/cyan color for contrast against blue mana bar
    spark:SetVertexColor(0.8, 1.0, 1.0)
    
    self.manaTickerSpark = spark
    
    -- Hide initially
    spark:Hide()
end

-- Get the height of the energy ticker (for other modules to offset)
-- Returns 0 if ticker is not visible or using spark style (which doesn't take space)
function ResourceBar:GetTickerHeight()
    -- Check if ticker should be visible based on power type and settings
    local db = addon.db.profile.resourceBar
    local tickerDb = db.energyTicker
    if not tickerDb then
        return 0
    end
    
    -- Only the "bar" style takes up space below the resource bar
    -- "spark" style overlays on the resource bar itself
    if tickerDb.style ~= self.C.TICKER_STYLE.BAR then
        return 0
    end
    
    -- Only counts when player uses energy
    if self.powerType ~= self.C.POWER_TYPE.ENERGY then
        return 0
    end
    
    -- Return height + gap (total space the ticker occupies below resource bar)
    -- offsetY is negative, so we use abs to get the gap
    return tickerDb.height + math.abs(tickerDb.offsetY)
end

function ResourceBar:CreateTickerBorder(ticker)
    self.tickerBorder = self.Utils:CreateBarBorder(ticker)
end

function ResourceBar:CreateTickerGradient(ticker)
    self.tickerGradient = self.Utils:CreateBarGradient(ticker)
end

-------------------------------------------------------------------------------
-- Predicted Cost Overlay
-- Shows a darkened section on the bar for pending resource deductions
-- (queued next-melee abilities like Heroic Strike, casting/channeling spells)
-------------------------------------------------------------------------------

function ResourceBar:CreateCostOverlay(bar)
    local barTexture = (addon.GetBarTexture and addon:GetBarTexture()) or self.C.TEXTURES.STATUSBAR

    -- ARTWORK sublevel 2: above the StatusBar fill (sublevel 0) so the dark
    -- section is visible on top of the bright fill
    local costOverlay = bar:CreateTexture(nil, "ARTWORK", nil, 2)
    costOverlay:SetTexture(barTexture)
    costOverlay:Hide()
    self.costOverlay = costOverlay

    -- Color is set by UpdateCostOverlayColor (called from UpdatePowerType)
end

-- Update overlay color to match the current power type (darkened)
function ResourceBar:UpdateCostOverlayColor()
    if not self.costOverlay then return end

    local db = addon.db.profile.resourceBar
    local r, g, b

    if db.powerColor then
        r, g, b = self.Utils:GetPowerColor(self.powerType)
    else
        local c = db.color
        r, g, b = c.r, c.g, c.b
    end

    -- Darken and slightly desaturate the power color for clear "consumed" contrast
    self.costOverlay:SetVertexColor(r * 0.25, g * 0.25, b * 0.25, 0.8)
end

-------------------------------------------------------------------------------
-- Predicted Cost: Event Handlers
-------------------------------------------------------------------------------

function ResourceBar:OnCastStart(event, unit, castGUID, spellID)
    if unit ~= "player" then return end
    self.castingSpellID = spellID
    self:UpdateCostOverlay()
end

function ResourceBar:OnCastEnd(event, unit)
    if unit ~= "player" then return end
    self.castingSpellID = nil
    self:UpdateCostOverlay()
end

function ResourceBar:OnChannelStart(event, unit, castGUID, spellID)
    if unit ~= "player" then return end
    self.channelingSpellID = spellID
    self:UpdateCostOverlay()
end

function ResourceBar:OnChannelEnd(event, unit)
    if unit ~= "player" then return end
    self.channelingSpellID = nil
    self:UpdateCostOverlay()
end

function ResourceBar:OnCurrentSpellChanged()
    self:UpdateCostOverlay()
end

-------------------------------------------------------------------------------
-- Predicted Cost: Detection
-------------------------------------------------------------------------------

-- Get the total pending resource cost (casting + channeling + queued abilities)
-- Only counts costs that match the bar's current power type
function ResourceBar:GetPendingResourceCost()
    local totalCost = 0

    -- 1. Currently casting spell
    if self.castingSpellID then
        totalCost = totalCost + self:GetSpellResourceCost(self.castingSpellID)
    end

    -- 2. Currently channeling spell
    if self.channelingSpellID then
        totalCost = totalCost + self:GetSpellResourceCost(self.channelingSpellID)
    end

    -- 3. Queued "next melee" ability (Heroic Strike, Cleave, Maul, etc.)
    totalCost = totalCost + self:GetQueuedSpellCost()

    -- Never project negative cost
    return math.max(0, totalCost)
end

-- Get the resource cost of a specific spell for the current power type
-- Returns 0 if the spell uses a different power type or has no cost
-- Handles CONSUMES_ALL_RESOURCE tagged spells (e.g., Execute) that drain all remaining power
function ResourceBar:GetSpellResourceCost(spellID)
    if not GetSpellPowerCost or not spellID then return 0 end
    local costTable = GetSpellPowerCost(spellID)
    if costTable and costTable[1] then
        local cost = costTable[1].cost or 0
        local costPowerType = costTable[1].type
        -- Only count costs that match the bar's displayed power type
        if costPowerType == self.powerType then
            -- Check if this spell consumes ALL remaining resource (e.g., Execute)
            local LibSpellDB = addon.LibSpellDB
            if LibSpellDB and LibSpellDB:HasTag(spellID, "CONSUMES_ALL_RESOURCE") then
                return UnitPower("player", self.powerType)
            end
            return cost
        end
    end
    return 0
end

-- Find ALL queued abilities among tracked spells and return their combined cost
-- Skips spells already tracked as casting/channeling to prevent double-counting
function ResourceBar:GetQueuedSpellCost()
    if not IsCurrentSpell then return 0 end

    local CooldownIcons = addon:GetModule("CooldownIcons")
    if not CooldownIcons then return 0 end

    local totalCost = 0
    for _, icons in pairs(CooldownIcons.iconsByRow or {}) do
        for _, frame in ipairs(icons) do
            if frame.actualSpellID and IsCurrentSpell(frame.actualSpellID) then
                -- Skip if already counted as a casting or channeling spell
                if frame.actualSpellID ~= self.castingSpellID
                   and frame.actualSpellID ~= self.channelingSpellID then
                    totalCost = totalCost + self:GetSpellResourceCost(frame.actualSpellID)
                end
            end
        end
    end
    return totalCost
end

-------------------------------------------------------------------------------
-- Predicted Cost: Overlay Positioning
-------------------------------------------------------------------------------

-- Reposition (or hide) the cost overlay based on current state
-- The overlay is a darkened section at the right edge of the bar fill,
-- representing resource that will be consumed by pending actions
function ResourceBar:UpdateCostOverlay()
    if not self.bar or not self.costOverlay then return end

    local db = addon.db.profile.resourceBar
    if not db.showPredictedCost then
        self.costOverlay:Hide()
        return
    end

    local pendingCost = self:GetPendingResourceCost()
    if pendingCost <= 0 then
        self.costOverlay:Hide()
        return
    end

    local maxPower = UnitPowerMax("player", self.powerType)
    if maxPower == 0 then maxPower = 1 end

    local currentPower = UnitPower("player", self.powerType)
    local currentPercent = currentPower / maxPower
    local costPercent = pendingCost / maxPower

    -- Can't show more cost than current resource
    costPercent = math.min(costPercent, currentPercent)

    local afterCostPercent = currentPercent - costPercent

    local barWidth = self.bar:GetWidth()
    local leftX = afterCostPercent * barWidth
    local costWidth = costPercent * barWidth

    if costWidth < 1 then
        self.costOverlay:Hide()
        return
    end

    self.costOverlay:ClearAllPoints()
    self.costOverlay:SetPoint("TOPLEFT", self.bar, "TOPLEFT", leftX, 0)
    self.costOverlay:SetPoint("BOTTOMLEFT", self.bar, "BOTTOMLEFT", leftX, 0)
    self.costOverlay:SetWidth(costWidth)
    self.costOverlay:Show()
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

        if db.powerColor then
            r, g, b = self.Utils:GetPowerColor(self.powerType)
        else
            local c = db.color
            r, g, b = c.r, c.g, c.b
        end

        self.bar:SetStatusBarColor(r, g, b)
        self.bar.bg:SetVertexColor(r * 0.2, g * 0.2, b * 0.2)
    end

    -- Update cost overlay color to match new power type
    self:UpdateCostOverlayColor()

    -- Show/hide energy ticker based on power type
    self:UpdateTickerVisibility()
end

function ResourceBar:UpdateTickerVisibility()
    if not self.bar then return end
    
    local db = addon.db.profile.resourceBar
    local tickerDb = db.energyTicker

    -- Only show ticker for energy users when enabled
    local isEnergy = self.powerType == self.C.POWER_TYPE.ENERGY
    local tickerEnabled = tickerDb and tickerDb.enabled
    local style = tickerDb and tickerDb.style
    local shouldShow = tickerEnabled and isEnergy
    
    -- Track previous visibility state for layout changes
    local wasBarVisible = self.ticker and self.ticker:IsShown()

    -- Handle "bar" style visibility
    if self.ticker then
        if shouldShow and style == self.C.TICKER_STYLE.BAR then
            self.ticker:Show()
        else
            self.ticker:Hide()
        end
    end
    
    -- Handle "spark" style visibility (initial state, actual show/hide in update)
    if self.tickerOverlaySpark then
        if shouldShow and style == self.C.TICKER_STYLE.SPARK then
            -- Spark visibility controlled by UpdateEnergyTicker based on energy level
            -- Just initialize tracking here
        else
            self.tickerOverlaySpark:Hide()
        end
    end

    -- Initialize energy tracking when becoming visible
    if shouldShow then
        local TickTracker = addon.TickTracker
        if TickTracker then
            TickTracker.lastSampleEnergy = UnitPower("player", self.C.POWER_TYPE.ENERGY)
            if TickTracker.lastEnergyTickTime == 0 then
                TickTracker.lastEnergyTickTime = GetTime()
            end
        end
    end

    -- Re-evaluate if we need the update ticker
    self:RegisterUpdateIfNeeded()
    
    -- Check if bar-style visibility changed (affects layout)
    local isBarVisible = self.ticker and self.ticker:IsShown()
    if wasBarVisible ~= isBarVisible then
        -- Update our gap in the layout system (ticker space only)
        addon.Layout:SetElementGap("resourceBar", self:GetTickerHeight())
        addon.Layout:Refresh()
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

    local animDb = addon.db.profile.animations
    if animDb.smoothBars then
        self.targetValue = percent
    else
        self.bar:SetValue(percent)
        self:UpdateSpark(percent)
    end

    -- Update text
    if self.text and db.textFormat and db.textFormat ~= self.C.TEXT_FORMAT.NONE then
        self:UpdateText(power, maxPower, percent, db.textFormat)
    elseif self.text then
        self.text:SetText("")
    end

    -- Update cost overlay position (power level changed, so the overlay section shifts)
    self:UpdateCostOverlay()
end

function ResourceBar:UpdateSpark(percent)
    if not self.spark then return end
    
    local db = addon.db.profile.resourceBar
    
    -- Respect showSpark setting
    if not db.showSpark then
        self.spark:Hide()
        return
    end
    
    -- Hide spark when full or empty
    if db.sparkHideFullEmpty then
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

-- Combined update function for smooth bars, energy ticker, and mana tracking
function ResourceBar:OnUpdate()
    -- Smooth bar updates
    if self.bar and self.targetValue then
    local animDb = addon.db.profile.animations
    if animDb.smoothBars then
            self.currentValue = self.Utils:SmoothBarValue(self.currentValue, self.targetValue)
            self.bar:SetValue(self.currentValue)
            self:UpdateSpark(self.currentValue)
        end
    end

    -- Energy ticker updates
    self:UpdateEnergyTicker()
    
    -- Mana rate tracking (for prediction mode) and mana ticker
    if self.powerType == self.C.POWER_TYPE.MANA then
        local ResourcePrediction = addon.ResourcePrediction
        if ResourcePrediction then
            ResourcePrediction:RecordManaSample()
        end
        
        -- Mana ticker updates (shows tick progress when in 5SR)
        self:UpdateManaTicker()
    end
end

function ResourceBar:UpdateEnergyTicker()
    -- Only run for energy-using power types (Rogue, Druid Cat Form)
    if self.powerType ~= self.C.POWER_TYPE.ENERGY then return end

    local db = addon.db.profile.resourceBar
    local tickerDb = db.energyTicker
    
    if not tickerDb or not tickerDb.enabled then return end
    local style = tickerDb.style

    local currentEnergy = UnitPower("player", self.C.POWER_TYPE.ENERGY)
    local maxEnergy = UnitPowerMax("player", self.C.POWER_TYPE.ENERGY)
    local showAtFullEnergy = tickerDb.showAtFullEnergy

    -- Use centralized tick tracking from TickTracker
    -- This ensures consistency between the ticker UI and spell predictions
    local TickTracker = addon.TickTracker
    if TickTracker then
        -- Record the energy sample (handles tick detection and phantom ticks)
        TickTracker:RecordEnergySample()
        
        -- Get tick progress from the centralized tracker
        local tickProgress = TickTracker:GetEnergyTickProgress(showAtFullEnergy)
        local isMaxEnergy = currentEnergy >= maxEnergy
        local hideForMaxEnergy = isMaxEnergy and not showAtFullEnergy
        
        -- Update based on style
        if style == self.C.TICKER_STYLE.BAR then
            self:UpdateTickerBar(tickProgress, hideForMaxEnergy)
        elseif style == self.C.TICKER_STYLE.SPARK then
            self:UpdateTickerOverlaySpark(tickProgress, hideForMaxEnergy)
        end
    end
end

-- Update "bar" style ticker
-- hideForMaxEnergy: true if we should hide/empty the ticker (at max energy and showAtFullEnergy is off)
function ResourceBar:UpdateTickerBar(progress, hideForMaxEnergy)
    if not self.ticker or not self.ticker:IsShown() then return end

    -- If hiding for max energy, show empty bar (no fill, just background)
    if hideForMaxEnergy then
        self.ticker:SetValue(0)
        self:UpdateTickerBarSpark(0)
        return
    end

    self.ticker:SetValue(progress)
    self:UpdateTickerBarSpark(progress)
end

function ResourceBar:UpdateTickerBarSpark(progress)
    if not self.tickerSpark then return end

    local db = addon.db.profile.resourceBar
    if not db.showSpark then
        self.tickerSpark:Hide()
        return
    end

    -- Hide spark when empty or full
    if progress <= 0 or progress >= 1 then
        self.tickerSpark:Hide()
        return
    end

    -- Show and position spark at fill edge
    self.tickerSpark:Show()
    local tickerWidth = self.ticker:GetWidth()
    local sparkX = tickerWidth * progress
    self.tickerSpark:SetPoint("CENTER", self.ticker, "LEFT", sparkX, 0)
end

-- Update "spark" style ticker (large spark overlay on resource bar)
-- hideForMaxEnergy: true if we should hide the ticker (at max energy and showAtFullEnergy is off)
function ResourceBar:UpdateTickerOverlaySpark(progress, hideForMaxEnergy)
    if not self.tickerOverlaySpark then return end
    if not self.bar then return end

    -- Hide spark when hiding for max energy or no progress
    if hideForMaxEnergy or progress <= 0 then
        self.tickerOverlaySpark:Hide()
        return
    end

    -- Show and position spark on resource bar
    self.tickerOverlaySpark:Show()
    local barWidth = self.bar:GetWidth()
    local sparkX = barWidth * progress
    self.tickerOverlaySpark:ClearAllPoints()
    self.tickerOverlaySpark:SetPoint("CENTER", self.bar, "LEFT", sparkX, 0)
end

-------------------------------------------------------------------------------
-- Mana Ticker Updates
-------------------------------------------------------------------------------

function ResourceBar:UpdateManaTicker()
    if not self.manaTickerSpark then return end
    if not self.bar then return end
    
    local db = addon.db.profile.resourceBar
    local manaTickerDb = db.manaTicker
    
    if not manaTickerDb or not manaTickerDb.enabled then
        self.manaTickerSpark:Hide()
        return
    end
    local style = manaTickerDb.style
    
    local currentMana = UnitPower("player", self.C.POWER_TYPE.MANA)
    local maxMana = UnitPowerMax("player", self.C.POWER_TYPE.MANA)
    
    -- Hide when at max mana
    if currentMana >= maxMana then
        self.manaTickerSpark:Hide()
        return
    end
    
    -- Check visibility based on style
    if style == "outside5sr" then
        -- Only show when OUTSIDE the 5-second rule (full spirit regen)
        local FSR = addon.FiveSecondRule
        if FSR and FSR:IsActive() then
            self.manaTickerSpark:Hide()
            return
        end
    end
    -- style == "nextfreetick": show progress toward first free tick (works inside or outside 5SR)
    
    -- Get tick progress from TickTracker
    local TickTracker = addon.TickTracker
    if not TickTracker then
        self.manaTickerSpark:Hide()
        return
    end
    
    -- Record mana sample for tick detection
    TickTracker:RecordManaSample()
    
    -- Use appropriate progress function based on style
    local tickProgress
    if style == "nextfulltick" then
        -- Shows progress toward first full-rate tick after 5SR ends
        tickProgress = TickTracker:GetFullTickProgress()
    else
        -- Normal 2-second tick cycle progress
        tickProgress = TickTracker:GetManaTickProgress()
    end
    
    -- Hide when no progress
    if tickProgress <= 0 then
        self.manaTickerSpark:Hide()
        return
    end
    
    -- Show and position spark on resource bar
    self.manaTickerSpark:Show()
    local barWidth = self.bar:GetWidth()
    local sparkX = barWidth * tickProgress
    self.manaTickerSpark:ClearAllPoints()
    self.manaTickerSpark:SetPoint("CENTER", self.bar, "LEFT", sparkX, 0)
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

function ResourceBar:Refresh()
    -- Re-apply config settings to existing frames
    local db = addon.db.profile.resourceBar
    
    -- Create frames if they don't exist and we should have them
    if not self.bar and db.enabled and addon.hudFrame then
        self:CreateFrames(addon.hudFrame)
    end
    
    if self.bar then
        -- Update size (position handled by layout system)
        self.bar:SetSize(db.width, db.height)
        
        -- Update bar texture
        local barTexture = addon:GetBarTexture()
        self.bar:SetStatusBarTexture(barTexture)
        if self.bar.bg then
            self.bar.bg:SetTexture(barTexture)
        end
        
        -- Update cost overlay texture to match
        if self.costOverlay then
            self.costOverlay:SetTexture(barTexture)
        end
        
        -- Update spark visibility and size
        if not db.showSpark then
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
                self.spark:SetSize(db.sparkWidth, db.height + db.sparkOverflow)
                self.spark:Show()
            end
        end
        
        -- Toggle visibility based on enabled
        if db.enabled then
            self.bar:Show()
        else
            self.bar:Hide()
        end
        
        -- Toggle gradient
        local appearanceDb = addon.db.profile.appearance
        if appearanceDb.showGradient then
            if not self.gradient then
                self:CreateGradient(self.bar)
            end
            if self.gradient then
                self.gradient:Show()
            end
        else
            if self.gradient then
                self.gradient:Hide()
            end
        end
        
        -- Toggle text visibility and update font size
        if self.text then
            self.text:SetFont(addon:GetFont(), db.textSize, "OUTLINE")
            if db.textFormat and db.textFormat ~= self.C.TEXT_FORMAT.NONE then
                self.text:Show()
            else
                self.text:Hide()
            end
        end
    end
    
    -- Refresh energy ticker
    self:RefreshEnergyTicker()
    
    self:UpdatePowerType()
    self:UpdateBar()
    
    -- Update layout gap (ticker space only) and refresh positions
    addon.Layout:SetElementGap("resourceBar", self:GetTickerHeight())
    addon.Layout:Refresh()
end

function ResourceBar:RefreshEnergyTicker()
    local db = addon.db.profile.resourceBar
    local tickerDb = db.energyTicker
    local tickerEnabled = tickerDb and tickerDb.enabled
    local style = tickerDb and tickerDb.style
    
    -- Handle "bar" style
    if tickerEnabled and style == self.C.TICKER_STYLE.BAR then
        -- Create bar if it doesn't exist
        if not self.ticker then
            self:CreateEnergyTickerBar(self.bar, db, tickerDb)
        end
        -- Update bar size and position (attached to resource bar)
        if self.ticker then
            self.ticker:SetSize(db.width, tickerDb.height)
            self.ticker:ClearAllPoints()
            self.ticker:SetPoint("TOP", self.bar, "BOTTOM", 0, tickerDb.offsetY)
            
            -- Update ticker texture
            local barTexture = addon:GetBarTexture()
            self.ticker:SetStatusBarTexture(barTexture)
            if self.ticker.bg then
                self.ticker.bg:SetTexture(barTexture)
            end
            
            -- Update ticker color
            local tickerColor = tickerDb.color
            self.ticker:SetStatusBarColor(tickerColor.r, tickerColor.g, tickerColor.b)
            if self.ticker.bg then
                self.ticker.bg:SetVertexColor(tickerColor.r * 0.15, tickerColor.g * 0.15, tickerColor.b * 0.15)
            end
            
            -- Toggle gradient
            local appearanceDb = addon.db.profile.appearance
            if appearanceDb.showGradient then
                if not self.tickerGradient then
                    self:CreateTickerGradient(self.ticker)
                end
                if self.tickerGradient then
                    self.tickerGradient:Show()
                end
            else
                if self.tickerGradient then
                    self.tickerGradient:Hide()
                end
            end
        end
        -- Hide spark if it exists
        if self.tickerOverlaySpark then
            self.tickerOverlaySpark:Hide()
        end
    elseif tickerEnabled and style == self.C.TICKER_STYLE.SPARK then
        -- Create spark if it doesn't exist
        if not self.tickerOverlaySpark then
            self:CreateEnergyTickerSpark(self.bar, db, tickerDb)
        end
        -- Update spark size
        if self.tickerOverlaySpark then
            local sparkWidth = tickerDb.sparkWidth
            local sparkHeightMult = tickerDb.sparkHeight
            local sparkHeight = db.height * sparkHeightMult
            self.tickerOverlaySpark:SetSize(sparkWidth, sparkHeight)
        end
        -- Hide bar if it exists
        if self.ticker then
            self.ticker:Hide()
        end
    else
        -- Not enabled - hide both
        if self.ticker then
            self.ticker:Hide()
        end
        if self.tickerOverlaySpark then
            self.tickerOverlaySpark:Hide()
        end
    end
    
    -- Update visibility based on power type and style
    self:UpdateTickerVisibility()
end
