--[[
    VeevHUD - Cooldown Icons Module
    Displays tracked spells organized in category rows
    
    Design:
    - All tracked spells are always visible
    - Ready spells: 100% alpha
    - On cooldown: 30% alpha with cooldown spiral
    - No resources: desaturated (like default action bars)
]]

local ADDON_NAME, addon = ...
local C = addon.Constants

local CooldownIcons = {}
addon:RegisterModule("CooldownIcons", CooldownIcons)

-- Row containers
CooldownIcons.rows = {}

-- Icon pool per row
CooldownIcons.iconsByRow = {}

-- Spell to row assignment cache
CooldownIcons.spellAssignments = {}

-- Icon naming counter for Masque
CooldownIcons.iconCounter = 0

-- Masque support
CooldownIcons.Masque = nil
CooldownIcons.MasqueGroup = nil


-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function CooldownIcons:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants
    self.Animations = addon.Animations

    -- Track active spell overlays (procs)
    self.activeOverlays = {}

    -- Initialize Masque support if available
    self:InitializeMasque()
    
    -- Check LibCustomGlow availability (shared via Utils)
    if self.Utils:GetLibCustomGlow() then
        self.Utils:LogInfo("LibCustomGlow support enabled")
    end

    -- Register for updates
    self.Events:RegisterEvent(self, "SPELL_UPDATE_COOLDOWN", self.OnSpellUpdate)
    self.Events:RegisterEvent(self, "SPELL_UPDATE_USABLE", self.OnSpellUpdate)
    self.Events:RegisterEvent(self, "UNIT_POWER_UPDATE", self.OnPowerUpdate)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)
    
    -- Register for spell activation overlay events (procs)
    self.Events:RegisterEvent(self, "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", self.OnOverlayShow)
    self.Events:RegisterEvent(self, "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", self.OnOverlayHide)
    
    -- Register for spell cast events (for cast feedback animation)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_SUCCEEDED", self.OnSpellCastSucceeded)
    
    -- Register for target changes (for target lockout debuff tracking like PWS/Weakened Soul)
    self.Events:RegisterEvent(self, "PLAYER_TARGET_CHANGED", self.OnSpellUpdate)
    self.Events:RegisterEvent(self, "UNIT_TARGET", self.OnUnitTarget)
    
    -- Register for range check updates (throttled by RangeChecker module)
    if addon.RangeChecker then
        addon.RangeChecker:RegisterCallback(self, self.OnRangeUpdate)
    end

    self.Utils:LogInfo("CooldownIcons initialized")
end

function CooldownIcons:InitializeMasque()
    local MSQ = LibStub and LibStub("Masque", true)
    if MSQ then
        self.Masque = MSQ
        self.MasqueGroup = MSQ:Group("VeevHUD", "Cooldowns")
        self.Utils:LogInfo("Masque support enabled - user can customize via Masque settings")
    else
        self.Utils:LogDebug("Masque not found, using built-in Classic Enhanced style")
    end
end

-- Configure external cooldown text addons (OmniCC, ElvUI, etc.)
-- If showCooldownText is enabled for this row, we use our own text and hide external addons
-- If showCooldownText is disabled for this row, we let external addons show their text
-- rowIndex: 1 = Primary, 2 = Secondary, 3+ = Utility (nil = use global setting)
function CooldownIcons:ConfigureCooldownText(cooldown, rowIndex)
    local db = addon.db and addon.db.profile.icons or {}
    
    -- Check if VeevHUD will show its own text for this specific row
    local showOwnText
    if rowIndex then
        showOwnText = addon.Database:IsRowSettingEnabled(db.showCooldownTextOn, rowIndex)
    else
        -- No row specified (initial creation) - default to allowing external addons
        -- Will be reconfigured when assigned to a row
        showOwnText = false
    end
    
    -- Use shared utility for the actual OmniCC/ElvUI configuration
    self.Utils:ConfigureCooldownText(cooldown, showOwnText)
end

function CooldownIcons:OnPlayerEnteringWorld()
    C_Timer.After(2, function()
        self:RebuildAllRows()
        self:UpdateAllIcons()
    end)
end

function CooldownIcons:OnSpellUpdate()
    self:UpdateAllIcons()
end

function CooldownIcons:OnPowerUpdate(event, unit)
    if unit == "player" then
        self:UpdateAllIcons()
    end
end

function CooldownIcons:OnUnitTarget(event, unit)
    -- Update when target's target changes (for targettarget lockout tracking)
    if unit == "target" then
        self:UpdateAllIcons()
    end
end

function CooldownIcons:OnRangeUpdate()
    -- Called by RangeChecker on throttled interval (0.1s) or target change
    -- RangeChecker already handles target existence check
    local db = addon.db and addon.db.profile.icons or {}
    local showRangeOn = db.showRangeIndicator
    
    -- Skip if range indicator is completely disabled
    if showRangeOn == "none" then
        return
    end
    
    self:UpdateAllRangeIndicators()
end

function CooldownIcons:OnOverlayShow(event, spellID)
    if spellID then
        self.activeOverlays[spellID] = true
        self:UpdateAllIcons()
    end
end

function CooldownIcons:OnOverlayHide(event, spellID)
    if spellID then
        self.activeOverlays[spellID] = nil
        self:UpdateAllIcons()
    end
end

function CooldownIcons:OnSpellCastSucceeded(event, unit, castGUID, spellID)
    if unit ~= "player" then return end
    
    -- Find the icon frame for this spell
    local frame = self:FindIconFrameBySpellID(spellID)
    if frame then
        self:PlayCastFeedback(frame)
    end
    
    -- Check if this spell is part of a shared cooldown group
    -- If so, and it's not the displayed spell, set an override to show this spell's buff
    self:HandleSharedCooldownCast(spellID)
end

-- Handle when a shared cooldown spell is cast that isn't the displayed one
-- Simply swap the icon to show the actually-used ability (buff + cooldown)
function CooldownIcons:HandleSharedCooldownCast(castSpellID)
    local LibSpellDB = addon.LibSpellDB
    if not LibSpellDB then return end
    
    -- Get the shared cooldown group for the cast spell
    local groupName, groupInfo = LibSpellDB:GetSharedCooldownGroup(castSpellID)
    if not groupName or not groupInfo then return end
    
    -- Find if we have an icon tracking any spell from this group
    for _, rowFrame in ipairs(self.rows or {}) do
        if rowFrame.icons then
            for _, iconFrame in ipairs(rowFrame.icons) do
                if iconFrame:IsShown() and iconFrame.spellID then
                    -- Check if this icon's spell is in the same shared CD group
                    local iconGroup = LibSpellDB:GetSharedCooldownGroup(iconFrame.spellID)
                    if iconGroup == groupName and iconFrame.spellID ~= castSpellID then
                        -- Different spell from same group was cast!
                        -- Swap the icon to show the used ability instead
                        local castSpellData = LibSpellDB:GetSpellInfo(castSpellID)
                        if castSpellData then
                            -- Update icon to the cast spell (permanent swap)
                            local texture = castSpellData.icon or self.Utils:GetSpellTexture(castSpellID)
                            iconFrame.icon:SetTexture(texture)
                            iconFrame.spellID = castSpellID
                            iconFrame.spellData = castSpellData
                            self.Utils:Debug("SharedCD swap: now showing", castSpellID, "instead of original")
                        end
                    end
                end
            end
        end
    end
end

-- Check if a buff is active on the player (for shared CD abilities like Reck/Retal/SWall)
-- Returns: isActive, remaining, duration, stacks
-- Uses cached buff lookup to avoid scanning 40 buffs per icon per update
function CooldownIcons:GetPlayerBuff(spellID)
    local spellName = GetSpellInfo(spellID)
    local aura = self.Utils:GetCachedBuff("player", spellID, spellName)
    
    if aura then
        local remaining = 0
        if aura.expirationTime and aura.expirationTime > 0 then
            remaining = aura.expirationTime - GetTime()
            if remaining < 0 then remaining = 0 end
        end
        return true, remaining, aura.duration or 0, aura.count or 0
    end
    
    return false, 0, 0, 0
end

-- Check if a buff is active on the relevant unit (fallback for when AuraTracker doesn't track)
-- Used for shared CD abilities and other buffs that need direct scanning
-- 
-- When checkSelfOnly is true: always checks player
-- When checkSelfOnly is false: follows target context (ally if targeting ally, else self)
--
-- Returns: isActive, remaining, duration, stacks
function CooldownIcons:GetRelevantBuff(spellID, checkSelfOnly)
    local spellName = GetSpellInfo(spellID)
    if not spellName then return false, 0, 0, 0 end
    
    -- Determine which unit to check
    local unit = "player"
    
    if not checkSelfOnly then
        local db = addon.db and addon.db.profile and addon.db.profile.icons or {}
        local useTargettarget = db.auraTargettargetSupport or false
        
        local targetExists = UnitExists("target")
        local targetIsEnemy = targetExists and UnitIsEnemy("player", "target")
        local targetIsFriend = targetExists and UnitIsFriend("player", "target")
        
        if targetIsFriend then
            -- Targeting an ally - check them for the buff
            unit = "target"
        elseif targetIsEnemy then
            -- Targeting an enemy - check targettarget if friendly (and enabled), else self
            if useTargettarget and UnitExists("targettarget") and UnitIsFriend("player", "targettarget") then
                unit = "targettarget"
            end
            -- else: fallback to self (already set)
        end
        -- No target or neutral: fallback to self (already set)
    end
    
    local aura = self.Utils:GetCachedBuff(unit, spellID, spellName)
    
    if aura then
        local remaining = 0
        if aura.expirationTime and aura.expirationTime > 0 then
            remaining = aura.expirationTime - GetTime()
            if remaining < 0 then remaining = 0 end
        end
        return true, remaining, aura.duration or 0, aura.count or 0
    end
    
    return false, 0, 0, 0
end

-- Check for target lockout debuff (e.g., Weakened Soul for PWS, Forbearance for Paladin spells)
-- Follows the same targeting logic as helpful effects (since lockouts restrict helpful spells)
-- Returns: isActive, remaining, duration, expirationTime
-- Note: Lockout debuffs are checked regardless of who applied them (any priest's Weakened Soul blocks your PWS)
function CooldownIcons:GetTargetLockoutDebuff(debuffSpellID, isSelfOnly)
    if not debuffSpellID then return false, 0, 0, 0 end
    
    local debuffName = GetSpellInfo(debuffSpellID)
    if not debuffName then return false, 0, 0, 0 end
    
    -- Determine which unit to check using the same logic as helpful effects
    -- Self-only spells (Divine Shield, Avenging Wrath) -> always check self
    -- Targeting enemy: targettarget if friendly (and setting enabled), else self
    -- Targeting ally: that ally
    -- No target: self
    local unit = "player"
    
    if not isSelfOnly then
        local db = addon.db and addon.db.profile and addon.db.profile.icons or {}
        local useTargettarget = db.auraTargettargetSupport or false
        
        local targetExists = UnitExists("target")
        local targetIsEnemy = targetExists and UnitIsEnemy("player", "target")
        local targetIsFriend = targetExists and UnitIsFriend("player", "target")
        
        if targetIsFriend then
            -- Targeting an ally - check them for the lockout
            unit = "target"
        elseif targetIsEnemy then
            -- Targeting an enemy - check targettarget if friendly (and enabled), else self
            if useTargettarget and UnitExists("targettarget") and UnitIsFriend("player", "targettarget") then
                unit = "targettarget"
            end
            -- else: fallback to self (already set)
        end
        -- No target or neutral: fallback to self (already set)
    end
    
    -- Use cached debuff lookup (checks any debuff with this ID, not just player's)
    local aura = self.Utils:GetCachedDebuff(unit, debuffSpellID, debuffName)
    
    if aura then
        local remaining = 0
        if aura.expirationTime and aura.expirationTime > 0 then
            remaining = aura.expirationTime - GetTime()
            if remaining < 0 then remaining = 0 end
        end
        return true, remaining, aura.duration or 0, aura.expirationTime or 0
    end
    
    return false, 0, 0, 0
end

-- Find icon frame by spell ID (checks ranks too)
function CooldownIcons:FindIconFrameBySpellID(spellID)
    local LibSpellDB = addon.LibSpellDB
    local canonicalID = LibSpellDB and LibSpellDB:GetCanonicalSpellID(spellID) or spellID
    
    for _, rowFrame in ipairs(self.rows or {}) do
        if rowFrame.icons then
            for _, iconFrame in ipairs(rowFrame.icons) do
                if iconFrame.spellID == canonicalID or iconFrame.spellID == spellID then
                    return iconFrame
                end
                -- Check ranks
                if iconFrame.spellData and iconFrame.spellData.ranks then
                    for _, rankID in ipairs(iconFrame.spellData.ranks) do
                        if rankID == spellID then
                            return iconFrame
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- Play cast feedback animation (scale punch using Animations utility)
function CooldownIcons:PlayCastFeedback(frame)
    if not frame then return end
    
    local db = addon.db and addon.db.profile.icons or {}
    
    -- Check row-based setting
    local rowIndex = frame.rowIndex or 1
    if not addon.Database:IsRowSettingEnabled(db.castFeedbackRows, rowIndex) then return end
    
    local scale = db.castFeedbackScale
    
    -- Track when cast feedback plays so dim transition can sync with it
    frame._lastCastFeedbackTime = GetTime()
    
    -- Use Animations utility for consistent scale punch behavior
    if self.Animations then
        self.Animations:PlayScalePunch(frame, scale, "punchAnim")
    end
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function CooldownIcons:CreateFrames(parent)
    local db = addon.db and addon.db.profile and addon.db.profile.icons

    if not db or not db.enabled then 
        self.Utils:LogInfo("CooldownIcons: disabled or no config")
        return 
    end

    -- Main container for all rows
    -- Position below the resource bar (which is at CENTER with offsetY=0, height=14)
    local resourceBarDb = addon.db.profile.resourceBar
    local resourceBarBottom = resourceBarDb.offsetY - resourceBarDb.height / 2
    
    local container = CreateFrame("Frame", "VeevHUDIconContainer", parent)
    container:SetSize(400, 400)
    container:SetPoint("TOP", parent, "CENTER", 0, resourceBarBottom - 2)  -- 2px below resource bar
    container:EnableMouse(false)  -- Click-through
    self.container = container

    self.Utils:LogInfo("CooldownIcons: Container created")

    -- Create row frames
    local success, err = pcall(function()
        self:CreateRowFrames()
    end)
    if not success then
        self.Utils:LogError("CooldownIcons: CreateRowFrames failed:", err)
    end

    -- Apply texcoords after all icons are created (ensures aspect ratio is respected)
    -- This handles cases where settings might not be fully loaded during CreateIcon
    self:ApplyIconTexCoords()

    -- Start update ticker
    self.Events:RegisterUpdate(self, 0.05, self.UpdateAllIcons)
end

-- Apply texcoords to all icons based on current aspect ratio and zoom settings
function CooldownIcons:ApplyIconTexCoords()
    local db = addon.db.profile.icons
    -- iconZoom is total crop percentage; divide by 2 to get per-edge crop
    local zoomPerEdge = db.iconZoom / 2
    
    for _, rowFrame in ipairs(self.rows or {}) do
        for _, icon in ipairs(rowFrame.icons or {}) do
            if icon.icon then
                local left, right, top, bottom = self.Utils:GetIconTexCoords(zoomPerEdge)
                icon.icon:SetTexCoord(left, right, top, bottom)
            end
        end
    end
end

function CooldownIcons:CreateRowFrames()
    local rowConfigs = addon.db and addon.db.profile and addon.db.profile.rows
    local iconDb = addon.db and addon.db.profile and addon.db.profile.icons
    
    if not rowConfigs then
        self.Utils:LogError("CooldownIcons: No rows config found")
        return
    end
    if not iconDb then
        self.Utils:LogError("CooldownIcons: No icons config found")
        return
    end
    
    self.Utils:LogInfo("CooldownIcons: Creating", #rowConfigs, "row frames")
    local yOffset = 0

    for rowIndex, rowConfig in ipairs(rowConfigs) do
        if rowConfig.enabled then
            -- Add extra space between primary and secondary rows
            if rowIndex == 2 then
                yOffset = yOffset - iconDb.primarySecondaryGap
            end
            
            -- Add extra space before utility section (row 3+)
            if rowIndex >= 3 then
                yOffset = yOffset - iconDb.sectionGap
            end

            -- Use per-row settings or fall back to global
            local rowIconSize = rowConfig.iconSize or iconDb.iconSize
            -- Use explicit nil check since 0 is a valid spacing value
            local rowIconSpacing = rowConfig.iconSpacing
            if rowIconSpacing == nil then
                rowIconSpacing = iconDb.iconSpacing
            end

            -- Get width/height based on aspect ratio
            local rowIconWidth, rowIconHeight = self.Utils:GetIconDimensions(rowIconSize)
            
            self.Utils:LogInfo("Row", rowIndex, rowConfig.name, "iconSize:", rowIconSize, "iconWidth:", rowIconWidth, "maxIcons:", rowConfig.maxIcons)

            local rowFrame = CreateFrame("Frame", nil, self.container)
            rowFrame:SetSize(rowConfig.maxIcons * (rowIconWidth + rowIconSpacing), rowIconHeight)
            rowFrame:SetPoint("TOP", self.container, "TOP", 0, yOffset)
            rowFrame:EnableMouse(false)  -- Click-through
            rowFrame.iconSize = rowIconSize
            rowFrame.iconWidth = rowIconWidth
            rowFrame.iconHeight = rowIconHeight
            rowFrame.iconSpacing = rowIconSpacing
            rowFrame.iconsPerRow = rowConfig.iconsPerRow or rowConfig.maxIcons
            rowFrame.flowLayout = rowConfig.flowLayout or false

            rowFrame.config = rowConfig
            rowFrame.icons = {}

            -- Pre-create icon frames for this row
            for i = 1, rowConfig.maxIcons do
                local icon = self:CreateIcon(rowFrame, i, rowIconSize)
                icon:Hide()
                rowFrame.icons[i] = icon
            end

            self.rows[rowIndex] = rowFrame
            self.iconsByRow[rowIndex] = {}

            -- Calculate height for yOffset - estimate rows needed for flow layout
            local estimatedHeight = rowIconHeight
            if rowConfig.flowLayout and rowConfig.iconsPerRow then
                local estimatedRows = math.ceil(rowConfig.maxIcons / rowConfig.iconsPerRow)
                estimatedHeight = estimatedRows * (rowIconHeight + iconDb.rowSpacing)
            end
            yOffset = yOffset - (estimatedHeight + iconDb.rowSpacing)
        end
    end
end

function CooldownIcons:CreateIcon(parent, index, size)
    local db = addon.db.profile.icons
    size = size or db.iconSize
    
    -- Get width/height based on aspect ratio (width = size * ratio, height = size)
    local iconWidth, iconHeight = self.Utils:GetIconDimensions(size)

    -- Create as Button for Masque compatibility
    local buttonName = "VeevHUDIcon" .. (self.iconCounter or 0)
    self.iconCounter = (self.iconCounter or 0) + 1

    local frame = CreateFrame("Button", buttonName, parent)
    frame:SetSize(iconWidth, iconHeight)
    frame:EnableMouse(false)  -- Click-through (display only, no interaction)
    frame.iconSize = size  -- Base size (used for calculations)
    frame.iconWidth = iconWidth
    frame.iconHeight = iconHeight

    -- Icon texture - fills the frame, spacing between icons creates separation
    local icon = frame:CreateTexture(buttonName .. "Icon", "ARTWORK")
    icon:SetAllPoints()
    -- Apply texcoords with zoom and aspect ratio cropping (uses setting, will be reapplied in ApplyIconTexCoords)
    -- iconZoom is total crop percentage; divide by 2 to get per-edge crop
    local zoomPerEdge = db.iconZoom / 2
    local left, right, top, bottom = self.Utils:GetIconTexCoords(zoomPerEdge)
    icon:SetTexCoord(left, right, top, bottom)
    frame.icon = icon
    frame.Icon = icon  -- Masque reference

    -- Normal texture for Masque compatibility (hidden by default)
    local normalTexture = frame:CreateTexture(buttonName .. "NormalTexture", "OVERLAY")
    normalTexture:SetAllPoints()
    normalTexture:SetTexture([[Interface\Buttons\UI-Quickslot2]])
    normalTexture:SetAlpha(0)  -- Hidden, Masque will use if configured
    frame:SetNormalTexture(normalTexture)
    frame.NormalTexture = normalTexture

    -- Cooldown spiral overlay (Masque expects this)
    local cooldown = CreateFrame("Cooldown", buttonName .. "Cooldown", frame, "CooldownFrameTemplate")
    cooldown:SetAllPoints(icon)
    cooldown:SetDrawEdge(false)
    -- Bling effect configured per-row in SetupIcon
    cooldown:SetDrawBling(false)  -- Default off, SetupIcon enables per-row
    cooldown:SetDrawSwipe(true)
    -- Dark swipe for time remaining (covers the icon), light underneath for elapsed
    cooldown:SetSwipeColor(0, 0, 0, 0.8)
    cooldown:SetReverse(false)  -- Swipe = remaining time (drains as cooldown progresses)
    frame.cooldown = cooldown
    frame.Cooldown = cooldown  -- Masque reference
    
    -- Configure external cooldown text (OmniCC, ElvUI, etc.)
    self:ConfigureCooldownText(cooldown)

    -- Text overlay frame (above everything including pixel glow)
    local textFrame = CreateFrame("Frame", nil, frame)
    textFrame:SetAllPoints()
    textFrame:SetFrameLevel(frame:GetFrameLevel() + 20)  -- Above pixel glow (which uses +8)
    
    -- Cooldown text (on top of everything) - scale font with icon size
    local fontSize = math.max(14, math.floor(size * 0.38))  -- Larger cooldown text
    local text = textFrame:CreateFontString(nil, "OVERLAY", nil, 7)
    text:SetFont(addon:GetFont(), fontSize, "OUTLINE")  -- Lighter outline
    text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    text:SetTextColor(self.C.COLORS.TEXT.r, self.C.COLORS.TEXT.g, self.C.COLORS.TEXT.b)
    text:SetShadowOffset(0.5, -0.5)  -- Subtle shadow
    text:SetShadowColor(0, 0, 0, 0.5)
    frame.text = text
    frame.textFrame = textFrame

    -- Charges text (bottom right)
    local chargesFontSize = math.max(9, math.floor(size * 0.24))
    local charges = frame:CreateFontString(nil, "OVERLAY")
    charges:SetFont(addon:GetFont(), chargesFontSize, "OUTLINE")
    charges:SetPoint("BOTTOMRIGHT", -2, 2)
    charges:SetTextColor(1, 1, 1)
    frame.charges = charges
    frame.Count = charges  -- Masque reference

    -- Stacks text (top right, for aura stacks like Rampage, Lifebloom, Sunder)
    -- Parented to textFrame so it renders above cooldown spiral
    local stacksFontSize = math.max(10, math.floor(size * 0.26))
    local stacks = textFrame:CreateFontString(nil, "OVERLAY", nil, 7)
    stacks:SetFont(addon:GetFont(), stacksFontSize, "OUTLINE")
    stacks:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 2)
    stacks:SetJustifyH("RIGHT")
    stacks:SetJustifyV("TOP")
    stacks:SetTextColor(self.C.COLORS.TEXT.r, self.C.COLORS.TEXT.g, self.C.COLORS.TEXT.b)
    frame.stacks = stacks

    -- Resource cost display elements
    -- Option A: Horizontal bar at bottom
    local resourceBar = CreateFrame("Frame", nil, frame)
    resourceBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    resourceBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    resourceBar:SetHeight(db.resourceBarHeight)
    resourceBar:SetFrameLevel(frame:GetFrameLevel() + 5)
    
    local resourceBarBg = resourceBar:CreateTexture(nil, "BACKGROUND")
    resourceBarBg:SetAllPoints()
    resourceBarBg:SetTexture([[Interface\Buttons\WHITE8X8]])
    resourceBarBg:SetVertexColor(0, 0, 0, 0.5)
    resourceBar.bg = resourceBarBg
    
    local resourceBarFill = resourceBar:CreateTexture(nil, "ARTWORK")
    resourceBarFill:SetPoint("TOPLEFT", resourceBar, "TOPLEFT", 0, 0)
    resourceBarFill:SetPoint("BOTTOMLEFT", resourceBar, "BOTTOMLEFT", 0, 0)
    resourceBarFill:SetTexture([[Interface\Buttons\WHITE8X8]])
    resourceBarFill:SetVertexColor(1, 0, 0, 1)  -- Default red (will be updated based on power type)
    resourceBarFill:SetWidth(1)  -- Start with minimal width
    resourceBar.fill = resourceBarFill
    
    resourceBar:Hide()
    frame.resourceBar = resourceBar
    
    -- Option B: Vertical fill from top (dark overlay showing missing resources)
    -- Anchored at top, grows downward to show what % of resources are missing
    local resourceFill = frame:CreateTexture(nil, "OVERLAY", nil, 1)
    resourceFill:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    resourceFill:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    resourceFill:SetTexture([[Interface\Buttons\WHITE8X8]])
    resourceFill:SetVertexColor(0, 0, 0, db.resourceFillAlpha)
    resourceFill:SetHeight(0)
    resourceFill:Hide()
    frame.resourceFill = resourceFill

    -- Range indicator overlay (red tint when target is out of range)
    -- Uses same approach as Blizzard action buttons (red overlay)
    -- We use a wrapper frame for the overlay so we can animate its alpha
    local rangeFrame = CreateFrame("Frame", nil, frame)
    rangeFrame:SetAllPoints(icon)
    rangeFrame:SetAlpha(0)
    rangeFrame:Hide()
    
    local rangeOverlay = rangeFrame:CreateTexture(nil, "OVERLAY", nil, 2)
    rangeOverlay:SetAllPoints()
    rangeOverlay:SetTexture([[Interface\Buttons\WHITE8X8]])
    rangeOverlay:SetVertexColor(177/255, 22/255, 22/255, 0.4)  -- Out-of-range red: rgb(177, 22, 22)
    
    -- Create fade animations using Animations utility
    if self.Animations then
        self.Animations:CreateFadePair(rangeFrame, 0.15)
    end
    
    frame.rangeOverlay = rangeOverlay
    frame.rangeFrame = rangeFrame

    frame.index = index
    frame.spellID = nil

    -- Register with Masque if available
    -- Masque will override our default textures with its own styling
    if self.MasqueGroup then
        self.MasqueGroup:AddButton(frame, {
            Icon = icon,
            Cooldown = cooldown,
            Normal = normalTexture,
            Count = charges,
        })
    else
        -- Apply built-in Classic Enhanced style when Masque is not installed
        addon.IconStyling:Apply(frame, size)
    end

    return frame
end

-------------------------------------------------------------------------------
-- Spell Assignment to Rows
-------------------------------------------------------------------------------

function CooldownIcons:OnTrackedSpellsChanged()
    self:RebuildAllRows()
    self:UpdateAllIcons()
    -- Ensure rows are repositioned after icon count changes
    -- (RebuildAllRows already calls this, but call again to be safe after UpdateAllIcons)
    self:RepositionRows()
    -- Force icon repositioning within rows after row frames are repositioned
    self:RefreshIconPositions()
end

-- Force all icons to be repositioned within their row frames
-- Called after RepositionRows to ensure icons are in correct positions
function CooldownIcons:RefreshIconPositions()
    local db = addon.db.profile.icons
    for rowIndex, rowFrame in pairs(self.rows or {}) do
        if rowFrame then
            local spells = self.iconsByRow[rowIndex] or {}
            local iconCount = #spells
            if iconCount > 0 then
                self:PositionRowIcons(rowFrame, iconCount, db)
            end
        end
    end
end


-- Get the default row for a spell based on tag matching (used by SpellsOptions)
function CooldownIcons:GetDefaultRowForSpell(spellID)
    local LibSpellDB = addon.LibSpellDB
    if not LibSpellDB then return nil end
    
    -- Also check if this spell is spec-relevant
    if not LibSpellDB:IsSpellRelevantForSpec(spellID) then
        return nil  -- Not relevant for current spec
    end
    
    local rowConfigs = addon.db.profile.rows or {}
    
    for rowIndex, rowConfig in ipairs(rowConfigs) do
        if rowConfig.enabled then
            for _, requiredTag in ipairs(rowConfig.tags or {}) do
                if LibSpellDB:HasTag(spellID, requiredTag) then
                    return rowIndex
                end
            end
        end
    end
    
    return nil  -- No matching row tags
end

-- Get spell config override for a specific spell
function CooldownIcons:GetSpellConfig(spellID)
    return addon:GetSpellConfigForSpell(spellID)
end

function CooldownIcons:RebuildAllRows()
    local tracker = addon:GetModule("SpellTracker")
    if not tracker then 
        self.Utils:LogError("CooldownIcons: SpellTracker not found")
        return 
    end

    local trackedSpells = tracker:GetTrackedSpells()
    local LibSpellDB = addon.LibSpellDB
    if not LibSpellDB then 
        self.Utils:LogError("CooldownIcons: LibSpellDB not found")
        return 
    end
    
    -- Reset dynamic sort animation state before rebuilding
    self:ResetDynamicSortPositions()
    
    local spellCount = 0
    for _ in pairs(trackedSpells) do spellCount = spellCount + 1 end
    self.Utils:LogInfo("CooldownIcons: Rebuilding with", spellCount, "tracked spells")

    -- Clear assignments
    wipe(self.spellAssignments)
    for rowIndex in pairs(self.iconsByRow) do
        wipe(self.iconsByRow[rowIndex])
    end

    -- Assign each tracked spell to a row based on tags (or spellConfig override)
    local rowConfigs = addon.db.profile.rows
    local spellCfg = addon:GetSpellConfig()

    for spellID, trackedData in pairs(trackedSpells) do
        local spellData = trackedData.spellData
        local assigned = false
        local cfg = spellCfg[spellID] or {}
        
        -- Check if spell has a row override in spellConfig
        if cfg.rowIndex then
            local rowIndex = cfg.rowIndex
            local rowConfig = rowConfigs[rowIndex]
            
            if rowConfig and rowConfig.enabled then
                if not self.iconsByRow[rowIndex] then
                    self.iconsByRow[rowIndex] = {}
                end
                
                if #self.iconsByRow[rowIndex] < rowConfig.maxIcons then
                    table.insert(self.iconsByRow[rowIndex], {
                        spellID = spellID,  -- Canonical ID for identification
                        actualSpellID = trackedData.actualSpellID or spellID,  -- Rank ID for WoW API calls
                        spellData = spellData,
                        customOrder = cfg.order,  -- Store custom order if set
                    })
                    self.spellAssignments[spellID] = rowIndex
                    assigned = true
                end
            end
        end
        
        -- Default: Find first matching row based on tags
        if not assigned then
            for rowIndex, rowConfig in ipairs(rowConfigs) do
                if rowConfig.enabled and not assigned then
                    for _, requiredTag in ipairs(rowConfig.tags) do
                        if LibSpellDB:HasTag(spellID, requiredTag) then
                            -- Assign to this row
                            if not self.iconsByRow[rowIndex] then
                                self.iconsByRow[rowIndex] = {}
                            end

                            -- Check if we have room
                            if #self.iconsByRow[rowIndex] < rowConfig.maxIcons then
                                table.insert(self.iconsByRow[rowIndex], {
                                    spellID = spellID,  -- Canonical ID for identification
                                    actualSpellID = trackedData.actualSpellID or spellID,  -- Rank ID for WoW API calls
                                    spellData = spellData,
                                    customOrder = cfg.order,  -- Store custom order if set
                                })
                                self.spellAssignments[spellID] = rowIndex
                                assigned = true
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- Sort spells within each row
    -- Custom order takes precedence, then priority, then cooldown
    for rowIndex, spells in pairs(self.iconsByRow) do
        -- First, assign default order indices for sorting
        -- Sort initially by priority/cooldown/spellID to get default order (stable)
        table.sort(spells, function(a, b)
            local priorityA = a.spellData.priority or 999
            local priorityB = b.spellData.priority or 999
            if priorityA ~= priorityB then
                return priorityA < priorityB
            end
            local cdA = a.spellData.cooldown or 0
            local cdB = b.spellData.cooldown or 0
            if cdA ~= cdB then
                return cdA < cdB
            end
            -- Tie-breaker: spellID for stable sorting
            return a.spellID < b.spellID
        end)
        
        -- Assign default order to each spell
        for i, spell in ipairs(spells) do
            spell.defaultOrder = i
        end
        
        -- Re-sort applying custom order overrides
        table.sort(spells, function(a, b)
            local orderA = a.customOrder or a.defaultOrder
            local orderB = b.customOrder or b.defaultOrder
            return orderA < orderB
        end)
    end

    -- Update icons to show assigned spells
    self:UpdateRowIcons()
    
    -- Reposition rows based on actual icon counts (important for flow layout rows)
    self:RepositionRows()

    self.Utils:LogInfo("CooldownIcons: Rebuilt rows")
    for rowIndex, spells in pairs(self.iconsByRow) do
        if #spells > 0 then
            local rowConfig = rowConfigs[rowIndex]
            self.Utils:LogDebug("  Row", rowIndex, "(" .. (rowConfig and rowConfig.name or "?") .. "):", #spells, "spells")
        end
    end
end

-- Reposition row frames based on actual icon counts
-- This is called after RebuildAllRows to ensure flow layout rows are positioned correctly
-- when the number of icons changes (e.g., after reset or enabling/disabling spells)
function CooldownIcons:RepositionRows()
    if not self.rows or not self.container then return end
    
    local rowConfigs = addon.db.profile.rows or {}
    local iconDb = addon.db.profile.icons or {}
    
    -- Get sorted list of row indices (to handle sparse tables)
    local sortedRowIndices = {}
    for rowIndex in pairs(self.rows) do
        table.insert(sortedRowIndices, rowIndex)
    end
    table.sort(sortedRowIndices)
    
    local yOffset = 0
    
    for _, rowIndex in ipairs(sortedRowIndices) do
        local rowFrame = self.rows[rowIndex]
        if rowFrame then
            local rowConfig = rowConfigs[rowIndex] or {}
            local iconHeight = rowFrame.iconHeight or rowFrame.iconSize
            local iconsPerRow = rowFrame.iconsPerRow or rowConfig.iconsPerRow or rowConfig.maxIcons
            local rowSpacing = iconDb.rowSpacing
            
            -- Get actual icon count for this row
            local actualIconCount = 0
            local spells = self.iconsByRow[rowIndex]
            if spells then
                actualIconCount = #spells
            end
            
            -- Add extra gap between primary and secondary rows
            if rowIndex == 2 then
                yOffset = yOffset - iconDb.primarySecondaryGap
            end
            
            -- Add section gap before utility rows (row 3+)
            if rowIndex >= 3 then
                yOffset = yOffset - iconDb.sectionGap
            end
            
            -- Position row frame
            rowFrame:ClearAllPoints()
            rowFrame:SetPoint("TOP", self.container, "TOP", 0, yOffset)
            
            -- Reset row frame height to match actual content height
            -- This ensures icons are positioned correctly when using TOP anchor
            rowFrame:SetHeight(iconHeight)
            
            -- Calculate height based on ACTUAL icon count (not maxIcons)
            local actualHeight = iconHeight
            if rowFrame.flowLayout and iconsPerRow and actualIconCount > 0 then
                local actualRows = math.ceil(actualIconCount / iconsPerRow)
                actualHeight = actualRows * (iconHeight + rowSpacing) - rowSpacing
            elseif actualIconCount == 0 then
                -- Empty row takes no vertical space
                actualHeight = 0
            end
            
            -- Only add row spacing if this row has icons
            if actualIconCount > 0 then
                yOffset = yOffset - actualHeight - rowSpacing
            end
        end
    end
end

function CooldownIcons:UpdateRowIcons()
    local db = addon.db.profile.icons
    local rowConfigs = addon.db.profile.rows or {}

    for rowIndex, rowFrame in pairs(self.rows) do
        if rowFrame then
            local spells = self.iconsByRow[rowIndex] or {}
            local iconCount = #spells
            
            -- Get row config for per-row settings
            local rowConfig = rowConfigs[rowIndex]

            -- Position and show icons for this row
            for i, iconFrame in ipairs(rowFrame.icons) do
                local shouldShow = i <= iconCount
                
                if shouldShow then
                    local spellInfo = spells[i]
                    self:SetupIcon(iconFrame, spellInfo.spellID, spellInfo.actualSpellID, spellInfo.spellData, rowConfig, rowIndex)
                    -- Store default sort order for stable sorting when using dynamic sort
                    iconFrame.defaultSortOrder = spellInfo.customOrder or spellInfo.defaultOrder or i
                    iconFrame:SetAlpha(iconFrame.iconAlpha or 1)
                    iconFrame:Show()
                else
                    iconFrame:Hide()
                    iconFrame.defaultSortOrder = nil
                end
            end

            -- Center the icons in the row
            self:PositionRowIcons(rowFrame, iconCount, db)
        end
    end
end

function CooldownIcons:PositionRowIcons(rowFrame, count, db)
    if count == 0 then
        rowFrame:Hide()
        return
    end

    rowFrame:Show()

    -- Use per-row settings (set during creation)
    local size = rowFrame.iconSize or db.iconSize
    local iconWidth = rowFrame.iconWidth or size
    local iconHeight = rowFrame.iconHeight or size
    -- Use explicit nil check since 0 is a valid spacing value
    local spacing = rowFrame.iconSpacing
    if spacing == nil then
        spacing = db.iconSpacing
    end
    local iconsPerRow = rowFrame.iconsPerRow or count  -- Default to all on one row
    local flowLayout = rowFrame.flowLayout or false
    local rowSpacing = db.rowSpacing  -- Vertical spacing between wrapped rows

    if flowLayout then
        -- Flow layout rows always use TOP anchor for consistency
        -- This ensures position doesn't jump when transitioning between 1 row and multiple rows
        if count > iconsPerRow then
            -- Multi-row flow layout
            self:PositionFlowLayout(rowFrame, count, iconWidth, iconHeight, spacing, iconsPerRow, rowSpacing)
        else
            -- Single row but still flow layout - use TOP anchor like multi-row
            local totalWidth = count * iconWidth + (count - 1) * spacing
            local startX = -totalWidth / 2 + iconWidth / 2

            for i = 1, count do
                local frame = rowFrame.icons[i]
                if frame and frame:IsShown() then
                    local x = startX + (i - 1) * (iconWidth + spacing)
                    frame:ClearAllPoints()
                    -- Use TOP anchor to match PositionFlowLayout behavior
                    frame:SetPoint("TOP", rowFrame, "TOP", x, 0)
                end
            end
        end
    else
        -- Non-flow layout rows use CENTER anchor
        local totalWidth = count * iconWidth + (count - 1) * spacing
        local startX = -totalWidth / 2 + iconWidth / 2

        for i = 1, count do
            local frame = rowFrame.icons[i]
            if frame and frame:IsShown() then
                local x = startX + (i - 1) * (iconWidth + spacing)
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", rowFrame, "CENTER", x, 0)
            end
        end
    end
end

function CooldownIcons:PositionFlowLayout(rowFrame, count, iconWidth, iconHeight, spacing, iconsPerRow, rowSpacing)
    -- Calculate how many rows we need
    local numRows = math.ceil(count / iconsPerRow)
    
    -- Check if last row would have only 1 icon - if so, redistribute
    local lastRowCount = count % iconsPerRow
    if lastRowCount == 1 and numRows > 1 then
        -- Adjust icons per row to balance better
        iconsPerRow = math.ceil(count / numRows)
    end
    
    -- Use rowSpacing for vertical gap between wrapped rows
    local verticalSpacing = rowSpacing
    local rowHeight = iconHeight + verticalSpacing
    local currentRow = 0
    local currentCol = 0
    local iconsInCurrentRow = 0
    
    -- Calculate icons per each row
    local rowIconCounts = {}
    local remaining = count
    for r = 1, numRows do
        local iconsThisRow = math.min(iconsPerRow, remaining)
        -- For last row, check if we need to balance
        if r == numRows and iconsThisRow == 1 and r > 1 then
            -- Steal one from previous row
            rowIconCounts[r-1] = rowIconCounts[r-1] - 1
            iconsThisRow = 2
        end
        rowIconCounts[r] = iconsThisRow
        remaining = remaining - iconsThisRow
    end
    
    local iconIndex = 1
    for row = 1, numRows do
        local iconsThisRow = rowIconCounts[row] or 0
        local rowWidth = iconsThisRow * iconWidth + (iconsThisRow - 1) * spacing
        local startX = -rowWidth / 2 + iconWidth / 2
        local yOffset = -(row - 1) * rowHeight
        
        for col = 1, iconsThisRow do
            local frame = rowFrame.icons[iconIndex]
            if frame and frame:IsShown() then
                local x = startX + (col - 1) * (iconWidth + spacing)
                frame:ClearAllPoints()
                frame:SetPoint("TOP", rowFrame, "TOP", x, yOffset)
            end
            iconIndex = iconIndex + 1
        end
    end
    
    -- Update row frame height to accommodate all rows
    rowFrame:SetHeight(numRows * rowHeight)
end

-------------------------------------------------------------------------------
-- Icon Setup and Updates
-------------------------------------------------------------------------------

function CooldownIcons:SetupIcon(frame, spellID, actualSpellID, spellData, rowConfig, rowIndex)
    -- spellID = canonical ID for identification and tag lookups
    -- actualSpellID = the actual rank ID the player knows (for WoW API calls)
    local texture = spellData.icon or self.Utils:GetSpellTexture(actualSpellID or spellID)
    frame.icon:SetTexture(texture)
    frame.spellID = spellID  -- Canonical ID
    frame.actualSpellID = actualSpellID or spellID  -- For GetSpellCooldown, etc.
    frame.spellData = spellData
    frame.rowIndex = rowIndex or 1
    -- dimOnCooldown is now determined dynamically in UpdateIcon based on global setting
    
    -- Configure external cooldown text (OmniCC, ElvUI) based on row assignment
    -- This allows OmniCC to show text on rows where VeevHUD doesn't
    if frame.cooldown then
        self:ConfigureCooldownText(frame.cooldown, frame.rowIndex)
        
        -- Configure bling effect per-row
        local db = addon.db and addon.db.profile.icons or {}
        local blingEnabled = addon.Database:IsRowSettingEnabled(db.cooldownBlingRows, frame.rowIndex)
        frame.cooldown:SetDrawBling(blingEnabled)
    end
    
    -- Check if this is a reactive spell (Execute, Revenge, Overpower)
    -- These allow repeated ready glows based on condition changes (e.g., target HP)
    frame.isReactive = false
    if spellData.tags then
        for _, tag in ipairs(spellData.tags) do
            if tag == "REACTIVE" then
                frame.isReactive = true
                break
            end
        end
    end
end

function CooldownIcons:UpdateAllIcons()
    if not self.rows then return end

    local db = addon.db.profile.icons

    for rowIndex, rowFrame in pairs(self.rows) do
        if rowFrame then
            for _, iconFrame in ipairs(rowFrame.icons) do
                if iconFrame:IsShown() and iconFrame.spellID then
                    self:UpdateIconState(iconFrame, db)
                end
            end
        end
    end
    
    -- Apply dynamic sorting to configured rows
    local dynamicSortRows = db.dynamicSortRows
    if dynamicSortRows ~= "none" then
        self:ApplyDynamicSorting(dynamicSortRows)
    end
end

-- Determine which rows should have dynamic sorting based on setting
function CooldownIcons:ShouldDynamicSortRow(rowIndex, dynamicSortRows)
    return addon.Database:IsRowSettingEnabled(dynamicSortRows, rowIndex)
end

-- Apply dynamic sorting to all configured rows
function CooldownIcons:ApplyDynamicSorting(dynamicSortRows)
    for rowIndex, rowFrame in pairs(self.rows) do
        if rowFrame and self:ShouldDynamicSortRow(rowIndex, dynamicSortRows) then
            self:SortRowByTimeRemaining(rowFrame, rowIndex)
        end
    end
end

-------------------------------------------------------------------------------
-- Dynamic Sorting by Time Remaining
-------------------------------------------------------------------------------

-- Reusable tables for sorting (avoids GC pressure from allocating every frame)
-- Per-row caches to support multi-row dynamic sorting
local dynamicSortCache = {}
local previousSortOrder = {}  -- previousSortOrder[rowIndex] = { spellID1, spellID2, ... }

-- Comparison function for sorting (defined once, not as closure each frame)
local function compareByActionableTime(a, b)
    local timeA = a.actionableTime or 0
    local timeB = b.actionableTime or 0
    if timeA ~= timeB then
        return timeA < timeB
    end
    -- Tie-breaker: use default order (stored during RebuildAllRows)
    local orderA = a.defaultSortOrder or a.spellID or 0
    local orderB = b.defaultSortOrder or b.spellID or 0
    return orderA < orderB
end

-- Sort a specific row by "actionable time" (least time remaining first)
-- This is useful for DOT-tracking classes to see which ability needs attention soonest
-- Optimized to minimize GC pressure and skip work when order hasn't changed
function CooldownIcons:SortRowByTimeRemaining(rowFrame, rowIndex)
    if not rowFrame then return end
    
    local db = addon.db.profile.icons
    local useAnimation = db.dynamicSortAnimation ~= false  -- default true
    
    -- Reuse cached table (wipe and refill instead of allocating new)
    wipe(dynamicSortCache)
    for _, iconFrame in ipairs(rowFrame.icons) do
        if iconFrame:IsShown() and iconFrame.spellID then
            dynamicSortCache[#dynamicSortCache + 1] = iconFrame
        end
    end
    
    local iconCount = #dynamicSortCache
    if iconCount == 0 then return end
    
    -- Sort by actionable time (ascending - least time remaining first)
    table.sort(dynamicSortCache, compareByActionableTime)
    
    -- Initialize per-row previous order cache if needed
    if not previousSortOrder[rowIndex] then
        previousSortOrder[rowIndex] = {}
    end
    local prevOrder = previousSortOrder[rowIndex]
    
    -- Check if sort order actually changed (compare spellIDs in order)
    local orderChanged = false
    if #prevOrder ~= iconCount then
        orderChanged = true
    else
        for i = 1, iconCount do
            if prevOrder[i] ~= dynamicSortCache[i].spellID then
                orderChanged = true
                break
            end
        end
    end
    
    -- Update previous order cache
    if orderChanged then
        wipe(prevOrder)
        for i = 1, iconCount do
            prevOrder[i] = dynamicSortCache[i].spellID
        end
    end
    
    -- Skip repositioning if order hasn't changed and all icons have positions
    -- (Animation mode still needs to run to handle ongoing animations)
    if not orderChanged and not useAnimation then
        -- Verify all icons have valid positions before skipping
        local allPositioned = true
        for i = 1, iconCount do
            if not dynamicSortCache[i].dynamicSortCurrentX then
                allPositioned = false
                break
            end
        end
        if allPositioned then
            return
        end
    end
    
    -- Use per-row settings
    local iconWidth = rowFrame.iconWidth or db.iconSize
    local spacing = rowFrame.iconSpacing
    if spacing == nil then
        spacing = db.iconSpacing
    end
    
    -- Calculate centered positioning
    local totalWidth = iconCount * iconWidth + (iconCount - 1) * spacing
    local startX = -totalWidth / 2 + iconWidth / 2
    
    for i, iconFrame in ipairs(dynamicSortCache) do
        local targetX = startX + (i - 1) * (iconWidth + spacing)
        
        if useAnimation then
            -- Initialize current position if not set (first time)
            if not iconFrame.dynamicSortCurrentX then
                iconFrame.dynamicSortCurrentX = targetX
                iconFrame:ClearAllPoints()
                iconFrame:SetPoint("CENTER", rowFrame, "CENTER", targetX, 0)
            end
            
            -- Only update target if it changed (avoids unnecessary work)
            if iconFrame.dynamicSortTargetX ~= targetX then
                iconFrame.dynamicSortTargetX = targetX
            end
        else
            -- No animation - only reposition if position actually changed
            if iconFrame.dynamicSortCurrentX ~= targetX then
                iconFrame:ClearAllPoints()
                iconFrame:SetPoint("CENTER", rowFrame, "CENTER", targetX, 0)
                iconFrame.dynamicSortCurrentX = targetX
                iconFrame.dynamicSortTargetX = targetX
            end
        end
    end
    
    -- Start slide animation if enabled
    -- Per-row check is done inside StartDynamicSortSlideUpdate
    if useAnimation then
        self:StartDynamicSortSlideUpdate(rowFrame)
    end
end

-- Smooth sliding animation for dynamic sort repositioning
-- Uses lerp with a fast slide speed for snappy, combat-friendly feedback
-- Handles multiple rows with animations running simultaneously
function CooldownIcons:StartDynamicSortSlideUpdate(rowFrame)
    -- Track per-row animation state
    if not self.dynamicSortSlideActive then
        self.dynamicSortSlideActive = {}
    end
    
    -- If this row already has an animation running, don't start another
    if self.dynamicSortSlideActive[rowFrame] then return end
    
    self.dynamicSortSlideActive[rowFrame] = true
    self.dynamicSortSlideRunning = true
    
    -- Fast slide speed for snappy feel (higher = faster)
    -- 20 is faster than ProcTracker's 12, suitable for combat tracking
    local slideSpeed = 20
    
    rowFrame:SetScript("OnUpdate", function(_, elapsed)
        local allSettled = true
        
        for _, iconFrame in ipairs(rowFrame.icons) do
            if iconFrame:IsShown() and iconFrame.dynamicSortCurrentX and iconFrame.dynamicSortTargetX then
                local diff = iconFrame.dynamicSortTargetX - iconFrame.dynamicSortCurrentX
                
                -- If close enough, snap to target
                if math.abs(diff) < 0.5 then
                    if iconFrame.dynamicSortCurrentX ~= iconFrame.dynamicSortTargetX then
                        iconFrame.dynamicSortCurrentX = iconFrame.dynamicSortTargetX
                        iconFrame:ClearAllPoints()
                        iconFrame:SetPoint("CENTER", rowFrame, "CENTER", iconFrame.dynamicSortTargetX, 0)
                    end
                else
                    -- Lerp toward target (ease-out feel)
                    allSettled = false
                    local move = diff * math.min(1, elapsed * slideSpeed)
                    iconFrame.dynamicSortCurrentX = iconFrame.dynamicSortCurrentX + move
                    iconFrame:ClearAllPoints()
                    iconFrame:SetPoint("CENTER", rowFrame, "CENTER", iconFrame.dynamicSortCurrentX, 0)
                end
            end
        end
        
        -- Stop updating when all icons have settled
        if allSettled then
            rowFrame:SetScript("OnUpdate", nil)
            self.dynamicSortSlideActive[rowFrame] = nil
            
            -- Check if any rows still have active animations
            local anyActive = false
            for _, active in pairs(self.dynamicSortSlideActive) do
                if active then
                    anyActive = true
                    break
                end
            end
            if not anyActive then
                self.dynamicSortSlideRunning = false
            end
        end
    end)
end

-- Reset dynamic sort position tracking (called when rebuilding rows)
function CooldownIcons:ResetDynamicSortPositions()
    -- Reset all rows
    for rowIndex, rowFrame in pairs(self.rows or {}) do
        if rowFrame then
            for _, iconFrame in ipairs(rowFrame.icons) do
                iconFrame.dynamicSortCurrentX = nil
                iconFrame.dynamicSortTargetX = nil
            end
            
            -- Stop any running animation on this row
            if self.dynamicSortSlideActive and self.dynamicSortSlideActive[rowFrame] then
                rowFrame:SetScript("OnUpdate", nil)
                self.dynamicSortSlideActive[rowFrame] = nil
            end
        end
    end
    
    -- Clear cached sort order for all rows
    wipe(previousSortOrder)
    
    self.dynamicSortSlideRunning = false
end

function CooldownIcons:UpdateIconState(frame, db)
    local spellID = frame.spellID  -- Canonical ID for lookups
    local actualSpellID = frame.actualSpellID or spellID  -- Rank ID for WoW API calls
    if not spellID then return end

    -- Check for active aura (debuff/buff applied by this spell)
    -- Only if aura tracking is enabled in settings
    local auraActive = false
    local auraRemaining, auraDuration, auraStacks = 0, 0, 0
    local spellData = frame.spellData
    
    if db.showAuraTracking ~= false then
        local auraTracker = addon:GetModule("AuraTracker")
        auraActive = auraTracker and auraTracker:IsAuraActive(spellID)
        if auraTracker then
            auraRemaining, auraDuration, auraStacks = auraTracker:GetAuraRemaining(spellID)
        end
        
        -- For shared CD abilities (Reck/Retal/SWall), also check buffs directly
        -- since AuraTracker may not track non-displayed spells
        -- Skip if spell has ignoreAura set (e.g., Bloodthirst buff is longer than CD)
        -- Respects target context: heals/external buffs check the relevant target
        local shouldCheckBuff = not (spellData and spellData.ignoreAura)
        
        if shouldCheckBuff then
            -- Determine buff tracking behavior:
            -- - Self-only spells: always check self
            -- - Rotational spells that can target others: check relevant target (ally if targeting ally)
            -- - Non-rotational spells that can target others: check self (always track behavior)
            local checkSelfOnly = true
            if addon.LibSpellDB then
                local isSelfOnly = addon.LibSpellDB:IsSelfOnly(spellData)
                local isRotational = addon.LibSpellDB:IsRotational(spellData)
                -- Only follow target context for rotational spells that can target others
                checkSelfOnly = isSelfOnly or not isRotational
            end
            
            local isBuffActive, buffRemaining, buffDuration, buffStacks = self:GetRelevantBuff(actualSpellID, checkSelfOnly)
            if isBuffActive then
                -- Always prefer buff data for permanent buffs (duration=0)
                -- This handles Shadowform, Stealth, Aspects, etc. correctly
                if buffDuration == 0 or not auraActive then
                    auraActive = true
                    auraRemaining = buffRemaining
                    auraDuration = buffDuration
                    auraStacks = buffStacks or 0
                end
            end
        end
    end

    -- Get cooldown info (including actual start time for accurate spiral)
    -- Use actualSpellID (the rank the player knows) for WoW API calls
    local remaining, duration, cdEnabled, cdStartTime = self.Utils:GetSpellCooldown(actualSpellID)
    
    -- GCD override protection: The WoW API can briefly return GCD info (1.5s duration)
    -- instead of the actual cooldown for certain spells (e.g., Blood Fury variants 33697, 33702).
    -- This causes the icon to briefly show as "ready" during GCD when it's actually on cooldown.
    -- Fix: Track real cooldowns and don't let GCD override them.
    local GCD_THRESHOLD = self.C.GCD_THRESHOLD
    if duration > GCD_THRESHOLD and cdStartTime > 0 then
        -- Store real cooldown info for this spell
        frame.actualCdStart = cdStartTime
        frame.actualCdDuration = duration
    elseif duration > 0 and duration <= GCD_THRESHOLD and frame.actualCdStart and frame.actualCdDuration then
        -- API returned GCD-like duration, but we have a tracked real cooldown
        -- Check if the tracked cooldown should still be active
        local trackedRemaining = (frame.actualCdStart + frame.actualCdDuration) - GetTime()
        if trackedRemaining > GCD_THRESHOLD then
            -- Real cooldown is still active and longer than GCD - use tracked values
            cdStartTime = frame.actualCdStart
            duration = frame.actualCdDuration
            remaining = trackedRemaining
        else
            -- Tracked cooldown has expired or is about to - clear tracking
            frame.actualCdStart = nil
            frame.actualCdDuration = nil
        end
    elseif remaining <= 0 then
        -- Spell is off cooldown - clear tracking
        frame.actualCdStart = nil
        frame.actualCdDuration = nil
    end
    
    -- Calculate "actionable time" for dynamic sorting
    -- This is when the ability will need attention: max(cooldown_remaining, aura_remaining)
    -- If both are 0, the ability is ready to be cast now
    -- Permanent buffs (Shadowform, Stealth, etc.) get very high actionableTime to sort right
    local effectiveCooldownRemaining = self.Utils:IsOnRealCooldown(remaining, duration) and remaining or 0
    local isPermanentBuffActive = auraActive and auraDuration == 0 and auraRemaining == 0
    if isPermanentBuffActive then
        -- Permanent buff active - sort to the right (doesn't need attention)
        frame.actionableTime = 999999
    else
        frame.actionableTime = math.max(effectiveCooldownRemaining, auraRemaining or 0)
    end
    
    -- Check for target lockout debuff (e.g., Weakened Soul for PWS, Forbearance for Paladin immunities)
    -- Use the MORE RESTRICTIVE of actual cooldown vs lockout debuff
    -- Example: Divine Shield (5min CD) + Forbearance (1min) -> show 5min CD
    -- Example: Avenging Wrath (ready) + Forbearance (1min) -> show 1min lockout
    local targetLockoutActive = false
    local targetLockoutRemaining, targetLockoutDuration, targetLockoutExpiration = 0, 0, 0
    local lockoutIsLimitingFactor = false  -- Track if lockout (not CD) is what's limiting us
    
    if spellData and spellData.targetLockoutDebuff then
        -- Determine lockout checking behavior (same logic as buff tracking):
        -- - Self-only spells: always check self
        -- - Rotational spells that can target others: check relevant target
        -- - Non-rotational spells: check self (major cooldowns, always track)
        local checkSelfOnly = true
        if addon.LibSpellDB then
            local isSelfOnly = addon.LibSpellDB:IsSelfOnly(spellData)
            local isRotational = addon.LibSpellDB:IsRotational(spellData)
            checkSelfOnly = isSelfOnly or not isRotational
        end
        targetLockoutActive, targetLockoutRemaining, targetLockoutDuration, targetLockoutExpiration = 
            self:GetTargetLockoutDebuff(spellData.targetLockoutDebuff, checkSelfOnly)
        
        if targetLockoutActive and targetLockoutRemaining > 0 then
            -- Use whichever is more restrictive (longer remaining time)
            if targetLockoutRemaining > remaining then
                -- Lockout debuff is more restrictive - use it
                lockoutIsLimitingFactor = true
                remaining = targetLockoutRemaining
                duration = targetLockoutDuration
                -- Calculate start time from expiration for accurate spiral
                cdStartTime = targetLockoutExpiration - targetLockoutDuration
            end
            -- else: actual cooldown is more restrictive - keep it
            
            -- Update actionableTime to factor in the lockout for dynamic sorting
            if not isPermanentBuffActive then
                frame.actionableTime = math.max(frame.actionableTime, targetLockoutRemaining)
            end
        end
    end
    
    -- Determine if this is GCD vs actual cooldown
    local isOnGCD = self.Utils:IsOnGCD(remaining, duration)
    local isOnActualCooldown = self.Utils:IsOnRealCooldown(remaining, duration)
    local almostReady = remaining > 0 and remaining <= C.READY_GLOW_THRESHOLD and isOnActualCooldown

    -- Determine if this row dims icons on cooldown based on global setting
    -- When false: full alpha + desaturation (keeps core rotation visually prominent)
    -- When true: reduced alpha on cooldown (traditional behavior)
    local rowIndex = frame.rowIndex or 1
    local dimOnCooldown = addon.Database:IsRowSettingEnabled(db.dimOnCooldown, rowIndex)
    
    -- Determine if GCD should be shown for this row based on settings
    local showGCDForThisRow = addon.Database:IsRowSettingEnabled(db.showGCDOn, rowIndex)

    -- Get usability info (uses spell NAME which correctly handles Execute, Revenge, etc.)
    -- Uses actualSpellID since GetEffectiveSpellID handles rank conversion internally
    local isUsable, notEnoughMana = self:IsSpellUsable(actualSpellID)
    
    -- Update actionableTime for conditional spells (Execute, Victory Rush, etc.)
    -- If spell is off cooldown but not usable, sort it after short-cooldown spells
    -- This prevents Execute from always sorting left when target is >20% HP
    if not isPermanentBuffActive and frame.actionableTime == 0 and not isUsable then
        -- Spell is "ready" but not usable due to conditions
        -- Give it low priority (after most cooldowns, before permanent buffs)
        frame.actionableTime = 60
    end
    
    -- Check for spell activation overlay (for proc glow display)
    -- Use actualSpellID since WoW overlay events use actual spell IDs
    local hasOverlay = self:HasSpellActivationOverlay(actualSpellID)
    
    -- Get power/resource info for resource display
    -- Uses actualSpellID since GetEffectiveSpellID handles rank conversion internally
    local powerCost, currentPower, maxPower, powerType, powerColor = self.Utils:GetSpellPowerInfo(actualSpellID)
    local hasResourceCost = powerCost and powerCost > 0
    local resourcePercent = hasResourceCost and math.min(1, currentPower / powerCost) or 1
    local canAfford = resourcePercent >= 1

    -- Prediction mode: extend cooldown to show when spell will be affordable
    -- Track state on frame for fallback handling
    local displayMode = db.resourceDisplayMode
    local displayRows = db.resourceDisplayRows
    local rowIndex = frame.rowIndex or 1
    local isPredictionMode = displayMode == C.RESOURCE_DISPLAY_MODE.PREDICTION
    local resourceEnabledForRow = addon.Database:IsRowSettingEnabled(displayRows, rowIndex)
    local timeUntilAffordable = 0
    local predictionRemaining = 0
    local predictionDuration = 0
    local predictionStartTime = 0
    local showPredictionSpiral = false
    local inPredictionFallback = false
    
    -- Skip prediction if aura is active - aura display takes precedence
    -- (e.g., Power Word: Shield active - show buff duration, not mana prediction)
    -- Also skip if resource display is not enabled for this row
    local skipPrediction = (auraActive and auraRemaining > 0) or not resourceEnabledForRow
    
    if isPredictionMode and hasResourceCost and not skipPrediction then
        if canAfford then
            -- Can afford now - clear any prediction state
            -- Reset ready glow tracking so it can trigger on this transition
            if frame.predictionActive then
                frame.readyGlowShown = false  -- Allow ready glow to show
            end
            frame.predictionActive = false
            frame.predictionStartTime = nil
            frame.predictionDuration = nil
            frame.predictionFallback = false
            frame.predictionLastPower = nil
        else
            -- Can't afford - calculate time until affordable
            local ResourcePrediction = addon.ResourcePrediction
            if ResourcePrediction then
                timeUntilAffordable = ResourcePrediction:GetTimeUntilAffordable(spellID)
            end
            
            -- Ensure timeUntilAffordable is reasonable (at least 0.1s to avoid flicker)
            -- This handles race conditions where tick tracking hasn't updated yet
            if timeUntilAffordable > 0 and timeUntilAffordable < 0.1 then
                timeUntilAffordable = 0.1
            end
            
            -- Determine what to show
            local isOffCooldown = self.Utils:IsOffCooldown(remaining, duration)
            local cdRemaining = isOffCooldown and 0 or remaining
            
            -- Use max of cooldown and resource prediction
            local effectiveWait = math.max(cdRemaining, timeUntilAffordable)
            
            -- Detect if resources were spent (need to restart prediction)
            -- This handles the case where user casts something else mid-prediction
            local resourcesSpent = frame.predictionActive and frame.predictionLastPower and currentPower < frame.predictionLastPower
            
            -- If prediction is already active and in fallback mode, stay in fallback
            -- (don't restart prediction spiral after fallback was triggered)
            if frame.predictionFallback and not resourcesSpent then
                inPredictionFallback = true
            elseif effectiveWait > 0 then
                if not frame.predictionActive or resourcesSpent then
                    -- Start new prediction (or restart because resources were spent)
                    frame.predictionActive = true
                    frame.predictionStartTime = GetTime()
                    frame.predictionDuration = effectiveWait
                    frame.predictionFallback = false
                    -- Reset ready glow so it can trigger when prediction completes
                    if not resourcesSpent then
                        frame.readyGlowShown = false
                    end
                end
                
                -- Track current power to detect spending
                frame.predictionLastPower = currentPower
                
                -- Calculate remaining time from when prediction started
                -- Use stored values to ensure smooth countdown (no recalculation mid-prediction)
                local elapsed = GetTime() - frame.predictionStartTime
                predictionRemaining = math.max(0, frame.predictionDuration - elapsed)
                predictionDuration = frame.predictionDuration
                predictionStartTime = frame.predictionStartTime
                
                -- Check if prediction expired but still can't afford (fallback case)
                -- Use small threshold to avoid floating point issues
                if predictionRemaining < 0.05 then
                    -- Prediction was wrong - switch to deterministic fallback
                    frame.predictionFallback = true
                    inPredictionFallback = true
                else
                    showPredictionSpiral = true
                end
            else
                -- effectiveWait is 0 but we can't afford - use fallback
                -- This happens for rage (unpredictable) or if tick tracking isn't ready
                frame.predictionFallback = true
                inPredictionFallback = true
            end
        end
    elseif not isPredictionMode then
        -- Not in prediction mode - clear any state
        frame.predictionActive = false
        frame.predictionStartTime = nil
        frame.predictionDuration = nil
        frame.predictionFallback = false
    end

    -- Get charges
    local charges, maxCharges = self:GetSpellCharges(spellID)
    local hasCharges = maxCharges and maxCharges > 1
    local noChargesLeft = hasCharges and charges == 0

    -- Only suppress desaturation/usability checks when RESTING and OUT OF COMBAT
    -- This means in PvP or open world, you'll still see indicators even if combat drops
    local inCombat = UnitAffectingCombat("player")
    local isResting = IsResting()
    local showUsabilityIndicators = inCombat or not isResting

    -- Initialize state
    local alpha = db.readyAlpha
    local desaturate = false
    local showSpinner = false
    local showText = false
    local showGlow = false
    local showAuraActive = false
    local auraDisplayRemaining = 0
    local auraDisplayDuration = 0
    
    -- Detect permanent buff (active but no duration, e.g., Shadowform, Stealth)
    local isPermanentBuffActive = auraActive and auraDuration == 0 and auraRemaining == 0

    -----------------------------------------------------------------------
    -- AURA ACTIVE STATE (overrides normal cooldown display)
    -- When a debuff/buff from this spell is active on a target
    -----------------------------------------------------------------------
    if auraActive and auraRemaining > 0 then
        -----------------------------------------------------------------------
        -- TIMED AURA ACTIVE STATE
        -- Debuff/buff from this spell is active with a duration
        -----------------------------------------------------------------------
        showAuraActive = true
        auraDisplayRemaining = auraRemaining
        auraDisplayDuration = auraDuration
        alpha = db.readyAlpha  -- Full alpha
        showGlow = true  -- Show animated glow while active
        showSpinner = true  -- Show spiral for aura duration
        showText = true  -- Show aura duration
        desaturate = false
        
    elseif isPermanentBuffActive then
        -----------------------------------------------------------------------
        -- PERMANENT BUFF ACTIVE STATE (e.g., Shadowform, Stealth, Aspects)
        -- Buff is active but has no duration - show subtle active indicator
        -- Don't show cooldown while buff is active (it's already cast)
        -- Cooldown only matters if buff is removed and needs to be recast
        -----------------------------------------------------------------------
        showAuraActive = true
        alpha = db.readyAlpha  -- Full alpha
        showGlow = true  -- Subtle static glow to indicate active state
        desaturate = false
        showSpinner = false  -- No cooldown display while buff is active
        showText = false
        
    elseif not dimOnCooldown then
        -----------------------------------------------------------------------
        -- NO DIM ON COOLDOWN (default for Primary row)
        -- Always 100% alpha, use desaturation for unavailable state
        -----------------------------------------------------------------------
        alpha = db.readyAlpha  -- Always 100%

        -- Desaturate when: no charges OR not usable
        -- Only suppress when resting AND out of combat (e.g., in town)
        if showUsabilityIndicators then
            if noChargesLeft then
                desaturate = true
            elseif not isUsable then
                desaturate = true
            end
        end

        -- Show GCD spinner for core abilities
        if isOnGCD then
            showSpinner = true
            showText = false  -- No text for GCD
        elseif isOnActualCooldown then
            showSpinner = true
            showText = duration >= 2  -- Only show text if cooldown >= 2 sec
        end

        -- Glow when almost ready (< 1 sec remaining on real cooldown)
        if almostReady then
            showGlow = true
        end

        -- Check for spell activation overlay (proc)
        -- Use actualSpellID since WoW overlay events use actual spell IDs
        if self:HasSpellActivationOverlay(actualSpellID) then
            showGlow = true
            desaturate = false  -- Never desaturate a proc
        end

    else
        -----------------------------------------------------------------------
        -- DIM ON COOLDOWN (default for Secondary/Utility rows)
        -- Reduced alpha when on cooldown
        -- GCD display controlled by showGCDOn setting
        -----------------------------------------------------------------------
        
        -- Is this a real cooldown (duration > GCD) or just the GCD?
        local isRealCooldown = self.Utils:IsOnRealCooldown(remaining, duration)
        
        if isRealCooldown then
            -- On actual cooldown (not just GCD): dim + spinner + text + desaturate
            alpha = db.cooldownAlpha
            desaturate = true
            showSpinner = true
            showText = duration >= 2  -- Only show text if cooldown >= 2 sec
            
            -- Glow when almost ready (< 1 sec remaining)
            if almostReady then
                showGlow = true
            end
        elseif isOnGCD and showGCDForThisRow then
            -- Show GCD spinner for this row (based on setting)
            showSpinner = true
            showText = false  -- No text for GCD
            alpha = db.readyAlpha  -- Keep full alpha during GCD
        elseif noChargesLeft then
            -- No charges left: dim + desaturate
            alpha = db.cooldownAlpha
            desaturate = true
            showSpinner = true
            showText = true
        else
            -- Ready to use (ignore GCD for non-core)
            alpha = db.readyAlpha
            
            -- Desaturate when not usable (suppressed only when resting and out of combat)
            if showUsabilityIndicators and not isUsable and db.desaturateNoResources then
                desaturate = true
            end
        end
    end

    -- Show/hide cooldown spiral (row-based setting)
    local showSpiralForRow = addon.Database:IsRowSettingEnabled(db.showCooldownSpiralOn, rowIndex)
    
    -- Prediction mode can show spiral even when spell is off cooldown
    local shouldShowSpiral = showSpinner or showPredictionSpiral
    
    if shouldShowSpiral and showSpiralForRow then
        frame.cooldown:SetAlpha(1)
        frame.cooldown:SetSwipeColor(0, 0, 0, 0.8)
        
        if showPredictionSpiral and predictionDuration > 0 then
            -- Show prediction spiral (waiting for resources)
            -- Uses same visual as cooldown: remaining = dark, elapsed = bright
            frame.cooldown:SetReverse(false)
            -- Only update if prediction changed to avoid visual glitches
            if frame.lastCdStart ~= predictionStartTime or frame.lastCdDuration ~= predictionDuration then
                frame.cooldown:SetCooldown(predictionStartTime, predictionDuration)
                frame.lastCdStart = predictionStartTime
                frame.lastCdDuration = predictionDuration
            end
            frame.cooldown:Show()
            frame._wasRealCooldown = false  -- Prediction, no bling
        elseif showAuraActive and auraDisplayDuration > 0 then
            -- Show aura duration spiral (remaining = bright, elapsed = dark)
            frame.cooldown:SetReverse(true)  -- Swipe fills as time passes (elapsed = dark)
            local start = GetTime() - (auraDisplayDuration - auraDisplayRemaining)
            -- Only update if cooldown changed to avoid visual glitches
            if frame.lastCdStart ~= start or frame.lastCdDuration ~= auraDisplayDuration then
                frame.cooldown:SetCooldown(start, auraDisplayDuration)
                frame.lastCdStart = start
                frame.lastCdDuration = auraDisplayDuration
            end
            frame.cooldown:Show()
            frame._wasRealCooldown = false  -- Aura spiral, no bling
        elseif duration > 0 and cdStartTime > 0 then
            -- Normal cooldown spiral (remaining = dark, elapsed = bright)
            -- Use actual start time from API for accuracy
            frame.cooldown:SetReverse(false)  -- Swipe drains as time passes (remaining = dark)
            -- Only update if cooldown changed to avoid visual glitches
            if frame.lastCdStart ~= cdStartTime or frame.lastCdDuration ~= duration then
                frame.cooldown:SetCooldown(cdStartTime, duration)
                frame.lastCdStart = cdStartTime
                frame.lastCdDuration = duration
            end
            frame._wasRealCooldown = true  -- Real cooldown, bling should play
            frame.cooldown:Show()
        else
            -- No active cooldown/aura - clear tracking
            -- For real cooldowns: let bling animation finish naturally
            -- For predictions/auras: clear immediately (no bling)
            if not frame._wasRealCooldown then
                frame.cooldown:SetCooldown(0, 0)  -- Clear non-cooldown spirals immediately
            end
            frame.lastCdStart = nil
            frame.lastCdDuration = nil
            frame._wasRealCooldown = nil
        end
    else
        -- Row setting disables spiral
        -- For real cooldowns: let bling play, for others: clear immediately
        if not frame._wasRealCooldown then
            frame.cooldown:SetCooldown(0, 0)
        end
        frame.lastCdStart = nil
        frame.lastCdDuration = nil
        frame._wasRealCooldown = nil
    end

    -- Show/hide cooldown text (or aura duration text) - row-based setting
    local showTextForRow = addon.Database:IsRowSettingEnabled(db.showCooldownTextOn, rowIndex)
    
    if showPredictionSpiral and predictionRemaining > 0 and showTextForRow then
        -- Show prediction remaining time (waiting for resources)
        -- Use same color as cooldown text for consistency
        frame.text:SetText(self.Utils:FormatCooldown(predictionRemaining))
        frame.text:SetTextColor(self.C.COLORS.TEXT.r, self.C.COLORS.TEXT.g, self.C.COLORS.TEXT.b)
    elseif showAuraActive and auraDisplayRemaining > 0 and showTextForRow then
        -- Show aura remaining time
        -- Always show our own text for aura duration (OmniCC doesn't track this)
        frame.text:SetText(self.Utils:FormatCooldown(auraDisplayRemaining))
        frame.text:SetTextColor(self.C.COLORS.TEXT.r, self.C.COLORS.TEXT.g, self.C.COLORS.TEXT.b)
    elseif showText and showTextForRow and remaining > 0 then
        -- For cooldowns, respect useOwnCooldownText setting
        local useOwnText = db.useOwnCooldownText ~= false  -- Default true
        if useOwnText then
            frame.text:SetText(self.Utils:FormatCooldown(remaining))
            -- Always use the same color for cooldown text
            frame.text:SetTextColor(self.C.COLORS.TEXT.r, self.C.COLORS.TEXT.g, self.C.COLORS.TEXT.b)
        else
            frame.text:SetText("")  -- Let external addon show text
        end
    else
        frame.text:SetText("")
    end

    -- Resource-based desaturation: if ability is ready (off cooldown) but lacking resources,
    -- desaturate to clearly show it's not usable yet
    -- Only suppress when RESTING and OUT OF COMBAT (town/inn) to avoid grey icons there
    -- In PvP/world, indicators remain active even if combat drops briefly
    -- Note: For core rotation abilities, desaturation is already handled above via isUsable.
    -- IsUsableSpell checks ALL conditions (resources, target health, etc.) so we don't
    -- need a separate resource-based desaturation check here.

    -- Store alpha on frame for use by glows and resource display
    frame.iconAlpha = alpha
    
    -- Apply alpha to the entire frame (affects all children and styling)
    -- Use smooth transition if enabled and alpha changed
    local animDb = addon.db.profile.animations or {}
    local targetAlpha = frame._targetAlpha
    local isTransitioning = frame._alphaAnimating
    
    -- Only animate dim transition when going ON cooldown (alpha decreasing)
    -- When coming OFF cooldown, snap to full alpha so bling isn't dimmed
    -- Timing: Delay 0.08s to sync with cast feedback shrink phase (if cast feedback enabled)
    if animDb.dimTransition and self.Animations then
        if targetAlpha ~= alpha then
            local currentAlpha = frame:GetAlpha()
            if alpha < currentAlpha then
                -- Dimming - delay only if cast feedback animation is currently playing
                -- Cancel any pending dim timer
                if frame._dimTimer then
                    frame._dimTimer:Cancel()
                    frame._dimTimer = nil
                end
                
                -- Only delay if cast feedback just played (within last 0.2s = total punch duration)
                local castFeedbackPlaying = frame._lastCastFeedbackTime and 
                    (GetTime() - frame._lastCastFeedbackTime) < 0.2
                local dimDelay = castFeedbackPlaying and 0.08 or 0
                
                -- Speed of 6 means ~0.12s for 0.7 alpha change (1.0 -> 0.3)
                if dimDelay > 0 then
                    frame._dimTimer = C_Timer.After(dimDelay, function()
                        if frame and frame:IsShown() then
                            self.Animations:TransitionAlpha(frame, alpha, 6)
                        end
                        frame._dimTimer = nil
                    end)
                else
                    -- No delay - start dim immediately
                    self.Animations:TransitionAlpha(frame, alpha, 6)
                end
            else
                -- Brightening (coming off cooldown) - cancel pending dim and snap immediately
                if frame._dimTimer then
                    frame._dimTimer:Cancel()
                    frame._dimTimer = nil
                end
                self.Animations:StopAlphaTransition(frame)
                frame:SetAlpha(alpha)
            end
            frame._targetAlpha = alpha
        end
        -- If already transitioning to this alpha, let it continue
    else
        -- Animation disabled - cancel any pending dim and set directly
        if frame._dimTimer then
            frame._dimTimer:Cancel()
            frame._dimTimer = nil
        end
        if self.Animations then
            self.Animations:StopAlphaTransition(frame)
        end
        frame:SetAlpha(alpha)
        frame._targetAlpha = alpha
    end
    
    -- Apply desaturation to icon (instant - always accurate state)
    frame.icon:SetDesaturated(desaturate)

    -- Update charges display
    if hasCharges then
        frame.charges:SetText(charges)
    else
        frame.charges:SetText("")
    end

    -- Update stacks display (for aura stacks like Rampage, Lifebloom, Sunder)
    if auraActive and auraStacks and auraStacks > 1 then
        frame.stacks:SetText(auraStacks)
    else
        frame.stacks:SetText("")
    end

    -- Update resource display (only show when ability is ready but lacking resources)
    -- In prediction mode: hide during active prediction, show vertical fill as fallback
    self:UpdateResourceDisplay(frame, spellID, remaining, hasResourceCost, resourcePercent, powerColor, db, showPredictionSpiral, inPredictionFallback)

    -- Handle glow effect (aura active / permanent buff / normal almost-ready glow)
    self:UpdateIconGlow(frame, showGlow, showAuraActive, isPermanentBuffActive)
    
    -- Handle ready glow (proc-style glow when ability becomes usable)
    -- Uses isUsable which checks ALL conditions (resources, target health for Execute, etc.)
    -- Skip if aura is active (that has its own glow)
    if not showAuraActive then
        local isReactive = frame.isReactive or false
        -- Pass lockoutIsLimitingFactor so glow can trigger when lockout is almost expired
        -- (WoW API reports isUsable=false while lockout is active, but we want glow at <1s remaining)
        -- Also pass prediction state so glow can trigger when prediction has <1s remaining
        local predictionIsLimitingFactor = showPredictionSpiral and predictionRemaining > 0
        self:UpdateReadyGlow(frame, spellID, remaining, duration, isUsable, isReactive, db, lockoutIsLimitingFactor, canAfford, predictionIsLimitingFactor, predictionRemaining)
    else
        -- Aura is active - hide ready glow but keep wasUsable updated
        -- This prevents false "just became usable" triggers when aura ends
        frame.wasUsable = isUsable
        if frame.readyGlowActive then
            self:HideReadyGlow(frame)
            frame.readyGlowActive = false
        end
    end
    
    -- Handle range indicator (red overlay when target is out of range)
    -- Only check if setting is enabled for this row and we have a target
    self:UpdateRangeIndicator(frame, actualSpellID, db)
end

-- Update resource cost display (horizontal bar or vertical fill)
-- In prediction mode:
--   - While prediction spiral is active: hide resource display (spiral is the indicator)
--   - When prediction failed (fallback): show vertical fill as deterministic feedback
function CooldownIcons:UpdateResourceDisplay(frame, spellID, cooldownRemaining, hasResourceCost, resourcePercent, powerColor, db, showPredictionSpiral, inPredictionFallback)
    local displayMode = db.resourceDisplayMode
    local displayRows = db.resourceDisplayRows
    local rowIndex = frame.rowIndex or 1
    local isPredictionMode = displayMode == C.RESOURCE_DISPLAY_MODE.PREDICTION
    
    -- Check if resource display is enabled for this row
    local enabledForRow = addon.Database:IsRowSettingEnabled(displayRows, rowIndex)
    
    -- Prediction mode: hide display while spiral is active
    if isPredictionMode and showPredictionSpiral then
        if frame.resourceBar then frame.resourceBar:Hide() end
        if frame.resourceFill then frame.resourceFill:Hide() end
        frame.resourceTarget = nil
        return
    end
    
    -- Only show resource indicator if:
    -- 1. Not resting and out of combat (show in PvP/world even if combat drops)
    -- 2. The spell has a resource cost
    -- 3. We don't have enough resources (resourcePercent < 1)
    -- 4. The ability is off cooldown (cooldown takes visual priority) - unless in prediction fallback
    -- 5. Resource display is enabled for this row
    local inCombat = UnitAffectingCombat("player")
    local isResting = IsResting()
    local showUsability = inCombat or not isResting
    
    -- In prediction fallback, show resource display regardless of cooldown
    local cooldownCheck = inPredictionFallback or cooldownRemaining <= 0
    local showResource = showUsability and hasResourceCost and resourcePercent < 1 and cooldownCheck and enabledForRow
    
    if not showResource then
        -- Hide and reset
        if frame.resourceBar then frame.resourceBar:Hide() end
        if frame.resourceFill then frame.resourceFill:Hide() end
        frame.resourceTarget = nil
        return
    end
    
    local iconSize = frame.iconSize or db.iconSize
    local iconWidth = frame.iconWidth or iconSize
    local iconHeight = frame.iconHeight or iconSize
    
    -- Initialize smooth animation state
    if not frame.resourceCurrent then
        frame.resourceCurrent = resourcePercent
    end
    frame.resourceTarget = resourcePercent
    frame.resourcePowerColor = powerColor
    frame.resourceIconSize = iconSize
    frame.resourceIconWidth = iconWidth
    frame.resourceIconHeight = iconHeight
    
    -- In prediction fallback, always use vertical fill regardless of configured mode
    local effectiveMode = inPredictionFallback and C.RESOURCE_DISPLAY_MODE.FILL or displayMode
    frame.resourceDisplayMode = effectiveMode
    
    -- Set up OnUpdate for smooth animation if not already
    if not frame.resourceOnUpdate then
        frame.resourceOnUpdate = true
        frame:HookScript("OnUpdate", function(f, elapsed)
            -- Get fresh db reference each frame
            local freshDb = addon.db and addon.db.profile.icons or {}
            self:AnimateResourceDisplay(f, elapsed, freshDb)
        end)
    end
    
    if effectiveMode == C.RESOURCE_DISPLAY_MODE.BAR and frame.resourceBar then
        frame.resourceBar:SetHeight(db.resourceBarHeight)
        frame.resourceBar:Show()
        if frame.resourceFill then frame.resourceFill:Hide() end
    elseif effectiveMode == C.RESOURCE_DISPLAY_MODE.FILL and frame.resourceFill then
        -- Frame alpha already handles visibility, just set the resource fill's own alpha
        frame.resourceFill:SetVertexColor(0, 0, 0, db.resourceFillAlpha)
        frame.resourceFill:Show()
        if frame.resourceBar then frame.resourceBar:Hide() end
    end
end

-- Animate resource display smoothly (or instantly if smoothing disabled)
function CooldownIcons:AnimateResourceDisplay(frame, elapsed, db)
    if not frame.resourceTarget then return end
    
    local displayMode = frame.resourceDisplayMode or db.resourceDisplayMode
    local current = frame.resourceCurrent or 0
    local target = frame.resourceTarget
    
    -- Check global animation setting
    local animDb = addon.db.profile.animations or {}
    if animDb.smoothBars then
        -- Smooth interpolation (lerp)
        local speed = 8  -- Higher = faster animation
        local diff = target - current
        
        if math.abs(diff) < 0.01 then
            current = target
        else
            current = current + diff * math.min(1, elapsed * speed)
        end
    else
        -- Instant update
        current = target
    end
    
    frame.resourceCurrent = current
    
    local iconWidth = frame.resourceIconWidth or frame.resourceIconSize or db.iconSize
    local iconHeight = frame.resourceIconHeight or frame.resourceIconSize or db.iconSize
    
    if displayMode == C.RESOURCE_DISPLAY_MODE.BAR and frame.resourceBar and frame.resourceBar:IsShown() then
        -- Horizontal bar fill - use width
        local fillWidth = iconWidth * current
        frame.resourceBar.fill:SetWidth(math.max(1, fillWidth))
        
        if frame.resourcePowerColor then
            local c = frame.resourcePowerColor
            frame.resourceBar.fill:SetVertexColor(c[1], c[2], c[3], 1)
        end
        
    elseif displayMode == C.RESOURCE_DISPLAY_MODE.FILL and frame.resourceFill and frame.resourceFill:IsShown() then
        -- Vertical fill (dark overlay showing missing portion) - use height
        -- Frame alpha handles visibility; vertex color just controls fill darkness
        local missingPercent = 1 - current
        local fillHeight = iconHeight * missingPercent
        frame.resourceFill:SetHeight(math.max(0, fillHeight))
    end
end

-- Check if spell has activation overlay (proc is active)
function CooldownIcons:HasSpellActivationOverlay(spellID)
    -- Check our event-tracked table first
    if self.activeOverlays and self.activeOverlays[spellID] then
        return true
    end
    -- Fallback to API if available
    if IsSpellOverlayed then
        return IsSpellOverlayed(spellID)
    end
    return false
end

-- Update glow effect on icon
-- glowStyle: "aura" (timed aura), "permanent" (permanent buff), or nil (proc/ready glow)
function CooldownIcons:UpdateIconGlow(frame, showGlow, isAuraActive, isPermanentBuff)
    if showGlow then
        local glowType = isPermanentBuff and "permanent" or (isAuraActive and "aura" or "normal")
        local iconAlpha = frame.iconAlpha or 1
        
        -- Check if glow is already showing with correct type AND same alpha
        -- We need to refresh the glow if alpha changed
        if frame.glowActive and frame.glowType == glowType and frame.glowAlpha == iconAlpha then
            return
        end
        
        -- Hide existing glow first if type or alpha changed
        if frame.glowActive then
            self:HideGlow(frame)
        end
        
        if isPermanentBuff then
            -- Permanent buff: Use subtle static glow (like default UI)
            self:ShowPermanentBuffGlow(frame)
        elseif isAuraActive then
            -- Timed aura active: Use pixel glow (animated border)
            self:ShowAuraGlow(frame)
        else
            -- Normal glow: Use standard overlay glow
            if ActionButton_ShowOverlayGlow then
                ActionButton_ShowOverlayGlow(frame)
            elseif self.MasqueGroup and frame.NormalTexture then
                -- Fallback glow only when Masque is active
                frame.NormalTexture:SetVertexColor(1, 1, 0.3)
            end
        end
        
        frame.glowActive = true
        frame.glowType = glowType
        frame.glowAlpha = iconAlpha
    else
        if frame.glowActive then
            self:HideGlow(frame)
            frame.glowActive = false
            frame.glowType = nil
            frame.glowAlpha = nil
        end
    end
end

-- Show static glow for permanent buffs (like Shadowform, Stealth)
-- Mimics the subtle glow effect from the default UI action buttons
function CooldownIcons:ShowPermanentBuffGlow(frame)
    local iconAlpha = frame.iconAlpha or 1
    
    -- Create the static glow overlay if it doesn't exist
    if not frame.permanentGlow then
        frame.permanentGlow = frame:CreateTexture(nil, "OVERLAY", nil, 1)
        frame.permanentGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        frame.permanentGlow:SetBlendMode("ADD")
        -- Offset Y slightly upward to center the glow visually (texture has asymmetric glow)
        frame.permanentGlow:SetPoint("CENTER", frame, "CENTER", 0, 1)
    end
    
    -- Size it slightly larger than the icon for a subtle border glow
    -- Use width (larger dimension with aspect ratio) for proper coverage
    local iconDb = addon.db.profile.icons
    local glowWidth = (frame.iconWidth or frame.iconSize or iconDb.iconSize) * 1.5
    local glowHeight = (frame.iconHeight or frame.iconSize or iconDb.iconSize) * 1.5
    frame.permanentGlow:SetSize(glowWidth, glowHeight)
    
    -- Golden/yellow color to match the default UI active state
    frame.permanentGlow:SetVertexColor(1.0, 0.82, 0.0, 0.6 * iconAlpha)
    frame.permanentGlow:Show()
end

-- Update the "ready glow" - shows when ability becomes ready
-- Triggers:
--   1. <1s remaining on CD/lockout/prediction AND usable -> show for remaining duration
--   2. Was not usable, just became usable (while off CD) -> show for configured duration
-- For Execute: "usable" means target < 20% AND enough rage
-- readyGlowRows controls which rows show the glow ("none" = disabled)
-- readyGlowMode controls behavior:
--   - "once": only glow once per cooldown cycle (default)
--   - "always": glow every time ability becomes ready
-- Reactive abilities (Execute, Overpower) always behave as "always" regardless of mode
-- lockoutIsLimitingFactor: true if the "remaining" time is from a lockout debuff, not the actual CD
-- canAfford: true if player has enough resources to cast the spell
-- predictionIsLimitingFactor: true if Resource Timer prediction is active and limiting usability
-- predictionRemaining: time remaining on prediction (when predictionIsLimitingFactor is true)
function CooldownIcons:UpdateReadyGlow(frame, spellID, remaining, duration, isUsable, isReactive, db, lockoutIsLimitingFactor, canAfford, predictionIsLimitingFactor, predictionRemaining)
    local glowRows = db.readyGlowRows
    local glowMode = db.readyGlowMode
    local rowIndex = frame.rowIndex or 1
    
    -- Check row-based setting first
    local enabledForRow = addon.Database:IsRowSettingEnabled(glowRows, rowIndex)
    
    -- Disabled or not enabled for this row: hide any active glow and return (unless reactive)
    if not enabledForRow and not isReactive then
        if frame.readyGlowActive then
            self:HideReadyGlow(frame)
            frame.readyGlowActive = false
        end
        return
    end
    
    -- Determine effective mode: reactive abilities always use "always" behavior
    local effectiveMode = isReactive and C.GLOW_MODE.ALWAYS or glowMode
    
    local isOnRealCooldown = self.Utils:IsOnRealCooldown(remaining, duration)
    local isAlmostReady = remaining > 0 and remaining <= C.READY_GLOW_THRESHOLD and isOnRealCooldown
    local isOffCooldown = self.Utils:IsOffCooldown(remaining, duration)
    
    -- Check if prediction is almost complete (Resource Timer mode for energy/mana)
    -- When prediction is the limiting factor and almost ready, treat as almost ready
    local isPredictionAlmostReady = predictionIsLimitingFactor and predictionRemaining > 0 and predictionRemaining <= C.READY_GLOW_THRESHOLD
    
    -- When lockout is the limiting factor and almost expired, treat as usable for glow purposes
    -- The WoW API reports isUsable=false while lockout is active, but we want to trigger
    -- the "almost ready" glow when the lockout has <1s remaining (if resources allow)
    local effectiveUsable = isUsable
    if lockoutIsLimitingFactor and isAlmostReady and canAfford then
        effectiveUsable = true
    end
    -- Similarly, when prediction is almost complete, treat as usable for glow purposes
    -- The ability will become usable in <1s when we have enough resources
    if isPredictionAlmostReady then
        effectiveUsable = true
        -- Also treat as "almost ready" for the glow trigger
        isAlmostReady = true
    end
    
    -- Track previous states
    local wasOnRealCooldown = frame.wasOnRealCooldown or false
    local wasUsable = frame.wasUsable or false
    
    -- Detect when ability goes on cooldown (used) -> reset tracking for ALL abilities
    if isOnRealCooldown and not wasOnRealCooldown then
        frame.readyGlowShown = false
        frame.readyGlowExpires = nil
    end
    
    local inCombat = UnitAffectingCombat("player")
    
    -- Reset glow tracking based on effective mode
    if effectiveMode == C.GLOW_MODE.ALWAYS then
        -- Reset glow when usability changes (allows re-triggering)
        if effectiveUsable and not wasUsable then
            frame.readyGlowShown = false
        end
    end
    -- "once" mode: readyGlowShown stays true until ability is used (goes on CD)
    
    -- Check if ready glow should be triggered
    local showReadyGlow = false
    
    if not frame.readyGlowShown then
        local glowDuration = db.readyGlowDuration
        
        -- Condition 1: <1s remaining on CD AND usable
        if isAlmostReady and effectiveUsable and inCombat then
            showReadyGlow = true
            frame.readyGlowShown = true
            frame.readyGlowExpires = GetTime() + glowDuration
            
        -- Condition 2: Just became usable while off CD
        elseif isOffCooldown and effectiveUsable and not wasUsable and inCombat then
            showReadyGlow = true
            frame.readyGlowShown = true
            frame.readyGlowExpires = GetTime() + glowDuration
        end
    end
    
    -- Check if existing ready glow should continue
    if frame.readyGlowExpires and frame.readyGlowExpires > GetTime() then
        showReadyGlow = true
    elseif frame.readyGlowExpires and frame.readyGlowExpires <= GetTime() then
        -- Glow expired
        frame.readyGlowExpires = nil
    end
    
    -- Update stored state for next frame
    frame.wasOnRealCooldown = isOnRealCooldown
    frame.wasUsable = isUsable
    
    -- Show or hide the ready glow
    if showReadyGlow then
        if not frame.readyGlowActive then
            self:ShowReadyGlow(frame)
            frame.readyGlowActive = true
        end
    else
        if frame.readyGlowActive then
            self:HideReadyGlow(frame)
            frame.readyGlowActive = false
        end
    end
end

function CooldownIcons:ShowReadyGlow(frame)
    self.Utils:ShowButtonGlow(frame)
end

function CooldownIcons:HideReadyGlow(frame)
    self.Utils:HideButtonGlow(frame)
end

function CooldownIcons:ShowAuraGlow(frame)
    -- Get icon's current alpha so glow respects Ready/Cooldown Alpha settings
    local iconAlpha = frame.iconAlpha or 1
    
    -- Use shared utility for LibCustomGlow pixel glow
    -- Color #ffcfaf (peachy gold), offset inward by -2
    local color = {1.0, 0.812, 0.686, iconAlpha}
    if self.Utils:ShowPixelGlow(frame, color, "aura", 8, 0.1, 10, 1, -2, -2) then
        return
    end
    
    -- Fallback: Create simple pixel border for aura active state
    if not frame.pixelGlow then
        frame.pixelGlow = {}
        local r, g, b, a = 1, 0.82, 0, iconAlpha  -- Golden yellow with icon alpha
        local thickness = 2
        local offset = 1  -- Offset from icon edge
        
        -- Helper to set solid color (compatible with Classic)
        local function SetSolidColor(tex, r, g, b, a)
            tex:SetTexture("Interface\\Buttons\\WHITE8X8")
            tex:SetVertexColor(r, g, b, a)
        end
        
        -- Top border
        frame.pixelGlow.top = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        SetSolidColor(frame.pixelGlow.top, r, g, b, a)
        frame.pixelGlow.top:SetPoint("TOPLEFT", frame, "TOPLEFT", -offset, offset)
        frame.pixelGlow.top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", offset, offset)
        frame.pixelGlow.top:SetHeight(thickness)
        
        -- Bottom border
        frame.pixelGlow.bottom = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        SetSolidColor(frame.pixelGlow.bottom, r, g, b, a)
        frame.pixelGlow.bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -offset, -offset)
        frame.pixelGlow.bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", offset, -offset)
        frame.pixelGlow.bottom:SetHeight(thickness)
        
        -- Left border
        frame.pixelGlow.left = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        SetSolidColor(frame.pixelGlow.left, r, g, b, a)
        frame.pixelGlow.left:SetPoint("TOPLEFT", frame, "TOPLEFT", -offset, offset - thickness)
        frame.pixelGlow.left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -offset, -offset + thickness)
        frame.pixelGlow.left:SetWidth(thickness)
        
        -- Right border
        frame.pixelGlow.right = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        SetSolidColor(frame.pixelGlow.right, r, g, b, a)
        frame.pixelGlow.right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", offset, offset - thickness)
        frame.pixelGlow.right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", offset, -offset + thickness)
        frame.pixelGlow.right:SetWidth(thickness)
    end
    
    -- Show all border pieces
    for _, tex in pairs(frame.pixelGlow) do
        tex:Show()
    end
    
    -- Hide old auraGlow if exists
    if frame.auraGlow then
        frame.auraGlow:Hide()
    end
end

function CooldownIcons:HideGlow(frame)
    -- Hide overlay glow
    if ActionButton_HideOverlayGlow then
        ActionButton_HideOverlayGlow(frame)
    end
    
    -- Stop LibCustomGlow pixel glow (via shared utility)
    self.Utils:HidePixelGlow(frame, "aura")
    
    -- Hide fallback pixel glow borders
    if frame.pixelGlow then
        for _, tex in pairs(frame.pixelGlow) do
            tex:Hide()
        end
    end
    
    -- Hide old auraGlow if exists
    if frame.auraGlow then
        frame.auraGlow:Hide()
    end
    
    -- Hide permanent buff glow
    if frame.permanentGlow then
        frame.permanentGlow:Hide()
    end
    
    -- Reset border color (only when Masque is active)
    if self.MasqueGroup and frame.NormalTexture then
        frame.NormalTexture:SetVertexColor(1, 1, 1)
    end
end

-------------------------------------------------------------------------------
-- Spell State Helpers
-------------------------------------------------------------------------------

function CooldownIcons:IsSpellUsable(spellID)
    -- Get effective spell ID (action bar rank, or highest known rank)
    -- This ensures we check usability for the same rank used for cost calculations
    local effectiveSpellID = self.Utils:GetEffectiveSpellID(spellID)
    
    if C_Spell and C_Spell.IsSpellUsable then
        local isUsable, notEnoughMana = C_Spell.IsSpellUsable(effectiveSpellID)
        return isUsable, notEnoughMana
    elseif IsUsableSpell then
        -- Try spell NAME first (like WeakAuras does), then fall back to ID
        local spellName = GetSpellInfo(effectiveSpellID)
        if spellName then
            local usable, noMana = IsUsableSpell(spellName)
            if usable ~= nil then
                return usable, noMana
            end
        end
        return IsUsableSpell(effectiveSpellID)
    end
    return true, false
end

function CooldownIcons:GetSpellCharges(spellID)
    if GetSpellCharges then
        local charges, maxCharges, start, duration = GetSpellCharges(spellID)
        return charges, maxCharges, start, duration
    end
    return nil, nil
end

-------------------------------------------------------------------------------
-- Range Indicator
-------------------------------------------------------------------------------

-- Update range indicator overlay on an icon
-- Shows a red tint when the target is out of range of the spell
-- Shows when ability is usable (has resources/conditions) even if on cooldown - gives positioning heads-up
-- Hides when: aura is active (tracking it), or ability is unusable (resource indicators take priority)
-- Visual hierarchy: grey = unusable, red = out of range, normal = ready
function CooldownIcons:UpdateRangeIndicator(frame, spellID, db)
    if not frame.rangeFrame then return end
    
    -- Check if range indicator is enabled for this row
    local rowIndex = frame.rowIndex or 1
    local showForRow = addon.Database:IsRowSettingEnabled(db.showRangeIndicator, rowIndex)
    
    if not showForRow then
        frame.rangeFrame.fadeIn:Stop()
        frame.rangeFrame.fadeOut:Stop()
        frame.rangeFrame:SetAlpha(0)
        frame.rangeFrame:Hide()
        frame.rangeWantShow = false
        return
    end
    
    -- Check if we have a target at all
    local hasTarget = UnitExists("target")
    
    -- Determine if we should show the range indicator
    local shouldShow = false
    
    if hasTarget then
        -- Skip if this spell has an active aura (buff/debuff already applied)
        local auraTracker = addon:GetModule("AuraTracker")
        local hasActiveAura = auraTracker and auraTracker:IsAuraActive(frame.spellID)
        
        -- Skip if player has an active buff from this spell (self-buffs, permanent buffs)
        -- Respect ignoreAura flag for spells where the buff is incidental (e.g., Bloodthirst healing)
        local actualSpellID = frame.actualSpellID or frame.spellID
        local spellData = frame.spellData
        local shouldCheckBuff = not (spellData and spellData.ignoreAura)
        local isBuffActive = shouldCheckBuff and self:GetPlayerBuff(actualSpellID)
        
        -- Skip if ability is not usable (resources, conditions, etc.)
        -- This ensures range doesn't compete with resource indicators
        -- Note: We DO show range during cooldown if otherwise usable (gives heads-up on positioning)
        local isUsable = self:IsSpellUsable(actualSpellID)
        
        if not hasActiveAura and not isBuffActive and isUsable then
            -- Check range - only show if explicitly out of range (false)
            local RangeChecker = addon.RangeChecker
            local inRange = RangeChecker and RangeChecker:IsSpellInRange(spellID, "target")
            shouldShow = (inRange == false)
        end
    end
    
    -- Track state transitions
    local wasShowing = frame.rangeWantShow or false
    frame.rangeWantShow = shouldShow
    
    if shouldShow and not wasShowing then
        -- Fade in - stop any existing animation first to ensure clean state
        frame.rangeFrame.fadeOut:Stop()
        frame.rangeFrame.fadeIn:Stop()
        frame.rangeFrame:Show()
        frame.rangeFrame:SetAlpha(0)
        frame.rangeFrame.fadeIn:Play()
    elseif not shouldShow and wasShowing then
        if hasTarget then
            -- Target exists but we're now in range: fade out smoothly
            frame.rangeFrame.fadeIn:Stop()
            frame.rangeFrame.fadeOut:Stop()
            frame.rangeFrame:SetAlpha(1)
            frame.rangeFrame.fadeOut:Play()
        else
            -- No target: instant hide (no animation) to avoid flicker
            frame.rangeFrame.fadeIn:Stop()
            frame.rangeFrame.fadeOut:Stop()
            frame.rangeFrame:SetAlpha(0)
            frame.rangeFrame:Hide()
        end
    end
end

-- Force update range for all visible icons (called on throttled timer via RangeChecker callback)
function CooldownIcons:UpdateAllRangeIndicators()
    local db = addon.db and addon.db.profile.icons or {}
    
    for _, rowFrame in ipairs(self.rows or {}) do
        if rowFrame.icons then
            for _, iconFrame in ipairs(rowFrame.icons) do
                if iconFrame:IsShown() and iconFrame.spellID then
                    local actualSpellID = iconFrame.actualSpellID or iconFrame.spellID
                    self:UpdateRangeIndicator(iconFrame, actualSpellID, db)
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

function CooldownIcons:Refresh()
    -- Update cached row settings from current config before rebuilding
    local rowConfigs = addon.db.profile.rows or {}
    local iconDb = addon.db.profile.icons or {}
    
    -- Track vertical offset for row repositioning
    local yOffset = 0
    
    for rowIndex, rowFrame in ipairs(self.rows or {}) do
        local rowConfig = rowConfigs[rowIndex] or {}
        local size = rowConfig.iconSize or iconDb.iconSize
        local iconWidth, iconHeight = self.Utils:GetIconDimensions(size)
        
        rowFrame.iconSize = size
        rowFrame.iconWidth = iconWidth
        rowFrame.iconHeight = iconHeight
        -- Use explicit nil check since 0 is a valid spacing value
        local newSpacing = rowConfig.iconSpacing
        if newSpacing == nil then
            newSpacing = iconDb.iconSpacing
        end
        rowFrame.iconSpacing = newSpacing
        rowFrame.iconsPerRow = rowConfig.iconsPerRow or rowConfig.maxIcons
        
        -- Update row frame size to match new icon dimensions
        local maxIcons = rowConfig.maxIcons
        rowFrame:SetSize(maxIcons * (iconWidth + newSpacing), iconHeight)
        
        -- Update icon sizes and config
        for _, icon in ipairs(rowFrame.icons or {}) do
            icon:SetSize(iconWidth, iconHeight)
            icon.iconSize = size
            icon.iconWidth = iconWidth
            icon.iconHeight = iconHeight
            
            if icon.cooldown then
                self:ConfigureCooldownText(icon.cooldown, icon.rowIndex)
                -- Clear cached cooldown values to force re-apply of spiral settings
                icon.lastCdStart = nil
                icon.lastCdDuration = nil
            end
            
            -- Update built-in style if Masque is not installed
            addon.IconStyling:Update(icon, size, self.MasqueGroup ~= nil)
        end
        
        -- Reposition row vertically based on current settings
        -- Add extra gap between primary and secondary rows
        if rowIndex == 2 then
            yOffset = yOffset - iconDb.primarySecondaryGap
        end
        
        -- Add section gap before utility rows (row 3+)
        if rowIndex >= 3 then
            yOffset = yOffset - iconDb.sectionGap
        end
        
        rowFrame:ClearAllPoints()
        rowFrame:SetPoint("TOP", self.container, "TOP", 0, yOffset)
        
        -- Calculate height for next row offset (use iconHeight, not size)
        local estimatedHeight = iconHeight
        if rowFrame.flowLayout and rowFrame.iconsPerRow then
            local estimatedRows = math.ceil(rowConfig.maxIcons / rowFrame.iconsPerRow)
            estimatedHeight = estimatedRows * (iconHeight + iconDb.rowSpacing)
        end
        yOffset = yOffset - (estimatedHeight + iconDb.rowSpacing)
    end
    
    self:RebuildAllRows()
    self:UpdateAllIcons()
    
    -- Reapply texcoords (ensures aspect ratio cropping is applied)
    self:ApplyIconTexCoords()
    
    -- Update cooldown bling setting on all icons (per-row)
    for rowIndex, rowFrame in ipairs(self.rows or {}) do
        local blingEnabled = addon.Database:IsRowSettingEnabled(iconDb.cooldownBlingRows, rowIndex)
        for _, iconFrame in ipairs(rowFrame.icons or {}) do
            if iconFrame.cooldown then
                iconFrame.cooldown:SetDrawBling(blingEnabled)
            end
        end
    end
    
    -- Final repositioning based on actual icon counts (overrides the estimated positions above)
    self:RepositionRows()
end

function CooldownIcons:RefreshFonts(fontPath)
    -- Update fonts on all icon text elements
    for _, rowFrame in ipairs(self.rows or {}) do
        for _, iconFrame in ipairs(rowFrame.icons or {}) do
            local size = iconFrame:GetWidth()
            
            -- Cooldown text
            if iconFrame.text then
                local fontSize = math.max(14, math.floor(size * 0.38))
                iconFrame.text:SetFont(fontPath, fontSize, "OUTLINE")
            end
            
            -- Charges text
            if iconFrame.charges then
                local chargesFontSize = math.max(9, math.floor(size * 0.24))
                iconFrame.charges:SetFont(fontPath, chargesFontSize, "OUTLINE")
            end
            
            -- Stacks text
            if iconFrame.stacks then
                local stacksFontSize = math.max(10, math.floor(size * 0.26))
                iconFrame.stacks:SetFont(fontPath, stacksFontSize, "OUTLINE")
            end
        end
    end
end
