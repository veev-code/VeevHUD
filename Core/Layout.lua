--[[
    VeevHUD - Layout Manager

    Centralized layout system for ALL HUD element positioning.

    All HUD elements (bars + icon rows) are stacked vertically in a
    user-configurable order. Each element registers with the layout manager
    and provides:
      - GetLayoutHeight(): returns the height this element needs (0 if hidden)
      - SetLayoutPosition(centerY): positions the element at the given Y offset

    The layout algorithm:
      1. Reads elementOrder from profile to determine stacking sequence
      2. Stacks elements downward from Y=0, applying per-element gaps
      3. Offsets the entire stack so Primary Row's top edge stays at a fixed
         Y position (PRIMARY_TOP_OFFSET), ensuring icon rows don't shift when
         bars above them appear or disappear

    Element keys (matching C.LAYOUT_ELEMENTS):
      auraTracker, auxiliaryRow, healthBar, resourceBar, comboPoints,
      swingBar, primaryRow, secondaryRow, utilityRow
]]

local _, addon = ...

local Layout = {}
addon.Layout = Layout

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------

-- Fixed Y position for Primary Row's top edge (relative to hudFrame center).
-- This value preserves backwards compatibility with the old layout where icon
-- rows started at approximately Y = -9.
local PRIMARY_TOP_OFFSET = -9

-------------------------------------------------------------------------------
-- Element Registry
-------------------------------------------------------------------------------

-- Registered layout elements
-- Key: element key (string), Value: { module, getHeight, setPosition }
Layout.elements = {}

-- Height/gap cache for skip-if-unchanged optimization
Layout._cachedHeights = {}
Layout._cachedGaps = {}
Layout._forceRefresh = false

--[[
    Register a layout element.

    @param key      Element key (must match a key in C.LAYOUT_ELEMENTS)
    @param module   Table with GetLayoutHeight() and SetLayoutPosition(centerY) methods
]]
function Layout:RegisterElement(key, module)
    self.elements[key] = {
        key = key,
        module = module,
    }
    addon.Utils:LogDebug("Layout: Registered element", key)
end

--[[
    Register an icon row element.
    Icon rows use function callbacks instead of module methods, since CooldownIcons
    manages all 3 rows and routes by row index.

    @param key        Element key ("primaryRow", "secondaryRow", "utilityRow", "auxiliaryRow")
    @param getHeight  Function() -> number (row pixel height, 0 if hidden)
    @param setPosition Function(topY) -> nil (position row at given Y offset)
]]
function Layout:RegisterRowElement(key, getHeight, setPosition)
    self.elements[key] = {
        key = key,
        getHeight = getHeight,
        setPosition = setPosition,
    }
    addon.Utils:LogDebug("Layout: Registered row element", key)
end

-------------------------------------------------------------------------------
-- Height / Position Dispatch
-------------------------------------------------------------------------------

-- Get the pixel height of a layout element (0 if hidden or unregistered)
function Layout:GetElementHeight(key)
    local elem = self.elements[key]
    if not elem then return 0 end

    -- Row elements use direct function callbacks
    if elem.getHeight then
        return elem.getHeight()
    end

    -- Bar elements use module methods
    local module = elem.module
    if module and module.GetLayoutHeight then
        return module:GetLayoutHeight()
    end

    return 0
end

-- Position a layout element at the given center Y offset
function Layout:SetElementPosition(key, centerY, topY)
    local elem = self.elements[key]
    if not elem then return end

    -- Row elements receive topY (they anchor from top edge)
    if elem.setPosition then
        elem.setPosition(topY)
        return
    end

    -- Bar elements receive centerY and topY
    local module = elem.module
    if module and module.SetLayoutPosition then
        module:SetLayoutPosition(centerY, topY)
    end
end

-------------------------------------------------------------------------------
-- Layout Calculation
-------------------------------------------------------------------------------

--[[
    Refresh all element positions.

    Called when any element's visibility changes, settings change, or
    element order is modified.

    Algorithm:
      1. Stack all visible elements downward from Y=0
      2. Compute offset to anchor Primary Row's top at PRIMARY_TOP_OFFSET
      3. Apply offset to all element positions
]]
function Layout:Refresh()
    if not addon.hudFrame then return end

    local db = addon.db and addon.db.profile
    if not db or not db.layout then return end

    local order = db.layout.elementOrder
    local gaps = db.layout.gaps
    if not order or not gaps then return end

    -- Gather current heights and check if anything changed since last refresh
    local heights = {}
    local anyChanged = self._forceRefresh
    for _, key in ipairs(order) do
        local h = self:GetElementHeight(key)
        heights[key] = h
        if not anyChanged then
            if self._cachedHeights[key] ~= h then anyChanged = true end
            if self._cachedGaps[key] ~= (gaps[key] or 0) then anyChanged = true end
        end
    end
    if not anyChanged then return end
    self._forceRefresh = false

    -- Phase 1: Collect visible elements and stack downward from Y=0
    local visible = {}
    local currentY = 0
    local primaryTopY = nil
    local visibleCount = 0
    local pendingGap = 0  -- max gap accumulated from hidden elements

    for _, key in ipairs(order) do
        local height = heights[key]
        if height > 0 then
            visibleCount = visibleCount + 1

            -- Apply gap: use the larger of this element's own gap and any
            -- hidden elements' gaps that were skipped above it
            local gap = 0
            if visibleCount > 1 then
                gap = math.max(gaps[key] or 0, pendingGap)
            end
            pendingGap = 0
            currentY = currentY - gap

            local topY = currentY
            local centerY = currentY - height / 2
            local bottomY = currentY - height

            table.insert(visible, {
                key = key,
                height = height,
                topY = topY,
                centerY = centerY,
                bottomY = bottomY,
            })

            -- Track primary row position for anchoring
            if key == "primaryRow" then
                primaryTopY = topY
            end

            currentY = bottomY
        else
            -- Element hidden: accumulate its gap for the next visible element
            pendingGap = math.max(pendingGap, gaps[key] or 0)
        end
    end

    -- Phase 2: Compute offset to anchor Primary Row at PRIMARY_TOP_OFFSET
    local offset = 0
    if primaryTopY then
        offset = PRIMARY_TOP_OFFSET - primaryTopY
    else
        -- Primary row not visible: center the entire stack at hudFrame center
        local stackHeight = -currentY  -- currentY is negative, so negate
        offset = stackHeight / 2
    end

    -- Phase 3: Apply positions with offset
    for _, elem in ipairs(visible) do
        self:SetElementPosition(elem.key, elem.centerY + offset, elem.topY + offset)
    end

    -- Phase 4: Toggle top border on skipTop bars based on adjacency
    -- Bars that use skipTop=true hide their top edge when a bar is directly
    -- above them (sharing a 1px separator). When no bar is above, they need
    -- to show their own top edge.
    local BAR_ELEMENTS = { healthBar = true, petHealthBar = true, resourceBar = true, comboPoints = true, swingBar = true }
    local prevIsBar = false
    for _, elem in ipairs(visible) do
        if BAR_ELEMENTS[elem.key] then
            local reg = self.elements[elem.key]
            local module = reg and reg.module
            if module and module.SetTopBorderShown then
                module:SetTopBorderShown(not prevIsBar)
            end
            prevIsBar = true
        else
            prevIsBar = false
        end
    end

    -- Update caches
    self._cachedHeights = heights
    for _, key in ipairs(order) do
        self._cachedGaps[key] = gaps[key] or 0
    end

    addon.Utils:LogDebug("Layout: Refreshed, elements:", visibleCount, "offset:", offset)
end

-- Force a layout refresh, bypassing height/gap caching.
-- Use for config changes where gaps may have changed without height changes.
function Layout:ForceRefresh()
    self._forceRefresh = true
    self:Refresh()
end

-------------------------------------------------------------------------------
-- Debug
-------------------------------------------------------------------------------

function Layout:PrintDebug()
    print("|cff00ff00VeevHUD Layout Debug:|r")
    print("  PRIMARY_TOP_OFFSET:", PRIMARY_TOP_OFFSET)

    local db = addon.db and addon.db.profile
    if not db or not db.layout then
        print("  |cffff0000No layout config found|r")
        return
    end

    local order = db.layout.elementOrder
    local gaps = db.layout.gaps

    -- Show ticker state if ResourceBar module exists
    local resourceBar = addon.ResourceBar
    if resourceBar then
        local tickerHeight = resourceBar.GetTickerHeight and resourceBar:GetTickerHeight() or 0
        local tickerVisible = resourceBar.ticker and resourceBar.ticker:IsShown()
        print("  Ticker: height=" .. tickerHeight .. ", visible=" .. tostring(tickerVisible or false))
    end

    -- Simulate the stacking algorithm
    local currentY = 0
    local primaryTopY = nil
    local visibleCount = 0
    local pendingGap = 0
    local allElements = {}

    for _, key in ipairs(order) do
        local height = self:GetElementHeight(key)
        local status = height > 0 and "|cff00ff00visible|r" or "|cff888888hidden|r"
        local gap = 0
        local topY, centerY

        if height > 0 then
            visibleCount = visibleCount + 1
            if visibleCount > 1 then
                gap = math.max(gaps[key] or 0, pendingGap)
            end
            pendingGap = 0
            currentY = currentY - gap
            topY = currentY
            centerY = currentY - height / 2
            if key == "primaryRow" then
                primaryTopY = topY
            end
            currentY = currentY - height
        else
            pendingGap = math.max(pendingGap, gaps[key] or 0)
        end

        table.insert(allElements, {
            key = key, height = height, gap = gap,
            topY = topY, centerY = centerY, status = status,
        })
    end

    local offset = 0
    if primaryTopY then
        offset = PRIMARY_TOP_OFFSET - primaryTopY
    else
        local stackHeight = -currentY
        offset = stackHeight / 2
    end

    print("  Offset:", offset, "(primaryTopY:", tostring(primaryTopY), ")")

    for i, elem in ipairs(allElements) do
        local finalCenter = elem.centerY and (elem.centerY + offset) or "n/a"
        local finalTop = elem.topY and (elem.topY + offset) or "n/a"
        print(string.format("  [%d] %s: height=%d, gap=%d, top=%s, center=%s %s",
            i, elem.key, elem.height, elem.gap,
            tostring(finalTop), tostring(finalCenter), elem.status))
    end

    print("  Stack bottom:", currentY + offset)
end
