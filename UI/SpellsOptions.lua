--[[
    VeevHUD - Spells Options Panel
    Allows users to enable/disable spells, reorder them, and move between rows.
    
    Key features:
    - Per-spec configuration (sparse storage)
    - Visual highlighting for modified spells (gold asterisk)
    - Per-spell reset to default (right-click)
    - Drag-and-drop reordering within and between rows
]]

local ADDON_NAME, addon = ...

local SpellsOptions = {}
addon.SpellsOptions = SpellsOptions

-- UI constants
local SPELL_ENTRY_HEIGHT = 28
local ICON_SIZE = 24
local ROW_HEADER_HEIGHT = 30
local AVAILABLE_ROW_INDEX = 99  -- Special row index for untracked spells

-- Drag state
SpellsOptions.dragState = nil
SpellsOptions.ghostFrame = nil
SpellsOptions.dropIndicator = nil
SpellsOptions.spellEntries = {}  -- All spell entry frames for drop detection

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function SpellsOptions:Initialize()
    -- Wait for Settings API and main Options to be ready
    if not Settings or not Settings.RegisterCanvasLayoutSubcategory then
        return
    end
    
    -- Delay initialization until Options panel is ready
    C_Timer.After(0.5, function()
        local success, err = pcall(function()
            self:CreatePanel()
        end)
        if not success and addon.Utils then
            addon.Utils:LogError("SpellsOptions: CreatePanel error:", err)
        end
    end)
end

function SpellsOptions:CreatePanel()
    local mainOptions = addon.Options
    if not mainOptions or not mainOptions.category then
        addon.Utils:LogInfo("Main options category not ready, retrying...")
        C_Timer.After(1, function() self:CreatePanel() end)
        return
    end
    
    -- Create panel frame
    local panel = CreateFrame("Frame")
    panel.name = "Spells"
    self.panel = panel
    
    -- Title
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Spell Configuration")
    
    -- Subtitle with spec info (set placeholder text so it has dimensions for anchoring)
    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    subtitle:SetText("Loading...")  -- Placeholder, will be updated
    subtitle:SetTextColor(0.6, 0.6, 0.6)
    self.subtitleText = subtitle
    
    -- Description/Help text (single line, hover for details)
    local descFrame = CreateFrame("Frame", nil, panel)
    descFrame:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -8)
    descFrame:SetSize(400, 16)
    
    local description = descFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    description:SetPoint("LEFT", 0, 0)
    description:SetText("Customize which spells appear on your HUD and their order. |cff888888[?]|r")
    
    descFrame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Spell Configuration", 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Check/uncheck to show or hide spells", 1, 0.82, 0)
        GameTooltip:AddLine("Drag :: to reorder spells within a row", 1, 0.82, 0)
        GameTooltip:AddLine("Drag spells between rows to move them", 1, 0.82, 0)
        GameTooltip:AddLine("Drag from Available to enable additional spells", 1, 0.82, 0)
        GameTooltip:AddLine("Right-click any modified spell to reset it", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    descFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    self.descriptionText = description
    self.descFrame = descFrame
    
    -- Legend
    local legend = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    legend:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -16)
    legend:SetText("|cffffd200*|r = Modified (Right-click to reset)")
    legend:SetTextColor(0.7, 0.7, 0.7)
    
    -- Instructions
    local instructions = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    instructions:SetPoint("TOPRIGHT", legend, "BOTTOMRIGHT", 0, -2)
    instructions:SetText("Drag |cffffffff::|r to reorder")
    instructions:SetTextColor(0.5, 0.5, 0.5)
    
    -- Reset Spells Button
    local resetSpellsButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetSpellsButton:SetPoint("TOPRIGHT", instructions, "BOTTOMRIGHT", 0, -8)
    resetSpellsButton:SetSize(160, 22)
    resetSpellsButton:SetText("Reset Spell Config")
    resetSpellsButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Reset Spell Configuration", 1, 1, 1)
        GameTooltip:AddLine("Resets all spell visibility and ordering", 1, 0.82, 0, true)
        GameTooltip:AddLine("for your current spec to defaults.", 1, 0.82, 0, true)
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("Current spec: " .. (SpellsOptions:GetSpecKey():gsub("_", " ")), 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    resetSpellsButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    resetSpellsButton:SetScript("OnClick", function()
        local specKey = SpellsOptions:GetSpecKey()
        StaticPopupDialogs["VEEVHUD_RESET_SPELLS_CONFIRM"] = {
            text = "Reset all spell configuration for " .. specKey:gsub("_", " ") .. " to defaults?",
            button1 = "Yes",
            button2 = "No",
            OnAccept = function()
                -- Clear all spellConfig for current spec
                if VeevHUDDB and VeevHUDDB.overrides and VeevHUDDB.overrides.spellConfig then
                    VeevHUDDB.overrides.spellConfig[specKey] = nil
                    -- Clean up empty parent if needed
                    if next(VeevHUDDB.overrides.spellConfig) == nil then
                        VeevHUDDB.overrides.spellConfig = nil
                    end
                end
                
                -- Rebuild live profile and refresh
                addon.Database:RebuildLiveProfile()
                
                local spellTracker = addon:GetModule("SpellTracker")
                if spellTracker then
                    spellTracker:FullRescan()
                end
                
                -- Force reposition rows after spell changes
                -- (delayed slightly to ensure all icon updates are complete)
                C_Timer.After(0.05, function()
                    local cooldownIcons = addon:GetModule("CooldownIcons")
                    if cooldownIcons and cooldownIcons.RepositionRows then
                        cooldownIcons:RepositionRows()
                    end
                end)
                
                SpellsOptions:RefreshSpellList()
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
        }
        StaticPopup_Show("VEEVHUD_RESET_SPELLS_CONFIRM")
    end)
    
    -- Create scroll frame (positioned below the description)
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", descFrame, "BOTTOMLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 10)
    self.resetSpellsButton = resetSpellsButton
    
    -- Scroll child (content container) - needs to be parented and sized properly
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(500)  -- Default width, will be updated on show
    scrollChild:SetHeight(1)   -- Will be updated after content is added
    scrollFrame:SetScrollChild(scrollChild)
    
    self.scrollFrame = scrollFrame
    self.scrollChild = scrollChild
    
    -- Create ghost frame for dragging
    self:CreateGhostFrame()
    
    -- Create drop indicator
    self:CreateDropIndicator()
    
    -- Register as subcategory
    local subcategory = Settings.RegisterCanvasLayoutSubcategory(mainOptions.category, panel, "Spells")
    self.category = subcategory
    
    -- Track the detected spec to know when to refresh
    local lastDetectedSpec = nil
    local lastRefreshTime = 0
    
    -- Helper function to refresh the spell list with spec detection
    local function DoRefresh()
        -- Set scroll child width
        local width = scrollFrame:GetWidth()
        if width and width > 0 then
            scrollChild:SetWidth(width - 10)
        else
            scrollChild:SetWidth(500)
        end
        
        -- Re-detect spec
        if addon.LibSpellDB then
            local newSpec = addon.LibSpellDB:DetectPlayerSpec()
            addon.playerSpec = newSpec
        end
        
        SpellsOptions:RefreshSpellList()
        lastDetectedSpec = addon.playerSpec
        lastRefreshTime = GetTime()
    end
    
    -- Refresh when panel becomes visible or spec changes
    panel:SetScript("OnShow", function(self)
        -- Small delay to ensure spec detection has run after talent changes
        C_Timer.After(0.1, function()
            if self:IsVisible() and SpellsOptions.scrollChild then
                DoRefresh()
            end
        end)
    end)
    
    if addon.Utils then
        addon.Utils:LogInfo("Spells options panel registered")
    end
    
    -- If panel is already visible (opened before CreatePanel finished), refresh now
    if panel:IsVisible() then
        C_Timer.After(0.1, function()
            DoRefresh()
        end)
    end
end

-------------------------------------------------------------------------------
-- Spec Key Helper
-------------------------------------------------------------------------------

function SpellsOptions:GetSpecKey()
    return addon:GetSpecKey()
end

function SpellsOptions:GetSpellConfig(spellID)
    return addon:GetSpellConfigForSpell(spellID)
end

function SpellsOptions:IsSpellModified(spellID)
    return addon:IsSpellConfigModified(spellID)
end

-------------------------------------------------------------------------------
-- Override Management
-------------------------------------------------------------------------------

function SpellsOptions:SetSpellOverride(spellID, field, value)
    -- Get default value to compare - if value matches default, clear the override
    local defaultValue = self:GetDefaultValue(spellID, field)
    
    if value == defaultValue then
        value = nil
    end
    
    addon:SetSpellConfigOverride(spellID, field, value)
    
    -- Trigger refresh
    local spellTracker = addon:GetModule("SpellTracker")
    if spellTracker then
        spellTracker:FullRescan()
    end
    
    -- Force reposition rows after spell changes
    -- (delayed slightly to ensure all icon updates are complete)
    C_Timer.After(0.05, function()
        local cooldownIcons = addon:GetModule("CooldownIcons")
        if cooldownIcons and cooldownIcons.RepositionRows then
            cooldownIcons:RepositionRows()
        end
    end)
end

function SpellsOptions:ResetSpell(spellID)
    addon:ClearSpellConfigOverride(spellID)
    
    -- IMPORTANT: Rescan FIRST to update trackedSpells, THEN refresh UI
    local spellTracker = addon:GetModule("SpellTracker")
    if spellTracker then
        spellTracker:FullRescan()
    end
    
    self:RefreshSpellList()
end

function SpellsOptions:GetDefaultValue(spellID, field)
    -- Get the INHERENT default (without considering user overrides)
    -- This should NOT change based on current tracked state
    if field == "enabled" then
        -- A spell is enabled by default if:
        -- 1. It has a default row assignment (spec-relevant and matches row tags)
        -- 2. It would NOT be excluded by SpellTracker (not FILLER, OUT_OF_COMBAT, etc.)
        local cooldownIcons = addon:GetModule("CooldownIcons")
        if cooldownIcons and cooldownIcons.GetDefaultRowForSpell then
            local defaultRow = cooldownIcons:GetDefaultRowForSpell(spellID)
            if defaultRow then
                -- Also check if spell would be excluded by SpellTracker
                -- (FILLER spells with no CD, OUT_OF_COMBAT, LONG_BUFF, etc.)
                local spellTracker = addon:GetModule("SpellTracker")
                if spellTracker and spellTracker.ShouldExcludeSpell then
                    local spellData = addon.LibSpellDB and addon.LibSpellDB:GetSpellInfo(spellID)
                    if spellData and spellTracker:ShouldExcludeSpell(spellData) then
                        return false  -- Would be excluded by default, so default enabled = false
                    end
                end
                return true  -- Spec-relevant spell and not excluded, enabled by default
            end
        end
        return false  -- Not spec-relevant, disabled by default (Available section)
    elseif field == "rowIndex" then
        -- Get from CooldownIcons default assignment
        local cooldownIcons = addon:GetModule("CooldownIcons")
        if cooldownIcons and cooldownIcons.GetDefaultRowForSpell then
            local defaultRow = cooldownIcons:GetDefaultRowForSpell(spellID)
            if defaultRow then
                return defaultRow
            end
        end
        return AVAILABLE_ROW_INDEX  -- Default to available section if no row
    elseif field == "order" then
        return nil  -- Default is nil (use priority-based sorting)
    end
    return nil
end

-------------------------------------------------------------------------------
-- Build Spell List
-------------------------------------------------------------------------------

function SpellsOptions:RefreshSpellList()
    if not self.scrollChild then return end
    
    -- Update subtitle with spec info
    local specKey = self:GetSpecKey()
    if self.subtitleText then
        self.subtitleText:SetText("Current spec: " .. specKey:gsub("_", " "))
    end
    
    -- Clear existing content (children/frames)
    for _, child in ipairs({self.scrollChild:GetChildren()}) do
        child:Hide()
        child:SetParent(nil)
    end
    
    -- Clear existing fontstrings/regions (they aren't children)
    for _, region in ipairs({self.scrollChild:GetRegions()}) do
        region:Hide()
        region:SetParent(nil)
    end
    
    wipe(self.spellEntries)
    
    -- Get spell data organized by row
    local rowSpells = self:GetEffectiveSpellList()
    
    -- Count total spells
    local totalSpells = 0
    for _, spells in pairs(rowSpells) do
        totalSpells = totalSpells + #spells
    end
    
    -- Build content
    local yOffset = 0
    local rowConfigs = addon.db.profile.rows or {}
    
    if totalSpells == 0 then
        -- Show message when no spells are found
        local noSpellsMsg = self.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        noSpellsMsg:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 0, yOffset)
        noSpellsMsg:SetText("|cff888888No spells found for this spec.|r\n\nMake sure you're logged in and have abilities learned.")
        noSpellsMsg:SetJustifyH("LEFT")
        yOffset = yOffset - 60
    else
        -- Display the 3 main rows
        for rowIndex, rowConfig in ipairs(rowConfigs) do
            local spells = rowSpells[rowIndex]
            if spells and #spells > 0 then
                -- Row header
                yOffset = self:CreateRowHeader(rowIndex, rowConfig.name, yOffset)
                
                -- Spell entries
                for i, spellInfo in ipairs(spells) do
                    yOffset = self:CreateSpellEntry(spellInfo, rowIndex, i, yOffset)
                end
                
                yOffset = yOffset - 8  -- Gap between rows
            end
        end
        
        -- Display "Available" section (untracked spells the player knows)
        local availableSpells = rowSpells[AVAILABLE_ROW_INDEX]
        if availableSpells and #availableSpells > 0 then
            yOffset = yOffset - 12  -- Extra gap before available section
            yOffset = self:CreateRowHeader(AVAILABLE_ROW_INDEX, "Available (Drag to Enable)", yOffset)
            
            -- Add description
            local availDesc = self.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
            availDesc:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 10, yOffset)
            availDesc:SetText("|cff888888Spells you know but aren't tracked. Drag to a row above to enable.|r")
            availDesc:SetWidth(450)
            availDesc:SetJustifyH("LEFT")
            yOffset = yOffset - 16
            
            for i, spellInfo in ipairs(availableSpells) do
                yOffset = self:CreateSpellEntry(spellInfo, AVAILABLE_ROW_INDEX, i, yOffset)
            end
        end
    end
    
    -- Set scroll child height
    self.scrollChild:SetHeight(math.abs(yOffset) + 20)
end

function SpellsOptions:GetEffectiveSpellList()
    local spellCfg = addon:GetSpellConfig()
    local rows = {}
    
    local spellTracker = addon:GetModule("SpellTracker")
    local cooldownIcons = addon:GetModule("CooldownIcons")
    
    -- Get tracked spells from SpellTracker
    local trackedSpells = {}
    if spellTracker and spellTracker.trackedSpells then
        trackedSpells = spellTracker.trackedSpells
    elseif spellTracker and spellTracker.GetTrackedSpells then
        trackedSpells = spellTracker:GetTrackedSpells() or {}
    end
    
    -- Build set of all spell IDs that are currently displayed (tracked or user-configured)
    -- SpellTracker now stores by canonical ID, so this is straightforward
    local displayedSpellIDs = {}
    for spellID, _ in pairs(trackedSpells) do
        displayedSpellIDs[spellID] = true
    end
    for spellID, cfg in pairs(spellCfg) do
        -- Include spells the user has configured (even if disabled)
        if cfg.enabled ~= nil or cfg.rowIndex ~= nil or cfg.order ~= nil then
            displayedSpellIDs[spellID] = true
        end
    end
    
    -- If we have no spells from SpellTracker, try to get them directly from CooldownIcons
    if next(displayedSpellIDs) == nil and cooldownIcons and cooldownIcons.iconsByRow then
        for rowIndex, spellList in pairs(cooldownIcons.iconsByRow) do
            for _, spellInfo in ipairs(spellList) do
                if spellInfo.spellID then
                    displayedSpellIDs[spellInfo.spellID] = true
                end
            end
        end
    end
    
    -- Process displayed spells (rows 1-3)
    for spellID, _ in pairs(displayedSpellIDs) do
        local tracked = trackedSpells[spellID]
        local cfg = spellCfg[spellID] or {}
        
        -- Get spell data from tracked or LibSpellDB
        local spellData = tracked and tracked.spellData
        if not spellData and addon.LibSpellDB then
            spellData = addon.LibSpellDB:GetSpellInfo(spellID)
        end
        
        if spellData then
            -- Determine effective row
            local defaultRow = nil
            if cooldownIcons and cooldownIcons.GetDefaultRowForSpell then
                defaultRow = cooldownIcons:GetDefaultRowForSpell(spellID)
            end
            local effectiveRow = cfg.rowIndex or defaultRow or 1
            
            -- Determine enabled state:
            -- - If spell is tracked (in trackedSpells), it's enabled unless explicitly disabled
            -- - If spell is NOT tracked (only has config overrides), it's disabled unless explicitly enabled
            local isTracked = tracked ~= nil
            local enabled
            if isTracked then
                enabled = cfg.enabled ~= false  -- nil or true = enabled for tracked spells
            else
                enabled = cfg.enabled == true  -- Must be explicitly enabled for non-tracked spells
            end
            
            rows[effectiveRow] = rows[effectiveRow] or {}
            table.insert(rows[effectiveRow], {
                spellID = spellID,
                spellData = spellData,
                enabled = enabled,
                rowIndex = effectiveRow,
                defaultRow = defaultRow,
                order = cfg.order,
                isModified = (cfg.enabled ~= nil or cfg.rowIndex ~= nil or cfg.order ~= nil),
                isAvailable = (defaultRow == nil),  -- Available if no default row (not spec-relevant)
            })
        end
    end
    
    -- Now find "available" spells - known spells not currently displayed
    -- These are ALL class spells the player knows but aren't tracked by default
    -- This includes off-spec abilities, out-of-combat spells, fillers, etc.
    if addon.LibSpellDB and spellTracker then
        local playerClass = addon.playerClass
        -- Use GetSpellsByClass to get ALL class spells, not just spec-relevant ones
        local allClassSpells = addon.LibSpellDB:GetSpellsByClass(playerClass) or {}
        
        local availableCount = 0
        local knownCount = 0
        
        for spellID, spellData in pairs(allClassSpells) do
            -- Skip if already displayed
            if not displayedSpellIDs[spellID] then
                -- Check if player knows this spell
                if spellTracker:IsSpellKnown(spellID, spellData) then
                    -- Skip spells blocked by shared cooldown (e.g., Shield Wall when Recklessness is tracked)
                    -- These are hidden entirely rather than shown as greyed out
                    local isBlocked = self:IsBlockedBySharedCooldown(spellID)
                    if not isBlocked then
                        knownCount = knownCount + 1
                        availableCount = availableCount + 1
                        -- Check if user has configured it to a specific row
                        local cfg = spellCfg[spellID] or {}
                        local effectiveRow = cfg.rowIndex or AVAILABLE_ROW_INDEX
                        local enabled = cfg.enabled == true  -- Must be explicitly enabled
                        
                        rows[effectiveRow] = rows[effectiveRow] or {}
                        table.insert(rows[effectiveRow], {
                            spellID = spellID,
                            spellData = spellData,
                            enabled = enabled,
                            rowIndex = effectiveRow,
                            defaultRow = AVAILABLE_ROW_INDEX,  -- Default is available section
                            order = cfg.order,
                            isModified = (cfg.enabled ~= nil or cfg.rowIndex ~= nil or cfg.order ~= nil),
                            isAvailable = (effectiveRow == AVAILABLE_ROW_INDEX),  -- True if in available section
                        })
                    end
                end
            end
        end
        
    end
    
    -- Sort each row: first by priority/cooldown to establish default order, then apply custom orders
    for rowIndex, spells in pairs(rows) do
        -- First sort: establish natural order by priority, then cooldown, then spellID (for stability)
        table.sort(spells, function(a, b)
            local prioA = a.spellData.priority or 999
            local prioB = b.spellData.priority or 999
            if prioA ~= prioB then
                return prioA < prioB
            end
            local cdA = a.spellData.cooldown or 0
            local cdB = b.spellData.cooldown or 0
            if cdA ~= cdB then
                return cdA < cdB
            end
            -- Tie-breaker: spellID for stable sorting
            return a.spellID < b.spellID
        end)
        
        -- Assign default order indices based on natural sort
        for i, spell in ipairs(spells) do
            spell.defaultOrder = i
        end
        
        -- Second sort: apply custom order overrides
        table.sort(spells, function(a, b)
            local orderA = a.order or a.defaultOrder
            local orderB = b.order or b.defaultOrder
            return orderA < orderB
        end)
    end
    
    return rows
end

-------------------------------------------------------------------------------
-- UI Creators
-------------------------------------------------------------------------------

function SpellsOptions:CreateRowHeader(rowIndex, name, yOffset)
    local frame = CreateFrame("Frame", nil, self.scrollChild)
    frame:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 0, yOffset)
    frame:SetSize(500, ROW_HEADER_HEIGHT)
    frame.rowIndex = rowIndex
    frame.isRowHeader = true
    
    -- Left separator line
    local leftLine = frame:CreateTexture(nil, "ARTWORK")
    leftLine:SetHeight(1)
    leftLine:SetPoint("LEFT", 0, 0)
    leftLine:SetPoint("RIGHT", frame, "LEFT", 60, 0)
    leftLine:SetColorTexture(0.6, 0.5, 0.2, 0.8)
    
    -- Header text
    local header = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("LEFT", leftLine, "RIGHT", 8, 0)
    header:SetText(name or "Row " .. rowIndex)
    header:SetTextColor(1, 0.82, 0)
    
    -- Right separator line
    local rightLine = frame:CreateTexture(nil, "ARTWORK")
    rightLine:SetHeight(1)
    rightLine:SetPoint("LEFT", header, "RIGHT", 8, 0)
    rightLine:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    rightLine:SetColorTexture(0.6, 0.5, 0.2, 0.8)
    
    -- Highlight for drag hover
    frame.highlight = frame:CreateTexture(nil, "BACKGROUND")
    frame.highlight:SetAllPoints()
    frame.highlight:SetColorTexture(1, 0.82, 0, 0.1)
    frame.highlight:Hide()
    
    frame:Show()  -- Explicitly show
    
    -- Store for drag detection
    table.insert(self.spellEntries, frame)
    
    return yOffset - ROW_HEADER_HEIGHT
end

function SpellsOptions:CreateSpellEntry(spellInfo, rowIndex, index, yOffset)
    local frame = CreateFrame("Frame", nil, self.scrollChild)
    frame:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 10, yOffset)
    frame:SetSize(480, SPELL_ENTRY_HEIGHT)
    frame:EnableMouse(true)
    frame:Show()  -- Explicitly show
    
    -- Store spell info
    frame.spellID = spellInfo.spellID
    frame.spellInfo = spellInfo
    frame.rowIndex = rowIndex
    frame.index = index
    frame.isSpellEntry = true
    
    -- Background (for hover/selection)
    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetAllPoints()
    frame.bg:SetColorTexture(0.1, 0.1, 0.1, 0.3)
    frame.bg:Hide()
    
    -- Drop indicator highlight
    frame.dropHighlight = frame:CreateTexture(nil, "OVERLAY")
    frame.dropHighlight:SetPoint("TOPLEFT", 0, 2)
    frame.dropHighlight:SetPoint("TOPRIGHT", 0, 2)
    frame.dropHighlight:SetHeight(2)
    frame.dropHighlight:SetColorTexture(0.3, 0.6, 1, 1)
    frame.dropHighlight:Hide()
    
    -- Icon
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("LEFT", 0, 0)
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    local spellName, _, spellIcon = GetSpellInfo(spellInfo.spellID)
    icon:SetTexture(spellIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
    frame.icon = icon
    
    -- Name with modified indicator
    local nameText = spellName or ("Spell " .. spellInfo.spellID)
    if spellInfo.isModified then
        nameText = "|cffffd200*|r " .. nameText
    end
    
    local name = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    name:SetText(nameText)
    name:SetWidth(200)
    name:SetJustifyH("LEFT")
    frame.nameText = name
    
    -- Grey out if disabled
    if not spellInfo.enabled then
        icon:SetDesaturated(true)
        icon:SetAlpha(0.5)
        name:SetTextColor(0.5, 0.5, 0.5)
    end
    
    -- Checkbox (enable/disable)
    local checkbox = CreateFrame("CheckButton", nil, frame, "InterfaceOptionsCheckButtonTemplate")
    checkbox:SetPoint("LEFT", name, "RIGHT", 8, 0)
    checkbox:SetChecked(spellInfo.enabled)
    checkbox.Text:SetText("")  -- No text on checkbox
    
    checkbox:SetScript("OnClick", function(self)
        local enabled = self:GetChecked()
        
        SpellsOptions:SetSpellOverride(spellInfo.spellID, "enabled", enabled)
        
        -- If enabling a spell from the Available section, move it to its default row
        -- BUT only if it doesn't already have a rowIndex override (user previously configured it)
        if enabled and spellInfo.isAvailable then
            local cfg = addon:GetSpellConfigForSpell(spellInfo.spellID)
            if cfg.rowIndex == nil then
                -- No existing row override, assign to default row
                local cooldownIcons = addon:GetModule("CooldownIcons")
                local defaultRow = 3  -- Default to Utility for non-spec-relevant spells
                if cooldownIcons and cooldownIcons.GetDefaultRowForSpell then
                    defaultRow = cooldownIcons:GetDefaultRowForSpell(spellInfo.spellID) or 3
                end
                SpellsOptions:SetSpellOverride(spellInfo.spellID, "rowIndex", defaultRow)
            end
        end
        
        SpellsOptions:RefreshSpellList()
    end)
    frame.checkbox = checkbox
    
    -- Drag handle (use simple :: symbol that renders in all fonts)
    local dragHandle = CreateFrame("Button", nil, frame)
    dragHandle:SetPoint("LEFT", checkbox, "RIGHT", 8, 0)
    dragHandle:SetSize(20, 20)
    
    local dragText = dragHandle:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    dragText:SetPoint("CENTER")
    dragText:SetText("::") -- Simple drag handle indicator
    dragText:SetTextColor(0.6, 0.6, 0.6)
    
    dragHandle:SetScript("OnEnter", function(self)
        dragText:SetTextColor(1, 1, 1)
        frame.bg:Show()
    end)
    dragHandle:SetScript("OnLeave", function(self)
        dragText:SetTextColor(0.6, 0.6, 0.6)
        frame.bg:Hide()
    end)
    
    -- Drag functionality
    dragHandle:RegisterForDrag("LeftButton")
    dragHandle:SetScript("OnDragStart", function()
        SpellsOptions:StartDrag(frame)
    end)
    dragHandle:SetScript("OnDragStop", function()
        SpellsOptions:EndDrag()
    end)
    frame.dragHandle = dragHandle
    
    -- Right-click to reset
    frame:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            SpellsOptions:ResetSpell(spellInfo.spellID)
        end
    end)
    
    -- Hover effects
    frame:SetScript("OnEnter", function(self)
        self.bg:Show()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(spellInfo.spellID)
        if spellInfo.isModified then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cffffd200Modified|r - Right-click to reset", 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function(self)
        self.bg:Hide()
        GameTooltip:Hide()
    end)
    
    -- Store for drag detection
    table.insert(self.spellEntries, frame)
    
    return yOffset - SPELL_ENTRY_HEIGHT
end

-------------------------------------------------------------------------------
-- Drag and Drop
-------------------------------------------------------------------------------

function SpellsOptions:CreateGhostFrame()
    local ghost = CreateFrame("Frame", nil, UIParent)
    ghost:SetSize(300, SPELL_ENTRY_HEIGHT)
    ghost:SetFrameStrata("TOOLTIP")
    ghost:SetAlpha(0.7)
    ghost:Hide()
    
    ghost.bg = ghost:CreateTexture(nil, "BACKGROUND")
    ghost.bg:SetAllPoints()
    ghost.bg:SetColorTexture(0.2, 0.4, 0.6, 0.8)
    
    ghost.icon = ghost:CreateTexture(nil, "ARTWORK")
    ghost.icon:SetPoint("LEFT", 4, 0)
    ghost.icon:SetSize(ICON_SIZE, ICON_SIZE)
    
    ghost.name = ghost:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    ghost.name:SetPoint("LEFT", ghost.icon, "RIGHT", 8, 0)
    
    self.ghostFrame = ghost
end

function SpellsOptions:CreateDropIndicator()
    local indicator = CreateFrame("Frame", nil, UIParent)
    indicator:SetSize(400, 3)
    indicator:SetFrameStrata("TOOLTIP")
    indicator:Hide()
    
    indicator.line = indicator:CreateTexture(nil, "ARTWORK")
    indicator.line:SetAllPoints()
    indicator.line:SetColorTexture(0.3, 0.6, 1, 1)
    
    self.dropIndicator = indicator
end

function SpellsOptions:StartDrag(frame)
    if not frame.spellInfo then return end
    
    self.dragState = {
        sourceFrame = frame,
        spellID = frame.spellID,
        spellInfo = frame.spellInfo,
        sourceRow = frame.rowIndex,
        sourceIndex = frame.index,
    }
    
    -- Setup ghost frame
    local spellName, _, spellIcon = GetSpellInfo(frame.spellID)
    self.ghostFrame.icon:SetTexture(spellIcon)
    self.ghostFrame.name:SetText(spellName or "Unknown")
    self.ghostFrame:Show()
    
    -- Start update loop
    self.ghostFrame:SetScript("OnUpdate", function()
        SpellsOptions:UpdateDrag()
    end)
    
    -- Dim source
    frame:SetAlpha(0.3)
end

function SpellsOptions:UpdateDrag()
    if not self.dragState then return end
    
    -- Move ghost to cursor
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    self.ghostFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    
    -- Find drop target
    local dropTarget, dropIndex, dropRow, insertAfter = self:FindDropTarget()
    
    -- Update drop indicator
    if dropTarget then
        self.dropIndicator:ClearAllPoints()
        
        if dropTarget.isRowHeader then
            -- Dropping into a row (at the end)
            self.dropIndicator:SetPoint("TOPLEFT", dropTarget, "BOTTOMLEFT", 10, 0)
            self.dropIndicator:SetPoint("TOPRIGHT", dropTarget, "BOTTOMRIGHT", -10, 0)
            dropTarget.highlight:Show()
        elseif insertAfter then
            -- Dropping after this spell (indicator at bottom)
            self.dropIndicator:SetPoint("BOTTOMLEFT", dropTarget, "BOTTOMLEFT", 0, -2)
            self.dropIndicator:SetPoint("BOTTOMRIGHT", dropTarget, "BOTTOMRIGHT", 0, -2)
        else
            -- Dropping before this spell (indicator at top)
            self.dropIndicator:SetPoint("TOPLEFT", dropTarget, "TOPLEFT", 0, 2)
            self.dropIndicator:SetPoint("TOPRIGHT", dropTarget, "TOPRIGHT", 0, 2)
        end
        
        self.dropIndicator:Show()
        
        self.dragState.dropTarget = dropTarget
        self.dragState.dropRow = dropRow
        self.dragState.dropIndex = dropIndex
    else
        self.dropIndicator:Hide()
        self.dragState.dropTarget = nil
        
        -- Clear row header highlights
        for _, entry in ipairs(self.spellEntries) do
            if entry.isRowHeader and entry.highlight then
                entry.highlight:Hide()
            end
        end
    end
end

function SpellsOptions:FindDropTarget()
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    x, y = x / scale, y / scale
    
    for _, entry in ipairs(self.spellEntries) do
        if entry:IsVisible() then
            local left = entry:GetLeft()
            local right = entry:GetRight()
            local top = entry:GetTop()
            local bottom = entry:GetBottom()
            
            if left and x >= left and x <= right and y >= bottom and y <= top then
                if entry.isRowHeader then
                    return entry, 999, entry.rowIndex, false  -- 999 = end of row
                else
                    -- Check if cursor is in top half or bottom half of the entry
                    -- Top half = insert before (at entry.index)
                    -- Bottom half = insert after (at entry.index + 1)
                    local midY = (top + bottom) / 2
                    local insertAfter = (y < midY)  -- Below midpoint = insert after
                    local targetIndex = insertAfter and (entry.index + 1) or entry.index
                    return entry, targetIndex, entry.rowIndex, insertAfter
                end
            end
        end
    end
    
    return nil
end

function SpellsOptions:EndDrag()
    if not self.dragState then return end
    
    -- Hide visuals
    self.ghostFrame:Hide()
    self.ghostFrame:SetScript("OnUpdate", nil)
    self.dropIndicator:Hide()
    
    -- Restore source alpha
    if self.dragState.sourceFrame then
        self.dragState.sourceFrame:SetAlpha(1)
    end
    
    -- Clear row header highlights
    for _, entry in ipairs(self.spellEntries) do
        if entry.isRowHeader and entry.highlight then
            entry.highlight:Hide()
        end
    end
    
    -- Apply drop
    if self.dragState.dropTarget then
        local spellID = self.dragState.spellID
        local newRow = self.dragState.dropRow
        local newIndex = self.dragState.dropIndex
        local sourceRow = self.dragState.sourceRow
        local sourceIndex = self.dragState.sourceIndex
        
        -- Check if anything actually changed (avoid no-op modifications)
        local rowChanged = newRow ~= sourceRow
        
        -- For order change detection: dropping above or below yourself is a no-op
        -- newIndex is where the spell would be inserted (before which position)
        -- If dropped at position sourceIndex or sourceIndex+1 in the same row, it's a no-op
        local orderChanged = true
        if not rowChanged then
            if newIndex == sourceIndex or newIndex == sourceIndex + 1 then
                orderChanged = false
            end
        end
        
        if not rowChanged and not orderChanged then
            -- No actual change, don't save anything
            self.dragState = nil
            return
        end
        
        -- If dragging from Available section to a main row, enable the spell
        if sourceRow == AVAILABLE_ROW_INDEX and newRow ~= AVAILABLE_ROW_INDEX then
            self:SetSpellOverride(spellID, "enabled", true)
            self:SetSpellOverride(spellID, "rowIndex", newRow)
        -- If dragging to Available section, disable the spell
        elseif newRow == AVAILABLE_ROW_INDEX and sourceRow ~= AVAILABLE_ROW_INDEX then
            self:SetSpellOverride(spellID, "enabled", false)
            self:SetSpellOverride(spellID, "rowIndex", nil)  -- Clear row override
        -- Row changed within main rows
        elseif rowChanged then
            self:SetSpellOverride(spellID, "rowIndex", newRow)
        end
        
        -- Update order (skip for Available section as order doesn't matter there)
        if newRow ~= AVAILABLE_ROW_INDEX and (orderChanged or rowChanged) then
            -- Calculate new order value based on position
            -- IMPORTANT: Filter out the dragged spell from rowSpells since it's already been added
            local allRowSpells = self:GetEffectiveSpellList()[newRow] or {}
            local rowSpells = {}
            local draggedSpellPositionInTargetRow = nil
            for i, spell in ipairs(allRowSpells) do
                if spell.spellID ~= spellID then
                    table.insert(rowSpells, spell)
                else
                    draggedSpellPositionInTargetRow = i
                end
            end
            
            -- Adjust newIndex ONLY when dragging within the SAME row
            -- Since we removed the source spell, indices after it shifted down by 1
            local adjustedIndex = newIndex
            if not rowChanged and draggedSpellPositionInTargetRow and draggedSpellPositionInTargetRow < newIndex then
                adjustedIndex = newIndex - 1
            end
            
            if newIndex == 999 or adjustedIndex > #rowSpells then
                -- Dropped at end of row
                local maxOrder = 0
                for _, spell in ipairs(rowSpells) do
                    local order = spell.order or spell.defaultOrder or 0
                    if order > maxOrder then maxOrder = order end
                end
                self:SetSpellOverride(spellID, "order", maxOrder + 1)
            elseif adjustedIndex <= 1 then
                -- Dropped at start
                local firstSpell = rowSpells[1]
                local firstOrder = firstSpell and (firstSpell.order or firstSpell.defaultOrder or 1) or 1
                local newOrder = firstOrder - 0.5
                self:SetSpellOverride(spellID, "order", newOrder)
            else
                -- Dropped between spells - calculate midpoint
                local prevSpell = rowSpells[adjustedIndex - 1]
                local nextSpell = rowSpells[adjustedIndex]
                
                local prevOrder = prevSpell and (prevSpell.order or prevSpell.defaultOrder or adjustedIndex - 1) or 0
                local nextOrder = nextSpell and (nextSpell.order or nextSpell.defaultOrder or adjustedIndex) or prevOrder + 2
                
                local newOrder = (prevOrder + nextOrder) / 2
                self:SetSpellOverride(spellID, "order", newOrder)
            end
        end
    end
    
    self.dragState = nil
    
    -- Refresh the list after brief delay for spell tracker to update
    C_Timer.After(0.05, function()
        self:RefreshSpellList()
    end)
end

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------

-- Check if a spell is blocked by shared cooldown (another spell in its group is already enabled)
-- Returns: isBlocked, blockingSpellName
function SpellsOptions:IsBlockedBySharedCooldown(spellID)
    if not addon.LibSpellDB then return false, nil end
    
    local sharedSpells = addon.LibSpellDB:GetSharedCooldownSpells(spellID)
    if not sharedSpells then return false, nil end
    
    local spellCfg = addon:GetSpellConfig()
    local spellTracker = addon:GetModule("SpellTracker")
    
    for _, otherSpellID in ipairs(sharedSpells) do
        if otherSpellID ~= spellID then
            -- Check if this other spell is enabled
            local cfg = spellCfg[otherSpellID] or {}
            local isEnabled = false
            
            -- Check if tracked by default (in trackedSpells) or explicitly enabled
            if spellTracker and spellTracker.trackedSpells and spellTracker.trackedSpells[otherSpellID] then
                -- Tracked by default, and not explicitly disabled
                if cfg.enabled ~= false then
                    isEnabled = true
                end
            elseif cfg.enabled == true then
                -- Explicitly enabled by user
                isEnabled = true
            end
            
            if isEnabled then
                local otherName = GetSpellInfo(otherSpellID) or ("Spell " .. otherSpellID)
                return true, otherName
            end
        end
    end
    
    return false, nil
end

-------------------------------------------------------------------------------
-- Register as module
-------------------------------------------------------------------------------

addon:RegisterModule("SpellsOptions", SpellsOptions)
