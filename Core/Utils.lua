--[[
    VeevHUD - Utility Functions
    General utilities for formatting, UI creation, and common helpers
    
    Note: Logging, spell utilities, and aura caching are in separate files:
    - Logger.lua: Logging system (Log, LogInfo, LogError, LogDebug, etc.)
    - SpellUtils.lua: Spell cooldowns, effective spell IDs, power info
    - AuraCache.lua: Buff/debuff caching system
]]

local _, addon = ...
local L = LibStub("AceLocale-3.0"):GetLocale("VeevHUD")

-- Utils table may already exist from Logger.lua (which loads first)
addon.Utils = addon.Utils or {}
local Utils = addon.Utils
local C = addon.Constants

-------------------------------------------------------------------------------
-- Display Name Localization
-------------------------------------------------------------------------------

-- Built-in element and row names live in Constants.lua in English because they
-- double as SavedVariables values and Masque group IDs -- translating them at
-- rest would orphan saved settings. Translate at render time instead.
--
-- AceLocale is strict (enUS declares no `silent` flag), so indexing L with an
-- arbitrary string errors. Only names we know are enUS keys may be looked up;
-- anything else (a hand-edited row name in an old profile) passes through.
local BUILTIN_NAMES = {}
for _, displayName in pairs(C.LAYOUT_ELEMENTS) do
    BUILTIN_NAMES[displayName] = true
end
for _, row in ipairs(C.DEFAULTS.profile.rows) do
    BUILTIN_NAMES[row.name] = true
end

-- Rows 3 and 4 are stored as "Utility"/"Auxiliary" but display as full row names.
local ROW_CANONICAL_NAME = {
    ["Utility"] = "Utility Row",
    ["Auxiliary"] = "Auxiliary Row",
}

--- Localize a built-in HUD element display name (C.LAYOUT_ELEMENTS value).
function Utils:LocalizeUIName(name)
    if type(name) ~= "string" then return name end
    if BUILTIN_NAMES[name] then return L[name] end  -- locale-ok: guarded by BUILTIN_NAMES
    return name
end

--- Localize an ability row's display name, expanding it to the full "<X> Row"
--- form. Falls back to a numbered label when the row has no name at all.
function Utils:GetRowDisplayName(name, rowIndex)
    if type(name) ~= "string" or name == "" then
        return L["Row %d"]:format(rowIndex or 0)
    end
    local canonical = ROW_CANONICAL_NAME[name] or name
    if BUILTIN_NAMES[canonical] then return L[canonical] end  -- locale-ok: guarded by BUILTIN_NAMES
    return name
end

-------------------------------------------------------------------------------
-- General Utilities
-------------------------------------------------------------------------------

-- Convert a key to number if it looks like one (for array tables like rows)
function Utils:ToKeyType(key)
    local num = tonumber(key)
    return num or key
end


-- Insert commas into an integer string (e.g., "12345" -> "12,345")
-- Manual implementation avoids depending on BreakUpLargeNumbers WoW API
-- which may behave inconsistently across WoW editions
local function InsertCommas(n)
    local formatted = tostring(n)
    local k
    while true do
        formatted, k = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted
end

-- Format large numbers with the given number format style
-- numberFormat: "abbreviated" (4.5k), "full" (4523), "comma" (4,523)
function Utils:FormatNumber(num, numberFormat)
    if numberFormat == C.NUMBER_FORMAT.FULL then
        return tostring(math.floor(num))
    elseif numberFormat == C.NUMBER_FORMAT.COMMA then
        return InsertCommas(math.floor(num))
    else
        -- abbreviated (default / legacy behavior)
        if num >= 1000000 then
            return string.format("%.1fm", num / 1000000)
        elseif num >= 1000 then
            return string.format("%.1fk", num / 1000)
        else
            return tostring(math.floor(num))
        end
    end
end

-- Apply font with the configured outline style to a FontString.
-- @param fontString  The FontString to configure
-- @param font        Font path (from addon:GetFont())
-- @param size        Font size in points
-- @param db          Config table for the element (e.g., addon.db.profile.icons)
--                    Must contain a .textOutline field; "INHERIT" falls back to
--                    the global appearance.textOutline setting.
function Utils:ApplyFontOutline(fontString, font, size, db)
    local style = db.textOutline
    if style == C.TEXT_OUTLINE.INHERIT then
        style = addon.db.profile.appearance.textOutline
    end

    local flag = (style == C.TEXT_OUTLINE.OUTLINE or style == C.TEXT_OUTLINE.BOTH) and "OUTLINE" or ""
    fontString:SetFont(font, size, flag)

    if style == C.TEXT_OUTLINE.SHADOW or style == C.TEXT_OUTLINE.BOTH then
        fontString:SetShadowOffset(0.5, -0.5)
        fontString:SetShadowColor(0, 0, 0, 0.5)
    else
        fontString:SetShadowOffset(0, 0)
    end
end

-- Format cooldown text for icon overlays (more compact).
-- Uses round-half-up at every magnitude so each displayed value is the closest
-- representable number to the actual remaining time. This matches OmniCC, the
-- de-facto standard cooldown text addon, so VeevHUD's icon text reads the same
-- as cooldown text users see elsewhere on their UI.
function Utils:FormatCooldown(seconds)
    if seconds <= 0 then return "" end
    local minutesThreshold = addon.db.profile.icons.detailedTimeThreshold * 60
    local tenthsThreshold = addon.db.profile.icons.tenthsThreshold
    -- Subtract half a tenth so the rounded tenths value never equals the
    -- threshold itself; this avoids a redundant "2.0" tick between "2" and "1.9".
    if seconds < tenthsThreshold - 0.05 then
        local tenths = math.floor(seconds * 10 + 0.5) / 10
        if tenths <= 0 then return "" end
        return string.format("%.1f", tenths)
    end
    if seconds >= 3600 then
        return string.format("%dh", math.floor(seconds / 3600 + 0.5))
    elseif seconds >= minutesThreshold then
        return string.format("%dm", math.floor(seconds / 60 + 0.5))
    end
    local whole = math.floor(seconds + 0.5)
    if whole >= 60 then
        return string.format("%d:%02d", math.floor(whole / 60), whole % 60)
    end
    return string.format("%d", whole)
end

-------------------------------------------------------------------------------
-- Scale Utilities
-------------------------------------------------------------------------------

-- Get the UI scale compensation factor
-- VeevHUD was designed at REFERENCE_UI_SCALE (0.65). This compensates so the HUD
-- appears the same visual size regardless of the player's UI scale setting.
function Utils:GetUIScaleCompensation()
    local uiScale = UIParent:GetScale()
    return C.REFERENCE_UI_SCALE / uiScale
end

-- Get the effective HUD scale (user's Global Scale * UI scale compensation)
-- This is what gets passed to hudFrame:SetScale()
function Utils:GetEffectiveHUDScale()
    local userScale = 1.0
    if addon.db and addon.db.profile and addon.db.profile.icons then
        userScale = addon.db.profile.icons.scale
    end
    return userScale * self:GetUIScaleCompensation()
end

-------------------------------------------------------------------------------
-- Icon Dimension Utilities
-------------------------------------------------------------------------------

-- Get icon width and height based on base size and aspect ratio
-- Width stays at base size; height shrinks based on ratio (makes HUD more compact vertically)
-- Returns: width, height
function Utils:GetIconDimensions(baseSize, aspectRatio)
    aspectRatio = aspectRatio or 1.0
    local width = baseSize
    local height = math.floor(baseSize / aspectRatio + 0.5)  -- Round to nearest pixel
    return width, height
end

-- Get texture coordinates for cropping an icon to fit the aspect ratio
-- Crops top/bottom of the texture to maintain proper proportions (no stretching)
-- Returns: left, right, top, bottom texcoords
function Utils:GetIconTexCoords(baseZoom, aspectRatio)
    baseZoom = baseZoom or 0.15  -- Default 15% zoom on each edge
    aspectRatio = aspectRatio or 1.0

    -- Horizontal texcoords stay the same
    local left = baseZoom
    local right = 1 - baseZoom

    -- For square aspect (1:1), use same zoom for vertical
    if aspectRatio <= 1.0 then
        return left, right, baseZoom, 1 - baseZoom
    end

    -- For wide aspect (>1), crop more from top/bottom
    -- The visible height of texture = (1 - 2*baseZoom) / aspectRatio
    local visibleWidth = 1 - 2 * baseZoom  -- e.g., 0.70 for 15% zoom
    local visibleHeight = visibleWidth / aspectRatio  -- shrinks for wider ratios
    local verticalMargin = (1 - visibleHeight) / 2
    local top = verticalMargin
    local bottom = 1 - verticalMargin

    return left, right, top, bottom
end

-------------------------------------------------------------------------------
-- Class & Spec Utilities
-------------------------------------------------------------------------------

-- Get player's class token
function Utils:GetPlayerClass()
    local _, classToken = UnitClass("player")
    return classToken
end

-- Get class color for a class token
function Utils:GetClassColor(classToken)
    local color = C.CLASS_COLORS[classToken]
    if color then
        return color.r, color.g, color.b
    end
    return 1, 1, 1  -- White fallback
end

-------------------------------------------------------------------------------
-- Power/Resource Utilities
-------------------------------------------------------------------------------

-- Get power color for a power type
function Utils:GetPowerColor(powerType)
    local powerName
    if powerType == C.POWER_TYPE.MANA then
        powerName = "MANA"
    elseif powerType == C.POWER_TYPE.RAGE then
        powerName = "RAGE"
    elseif powerType == C.POWER_TYPE.ENERGY then
        powerName = "ENERGY"
    elseif powerType == C.POWER_TYPE.FOCUS then
        powerName = "FOCUS"
    end

    local color = C.POWER_COLORS[powerName]
    if color then
        return color.r, color.g, color.b
    end
    return 0.5, 0.5, 0.5  -- Gray fallback
end

-------------------------------------------------------------------------------
-- Frame Utilities
-------------------------------------------------------------------------------

-- Disable WoW's automatic pixel-grid snapping on a texture or frame.
-- At non-integer UI scales (e.g., 105%), the renderer rounds each edge to the
-- nearest pixel independently, causing 1px borders to vanish on one side or
-- vary in thickness. Disabling snap lets the GPU render at sub-pixel precision.
-- Works on Texture, StatusBar, Line, MaskTexture, and any object that supports
-- the SetSnapToPixelGrid / SetTexelSnappingBias APIs.
function Utils:DisablePixelSnap(object)
    if object.SetSnapToPixelGrid then
        object:SetSnapToPixelGrid(false)
    end
    if object.SetTexelSnappingBias then
        object:SetTexelSnappingBias(0)
    end
end

-- Create a texture with pixel snapping disabled.
-- Drop-in replacement for frame:CreateTexture() — all arguments forwarded.
-- Use this instead of raw CreateTexture to guarantee correct rendering at
-- non-integer scales. Used by all factories and modules.
function Utils:CreateTexture(parent, ...)
    local tex = parent:CreateTexture(...)
    self:DisablePixelSnap(tex)
    return tex
end

-- Create a status bar
function Utils:CreateStatusBar(parent, width, height, texture)
    local resolvedTexture = texture or (addon.GetBarTexture and addon:GetBarTexture()) or C.TEXTURES.STATUSBAR
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(width, height)
    bar:SetStatusBarTexture(resolvedTexture)
    self:DisablePixelSnap(bar:GetStatusBarTexture())
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar:EnableMouse(false)  -- Click-through

    -- Background
    bar.bg = self:CreateTexture(bar, nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetTexture(resolvedTexture)
    bar.bg:SetVertexColor(0.2, 0.2, 0.2, 0.8)

    return bar
end

-------------------------------------------------------------------------------
-- Visibility Utilities
-------------------------------------------------------------------------------

-- Check if HUD should be visible based on settings
-- Returns: shouldShow, alphaMultiplier
function Utils:ShouldShowHUD()
    local db = addon.db.profile.visibility

    -- Master enable/disable toggle
    if not addon.db.profile.enabled then
        return false, 0
    end

    -- Always show at full opacity when config panel is open
    local forceVisible = (addon.Options and addon.Options.isConfigOpen) or (addon.SpellsOptions and addon.SpellsOptions.isConfigOpen)
    if forceVisible then
        return true, 1.0
    end

    -- Hide completely when on flight path
    if db.hideOnFlightPath and UnitOnTaxi("player") then
        return false, 0
    end

    -- Apply out-of-combat alpha multiplier
    local alpha = 1.0
    if not UnitAffectingCombat("player") then
        alpha = db.outOfCombatAlpha
    end

    return true, alpha
end

-------------------------------------------------------------------------------
-- Bar Utilities (shared by HealthBar and ResourceBar)
-------------------------------------------------------------------------------

-- Create a dark border around a status bar using individual 1px edge textures.
-- @param bar      The status bar frame to border
-- @param skipTop  If true, omit the top edge so adjacent stacked bars share a
--                 single 1px separator (the bottom edge of the bar above).
-- Returns: border frame
function Utils:CreateBarBorder(bar, skipTop)
    local borderFrame = CreateFrame("Frame", nil, bar)
    borderFrame:SetPoint("TOPLEFT", -1, skipTop and 0 or 1)
    borderFrame:SetPoint("BOTTOMRIGHT", 1, -1)
    borderFrame:SetFrameLevel(bar:GetFrameLevel() - 1)
    borderFrame:EnableMouse(false)

    local function edge(p1, p2, dim)
        local t = self:CreateTexture(borderFrame, nil, "ARTWORK")
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        t:SetVertexColor(0, 0, 0, 1)
        t:SetPoint(p1)
        t:SetPoint(p2)
        if dim == "h" then t:SetHeight(1) else t:SetWidth(1) end
        return t
    end

    edge("TOPLEFT", "BOTTOMLEFT", "w")      -- Left
    edge("TOPRIGHT", "BOTTOMRIGHT", "w")     -- Right
    edge("BOTTOMLEFT", "BOTTOMRIGHT", "h")   -- Bottom

    local topEdge = edge("TOPLEFT", "TOPRIGHT", "h")  -- Top
    borderFrame.topEdge = topEdge

    if skipTop then
        topEdge:Hide()
    end

    --- Show or hide the top border edge.
    -- When a bar above is visible, the top edge can be hidden to avoid
    -- a double-thick separator; when there is no bar above, show it.
    function borderFrame:SetTopEdgeShown(show)
        if show then
            topEdge:Show()
            borderFrame:SetPoint("TOPLEFT", -1, 1)
        else
            topEdge:Hide()
            borderFrame:SetPoint("TOPLEFT", -1, 0)
        end
    end

    return borderFrame
end

-- Create a horizontal gradient overlay on a status bar (darker left, lighter right)
-- Returns: gradient texture
function Utils:CreateBarGradient(bar)
    local gradient = self:CreateTexture(bar, nil, "OVERLAY", nil, 1)
    gradient:SetAllPoints(bar:GetStatusBarTexture())
    gradient:SetTexture([[Interface\Buttons\WHITE8X8]])
    gradient:SetGradient("HORIZONTAL",
        CreateColor(0, 0, 0, 0.35),  -- Left (darker)
        CreateColor(1, 1, 1, 0.15)   -- Right (lighter/highlight)
    )
    return gradient
end

-- Format bar text based on format type and number format
-- format: "current", "percent", "both", "currentMax", "deficit", "none"
-- numberFormat: "abbreviated", "full", "comma" (optional, defaults to "abbreviated")
function Utils:FormatBarText(value, maxValue, percent, format, numberFormat)
    if format == C.TEXT_FORMAT.CURRENT then
        return self:FormatNumber(value, numberFormat)
    elseif format == C.TEXT_FORMAT.PERCENT then
        return string.format("%d%%", percent * 100)
    elseif format == C.TEXT_FORMAT.BOTH then
        return string.format("%s (%d%%)", self:FormatNumber(value, numberFormat), percent * 100)
    elseif format == C.TEXT_FORMAT.CURRENT_MAX then
        return string.format("%s / %s", self:FormatNumber(value, numberFormat), self:FormatNumber(maxValue, numberFormat))
    elseif format == C.TEXT_FORMAT.CURRENT_MAX_PERCENT then
        return string.format("%s / %s (%d%%)", self:FormatNumber(value, numberFormat), self:FormatNumber(maxValue, numberFormat), percent * 100)
    elseif format == C.TEXT_FORMAT.DEFICIT then
        local missing = maxValue - value
        if missing <= 0 then return "" end
        return string.format("-%s", self:FormatNumber(missing, numberFormat))
    else
        return ""
    end
end

-- Smooth bar update using lerp
-- Returns: newCurrentValue, hasReachedTarget
-------------------------------------------------------------------------------
-- Smooth Status Bar Driver (shared by HealthBar / PetHealthBar)
-------------------------------------------------------------------------------

-- Attach or detach a smoothing OnUpdate driver on a status bar, based on the
-- current animations.smoothBars setting. Must be called at frame creation AND
-- from Refresh: a driver attached only at creation freezes the bar forever if
-- smoothing is enabled mid-session (updates write targets nobody consumes),
-- and one never detached burns an OnUpdate doing nothing when disabled.
function Utils:ApplySmoothBarDriver(bar, enabled)
    if not bar then return end
    if enabled then
        if not bar._smoothDriverActive then
            bar._smoothDriverActive = true
            -- Seed from the live value so the fill doesn't jump on attach
            bar._smoothCurrent = bar:GetValue()
            bar._smoothTarget = bar._smoothCurrent
            bar:SetScript("OnUpdate", function(b, elapsed)
                local target = b._smoothTarget
                if not target then return end
                -- elapsed*18 ≙ the legacy 0.3/frame at 60fps, frame-rate independent
                b._smoothCurrent = Utils:SmoothBarValue(b._smoothCurrent or target, target, math.min(1, elapsed * 18))
                b:SetValue(b._smoothCurrent)
            end)
        end
    elseif bar._smoothDriverActive then
        bar._smoothDriverActive = nil
        bar:SetScript("OnUpdate", nil)
        -- Snap to the last requested target so the bar isn't left mid-lerp
        if bar._smoothTarget then
            bar:SetValue(bar._smoothTarget)
        end
    end
end

-- Set a bar's value, routing through the smooth driver when it is attached.
function Utils:SetBarValueSmooth(bar, value)
    if bar._smoothDriverActive then
        bar._smoothTarget = value
    else
        bar:SetValue(value)
    end
end

-- "Show usability indicators" gate (in combat, or out of a rested area),
-- memoized per frame: it's read per icon per update tick from both the state
-- engine and the renderer, and GetTime() is constant within a frame.
local usabilityMemoTime, usabilityMemoValue
function Utils:ShouldShowUsabilityIndicators()
    local now = GetTime()
    if usabilityMemoTime ~= now then
        usabilityMemoTime = now
        usabilityMemoValue = UnitAffectingCombat("player") or not IsResting()
    end
    return usabilityMemoValue
end

function Utils:SmoothBarValue(currentValue, targetValue, speed)
    speed = speed or 0.3
    local diff = targetValue - currentValue
    if math.abs(diff) < 0.001 then
        return targetValue, true
    else
        return currentValue + diff * speed, false
    end
end

-------------------------------------------------------------------------------
-- LibCustomGlow Utilities (shared glow management)
-------------------------------------------------------------------------------

-- Get LibCustomGlow library (cached)
function Utils:GetLibCustomGlow()
    if self._libCustomGlow == nil then
        self._libCustomGlow = LibStub and LibStub("LibCustomGlow-1.0", true) or false
    end
    return self._libCustomGlow or nil
end

-- Show button glow (proc-style animated glow)
function Utils:ShowButtonGlow(frame, color)
    local LCG = self:GetLibCustomGlow()
    if LCG then
        LCG.ButtonGlow_Start(frame, color)
        return true
    end
    -- Fallback
    if ActionButton_ShowOverlayGlow then
        ActionButton_ShowOverlayGlow(frame)
        return true
    end
    return false
end

-- Hide button glow
function Utils:HideButtonGlow(frame)
    local LCG = self:GetLibCustomGlow()
    if LCG then
        LCG.ButtonGlow_Stop(frame)
        return true
    end
    -- Fallback
    if ActionButton_HideOverlayGlow then
        ActionButton_HideOverlayGlow(frame)
        return true
    end
    return false
end

-- Show pixel glow (animated pixel border)
-- color: {r, g, b, a} or nil for default
-- key: unique identifier for this glow (allows multiple glows per frame)
function Utils:ShowPixelGlow(frame, color, key, particles, frequency, length, thickness, xOffset, yOffset)
    local LCG = self:GetLibCustomGlow()
    if LCG then
        LCG.PixelGlow_Start(
            frame,
            color,
            particles or 8,
            frequency or 0.1,
            length or 10,
            thickness or 1,
            xOffset or 0,
            yOffset or 0,
            true,  -- border
            key or "default"
        )
        return true
    end
    return false
end

-- Hide pixel glow
function Utils:HidePixelGlow(frame, key)
    local LCG = self:GetLibCustomGlow()
    if LCG then
        LCG.PixelGlow_Stop(frame, key or "default")
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- Friendly Target Resolution
-------------------------------------------------------------------------------

-- Returns the unit ID of the best friendly target to check for ally-applied buffs.
-- Priority: friendly target > targettarget (if enemy targeted) > player
-- Used by AuraTracker (Inspiration etc.) and TrinketTracker (target-applied procs).
function Utils:GetFriendlyBuffUnit()
    local targetExists = UnitExists("target")
    if targetExists then
        if UnitIsFriend("player", "target") then
            return "target"
        elseif UnitCanAttack("player", "target") then
            local useTargettarget = addon.db.profile.icons.auraTargettargetSupport
            if useTargettarget and UnitExists("targettarget") and UnitIsFriend("player", "targettarget") then
                return "targettarget"
            end
        end
    end
    return "player"
end

-------------------------------------------------------------------------------
-- Cooldown Text Utilities (OmniCC/ElvUI integration)
-------------------------------------------------------------------------------

-- Configure external cooldown text addons (OmniCC, ElvUI, etc.)
-- hideExternal: if true, hide external addon text; if false, allow external text
function Utils:ConfigureCooldownText(cooldown, hideExternal)
    if hideExternal then
        -- Hide external cooldown text
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
    else
        -- Allow external cooldown text
        if OmniCC and OmniCC.Cooldown and OmniCC.Cooldown.SetNoCooldownCount then
            cooldown:SetHideCountdownNumbers(false)
            OmniCC.Cooldown.SetNoCooldownCount(cooldown, false)
        elseif ElvUI and ElvUI[1] and ElvUI[1].CooldownEnabled 
               and ElvUI[1].ToggleCooldown and ElvUI[1]:CooldownEnabled() then
            cooldown:SetHideCountdownNumbers(false)
            ElvUI[1]:ToggleCooldown(cooldown, true)
        else
            cooldown:SetHideCountdownNumbers(false)
        end
    end
end

-------------------------------------------------------------------------------
-- Wrapper Icon Factory (shared by AuraTracker and BuffReminders)
-------------------------------------------------------------------------------
-- Creates a wrapper+visual+textContainer frame hierarchy for icon modules
-- that need to decouple positioning (slide animation) from visual effects
-- (scale punch, alpha animations). The wrapper receives SetPoint from the
-- slide animator, while the visual Button receives SetScale for animations.
-- Text is parented to the wrapper so it stays crisp during scale effects.
--
-- Returns a wrapper Frame with these fields:
--   wrapper.visual         — Button (CENTER-anchored, for Masque/animations)
--   wrapper.icon           — Texture on visual (ARTWORK layer)
--   wrapper.textContainer  — Frame on wrapper (for duration/stacks text)
--   visual.Icon            — Masque reference to icon texture
--   visual.NormalTexture   — Masque reference to normal texture
function Utils:CreateWrapperIcon(parent, buttonName, width, height)
    -- Wrapper frame: positioning target (slide/layout operates here)
    local wrapper = CreateFrame("Frame", nil, parent)
    wrapper:SetSize(width, height)

    -- Visual frame: Button for Masque, centered so SetScale doesn't shift position
    local visual = CreateFrame("Button", buttonName, wrapper)
    visual:SetSize(width, height)
    visual:SetPoint("CENTER")
    visual:EnableMouse(false)

    -- Icon texture on visual
    local icon = self:CreateTexture(visual, buttonName .. "Icon", "ARTWORK")
    icon:SetAllPoints()
    visual.Icon = icon
    wrapper.icon = icon
    wrapper.visual = visual

    -- Normal texture for Masque (hidden by default)
    local normalTexture = self:CreateTexture(visual, buttonName .. "NormalTexture", "OVERLAY")
    normalTexture:SetAllPoints()
    normalTexture:SetTexture([[Interface\Buttons\UI-Quickslot2]])
    normalTexture:SetAlpha(0)
    visual:SetNormalTexture(normalTexture)
    visual.NormalTexture = normalTexture

    -- Text container: child of wrapper (not visual) so unaffected by scale animations
    local textContainer = CreateFrame("Frame", nil, wrapper)
    textContainer:SetAllPoints(wrapper)
    textContainer:SetFrameLevel(wrapper:GetFrameLevel() + 5)
    wrapper.textContainer = textContainer

    return wrapper
end
