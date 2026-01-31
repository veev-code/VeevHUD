--[[
    VeevHUD - Combo Points Module
    Displays combo points as horizontal bars below the resource bar
    
    Design:
    - 5 individual horizontal bars (TBC Classic max)
    - Positioned below resource bar, above primary spell row
    - Active points: Full color with gradient
    - Inactive points: Dark/empty appearance
    - Only shown for Rogues and Feral Druids (Cat Form)
]]

local ADDON_NAME, addon = ...

local ComboPoints = {}
addon:RegisterModule("ComboPoints", ComboPoints)

-------------------------------------------------------------------------------
-- Class/Spec Detection
-------------------------------------------------------------------------------

-- Check if the current class/spec uses combo points
function ComboPoints:UsesComboPoints()
    local playerClass = addon.playerClass
    
    -- Rogues always use combo points
    if playerClass == "ROGUE" then
        return true
    end
    
    -- Druids use combo points in Cat Form
    if playerClass == "DRUID" then
        -- Check if in Cat Form (shapeshift form 3)
        local form = GetShapeshiftForm()
        return form == 3  -- Cat Form
    end
    
    return false
end

-- Calculate individual bar width based on total width setting
function ComboPoints:GetBarWidth()
    local comboDb = addon.db and addon.db.profile and addon.db.profile.comboPoints
    
    local totalWidth = comboDb and comboDb.width or 230
    local spacing = comboDb and comboDb.barSpacing or 2
    local numBars = self.C.MAX_COMBO_POINTS
    
    -- totalWidth = numBars * barWidth + (numBars - 1) * spacing
    -- Solve for barWidth: barWidth = (totalWidth - (numBars - 1) * spacing) / numBars
    local barWidth = (totalWidth - (numBars - 1) * spacing) / numBars
    return barWidth
end

-------------------------------------------------------------------------------
-- Layout System Integration
-------------------------------------------------------------------------------

-- Returns the height this element needs in the layout stack
-- Returns 0 if hidden (element won't take any space)
function ComboPoints:GetLayoutHeight()
    if not self:UsesComboPoints() then
        return 0
    end
    
    local db = addon.db and addon.db.profile and addon.db.profile.comboPoints
    if not db or not db.enabled then
        return 0
    end
    
    if not self.container or not self.container:IsShown() then
        return 0
    end
    
    -- Include border in visual height (1px top + 1px bottom = 2px total)
    return db.barHeight + 2
end

-- Position this element at the given Y offset (center of element)
function ComboPoints:SetLayoutPosition(centerY)
    if not self.container then return end
    
    self.container:ClearAllPoints()
    self.container:SetPoint("CENTER", self.container:GetParent(), "CENTER", 0, centerY)
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function ComboPoints:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants
    
    -- Combo point bar frames
    self.bars = {}
    
    -- Register with layout system (priority 10 = closest to icons, gap from settings)
    local db = addon.db and addon.db.profile and addon.db.profile.comboPoints
    local gap = db and db.offsetY or 2
    addon.Layout:RegisterElement("comboPoints", self, 10, gap)
    
    -- Register events
    -- UNIT_POWER_UPDATE fires when combo points change (powerType = "COMBO_POINTS")
    self.Events:RegisterEvent(self, "UNIT_POWER_UPDATE", self.OnPowerUpdate)
    -- Target change needed because combo points are per-target in TBC
    self.Events:RegisterEvent(self, "PLAYER_TARGET_CHANGED", self.OnTargetChanged)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)
    self.Events:RegisterEvent(self, "UPDATE_SHAPESHIFT_FORM", self.OnShapeshiftChange)
    
    self.Utils:LogInfo("ComboPoints module initialized for class:", addon.playerClass)
end

function ComboPoints:OnPlayerEnteringWorld()
    self:UpdateVisibility()
    self:UpdateComboPoints(false)  -- Initial load, no animation
end

function ComboPoints:OnPowerUpdate(event, unit, powerType)
    -- Only respond to player's combo point changes
    if unit == "player" and powerType == "COMBO_POINTS" then
        self:UpdateComboPoints(true)  -- Allow animation on actual combo point gain
    end
end

function ComboPoints:OnTargetChanged()
    -- Combo points are per-target in TBC, so update when target changes
    -- Don't animate - just show current state for the new target
    self:UpdateComboPoints(false)
end

function ComboPoints:OnShapeshiftChange()
    -- Druid changed form - update visibility
    self:UpdateVisibility()
    self:UpdateComboPoints(false)  -- Form change, no animation
    
    -- Notify layout system to reposition all elements
    addon.Layout:Refresh()
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function ComboPoints:CreateFrames(parent)
    local db = addon.db.profile.comboPoints
    local playerClass = addon.playerClass
    
    if not db or not db.enabled then return end
    
    -- Only create frames for classes that can use combo points
    if playerClass ~= "ROGUE" and playerClass ~= "DRUID" then
        return
    end
    
    -- Calculate bar width based on combo points width setting
    local barWidth = self:GetBarWidth()
    local totalWidth = db.width or 230
    
    -- Create container (position will be set by layout system)
    local container = CreateFrame("Frame", "VeevHUDComboPoints", parent)
    container:SetSize(totalWidth, db.barHeight)
    container:SetPoint("CENTER", parent, "CENTER", 0, 0)  -- Temporary, layout will reposition
    container:EnableMouse(false)  -- Click-through
    self.container = container
    
    -- Create individual combo point bars
    for i = 1, self.C.MAX_COMBO_POINTS do
        local bar = self:CreateComboPointBar(container, i, db, barWidth)
        self.bars[i] = bar
    end
    
    -- Initial visibility and state
    self:UpdateVisibility()
    self:UpdateComboPoints(false)  -- Initial state, no animation
    
    self.Utils:LogInfo("ComboPoints: Frames created for", playerClass)
end

function ComboPoints:CreateComboPointBar(parent, index, db, barWidth)
    local spacing = db.barSpacing
    local totalWidth = db.width or 230
    local startX = -totalWidth / 2 + barWidth / 2
    local xOffset = startX + (index - 1) * (barWidth + spacing)
    
    -- Main bar frame
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(barWidth, db.barHeight)
    bar:SetPoint("CENTER", parent, "CENTER", xOffset, 0)
    bar.barWidth = barWidth  -- Store for refresh
    
    -- Background (neutral gray, matching resource bar background style)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(self.C.TEXTURES.STATUSBAR)  -- Same texture as resource bar
    bg:SetVertexColor(0.2, 0.2, 0.2, 0.8)
    bar.bg = bg
    
    -- Fill texture (shown when point is active)
    local color = self.C.COMBO_POINT_COLOR
    local fill = bar:CreateTexture(nil, "ARTWORK")
    fill:SetAllPoints()
    fill:SetTexture(self.C.TEXTURES.STATUSBAR)
    fill:SetVertexColor(color.r, color.g, color.b, 1)
    fill:Hide()
    bar.fill = fill
    
    -- Gradient overlay (darker left, lighter right) - matches resource/health bar style
    -- Only shown when active (hidden by default so empty bars match resource bar background)
    if db.showGradient then
        local gradient = bar:CreateTexture(nil, "ARTWORK", nil, 1)
        gradient:SetAllPoints()
        gradient:SetTexture([[Interface\Buttons\WHITE8X8]])
        gradient:SetGradient("HORIZONTAL", 
            CreateColor(0, 0, 0, 0.35),  -- Left: darker
            CreateColor(1, 1, 1, 0.15)   -- Right: lighter/highlight
        )
        gradient:Hide()
        bar.gradient = gradient
    end
    
    -- Highlight line at top (bright edge when active, like proc glow style)
    local highlight = bar:CreateTexture(nil, "ARTWORK", nil, 2)
    highlight:SetTexture([[Interface\Buttons\WHITE8X8]])
    highlight:SetHeight(1)
    highlight:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    highlight:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, 0)
    highlight:SetVertexColor(1, 1, 1, 0.6)  -- Bright white, semi-transparent
    highlight:Hide()
    bar.highlight = highlight
    
    -- Border (subtle dark outline)
    local border = self.Utils:CreateBarBorder(bar)
    bar.border = border
    
    bar.index = index
    bar.isActive = false
    
    return bar
end

-------------------------------------------------------------------------------
-- Updates
-------------------------------------------------------------------------------

function ComboPoints:UpdateVisibility()
    if not self.container then return end
    
    local shouldShow = self:UsesComboPoints()
    local db = addon.db and addon.db.profile and addon.db.profile.comboPoints
    
    if shouldShow and db and db.enabled then
        self.container:Show()
    else
        self.container:Hide()
    end
end

function ComboPoints:UpdateComboPoints(allowAnimation)
    if not self.container or not self.container:IsShown() then return end
    
    -- Get current combo points
    local comboPoints = GetComboPoints("player", "target") or 0
    local previousPoints = self.lastComboPoints or 0
    
    -- Determine if we should animate: only on actual increment via UNIT_POWER_UPDATE
    -- (allowAnimation = true) AND points increased (not just target switch showing existing points)
    local shouldAnimate = allowAnimation and comboPoints > previousPoints
    
    self.lastComboPoints = comboPoints
    
    -- Update each bar
    for i, bar in ipairs(self.bars) do
        local isActive = i <= comboPoints
        
        if isActive ~= bar.isActive then
            bar.isActive = isActive
            
            if isActive then
                bar.fill:Show()
                if bar.gradient then bar.gradient:Show() end
                if bar.highlight then bar.highlight:Show() end
                -- Only animate newly gained points (points above previous count)
                if shouldAnimate and i > previousPoints then
                    self:PlayActivateAnimation(bar)
                end
            else
                bar.fill:Hide()
                if bar.gradient then bar.gradient:Hide() end
                if bar.highlight then bar.highlight:Hide() end
            end
        end
    end
end

-- Play a subtle scale animation when a combo point activates
function ComboPoints:PlayActivateAnimation(bar)
    if not bar then return end
    
    -- Create animation group on first use
    if not bar.activateAnim then
        local ag = bar:CreateAnimationGroup()
        
        -- Scale up slightly
        local scaleUp = ag:CreateAnimation("Scale")
        scaleUp:SetOrigin("CENTER", 0, 0)
        scaleUp:SetScale(1.15, 1.15)
        scaleUp:SetDuration(0.08)
        scaleUp:SetSmoothing("OUT")
        scaleUp:SetOrder(1)
        
        -- Scale back down
        local scaleDown = ag:CreateAnimation("Scale")
        scaleDown:SetOrigin("CENTER", 0, 0)
        scaleDown:SetScale(1/1.15, 1/1.15)
        scaleDown:SetDuration(0.1)
        scaleDown:SetSmoothing("IN")
        scaleDown:SetOrder(2)
        
        bar.activateAnim = ag
    end
    
    bar.activateAnim:Stop()
    bar.activateAnim:Play()
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

function ComboPoints:Refresh()
    local db = addon.db and addon.db.profile and addon.db.profile.comboPoints
    if not db then return end
    
    -- Update layout gap from settings
    addon.Layout:SetElementGap("comboPoints", db.offsetY or 2)
    
    -- Create frames if they don't exist and we should have them
    if not self.container and db.enabled and addon.hudFrame then
        self:CreateFrames(addon.hudFrame)
    end
    
    if self.container then
        -- Recalculate bar width based on combo points width setting
        local barWidth = self:GetBarWidth()
        local totalWidth = db.width or 230
        
        -- Update container size (position handled by layout system)
        self.container:SetSize(totalWidth, db.barHeight)
        
        -- Update bar sizes and positions within container
        local spacing = db.barSpacing
        local startX = -totalWidth / 2 + barWidth / 2
        
        for i, bar in ipairs(self.bars) do
            local xOffset = startX + (i - 1) * (barWidth + spacing)
            bar:SetSize(barWidth, db.barHeight)
            bar:ClearAllPoints()
            bar:SetPoint("CENTER", self.container, "CENTER", xOffset, 0)
        end
        
        self:UpdateVisibility()
    end
    
    self:UpdateComboPoints(false)  -- Refresh, no animation
    
    -- Notify layout system (our height may have changed)
    addon.Layout:Refresh()
end
