--[[
    VeevHUD - Utility Functions
]]

local ADDON_NAME, addon = ...

addon.Utils = {}
local Utils = addon.Utils
local C = addon.Constants

-------------------------------------------------------------------------------
-- Logging System (only saves to SavedVariables when debug mode is enabled)
-------------------------------------------------------------------------------

local MAX_LOG_ENTRIES = 200

-- Check if debug mode is enabled
local function IsDebugMode()
    return addon.db and addon.db.profile and addon.db.profile.debugMode
end

-- Get log storage (only creates SavedVariables entry if debug mode is on)
local function GetLog()
    if not IsDebugMode() then
        return nil
    end
    VeevHUDLog = VeevHUDLog or { entries = {}, session = 0 }
    return VeevHUDLog
end

-- Add entry to persistent log (only if debug mode is enabled)
function Utils:Log(level, ...)
    local log = GetLog()
    if not log then return end  -- Debug mode off, skip logging
    
    local message = table.concat({...}, " ")
    local timestamp = date("%H:%M:%S")
    
    local entry = {
        time = timestamp,
        level = level,
        msg = message,
        session = log.session,
    }
    
    table.insert(log.entries, entry)
    
    -- Trim old entries
    while #log.entries > MAX_LOG_ENTRIES do
        table.remove(log.entries, 1)
    end
end

function Utils:LogInfo(...)
    self:Log("INFO", ...)
end

function Utils:LogError(...)
    self:Log("ERROR", ...)
    -- Also print errors to chat (always, regardless of debug mode)
    print("|cffff0000VeevHUD Error:|r", ...)
end

function Utils:LogDebug(...)
    self:Log("DEBUG", ...)
end

function Utils:StartNewSession()
    local log = GetLog()
    if not log then return end  -- Debug mode off, skip
    
    log.session = (log.session or 0) + 1
    self:LogInfo("=== Session", log.session, "started ===")
    self:LogInfo("Player:", UnitName("player"), "Class:", select(2, UnitClass("player")))
    self:LogInfo("Game version:", GetBuildInfo())
end

function Utils:ClearLog()
    VeevHUDLog = nil  -- Remove entirely from SavedVariables
    self:Print("Log cleared.")
end

function Utils:PrintRecentLog(count)
    if not VeevHUDLog or not VeevHUDLog.entries then
        self:Print("No log entries. Enable debug mode (/vh debug) to start logging.")
        return
    end
    
    local log = VeevHUDLog
    count = count or 20
    
    print("|cff00ccffVeevHUD Log|r (last " .. count .. " entries):")
    
    local start = math.max(1, #log.entries - count + 1)
    for i = start, #log.entries do
        local e = log.entries[i]
        local color = "|cffffffff"
        if e.level == "ERROR" then color = "|cffff0000"
        elseif e.level == "DEBUG" then color = "|cff888888"
        elseif e.level == "INFO" then color = "|cff00ff00" end
        
        print(string.format("  %s[%s] %s%s|r", color, e.time, e.level, ": " .. e.msg))
    end
end

-------------------------------------------------------------------------------
-- General Utilities
-------------------------------------------------------------------------------

-- Safe print with addon prefix
function Utils:Print(...)
    print("|cff00ccffVeevHUD:|r", ...)
end

-- Debug print (only when debug mode is on)
function Utils:Debug(...)
    self:LogDebug(...)
    if addon.db and addon.db.profile.debugMode then
        print("|cff888888VeevHUD [Debug]:|r", ...)
    end
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

-- Format time (seconds -> mm:ss or just seconds)
function Utils:FormatTime(seconds)
    if seconds >= 3600 then
        return string.format("%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    elseif seconds >= 60 then
        return string.format("%d:%02d", seconds / 60, seconds % 60)
    elseif seconds >= 10 then
        return string.format("%d", seconds)
    elseif seconds >= 1 then
        return string.format("%.1f", seconds)
    else
        return string.format("%.1f", seconds)
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

-- Get class color as hex string
function Utils:GetClassColorHex(classToken)
    local r, g, b = self:GetClassColor(classToken)
    return string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
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
-- Spell Utilities
-------------------------------------------------------------------------------

-- Get spell cooldown info
-- Returns: remaining, duration, enabled, startTime (actual API start time for SetCooldown)
function Utils:GetSpellCooldown(spellID)
    local start, duration, enabled
    
    -- Try by spell ID first
    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(spellID)
        if info then
            start = info.startTime
            duration = info.duration
            enabled = info.isEnabled
        end
    else
        start, duration, enabled = GetSpellCooldown(spellID)
    end

    -- If no cooldown found by ID, try by spell name (some abilities need this)
    if (not start or start == 0) and GetSpellInfo then
        local spellName = GetSpellInfo(spellID)
        if spellName then
            local nameStart, nameDuration, nameEnabled = GetSpellCooldown(spellName)
            if nameStart and nameStart > 0 then
                start, duration, enabled = nameStart, nameDuration, nameEnabled
            end
        end
    end

    if start and duration and start > 0 and duration > 0 then
        local remaining = (start + duration) - GetTime()
        -- Return remaining, duration, enabled, and the actual start time for SetCooldown
        return remaining > 0 and remaining or 0, duration, true, start
    end

    return 0, 0, enabled ~= 0, 0
end

-- Get spell info
function Utils:GetSpellInfo(spellID)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info then
            return info.name, nil, info.iconID, info.castTime, info.minRange, info.maxRange, info.spellID
        end
    elseif GetSpellInfo then
        return GetSpellInfo(spellID)
    end
    return nil
end

-- Get spell texture/icon
function Utils:GetSpellTexture(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID)
    elseif GetSpellTexture then
        return GetSpellTexture(spellID)
    end
    return nil
end

-------------------------------------------------------------------------------
-- Effective Spell ID Resolution (with caching)
-- Determines the actual spell rank to use for costs, based on action bar placement
-------------------------------------------------------------------------------

-- Cache for effective spell IDs
Utils.effectiveSpellCache = {}

-- Find if any rank of a spell is on the player's action bars
-- Returns the spell ID found on action bar, or nil if not found
function Utils:FindSpellOnActionBar(spellID)
    local LibSpellDB = LibStub and LibStub("LibSpellDB-1.0", true)
    if not LibSpellDB then return nil end
    
    local rankSet = LibSpellDB:GetAllRankIDs(spellID)
    
    -- Scan all action bar slots (1-120 covers all bars)
    for slot = 1, 120 do
        local actionType, id, subType = GetActionInfo(slot)
        if actionType == "spell" and id then
            if rankSet[id] then
                return id
            end
        end
    end
    
    return nil
end

-- Ensure the cache invalidation event frame is set up (lazy initialization)
function Utils:EnsureCacheInitialized()
    if self.effectiveSpellCacheFrame then return end
    
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
    frame:RegisterEvent("PLAYER_LEVEL_UP")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("SPELLS_CHANGED")
    frame:RegisterEvent("CHARACTER_POINTS_CHANGED")  -- Talent changes (TBC)
    
    frame:SetScript("OnEvent", function(eventFrame, event, ...)
        Utils:InvalidateEffectiveSpellCache()
    end)
    
    self.effectiveSpellCacheFrame = frame
end

-- Invalidate the effective spell cache
-- Called when action bars or spells change
function Utils:InvalidateEffectiveSpellCache()
    wipe(self.effectiveSpellCache)
end

-- Get the effective spell ID for a spell, with caching
-- Priority: 1) Spell rank on action bar, 2) Highest known rank
function Utils:GetEffectiveSpellID(spellID)
    -- Lazy initialize the cache event frame
    self:EnsureCacheInitialized()
    
    local LibSpellDB = LibStub and LibStub("LibSpellDB-1.0", true)
    if not LibSpellDB then return spellID end
    
    local canonicalID = LibSpellDB:GetCanonicalSpellID(spellID) or spellID
    
    -- Check cache first
    local cached = self.effectiveSpellCache[canonicalID]
    if cached then
        return cached
    end
    
    -- Not cached, compute it
    local result
    
    -- First, check if any rank is on the action bar
    local actionBarSpellID = self:FindSpellOnActionBar(spellID)
    if actionBarSpellID then
        result = actionBarSpellID
    else
        -- Fallback to highest known rank from LibSpellDB
        result = LibSpellDB:GetHighestKnownRank(spellID)
    end
    
    -- Cache and return
    self.effectiveSpellCache[canonicalID] = result
    return result
end

-------------------------------------------------------------------------------
-- Buff/Debuff Caching
-- Scans all buffs/debuffs once per unit, cached until UNIT_AURA fires
-------------------------------------------------------------------------------

-- Cache structures: buffCache[unit][spellID] = auraData, debuffCache[unit][spellID] = auraData
-- Also cache by name for fallback lookups: buffCacheByName[unit][name] = auraData
Utils.buffCache = {}
Utils.debuffCache = {}
Utils.buffCacheByName = {}
Utils.debuffCacheByName = {}
Utils.auraCacheValid = {}  -- auraCacheValid[unit] = true when cache is populated

-- Populate buff cache for a unit (scans once, stores all buffs)
function Utils:PopulateBuffCache(unit)
    if self.auraCacheValid[unit] then return end
    
    self.buffCache[unit] = {}
    self.buffCacheByName[unit] = {}
    
    for i = 1, 40 do
        local name, icon, count, debuffType, duration, expirationTime, source, 
              isStealable, nameplateShowPersonal, auraSpellID = UnitBuff(unit, i)
        
        if not name then break end
        
        local auraData = {
            name = name,
            icon = icon,
            count = count or 0,
            debuffType = debuffType,
            duration = duration or 0,
            expirationTime = expirationTime or 0,
            source = source,
            isStealable = isStealable,
            nameplateShowPersonal = nameplateShowPersonal,
            spellID = auraSpellID,
        }
        
        if auraSpellID then
            self.buffCache[unit][auraSpellID] = auraData
        end
        if name then
            self.buffCacheByName[unit][name] = auraData
        end
    end
    
    self.auraCacheValid[unit] = true
end

-- Populate debuff cache for a unit
function Utils:PopulateDebuffCache(unit)
    local cacheKey = unit .. "_debuff"
    if self.auraCacheValid[cacheKey] then return end
    
    self.debuffCache[unit] = {}
    self.debuffCacheByName[unit] = {}
    
    for i = 1, 40 do
        local name, icon, count, debuffType, duration, expirationTime, source, 
              isStealable, nameplateShowPersonal, auraSpellID = UnitDebuff(unit, i)
        
        if not name then break end
        
        local auraData = {
            name = name,
            icon = icon,
            count = count or 0,
            debuffType = debuffType,
            duration = duration or 0,
            expirationTime = expirationTime or 0,
            source = source,
            isStealable = isStealable,
            nameplateShowPersonal = nameplateShowPersonal,
            spellID = auraSpellID,
        }
        
        if auraSpellID then
            self.debuffCache[unit][auraSpellID] = auraData
        end
        if name then
            self.debuffCacheByName[unit][name] = auraData
        end
    end
    
    self.auraCacheValid[cacheKey] = true
end

-- Invalidate aura cache for a unit
function Utils:InvalidateAuraCache(unit)
    self.auraCacheValid[unit] = nil
    self.auraCacheValid[unit .. "_debuff"] = nil
    self.buffCache[unit] = nil
    self.debuffCache[unit] = nil
    self.buffCacheByName[unit] = nil
    self.debuffCacheByName[unit] = nil
end

-- Invalidate all aura caches
function Utils:InvalidateAllAuraCaches()
    wipe(self.buffCache)
    wipe(self.debuffCache)
    wipe(self.buffCacheByName)
    wipe(self.debuffCacheByName)
    wipe(self.auraCacheValid)
end

-- Get cached buff by spell ID (populates cache if needed)
-- Returns: auraData table or nil
function Utils:GetCachedBuff(unit, spellID, spellName)
    self:EnsureAuraCacheInitialized()
    self:PopulateBuffCache(unit)
    
    local cache = self.buffCache[unit]
    if cache and cache[spellID] then
        return cache[spellID]
    end
    
    -- Fallback to name lookup
    if spellName then
        local nameCache = self.buffCacheByName[unit]
        if nameCache and nameCache[spellName] then
            return nameCache[spellName]
        end
    end
    
    return nil
end

-- Get cached debuff by spell ID (populates cache if needed)
-- Returns: auraData table or nil
function Utils:GetCachedDebuff(unit, spellID, spellName)
    self:EnsureAuraCacheInitialized()
    self:PopulateDebuffCache(unit)
    
    local cache = self.debuffCache[unit]
    if cache and cache[spellID] then
        return cache[spellID]
    end
    
    -- Fallback to name lookup
    if spellName then
        local nameCache = self.debuffCacheByName[unit]
        if nameCache and nameCache[spellName] then
            return nameCache[spellName]
        end
    end
    
    return nil
end

-- Ensure aura cache event frame is set up (lazy initialization)
function Utils:EnsureAuraCacheInitialized()
    if self.auraCacheFrame then return end
    
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("UNIT_AURA")
    frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    
    frame:SetScript("OnEvent", function(eventFrame, event, unit, ...)
        if event == "UNIT_AURA" then
            Utils:InvalidateAuraCache(unit)
        elseif event == "PLAYER_TARGET_CHANGED" then
            Utils:InvalidateAuraCache("target")
            Utils:InvalidateAuraCache("targettarget")
        elseif event == "PLAYER_ENTERING_WORLD" then
            Utils:InvalidateAllAuraCaches()
        end
    end)
    
    self.auraCacheFrame = frame
end

-------------------------------------------------------------------------------
-- Spell Power Info
-------------------------------------------------------------------------------

-- Get spell power cost and current power
-- Returns: cost, currentPower, maxPower, powerType, powerColor
function Utils:GetSpellPowerInfo(spellID)
    local cost = 0
    local powerType = nil
    
    -- Get effective spell ID: action bar rank first, then highest known rank
    local effectiveSpellID = self:GetEffectiveSpellID(spellID)
    
    -- Try to get power cost from spell info
    if GetSpellPowerCost then
        local costTable = GetSpellPowerCost(effectiveSpellID)
        if costTable and costTable[1] then
            cost = costTable[1].cost or 0
            powerType = costTable[1].type
        end
    end
    
    -- If no cost found, spell is free
    if cost == 0 then
        return 0, 0, 0, nil, nil
    end
    
    -- Get current and max power for that power type
    local currentPower = UnitPower("player", powerType) or 0
    local maxPower = UnitPowerMax("player", powerType) or 1
    
    -- Get power color
    local powerColor = {1, 1, 1}  -- Default white
    local powerInfo = PowerBarColor[powerType]
    if powerInfo then
        powerColor = {powerInfo.r or 1, powerInfo.g or 1, powerInfo.b or 1}
    else
        -- Fallback colors for common power types
        if powerType == 0 then      -- Mana
            powerColor = {0, 0.5, 1}
        elseif powerType == 1 then  -- Rage
            powerColor = {1, 0, 0}
        elseif powerType == 2 then  -- Focus
            powerColor = {1, 0.5, 0.25}
        elseif powerType == 3 then  -- Energy
            powerColor = {1, 1, 0}
        elseif powerType == 6 then  -- Runic Power
            powerColor = {0, 0.82, 1}
        end
    end
    
    return cost, currentPower, maxPower, powerType, powerColor
end

-------------------------------------------------------------------------------
-- Buff/Debuff Utilities (using cache)
-------------------------------------------------------------------------------

-- Find a buff on unit by spell ID (uses cache)
function Utils:FindBuffBySpellID(unit, spellID)
    self:EnsureAuraCacheInitialized()
    return self:GetCachedBuff(unit, spellID)
end

-- Find a debuff on unit by spell ID (uses cache)
function Utils:FindDebuffBySpellID(unit, spellID)
    self:EnsureAuraCacheInitialized()
    return self:GetCachedDebuff(unit, spellID)
end

-------------------------------------------------------------------------------
-- Frame Utilities
-------------------------------------------------------------------------------

-- Create a simple backdrop
function Utils:CreateBackdrop(frame, bgColor, borderColor)
    bgColor = bgColor or {0, 0, 0, 0.7}
    borderColor = borderColor or {0.3, 0.3, 0.3, 1}

    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = C.TEXTURES.BACKDROP,
            edgeFile = C.TEXTURES.BORDER,
            tile = true, tileSize = 16, edgeSize = 16,
            insets = {left = 4, right = 4, top = 4, bottom = 4}
        })
        frame:SetBackdropColor(unpack(bgColor))
        frame:SetBackdropBorderColor(unpack(borderColor))
    end
end

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
-- Supported formats: "current", "percent", "both", "deficit", "full"
function Utils:FormatBarText(value, maxValue, percent, format)
    if format == "current" then
        return self:FormatNumber(value)
    elseif format == "percent" then
        return string.format("%d%%", percent * 100)
    elseif format == "both" then
        return string.format("%s (%d%%)", self:FormatNumber(value), percent * 100)
    elseif format == "deficit" then
        local deficit = maxValue - value
        if deficit > 0 then
            return "-" .. self:FormatNumber(deficit)
        else
            return ""
        end
    elseif format == "full" then
        return string.format("%s / %s", self:FormatNumber(value), self:FormatNumber(maxValue))
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
