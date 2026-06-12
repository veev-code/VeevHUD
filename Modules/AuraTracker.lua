--[[
    VeevHUD - Aura Tracker Module
    Displays important auras: class procs, external buffs, and custom user-tracked auras

    Design:
    - Icons shown above health bar
    - Active auras: Full color + glow + duration text
    - Inactive auras: Desaturated + dimmed (optional)

    Data sources:
    1. Class procs from LibSpellDB (Data/Procs.lua)
    2. External buffs from LibSpellDB (AURA_WATCH tag)
    3. Custom user-added auras (profile)
]]

local _, addon = ...
local C = addon.Constants

local AuraTracker = {}
addon:RegisterModule("AuraTracker", AuraTracker)

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function AuraTracker:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants
    self.Animations = addon.Animations
    self.iconFactory = addon:GetModule("IconFrameFactory")

    -- Icon frames
    self.icons = {}
    self.iconCounter = 0
    -- Pool of discarded icon frames for reuse (frames can't be GC'd, and
    -- their Masque registrations persist — see RebuildFrames)
    self._iconPool = {}

    -- Load LibSpellDB for proc data
    self.LibSpellDB = LibStub and LibStub("LibSpellDB-1.0", true)

    -- Initialize Masque support if available
    local MSQ = LibStub and LibStub("Masque", true)
    if MSQ then
        self.MasqueGroup = MSQ:Group("VeevHUD", "Aura Tracker")
    end

    -- Register with layout system
    addon.Layout:RegisterElement("auraTracker", self)

    -- Register events
    self.Events:RegisterEvent(self, "UNIT_AURA", self.OnAuraUpdate)
    self.Events:RegisterEvent(self, "PLAYER_TARGET_CHANGED", self.OnTargetChanged)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)
    self.Events:RegisterEvent(self, "PLAYER_EQUIPMENT_CHANGED", self.OnEquipmentChanged)

    self.Utils:Debug("AuraTracker initialized")
end

-------------------------------------------------------------------------------
-- Aura Loading (three data sources)
-------------------------------------------------------------------------------

-- Load all auras: class procs + external buffs + custom user auras
function AuraTracker:LoadAllAuras()
    local allAuras = {}

    -- 1. Class procs from LibSpellDB
    for _, aura in ipairs(self:GetProcsForClass(addon.playerClass)) do
        table.insert(allAuras, aura)
    end

    -- 2. External buffs from LibSpellDB (IMPORTANT_EXTERNAL tag)
    for _, aura in ipairs(self:GetExternalAuras()) do
        table.insert(allAuras, aura)
    end

    -- 3. Custom user-added auras from profile
    for _, aura in ipairs(self:GetCustomAuras()) do
        table.insert(allAuras, aura)
    end

    return allAuras
end

-- Load procs from LibSpellDB for the given class
function AuraTracker:GetProcsForClass(class)
    local procs = {}

    if self.LibSpellDB then
        local libProcs = self.LibSpellDB:GetProcs(class)
        for _, spellData in ipairs(libProcs) do
            -- Skip equipment-gated procs if none of the required items are equipped
            local include = true
            local requiredItems = spellData.requiredItemIDs
            if requiredItems then
                include = false
                for _, itemID in ipairs(requiredItems) do
                    if IsEquippedItem(itemID) then
                        include = true
                        break
                    end
                end
            end

            -- Skip reactive-window procs (castable abilities like Victory Rush) if not yet learned
            if include and spellData.reactiveWindow then
                local known = false
                if IsSpellKnown and IsSpellKnown(spellData.spellID) then
                    known = true
                elseif IsPlayerSpell and IsPlayerSpell(spellData.spellID) then
                    known = true
                end
                if not known then
                    include = false
                end
            end

            if include then
                local allRankIDs = self.LibSpellDB:GetAllRankIDs(spellData.spellID)
                table.insert(procs, {
                    spellID = spellData.spellID,
                    name = spellData.name,
                    duration = spellData.duration or 15,
                    procInfo = spellData.procInfo,
                    allRankIDs = allRankIDs,
                    requiredItemIDs = spellData.requiredItemIDs,
                    reactiveWindow = spellData.reactiveWindow,
                    source = "proc",
                })
            end
        end
    end

    return procs
end

-- Load external buffs from LibSpellDB (tagged IMPORTANT_EXTERNAL)
-- Excludes spells already loaded as class procs to avoid duplicates.
function AuraTracker:GetExternalAuras()
    local externals = {}
    if not self.LibSpellDB then return externals end

    -- Build a set of proc spellIDs we already have (avoid duplicates)
    local procIDs = {}
    local libProcs = self.LibSpellDB:GetProcs(addon.playerClass)
    for _, spellData in ipairs(libProcs) do
        procIDs[spellData.spellID] = true
    end

    -- Collect from both IMPORTANT_EXTERNAL and MINOR_EXTERNAL tags
    for _, tag in ipairs({"IMPORTANT_EXTERNAL", "MINOR_EXTERNAL"}) do
        local tagged = self.LibSpellDB:GetSpellsByTag(tag)
        for _, spellData in pairs(tagged) do
            if not procIDs[spellData.spellID] then
                local allRankIDs = self.LibSpellDB:GetAllRankIDs(spellData.spellID)
                table.insert(externals, {
                    spellID = spellData.spellID,
                    name = spellData.name,
                    duration = spellData.duration or 30,
                    allRankIDs = allRankIDs,
                    source = "external",
                })
            end
        end
    end

    return externals
end

-- Load custom auras from profile settings
function AuraTracker:GetCustomAuras()
    local customs = {}
    local db = addon.db and addon.db.profile and addon.db.profile.auraTracker
    if not db or not db.customAuras then return customs end

    for _, entry in ipairs(db.customAuras) do
        local spellID = entry.id
        local spellName = entry.name

        -- Resolve spell info (works for any valid spell ID, even if player doesn't know it)
        local resolvedName, _, resolvedIcon, _, _, _, resolvedID
        if spellID then
            resolvedName, _, resolvedIcon = GetSpellInfo(spellID)
        elseif spellName then
            resolvedName, _, resolvedIcon, _, _, _, resolvedID = GetSpellInfo(spellName)
            spellID = resolvedID
        end

        if resolvedName then
            table.insert(customs, {
                spellID = spellID or 0,
                name = resolvedName,
                duration = 0,  -- Unknown, will use actual buff duration
                source = "custom",
                customName = spellName,  -- Original user-entered name (for name-based lookup)
            })
        elseif spellName then
            -- Unresolvable at load time (player doesn't know the spell).
            -- Keep the entry so it can match by name at runtime when the buff appears.
            table.insert(customs, {
                spellID = 0,
                name = spellName,
                duration = 0,
                source = "custom",
                customName = spellName,
            })
        end
    end

    return customs
end

function AuraTracker:OnPlayerEnteringWorld()
    self:UpdateAllProcs()
end

-- Rebuild proc list when weapons change (equipment-gated procs like Deep Thunder / Stormherald)
function AuraTracker:OnEquipmentChanged(event, slotID)
    -- Only care about weapon slots: 16 = main hand, 17 = off hand
    if slotID ~= 16 and slotID ~= 17 then return end
    self:RebuildFrames()
end

-- Tear down and recreate all proc frames (called on weapon swap to re-evaluate equipment-gated procs)
function AuraTracker:RebuildFrames()
    if not addon.hudFrame then return end

    -- Stop update ticker
    self.Events:UnregisterUpdate(self)

    -- Return existing frames to the pool for reuse — frames can't be
    -- garbage-collected and their Masque registrations persist, so
    -- recreating from scratch on every weapon swap would leak both.
    for _, frame in ipairs(self.icons or {}) do
        if frame.glowActive then
            self:HideProcGlow(frame)
            frame.glowActive = false
        end
        if self.Animations then
            self.Animations:StopScalePunch(frame.visual or frame)
        end
        frame:Hide()
        table.insert(self._iconPool, frame)
    end
    self.icons = {}

    if self.slideAnimator then
        self.slideAnimator:Stop()
        self.slideAnimator = nil
    end
    if self.container then
        self.container:Hide()
        self.container = nil
    end

    self.allAuras = nil

    -- Recreate
    self:CreateFrames(addon.hudFrame)
    addon.Layout:ForceRefresh()
end

function AuraTracker:OnAuraUpdate(event, unit)
    if unit == "player" or unit == "target" or unit == "targettarget" then
        self:UpdateAllProcs()
    end
end

function AuraTracker:OnTargetChanged()
    self:UpdateAllProcs()
end

-------------------------------------------------------------------------------
-- Layout System Integration
-------------------------------------------------------------------------------

-- Returns the height this element needs in the layout stack
function AuraTracker:GetLayoutHeight()
    local db = addon.db and addon.db.profile and addon.db.profile.auraTracker
    if not db or not db.enabled then
        return 0
    end
    if not self.container then
        return 0
    end
    
    -- Return the icon height (using aspect ratio if configured)
    local iconSize = db.iconSize
    local aspectRatio = db.iconAspectRatio
    local _, iconHeight = self.Utils:GetIconDimensions(iconSize, aspectRatio)
    return iconHeight
end

-- Position this element at the given Y offset (center of element)
function AuraTracker:SetLayoutPosition(centerY)
    if not self.container then return end
    
    self.container:ClearAllPoints()
    self.container:SetPoint("CENTER", self.container:GetParent(), "CENTER", 0, centerY)
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function AuraTracker:CreateFrames(parent)
    local db = addon.db.profile.auraTracker
    
    if not db or not db.enabled then return end

    -- Load all aura sources: class procs + external buffs + custom auras
    local allAuras = self:LoadAllAuras()
    if not allAuras or #allAuras == 0 then
        self.Utils:Debug("AuraTracker: No auras to track for " .. (addon.playerClass or "unknown"))
        return
    end

    -- Store for later reference
    self.allAuras = allAuras

    -- Get width/height based on aspect ratio (needed for sizing)
    local iconSize = db.iconSize
    local aspectRatio = db.iconAspectRatio
    local iconWidth, iconHeight = self.Utils:GetIconDimensions(iconSize, aspectRatio)
    
    -- Container frame (position will be set by layout system)
    local container = CreateFrame("Frame", nil, parent)
    container:SetPoint("CENTER", parent, "CENTER", 0, 0)  -- Temporary, layout will reposition
    container:EnableMouse(false)  -- Click-through
    self.container = container
    self.slideAnimator = self.Animations:CreateSlideAnimator(container, 12)

    -- Create icon frames for each proc
    local spacing = db.iconSpacing
    local totalWidth = (#allAuras * iconWidth) + ((#allAuras - 1) * spacing)
    
    container:SetSize(totalWidth, iconHeight)
    
    for i, procData in ipairs(allAuras) do
        local frame = self:CreateProcIcon(container, procData, i, iconSize, iconWidth, iconHeight, spacing, db)
        self.icons[i] = frame
    end
    
    -- Apply texcoords after all icons are created (handles Masque compositing)
    self:ApplyIconTexCoords()
    
    -- Start update ticker
    self.Events:RegisterUpdate(self, 0.1, self.UpdateAllProcs)
    
    -- Initial update
    self:UpdateAllProcs()
end

-- Apply texcoords to all proc icons based on current aspect ratio and zoom settings.
-- Delegates to IconFrameFactory which handles Masque compositing (reads Masque's
-- texcoords and applies VeevHUD zoom on top when Masque is active).
function AuraTracker:ApplyIconTexCoords()
    if self.iconFactory then
        self.iconFactory:ApplyTexCoords(
            self.icons or {},
            addon.db.profile.icons.iconZoom,
            addon.db.profile.auraTracker.iconAspectRatio,
            self.MasqueGroup
        )
    end
end

function AuraTracker:CreateProcIcon(parent, procData, index, size, iconWidth, iconHeight, spacing, db)
    local xOffset = (index - 1) * (iconWidth + spacing) - (parent:GetWidth() / 2) + (iconWidth / 2)

    -- Reuse a pooled frame when available — child widgets and Masque
    -- registration already exist, so only reset state and re-parent.
    local frame = table.remove(self._iconPool)
    local isReused = frame ~= nil
    local buttonName

    if isReused then
        frame:SetParent(parent)
        frame:ClearAllPoints()
        frame:SetSize(iconWidth, iconHeight)
        frame.visual:SetSize(iconWidth, iconHeight)
        frame.icon:SetSize(iconWidth, iconHeight)
        -- Clear runtime state left over from the previous assignment
        frame.wasInactive = nil
        frame.lastStart = nil
        frame.lastDuration = nil
        frame.lastExpirationTime = nil
        frame._activationTime = nil
        frame._needsProcAnim = nil
        frame.glowActive = false
        frame.reactiveWindowStart = nil
        frame.reactiveWindowExpires = nil
        frame.text:SetText("")
        frame.stacks:SetText("")
        frame.cooldown:Hide()
        frame:Show()
    else
        -- Create wrapper+visual+textContainer via shared factory
        buttonName = "VeevHUDAura" .. self.iconCounter
        self.iconCounter = self.iconCounter + 1
        frame = self.Utils:CreateWrapperIcon(parent, buttonName, iconWidth, iconHeight)
    end
    frame:SetPoint("CENTER", parent, "CENTER", xOffset, 0)

    local visual = frame.visual
    local icon = frame.icon

    -- Store proc data and dimensions on the wrapper
    frame.procData = procData
    frame.spellID = procData.spellID
    frame.iconSize = size
    frame.iconWidth = iconWidth
    frame.iconHeight = iconHeight

    -- Reactive window support (e.g., Victory Rush: usable for 20s after kill)
    frame.reactiveWindow = procData.reactiveWindow
    frame.reactiveWindowWasUsable = false

    -- Backdrop glow (soft radial halo behind icon) - on wrapper, BACKGROUND layer
    -- Created if intensity > 0 (intensity of 0 effectively disables it)
    local glowIntensity = db.backdropGlowIntensity
    if glowIntensity > 0 and not frame.backdropGlow then
        local backdropGlow = self.Utils:CreateTexture(frame, nil, "BACKGROUND", nil, -1)
        backdropGlow:SetPoint("CENTER", frame, "CENTER", 0, 0)
        backdropGlow:SetTexture("Interface\\BUTTONS\\UI-ActionButton-Border")
        backdropGlow:SetBlendMode("ADD")
        frame.backdropGlow = backdropGlow
    end
    if frame.backdropGlow then
        local backdropGlow = frame.backdropGlow
        backdropGlow:SetSize(iconWidth * db.backdropGlowSize, iconHeight * db.backdropGlowSize)
        local glowColor = db.backdropGlowColor
        backdropGlow:SetVertexColor(glowColor[1], glowColor[2], glowColor[3], glowIntensity)
        backdropGlow:Hide()
    end

    -- Border (BACKGROUND layer on visual - below icon so icon covers it when scaling)
    if not frame.border then
        local border = self.Utils:CreateTexture(visual, nil, "BACKGROUND")
        border:SetTexture([[Interface\Buttons\WHITE8X8]])
        border:SetVertexColor(0, 0, 0, 1)
        border:SetPoint("TOPLEFT", -1, 1)
        border:SetPoint("BOTTOMRIGHT", 1, -1)
        frame.border = border
    end

    -- Texcoords are set by ApplyIconTexCoords() after all icons are created

    -- Get icon texture: LibSpellDB icon (handles overrides) > GetSpellInfo icon > equipped item icon
    local spellName, _, spellIcon = GetSpellInfo(procData.spellID)
    local displayIcon = self.LibSpellDB and self.LibSpellDB:GetSpellIcon(procData.spellID) or spellIcon
    if procData.requiredItemIDs then
        for _, itemID in ipairs(procData.requiredItemIDs) do
            if IsEquippedItem(itemID) then
                displayIcon = GetItemIcon(itemID) or displayIcon
                break
            end
        end
    end
    if displayIcon then
        icon:SetTexture(displayIcon)
    else
        icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    end
    frame.spellName = spellName or procData.name

    -- Duration text (center) — on textContainer (unaffected by visual's scale)
    local textContainer = frame.textContainer
    local durationFontSize = math.max(10, math.floor(size * 0.38))
    if not frame.text then
        local text = textContainer:CreateFontString(nil, "OVERLAY", nil, 7)
        text:SetPoint("CENTER", textContainer, "CENTER", 0, 0)
        frame.text = text
    end
    self.Utils:ApplyFontOutline(frame.text, addon:GetFont(), durationFontSize, db)
    frame.text:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)

    -- Stack count (top right corner) — on textContainer
    local stacksFontSize = math.max(10, math.floor(size * 0.26))
    if not frame.stacks then
        local stacks = textContainer:CreateFontString(nil, "OVERLAY", nil, 7)
        stacks:SetPoint("TOPRIGHT", textContainer, "TOPRIGHT", 4, 4)
        stacks:SetJustifyH("RIGHT")
        stacks:SetJustifyV("TOP")
        frame.stacks = stacks
    end
    self.Utils:ApplyFontOutline(frame.stacks, addon:GetFont(), stacksFontSize, db)
    frame.stacks:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)

    -- Cooldown spiral for duration (on visual, so it scales with punch)
    if not frame.cooldown then
        local cooldown = CreateFrame("Cooldown", buttonName .. "Cooldown", visual, "CooldownFrameTemplate")
        cooldown:SetAllPoints(icon)
        cooldown:SetDrawEdge(false)
        cooldown:SetDrawBling(false)
        cooldown:SetDrawSwipe(true)
        cooldown:SetSwipeColor(0, 0, 0, 0.8)
        cooldown:SetReverse(true)
        cooldown:Hide()
        frame.cooldown = cooldown
        frame.Cooldown = cooldown  -- Masque reference

        -- Hide external cooldown text (OmniCC, ElvUI) - we use our own
        self:ConfigureCooldownText(cooldown)
    end

    -- Raise textContainer above the cooldown spiral (CooldownFrameTemplate pushes levels)
    textContainer:SetFrameLevel(visual:GetFrameLevel() + 10)

    -- Register with Masque if available (register the visual Button).
    -- Reused frames are already registered — re-adding would leak buttons.
    if self.MasqueGroup then
        if not isReused then
            self.MasqueGroup:AddButton(visual, {
                Icon = icon,
                Cooldown = frame.cooldown,
                Normal = visual.NormalTexture,
            })
        end
        -- Hide manual border — Masque provides its own
        frame.border:Hide()
    elseif not isReused then
        -- Apply built-in Classic Enhanced style when Masque is not installed
        addon.IconStyling:Apply(visual, size, addon.db.profile.auraTracker.iconAspectRatio)
    end

    -- Set initial state (inactive)
    frame:SetAlpha(db.inactiveAlpha)
    icon:SetDesaturated(true)

    return frame
end

-------------------------------------------------------------------------------
-- Updates
-------------------------------------------------------------------------------

function AuraTracker:UpdateAllProcs()
    if not self.icons then return end
    
    local db = addon.db.profile.auraTracker
    if not db then return end
    
    for _, frame in ipairs(self.icons) do
        self:UpdateProcIcon(frame, db)
    end
    
    -- Reposition visible icons to remove gaps
    if not db.showInactiveIcons then
        self:RepositionIcons()
    end
    
    -- Play queued proc animations (after repositioning so scale doesn't corrupt offsets)
    for _, frame in ipairs(self.icons) do
        if frame._needsProcAnim then
            self:PlayProcAnimation(frame)
            frame._needsProcAnim = nil
        end
    end
end

function AuraTracker:UpdateProcIcon(frame, db)
    if not frame or not frame.procData then return end
    
    local procData = frame.procData
    local spellID = procData.spellID
    
    -- Check if this proc is disabled in config
    if not addon:IsAuraEnabled(spellID) then
        frame:Hide()
        frame.wasInactive = true
        frame.text:SetText("")
        frame.stacks:SetText("")
        frame.cooldown:Hide()
        frame.lastStart = nil
        frame.lastDuration = nil
        frame.lastExpirationTime = nil
        frame._activationTime = nil
        frame.reactiveWindowStart = nil
        frame.reactiveWindowExpires = nil
        frame.reactiveWindowWasUsable = false
        if frame.backdropGlow then frame.backdropGlow:Hide() end
        if frame.glowActive then
            self:HideProcGlow(frame)
            frame.glowActive = false
        end
        if self.Animations and frame.visual then
            self.Animations:StopScalePunch(frame.visual)
        end
        self:ResetIconPosition(frame)
        return
    end
    
    -- Check if aura is active (buff on player, debuff on target, or buff on ally)
    local name, icon, count, debuffType, duration, expirationTime, source, isStealable,
          nameplateShowPersonal, spellId

    if frame.reactiveWindow then
        -- Reactive proc (e.g., Victory Rush): track spell usability window instead of UnitBuff
        local isUsable = IsUsableSpell(spellID)
        local wasUsable = frame.reactiveWindowWasUsable or false
        local now = GetTime()

        -- Transition: unusable -> usable: start window
        if isUsable and not wasUsable then
            frame.reactiveWindowStart = now
            frame.reactiveWindowExpires = now + frame.reactiveWindow
        end

        -- Transition: usable -> unusable: clear window (cast or expired)
        if not isUsable and wasUsable then
            frame.reactiveWindowStart = nil
            frame.reactiveWindowExpires = nil
        end

        -- Natural expiration
        if frame.reactiveWindowExpires and now >= frame.reactiveWindowExpires then
            frame.reactiveWindowStart = nil
            frame.reactiveWindowExpires = nil
        end

        frame.reactiveWindowWasUsable = isUsable

        -- Set locals for the display code below
        if frame.reactiveWindowExpires then
            local rwRemaining = frame.reactiveWindowExpires - now
            if rwRemaining > 0 then
                name = frame.spellName
                duration = frame.reactiveWindow
                expirationTime = frame.reactiveWindowExpires
            end
        end
    else
        -- Standard aura detection: buff on player, debuff on target, or buff on ally
        local allRankIDs = procData.allRankIDs
        local isOnTarget = procData.procInfo and procData.procInfo.onTarget
        local isOnAlly = procData.procInfo and procData.procInfo.onAlly
        if isOnTarget then
            name, icon, count, debuffType, duration, expirationTime = self:FindDebuffOnTarget(spellID, allRankIDs, procData.name)
        elseif isOnAlly then
            name, icon, count, debuffType, duration, expirationTime = self:FindBuffOnAlly(spellID, allRankIDs, procData.name)
        else
            name, icon, count, debuffType, duration, expirationTime, source, isStealable,
                  nameplateShowPersonal, spellId = self:FindBuffBySpellID(spellID, allRankIDs, procData.name)
        end
    end

    -- Apply source filter (own/notOwn/any)
    if name and source then
        local filter = addon:GetAuraSourceFilter(spellID, procData.source)
        if filter == C.AURA_SOURCE_OWN and source ~= "player" then
            name = nil
        elseif filter == C.AURA_SOURCE_NOT_OWN and source == "player" then
            name = nil
        end
    end

    local isActive = name ~= nil
    local remaining = 0

    if isActive and expirationTime and expirationTime > 0 then
        remaining = expirationTime - GetTime()
        if remaining < 0 then remaining = 0 end
    end
    
    if isActive then
        -- ACTIVE STATE: Full color, glow, duration
        local wasHidden = not frame:IsShown() or frame.wasInactive
        frame:Show()
        frame:SetAlpha(1)
        frame.icon:SetDesaturated(false)
        frame.wasInactive = false

        -- Track activation time for FIFO sort
        if wasHidden then
            frame._activationTime = GetTime()
        end
        
        -- Detect if proc was refreshed (expirationTime changed)
        local wasRefreshed = false
        if expirationTime and frame.lastExpirationTime then
            -- If expiration time increased, the proc was refreshed
            if expirationTime > frame.lastExpirationTime + 0.5 then
                wasRefreshed = true
            end
        end
        frame.lastExpirationTime = expirationTime
        
        -- Queue pop-in animation if just became active OR refreshed
        -- (played after RepositionIcons so scale doesn't corrupt offsets)
        if wasHidden or wasRefreshed then
            frame._needsProcAnim = true
        end

        -- Play sound on activation or refresh (if configured)
        if wasHidden or (wasRefreshed and addon:GetAuraSoundOnRefresh(spellID)) then
            addon.SoundManager:PlaySound(addon:GetAuraSound(spellID) or db.soundOnProc)
        end
        
        -- Show duration text
        if db.showDuration and remaining > 0 then
            frame.text:SetText(self.Utils:FormatCooldown(remaining))
        else
            frame.text:SetText("")
        end
        
        -- Show stack count
        if count and count > 1 then
            frame.stacks:SetText(count)
        else
            frame.stacks:SetText("")
        end
        
        -- Show duration spiral
        if duration and duration > 0 and expirationTime then
            local startTime = expirationTime - duration
            if frame.lastStart ~= startTime or frame.lastDuration ~= duration then
                frame.cooldown:SetCooldown(startTime, duration)
                frame.lastStart = startTime
                frame.lastDuration = duration
            end
            frame.cooldown:Show()
        else
            frame.cooldown:Hide()
        end
        
        -- Per-aura glow check (global setting AND per-aura override)
        local auraGlowEnabled = addon:IsAuraGlowEnabled(spellID)

        -- Show backdrop glow (soft halo behind icon) if intensity > 0 and per-aura glow enabled
        if frame.backdropGlow and db.backdropGlowIntensity > 0 and auraGlowEnabled then
            frame.backdropGlow:SetAlpha(db.backdropGlowIntensity)
            frame.backdropGlow:Show()
        elseif frame.backdropGlow then
            frame.backdropGlow:Hide()
        end

        -- Show edge glow (pixel glow matching aura style)
        local edgeGlowEnabled = db.activeGlow and auraGlowEnabled
        if edgeGlowEnabled and not frame.glowActive then
            self:ShowProcGlow(frame)
            frame.glowActive = true
        elseif not edgeGlowEnabled and frame.glowActive then
            self:HideProcGlow(frame)
            frame.glowActive = false
        end
    else
        -- INACTIVE STATE: Hide by default, or show dimmed if configured
        frame.wasInactive = true
        
        if db.showInactiveIcons then
            frame:SetAlpha(db.inactiveAlpha)
            frame.icon:SetDesaturated(true)
            frame:Show()
        else
            frame:Hide()
            -- Reset position tracking so it doesn't slide from old position when reappearing
            self:ResetIconPosition(frame)
        end
        
        frame.text:SetText("")
        frame.stacks:SetText("")
        frame.cooldown:Hide()
        frame.lastStart = nil
        frame.lastDuration = nil
        frame.lastExpirationTime = nil
        frame._activationTime = nil

        -- Hide backdrop glow
        if frame.backdropGlow then
            frame.backdropGlow:Hide()
        end
        
        -- Hide edge glow
        if frame.glowActive then
            self:HideProcGlow(frame)
            frame.glowActive = false
        end
        
        -- Stop any running scale punch animation on the visual
        if self.Animations and frame.visual then
            self.Animations:StopScalePunch(frame.visual)
        end
    end
end

-- Reposition visible icons dynamically (with optional smooth sliding animation)
function AuraTracker:RepositionIcons()
    if not self.icons or not self.container or not self.slideAnimator then return end

    local db = addon.db.profile.auraTracker
    local size = db.iconSize
    local aspectRatio = db.iconAspectRatio
    local iconWidth, iconHeight = self.Utils:GetIconDimensions(size, aspectRatio)
    local spacing = db.iconSpacing

    local visibleIcons = {}
    for _, frame in ipairs(self.icons) do
        if frame:IsShown() then
            table.insert(visibleIcons, frame)
        end
    end

    if #visibleIcons == 0 then return end

    -- Sort visible icons based on configured sort order
    local sortOrder = db.sortOrder
    if sortOrder == C.AURA_SORT_ORDER.FIFO then
        table.sort(visibleIcons, function(a, b)
            local aTime = a._activationTime or 0
            local bTime = b._activationTime or 0
            return aTime < bTime
        end)
    elseif sortOrder == C.AURA_SORT_ORDER.REMAINING then
        table.sort(visibleIcons, function(a, b)
            local aExp = a.lastExpirationTime or math.huge
            local bExp = b.lastExpirationTime or math.huge
            return aExp < bExp
        end)
    end
    -- FIXED = no sort, preserve self.icons registration order

    self.slideAnimator:LayoutFrames(visibleIcons, iconWidth, spacing, db.slideAnimation)
end

-- Reset position tracking when icon becomes hidden
function AuraTracker:ResetIconPosition(frame)
    if self.slideAnimator then
        self.slideAnimator:ResetFrame(frame)
    end
end

function AuraTracker:FindBuffBySpellID(spellID, allRankIDs, spellName)
    -- Use cached buff lookup to avoid scanning 40 buffs per proc per update
    local aura = self.Utils:GetCachedBuff("player", spellID, spellName)
    
    if aura then
        return aura.name, aura.icon, aura.count, aura.debuffType, aura.duration, 
               aura.expirationTime, aura.source, aura.isStealable, 
               aura.nameplateShowPersonal, aura.spellID
    end
    
    -- Check all rank IDs (player may have a lower rank of the talent)
    if allRankIDs then
        for rankID in pairs(allRankIDs) do
            if rankID ~= spellID then
                aura = self.Utils:GetCachedBuff("player", rankID)
                if aura then
                    return aura.name, aura.icon, aura.count, aura.debuffType, aura.duration, 
                           aura.expirationTime, aura.source, aura.isStealable, 
                           aura.nameplateShowPersonal, aura.spellID
                end
            end
        end
    end
    
    return nil
end

function AuraTracker:FindDebuffOnTarget(spellID, allRankIDs, spellName)
    -- Use cached debuff lookup on current target (with name fallback for version-specific IDs)
    -- Only track debuffs applied by the player
    local aura = self.Utils:GetCachedDebuff("target", spellID, spellName)

    if aura and aura.source == "player" then
        return aura.name, aura.icon, aura.count, aura.debuffType, aura.duration, 
               aura.expirationTime, aura.source, aura.isStealable, 
               aura.nameplateShowPersonal, aura.spellID
    end
    
    -- Check all rank IDs (player may have a lower rank of the talent)
    if allRankIDs then
        for rankID in pairs(allRankIDs) do
            if rankID ~= spellID then
                aura = self.Utils:GetCachedDebuff("target", rankID)
                if aura and aura.source == "player" then
                    return aura.name, aura.icon, aura.count, aura.debuffType, aura.duration, 
                           aura.expirationTime, aura.source, aura.isStealable, 
                           aura.nameplateShowPersonal, aura.spellID
                end
            end
        end
    end
    
    return nil
end

function AuraTracker:FindBuffOnAlly(spellID, allRankIDs, spellName)
    local unit = self.Utils:GetFriendlyBuffUnit()

    -- Check primary spell ID (with name fallback — buff IDs may differ across game versions)
    local aura = self.Utils:GetCachedBuff(unit, spellID, spellName)
    if aura then
        return aura.name, aura.icon, aura.count, aura.debuffType, aura.duration,
               aura.expirationTime, aura.source, aura.isStealable,
               aura.nameplateShowPersonal, aura.spellID
    end

    -- Check all rank IDs
    if allRankIDs then
        for rankID in pairs(allRankIDs) do
            if rankID ~= spellID then
                aura = self.Utils:GetCachedBuff(unit, rankID)
                if aura then
                    return aura.name, aura.icon, aura.count, aura.debuffType, aura.duration,
                           aura.expirationTime, aura.source, aura.isStealable,
                           aura.nameplateShowPersonal, aura.spellID
                end
            end
        end
    end

    return nil
end

-------------------------------------------------------------------------------
-- Proc Animation (scale punch using Animations utility)
-------------------------------------------------------------------------------

function AuraTracker:PlayProcAnimation(frame)
    if not frame then return end

    -- Punch the visual (not the wrapper) so slide animation is unaffected
    local scale = addon.db.profile.auraTracker.punchScale
    if self.Animations and frame.visual and scale > 1 then
        self.Animations:PlayScalePunch(frame.visual, scale)
    end
end

-------------------------------------------------------------------------------
-- Cooldown Text Configuration
-------------------------------------------------------------------------------

-- Configure external cooldown text addons (OmniCC, ElvUI, etc.)
-- We use our own text, so hide theirs
function AuraTracker:ConfigureCooldownText(cooldown)
    self.Utils:ConfigureCooldownText(cooldown, true)  -- Always hide external text
end

-------------------------------------------------------------------------------
-- Glow Effects
-------------------------------------------------------------------------------

function AuraTracker:ShowProcGlow(frame)
    -- Proc glow on the visual (glow API attaches to a frame)
    local target = frame.visual or frame
    -- Scale glow line length proportional to icon size (same ratio as ability icons: 10/56)
    local iconSize = addon.db.profile.auraTracker.iconSize
    local length = math.max(3, math.floor(iconSize * 10 / 56 + 0.5))
    self.Utils:ShowPixelGlow(target, {1.0, 0.75, 0.4, 1}, "procGlow", 6, 0.25, length, 1, 0, 0)
end

function AuraTracker:HideProcGlow(frame)
    local target = frame.visual or frame
    self.Utils:HidePixelGlow(target, "procGlow")
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

function AuraTracker:Refresh()
    -- Re-apply config settings to existing frames
    local db = addon.db.profile.auraTracker
    
    -- Create frames if they don't exist and we should have them
    if not self.container and db.enabled and addon.hudFrame then
        self:CreateFrames(addon.hudFrame)
    end
    
    if self.container then
        -- Get icon dimensions (needed for sizing with aspect ratio)
        local iconSize = db.iconSize
        local aspectRatio = db.iconAspectRatio
        local iconWidth, iconHeight = self.Utils:GetIconDimensions(iconSize, aspectRatio)
        
        -- Toggle visibility based on enabled
        if db.enabled then
            self.container:Show()
        else
            self.container:Hide()
        end
        
        -- Update icon sizes and spacing (use aspect ratio for height)
        local spacing = db.iconSpacing
        local numProcs = #(self.allAuras or {})
        local totalWidth = (numProcs * iconWidth) + ((numProcs - 1) * spacing)
        
        self.container:SetSize(totalWidth, iconHeight)
        
        -- Resize all icons and update stored dimensions
        for i, frame in ipairs(self.icons or {}) do
            local xOffset = (i - 1) * (iconWidth + spacing) - (totalWidth / 2) + (iconWidth / 2)
            -- Resize both wrapper and visual
            frame:SetSize(iconWidth, iconHeight)
            if frame.visual then
                frame.visual:SetSize(iconWidth, iconHeight)
            end
            frame.iconSize = iconSize
            frame.iconWidth = iconWidth
            frame.iconHeight = iconHeight
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", self.container, "CENTER", xOffset, 0)

            -- Resize icon texture (texcoords handled by ApplyIconTexCoords after ReSkin)
            if frame.icon then
                frame.icon:SetSize(iconWidth, iconHeight)
            end

            -- Update backdrop glow size to match new icon size
            if frame.backdropGlow then
                local glowWidth = iconWidth * db.backdropGlowSize
                local glowHeight = iconHeight * db.backdropGlowSize
                frame.backdropGlow:SetSize(glowWidth, glowHeight)
            end

            -- Update font sizes to match new icon size
            local fontPath = addon:GetFont()
            if frame.text then
                local durationFontSize = math.max(10, math.floor(iconSize * 0.38))
                self.Utils:ApplyFontOutline(frame.text, fontPath, durationFontSize, db)
            end
            if frame.stacks then
                local stacksFontSize = math.max(10, math.floor(iconSize * 0.26))
                self.Utils:ApplyFontOutline(frame.stacks, fontPath, stacksFontSize, db)
            end

            -- Reset slide animation position so RepositionIcons will snap to new position
            if self.slideAnimator then
                self.slideAnimator:ResetFrame(frame)
            end

            -- Update built-in style on the visual (not wrapper)
            addon.IconStyling:Update(frame.visual or frame, iconSize, self.MasqueGroup ~= nil, addon.db.profile.auraTracker.iconAspectRatio)
        end

        -- Tell Masque to re-apply skins at new icon sizes
        if self.MasqueGroup then
            self.MasqueGroup:ReSkin()
        end
    end

    -- Reapply texcoords (handles Masque compositing)
    self:ApplyIconTexCoords()

    -- Reposition to re-center visible icons
    self:RepositionIcons()
    
    self:UpdateAllProcs()
    
    -- Notify layout system (our height may have changed)
    addon.Layout:Refresh()
end

function AuraTracker:RefreshFonts(fontPath)
    -- Update fonts and text color on all proc icon text elements
    local db = addon.db.profile.auraTracker
    local iconSize = db.iconSize
    local tc = addon.db.profile.appearance.textColor

    for _, frame in ipairs(self.icons or {}) do
        -- Duration text
        if frame.text then
            local durationFontSize = math.max(10, math.floor(iconSize * 0.38))
            self.Utils:ApplyFontOutline(frame.text, fontPath, durationFontSize, db)
            frame.text:SetTextColor(tc.r, tc.g, tc.b)
        end

        -- Stacks text
        if frame.stacks then
            local stacksFontSize = math.max(10, math.floor(iconSize * 0.26))
            self.Utils:ApplyFontOutline(frame.stacks, fontPath, stacksFontSize, db)
            frame.stacks:SetTextColor(tc.r, tc.g, tc.b)
        end
    end
end
