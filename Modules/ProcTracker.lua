--[[
    VeevHUD - Proc Tracker Module
    Displays important proc buffs (Enrage, Flurry, etc.) in a dedicated area
    
    Design:
    - Icons shown above health bar
    - Active procs: Full color + glow + duration text
    - Inactive procs: Desaturated + dimmed (optional)
    
    Proc data is loaded from LibSpellDB (Data/Procs.lua)
]]

local ADDON_NAME, addon = ...

local ProcTracker = {}
addon:RegisterModule("ProcTracker", ProcTracker)

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function ProcTracker:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants
    
    -- Icon frames
    self.icons = {}
    
    -- Load LibSpellDB for proc data
    self.LibSpellDB = LibStub and LibStub("LibSpellDB-1.0", true)
    
    -- Register events
    self.Events:RegisterEvent(self, "UNIT_AURA", self.OnAuraUpdate)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)
    
    -- Initialize LibCustomGlow
    self.LibCustomGlow = LibStub and LibStub("LibCustomGlow-1.0", true)
    
    self.Utils:Debug("ProcTracker initialized")
end

-- Load procs from LibSpellDB for the given class
function ProcTracker:GetProcsForClass(class)
    local procs = {}
    
    if self.LibSpellDB then
        local libProcs = self.LibSpellDB:GetProcs(class)
        for _, spellData in ipairs(libProcs) do
            table.insert(procs, {
                spellID = spellData.spellID,
                name = spellData.name,
                duration = spellData.duration or 15,
                procInfo = spellData.procInfo,
            })
        end
    end
    
    if #procs == 0 then
        self.Utils:Debug("ProcTracker: No procs found in LibSpellDB for " .. (class or "unknown"))
    end
    
    return procs
end

function ProcTracker:OnPlayerEnteringWorld()
    self:UpdateAllProcs()
end

function ProcTracker:OnAuraUpdate(event, unit)
    if unit == "player" then
        self:UpdateAllProcs()
    end
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function ProcTracker:CreateFrames(parent)
    local db = addon.db.profile.procTracker
    
    if not db or not db.enabled then return end
    
    -- Get procs for current class from LibSpellDB
    local classProcs = self:GetProcsForClass(addon.playerClass)
    if not classProcs or #classProcs == 0 then
        self.Utils:Debug("ProcTracker: No procs defined for " .. (addon.playerClass or "unknown"))
        return
    end
    
    -- Store for later reference
    self.classProcs = classProcs
    
    -- Container frame
    local container = CreateFrame("Frame", "VeevHUD_ProcTracker", parent)
    container:SetPoint("CENTER", parent, "CENTER", 0, db.offsetY)
    self.container = container
    
    -- Create icon frames for each proc
    local iconSize = db.iconSize
    local spacing = db.iconSpacing
    local totalWidth = (#classProcs * iconSize) + ((#classProcs - 1) * spacing)
    
    container:SetSize(totalWidth, iconSize)
    
    for i, procData in ipairs(classProcs) do
        local frame = self:CreateProcIcon(container, procData, i, iconSize, spacing, db)
        self.icons[i] = frame
    end
    
    -- Start update ticker
    self.Events:RegisterUpdate(self, 0.1, self.UpdateAllProcs)
    
    -- Initial update
    self:UpdateAllProcs()
end

function ProcTracker:CreateProcIcon(parent, procData, index, size, spacing, db)
    local xOffset = (index - 1) * (size + spacing) - (parent:GetWidth() / 2) + (size / 2)
    
    local frame = CreateFrame("Button", "VeevHUD_Proc" .. index, parent)
    frame:SetSize(size, size)
    frame:SetPoint("CENTER", parent, "CENTER", xOffset, 0)
    
    -- Store proc data
    frame.procData = procData
    frame.spellID = procData.spellID
    
    -- Border (BACKGROUND layer - below icon so icon covers it when scaling)
    local border = frame:CreateTexture(nil, "BACKGROUND")
    border:SetTexture([[Interface\Buttons\WHITE8X8]])
    border:SetVertexColor(0, 0, 0, 1)
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    frame.border = border
    
    -- Icon texture (ARTWORK layer - above border)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    -- Zoom in slightly like other icons
    local zoom = 0.1
    icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
    frame.icon = icon
    
    -- Get spell texture
    local spellName, _, spellIcon = GetSpellInfo(procData.spellID)
    if spellIcon then
        icon:SetTexture(spellIcon)
    else
        icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    end
    frame.spellName = spellName or procData.name
    
    -- Duration text
    local text = frame:CreateFontString(nil, "OVERLAY")
    text:SetFont(self.C.FONTS.NUMBER, math.max(10, size * 0.35), "OUTLINE")
    text:SetPoint("CENTER", 0, 0)
    text:SetTextColor(1.0, 0.906, 0.745)  -- #ffe7be
    frame.text = text
    
    -- Stack count (bottom right, matching Rampage style from CooldownIcons)
    local stacksFontSize = math.max(10, math.floor(size * 0.32))
    local stacks = frame:CreateFontString(nil, "OVERLAY")
    stacks:SetFont(self.C.FONTS.NUMBER, stacksFontSize, "OUTLINE")
    stacks:SetPoint("BOTTOMRIGHT", -3, 3)
    stacks:SetTextColor(1.0, 0.906, 0.745)  -- #ffe7be to match aura state
    frame.stacks = stacks
    
    -- Cooldown spiral for duration
    local cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    cooldown:SetAllPoints(icon)
    cooldown:SetDrawEdge(false)
    cooldown:SetDrawBling(false)
    cooldown:SetDrawSwipe(true)
    cooldown:SetSwipeColor(0, 0, 0, 0.8)  -- Match buff active darkness
    cooldown:SetReverse(true)  -- Fills as time passes
    cooldown:Hide()
    frame.cooldown = cooldown
    
    -- Hide external cooldown text (OmniCC, ElvUI) - we use our own
    self:ConfigureCooldownText(cooldown)
    
    -- Set initial state (inactive)
    frame:SetAlpha(db.inactiveAlpha or 0.4)
    icon:SetDesaturated(true)
    
    return frame
end

-------------------------------------------------------------------------------
-- Updates
-------------------------------------------------------------------------------

function ProcTracker:UpdateAllProcs()
    if not self.icons then return end
    
    local db = addon.db.profile.procTracker
    
    for _, frame in ipairs(self.icons) do
        self:UpdateProcIcon(frame, db)
    end
    
    -- Reposition visible icons to remove gaps
    if not db.showInactiveIcons then
        self:RepositionIcons()
    end
end

function ProcTracker:UpdateProcIcon(frame, db)
    if not frame or not frame.procData then return end
    
    local procData = frame.procData
    local spellID = procData.spellID
    
    -- Check if buff is active
    local name, icon, count, debuffType, duration, expirationTime, source, isStealable, 
          nameplateShowPersonal, spellId = self:FindBuffBySpellID(spellID)
    
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
        
        -- Detect if proc was refreshed (expirationTime changed)
        local wasRefreshed = false
        if expirationTime and frame.lastExpirationTime then
            -- If expiration time increased, the proc was refreshed
            if expirationTime > frame.lastExpirationTime + 0.5 then
                wasRefreshed = true
            end
        end
        frame.lastExpirationTime = expirationTime
        
        -- Play pop-in animation if just became active OR refreshed
        if wasHidden or wasRefreshed then
            self:PlayProcAnimation(frame)
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
        
        -- Show glow
        if db.activeGlow and not frame.glowActive then
            self:ShowProcGlow(frame)
            frame.glowActive = true
        end
    else
        -- INACTIVE STATE: Hide by default, or show dimmed if configured
        frame.wasInactive = true
        
        if db.showInactiveIcons then
            frame:SetAlpha(db.inactiveAlpha or 0.4)
            frame.icon:SetDesaturated(true)
            frame:Show()
        else
            frame:Hide()
        end
        
        frame.text:SetText("")
        frame.stacks:SetText("")
        frame.cooldown:Hide()
        frame.lastStart = nil
        frame.lastDuration = nil
        frame.lastExpirationTime = nil
        
        -- Hide glow
        if frame.glowActive then
            self:HideProcGlow(frame)
            frame.glowActive = false
        end
        
        -- Stop any running animation
        if frame.procAnim then
            frame.procAnim:Stop()
        end
    end
end

-- Reposition visible icons dynamically (removes gaps when some are hidden)
function ProcTracker:RepositionIcons()
    if not self.icons or not self.container then return end
    
    local db = addon.db.profile.procTracker
    local size = db.iconSize
    local spacing = db.iconSpacing
    
    -- Count visible icons
    local visibleIcons = {}
    for _, frame in ipairs(self.icons) do
        if frame:IsShown() then
            table.insert(visibleIcons, frame)
        end
    end
    
    if #visibleIcons == 0 then return end
    
    -- Calculate total width and reposition
    local totalWidth = (#visibleIcons * size) + ((#visibleIcons - 1) * spacing)
    
    for i, frame in ipairs(visibleIcons) do
        local xOffset = (i - 1) * (size + spacing) - (totalWidth / 2) + (size / 2)
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", self.container, "CENTER", xOffset, 0)
    end
end

function ProcTracker:FindBuffBySpellID(spellID)
    -- Scan player buffs for the spell ID
    for i = 1, 40 do
        local name, icon, count, debuffType, duration, expirationTime, source, 
              isStealable, nameplateShowPersonal, buffSpellId = UnitBuff("player", i)
        
        if not name then break end
        
        if buffSpellId == spellID then
            return name, icon, count, debuffType, duration, expirationTime, source, 
                   isStealable, nameplateShowPersonal, buffSpellId
        end
    end
    
    return nil
end

-------------------------------------------------------------------------------
-- Proc Animation (scale punch + fade in using Animation API)
-------------------------------------------------------------------------------

function ProcTracker:PlayProcAnimation(frame)
    if not frame then return end
    
    -- Create animation group on first use
    if not frame.procAnim then
        local ag = frame:CreateAnimationGroup()
        
        -- Scale up from center
        local scaleUp = ag:CreateAnimation("Scale")
        scaleUp:SetOrigin("CENTER", 0, 0)
        scaleUp:SetScale(1.25, 1.25)  -- Scale to 125%
        scaleUp:SetDuration(0.1)
        scaleUp:SetSmoothing("OUT")
        scaleUp:SetOrder(1)
        
        -- Scale back down
        local scaleDown = ag:CreateAnimation("Scale")
        scaleDown:SetOrigin("CENTER", 0, 0)
        scaleDown:SetScale(1/1.25, 1/1.25)  -- Scale back to 100%
        scaleDown:SetDuration(0.15)
        scaleDown:SetSmoothing("IN")
        scaleDown:SetOrder(2)
        
        frame.procAnim = ag
    end
    
    frame.procAnim:Stop()
    frame.procAnim:Play()
end

-------------------------------------------------------------------------------
-- Cooldown Text Configuration
-------------------------------------------------------------------------------

-- Configure external cooldown text addons (OmniCC, ElvUI, etc.)
-- We use our own text, so hide theirs
function ProcTracker:ConfigureCooldownText(cooldown)
    -- Hide external cooldown text, use our own
    if OmniCC and OmniCC.Cooldown and OmniCC.Cooldown.SetNoCooldownCount then
        cooldown:SetHideCountdownNumbers(true)
        OmniCC.Cooldown.SetNoCooldownCount(cooldown, true)
    elseif ElvUI and ElvUI[1] and ElvUI[1].CooldownEnabled 
           and ElvUI[1].ToggleCooldown and ElvUI[1]:CooldownEnabled() then
        cooldown:SetHideCountdownNumbers(true)
        ElvUI[1]:ToggleCooldown(cooldown, false)
    else
        cooldown:SetHideCountdownNumbers(true)
    end
end

-------------------------------------------------------------------------------
-- Glow Effects
-------------------------------------------------------------------------------

function ProcTracker:ShowProcGlow(frame)
    if self.LibCustomGlow then
        -- Use pixel glow like aura active state
        self.LibCustomGlow.PixelGlow_Start(
            frame,
            {1, 0.812, 0.686, 1},  -- #ffcfaf color
            8,      -- Number of particles
            0.25,   -- Frequency
            8,      -- Length
            2,      -- Thickness
            2,      -- xOffset
            2,      -- yOffset
            false,  -- Border
            "procGlow"
        )
    end
end

function ProcTracker:HideProcGlow(frame)
    if self.LibCustomGlow then
        self.LibCustomGlow.PixelGlow_Stop(frame, "procGlow")
    end
end

-------------------------------------------------------------------------------
-- Enable/Disable
-------------------------------------------------------------------------------

function ProcTracker:Enable()
    if self.container then
        self.container:Show()
    end
end

function ProcTracker:Disable()
    if self.container then
        self.container:Hide()
    end
end

function ProcTracker:Refresh()
    self:UpdateAllProcs()
end
