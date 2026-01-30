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

    -- Energy ticker state
    self.ENERGY_TICK_RATE = 2.0  -- Energy ticks every 2 seconds in WoW
    self.lastEnergy = 0
    self.tickTimer = 0
    self.lastTickTime = GetTime()

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

-- Get total lift for resource bar (combo points + ticker)
-- Resource bar moves UP to make room for both ticker and combo points below it
function ResourceBar:GetTotalLift()
    local comboPointLift = self:GetComboPointLift()
    local tickerLift = self:GetTickerHeight()
    return comboPointLift + tickerLift
end

function ResourceBar:CreateFrames(parent)
    local db = addon.db.profile.resourceBar

    if not db.enabled then return end

    -- Calculate Y offset - resource bar moves UP when combo points and/or ticker are present
    -- Combo points and ticker fill the space between resource bar and primary row (icons)
    -- Note: GetTotalLift() may return 0 initially since powerType isn't set yet
    -- UpdateTickerVisibility will trigger a refresh when power type is determined
    local totalLift = self:GetTotalLift()

    -- Main bar frame (resource bar is anchor at Y=0, lifted when combo points/ticker present)
    local bar = self.Utils:CreateStatusBar(parent, db.width, db.height)
    bar:SetPoint("CENTER", parent, "CENTER", 0, totalLift)
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

    -- Energy ticker bar (shows progress to next energy tick)
    self:CreateEnergyTicker(bar, db)

    -- Initialize
    self:UpdatePowerType()
    self:UpdateBar()

    -- Register for updates (smooth bars and/or energy ticker)
    self.targetValue = 1
    self.currentValue = 1
    self:RegisterUpdateIfNeeded()
end

function ResourceBar:RegisterUpdateIfNeeded()
    local animDb = addon.db.profile.animations or {}
    local db = addon.db.profile.resourceBar
    local tickerDb = db.energyTicker
    
    -- Need updates if smooth bars enabled OR if ticker is enabled and we have energy
    local needsSmoothUpdate = animDb.smoothBars
    local isEnergy = self.powerType == self.C.POWER_TYPE.ENERGY
    local tickerStyle = tickerDb and tickerDb.style or "disabled"
    local needsTickerUpdate = tickerStyle ~= "disabled" and isEnergy
    
    if needsSmoothUpdate or needsTickerUpdate then
        self.Events:RegisterUpdate(self, 0.02, self.OnUpdate)
        self.updateRegistered = true
    elseif self.updateRegistered then
        self.Events:UnregisterUpdate(self)
        self.updateRegistered = false
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

function ResourceBar:CreateEnergyTicker(bar, db)
    local tickerDb = db.energyTicker
    if not tickerDb or tickerDb.style == "disabled" then return end

    if tickerDb.style == "bar" then
        self:CreateEnergyTickerBar(bar, db, tickerDb)
    elseif tickerDb.style == "spark" then
        self:CreateEnergyTickerSpark(bar, db, tickerDb)
    end
end

-- "bar" style: Separate bar below resource bar
function ResourceBar:CreateEnergyTickerBar(bar, db, tickerDb)
    local tickerHeight = tickerDb.height or 3
    local tickerOffsetY = tickerDb.offsetY or -1

    -- Create ticker bar using same utility as resource bar
    -- Position BELOW the resource bar (between resource bar and combo points)
    local ticker = self.Utils:CreateStatusBar(bar, db.width, tickerHeight)
    ticker:SetPoint("TOP", bar, "BOTTOM", 0, tickerOffsetY)
    ticker:SetMinMaxValues(0, 1)
    ticker:SetValue(0)
    self.ticker = ticker

    -- Use energy color (yellow) for the ticker
    local energyColor = self.C.POWER_COLORS.ENERGY
    ticker:SetStatusBarColor(energyColor.r, energyColor.g, energyColor.b)
    ticker.bg:SetVertexColor(energyColor.r * 0.15, energyColor.g * 0.15, energyColor.b * 0.15)

    -- Border for ticker (matches resource bar style)
    self:CreateTickerBorder(ticker)

    -- Gradient overlay (matches resource bar style)
    if tickerDb.showGradient ~= false then
        self:CreateTickerGradient(ticker)
    end

    -- Spark texture (glowing line at fill position, matches resource bar)
    self:CreateTickerBarSpark(ticker, tickerHeight)

    -- Hide initially (will show when player has energy)
    ticker:Hide()
end

function ResourceBar:CreateTickerBarSpark(ticker, tickerHeight)
    local db = addon.db.profile.resourceBar
    if db.showSpark == false then return end

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
    local sparkWidth = tickerDb.sparkWidth or 6
    local sparkHeightMult = tickerDb.sparkHeight or 1.8
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
    if tickerDb.style ~= "bar" then
        return 0
    end
    
    -- Only counts when player uses energy
    if self.powerType ~= self.C.POWER_TYPE.ENERGY then
        return 0
    end
    
    -- Return height + gap (total space the ticker occupies below resource bar)
    -- offsetY is negative, so we use abs to get the gap
    return (tickerDb.height or 3) + math.abs(tickerDb.offsetY or -1)
end

function ResourceBar:CreateTickerBorder(ticker)
    self.tickerBorder = self.Utils:CreateBarBorder(ticker)
end

function ResourceBar:CreateTickerGradient(ticker)
    self.tickerGradient = self.Utils:CreateBarGradient(ticker)
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

    -- Show/hide energy ticker based on power type
    self:UpdateTickerVisibility()
end

function ResourceBar:UpdateTickerVisibility()
    local db = addon.db.profile.resourceBar
    local tickerDb = db.energyTicker

    -- Only show ticker for energy users when not disabled
    local isEnergy = self.powerType == self.C.POWER_TYPE.ENERGY
    local style = tickerDb and tickerDb.style or "disabled"
    local shouldShow = style ~= "disabled" and isEnergy
    
    -- Track previous visibility state for layout changes
    local wasBarVisible = self.ticker and self.ticker:IsShown()

    -- Handle "bar" style visibility
    if self.ticker then
        if shouldShow and style == "bar" then
            self.ticker:Show()
        else
            self.ticker:Hide()
        end
    end
    
    -- Handle "spark" style visibility (initial state, actual show/hide in update)
    if self.tickerOverlaySpark then
        if shouldShow and style == "spark" then
            -- Spark visibility controlled by UpdateEnergyTicker based on energy level
            -- Just initialize tracking here
        else
            self.tickerOverlaySpark:Hide()
        end
    end

    -- Initialize energy tracking when becoming visible
    if shouldShow then
        self.lastEnergy = UnitPower("player", self.C.POWER_TYPE.ENERGY)
        self.lastTickTime = GetTime()
    end

    -- Re-evaluate if we need the update ticker
    self:RegisterUpdateIfNeeded()
    
    -- Check if bar-style visibility changed (affects layout)
    local isBarVisible = self.ticker and self.ticker:IsShown()
    if wasBarVisible ~= isBarVisible then
        -- Reposition resource bar (needs to move up/down to accommodate ticker bar)
        if self.bar then
            local totalLift = self:GetTotalLift()
            self.bar:ClearAllPoints()
            self.bar:SetPoint("CENTER", self.bar:GetParent(), "CENTER", 0, totalLift)
        end
        
        -- Notify HealthBar to reposition (it's above the resource bar)
        local healthBar = addon:GetModule("HealthBar")
        if healthBar and healthBar.Refresh then
            healthBar:Refresh()
        end
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

-- Combined update function for smooth bars and energy ticker
function ResourceBar:OnUpdate()
    -- Smooth bar updates
    if self.bar and self.targetValue then
        local animDb = addon.db.profile.animations or {}
        if animDb.smoothBars then
            self.currentValue = self.Utils:SmoothBarValue(self.currentValue, self.targetValue)
            self.bar:SetValue(self.currentValue)
            self:UpdateSpark(self.currentValue)
        end
    end

    -- Energy ticker updates
    self:UpdateEnergyTicker()
end

function ResourceBar:UpdateEnergyTicker()
    local db = addon.db.profile.resourceBar
    local tickerDb = db.energyTicker
    local style = tickerDb and tickerDb.style or "disabled"
    
    if style == "disabled" then return end

    local currentEnergy = UnitPower("player", self.C.POWER_TYPE.ENERGY)
    local maxEnergy = UnitPowerMax("player", self.C.POWER_TYPE.ENERGY)
    local currentTime = GetTime()

    -- Detect energy tick (energy increased naturally, not from abilities)
    -- Energy ticks give +20 energy per tick in Classic
    if currentEnergy > self.lastEnergy then
        -- Energy increased, a tick just happened - reset timer
        self.lastTickTime = currentTime
    end

    -- Update stored energy value
    self.lastEnergy = currentEnergy

    -- Calculate progress toward next tick
    local tickProgress = 0
    if currentEnergy < maxEnergy then
        local timeSinceTick = currentTime - self.lastTickTime
        tickProgress = timeSinceTick / self.ENERGY_TICK_RATE
        -- Clamp to 0-1 range
        tickProgress = math.min(1, math.max(0, tickProgress))
    end

    -- Update based on style
    if style == "bar" then
        self:UpdateTickerBar(tickProgress, currentEnergy >= maxEnergy)
    elseif style == "spark" then
        self:UpdateTickerOverlaySpark(tickProgress, currentEnergy >= maxEnergy)
    end
end

-- Update "bar" style ticker
function ResourceBar:UpdateTickerBar(progress, isMaxEnergy)
    if not self.ticker or not self.ticker:IsShown() then return end

    -- If at max energy, show empty bar (no fill, just background)
    if isMaxEnergy then
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
    if db.showSpark == false then
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
function ResourceBar:UpdateTickerOverlaySpark(progress, isMaxEnergy)
    if not self.tickerOverlaySpark then return end
    if not self.bar then return end

    -- Hide spark when at max energy or no progress
    if isMaxEnergy or progress <= 0 then
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
        
        -- Resource bar moves UP when combo points and/or ticker are present
        local totalLift = self:GetTotalLift()
        self.bar:ClearAllPoints()
        self.bar:SetPoint("CENTER", self.bar:GetParent(), "CENTER", 0, totalLift)
        
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
    
    -- Refresh energy ticker
    self:RefreshEnergyTicker()
    
    self:UpdatePowerType()
    self:UpdateBar()
end

function ResourceBar:RefreshEnergyTicker()
    local db = addon.db.profile.resourceBar
    local tickerDb = db.energyTicker
    local style = tickerDb and tickerDb.style or "disabled"
    
    -- Handle "bar" style
    if style == "bar" then
        -- Create bar if it doesn't exist
        if not self.ticker then
            self:CreateEnergyTickerBar(self.bar, db, tickerDb)
        end
        -- Update bar size and position
        if self.ticker then
            local tickerHeight = tickerDb.height or 3
            local tickerOffsetY = tickerDb.offsetY or -1
            
            self.ticker:SetSize(db.width, tickerHeight)
            self.ticker:ClearAllPoints()
            self.ticker:SetPoint("TOP", self.bar, "BOTTOM", 0, tickerOffsetY)
        end
        -- Hide spark if it exists
        if self.tickerOverlaySpark then
            self.tickerOverlaySpark:Hide()
        end
    elseif style == "spark" then
        -- Create spark if it doesn't exist
        if not self.tickerOverlaySpark then
            self:CreateEnergyTickerSpark(self.bar, db, tickerDb)
        end
        -- Update spark size
        if self.tickerOverlaySpark then
            local sparkWidth = tickerDb.sparkWidth or 6
            local sparkHeightMult = tickerDb.sparkHeight or 1.8
            local sparkHeight = db.height * sparkHeightMult
            self.tickerOverlaySpark:SetSize(sparkWidth, sparkHeight)
        end
        -- Hide bar if it exists
        if self.ticker then
            self.ticker:Hide()
        end
    else
        -- Disabled - hide both
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
