--[[
    VeevHUD - Utility Functions
]]

local ADDON_NAME, addon = ...

addon.Utils = {}
local Utils = addon.Utils
local C = addon.Constants

-------------------------------------------------------------------------------
-- Logging System
-------------------------------------------------------------------------------

local MAX_LOG_ENTRIES = 200

-- Initialize log storage
local function GetLog()
    VeevHUDLog = VeevHUDLog or { entries = {}, session = 0 }
    return VeevHUDLog
end

-- Add entry to persistent log
function Utils:Log(level, ...)
    local log = GetLog()
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
    -- Also print errors to chat
    print("|cffff0000VeevHUD Error:|r", ...)
end

function Utils:LogDebug(...)
    self:Log("DEBUG", ...)
end

function Utils:StartNewSession()
    local log = GetLog()
    log.session = (log.session or 0) + 1
    self:LogInfo("=== Session", log.session, "started ===")
    self:LogInfo("Player:", UnitName("player"), "Class:", select(2, UnitClass("player")))
    self:LogInfo("Game version:", GetBuildInfo())
end

function Utils:ClearLog()
    VeevHUDLog = { entries = {}, session = 0 }
    self:Print("Log cleared.")
end

function Utils:PrintRecentLog(count)
    local log = GetLog()
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

-- Check if spell is usable
function Utils:IsSpellUsable(spellID)
    if C_Spell and C_Spell.IsSpellUsable then
        return C_Spell.IsSpellUsable(spellID)
    elseif IsUsableSpell then
        local usable, noMana = IsUsableSpell(spellID)
        return usable or noMana
    end
    return false
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

-- Get spell power cost and current power
-- Returns: cost, currentPower, maxPower, powerType, powerColor
function Utils:GetSpellPowerInfo(spellID)
    local cost = 0
    local powerType = nil
    
    -- Try to get power cost from spell info
    if GetSpellPowerCost then
        local costTable = GetSpellPowerCost(spellID)
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
-- Buff/Debuff Utilities
-------------------------------------------------------------------------------

-- Find a buff on unit by spell ID
function Utils:FindBuffBySpellID(unit, spellID)
    for i = 1, 40 do
        local name, icon, count, debuffType, duration, expirationTime, source, isStealable, nameplateShowPersonal, auraSpellID = UnitBuff(unit, i)
        if not name then break end
        if auraSpellID == spellID then
            return {
                name = name,
                icon = icon,
                count = count,
                duration = duration,
                expirationTime = expirationTime,
                source = source,
                spellID = auraSpellID,
            }
        end
    end
    return nil
end

-- Find a debuff on unit by spell ID
function Utils:FindDebuffBySpellID(unit, spellID)
    for i = 1, 40 do
        local name, icon, count, debuffType, duration, expirationTime, source, isStealable, nameplateShowPersonal, auraSpellID = UnitDebuff(unit, i)
        if not name then break end
        if auraSpellID == spellID then
            return {
                name = name,
                icon = icon,
                count = count,
                debuffType = debuffType,
                duration = duration,
                expirationTime = expirationTime,
                source = source,
                spellID = auraSpellID,
            }
        end
    end
    return nil
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

-- Make a frame draggable
function Utils:MakeDraggable(frame, saveCallback)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")

    frame:SetScript("OnDragStart", function(self)
        if not addon.db.profile.locked then
            self:StartMoving()
        end
    end)

    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if saveCallback then
            saveCallback(self)
        end
    end)
end

-- Create a status bar
function Utils:CreateStatusBar(parent, width, height, texture)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(width, height)
    bar:SetStatusBarTexture(texture or C.TEXTURES.STATUSBAR)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)

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
function Utils:ShouldShowHUD()
    local db = addon.db.profile.visibility

    -- Hide completely when on flight path
    if db.hideOnFlightPath and UnitOnTaxi("player") then
        return false, 0
    end

    -- Always show at full alpha otherwise
    return true, 1.0
end
