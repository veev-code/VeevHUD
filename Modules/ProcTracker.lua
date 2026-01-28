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
    
    -- Calculate position relative to health bar (proc tracker is ABOVE health bar)
    local healthDb = addon.db.profile.healthBar
    local resourceDb = addon.db.profile.resourceBar
    local procGap = db.gapAboveHealthBar
    local procOffset
    
    if healthDb.enabled then
        -- Health bar is shown - position above it
        local healthBarOffset
        if resourceDb.enabled then
            healthBarOffset = resourceDb.height / 2 + healthDb.height / 2
        else
            healthBarOffset = 0
        end
        local healthBarTop = healthBarOffset + healthDb.height / 2
        procOffset = healthBarTop + procGap + db.iconSize / 2
    elseif resourceDb.enabled then
        -- Only resource bar shown - position above it
        local resourceBarTop = resourceDb.height / 2
        procOffset = resourceBarTop + procGap + db.iconSize / 2
    else
        -- No bars shown - position at center
        procOffset = procGap + db.iconSize / 2
    end
    
    -- Container frame
    local container = CreateFrame("Frame", "VeevHUD_ProcTracker", parent)
    container:SetPoint("CENTER", parent, "CENTER", 0, procOffset)
    container:EnableMouse(false)  -- Click-through
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
    frame:EnableMouse(false)  -- Click-through
    
    -- Store proc data
    frame.procData = procData
    frame.spellID = procData.spellID
    
    -- Backdrop glow (soft radial halo behind icon) - BACKGROUND layer, behind everything
    -- Created if intensity > 0 (intensity of 0 effectively disables it)
    local glowIntensity = db.backdropGlowIntensity
    if glowIntensity > 0 then
        local backdropGlow = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
        local glowSize = size * db.backdropGlowSize
        backdropGlow:SetSize(glowSize, glowSize)
        backdropGlow:SetPoint("CENTER", frame, "CENTER", 0, 0)
        -- Use a simple circular glow texture
        backdropGlow:SetTexture("Interface\\BUTTONS\\UI-ActionButton-Border")
        backdropGlow:SetBlendMode("ADD")
        local glowColor = db.backdropGlowColor
        backdropGlow:SetVertexColor(glowColor[1], glowColor[2], glowColor[3], glowIntensity)
        backdropGlow:Hide()  -- Hidden by default, shown when proc is active
        frame.backdropGlow = backdropGlow
    end
    
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
    
    -- Text container (sits above cooldown spiral)
    local textContainer = CreateFrame("Frame", nil, frame)
    textContainer:SetAllPoints(frame)
    textContainer:SetFrameLevel(frame:GetFrameLevel() + 10)
    frame.textContainer = textContainer
    
    -- Duration text (center)
    local durationFontSize = math.max(10, math.floor(size * 0.5))
    local text = textContainer:CreateFontString(nil, "OVERLAY", nil, 7)
    text:SetFont(self.C.FONTS.NUMBER, durationFontSize, "OUTLINE")
    text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    text:SetTextColor(self.C.COLORS.TEXT.r, self.C.COLORS.TEXT.g, self.C.COLORS.TEXT.b)
    frame.text = text
    
    -- Stack count (top right corner, slightly larger font)
    local stacksFontSize = math.max(11, math.floor(size * 0.55))
    local stacks = textContainer:CreateFontString(nil, "OVERLAY", nil, 7)
    stacks:SetFont(self.C.FONTS.NUMBER, stacksFontSize, "OUTLINE")
    stacks:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 4, 4)
    stacks:SetJustifyH("RIGHT")
    stacks:SetJustifyV("TOP")
    stacks:SetTextColor(self.C.COLORS.TEXT.r, self.C.COLORS.TEXT.g, self.C.COLORS.TEXT.b)
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
    frame:SetAlpha(db.inactiveAlpha)
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
        
        -- Show backdrop glow (soft halo behind icon) if intensity > 0
        if frame.backdropGlow and db.backdropGlowIntensity > 0 then
            frame.backdropGlow:SetAlpha(db.backdropGlowIntensity)
            frame.backdropGlow:Show()
        elseif frame.backdropGlow then
            frame.backdropGlow:Hide()
        end
        
        -- Show edge glow (pixel glow matching aura style)
        if db.activeGlow and not frame.glowActive then
            self:ShowProcGlow(frame)
            frame.glowActive = true
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
        
        -- Hide backdrop glow
        if frame.backdropGlow then
            frame.backdropGlow:Hide()
        end
        
        -- Hide edge glow
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

-- Reposition visible icons dynamically (with optional smooth sliding animation)
function ProcTracker:RepositionIcons()
    if not self.icons or not self.container then return end
    
    local db = addon.db.profile.procTracker
    local size = db.iconSize
    local spacing = db.iconSpacing
    local useSlideAnimation = db.slideAnimation ~= false  -- default true
    
    -- Count visible icons
    local visibleIcons = {}
    for _, frame in ipairs(self.icons) do
        if frame:IsShown() then
            table.insert(visibleIcons, frame)
        end
    end
    
    if #visibleIcons == 0 then return end
    
    -- Calculate total width and target positions
    local totalWidth = (#visibleIcons * size) + ((#visibleIcons - 1) * spacing)
    
    for i, frame in ipairs(visibleIcons) do
        local targetX = (i - 1) * (size + spacing) - (totalWidth / 2) + (size / 2)
        
        if useSlideAnimation then
            -- Initialize current position if not set (first time or just became visible)
            if not frame.currentX then
                frame.currentX = targetX
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", self.container, "CENTER", targetX, 0)
            end
            
            -- Set target for sliding
            frame.targetX = targetX
        else
            -- No animation - snap directly to position
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", self.container, "CENTER", targetX, 0)
            frame.currentX = targetX
            frame.targetX = targetX
        end
    end
    
    -- Start slide update if animation enabled and not already running
    if useSlideAnimation and not self.slideUpdateRunning then
        self:StartSlideUpdate()
    end
end

-- Smooth sliding animation using OnUpdate lerp
function ProcTracker:StartSlideUpdate()
    if self.slideUpdateRunning then return end
    
    self.slideUpdateRunning = true
    local slideSpeed = 12  -- Higher = faster (pixels per second multiplier)
    
    self.container:SetScript("OnUpdate", function(_, elapsed)
        local allSettled = true
        
        for _, frame in ipairs(self.icons) do
            if frame:IsShown() and frame.currentX and frame.targetX then
                local diff = frame.targetX - frame.currentX
                
                -- If close enough, snap to target
                if math.abs(diff) < 0.5 then
                    if frame.currentX ~= frame.targetX then
                        frame.currentX = frame.targetX
                        frame:ClearAllPoints()
                        frame:SetPoint("CENTER", self.container, "CENTER", frame.targetX, 0)
                    end
                else
                    -- Lerp toward target (ease-out feel)
                    allSettled = false
                    local move = diff * math.min(1, elapsed * slideSpeed)
                    frame.currentX = frame.currentX + move
                    frame:ClearAllPoints()
                    frame:SetPoint("CENTER", self.container, "CENTER", frame.currentX, 0)
                end
            end
        end
        
        -- Stop updating when all icons have settled
        if allSettled then
            self.container:SetScript("OnUpdate", nil)
            self.slideUpdateRunning = false
        end
    end)
end

-- Reset position tracking when icon becomes hidden
function ProcTracker:ResetIconPosition(frame)
    frame.currentX = nil
    frame.targetX = nil
end

function ProcTracker:FindBuffBySpellID(spellID)
    -- Use cached buff lookup to avoid scanning 40 buffs per proc per update
    local aura = self.Utils:GetCachedBuff("player", spellID)
    
    if aura then
        return aura.name, aura.icon, aura.count, aura.debuffType, aura.duration, 
               aura.expirationTime, aura.source, aura.isStealable, 
               aura.nameplateShowPersonal, aura.spellID
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
        -- Proc glow: Subtle animated border
        -- PixelGlow_Start(frame, color, N, frequency, length, thickness, xOffset, yOffset, border, key)
        self.LibCustomGlow.PixelGlow_Start(
            frame,
            {1.0, 0.75, 0.4, 1},  -- Warm orange-gold
            6,      -- Fewer particles for cleaner look
            0.25,   -- Slower frequency
            4,      -- Shorter particle length
            1,      -- Thinner
            0,      -- xOffset - centered
            0,      -- yOffset - centered
            true,   -- Border: constrain to frame edges
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
    -- Re-apply config settings to existing frames
    local db = addon.db.profile.procTracker
    local healthDb = addon.db.profile.healthBar
    local resourceDb = addon.db.profile.resourceBar
    
    if self.container then
        -- Calculate position relative to health bar (proc tracker is ABOVE health bar)
        local procGap = db.gapAboveHealthBar
        local procOffset
        
        if healthDb.enabled then
            -- Health bar is shown - position above it
            local healthBarOffset
            if resourceDb.enabled then
                healthBarOffset = resourceDb.height / 2 + healthDb.height / 2
            else
                healthBarOffset = 0
            end
            local healthBarTop = healthBarOffset + healthDb.height / 2
            procOffset = healthBarTop + procGap + db.iconSize / 2
        elseif resourceDb.enabled then
            -- Only resource bar shown - position above it
            local resourceBarTop = resourceDb.height / 2
            procOffset = resourceBarTop + procGap + db.iconSize / 2
        else
            -- No bars shown - position at center
            procOffset = procGap + db.iconSize / 2
        end
        
        self.container:ClearAllPoints()
        self.container:SetPoint("CENTER", self.container:GetParent(), "CENTER", 0, procOffset)
        
        -- Toggle visibility based on enabled
        if db.enabled then
            self.container:Show()
        else
            self.container:Hide()
        end
        
        -- Update icon sizes and spacing
        local iconSize = db.iconSize
        local spacing = db.iconSpacing
        local numProcs = #(self.classProcs or {})
        local totalWidth = (numProcs * iconSize) + ((numProcs - 1) * spacing)
        
        self.container:SetSize(totalWidth, iconSize)
        
        -- Reposition and resize all icons
        for i, frame in ipairs(self.icons or {}) do
            local xOffset = (i - 1) * (iconSize + spacing) - (totalWidth / 2) + (iconSize / 2)
            frame:SetSize(iconSize, iconSize)
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", self.container, "CENTER", xOffset, 0)
            
            -- Update border to match new size
            if frame.border then
                frame.border:ClearAllPoints()
                frame.border:SetPoint("TOPLEFT", -1, 1)
                frame.border:SetPoint("BOTTOMRIGHT", 1, -1)
            end
            
            -- Update backdrop glow size to match new icon size
            if frame.backdropGlow then
                local glowSize = iconSize * 2.0
                frame.backdropGlow:SetSize(glowSize, glowSize)
            end
        end
    end
    
    self:UpdateAllProcs()
end
