--[[
    VeevHUD - Icon Frame Factory
    Frame construction service for cooldown/aura icons. Creates fully-equipped
    icon frames with all child elements. No spell-specific metadata — that's
    configured later by CooldownIcons:SetupIcon().

    Extracted from CooldownIcons:CreateIcon to enforce Layer 3 (Construction)
    separation from Layer 4 (Orchestration).
]]

local ADDON_NAME, addon = ...

local IconFrameFactory = {}
addon:RegisterModule("IconFrameFactory", IconFrameFactory)

-- Unique button naming counter for Masque compatibility
IconFrameFactory.iconCounter = 0

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function IconFrameFactory:Initialize()
    self.Utils = addon.Utils
    self.Animations = addon.Animations
end

-------------------------------------------------------------------------------
-- Public API: Create Icon Frame
-------------------------------------------------------------------------------

-- Create a fully-equipped icon frame with all child elements.
-- Returns a Button frame (Masque-compatible) with:
--   .icon, .Icon           — Icon texture + Masque reference
--   .NormalTexture          — Hidden normal texture for Masque fallback
--   .cooldown, .Cooldown   — Cooldown spiral + Masque reference
--   .text, .textFrame      — Cooldown text overlay
--   .charges, .Count       — Charges display + Masque reference
--   .stacks                — Aura stack count
--   .keybindText           — Keyboard shortcut display
--   .resourceBar            — Horizontal bottom bar (resource cost)
--   .resourceFill           — Vertical fill overlay (resource cost)
--   .rangeFrame, .rangeOverlay — Out-of-range red tint with fade animations
--   .queuedHighlight       — Queued spell highlight texture
--   .index                 — Position within row
--   .iconSize, .iconWidth, .iconHeight — Dimensions
--
-- Does NOT set: spellID, actualSpellID, spellData, rowIndex, or any
-- spell-specific metadata. Those are configured by CooldownIcons:SetupIcon().
--
-- Does NOT register with Masque or apply fallback styling — caller controls
-- that via RegisterWithMasque() or ApplyFallbackStyle().
--
-- @param parent  Row frame to parent the icon to
-- @param index   Position within the row (1..maxIcons)
-- @param size    Base icon size (height; width = size * aspectRatio)
function IconFrameFactory:CreateIconFrame(parent, index, size)
    local db = addon.db.profile.icons
    size = size or db.iconSize

    -- Get width/height based on aspect ratio (width = size * ratio, height = size)
    local iconWidth, iconHeight = self.Utils:GetIconDimensions(size, db.iconAspectRatio)

    -- Create as Button for Masque compatibility
    local buttonName = "VeevHUDIcon" .. self.iconCounter
    self.iconCounter = self.iconCounter + 1

    local frame = CreateFrame("Button", buttonName, parent)
    frame:SetSize(iconWidth, iconHeight)
    frame:EnableMouse(false)  -- Click-through (display only, no interaction)
    frame.iconSize = size  -- Base size (used for calculations)
    frame.iconWidth = iconWidth
    frame.iconHeight = iconHeight

    -- Icon texture - fills the frame, spacing between icons creates separation
    local icon = frame:CreateTexture(buttonName .. "Icon", "ARTWORK")
    icon:SetAllPoints()
    -- Apply texcoords with zoom and aspect ratio cropping
    local zoomPerEdge = db.iconZoom / 2
    local left, right, top, bottom = self.Utils:GetIconTexCoords(zoomPerEdge, db.iconAspectRatio)
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
    cooldown:SetSwipeColor(0, 0, 0, 1)
    cooldown:SetReverse(false)  -- Swipe = remaining time (drains as cooldown progresses)
    frame.cooldown = cooldown
    frame.Cooldown = cooldown  -- Masque reference

    -- Configure external cooldown text (OmniCC, ElvUI, etc.)
    local renderer = addon:GetModule("IconRenderer")
    if renderer then
        renderer:ConfigureCooldownText(cooldown)
    end

    -- Text overlay frame (above everything including pixel glow)
    local textFrame = CreateFrame("Frame", nil, frame)
    textFrame:SetAllPoints()
    textFrame:SetFrameLevel(frame:GetFrameLevel() + 20)  -- Above pixel glow (which uses +8)

    -- Cooldown text (on top of everything) - scale font with icon size
    local fontSize = math.max(14, math.floor(size * 0.38))
    local text = textFrame:CreateFontString(nil, "OVERLAY", nil, 7)
    text:SetFont(addon:GetFont(), fontSize, "OUTLINE")
    text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    text:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)
    text:SetShadowOffset(0.5, -0.5)
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
    stacks:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)
    frame.stacks = stacks

    -- Keybind text (bottom right, shows keyboard shortcut like default action bars)
    -- Parented to textFrame so it renders above cooldown spiral
    frame.keybindText = addon.Keybinds:CreateKeybindText(frame, textFrame, addon:GetFont(), db.keybindTextSize, size)

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
    resourceBarFill:SetVertexColor(1, 0, 0, 1)  -- Default red (updated based on power type)
    resourceBarFill:SetWidth(1)
    resourceBar.fill = resourceBarFill

    resourceBar:Hide()
    frame.resourceBar = resourceBar

    -- Option B: Vertical fill from top (dark overlay showing missing resources)
    local resourceFill = frame:CreateTexture(nil, "OVERLAY", nil, 1)
    resourceFill:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    resourceFill:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    resourceFill:SetTexture([[Interface\Buttons\WHITE8X8]])
    resourceFill:SetVertexColor(0, 0, 0, db.resourceFillAlpha)
    resourceFill:SetHeight(0)
    resourceFill:Hide()
    frame.resourceFill = resourceFill

    -- Range indicator overlay (red tint when target is out of range)
    local rangeFrame = CreateFrame("Frame", nil, frame)
    rangeFrame:SetAllPoints(icon)
    rangeFrame:SetAlpha(0)
    rangeFrame:Hide()

    local rangeOverlay = rangeFrame:CreateTexture(nil, "OVERLAY", nil, 2)
    rangeOverlay:SetAllPoints()
    rangeOverlay:SetTexture([[Interface\Buttons\WHITE8X8]])
    rangeOverlay:SetVertexColor(177/255, 22/255, 22/255, 0.4)  -- Out-of-range red

    -- Create fade animations using Animations utility
    if self.Animations then
        self.Animations:CreateFadePair(rangeFrame, 0.15)
    end

    frame.rangeOverlay = rangeOverlay
    frame.rangeFrame = rangeFrame

    -- Queued spell highlight (for "next melee" abilities like Heroic Strike, Cleave, Maul)
    local queuedHighlight = frame:CreateTexture(nil, "OVERLAY", nil, 3)
    queuedHighlight:SetTexture([[Interface\Buttons\CheckButtonHilight]])
    queuedHighlight:SetBlendMode("ADD")
    queuedHighlight:SetAllPoints()
    queuedHighlight:Hide()
    frame.queuedHighlight = queuedHighlight

    frame.index = index
    frame.spellID = nil

    return frame
end

-------------------------------------------------------------------------------
-- Public API: Masque Registration
-------------------------------------------------------------------------------

-- Register a frame with a Masque group for icon skinning.
-- Call after CreateIconFrame when Masque is available.
function IconFrameFactory:RegisterWithMasque(frame, masqueGroup)
    if not masqueGroup then return end
    masqueGroup:AddButton(frame, {
        Icon = frame.icon,
        Cooldown = frame.cooldown,
        Normal = frame.NormalTexture,
        Count = frame.charges,
    })
end

-------------------------------------------------------------------------------
-- Public API: Fallback Styling
-------------------------------------------------------------------------------

-- Apply built-in Classic Enhanced style when Masque is not installed.
function IconFrameFactory:ApplyFallbackStyle(frame, size, aspectRatio)
    addon.IconStyling:Apply(frame, size, aspectRatio)
end

-------------------------------------------------------------------------------
-- Public API: TexCoord Application
-------------------------------------------------------------------------------

-- Apply zoom/aspect ratio texcoords to a list of icon frames.
-- Called after config changes that affect icon zoom or aspect ratio.
-- When masqueActive is true, reads Masque's applied texcoords first and applies
-- VeevHUD's zoom on top (WeakAuras-style compositing), so both the Masque skin's
-- texcoords and VeevHUD's iconZoom coexist.
function IconFrameFactory:ApplyTexCoords(icons, zoom, aspectRatio, masqueGroup)
    local zoomPerEdge = zoom / 2
    -- Check if Masque is actively skinning (installed AND not disabled for this group)
    local masqueActive = masqueGroup and not (masqueGroup.db and masqueGroup.db.Disabled)
    if masqueActive then
        for _, icon in ipairs(icons) do
            if icon.icon then
                self:ApplyZoomOverMasque(icon.icon, zoomPerEdge, aspectRatio)
            end
        end
    else
        local left, right, top, bottom = self.Utils:GetIconTexCoords(zoomPerEdge, aspectRatio)
        for _, icon in ipairs(icons) do
            if icon.icon then
                icon.icon:SetTexCoord(left, right, top, bottom)
            end
        end
    end
end

-- Apply VeevHUD's zoom on top of Masque's texcoords (WeakAuras-style).
-- Reads the icon's current texcoords (set by Masque skin), then applies
-- VeevHUD's zoom as a proportional inward crop.
function IconFrameFactory:ApplyZoomOverMasque(iconTexture, zoomPerEdge, aspectRatio)
    -- Read Masque's applied texcoords (8-value: ULx,ULy, LLx,LLy, URx,URy, LRx,LRy)
    local ULx, ULy, LLx, LLy, URx, URy, LRx, LRy = iconTexture:GetTexCoord()

    -- Convert to 4-value (left, right, top, bottom) assuming no rotation
    local baseLeft = ULx
    local baseRight = URx
    local baseTop = ULy
    local baseBottom = LLy

    -- Apply zoom as proportional inward crop on Masque's range
    local rangeH = baseRight - baseLeft
    local rangeV = baseBottom - baseTop
    local left = baseLeft + zoomPerEdge * rangeH
    local right = baseRight - zoomPerEdge * rangeH
    local top = baseTop + zoomPerEdge * rangeV
    local bottom = baseBottom - zoomPerEdge * rangeV

    -- Apply aspect ratio crop (additional vertical crop for wide icons)
    if aspectRatio > 1.0 then
        local visibleH = rangeH * (1 - 2 * zoomPerEdge)
        local visibleV = visibleH / aspectRatio
        local currentV = rangeV * (1 - 2 * zoomPerEdge)
        local extraCrop = (currentV - visibleV) / 2
        top = top + extraCrop
        bottom = bottom - extraCrop
    end

    iconTexture:SetTexCoord(left, right, top, bottom)
end
