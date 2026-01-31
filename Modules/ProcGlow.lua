--[[
    VeevHUD - Proc Glow Module
    Tracks and displays proc/activation overlays
]]

local ADDON_NAME, addon = ...

local ProcGlow = {}
addon:RegisterModule("ProcGlow", ProcGlow)

-- Active procs
ProcGlow.activeProcs = {}

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function ProcGlow:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants

    -- Register for spell activation overlay events (Blizzard's built-in proc system)
    self.Events:RegisterEvent(self, "SPELL_ACTIVATION_OVERLAY_SHOW", self.OnProcShow)
    self.Events:RegisterEvent(self, "SPELL_ACTIVATION_OVERLAY_HIDE", self.OnProcHide)

    -- Register for aura events (for custom proc tracking)
    self.Events:RegisterEvent(self, "UNIT_AURA", self.OnAuraUpdate)

    self.Utils:Debug("ProcGlow initialized")
end

-------------------------------------------------------------------------------
-- Blizzard Spell Activation Overlay
-------------------------------------------------------------------------------

function ProcGlow:OnProcShow(event, spellID, ...)
    if not spellID then return end

    self.Utils:Debug("Proc shown:", spellID)

    self.activeProcs[spellID] = {
        spellID = spellID,
        startTime = GetTime(),
        source = "overlay",
    }

    self:UpdateDisplay()
end

function ProcGlow:OnProcHide(event, spellID)
    if not spellID then return end

    self.Utils:Debug("Proc hidden:", spellID)

    self.activeProcs[spellID] = nil

    self:UpdateDisplay()
end

-------------------------------------------------------------------------------
-- Custom Proc Tracking via Auras
-------------------------------------------------------------------------------

-- Procs to track that might not use the overlay system
ProcGlow.customProcs = {
    -- Warrior
    [12964] = true,   -- Battle Trance (for retail-style)

    -- Priest
    [18095] = true,   -- Nightfall (Shadow Trance)

    -- Mage
    [12536] = true,   -- Clearcasting

    -- Warlock
    [17941] = true,   -- Shadow Trance (Nightfall proc)

    -- Rogue
    -- Add any proc buffs here

    -- Shaman
    -- Elemental Focus, etc.

    -- Paladin
    [20375] = true,   -- Seal of Command (proc window)
}

function ProcGlow:OnAuraUpdate(event, unit)
    if unit ~= "player" then return end

    -- Check for custom proc buffs
    for spellID in pairs(self.customProcs) do
        local aura = self.Utils:FindBuffBySpellID("player", spellID)

        if aura and not self.activeProcs[spellID] then
            -- Proc appeared
            self.activeProcs[spellID] = {
                spellID = spellID,
                startTime = GetTime(),
                expirationTime = aura.expirationTime,
                source = "aura",
                icon = aura.icon,
            }
            self:UpdateDisplay()
        elseif not aura and self.activeProcs[spellID] then
            -- Proc expired
            self.activeProcs[spellID] = nil
            self:UpdateDisplay()
        end
    end
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function ProcGlow:CreateFrames(parent)
    local db = addon.db.profile.procIcons

    if not db.enabled then return end

    -- Container for proc icons
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(db.maxIcons * (db.iconSize + db.iconSpacing), db.iconSize)
    container:SetPoint("CENTER", parent, "CENTER", 0, db.offsetY)
    container:EnableMouse(false)  -- Click-through
    self.container = container

    -- Pre-create icon pool
    self.iconPool = {}
    for i = 1, db.maxIcons do
        local icon = self:CreateProcIcon(container, i)
        icon:Hide()
        self.iconPool[i] = icon
    end
end

function ProcGlow:CreateProcIcon(parent, index)
    local db = addon.db.profile.procIcons
    local size = db.iconSize

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(size, size)
    frame:EnableMouse(false)  -- Click-through

    -- Icon texture
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    frame.icon = icon

    -- Border
    local border = frame:CreateTexture(nil, "OVERLAY")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 1)
    border:SetDrawLayer("OVERLAY", -1)
    frame.border = border

    -- Duration text
    local text = frame:CreateFontString(nil, "OVERLAY")
    text:SetFont(addon:GetFont(), 11, "OUTLINE")
    text:SetPoint("CENTER", 0, 0)
    text:SetTextColor(1, 1, 0)
    frame.text = text

    -- Glow effect
    if db.glowEnabled then
        self:AddGlowEffect(frame)
    end

    frame.index = index
    return frame
end

function ProcGlow:AddGlowEffect(frame)
    -- Create pulsing glow border
    local glow = frame:CreateTexture(nil, "BACKGROUND")
    glow:SetPoint("TOPLEFT", -6, 6)
    glow:SetPoint("BOTTOMRIGHT", 6, -6)
    glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    glow:SetBlendMode("ADD")
    glow:SetVertexColor(1, 1, 0.5, 0.8)
    frame.glow = glow

    -- Animation
    local ag = glow:CreateAnimationGroup()
    ag:SetLooping("REPEAT")

    local scale1 = ag:CreateAnimation("Scale")
    scale1:SetScale(1.1, 1.1)
    scale1:SetDuration(0.4)
    scale1:SetOrder(1)
    scale1:SetSmoothing("IN_OUT")

    local scale2 = ag:CreateAnimation("Scale")
    scale2:SetScale(0.909, 0.909)  -- 1/1.1 to return to original
    scale2:SetDuration(0.4)
    scale2:SetOrder(2)
    scale2:SetSmoothing("IN_OUT")

    frame.glowAnim = ag
    ag:Play()
end

-------------------------------------------------------------------------------
-- Display Updates
-------------------------------------------------------------------------------

function ProcGlow:UpdateDisplay()
    if not self.container or not self.iconPool then return end

    local db = addon.db.profile.procIcons
    local index = 0

    for spellID, procData in pairs(self.activeProcs) do
        index = index + 1
        if index > db.maxIcons then break end

        local frame = self.iconPool[index]
        if frame then
            self:SetupProcIcon(frame, procData, db)
            frame:Show()
        end
    end

    -- Hide remaining icons
    for i = index + 1, db.maxIcons do
        if self.iconPool[i] then
            self.iconPool[i]:Hide()
        end
    end

    -- Position icons
    self:PositionIcons(index, db)
end

function ProcGlow:SetupProcIcon(frame, procData, db)
    -- Get icon texture
    local texture = procData.icon or self.Utils:GetSpellTexture(procData.spellID)
    frame.icon:SetTexture(texture)

    -- Update duration text if applicable
    if procData.expirationTime then
        local remaining = procData.expirationTime - GetTime()
        if remaining > 0 then
            frame.text:SetText(self.Utils:FormatCooldown(remaining))
        else
            frame.text:SetText("")
        end
    else
        frame.text:SetText("")
    end

    frame.spellID = procData.spellID
end

function ProcGlow:PositionIcons(count, db)
    if count == 0 then return end

    local size = db.iconSize
    local spacing = db.iconSpacing
    local totalWidth = count * size + (count - 1) * spacing
    local startX = -totalWidth / 2 + size / 2

    for i = 1, count do
        local frame = self.iconPool[i]
        if frame and frame:IsShown() then
            local x = startX + (i - 1) * (size + spacing)
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", self.container, "CENTER", x, 0)
        end
    end
end

-------------------------------------------------------------------------------
-- Enable/Disable
-------------------------------------------------------------------------------

function ProcGlow:Enable()
    if self.container then
        self.container:Show()
    end
end

function ProcGlow:Disable()
    if self.container then
        self.container:Hide()
    end
end

function ProcGlow:Refresh()
    self:UpdateDisplay()
end

function ProcGlow:RefreshFonts(fontPath)
    -- Update fonts on all proc icon text elements
    for _, frame in ipairs(self.iconPool or {}) do
        if frame.text then
            frame.text:SetFont(fontPath, 11, "OUTLINE")
        end
    end
end
