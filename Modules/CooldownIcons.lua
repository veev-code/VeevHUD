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

local CooldownIcons = {}
addon:RegisterModule("CooldownIcons", CooldownIcons)

-- Row containers
CooldownIcons.rows = {}

-- Icon pool per row
CooldownIcons.iconsByRow = {}

-- Spell to row assignment cache
CooldownIcons.spellAssignments = {}

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

    -- Track active spell overlays (procs)
    self.activeOverlays = {}

    -- Initialize Masque support if available
    self:InitializeMasque()
    
    -- Initialize LibCustomGlow if available
    self.LibCustomGlow = LibStub and LibStub("LibCustomGlow-1.0", true)
    if self.LibCustomGlow then
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
-- If showCooldownText is enabled, we use our own text and hide external addons
-- If showCooldownText is disabled, we let external addons show their text
function CooldownIcons:ConfigureCooldownText(cooldown)
    local db = addon.db and addon.db.profile.icons or {}
    local showOwnText = db.showCooldownText ~= false  -- Default true
    
    if showOwnText then
        -- Hide external cooldown text, use our own
        if OmniCC and OmniCC.Cooldown and OmniCC.Cooldown.SetNoCooldownCount then
            -- OmniCC: always hide default numbers, tell OmniCC to hide its text
            cooldown:SetHideCountdownNumbers(true)
            OmniCC.Cooldown.SetNoCooldownCount(cooldown, true)
        elseif ElvUI and ElvUI[1] and ElvUI[1].CooldownEnabled 
               and ElvUI[1].ToggleCooldown and ElvUI[1]:CooldownEnabled() then
            -- ElvUI: hide countdown numbers and disable ElvUI cooldown
            cooldown:SetHideCountdownNumbers(true)
            ElvUI[1]:ToggleCooldown(cooldown, false)
        else
            -- Default: just hide the built-in countdown numbers
            cooldown:SetHideCountdownNumbers(true)
        end
    else
        -- Let external addons show their text (OmniCC, ElvUI, etc.)
        if OmniCC and OmniCC.Cooldown and OmniCC.Cooldown.SetNoCooldownCount then
            cooldown:SetHideCountdownNumbers(true)
            OmniCC.Cooldown.SetNoCooldownCount(cooldown, false)
        elseif ElvUI and ElvUI[1] and ElvUI[1].CooldownEnabled
               and ElvUI[1].ToggleCooldown and ElvUI[1]:CooldownEnabled() then
            cooldown:SetHideCountdownNumbers(true)
            ElvUI[1]:ToggleCooldown(cooldown, true)
        else
            -- No external addon, show default countdown numbers
            cooldown:SetHideCountdownNumbers(false)
        end
    end
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
function CooldownIcons:GetPlayerBuff(spellID)
    local spellName = GetSpellInfo(spellID)
    
    for i = 1, 40 do
        local name, icon, count, debuffType, duration, expirationTime, source, 
              isStealable, nameplateShowPersonal, buffSpellId = UnitBuff("player", i)
        
        if not name then break end
        
        if buffSpellId == spellID or name == spellName then
            local remaining = 0
            if expirationTime and expirationTime > 0 then
                remaining = expirationTime - GetTime()
                if remaining < 0 then remaining = 0 end
            end
            return true, remaining, duration or 0, count or 0
        end
    end
    
    return false, 0, 0, 0
end

-- Check for target lockout debuff (e.g., Weakened Soul for PWS)
-- Priority: friendly target -> friendly targettarget -> self
-- Returns: isActive, remaining, duration, expirationTime
function CooldownIcons:GetTargetLockoutDebuff(debuffSpellID)
    if not debuffSpellID then return false, 0, 0, 0 end
    
    local debuffName = GetSpellInfo(debuffSpellID)
    if not debuffName then return false, 0, 0, 0 end
    
    -- Determine which unit to check (priority order)
    local unit = "player"
    if UnitExists("target") and UnitIsFriend("player", "target") then
        -- Friendly target - check them
        unit = "target"
    elseif UnitExists("targettarget") and UnitIsFriend("player", "targettarget") then
        -- Enemy target but their target is friendly (e.g., tank) - check them
        unit = "targettarget"
    end
    -- else: fallback to self
    
    -- Scan debuffs on the unit
    for i = 1, 40 do
        local name, icon, count, debuffType, duration, expirationTime, source, 
              isStealable, nameplateShowPersonal, debuffSpellId = UnitDebuff(unit, i)
        
        if not name then break end
        
        if debuffSpellId == debuffSpellID or name == debuffName then
            local remaining = 0
            if expirationTime and expirationTime > 0 then
                remaining = expirationTime - GetTime()
                if remaining < 0 then remaining = 0 end
            end
            return true, remaining, duration or 0, expirationTime or 0
        end
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

-- Play cast feedback animation (scale punch using Animation API)
function CooldownIcons:PlayCastFeedback(frame)
    if not frame then return end
    
    local db = addon.db and addon.db.profile.icons or {}
    if db.castFeedback == false then return end  -- Allow disabling
    
    local scale = db.castFeedbackScale or 1.1
    
    -- Create or update animation group
    if not frame.punchAnim or frame.punchAnimScale ~= scale then
        -- Need to create new animation with updated scale
        if frame.punchAnim then
            frame.punchAnim:Stop()
        end
        
        local ag = frame:CreateAnimationGroup()
        
        -- Scale up from center
        local scaleUp = ag:CreateAnimation("Scale")
        scaleUp:SetOrigin("CENTER", 0, 0)
        scaleUp:SetScale(scale, scale)
        scaleUp:SetDuration(0.08)
        scaleUp:SetSmoothing("OUT")
        scaleUp:SetOrder(1)
        
        -- Scale back down to normal
        local scaleDown = ag:CreateAnimation("Scale")
        scaleDown:SetOrigin("CENTER", 0, 0)
        scaleDown:SetScale(1/scale, 1/scale)
        scaleDown:SetDuration(0.12)
        scaleDown:SetSmoothing("IN")
        scaleDown:SetOrder(2)
        
        frame.punchAnim = ag
        frame.punchAnimScale = scale
    end
    
    frame.punchAnim:Stop()
    frame.punchAnim:Play()
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
    local resourceBarBottom = (resourceBarDb.offsetY or 0) - (resourceBarDb.height or 14) / 2
    
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

    -- Start update ticker
    self.Events:RegisterUpdate(self, 0.05, self.UpdateAllIcons)
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
                local psGap = iconDb.primarySecondaryGap or 0
                yOffset = yOffset - psGap
            end
            
            -- Add extra space before utility section (row 3+)
            if rowIndex >= 3 then
                local sectionGap = iconDb.sectionGap or 16
                yOffset = yOffset - sectionGap
            end

            -- Use per-row settings or fall back to global
            local rowIconSize = rowConfig.iconSize or iconDb.iconSize or 40
            -- Use explicit nil check since 0 is a valid spacing value
            local rowIconSpacing = rowConfig.iconSpacing
            if rowIconSpacing == nil then
                rowIconSpacing = iconDb.iconSpacing
            end
            if rowIconSpacing == nil then
                rowIconSpacing = 1
            end

            self.Utils:LogInfo("Row", rowIndex, rowConfig.name, "iconSize:", rowIconSize, "maxIcons:", rowConfig.maxIcons)

            local rowFrame = CreateFrame("Frame", nil, self.container)
            rowFrame:SetSize(rowConfig.maxIcons * (rowIconSize + rowIconSpacing), rowIconSize)
            rowFrame:SetPoint("TOP", self.container, "TOP", 0, yOffset)
            rowFrame:EnableMouse(false)  -- Click-through
            rowFrame.iconSize = rowIconSize
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
            local estimatedHeight = rowIconSize
            if rowConfig.flowLayout and rowConfig.iconsPerRow then
                local estimatedRows = math.ceil(rowConfig.maxIcons / rowConfig.iconsPerRow)
                local verticalSpacing = iconDb.rowSpacing or 1
                estimatedHeight = estimatedRows * (rowIconSize + verticalSpacing)
            end
            yOffset = yOffset - (estimatedHeight + (iconDb.rowSpacing or 1))
        end
    end
end

function CooldownIcons:CreateIcon(parent, index, size)
    local db = addon.db.profile.icons
    size = size or db.iconSize or 56

    -- Create as Button for Masque compatibility
    local buttonName = "VeevHUDIcon" .. (self.iconCounter or 0)
    self.iconCounter = (self.iconCounter or 0) + 1

    local frame = CreateFrame("Button", buttonName, parent)
    frame:SetSize(size, size)
    frame:EnableMouse(false)  -- Click-through (display only, no interaction)
    frame.iconSize = size

    -- Icon texture - fills the frame, spacing between icons creates separation
    local icon = frame:CreateTexture(buttonName .. "Icon", "ARTWORK")
    icon:SetAllPoints()
    -- Zoom in 30% (15% cut from each edge)
    local zoom = 0.15
    icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
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
    cooldown:SetDrawBling(false)
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
    text:SetFont(self.C.FONTS.NUMBER, fontSize, "OUTLINE")  -- Lighter outline
    text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    text:SetTextColor(1.0, 0.906, 0.745)  -- #ffe7be
    text:SetShadowOffset(0.5, -0.5)  -- Subtle shadow
    text:SetShadowColor(0, 0, 0, 0.5)
    frame.text = text
    frame.textFrame = textFrame

    -- Charges text (bottom right)
    local chargesFontSize = math.max(9, math.floor(size * 0.24))
    local charges = frame:CreateFontString(nil, "OVERLAY")
    charges:SetFont(self.C.FONTS.NUMBER, chargesFontSize, "OUTLINE")
    charges:SetPoint("BOTTOMRIGHT", -2, 2)
    charges:SetTextColor(1, 1, 1)
    frame.charges = charges
    frame.Count = charges  -- Masque reference

    -- Stacks text (bottom right, for aura stacks like Rampage, Lifebloom, Sunder)
    local stacksFontSize = math.max(10, math.floor(size * 0.26))
    local stacks = frame:CreateFontString(nil, "OVERLAY")
    stacks:SetFont(self.C.FONTS.NUMBER, stacksFontSize, "OUTLINE")
    stacks:SetPoint("BOTTOMRIGHT", -4, 4)
    stacks:SetTextColor(1.0, 0.906, 0.745)  -- #ffe7be to match aura state
    frame.stacks = stacks

    -- Resource cost display elements
    -- Option A: Horizontal bar at bottom
    local resourceBar = CreateFrame("Frame", nil, frame)
    resourceBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    resourceBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    resourceBar:SetHeight(db.resourceBarHeight or 4)
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
    resourceFill:SetVertexColor(0, 0, 0, db.resourceFillAlpha or 0.6)
    resourceFill:SetHeight(0)
    resourceFill:Hide()
    frame.resourceFill = resourceFill

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
        self:ApplyBuiltInStyle(frame, size)
    end

    return frame
end

-------------------------------------------------------------------------------
-- Built-in Icon Styling (when Masque is not installed)
-- Uses the exact same textures as Masque's "Classic Enhanced" skin
-------------------------------------------------------------------------------

-- Classic Enhanced skin texture paths (built into WoW client)
-- Tweaked for a more subtle appearance while maintaining proper proportions
local CLASSIC_ENHANCED = {
    Normal = [[Interface\Buttons\UI-Quickslot2]],      -- The action button border frame
    Backdrop = [[Interface\Buttons\UI-Quickslot]],     -- Empty slot background
    IconTexCoords = {0.07, 0.93, 0.07, 0.93},          -- Icon crop (7% from each edge)
    NormalSize = 62,                                    -- Border texture size (must be larger than icon to frame it)
    BackdropSize = 64,                                  -- Backdrop texture size
    NormalOffset = {0.5, -0.5},                         -- Border offset {x, y}
    BackdropAlpha = 0.4,                                -- Subtle backdrop visibility
    NormalAlpha = 0.8,                                  -- Slightly softer border
}

function CooldownIcons:ApplyBuiltInStyle(frame, size)
    size = size or frame.iconSize or 40
    
    -- Calculate scale factor (Classic Enhanced is designed for 36px base icon, our default is 40)
    local scale = size / 36
    
    -- Apply icon TexCoords to match Classic Enhanced (7% crop from each edge)
    if frame.icon then
        frame.icon:SetTexCoord(unpack(CLASSIC_ENHANCED.IconTexCoords))
    end
    
    -- Create backdrop (empty slot background) - sits behind everything
    if not frame.builtInBackdrop then
        local backdrop = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
        backdrop:SetTexture(CLASSIC_ENHANCED.Backdrop)
        frame.builtInBackdrop = backdrop
    end
    
    -- Apply subtle backdrop styling
    frame.builtInBackdrop:SetVertexColor(1, 1, 1, CLASSIC_ENHANCED.BackdropAlpha)
    
    -- Size and position backdrop (centered, slightly larger than icon)
    local backdropSize = CLASSIC_ENHANCED.BackdropSize * scale
    frame.builtInBackdrop:SetSize(backdropSize, backdropSize)
    frame.builtInBackdrop:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.builtInBackdrop:Show()
    
    -- Create normal border (the classic action button frame)
    if not frame.builtInNormal then
        local normal = frame:CreateTexture(nil, "OVERLAY", nil, 1)
        normal:SetTexture(CLASSIC_ENHANCED.Normal)
        frame.builtInNormal = normal
    end
    
    -- Apply subtle border styling
    frame.builtInNormal:SetVertexColor(1, 1, 1, CLASSIC_ENHANCED.NormalAlpha)
    
    -- Size and position border (centered with slight offset like Masque does)
    local normalSize = CLASSIC_ENHANCED.NormalSize * scale
    local offsetX, offsetY = CLASSIC_ENHANCED.NormalOffset[1], CLASSIC_ENHANCED.NormalOffset[2]
    frame.builtInNormal:SetSize(normalSize, normalSize)
    frame.builtInNormal:SetPoint("CENTER", frame, "CENTER", offsetX, offsetY)
    frame.builtInNormal:Show()
    
    -- Store that we applied built-in style
    frame.hasBuiltInStyle = true
end

-- Update built-in style when icon size changes
function CooldownIcons:UpdateBuiltInStyle(frame, size)
    if frame.hasBuiltInStyle then
        -- Recalculate sizes based on new icon size
        size = size or frame.iconSize or 40
        local scale = size / 36
        
        if frame.builtInBackdrop then
            local backdropSize = CLASSIC_ENHANCED.BackdropSize * scale
            frame.builtInBackdrop:SetSize(backdropSize, backdropSize)
        end
        
        if frame.builtInNormal then
            local normalSize = CLASSIC_ENHANCED.NormalSize * scale
            frame.builtInNormal:SetSize(normalSize, normalSize)
        end
    elseif not self.MasqueGroup then
        self:ApplyBuiltInStyle(frame, size)
    end
end

-------------------------------------------------------------------------------
-- Spell Assignment to Rows
-------------------------------------------------------------------------------

function CooldownIcons:OnTrackedSpellsChanged()
    self:RebuildAllRows()
    self:UpdateAllIcons()
end

-- Get current spec key for spellConfig lookup
function CooldownIcons:GetSpecKey()
    return addon:GetSpecKey()
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
                        spellID = spellID,
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
                                    spellID = spellID,
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

    self.Utils:LogInfo("CooldownIcons: Rebuilt rows")
    for rowIndex, spells in pairs(self.iconsByRow) do
        if #spells > 0 then
            local rowConfig = rowConfigs[rowIndex]
            self.Utils:LogDebug("  Row", rowIndex, "(" .. (rowConfig and rowConfig.name or "?") .. "):", #spells, "spells")
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
                if i <= iconCount then
                    local spellInfo = spells[i]
                    self:SetupIcon(iconFrame, spellInfo.spellID, spellInfo.spellData, rowConfig, rowIndex)
                    iconFrame:Show()
                else
                    iconFrame:Hide()
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
    local size = rowFrame.iconSize or db.iconSize or 40
    -- Use explicit nil check since 0 is a valid spacing value
    local spacing = rowFrame.iconSpacing
    if spacing == nil then
        spacing = db.iconSpacing
    end
    if spacing == nil then
        spacing = 1
    end
    local iconsPerRow = rowFrame.iconsPerRow or count  -- Default to all on one row
    local flowLayout = rowFrame.flowLayout or false
    local rowSpacing = db.rowSpacing or 1  -- Vertical spacing between wrapped rows

    if flowLayout and count > iconsPerRow then
        -- Multi-row flow layout
        self:PositionFlowLayout(rowFrame, count, size, spacing, iconsPerRow, rowSpacing)
    else
        -- Single row layout (centered)
        local totalWidth = count * size + (count - 1) * spacing
        local startX = -totalWidth / 2 + size / 2

        for i = 1, count do
            local frame = rowFrame.icons[i]
            if frame and frame:IsShown() then
                local x = startX + (i - 1) * (size + spacing)
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", rowFrame, "CENTER", x, 0)
            end
        end
    end
end

function CooldownIcons:PositionFlowLayout(rowFrame, count, size, spacing, iconsPerRow, rowSpacing)
    -- Calculate how many rows we need
    local numRows = math.ceil(count / iconsPerRow)
    
    -- Check if last row would have only 1 icon - if so, redistribute
    local lastRowCount = count % iconsPerRow
    if lastRowCount == 1 and numRows > 1 then
        -- Adjust icons per row to balance better
        iconsPerRow = math.ceil(count / numRows)
    end
    
    -- Use rowSpacing for vertical gap between wrapped rows (defaults to 1 if not provided)
    local verticalSpacing = rowSpacing or 1
    local rowHeight = size + verticalSpacing
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
        local rowWidth = iconsThisRow * size + (iconsThisRow - 1) * spacing
        local startX = -rowWidth / 2 + size / 2
        local yOffset = -(row - 1) * rowHeight
        
        for col = 1, iconsThisRow do
            local frame = rowFrame.icons[iconIndex]
            if frame and frame:IsShown() then
                local x = startX + (col - 1) * (size + spacing)
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

function CooldownIcons:SetupIcon(frame, spellID, spellData, rowConfig, rowIndex)
    local texture = spellData.icon or self.Utils:GetSpellTexture(spellID)
    frame.icon:SetTexture(texture)
    frame.spellID = spellID
    frame.spellData = spellData
    frame.rowIndex = rowIndex or 1
    -- dimOnCooldown is now determined dynamically in UpdateIcon based on global setting
    
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
end

function CooldownIcons:UpdateIconState(frame, db)
    local spellID = frame.spellID
    if not spellID then return end

    -- Check for active aura (debuff/buff applied by this spell)
    -- Only if aura tracking is enabled in settings
    local auraActive = false
    local auraRemaining, auraDuration, auraStacks = 0, 0, 0
    local auraTargetCount = 0
    
    if db.showAuraTracking ~= false then
        local auraTracker = addon:GetModule("AuraTracker")
        auraActive = auraTracker and auraTracker:IsAuraActive(spellID)
        if auraTracker then
            auraRemaining, auraDuration, auraStacks = auraTracker:GetAuraRemaining(spellID)
        end
        auraTargetCount = auraTracker and auraTracker:GetAuraTargetCount(spellID) or 0
        
        -- For shared CD abilities (Reck/Retal/SWall), also check player buffs directly
        -- since AuraTracker may not track non-displayed spells
        -- Skip if spell has ignoreAura set (e.g., Bloodthirst buff is longer than CD)
        local spellData = frame.spellData
        local shouldCheckBuff = not (spellData and spellData.ignoreAura)
        
        if not auraActive and shouldCheckBuff then
            local isBuffActive, buffRemaining, buffDuration, buffStacks = self:GetPlayerBuff(spellID)
            if isBuffActive then
                auraActive = true
                auraRemaining = buffRemaining
                auraDuration = buffDuration
                auraStacks = buffStacks or 0
            end
        end
    end

    -- Get cooldown info (including actual start time for accurate spiral)
    local remaining, duration, cdEnabled, cdStartTime = self.Utils:GetSpellCooldown(spellID)
    
    -- Check for target lockout debuff (e.g., Weakened Soul for PWS)
    -- This acts as a per-target cooldown, overriding actual spell cooldown
    local spellData = frame.spellData
    local targetLockoutActive = false
    local targetLockoutRemaining, targetLockoutDuration, targetLockoutExpiration = 0, 0, 0
    
    if spellData and spellData.targetLockoutDebuff then
        targetLockoutActive, targetLockoutRemaining, targetLockoutDuration, targetLockoutExpiration = 
            self:GetTargetLockoutDebuff(spellData.targetLockoutDebuff)
        
        if targetLockoutActive and targetLockoutRemaining > 0 then
            -- Use lockout debuff as the effective cooldown
            remaining = targetLockoutRemaining
            duration = targetLockoutDuration
            -- Calculate start time from expiration for accurate spiral
            cdStartTime = targetLockoutExpiration - targetLockoutDuration
        end
    end
    
    -- Determine if this is GCD vs actual cooldown
    local GCD_THRESHOLD = 1.5
    local isOnGCD = remaining > 0 and duration <= GCD_THRESHOLD  -- Only GCD if duration is short
    local isOnActualCooldown = remaining > 0 and duration > GCD_THRESHOLD  -- Real CD if duration exceeds GCD
    local almostReady = remaining > 0 and remaining <= 1.0 and duration > GCD_THRESHOLD

    -- Determine if this row dims icons on cooldown based on global setting
    -- When false: full alpha + desaturation (keeps core rotation visually prominent)
    -- When true: reduced alpha on cooldown (traditional behavior)
    local rowIndex = frame.rowIndex or 1
    local dimSetting = db.dimOnCooldown or "secondary_utility"
    local dimOnCooldown = false
    if dimSetting == "all" then
        dimOnCooldown = true
    elseif dimSetting == "secondary_utility" then
        dimOnCooldown = (rowIndex >= 2)  -- Secondary (2) and Utility (3+)
    elseif dimSetting == "utility" then
        dimOnCooldown = (rowIndex >= 3)  -- Utility only (3+)
    end
    -- "none" leaves dimOnCooldown = false
    
    -- Determine if GCD should be shown for this row based on settings
    local showGCDOn = db.showGCDOn or "primary"
    local showGCDForThisRow = false
    if showGCDOn == "primary" then
        showGCDForThisRow = (rowIndex == 1)
    elseif showGCDOn == "primary_secondary" then
        showGCDForThisRow = (rowIndex == 1 or rowIndex == 2)
    elseif showGCDOn == "all" then
        showGCDForThisRow = true
    end

    -- Get usability info (uses spell NAME which correctly handles Execute, Revenge, etc.)
    local isUsable, notEnoughMana = self:IsSpellUsable(spellID)
    
    -- Check for spell activation overlay (for proc glow display)
    local hasOverlay = self:HasSpellActivationOverlay(spellID)
    
    -- Get power/resource info for resource display
    local powerCost, currentPower, maxPower, powerType, powerColor = self.Utils:GetSpellPowerInfo(spellID)
    local hasResourceCost = powerCost and powerCost > 0
    local resourcePercent = hasResourceCost and math.min(1, currentPower / powerCost) or 1

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

    -----------------------------------------------------------------------
    -- AURA ACTIVE STATE (overrides normal cooldown display)
    -- When a debuff/buff from this spell is active on a target
    -----------------------------------------------------------------------
    if auraActive and auraRemaining > 0 then
        -----------------------------------------------------------------------
        -- AURA ACTIVE STATE
        -- Debuff/buff from this spell is active on a target
        -----------------------------------------------------------------------
        showAuraActive = true
        auraDisplayRemaining = auraRemaining
        auraDisplayDuration = auraDuration
        alpha = db.readyAlpha  -- Full alpha
        showGlow = true  -- Show animated glow while active
        showSpinner = true  -- Show spiral for aura duration
        showText = true  -- Show aura duration
        desaturate = false
        
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
        if self:HasSpellActivationOverlay(spellID) then
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
        local isRealCooldown = duration > GCD_THRESHOLD
        
        if remaining > 0 and isRealCooldown then
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

    -- Show/hide cooldown spiral
    local showSpiral = db.showCooldownSpiral ~= false
    if showSpinner and showSpiral then
        frame.cooldown:SetAlpha(1)
        frame.cooldown:SetSwipeColor(0, 0, 0, 0.8)
        
        if showAuraActive and auraDisplayDuration > 0 then
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
            frame.cooldown:Show()
        else
            frame.cooldown:Hide()
            frame.lastCdStart = nil
            frame.lastCdDuration = nil
        end
    else
        frame.cooldown:Hide()
        frame.lastCdStart = nil
        frame.lastCdDuration = nil
    end

    -- Show/hide cooldown text (or aura duration text)
    if showAuraActive and auraDisplayRemaining > 0 then
        -- Show aura remaining time in #ffe7be color
        -- Always show our own text for aura duration (OmniCC doesn't track this)
        frame.text:SetText(self.Utils:FormatCooldown(auraDisplayRemaining))
        frame.text:SetTextColor(1.0, 0.906, 0.745)  -- #ffe7be
    elseif showText and db.showCooldownText and remaining > 0 then
        -- For cooldowns, respect useOwnCooldownText setting
        local useOwnText = db.useOwnCooldownText ~= false  -- Default true
        if useOwnText then
            frame.text:SetText(self.Utils:FormatCooldown(remaining))
            -- Always use the same color for cooldown text
            frame.text:SetTextColor(1.0, 0.906, 0.745)  -- #ffe7be
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
    frame:SetAlpha(alpha)
    
    -- Apply desaturation to icon
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
    self:UpdateResourceDisplay(frame, spellID, remaining, hasResourceCost, resourcePercent, powerColor, db)

    -- Handle glow effect (aura active / normal almost-ready glow)
    self:UpdateIconGlow(frame, showGlow, showAuraActive)
    
    -- Handle ready glow (proc-style glow when ability becomes usable)
    -- Uses isUsable which checks ALL conditions (resources, target health for Execute, etc.)
    -- Skip if aura is active (that has its own glow)
    if not showAuraActive then
        local isReactive = frame.isReactive or false
        self:UpdateReadyGlow(frame, spellID, remaining, duration, isUsable, isReactive, db)
    elseif frame.readyGlowActive then
        -- Hide ready glow if aura became active
        self:HideReadyGlow(frame)
        frame.readyGlowActive = false
    end
end

-- Update resource cost display (horizontal bar or vertical fill)
function CooldownIcons:UpdateResourceDisplay(frame, spellID, cooldownRemaining, hasResourceCost, resourcePercent, powerColor, db)
    local displayMode = db.resourceDisplayMode or "bar"
    
    -- Only show resource indicator if:
    -- 1. Not resting and out of combat (show in PvP/world even if combat drops)
    -- 2. The spell has a resource cost
    -- 3. We don't have enough resources (resourcePercent < 1)
    -- 4. The ability is off cooldown (cooldown takes visual priority)
    local inCombat = UnitAffectingCombat("player")
    local isResting = IsResting()
    local showUsability = inCombat or not isResting
    local showResource = showUsability and hasResourceCost and resourcePercent < 1 and cooldownRemaining <= 0
    
    if not showResource or displayMode == "none" then
        -- Hide and reset
        if frame.resourceBar then frame.resourceBar:Hide() end
        if frame.resourceFill then frame.resourceFill:Hide() end
        frame.resourceTarget = nil
        return
    end
    
    local iconSize = frame.iconSize or 48
    
    -- Initialize smooth animation state
    if not frame.resourceCurrent then
        frame.resourceCurrent = resourcePercent
    end
    frame.resourceTarget = resourcePercent
    frame.resourcePowerColor = powerColor
    frame.resourceIconSize = iconSize
    frame.resourceDisplayMode = displayMode  -- Store mode on frame for animation
    
    -- Set up OnUpdate for smooth animation if not already
    if not frame.resourceOnUpdate then
        frame.resourceOnUpdate = true
        frame:HookScript("OnUpdate", function(f, elapsed)
            -- Get fresh db reference each frame
            local freshDb = addon.db and addon.db.profile.icons or {}
            self:AnimateResourceDisplay(f, elapsed, freshDb)
        end)
    end
    
    if displayMode == "bar" and frame.resourceBar then
        frame.resourceBar:SetHeight(db.resourceBarHeight or 4)
        frame.resourceBar:Show()
        if frame.resourceFill then frame.resourceFill:Hide() end
    elseif displayMode == "fill" and frame.resourceFill then
        -- Frame alpha already handles visibility, just set the resource fill's own alpha
        frame.resourceFill:SetVertexColor(0, 0, 0, db.resourceFillAlpha or 0.6)
        frame.resourceFill:Show()
        if frame.resourceBar then frame.resourceBar:Hide() end
    end
end

-- Animate resource display smoothly (or instantly if smoothing disabled)
function CooldownIcons:AnimateResourceDisplay(frame, elapsed, db)
    if not frame.resourceTarget then return end
    
    local displayMode = frame.resourceDisplayMode or db.resourceDisplayMode or "bar"
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
    
    local iconSize = frame.resourceIconSize or 48
    
    if displayMode == "bar" and frame.resourceBar and frame.resourceBar:IsShown() then
        -- Horizontal bar fill
        local fillWidth = iconSize * current
        frame.resourceBar.fill:SetWidth(math.max(1, fillWidth))
        
        if frame.resourcePowerColor then
            local c = frame.resourcePowerColor
            frame.resourceBar.fill:SetVertexColor(c[1], c[2], c[3], 1)
        end
        
    elseif displayMode == "fill" and frame.resourceFill and frame.resourceFill:IsShown() then
        -- Vertical fill (dark overlay showing missing portion)
        -- Frame alpha handles visibility; vertex color just controls fill darkness
        local missingPercent = 1 - current
        local fillHeight = iconSize * missingPercent
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
function CooldownIcons:UpdateIconGlow(frame, showGlow, isAuraActive)
    if showGlow then
        local glowType = isAuraActive and "aura" or "normal"
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
        
        if isAuraActive then
            -- Aura active: Use pixel glow (purple/pink border)
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

-- Update the "ready glow" - shows when ability becomes ready
-- Triggers:
--   1. <1s remaining on CD AND usable -> show for remaining duration
--   2. Was not usable, just became usable (while off CD) -> show for configured duration
-- For Execute: "usable" means target < 20% AND enough rage
-- readyGlowMode controls behavior:
--   - "once": only glow once per cooldown cycle (default)
--   - "always": glow every time ability becomes ready
--   - "disabled": no glow
-- Reactive abilities (Execute, Overpower) always behave as "always" regardless of mode
function CooldownIcons:UpdateReadyGlow(frame, spellID, remaining, duration, isUsable, isReactive, db)
    local glowMode = db.readyGlowMode or "once"
    
    -- Disabled mode: hide any active glow and return (unless reactive)
    if glowMode == "disabled" and not isReactive then
        if frame.readyGlowActive then
            self:HideReadyGlow(frame)
            frame.readyGlowActive = false
        end
        return
    end
    
    -- Determine effective mode: reactive abilities always use "always" behavior
    local effectiveMode = isReactive and "always" or glowMode
    
    local GCD_THRESHOLD = 1.5
    local isOnRealCooldown = remaining > 0 and duration > GCD_THRESHOLD
    local isAlmostReady = remaining > 0 and remaining <= 1.0 and duration > GCD_THRESHOLD
    local isOffCooldown = remaining <= 0 or duration <= GCD_THRESHOLD  -- Off CD or only GCD
    
    -- Track previous states
    local wasOnRealCooldown = frame.wasOnRealCooldown or false
    local wasUsable = frame.wasUsable or false
    
    -- Detect when ability goes on cooldown (used) -> reset tracking for ALL abilities
    if isOnRealCooldown and not wasOnRealCooldown then
        frame.readyGlowShown = false
        frame.readyGlowExpires = nil
    end
    
    -- Reset glow tracking based on effective mode
    if effectiveMode == "always" then
        -- Reset glow when usability changes (allows re-triggering)
        if isUsable and not wasUsable then
            frame.readyGlowShown = false
        end
    end
    -- "once" mode: readyGlowShown stays true until ability is used (goes on CD)
    
    -- Check if ready glow should be triggered
    local showReadyGlow = false
    
    if not frame.readyGlowShown then
        local glowDuration = db.readyGlowDuration or 1.0
        
        -- Only initiate new glows when in combat
        local inCombat = UnitAffectingCombat("player")
        
        -- Condition 1: <1s remaining on CD AND usable
        if isAlmostReady and isUsable and inCombat then
            showReadyGlow = true
            frame.readyGlowShown = true
            frame.readyGlowExpires = GetTime() + glowDuration
            
        -- Condition 2: Just became usable while off CD
        elseif isOffCooldown and isUsable and not wasUsable and inCombat then
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
    -- Use LibCustomGlow ButtonGlow for the proc effect
    if self.LibCustomGlow then
        -- ButtonGlow_Start(frame, color, frequency, frameLevel)
        self.LibCustomGlow.ButtonGlow_Start(frame, nil, nil, nil)
        return
    end
    
    -- Fallback: Use ActionButton_ShowOverlayGlow if available
    if ActionButton_ShowOverlayGlow then
        ActionButton_ShowOverlayGlow(frame)
    end
end

function CooldownIcons:HideReadyGlow(frame)
    -- Use LibCustomGlow ButtonGlow stop
    if self.LibCustomGlow then
        self.LibCustomGlow.ButtonGlow_Stop(frame)
        return
    end
    
    -- Fallback
    if ActionButton_HideOverlayGlow then
        ActionButton_HideOverlayGlow(frame)
    end
end

function CooldownIcons:ShowAuraGlow(frame)
    -- Get icon's current alpha so glow respects Ready/Cooldown Alpha settings
    local iconAlpha = frame.iconAlpha or 1
    
    -- Use LibCustomGlow for animated pixel glow if available
    if self.LibCustomGlow then
        -- PixelGlow_Start(frame, color, N, frequency, length, thickness, xOffset, yOffset, border, key, frameLevel)
        -- Color #ffcfaf (peachy gold), offset inward by -2
        local color = {1.0, 0.812, 0.686, iconAlpha}  -- #ffcfaf with icon alpha
        self.LibCustomGlow.PixelGlow_Start(frame, color, 8, 0.1, 10, 1, -2, -2, true, "aura")
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
    
    -- Stop LibCustomGlow pixel glow
    if self.LibCustomGlow then
        self.LibCustomGlow.PixelGlow_Stop(frame, "aura")
    end
    
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
    
    -- Reset border color (only when Masque is active)
    if self.MasqueGroup and frame.NormalTexture then
        frame.NormalTexture:SetVertexColor(1, 1, 1)
    end
end

-------------------------------------------------------------------------------
-- Spell State Helpers
-------------------------------------------------------------------------------

function CooldownIcons:IsSpellUsable(spellID)
    if C_Spell and C_Spell.IsSpellUsable then
        local isUsable, notEnoughMana = C_Spell.IsSpellUsable(spellID)
        return isUsable, notEnoughMana
    elseif IsUsableSpell then
        -- Try spell NAME first (like WeakAuras does), then fall back to ID
        local spellName = GetSpellInfo(spellID)
        if spellName then
            local usable, noMana = IsUsableSpell(spellName)
            if usable ~= nil then
                return usable, noMana
            end
        end
        return IsUsableSpell(spellID)
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
-- Enable/Disable
-------------------------------------------------------------------------------

function CooldownIcons:Enable()
    if self.container then
        self.container:Show()
    end
end

function CooldownIcons:Disable()
    if self.container then
        self.container:Hide()
    end
end

function CooldownIcons:Refresh()
    -- Update cached row settings from current config before rebuilding
    local rowConfigs = addon.db.profile.rows or {}
    local iconDb = addon.db.profile.icons or {}
    
    -- Track vertical offset for row repositioning
    local yOffset = 0
    
    for rowIndex, rowFrame in ipairs(self.rows or {}) do
        local rowConfig = rowConfigs[rowIndex] or {}
        rowFrame.iconSize = rowConfig.iconSize or iconDb.iconSize or 40
        -- Use explicit nil check since 0 is a valid spacing value
        local newSpacing = rowConfig.iconSpacing
        if newSpacing == nil then
            newSpacing = iconDb.iconSpacing
        end
        if newSpacing == nil then
            newSpacing = 1
        end
        rowFrame.iconSpacing = newSpacing
        rowFrame.iconsPerRow = rowConfig.iconsPerRow or rowConfig.maxIcons or 6
        
        -- Update icon sizes and cooldown text config if needed
        local size = rowFrame.iconSize
        for _, icon in ipairs(rowFrame.icons or {}) do
            icon:SetSize(size, size)
            icon.iconSize = size
            -- Reconfigure external cooldown text (OmniCC, etc.) when settings change
            if icon.cooldown then
                self:ConfigureCooldownText(icon.cooldown)
                -- Clear cached cooldown values to force re-apply of spiral settings
                icon.lastCdStart = nil
                icon.lastCdDuration = nil
            end
            -- Update built-in style if Masque is not installed
            self:UpdateBuiltInStyle(icon, size)
        end
        
        -- Reposition row vertically based on current settings
        -- Add extra gap between primary and secondary rows
        if rowIndex == 2 then
            local psGap = iconDb.primarySecondaryGap or 0
            yOffset = yOffset - psGap
        end
        
        -- Add section gap before utility rows (row 3+)
        if rowIndex >= 3 then
            local sectionGap = iconDb.sectionGap or 16
            yOffset = yOffset - sectionGap
        end
        
        rowFrame:ClearAllPoints()
        rowFrame:SetPoint("TOP", self.container, "TOP", 0, yOffset)
        
        -- Calculate height for next row offset
        local estimatedHeight = size
        if rowFrame.flowLayout and rowFrame.iconsPerRow then
            local maxIcons = rowConfig.maxIcons or 6
            local estimatedRows = math.ceil(maxIcons / rowFrame.iconsPerRow)
            local verticalSpacing = iconDb.rowSpacing or 1
            estimatedHeight = estimatedRows * (size + verticalSpacing)
        end
        yOffset = yOffset - (estimatedHeight + (iconDb.rowSpacing or 1))
    end
    
    self:RebuildAllRows()
    self:UpdateAllIcons()
end
