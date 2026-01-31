--[[
    VeevHUD - Layout Manager
    
    Centralized layout system for positioning HUD elements.
    Each element registers with the layout manager and provides:
      - GetLayoutHeight(): returns the height this element needs (0 if hidden)
      - SetLayoutPosition(centerY): positions the element at the given Y offset
    
    Elements are stacked upward from the icon row (bottom) to procTracker (top).
    No element needs to know about any other element - the layout manager
    handles all positioning based on what's visible.
    
    Layout order (bottom to top, by priority):
      10: ComboPoints
      20: EnergyTicker (part of ResourceBar, separate slot)
      30: ResourceBar
      40: HealthBar
      50: ProcTracker
]]

local ADDON_NAME, addon = ...

local Layout = {}
addon.Layout = Layout

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------

-- Base Y offset: the TOP of the icon row (where bars start stacking from)
-- All bars stack UPWARD from this position
-- Icons top is at approximately -9 with default settings (14px resource bar / 2 + 2px gap)
-- Value is relative to HUD center (Y=0)
Layout.baseOffset = -9  -- Icons top edge

-------------------------------------------------------------------------------
-- Element Registry
-------------------------------------------------------------------------------

-- Registered layout elements
-- Key: element name, Value: { module, priority, gap }
Layout.elements = {}

--[[
    Register a layout element.
    
    @param name     Unique identifier for this element
    @param module   The module instance (must implement GetLayoutHeight and SetLayoutPosition)
    @param priority Lower numbers are positioned closer to icons (stacked first)
                    Recommended: 10=ComboPoints, 20=EnergyTicker, 30=ResourceBar, 40=HealthBar, 50=ProcTracker
    @param gap      Spacing (in pixels) BELOW this element (between its bottom and the top of the previous element)
]]
function Layout:RegisterElement(name, module, priority, gap)
    self.elements[name] = {
        name = name,
        module = module,
        priority = priority or 50,
        gap = gap or 0,
    }
    addon.Utils:LogDebug("Layout: Registered element", name, "priority:", priority, "gap:", gap)
end

--[[
    Unregister a layout element.
    @param name The element name to unregister
]]
function Layout:UnregisterElement(name)
    self.elements[name] = nil
    addon.Utils:LogDebug("Layout: Unregistered element", name)
end

--[[
    Update the gap for an existing element.
    Useful when element spacing changes based on settings.
    @param name The element name
    @param gap  New gap value
]]
function Layout:SetElementGap(name, gap)
    if self.elements[name] then
        self.elements[name].gap = gap
    end
end

-------------------------------------------------------------------------------
-- Layout Calculation
-------------------------------------------------------------------------------

--[[
    Refresh all element positions.
    
    Called automatically when any element's visibility changes.
    
    The layout algorithm uses SIMPLE UPWARD STACKING from the icon row:
    1. Icons are the true anchor (fixed position)
    2. All bars stack UPWARD from baseOffset (just above icons)
    3. Elements are positioned in priority order (lowest priority = closest to icons)
    
    Gap semantics:
    - gap is space ABOVE this element (between its top and the next element's bottom)
    - For attached sub-elements (like energy ticker), gap represents the extra space
      that hangs below the element
]]
function Layout:Refresh()
    if not addon.hudFrame then return end
    
    -- Collect all visible elements
    local visibleElements = {}
    
    for _, element in pairs(self.elements) do
        local module = element.module
        if module and module.GetLayoutHeight then
            local height = module:GetLayoutHeight()
            if height > 0 then
                table.insert(visibleElements, element)
            end
        end
    end
    
    -- Sort by priority ascending (lowest priority = closest to icons, stacks first)
    table.sort(visibleElements, function(a, b) return a.priority < b.priority end)
    
    -- Stack upward from baseOffset (icons top)
    -- currentY tracks the top of the previous element (or icons top initially)
    local currentY = self.baseOffset
    
    -- Get configurable icon row gap (default 2)
    local iconRowGap = 2
    if addon.db and addon.db.profile and addon.db.profile.layout then
        iconRowGap = addon.db.profile.layout.iconRowGap or 2
    end
    
    for i, element in ipairs(visibleElements) do
        local module = element.module
        local height = module:GetLayoutHeight()
        
        -- Gap is space between previous element's top and this element's bottom
        -- First visible element gets minimum gap from icons (configurable)
        local gap = element.gap
        if i == 1 and gap < iconRowGap then
            gap = iconRowGap
        end
        
        local bottom = currentY + gap
        local centerY = bottom + (height / 2)
        local top = bottom + height
        
        if module.SetLayoutPosition then
            module:SetLayoutPosition(centerY)
        end
        
        -- Move currentY to this element's top for next iteration
        currentY = top
    end
    
    addon.Utils:LogDebug("Layout: Refreshed, elements:", #visibleElements, "top:", currentY)
end

-------------------------------------------------------------------------------
-- Utility Functions
-------------------------------------------------------------------------------

--[[
    Get the current top Y position (useful for elements that need to know
    where the stack ends, like positioning elements above the entire HUD).
    
    @return The Y offset of the topmost element's top edge
]]
function Layout:GetStackTop()
    local currentY = self.baseOffset
    
    -- Collect and sort visible elements
    local visibleElements = {}
    for _, element in pairs(self.elements) do
        local module = element.module
        if module and module.GetLayoutHeight then
            local height = module:GetLayoutHeight()
            if height > 0 then
                table.insert(visibleElements, element)
            end
        end
    end
    table.sort(visibleElements, function(a, b) return a.priority < b.priority end)
    
    -- Get configurable icon row gap (default 2)
    local iconRowGap = 2
    if addon.db and addon.db.profile and addon.db.profile.layout then
        iconRowGap = addon.db.profile.layout.iconRowGap or 2
    end
    
    -- Stack upward (same logic as Refresh)
    for i, element in ipairs(visibleElements) do
        local height = element.module:GetLayoutHeight()
        local gap = element.gap
        if i == 1 and gap < iconRowGap then
            gap = iconRowGap
        end
        local bottom = currentY + gap
        currentY = bottom + height  -- top of this element
    end
    
    return currentY
end

--[[
    Debug function to print current layout state.
]]
function Layout:PrintDebug()
    print("|cff00ff00VeevHUD Layout Debug:|r")
    print("  Base offset (icons top):", self.baseOffset)
    
    -- Show ticker state if ResourceBar module exists
    local resourceBar = addon.ResourceBar
    if resourceBar then
        local tickerHeight = resourceBar.GetTickerHeight and resourceBar:GetTickerHeight() or 0
        local tickerVisible = resourceBar.ticker and resourceBar.ticker:IsShown()
        print("  Ticker: height=" .. tickerHeight .. ", visible=" .. tostring(tickerVisible or false))
    end
    
    -- Collect all elements
    local allElements = {}
    for _, element in pairs(self.elements) do
        local module = element.module
        local height = 0
        if module and module.GetLayoutHeight then
            height = module:GetLayoutHeight()
        end
        element._debugHeight = height
        table.insert(allElements, element)
    end
    
    -- Sort by priority (lowest first = closest to icons)
    table.sort(allElements, function(a, b) return a.priority < b.priority end)
    
    -- Get configurable icon row gap (default 2)
    local iconRowGap = 2
    if addon.db and addon.db.profile and addon.db.profile.layout then
        iconRowGap = addon.db.profile.layout.iconRowGap or 2
    end
    
    -- Calculate positions with upward stacking (same logic as Refresh)
    local currentY = self.baseOffset
    local visibleIndex = 0
    
    for _, element in ipairs(allElements) do
        local height = element._debugHeight
        local status = height > 0 and "|cff00ff00visible|r" or "|cff888888hidden|r"
        local centerY = "n/a"
        local bottom = "n/a"
        local effectiveGap = element.gap
        
        if height > 0 then
            visibleIndex = visibleIndex + 1
            -- First visible element gets minimum gap from icons (configurable)
            if visibleIndex == 1 and effectiveGap < iconRowGap then
                effectiveGap = iconRowGap
            end
            bottom = currentY + effectiveGap
            centerY = bottom + (height / 2)
            currentY = bottom + height  -- top of this element
        end
        
        print(string.format("  [%d] %s: height=%d, gap=%d (eff:%d), bottom=%s, centerY=%s %s", 
            element.priority, element.name, height, element.gap, effectiveGap, tostring(bottom), tostring(centerY), status))
    end
    
    print("  Stack top:", currentY)
end
