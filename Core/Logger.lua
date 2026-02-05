--[[
    VeevHUD - Logging System
    Persistent logging to SavedVariables when debug mode is enabled
    
    AI-Assisted Debugging Workflow:
    ─────────────────────────────────────────────────────────────────────────────
    Debug logs are saved to VeevHUDLog in SavedVariables and can be analyzed
    by AI models (Claude, etc.) in future prompt sessions.
    
    Steps:
    1. Enable debug mode: /vh debug
    2. Play and reproduce the issue
    3. Reload UI: /reload (flushes logs to disk)
    4. Share the SavedVariables file with the AI:
       Path: WTF/Account/<account>/SavedVariables/VeevHUD.lua
       Look for the VeevHUDLog table - it contains timestamped log entries.
    5. Or use /vh log [n] to view recent entries in chat
    
    The AI can read these logs to diagnose timing issues, event sequences,
    and other runtime behavior that's hard to reproduce in a static codebase.
    ─────────────────────────────────────────────────────────────────────────────
]]

local ADDON_NAME, addon = ...

-- Create Utils table if it doesn't exist (Logger loads early)
addon.Utils = addon.Utils or {}
local Utils = addon.Utils

-------------------------------------------------------------------------------
-- Logging System (only saves to SavedVariables when debug mode is enabled)
-------------------------------------------------------------------------------

local MAX_LOG_ENTRIES = 500

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

-------------------------------------------------------------------------------
-- User-facing Output
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
