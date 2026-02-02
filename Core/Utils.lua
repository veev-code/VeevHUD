--[[
    VeevHUD - Utility Functions
    General utilities for formatting, UI creation, and common helpers
    
    Note: Logging, spell utilities, and aura caching are in separate files:
    - Logger.lua: Logging system (Log, LogInfo, LogError, LogDebug, etc.)
    - SpellUtils.lua: Spell cooldowns, effective spell IDs, power info
    - AuraCache.lua: Buff/debuff caching system
]]

local ADDON_NAME, addon = ...

-- Utils table may already exist from Logger.lua (which loads first)
addon.Utils = addon.Utils or {}
local Utils = addon.Utils
local C = addon.Constants

-------------------------------------------------------------------------------
-- General Utilities
-------------------------------------------------------------------------------

-- Convert a key to number if it looks like one (for array tables like rows)
function Utils:ToKeyType(key)
    local num = tonumber(key)
    return num or key
end


-- Format large numbers (1000 -> 1k, 1000000 -> 1m)
function Utils:FormatNumber(num)
    if num >= 1000000 then
        return string.format("%.1fm", num / 1000000)
    elseif num >= 1000 then
        return string.format("%.1fk", num / 1000)
    else
        return tostring(math.floor(num))
    end
end

-- Format cooldown text for icon overlays (more compact)
-- No decimals until < 1s remains
-- Uses floor so "1" displays for exactly 1 second before switching to decimals
function Utils:FormatCooldown(seconds)
    if seconds >= 3600 then
        return string.format("%dh", math.floor(seconds / 3600))
    elseif seconds >= 60 then
        return string.format("%dm", math.floor(seconds / 60))
    elseif seconds >= 1 then
        return string.format("%d", math.floor(seconds))
    elseif seconds > 0 then
        return string.format("%.1f", seconds)
    else
        return ""
    end
end

-------------------------------------------------------------------------------
-- Icon Dimension Utilities
-------------------------------------------------------------------------------

-- Get icon width and height based on base size and global aspect ratio setting
-- Width stays at base size; height shrinks based on ratio (makes HUD more compact vertically)
-- Returns: width, height
function Utils:GetIconDimensions(baseSize)
    local aspectRatio = 1.0
    if addon.db and addon.db.profile and addon.db.profile.icons then
        aspectRatio = addon.db.profile.icons.iconAspectRatio or 1.0
    end
    local width = baseSize
    local height = math.floor(baseSize / aspectRatio + 0.5)  -- Round to nearest pixel
    return width, height
end

-- Get texture coordinates for cropping an icon to fit the aspect ratio
-- Crops top/bottom of the texture to maintain proper proportions (no stretching)
-- Returns: left, right, top, bottom texcoords
function Utils:GetIconTexCoords(baseZoom)
    baseZoom = baseZoom or 0.15  -- Default 15% zoom on each edge
    
    local aspectRatio = 1.0
    if addon.db and addon.db.profile and addon.db.profile.icons then
        aspectRatio = addon.db.profile.icons.iconAspectRatio or 1.0
    end
    
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

-- Create a status bar
function Utils:CreateStatusBar(parent, width, height, texture)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(width, height)
    bar:SetStatusBarTexture(texture or C.TEXTURES.STATUSBAR)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar:EnableMouse(false)  -- Click-through

    -- Background
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetTexture(texture or C.TEXTURES.STATUSBAR)
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

    -- Always show at full opacity when config panel is open
    local options = addon.Options
    if options and options.isConfigOpen then
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

-- Create a dark border with shadow around a status bar
-- Returns: border frame (shadow is parented to border)
function Utils:CreateBarBorder(bar)
    local border = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    border:SetBackdropBorderColor(0, 0, 0, 1)
    border:SetFrameLevel(bar:GetFrameLevel() - 1)
    border:EnableMouse(false)

    -- Outer shadow for depth
    local shadow = CreateFrame("Frame", nil, border, "BackdropTemplate")
    shadow:SetPoint("TOPLEFT", -1, 1)
    shadow:SetPoint("BOTTOMRIGHT", 1, -1)
    shadow:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    shadow:SetBackdropBorderColor(0, 0, 0, 0.5)
    shadow:EnableMouse(false)
    shadow:SetFrameLevel(border:GetFrameLevel() - 1)

    return border
end

-- Create a horizontal gradient overlay on a status bar (darker left, lighter right)
-- Returns: gradient texture
function Utils:CreateBarGradient(bar)
    local gradient = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    gradient:SetAllPoints(bar:GetStatusBarTexture())
    gradient:SetTexture([[Interface\Buttons\WHITE8X8]])
    gradient:SetGradient("HORIZONTAL", 
        CreateColor(0, 0, 0, 0.35),  -- Left (darker)
        CreateColor(1, 1, 1, 0.15)   -- Right (lighter/highlight)
    )
    return gradient
end

-- Format bar text based on format type
-- Supported formats: "current", "percent", "both"
function Utils:FormatBarText(value, maxValue, percent, format)
    if format == "current" then
        return self:FormatNumber(value)
    elseif format == "percent" then
        return string.format("%d%%", percent * 100)
    elseif format == "both" then
        return string.format("%s (%d%%)", self:FormatNumber(value), percent * 100)
    else
        return ""
    end
end

-- Smooth bar update using lerp
-- Returns: newCurrentValue, hasReachedTarget
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
