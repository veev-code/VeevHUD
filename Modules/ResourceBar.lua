--[[
    VeevHUD - Resource Bar Module
    Displays player resource (mana/rage/energy) bar
]]

local _, addon = ...

-- Localized WoW API functions (hot path)
local UnitBuff = UnitBuff
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local UnitPowerType = UnitPowerType
local GetTime = GetTime
local IsSpellKnown = IsSpellKnown

local ResourceBar = {}
addon:RegisterModule("ResourceBar", ResourceBar)

-- Resolve Innervate spell ID + name from LibSpellDB (tagged IMPORTANT_EXTERNAL + RESOURCE)
local innervateSpellID, innervateName
do
    local LibSpellDB = LibStub and LibStub("LibSpellDB-1.0", true)
    if LibSpellDB then
        local spells = LibSpellDB:GetSpellsByAllTags({"IMPORTANT_EXTERNAL", "RESOURCE"})
        for id, data in pairs(spells) do
            innervateSpellID = id
            innervateName = data.name or GetSpellInfo(id)
            break
        end
    end
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function ResourceBar:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants

    -- Register with layout system
    addon.Layout:RegisterElement("resourceBar", self)

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
    self.Events:RegisterEvent(self, "UNIT_AURA", self.OnUnitAura)

    self.Utils:Debug("ResourceBar initialized")
end

function ResourceBar:OnUnitAura(event, unit)
    if unit == "player" then
        self:CheckInnervate()
    end
end

function ResourceBar:CheckInnervate()
    local db = addon.db.profile.resourceBar
    local hasInnervate = false

    if db.innervateHighlight.enabled then
        for i = 1, 40 do
            local name, _, _, _, _, _, _, _, _, spellID = UnitBuff("player", i)
            if not name then break end
            if (innervateSpellID and spellID == innervateSpellID) or (innervateName and name == innervateName) then
                hasInnervate = true
                break
            end
        end
    end

    if hasInnervate ~= (self.innervateActive or false) then
        self.innervateActive = hasInnervate
        self:UpdateBarColor()
        self:UpdateDruidManaBarColor()
    end
end

function ResourceBar:OnPlayerEnteringWorld()
    self:CheckInnervate()
    self:UpdatePowerType()
    self:UpdateBar()

    -- Initialize form tracking for druids
    local TickTracker = addon.TickTracker
    if TickTracker and TickTracker.InitFormTracking then
        TickTracker:InitFormTracking()
    end

    -- Initialize druid mana bar visibility based on current form
    self:UpdateDruidManaBarVisibility()
end

function ResourceBar:OnPowerUpdate(event, unit, powerType)
    if unit == "player" then
        self:UpdateBar()
        if powerType == "MANA" then
            self:UpdateDruidManaBar()
        end
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

    -- Show/hide druid secondary mana bar based on current form
    self:UpdateDruidManaBarVisibility()
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

    -- Include border in visual height (skipTop: 1px bottom only)
    -- Include energy ticker height (bar-style ticker hangs below resource bar)
    -- Include druid mana bar height (when visible in Cat/Bear Form)
    return db.height + 1 + self:GetTickerHeight() + self:GetManaBarHeight()
end

-- Position this element at the given Y offset.
-- Uses topY to anchor from top edge (skipTop border = no top overhang,
-- so top of bar must align exactly with allocation top for clean adjacency).
function ResourceBar:SetLayoutPosition(centerY, topY)
    if not self.bar then return end

    self.bar:ClearAllPoints()
    self.bar:SetPoint("TOP", self.bar:GetParent(), "CENTER", 0, topY)
end

-- Toggle top border edge visibility (called by Layout when bar adjacency changes)
function ResourceBar:SetTopBorderShown(show)
    if self.border then
        self.border:SetTopEdgeShown(show)
    end
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

    -- Druid secondary mana bar (shows mana while in Cat/Bear Form)
    self:CreateDruidManaBar(bar, db)

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
    if not self.bar then return end

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
    local druidManaBarVisible = self.manaBar and self.manaBar:IsShown()
    local needsManaTicker = manaTickerEnabled and (isMana or druidManaBarVisible)

    -- Also need updates for mana rate tracking when prediction mode is enabled
    local isPredictionMode = iconsDb.resourceDisplayMode == self.C.RESOURCE_DISPLAY_MODE.PREDICTION
    local needsManaTracking = isPredictionMode and isMana

    if needsSmoothUpdate or needsEnergyTicker or needsManaTicker or needsManaTracking then
        -- Use frame OnUpdate for frame-rate synced smooth animation
        if not self.updateRegistered then
            self.bar:SetScript("OnUpdate", function()
                self:OnUpdate()
            end)
            self.updateRegistered = true
        end
    elseif self.updateRegistered then
        self.bar:SetScript("OnUpdate", nil)
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
    self.border = self.Utils:CreateBarBorder(bar, true)  -- skipTop: health bar above provides the separator
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
    self:CreateTickerBarSpark(ticker, tickerDb.height)

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
-- Druid Secondary Mana Bar
-- Shows mana alongside energy/rage while shapeshifted into Cat or Bear Form
-------------------------------------------------------------------------------

function ResourceBar:CreateDruidManaBar(bar, db)
    if addon.playerClass ~= self.C.CLASS.DRUID then return end
    local manaDb = db.druidManaBar
    if not manaDb or not manaDb.enabled then return end

    local manaBar = self.Utils:CreateStatusBar(bar, db.width, manaDb.height)
    manaBar:SetPoint("TOP", bar, "BOTTOM", 0, -1 - self:GetTickerHeight())
    manaBar:SetMinMaxValues(0, 1)
    manaBar:SetValue(0)
    self.manaBar = manaBar

    -- Color from config
    local mc = manaDb.color
    manaBar:SetStatusBarColor(mc.r, mc.g, mc.b)
    manaBar.bg:SetVertexColor(mc.r * 0.2, mc.g * 0.2, mc.b * 0.2)

    -- Border
    self.manaBarBorder = self.Utils:CreateBarBorder(manaBar)

    -- Gradient overlay
    if addon.db.profile.appearance.showGradient then
        self.manaBarGradient = self.Utils:CreateBarGradient(manaBar)
    end

    -- Spark (scaled to mana bar height)
    if manaDb.showSpark then
        local spark = manaBar:CreateTexture(nil, "OVERLAY")
        spark:SetTexture([[Interface\CastingBar\UI-CastingBar-Spark]])
        spark:SetBlendMode("ADD")
        spark:SetSize(db.sparkWidth, manaDb.height + db.sparkOverflow)
        spark:SetPoint("CENTER", manaBar, "LEFT", 0, 0)
        spark:SetAlpha(0.9)
        self.manaBarSpark = spark
    end

    -- Form cost marker (vertical line showing mana cost of current form)
    local marker = manaBar:CreateTexture(nil, "OVERLAY")
    marker:SetColorTexture(1, 1, 1, 0.7)
    marker:SetSize(2, manaDb.height)
    marker:Hide()
    self.formCostMarker = marker

    -- Text
    local text = manaBar:CreateFontString(nil, "OVERLAY")
    text:SetFont(addon:GetFont(), manaDb.textSize, "OUTLINE")
    text:SetPoint("CENTER")
    self.manaBarText = text

    -- Start hidden (shown by UpdateDruidManaBarVisibility on form change)
    manaBar:Hide()
end

-- Spell IDs for shapeshift forms (used by form cost marker)
local FORM_COST_SPELLS = {
    BEAR = { 5487, 9634 },  -- Bear Form, Dire Bear Form
    CAT  = { 768 },         -- Cat Form
}

function ResourceBar:GetManaBarHeight()
    if addon.playerClass ~= self.C.CLASS.DRUID then return 0 end
    local db = addon.db.profile.resourceBar
    local manaDb = db.druidManaBar
    if not manaDb or not manaDb.enabled then return 0 end
    if not self.manaBar or not self.manaBar:IsShown() then return 0 end
    return manaDb.height + 1
end

function ResourceBar:UpdateDruidManaBarVisibility()
    if not self.manaBar then return end

    -- Respect the enabled setting
    local db = addon.db.profile.resourceBar
    local manaDb = db.druidManaBar
    if not manaDb or not manaDb.enabled then
        local wasVisible = self.manaBar:IsShown()
        self.manaBar:Hide()
        if wasVisible then
            addon.Layout:Refresh()
            self:RegisterUpdateIfNeeded()
        end
        return
    end

    local form = self.C.GetDruidForm()
    local inForm = (form == "CAT" or form == "BEAR")
    local wasVisible = self.manaBar:IsShown()

    if inForm then
        -- Reposition below bar + ticker (ticker height may have changed)
        local db = addon.db.profile.resourceBar
        local manaDb = db.druidManaBar
        self.manaBar:ClearAllPoints()
        self.manaBar:SetPoint("TOP", self.bar, "BOTTOM", 0, -1 - self:GetTickerHeight())
        self.manaBar:Show()
        self:UpdateDruidManaBar()
        self:UpdateDruidManaBarColor()
    else
        self.manaBar:Hide()
    end

    if wasVisible ~= self.manaBar:IsShown() then
        addon.Layout:Refresh()
        -- Mana ticker may need to start/stop updating for the druid mana bar
        self:RegisterUpdateIfNeeded()
    end
end

function ResourceBar:UpdateDruidManaBar()
    if not self.manaBar or not self.manaBar:IsShown() then return end
    local mana = UnitPower("player", self.C.POWER_TYPE.MANA)
    local maxMana = UnitPowerMax("player", self.C.POWER_TYPE.MANA)
    if maxMana == 0 then maxMana = 1 end
    local percent = mana / maxMana
    self.manaBar:SetValue(percent)

    -- Update spark and form cost marker positions
    self:UpdateManaBarSpark(percent)
    self:UpdateFormCostMarker()

    local db = addon.db.profile.resourceBar.druidManaBar
    if self.manaBarText and db.textFormat and db.textFormat ~= self.C.TEXT_FORMAT.NONE then
        self.manaBarText:SetText(self.Utils:FormatBarText(mana, maxMana, percent, db.textFormat, db.numberFormat))
    elseif self.manaBarText then
        self.manaBarText:SetText("")
    end
end

function ResourceBar:UpdateFormCostMarker()
    if not self.formCostMarker then return end

    local manaDb = addon.db.profile.resourceBar.druidManaBar
    if not manaDb.showFormCostMarker then
        self.formCostMarker:Hide()
        return
    end

    local form = addon.Constants.GetDruidForm()
    local formSpells = FORM_COST_SPELLS[form]
    if not formSpells then
        self.formCostMarker:Hide()
        return
    end

    -- Get mana cost of the current form spell (try each variant, e.g., Bear vs Dire Bear)
    local formCost = 0
    for _, spellID in ipairs(formSpells) do
        if IsSpellKnown(spellID) and GetSpellPowerCost then
            local costTable = GetSpellPowerCost(spellID)
            if costTable and costTable[1] then
                formCost = costTable[1].cost or 0
                if formCost > 0 then break end
            end
        end
    end

    if formCost <= 0 then
        self.formCostMarker:Hide()
        return
    end

    local maxMana = UnitPowerMax("player", self.C.POWER_TYPE.MANA)
    if maxMana <= 0 then
        self.formCostMarker:Hide()
        return
    end

    -- Only show when mana is insufficient to re-enter form
    local currentMana = UnitPower("player", self.C.POWER_TYPE.MANA)
    if currentMana >= formCost then
        self.formCostMarker:Hide()
        return
    end

    local markerPercent = formCost / maxMana
    local barWidth = self.manaBar:GetWidth()
    local markerX = barWidth * markerPercent

    self.formCostMarker:ClearAllPoints()
    self.formCostMarker:SetPoint("CENTER", self.manaBar, "LEFT", markerX, 0)
    self.formCostMarker:Show()
end

function ResourceBar:UpdateManaBarSpark(percent)
    if not self.manaBarSpark then return end

    local manaDb = addon.db.profile.resourceBar.druidManaBar
    if not manaDb.showSpark then
        self.manaBarSpark:Hide()
        return
    end

    local db = addon.db.profile.resourceBar
    if db.sparkHideFullEmpty then
        if percent <= 0 or percent >= 1 then
            self.manaBarSpark:Hide()
            return
        else
            self.manaBarSpark:Show()
        end
    end

    local barWidth = self.manaBar:GetWidth()
    local sparkX = barWidth * percent
    self.manaBarSpark:ClearAllPoints()
    self.manaBarSpark:SetPoint("CENTER", self.manaBar, "LEFT", sparkX, 0)
end

function ResourceBar:RefreshDruidManaBar()
    local db = addon.db.profile.resourceBar
    local manaDb = db.druidManaBar
    local enabled = manaDb and manaDb.enabled and addon.playerClass == self.C.CLASS.DRUID

    if enabled then
        -- Create if it doesn't exist yet
        if not self.manaBar and self.bar then
            self:CreateDruidManaBar(self.bar, db)
        end

        if self.manaBar then
            -- Update size and position
            self.manaBar:SetSize(db.width, manaDb.height)
            self.manaBar:ClearAllPoints()
            self.manaBar:SetPoint("TOP", self.bar, "BOTTOM", 0, -1 - self:GetTickerHeight())

            -- Update texture
            local barTexture = addon:GetBarTexture()
            self.manaBar:SetStatusBarTexture(barTexture)
            if self.manaBar.bg then
                self.manaBar.bg:SetTexture(barTexture)
            end

            -- Update color (respects Innervate highlight if active)
            self:UpdateDruidManaBarColor()

            -- Update border
            if not self.manaBarBorder then
                self.manaBarBorder = self.Utils:CreateBarBorder(self.manaBar)
            end

            -- Toggle gradient
            local appearanceDb = addon.db.profile.appearance
            if appearanceDb.showGradient then
                if not self.manaBarGradient then
                    self.manaBarGradient = self.Utils:CreateBarGradient(self.manaBar)
                end
                if self.manaBarGradient then
                    self.manaBarGradient:Show()
                end
            else
                if self.manaBarGradient then
                    self.manaBarGradient:Hide()
                end
            end

            -- Update spark
            if manaDb.showSpark then
                if not self.manaBarSpark then
                    local spark = self.manaBar:CreateTexture(nil, "OVERLAY")
                    spark:SetTexture([[Interface\CastingBar\UI-CastingBar-Spark]])
                    spark:SetBlendMode("ADD")
                    spark:SetPoint("CENTER", self.manaBar, "LEFT", 0, 0)
                    spark:SetAlpha(0.9)
                    self.manaBarSpark = spark
                end
                self.manaBarSpark:SetSize(db.sparkWidth, manaDb.height + db.sparkOverflow)
                self.manaBarSpark:Show()
            else
                if self.manaBarSpark then
                    self.manaBarSpark:Hide()
                end
            end

            -- Update form cost marker
            if not self.formCostMarker then
                local marker = self.manaBar:CreateTexture(nil, "OVERLAY")
                marker:SetColorTexture(1, 1, 1, 0.7)
                marker:Hide()
                self.formCostMarker = marker
            end
            self.formCostMarker:SetSize(2, manaDb.height)

            -- Update text font
            if self.manaBarText then
                self.manaBarText:SetFont(addon:GetFont(), manaDb.textSize, "OUTLINE")
            end
        end
    else
        -- Hide if disabled or not a druid
        if self.manaBar then
            self.manaBar:Hide()
        end
    end

    -- Update visibility based on current form
    self:UpdateDruidManaBarVisibility()
end

-- Update druid mana bar color (applies Innervate highlight when active)
function ResourceBar:UpdateDruidManaBarColor()
    if not self.manaBar then return end

    local db = addon.db.profile.resourceBar
    local r, g, b

    if self.innervateActive and db.innervateHighlight.enabled then
        local c = db.innervateHighlight.color
        r, g, b = c.r, c.g, c.b
    else
        local mc = db.druidManaBar.color
        r, g, b = mc.r, mc.g, mc.b
    end

    self.manaBar:SetStatusBarColor(r, g, b)
    if self.manaBar.bg then
        self.manaBar.bg:SetVertexColor(r * 0.2, g * 0.2, b * 0.2)
    end
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

-- Returns the current resolved bar color (accounts for Innervate override)
-- Innervate only highlights the mana bar — for feral druids, the druid mana bar
-- handles this via UpdateDruidManaBarColor instead.
function ResourceBar:GetBarColor()
    local db = addon.db.profile.resourceBar

    if self.innervateActive and db.innervateHighlight.enabled
       and self.powerType == self.C.POWER_TYPE.MANA then
        local c = db.innervateHighlight.color
        return c.r, c.g, c.b
    elseif db.powerColor then
        return self.Utils:GetPowerColor(self.powerType)
    else
        local c = db.color
        return c.r, c.g, c.b
    end
end

-- Update overlay color to match the current bar color (darkened)
function ResourceBar:UpdateCostOverlayColor()
    if not self.costOverlay then return end

    local r, g, b = self:GetBarColor()

    -- Darken and slightly desaturate the bar color for clear "consumed" contrast
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

    local LibSpellDB = addon.LibSpellDB

    local totalCost = 0
    for _, icons in pairs(CooldownIcons.iconsByRow or {}) do
        for _, frame in ipairs(icons) do
            local sid = frame.actualSpellID
            if sid and IsCurrentSpell(sid) then
                -- Pet summons stay "current" permanently after casting; skip them
                if LibSpellDB and LibSpellDB:HasTag(sid, "PET_SUMMON") then
                    -- skip
                elseif sid ~= self.castingSpellID and sid ~= self.channelingSpellID then
                    totalCost = totalCost + self:GetSpellResourceCost(sid)
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

function ResourceBar:UpdateBarColor()
    if not self.bar then return end

    local r, g, b = self:GetBarColor()
    self.bar:SetStatusBarColor(r, g, b)
    self.bar.bg:SetVertexColor(r * 0.2, g * 0.2, b * 0.2)

    -- Keep cost overlay in sync
    self:UpdateCostOverlayColor()
end

function ResourceBar:UpdatePowerType()
    self.powerType = UnitPowerType("player")

    self:UpdateBarColor()

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
    
    -- Check if bar-style visibility changed (affects layout height)
    local isBarVisible = self.ticker and self.ticker:IsShown()
    if wasBarVisible ~= isBarVisible then
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
        self.text:SetText(self.Utils:FormatBarText(power, maxPower, percent, db.textFormat, db.numberFormat))
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

-- Combined update function for smooth bars, energy ticker, and mana tracking
function ResourceBar:OnUpdate()
    -- Smooth bar updates
    if self.bar and self.currentValue and self.targetValue then
    local animDb = addon.db.profile.animations
    if animDb.smoothBars then
            self.currentValue = self.Utils:SmoothBarValue(self.currentValue, self.targetValue)
            self.bar:SetValue(self.currentValue)
            self:UpdateSpark(self.currentValue)
        end
    end

    -- Energy ticker updates
    self:UpdateEnergyTicker()
    
    -- Mana rate tracking (for prediction mode) — only when main bar shows mana
    if self.powerType == self.C.POWER_TYPE.MANA then
        local ResourcePrediction = addon.ResourcePrediction
        if ResourcePrediction then
            ResourcePrediction:RecordManaSample()
        end
    end

    -- Mana ticker updates (on main bar when mana, or on druid mana bar in form)
    self:UpdateManaTicker()
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

    local db = addon.db.profile.resourceBar
    local manaTickerDb = db.manaTicker

    if not manaTickerDb or not manaTickerDb.enabled then
        self.manaTickerSpark:Hide()
        return
    end

    -- Determine which bar shows mana: druid mana bar in form, or main bar in caster
    local targetBar
    local manaDb = db.druidManaBar
    if self.manaBar and self.manaBar:IsShown() and manaDb.showManaTicker then
        targetBar = self.manaBar
    elseif self.powerType == self.C.POWER_TYPE.MANA and self.bar then
        targetBar = self.bar
    else
        self.manaTickerSpark:Hide()
        return
    end

    -- Re-parent spark to the correct bar if needed
    if self.manaTickerSpark:GetParent() ~= targetBar then
        self.manaTickerSpark:SetParent(targetBar)
        -- Resize spark for the target bar's height
        local sparkWidth = manaTickerDb.sparkWidth
        local sparkHeightMult = manaTickerDb.sparkHeight
        local barHeight = (targetBar == self.manaBar) and db.druidManaBar.height or db.height
        self.manaTickerSpark:SetSize(sparkWidth, barHeight * sparkHeightMult)
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

    -- Show and position spark on target bar
    self.manaTickerSpark:Show()
    local barWidth = targetBar:GetWidth()
    local sparkX = barWidth * tickProgress
    self.manaTickerSpark:ClearAllPoints()
    self.manaTickerSpark:SetPoint("CENTER", targetBar, "LEFT", sparkX, 0)
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

    -- Refresh druid mana bar
    self:RefreshDruidManaBar()

    self:UpdatePowerType()
    self:UpdateBar()
    
    -- Refresh layout (height may have changed due to ticker)
    addon.Layout:Refresh()
end

function ResourceBar:RefreshEnergyTicker()
    if not self.bar then return end
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
