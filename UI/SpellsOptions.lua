--[[
    VeevHUD - Spells Options Panel
    Allows users to enable/disable spells, reorder them, and move between rows.
    
    Key features:
    - Per-spec configuration (sparse storage)
    - Drag-and-drop reordering within and between rows
    - Reset all spell config via button

    Why this is a standalone window (not embedded in AceConfig):
    
    AceConfig is a declarative system with fixed widget types (toggle, range,
    select, execute). It has no support for drag-and-drop, dynamic spell lists,
    ghost frames, or custom scrollable content — all of which this panel needs.
    
    The current flow closes the AceConfig dialog, opens this standalone window,
    and reopens AceConfig (on the Spells tab) when this window closes. It works,
    but the window-swap feels janky.
    
    Options to embed it in the future (roughly easiest to hardest):
    
    1. Hijack AceConfigDialog's content area (~1-2 days)
       When the Spells tab is selected, hide AceConfig's auto-generated content
       and reparent this panel's scroll frame into the dialog. Restore on tab
       switch. Keeps drag-and-drop intact but depends on AceConfigDialog internals
       and could break if the library updates.
    
    2. Pure AceConfig widgets (~2-3 days)
       Replace spell entries with AceConfig primitives: a toggle per spell, a
       select for row assignment, and Move Up/Down buttons for ordering. Loses
       drag-and-drop entirely and looks like a generic settings page. Dynamic
       per-spec content is also awkward since AceConfig tables are typically static.
    
    3. Custom AceGUI widget (~3-5 days)
       Build a proper AceGUI widget wrapping this UI, registered via dialogControl.
       Best result (native feel + drag-and-drop) but requires deep knowledge of
       AceGUI widget internals (OnAcquire, OnRelease, SetValue, layout callbacks).
]]

local _, addon = ...

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
SpellsOptions._entryPool = {}    -- Reusable spell entry frames (WoW never garbage-collects frames)
SpellsOptions._headerPool = {}   -- Reusable row header frames

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function SpellsOptions:Initialize()
    -- Created lazily when opened from AceConfig.
end

function SpellsOptions:Open(centerX, centerY)
    if not self.dialog then
        self:CreateDialog()
    end
    if self.dialog then
        -- Track whether we were opened from AceConfig (should reopen on close)
        self._openedFromAceConfig = (centerX ~= nil)
        -- Reposition to match previous window's center (e.g., AceConfig dialog)
        if centerX and centerY then
            self.dialog:ClearAllPoints()
            self.dialog:SetPoint("CENTER", UIParent, "BOTTOMLEFT", centerX, centerY)
            -- Store as last known position (before any drag)
            self._lastCenterX, self._lastCenterY = centerX, centerY
        end
        self.dialog:Show()
    end
end

function SpellsOptions:CreateDialog()
    if self.dialog then return self.dialog end

    local dialog = CreateFrame("Frame", "VeevHUDSpellConfigDialog", UIParent, "BasicFrameTemplateWithInset")
    dialog:SetSize(720, 640)
    -- Position ~30% down from top (instead of center) to avoid hiding the HUD
    dialog:SetPoint("CENTER", UIParent, "CENTER", 0, UIParent:GetHeight() * 0.20)
    dialog:SetFrameStrata("DIALOG")
    dialog:SetMovable(true)
    dialog:EnableMouse(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Track last known center so we can pass it back to the main options window
        SpellsOptions._lastCenterX, SpellsOptions._lastCenterY = self:GetCenter()
    end)
    dialog:Hide()

    -- Allow ESC to close the dialog
    tinsert(UISpecialFrames, "VeevHUDSpellConfigDialog")

    if dialog.TitleText then
        dialog.TitleText:SetText("VeevHUD - Spell Configuration")
    end

    local panel = dialog
    
    -- Description/Help text (single line, hover for details)
    local descFrame = CreateFrame("Frame", nil, panel)
    descFrame:SetPoint("TOPLEFT", 16, -34)
    descFrame:SetSize(400, 16)

    local description = descFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    description:SetPoint("LEFT", 0, 0)
    description:SetText("Customize which spells appear on your HUD and their order. |cff888888[?]|r")

    -- Spec label below description (wrapped in a frame for mouse interaction)
    local specFrame = CreateFrame("Frame", nil, panel)
    specFrame:SetPoint("TOPLEFT", descFrame, "BOTTOMLEFT", 0, -4)
    specFrame:SetSize(300, 16)
    local subtitle = specFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    subtitle:SetPoint("LEFT", 0, 0)
    subtitle:SetText("Loading...")
    self.subtitleText = subtitle

    specFrame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Per-Spec Configuration", 1, 1, 1)
        GameTooltip:AddLine("Settings on this screen are saved per-spec. Switching specs loads that spec's configuration.", 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    specFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    descFrame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Spell Configuration", 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Check/uncheck to show or hide spells", 1, 0.82, 0)
        GameTooltip:AddLine("Drag :: to reorder spells within a row", 1, 0.82, 0)
        GameTooltip:AddLine("Drag spells between rows to move them", 1, 0.82, 0)
        GameTooltip:AddLine("Drag from Available to enable additional spells", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    descFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    self.descriptionText = description
    self.descFrame = descFrame
    
    -- Instructions
    local instructions = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    instructions:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -34)
    instructions:SetText("Drag |cffffffff::|r to reorder")
    instructions:SetTextColor(0.5, 0.5, 0.5)
    
    -- Reset Spells Button
    local resetSpellsButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetSpellsButton:SetPoint("TOPRIGHT", instructions, "BOTTOMRIGHT", 0, -4)
    resetSpellsButton:SetSize(160, 22)
    resetSpellsButton:SetText("Reset Spell Config")
    resetSpellsButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Reset Spell Configuration", 1, 1, 1)
        GameTooltip:AddLine("Resets all spell visibility, ordering, and", 1, 0.82, 0, true)
        GameTooltip:AddLine("proc tracker settings to defaults.", 1, 0.82, 0, true)
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("Current spec: " .. addon:FormatSpecKey(SpellsOptions:GetSpecKey()), 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    resetSpellsButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    resetSpellsButton:SetScript("OnClick", function()
        local specKey = SpellsOptions:GetSpecKey()
        StaticPopupDialogs["VEEVHUD_RESET_SPELLS_CONFIRM"] = {
            text = "Reset all spell configuration for " .. addon:FormatSpecKey(specKey) .. " to defaults?",
            button1 = "Yes",
            button2 = "No",
            OnAccept = function()
                -- Clear all spellConfig for current spec (profile-scoped)
                if addon.db and addon.db.profile and addon.db.profile.spellConfig then
                    addon.db.profile.spellConfig[specKey] = nil
                    if next(addon.db.profile.spellConfig) == nil then
                        addon.db.profile.spellConfig = nil
                    end
                end
                
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
    scrollFrame:SetPoint("TOPLEFT", specFrame, "BOTTOMLEFT", 0, -8)
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
    end
    
    -- Refresh when panel becomes visible or spec changes
    panel:SetScript("OnShow", function(self)
        SpellsOptions.isConfigOpen = true
        if addon and addon.UpdateVisibility then
            addon:UpdateVisibility()
        end

        -- Small delay to ensure spec detection has run after talent changes
        C_Timer.After(0.1, function()
            if self:IsVisible() and SpellsOptions.scrollChild then
                DoRefresh()
            end
        end)
    end)

    panel:SetScript("OnHide", function()
        SpellsOptions.isConfigOpen = false
        if addon and addon.UpdateVisibility then
            addon:UpdateVisibility()
        end

        -- Cancel any drag state cleanly
        if SpellsOptions.ghostFrame then
            SpellsOptions.ghostFrame:SetScript("OnUpdate", nil)
            SpellsOptions.ghostFrame:Hide()
        end
        if SpellsOptions.dropIndicator then
            SpellsOptions.dropIndicator:Hide()
        end
        if SpellsOptions.dragState and SpellsOptions.dragState.sourceFrame then
            SpellsOptions.dragState.sourceFrame:SetAlpha(1.0)
        end
        SpellsOptions.dragState = nil

        -- Reopen the main AceConfig options dialog only if we were opened from it
        -- (not when user closes via X button or Escape from a standalone open)
        if SpellsOptions._openedFromAceConfig and addon.Options and addon.Options.Open then
            SpellsOptions._openedFromAceConfig = false
            -- Use last known position (saved on drag stop / open) since GetCenter()
            -- may return nil during OnHide
            local cx, cy = SpellsOptions._lastCenterX, SpellsOptions._lastCenterY
            -- Slight delay so the hide finishes before the open
            C_Timer.After(0, function()
                addon.Options:Open(cx, cy)
                -- Select the "spells" tab so the user lands back on the button
                local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
                if AceConfigDialog then
                    AceConfigDialog:SelectGroup("VeevHUD", "spells")
                end
            end)
        end
    end)
    
    if addon.Utils then
        addon.Utils:LogInfo("Spells options window created")
    end
    
    self.dialog = dialog
    self.panel = dialog
    return dialog
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
    self:SetSpellOverrideRaw(spellID, field, value)
    self:ApplyPendingSpellChanges()
end

-- Write an override without rescanning. Use in loops that change many spells at
-- once, then call ApplyPendingSpellChanges() exactly once at the end.
function SpellsOptions:SetSpellOverrideRaw(spellID, field, value)
    -- Get default value to compare - if value matches default, clear the override
    local defaultValue = self:GetDefaultValue(spellID, field)

    if value == defaultValue then
        value = nil
    end

    addon:SetSpellConfigOverride(spellID, field, value)
end

-- Rescan and reposition after one or more spell overrides changed
function SpellsOptions:ApplyPendingSpellChanges()
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
        -- Rebuild ready glow sound overrides to reflect new spell order
        local options = addon:GetModule("Options")
        if options and options.RebuildReadyGlowSoundOverrideArgs then
            options:RebuildReadyGlowSoundOverrideArgs()
        end
    end)
end

function SpellsOptions:GetDefaultValue(spellID, field)
    -- Get the INHERENT default (without considering user overrides)
    -- This should NOT change based on current tracked state

    -- Trinket sentinel IDs aren't in LibSpellDB — handle them directly
    local trinketTracker = addon:GetModule("TrinketTracker")
    if trinketTracker and trinketTracker:IsTrinketSentinel(spellID) then
        if field == "enabled" then
            return true  -- Trinkets are enabled by default when equipped
        elseif field == "rowIndex" then
            return 2  -- Default to Secondary row
        end
        return nil
    end

    -- Totem sentinel IDs — handle directly
    local totemTracker = addon:GetModule("TotemTracker")
    if totemTracker and totemTracker:IsTotemSentinel(spellID) then
        if field == "enabled" then
            return true  -- Totem slots enabled by default
        elseif field == "rowIndex" then
            return 4  -- Default to Auxiliary row
        end
        return nil
    end

    -- Stance sentinel ID — handle directly
    local stanceTracker = addon:GetModule("StanceTracker")
    if stanceTracker and stanceTracker:IsStanceSentinel(spellID) then
        if field == "enabled" then
            return false  -- Stance indicator hidden by default
        elseif field == "rowIndex" then
            return 4  -- Default to Auxiliary row
        end
        return nil
    end

    -- Consumable sentinel IDs — handle directly
    local consumableTracker = addon:GetModule("ConsumableTracker")
    if consumableTracker and consumableTracker:IsConsumableSentinel(spellID) then
        if field == "enabled" then
            return true  -- Consumables enabled by default when configured
        elseif field == "rowIndex" then
            return 2  -- Default to Secondary row
        end
        return nil
    end

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
        -- Not spec-relevant — but check if it's a known off-tree talent that would
        -- be auto-tracked by FullRescan (e.g., Fel Domination for Affliction warlocks).
        -- Mirrors SpellTracker off-tree talent logic + ShouldTrackSpell tag matching.
        local spellTracker = addon:GetModule("SpellTracker")
        local LibSpellDB = addon.LibSpellDB
        if spellTracker and LibSpellDB then
            local spellData = LibSpellDB:GetSpellInfo(spellID)
            if spellData and spellData.talent and spellTracker:IsSpellKnown(spellID, spellData) then
                local enabledTags = spellTracker:GetEnabledTags()
                local hasMatchingTag = false
                for _, tag in ipairs(spellData.tags or {}) do
                    if enabledTags[tag] then
                        hasMatchingTag = true
                        break
                    end
                end
                if hasMatchingTag and not spellTracker:ShouldExcludeSpell(spellData) then
                    return true  -- Known off-tree talent, would be auto-tracked
                end
            end
        end
        return false  -- Not spec-relevant and not an auto-tracked talent
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
    elseif field == "druidForm" then
        return nil  -- Default is tag-based (nil = use LibSpellDB tags)
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
        self.subtitleText:SetText(addon:FormatSpecLabel(specKey) or ("Current spec: " .. addon:FormatSpecKey(specKey)))
    end

    -- Return active entry/header frames to their pools for reuse
    -- (WoW never garbage-collects frames, so recreating them every refresh leaks)
    for _, frame in ipairs(self.spellEntries) do
        frame:Hide()
        if frame.isRowHeader then
            table.insert(self._headerPool, frame)
        else
            table.insert(self._entryPool, frame)
        end
    end
    wipe(self.spellEntries)

    -- Hide the persistent info texts; re-shown below when applicable
    if self._druidInfoText then self._druidInfoText:Hide() end
    if self._noSpellsText then self._noSpellsText:Hide() end
    if self._availDescText then self._availDescText:Hide() end

    -- Get spell data organized by row
    local rowSpells = self:GetEffectiveSpellList()
    
    -- Count total spells
    local totalSpells = 0
    for _, spells in pairs(rowSpells) do
        totalSpells = totalSpells + #spells
    end
    
    -- Build content
    local yOffset = 0
    local rowConfigs = addon.db.profile.rows

    -- Druid-specific explanation (persistent fontstring, reused across refreshes)
    if addon.playerClass == "DRUID" then
        local druidInfo = self._druidInfoText
        if not druidInfo then
            druidInfo = self.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
            druidInfo:SetWidth(460)
            druidInfo:SetJustifyH("LEFT")
            druidInfo:SetText("|cff888888Druid: Cat Form and Bear Form abilities are filtered by your current form — Cat abilities hide in Bear Form and vice versa. In caster or travel form, your last Cat/Bear form is remembered. Click the form label (Cat/Bear/Any) next to any spell to override this.|r")
            self._druidInfoText = druidInfo
        end
        druidInfo:ClearAllPoints()
        druidInfo:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 10, yOffset)
        druidInfo:Show()
        local infoHeight = druidInfo:GetStringHeight() + 8
        yOffset = yOffset - infoHeight
    end

    if totalSpells == 0 then
        -- Show message when no spells are found (persistent fontstring)
        local noSpellsMsg = self._noSpellsText
        if not noSpellsMsg then
            noSpellsMsg = self.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            noSpellsMsg:SetText("|cff888888No spells found for this spec.|r\n\nMake sure you're logged in and have abilities learned.")
            noSpellsMsg:SetJustifyH("LEFT")
            self._noSpellsText = noSpellsMsg
        end
        noSpellsMsg:ClearAllPoints()
        noSpellsMsg:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 0, yOffset)
        noSpellsMsg:Show()
        yOffset = yOffset - 60
    else
        -- Display rows in visual order (matching default HUD layout: Aux above Primary)
        local rowDisplayOrder = {4, 1, 2, 3}
        for _, rowIndex in ipairs(rowDisplayOrder) do
            local rowConfig = rowConfigs[rowIndex]
            if not rowConfig then break end
            local spells = rowSpells[rowIndex]

            -- Always show row header (even when empty) so it remains a drop target
            yOffset = self:CreateRowHeader(rowIndex, rowConfig.name, yOffset)

            -- Spell entries
            if spells then
                for i, spellInfo in ipairs(spells) do
                    yOffset = self:CreateSpellEntry(spellInfo, rowIndex, i, yOffset)
                end
            end

            yOffset = yOffset - 8  -- Gap between rows
        end
        
        -- Display "Available" section (untracked spells the player knows)
        local availableSpells = rowSpells[AVAILABLE_ROW_INDEX]
        if availableSpells and #availableSpells > 0 then
            yOffset = yOffset - 12  -- Extra gap before available section
            yOffset = self:CreateRowHeader(AVAILABLE_ROW_INDEX, "Available", yOffset)
            
            -- Add description (persistent fontstring, reused across refreshes)
            local availDesc = self._availDescText
            if not availDesc then
                availDesc = self.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
                availDesc:SetText("|cff888888Spells you know but aren't tracked. Drag to a row above to enable.|r")
                availDesc:SetWidth(450)
                availDesc:SetJustifyH("LEFT")
                self._availDescText = availDesc
            end
            availDesc:ClearAllPoints()
            availDesc:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 10, yOffset)
            availDesc:Show()
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
            local effectiveRow = cfg.rowIndex or defaultRow or AVAILABLE_ROW_INDEX

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
                isAvailable = (effectiveRow == AVAILABLE_ROW_INDEX),  -- Available if in available section
            })
        end
    end
    
    -- Inject trinket entries from TrinketTracker
    local trinketTracker = addon:GetModule("TrinketTracker")
    if trinketTracker then
        for slotID, slotData in pairs(trinketTracker.slots) do
            if slotData then
                local sentinelID = slotData.sentinelID
                local cfg = spellCfg[sentinelID] or {}
                local slotLabel = (slotID == 13) and "Trinket 1" or "Trinket 2"
                local label = slotLabel
                if slotData.name then
                    label = slotLabel .. " (" .. slotData.name .. ")"
                end
                local effectiveRow = cfg.rowIndex or 2  -- Default: Secondary
                rows[effectiveRow] = rows[effectiveRow] or {}
                table.insert(rows[effectiveRow], {
                    spellID = sentinelID,
                    spellData = { tags = {"TRINKET"}, icon = slotData.icon, name = label, priority = 1000 + slotID },
                    enabled = cfg.enabled ~= false,
                    rowIndex = effectiveRow,
                    defaultRow = 2,
                    order = cfg.order,
                    isTrinket = true,
                    isAvailable = (effectiveRow == AVAILABLE_ROW_INDEX),
                })
            end
        end
    end

    -- Inject totem element entries for Shamans
    local totemTracker = addon:GetModule("TotemTracker")
    if totemTracker and addon.playerClass == "SHAMAN" then
        local sentinelIDs = totemTracker:GetSentinelIDs()
        if sentinelIDs then
            for _, sentinelID in ipairs(sentinelIDs) do
                local cfg = spellCfg[sentinelID] or {}
                local label = totemTracker:GetSentinelLabel(sentinelID) or "Totem"
                local icon = totemTracker:GetSentinelIcon(sentinelID)
                local effectiveRow = cfg.rowIndex or 4  -- Default: Auxiliary
                rows[effectiveRow] = rows[effectiveRow] or {}
                table.insert(rows[effectiveRow], {
                    spellID = sentinelID,
                    spellData = { tags = {}, icon = icon, name = label, priority = 2000 + (sentinelID % 10) },
                    enabled = cfg.enabled ~= false,
                    rowIndex = effectiveRow,
                    defaultRow = 4,
                    order = cfg.order,
                    isTotemSlot = true,
                    isAvailable = (effectiveRow == AVAILABLE_ROW_INDEX),
                })
            end
        end
    end

    -- Inject consumable entries from ConsumableTracker
    local consumableTracker = addon:GetModule("ConsumableTracker")
    if consumableTracker then
        local configured = consumableTracker:GetConfiguredItems()
        for _, entry in ipairs(configured) do
            local consumableData = consumableTracker:GetConsumableData(entry.itemID)
            if consumableData then
                local sentinelID = consumableData.sentinelID
                local cfg = spellCfg[sentinelID] or {}
                local label = consumableData.name
                local effectiveRow = cfg.rowIndex or 2  -- Default: Secondary
                rows[effectiveRow] = rows[effectiveRow] or {}
                table.insert(rows[effectiveRow], {
                    spellID = sentinelID,
                    spellData = { tags = {"POTION"}, icon = consumableData.icon, name = label, priority = 2000 + entry.itemID },
                    enabled = cfg.enabled ~= false,
                    rowIndex = effectiveRow,
                    defaultRow = 2,
                    order = cfg.order,
                    isConsumable = true,
                    consumableItemID = entry.itemID,
                    isAvailable = (effectiveRow == AVAILABLE_ROW_INDEX),
                })
            end
        end
    end

    -- Inject stance indicator for supported classes (Warrior, Druid, Paladin)
    -- Only shown when the player knows at least one stance/form/aura
    local stanceTracker = addon:GetModule("StanceTracker")
    local numShapeshiftForms = GetNumShapeshiftForms() or 0
    local minFormsNeeded = (addon.playerClass == "DRUID") and 1 or 2
    if stanceTracker and stanceTracker:GetSentinelID() and numShapeshiftForms >= minFormsNeeded then
        local sentinelID = stanceTracker:GetSentinelID()
        if sentinelID then
            local cfg = spellCfg[sentinelID] or {}
            local label = stanceTracker:GetSentinelLabel() or "Stance"
            local icon = stanceTracker:GetSentinelIcon()
            local effectiveRow = cfg.rowIndex or 4  -- Default: Auxiliary
            rows[effectiveRow] = rows[effectiveRow] or {}
            table.insert(rows[effectiveRow], {
                spellID = sentinelID,
                spellData = { tags = {}, icon = icon, name = label, priority = 3000 },
                enabled = cfg.enabled == true,  -- Hidden by default; must be explicitly enabled
                rowIndex = effectiveRow,
                defaultRow = 4,
                order = cfg.order,
                isStanceIndicator = true,
                isAvailable = (effectiveRow == AVAILABLE_ROW_INDEX),
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
                -- Skip PROC-tagged spells — they belong in AuraTracker, not ability rows.
                -- Exception: reactive-window procs (e.g., Victory Rush) are castable abilities
                -- that can optionally be shown as cooldown icons.
                if addon.LibSpellDB:HasTag(spellID, "PROC") and not addon.LibSpellDB:GetReactiveWindow(spellID) then
                    -- skip
                -- Check if player knows this spell
                elseif spellTracker:IsSpellKnown(spellID, spellData) then
                    -- Skip spells blocked by shared cooldown (e.g., Shield Wall when Recklessness is tracked)
                    -- These are hidden entirely rather than shown as greyed out
                    local isBlocked = self:IsBlockedBySharedCooldown(spellID)
                    -- Skip non-representative exclusive group members (they'll be collapsed into the group entry).
                    -- Only block members with the same auraTarget — spells targeting different units
                    -- (e.g., Earth Shield=ally vs Water Shield=self) can coexist.
                    if not isBlocked then
                        local gName, gInfo = addon.LibSpellDB:GetBuffGroup(spellID)
                        if gName and gInfo and gInfo.relationship == "exclusive" then
                            local myAuraTarget = addon.LibSpellDB:GetAuraTarget(spellID) or "self"
                            for _, gSpellID in ipairs(gInfo.spells) do
                                if gSpellID ~= spellID and displayedSpellIDs[gSpellID] then
                                    local otherAuraTarget = addon.LibSpellDB:GetAuraTarget(gSpellID) or "self"
                                    if otherAuraTarget == myAuraTarget then
                                        isBlocked = true
                                        break
                                    end
                                end
                            end
                        end
                    end
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
            if orderA ~= orderB then
                return orderA < orderB
            end
            return a.spellID < b.spellID
        end)
    end

    -- Collapse exclusive BuffGroup members into a single group entry per group.
    -- E.g., 8 warlock curses become one "Curses" entry since they share a tracker.
    if addon.LibSpellDB then
        -- Discover exclusive groups across all rows, sub-grouped by auraTarget.
        -- Spells targeting different units (e.g., Earth Shield=ally vs Water Shield=self)
        -- can coexist and must not be collapsed together.
        local groupEntries = {}  -- subKey -> {{spellInfo, rowIndex}, ...}
        for rowIndex, spells in pairs(rows) do
            for _, spellInfo in ipairs(spells) do
                local groupName, groupInfo = addon.LibSpellDB:GetBuffGroup(spellInfo.spellID)
                if groupName and groupInfo and groupInfo.relationship == "exclusive" then
                    local auraTarget = addon.LibSpellDB:GetAuraTarget(spellInfo.spellID) or "self"
                    local subKey = groupName .. "|" .. auraTarget
                    groupEntries[subKey] = groupEntries[subKey] or {info = groupInfo, members = {}}
                    table.insert(groupEntries[subKey].members, {spellInfo = spellInfo, rowIndex = rowIndex})
                end
            end
        end

        -- For each group with 2+ entries, collapse into one
        for groupName, group in pairs(groupEntries) do
            if #group.members >= 2 then
                -- Pick representative: lowest rowIndex (Primary > Secondary > Utility > Available),
                -- then priority, then spellID
                table.sort(group.members, function(a, b)
                    if a.rowIndex ~= b.rowIndex then return a.rowIndex < b.rowIndex end
                    local prioA = a.spellInfo.spellData.priority or 999
                    local prioB = b.spellInfo.spellData.priority or 999
                    if prioA ~= prioB then return prioA < prioB end
                    return a.spellInfo.spellID < b.spellInfo.spellID
                end)

                local rep = group.members[1]
                local memberIDs = {}
                local anyEnabled = false

                -- Collect member IDs and check enabled state
                for _, m in ipairs(group.members) do
                    table.insert(memberIDs, m.spellInfo.spellID)
                    if m.spellInfo.enabled then anyEnabled = true end
                end

                -- Remove all member entries from their rows
                local removeSet = {}
                for _, m in ipairs(group.members) do
                    removeSet[m.spellInfo.spellID] = true
                end
                for rowIndex, spells in pairs(rows) do
                    local filtered = {}
                    for _, s in ipairs(spells) do
                        if not removeSet[s.spellID] then
                            table.insert(filtered, s)
                        end
                    end
                    rows[rowIndex] = filtered
                end

                -- Create group entry from representative
                local groupEntry = {
                    spellID = rep.spellInfo.spellID,
                    spellData = rep.spellInfo.spellData,
                    enabled = anyEnabled,
                    rowIndex = rep.rowIndex,
                    defaultRow = rep.spellInfo.defaultRow,
                    order = rep.spellInfo.order,
                    isAvailable = rep.spellInfo.isAvailable,
                    defaultOrder = rep.spellInfo.defaultOrder,
                    -- Group metadata
                    isExclusiveGroup = true,
                    exclusiveGroupName = groupName,
                    exclusiveGroupMembers = memberIDs,
                    exclusiveGroupDescription = group.info.description,
                }

                -- Insert into representative's row and re-sort to maintain position
                rows[rep.rowIndex] = rows[rep.rowIndex] or {}
                table.insert(rows[rep.rowIndex], groupEntry)
                table.sort(rows[rep.rowIndex], function(a, b)
                    local orderA = a.order or a.defaultOrder or 999
                    local orderB = b.order or b.defaultOrder or 999
                    if orderA ~= orderB then
                        return orderA < orderB
                    end
                    return a.spellID < b.spellID
                end)
            end
        end
    end

    -- Replace shared cooldown group entries with a meta-entry (like exclusive BuffGroups).
    -- E.g., Arms warrior's Retaliation becomes a group entry showing the override spell icon.
    if addon.LibSpellDB then
        for rowIndex, spells in pairs(rows) do
            for i, spellInfo in ipairs(spells) do
                local groupName, groupInfo = addon.LibSpellDB:GetSharedCooldownGroup(spellInfo.spellID)
                if groupName and groupInfo then
                    local displayID = spellInfo.spellID
                    local displayData = spellInfo.spellData
                    local overrideID, overrideData = addon.Database:ResolveSharedCooldownOverride(displayID)
                    if overrideID then
                        displayID = overrideID
                        displayData = overrideData
                    end

                    -- Replace with shared CD group meta-entry.
                    -- Unlike isExclusiveGroup (where all members are tracked), only the
                    -- spec-default spell is tracked — config overrides apply to it alone.
                    spells[i] = {
                        spellID = displayID,
                        spellData = displayData,
                        enabled = spellInfo.enabled,
                        rowIndex = spellInfo.rowIndex,
                        defaultRow = spellInfo.defaultRow,
                        order = spellInfo.order,
                        isAvailable = spellInfo.isAvailable,
                        defaultOrder = spellInfo.defaultOrder,
                        isSharedCDGroup = true,
                        sharedCDTrackedSpellID = spellInfo.spellID,  -- original tracked spell for config writes
                        sharedCDGroupMembers = groupInfo.spells,
                        sharedCDGroupDescription = groupInfo.description,
                    }
                end
            end
        end
    end

    return rows
end

-------------------------------------------------------------------------------
-- UI Creators
-------------------------------------------------------------------------------

function SpellsOptions:CreateRowHeader(rowIndex, name, yOffset)
    -- Acquire from pool (frames are never garbage-collected, so reuse them)
    local frame = table.remove(self._headerPool)
    if not frame then
        frame = CreateFrame("Frame", nil, self.scrollChild)
        frame:SetSize(500, ROW_HEADER_HEIGHT)
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
        header:SetTextColor(1, 0.82, 0)
        frame.headerText = header

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
    end

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 0, yOffset)
    frame.rowIndex = rowIndex
    frame.headerText:SetText(name or "Row " .. rowIndex)
    frame.highlight:Hide()
    frame:Show()  -- Explicitly show

    -- Store for drag detection
    table.insert(self.spellEntries, frame)

    return yOffset - ROW_HEADER_HEIGHT
end

-- Build the static skeleton of a spell entry frame. Created once, then pooled and
-- reused — everything that depends on the specific spell is (re)set in CreateSpellEntry.
function SpellsOptions:CreateSpellEntryFrame()
    local frame = CreateFrame("Frame", nil, self.scrollChild)
    frame:SetSize(480, SPELL_ENTRY_HEIGHT)
    frame:EnableMouse(true)
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
    frame.icon = icon

    -- Name
    local name = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    name:SetWidth(200)
    name:SetJustifyH("LEFT")
    frame.nameText = name

    -- Checkbox (enable/disable); OnClick is bound per-spell in CreateSpellEntry
    local checkbox = CreateFrame("CheckButton", nil, frame, "InterfaceOptionsCheckButtonTemplate")
    checkbox:SetPoint("LEFT", name, "RIGHT", 8, 0)
    checkbox.Text:SetText("")  -- No text on checkbox
    frame.checkbox = checkbox

    -- Druid form selector (all druid specs — form filtering applies to all druids);
    -- per-spell state and scripts are bound in CreateSpellEntry
    local dragAnchor = checkbox  -- Default: drag handle anchors to checkbox
    if addon.playerClass == "DRUID" then
        local formBtn = CreateFrame("Button", nil, frame)
        formBtn:SetPoint("LEFT", checkbox, "RIGHT", 4, 0)
        formBtn:SetSize(36, 20)

        local formText = formBtn:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        formText:SetPoint("CENTER")
        formBtn.text = formText

        frame.formBtn = formBtn
        dragAnchor = formBtn  -- Drag handle anchors to form button instead
    end

    -- Drag handle (use simple :: symbol that renders in all fonts)
    local dragHandle = CreateFrame("Button", nil, frame)
    dragHandle:SetPoint("LEFT", dragAnchor, "RIGHT", 8, 0)
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

    -- Drag functionality (reads the frame's current spellInfo, so bound once)
    dragHandle:RegisterForDrag("LeftButton")
    dragHandle:SetScript("OnDragStart", function()
        SpellsOptions:StartDrag(frame)
    end)
    dragHandle:SetScript("OnDragStop", function()
        SpellsOptions:EndDrag()
    end)
    frame.dragHandle = dragHandle

    frame:SetScript("OnLeave", function(self)
        self.bg:Hide()
        GameTooltip:Hide()
    end)

    return frame
end

function SpellsOptions:CreateSpellEntry(spellInfo, rowIndex, index, yOffset)
    -- Acquire from pool (frames are never garbage-collected, so reuse them)
    local frame = table.remove(self._entryPool)
    if not frame then
        frame = self:CreateSpellEntryFrame()
    end

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 10, yOffset)
    frame:SetAlpha(1)  -- May have been dimmed as a drag source
    frame:Show()  -- Explicitly show

    -- Store spell info
    frame.spellID = spellInfo.spellID
    frame.spellInfo = spellInfo
    frame.rowIndex = rowIndex
    frame.index = index

    -- Reset transient visuals from a previous use
    frame.bg:Hide()
    frame.dropHighlight:Hide()

    -- Icon
    local icon = frame.icon
    local spellName, _, spellIcon
    if spellInfo.isTrinket or spellInfo.isTotemSlot or spellInfo.isStanceIndicator or spellInfo.isConsumable then
        spellName = spellInfo.spellData.name
        spellIcon = spellInfo.spellData.icon
    else
        spellName, _, spellIcon = GetSpellInfo(spellInfo.spellID)
    end
    icon:SetTexture(spellIcon or "Interface\\Icons\\INV_Misc_QuestionMark")

    -- Name (use group description for group entries)
    local nameText
    if spellInfo.isExclusiveGroup and spellInfo.exclusiveGroupDescription then
        local desc = spellInfo.exclusiveGroupDescription
        local shortDesc = desc:match("^%w+%s+(.+)$") or desc
        nameText = shortDesc:sub(1, 1):upper() .. shortDesc:sub(2)
    elseif spellInfo.isSharedCDGroup and spellInfo.sharedCDGroupDescription then
        local desc = spellInfo.sharedCDGroupDescription
        local shortDesc = desc:match("^%w+%s+(.+)$") or desc
        nameText = shortDesc:sub(1, 1):upper() .. shortDesc:sub(2)
    else
        nameText = spellName or ("Spell " .. spellInfo.spellID)
    end

    local name = frame.nameText
    name:SetText(nameText)

    -- Grey out if disabled (reset both ways — the frame may be reused)
    if spellInfo.enabled then
        icon:SetDesaturated(false)
        icon:SetAlpha(1)
        name:SetTextColor(1, 1, 1)
    else
        icon:SetDesaturated(true)
        icon:SetAlpha(0.5)
        name:SetTextColor(0.5, 0.5, 0.5)
    end

    -- Checkbox (enable/disable)
    local checkbox = frame.checkbox
    checkbox:SetChecked(spellInfo.enabled)

    checkbox:SetScript("OnClick", function(self)
        local enabled = self:GetChecked()

        if spellInfo.isExclusiveGroup then
            -- Toggle ALL group members at once
            for _, memberID in ipairs(spellInfo.exclusiveGroupMembers) do
                SpellsOptions:SetSpellOverrideRaw(memberID, "enabled", enabled)
            end
        elseif spellInfo.isSharedCDGroup then
            -- Only toggle the tracked spell (others aren't spec-relevant)
            SpellsOptions:SetSpellOverrideRaw(spellInfo.sharedCDTrackedSpellID, "enabled", enabled)
        else
            SpellsOptions:SetSpellOverrideRaw(spellInfo.spellID, "enabled", enabled)
        end

        -- If enabling a spell from the Available section, move it to its default row
        -- BUT only if it doesn't already have a meaningful rowIndex override (user previously configured it)
        if enabled and spellInfo.isAvailable then
            local cooldownIcons = addon:GetModule("CooldownIcons")
            local defaultRow = 3  -- Default to Utility for non-spec-relevant spells
            if spellInfo.isTotemSlot or spellInfo.isStanceIndicator then
                defaultRow = spellInfo.defaultRow or 4
            elseif spellInfo.isTrinket or spellInfo.isConsumable then
                defaultRow = spellInfo.defaultRow or 2
            elseif cooldownIcons and cooldownIcons.GetDefaultRowForSpell then
                defaultRow = cooldownIcons:GetDefaultRowForSpell(spellInfo.spellID) or 3
            end

            if spellInfo.isExclusiveGroup then
                -- Move all group members to the default row
                for _, memberID in ipairs(spellInfo.exclusiveGroupMembers) do
                    local memberCfg = addon:GetSpellConfigForSpell(memberID)
                    if memberCfg.rowIndex == nil or memberCfg.rowIndex == AVAILABLE_ROW_INDEX then
                        local memberRow = defaultRow
                        if cooldownIcons and cooldownIcons.GetDefaultRowForSpell then
                            memberRow = cooldownIcons:GetDefaultRowForSpell(memberID) or defaultRow
                        end
                        SpellsOptions:SetSpellOverrideRaw(memberID, "rowIndex", memberRow)
                    end
                end
            elseif spellInfo.isSharedCDGroup then
                local trackedCfg = addon:GetSpellConfigForSpell(spellInfo.sharedCDTrackedSpellID)
                if trackedCfg.rowIndex == nil or trackedCfg.rowIndex == AVAILABLE_ROW_INDEX then
                    SpellsOptions:SetSpellOverrideRaw(spellInfo.sharedCDTrackedSpellID, "rowIndex", defaultRow)
                end
            else
                local cfg = addon:GetSpellConfigForSpell(spellInfo.spellID)
                if cfg.rowIndex == nil or cfg.rowIndex == AVAILABLE_ROW_INDEX then
                    SpellsOptions:SetSpellOverrideRaw(spellInfo.spellID, "rowIndex", defaultRow)
                end
            end
        end

        -- Rescan/reposition once for all the overrides written above
        SpellsOptions:ApplyPendingSpellChanges()

        SpellsOptions:RefreshSpellList()
    end)

    -- Druid form selector (per-spell state — rebound on every acquire)
    if frame.formBtn then
        local LibSpellDB = addon.LibSpellDB
        local sid = spellInfo.spellID

        -- Determine tag-based default for this spell
        local tagDefault = "ANY"
        if LibSpellDB and LibSpellDB:HasTag(sid, "CAT_FORM") then
            tagDefault = "CAT"
        elseif LibSpellDB and LibSpellDB:HasTag(sid, "BEAR_FORM") then
            tagDefault = "BEAR"
        end

        -- Display labels
        local formLabels = { CAT = "Cat", BEAR = "Bear", ANY = "Any" }
        -- Cycle order
        local cycleOrder = { "CAT", "BEAR", "ANY" }

        local formBtn = frame.formBtn
        local formText = formBtn.text

        -- Get current override
        local cfg = addon:GetSpellConfigForSpell(sid)
        local currentOverride = cfg.druidForm  -- nil, "CAT", "BEAR", or "ANY"
        local effectiveForm = currentOverride or tagDefault

        -- Update display
        local function UpdateFormDisplay()
            formText:SetText(formLabels[effectiveForm] or "Any")
            if not spellInfo.enabled then
                -- Spell disabled: extra dim
                formText:SetTextColor(0.3, 0.3, 0.3)
            elseif currentOverride then
                -- Override active: gold text
                formText:SetTextColor(1, 0.82, 0)
            else
                -- Default: dimmed grey
                formText:SetTextColor(0.5, 0.5, 0.5)
            end
        end
        UpdateFormDisplay()

        formBtn:SetScript("OnClick", function()
            if not spellInfo.enabled then return end
            -- Find current position in cycle
            local currentIdx = 0
            for i, v in ipairs(cycleOrder) do
                if effectiveForm == v then
                    currentIdx = i
                    break
                end
            end
            -- Advance to next
            local nextIdx = (currentIdx % #cycleOrder) + 1
            local nextForm = cycleOrder[nextIdx]

            -- If next matches tag default, store nil (clear override)
            if nextForm == tagDefault then
                currentOverride = nil
                effectiveForm = tagDefault
            else
                currentOverride = nextForm
                effectiveForm = nextForm
            end

            SpellsOptions:SetSpellOverride(sid, "druidForm", currentOverride)
            UpdateFormDisplay()
        end)

        formBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Form Visibility")
            GameTooltip:AddLine("Click to cycle: Cat / Bear / Any", 1, 1, 1, true)
            if currentOverride then
                GameTooltip:AddLine("Currently overridden (gold = custom)", 1, 0.82, 0)
            else
                GameTooltip:AddLine("Using default (based on spell tags)", 0.5, 0.5, 0.5)
            end
            GameTooltip:Show()
        end)
        formBtn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    -- Hover effects (tooltip depends on the spell — rebound on every acquire)
    frame:SetScript("OnEnter", function(self)
        self.bg:Show()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if spellInfo.isExclusiveGroup or spellInfo.isSharedCDGroup then
            local members = spellInfo.exclusiveGroupMembers or spellInfo.sharedCDGroupMembers
            GameTooltip:AddLine("Shared Tracker", 1, 1, 1)
            GameTooltip:AddLine("Only one active at a time — icon swaps on cast", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine(" ")
            for _, memberID in ipairs(members) do
                local mName = GetSpellInfo(memberID)
                if mName then
                    GameTooltip:AddLine(mName, 1, 0.82, 0)
                end
            end
        elseif spellInfo.isTotemSlot then
            GameTooltip:AddLine(spellInfo.spellData.name, 1, 1, 1)
            GameTooltip:AddLine("Element slot — shows your active totem for this element", 0.7, 0.7, 0.7, true)
        elseif spellInfo.isStanceIndicator then
            GameTooltip:AddLine(spellInfo.spellData.name, 1, 1, 1)
            GameTooltip:AddLine("Shows your current active stance, form, or aura", 0.7, 0.7, 0.7, true)
        elseif spellInfo.isTrinket then
            local slotID = (spellInfo.spellID == addon.Constants.TRINKET_SLOT_13) and 13 or 14
            GameTooltip:SetInventoryItem("player", slotID)
        elseif spellInfo.isConsumable and spellInfo.consumableItemID then
            GameTooltip:SetItemByID(spellInfo.consumableItemID)
        else
            GameTooltip:SetSpellByID(spellInfo.spellID)
        end
        GameTooltip:Show()
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
    
    -- Setup ghost frame (sentinel entries aren't real spells — resolve from spellData)
    local info = frame.spellInfo
    local spellName, _, spellIcon
    if info.isTrinket or info.isTotemSlot or info.isStanceIndicator or info.isConsumable then
        spellName = info.spellData.name
        spellIcon = info.spellData.icon
    else
        spellName, _, spellIcon = GetSpellInfo(frame.spellID)
    end
    self.ghostFrame.icon:SetTexture(spellIcon)
    if info.isExclusiveGroup or info.isSharedCDGroup then
        self.ghostFrame.name:SetText(frame.nameText:GetText() or "Group")
    else
        self.ghostFrame.name:SetText(spellName or "Unknown")
    end
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
        
        -- For exclusive group entries, apply overrides to all members.
        -- For shared CD groups, only apply to the single tracked spell.
        local isExclGroup = self.dragState.spellInfo and self.dragState.spellInfo.isExclusiveGroup
        local exclMembers = isExclGroup and self.dragState.spellInfo.exclusiveGroupMembers
        local isSharedCD = self.dragState.spellInfo and self.dragState.spellInfo.isSharedCDGroup
        local sharedCDTarget = isSharedCD and self.dragState.spellInfo.sharedCDTrackedSpellID

        -- If dragging from Available section to a main row, enable the spell
        if sourceRow == AVAILABLE_ROW_INDEX and newRow ~= AVAILABLE_ROW_INDEX then
            if isExclGroup then
                for _, memberID in ipairs(exclMembers) do
                    self:SetSpellOverrideRaw(memberID, "enabled", true)
                    self:SetSpellOverrideRaw(memberID, "rowIndex", nil)  -- Clear AVAILABLE_ROW_INDEX
                end
            elseif isSharedCD then
                self:SetSpellOverrideRaw(sharedCDTarget, "enabled", true)
                self:SetSpellOverrideRaw(sharedCDTarget, "rowIndex", nil)
            else
                self:SetSpellOverrideRaw(spellID, "enabled", true)
            end
            self:SetSpellOverrideRaw(isSharedCD and sharedCDTarget or spellID, "rowIndex", newRow)
        -- If dragging to Available section, disable the spell
        elseif newRow == AVAILABLE_ROW_INDEX and sourceRow ~= AVAILABLE_ROW_INDEX then
            if isExclGroup then
                for _, memberID in ipairs(exclMembers) do
                    self:SetSpellOverrideRaw(memberID, "enabled", false)
                    self:SetSpellOverrideRaw(memberID, "rowIndex", AVAILABLE_ROW_INDEX)
                end
            elseif isSharedCD then
                self:SetSpellOverrideRaw(sharedCDTarget, "enabled", false)
                self:SetSpellOverrideRaw(sharedCDTarget, "rowIndex", AVAILABLE_ROW_INDEX)
            else
                self:SetSpellOverrideRaw(spellID, "enabled", false)
                self:SetSpellOverrideRaw(spellID, "rowIndex", AVAILABLE_ROW_INDEX)
            end
        -- Row changed within main rows
        elseif rowChanged then
            if isExclGroup then
                for _, memberID in ipairs(exclMembers) do
                    self:SetSpellOverrideRaw(memberID, "rowIndex", newRow)
                end
            else
                self:SetSpellOverrideRaw(isSharedCD and sharedCDTarget or spellID, "rowIndex", newRow)
            end
        end
        
        -- Update order (skip for Available section as order doesn't matter there)
        if newRow ~= AVAILABLE_ROW_INDEX and (orderChanged or rowChanged) then
            -- FIX: Assign explicit order values to ALL spells in this row.
            -- This is critical because CooldownIcons computes defaultOrder based only on ENABLED spells,
            -- while SpellsOptions computes defaultOrder based on ALL spells (enabled + disabled).
            -- By saving explicit order values for every spell, we ensure consistent ordering
            -- regardless of which spells are enabled or disabled.
            
            -- Get ALL spells in the target row (including the dragged spell)
            local allRowSpells = self:GetEffectiveSpellList()[newRow] or {}
            
            -- Build list excluding the dragged spell
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
            
            -- Calculate the new order for the dragged spell
            local newDraggedOrder
            if newIndex == 999 or adjustedIndex > #rowSpells then
                -- Dropped at end of row
                newDraggedOrder = #rowSpells + 1
            elseif adjustedIndex <= 1 then
                -- Dropped at start
                newDraggedOrder = 1
            else
                -- Dropped between spells - use the target position
                newDraggedOrder = adjustedIndex
            end
            
            -- Build the final ordered list by inserting dragged spell at its new position
            local finalOrder = {}
            local insertPos = math.max(1, math.min(newDraggedOrder, #rowSpells + 1))
            
            for i, spell in ipairs(rowSpells) do
                if i == insertPos then
                    table.insert(finalOrder, { spellID = spellID, isNew = true })
                end
                table.insert(finalOrder, spell)
            end
            -- Handle insertion at end
            if insertPos > #rowSpells then
                table.insert(finalOrder, { spellID = spellID, isNew = true })
            end
            
            -- Assign sequential order values to ALL spells (1, 2, 3, ...)
            -- This ensures every spell has an explicit order, eliminating defaultOrder inconsistencies
            for i, spell in ipairs(finalOrder) do
                self:SetSpellOverrideRaw(spell.spellID, "order", i)
            end
        end

        -- Rescan/reposition once for all the overrides written above
        self:ApplyPendingSpellChanges()
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
