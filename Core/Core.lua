--[[
    VeevHUD - Core Addon Framework
]]

local ADDON_NAME, addon = ...

-- Make addon accessible globally for debugging
_G.VeevHUD = addon

-- Core addon object
addon.name = ADDON_NAME
addon.version = addon.Constants.VERSION

-- Module registry
addon.modules = {}

-- Libraries
addon.LibSpellDB = nil  -- Set on load

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        addon:OnAddonLoaded()
    elseif event == "PLAYER_LOGIN" then
        addon:OnPlayerLogin()
    elseif event == "PLAYER_LOGOUT" then
        addon:OnPlayerLogout()
    end
end)

function addon:OnAddonLoaded()
    -- Initialize saved variables with defaults
    VeevHUDDB = VeevHUDDB or {}
    self:InitializeDB()

    -- Get LibSpellDB reference
    if LibStub then
        self.LibSpellDB = LibStub:GetLibrary("LibSpellDB-1.0", true)
        if not self.LibSpellDB then
            self.Utils:Print("|cffff0000Warning:|r LibSpellDB not found. Some features may not work.")
        end
    end
end

function addon:OnPlayerLogin()
    -- Start logging session
    self.Utils:StartNewSession()
    self.Utils:LogInfo("VeevHUD v" .. self.version .. " initializing...")

    -- Initialize player info
    self.playerClass = self.Utils:GetPlayerClass()
    self.playerGUID = UnitGUID("player")
    self.Utils:LogInfo("Player class:", self.playerClass)

    -- Initialize spec detection via LibSpellDB
    if self.LibSpellDB then
        local success, err = pcall(function()
            local spec, points = self.LibSpellDB:DetectPlayerSpec()
            self.playerSpec = spec
            self.Utils:LogInfo("Player spec:", spec, "(" .. points[1] .. "/" .. points[2] .. "/" .. points[3] .. ")")
        end)
        if not success then
            self:ShowFatalError("Spec Detection Failed", err)
            return
        end
    else
        self:ShowFatalError("LibSpellDB Missing", "LibSpellDB is required but not loaded.")
        return
    end

    -- Initialize modules
    self:InitializeModules()

    -- Create main HUD frame
    self:CreateHUDFrame()

    -- Register slash commands
    self:RegisterSlashCommands()

    -- Log LibSpellDB status
    if self.LibSpellDB then
        self.Utils:LogInfo("LibSpellDB loaded, spell count:", self.LibSpellDB:GetSpellCount())
        self.Utils:LogInfo("Class spells:", self.LibSpellDB:GetClassSpellCount(self.playerClass))
    else
        self.Utils:LogError("LibSpellDB not found!")
    end

    self.Utils:LogInfo("Initialization complete.")

    -- Print load message
    self.Utils:Print("v" .. self.version .. " loaded. Type |cff00ff00/vh|r for options.")
end

function addon:OnPlayerLogout()
    -- Save any pending data
end

-------------------------------------------------------------------------------
-- Fatal Error Handling
-------------------------------------------------------------------------------

function addon:ShowFatalError(title, message)
    -- Log the error
    self.Utils:LogError("FATAL:", title, "-", message)
    
    -- Print to chat
    self.Utils:Print("|cffff0000FATAL ERROR:|r " .. title)
    print("|cffff0000VeevHUD:|r " .. tostring(message))
    
    -- Show popup dialog
    StaticPopupDialogs["VEEVHUD_FATAL_ERROR"] = {
        text = "|cffff0000VeevHUD Error|r\n\n" .. title .. "\n\n" .. tostring(message) .. "\n\nThe addon has been disabled.",
        button1 = "OK",
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopup_Show("VEEVHUD_FATAL_ERROR")
    
    -- Disable the addon
    self.fatalError = true
    if self.hudFrame then
        self.hudFrame:Hide()
    end
end

-------------------------------------------------------------------------------
-- Database Management
-- 
-- Philosophy: Only save user customizations, not entire profile.
-- This way users always get the latest addon defaults unless they
-- explicitly changed a specific setting.
-------------------------------------------------------------------------------

function addon:InitializeDB()
    -- Migration: if old format exists (profile), convert to new format (overrides)
    if VeevHUDDB.profile and not VeevHUDDB.overrides then
        -- Old format detected - start fresh with new defaults
        -- User hasn't explicitly customized in the new system yet
        self.Utils:LogInfo("Migrating to new settings format - applying latest defaults")
        VeevHUDDB.profile = nil
        VeevHUDDB.overrides = {}
    end
    
    -- VeevHUDDB.overrides contains ONLY user-customized settings
    -- Everything else comes from Constants.DEFAULTS
    if not VeevHUDDB.overrides then
        VeevHUDDB.overrides = {}
    end
    
    -- Build the live profile by layering overrides on top of defaults
    self:RebuildLiveProfile()
end

-- Rebuild the live profile from defaults + overrides
function addon:RebuildLiveProfile()
    local defaults = self.Constants.DEFAULTS.profile
    local overrides = VeevHUDDB.overrides or {}
    
    -- Create a proxy table that reads from overrides first, then defaults
    self.db = {
        profile = self:MergeWithDefaults(overrides, defaults)
    }
end

-- Deep merge: overrides take precedence over defaults
function addon:MergeWithDefaults(overrides, defaults)
    -- Just deep copy defaults (DeepCopy handles arrays correctly now)
    local result = self:DeepCopy(defaults)
    
    -- Then apply overrides on top
    self:ApplyOverrides(result, overrides)
    
    return result
end

-- Apply overrides recursively
function addon:ApplyOverrides(target, overrides)
    for k, v in pairs(overrides) do
        if type(v) == "table" and type(target[k]) == "table" then
            self:ApplyOverrides(target[k], v)
        else
            target[k] = v
        end
    end
end

function addon:DeepCopy(orig)
    local copy
    if type(orig) == "table" then
        copy = {}
        -- Use ipairs first for arrays to preserve order
        for i, v in ipairs(orig) do
            copy[i] = self:DeepCopy(v)
        end
        -- Then copy any non-numeric keys
        for k, v in pairs(orig) do
            if type(k) ~= "number" then
                copy[k] = self:DeepCopy(v)
            end
        end
    else
        copy = orig
    end
    return copy
end

-- Save a user override (only saves the specific changed value)
function addon:SetOverride(path, value)
    local overrides = VeevHUDDB.overrides
    local keys = {strsplit(".", path)}
    
    -- Navigate to the parent table, creating as needed
    for i = 1, #keys - 1 do
        local key = keys[i]
        if not overrides[key] then
            overrides[key] = {}
        end
        overrides = overrides[key]
    end
    
    -- Set the value
    overrides[keys[#keys]] = value
    
    -- Rebuild live profile
    self:RebuildLiveProfile()
end

-- Clear a specific override (revert to default)
function addon:ClearOverride(path)
    local overrides = VeevHUDDB.overrides
    local keys = {strsplit(".", path)}
    
    -- Navigate to the parent
    for i = 1, #keys - 1 do
        local key = keys[i]
        if not overrides[key] then
            return -- Path doesn't exist, nothing to clear
        end
        overrides = overrides[key]
    end
    
    -- Clear the value
    overrides[keys[#keys]] = nil
    
    -- Rebuild live profile
    self:RebuildLiveProfile()
end

function addon:ResetProfile()
    -- Clear all overrides - user gets fresh defaults
    VeevHUDDB.overrides = {}
    self:RebuildLiveProfile()

    -- Refresh all modules
    for name, module in pairs(self.modules) do
        if module.Refresh then
            module:Refresh()
        end
    end

    self.Utils:Print("Profile reset to defaults. Type /reload to apply all changes.")
end

-------------------------------------------------------------------------------
-- Module System
-------------------------------------------------------------------------------

function addon:RegisterModule(name, module)
    self.modules[name] = module
    module.addon = self
    module.name = name
end

function addon:GetModule(name)
    return self.modules[name]
end

function addon:InitializeModules()
    for name, module in pairs(self.modules) do
        if module.Initialize then
            local success, err = pcall(module.Initialize, module)
            if not success then
                self.Utils:Print("|cffff0000Error initializing module " .. name .. ":|r " .. tostring(err))
            end
        end
    end
end

function addon:EnableModules()
    for name, module in pairs(self.modules) do
        if module.Enable then
            module:Enable()
        end
    end
end

function addon:DisableModules()
    for name, module in pairs(self.modules) do
        if module.Disable then
            module:Disable()
        end
    end
end

-------------------------------------------------------------------------------
-- HUD Frame
-------------------------------------------------------------------------------

function addon:CreateHUDFrame()
    -- Main container frame
    local hud = CreateFrame("Frame", "VeevHUDFrame", UIParent)
    hud:SetSize(300, 200)
    hud:SetPoint(
        self.db.profile.anchor.point,
        UIParent,
        self.db.profile.anchor.relativePoint,
        self.db.profile.anchor.x,
        self.db.profile.anchor.y
    )
    hud:SetFrameStrata("MEDIUM")
    hud:SetFrameLevel(10)

    -- Make draggable when unlocked
    self.Utils:MakeDraggable(hud, function(frame)
        local point, _, relativePoint, x, y = frame:GetPoint()
        self.db.profile.anchor.point = point
        self.db.profile.anchor.relativePoint = relativePoint
        self.db.profile.anchor.x = x
        self.db.profile.anchor.y = y
    end)

    self.hudFrame = hud

    -- Create module frames
    self:CreateModuleFrames()

    -- Start visibility updates
    self:StartVisibilityUpdates()
end

function addon:CreateModuleFrames()
    -- Each module will create its own frames attached to self.hudFrame
    for name, module in pairs(self.modules) do
        if module.CreateFrames then
            module:CreateFrames(self.hudFrame)
        end
    end
end

function addon:StartVisibilityUpdates()
    local ticker = C_Timer.NewTicker(0.1, function()
        self:UpdateVisibility()
    end)
    self.visibilityTicker = ticker
end

function addon:UpdateVisibility()
    if not self.hudFrame then return end

    local shouldShow, alpha = self.Utils:ShouldShowHUD()

    if shouldShow then
        self.hudFrame:Show()
        self.hudFrame:SetAlpha(alpha)
    else
        self.hudFrame:Hide()
    end
end

-------------------------------------------------------------------------------
-- Lock/Unlock
-------------------------------------------------------------------------------

function addon:ToggleLock()
    self.db.profile.locked = not self.db.profile.locked

    if self.db.profile.locked then
        self.Utils:Print("HUD |cffff0000locked|r.")
    else
        self.Utils:Print("HUD |cff00ff00unlocked|r. Drag to reposition.")
        -- Show frame while unlocked for positioning
        if self.hudFrame then
            self.hudFrame:Show()
            self.hudFrame:SetAlpha(1)
        end
    end
end

function addon:IsLocked()
    return self.db.profile.locked
end

-------------------------------------------------------------------------------
-- Slash Commands
-------------------------------------------------------------------------------

function addon:RegisterSlashCommands()
    SLASH_VEEVHUD1 = "/veevhud"
    SLASH_VEEVHUD2 = "/vh"

    SlashCmdList["VEEVHUD"] = function(msg)
        local args = {}
        for word in msg:gmatch("%S+") do
            table.insert(args, word:lower())
        end

        local cmd = args[1] or "help"

        if cmd == "help" then
            self.Utils:Print("Commands:")
            print("  /vh lock - Toggle lock/unlock")
            print("  /vh reset - Reset to defaults")
            print("  /vh toggle - Enable/disable HUD")
            print("  /vh spec - Show detected spec")
            print("  /vh scan - Force rescan spells")
            print("  /vh resource - Cycle resource display (none/bar/fill)")
            print("  /vh show <id> - Force show a spell")
            print("  /vh hide <id> - Force hide a spell")
            print("  /vh clear <id> - Remove spell override")
            print("  /vh log [n] - Show log entries")
            print("  /vh debug - Toggle debug mode")

        elseif cmd == "lock" or cmd == "unlock" then
            self:ToggleLock()

        elseif cmd == "reset" then
            self:ResetProfile()

        elseif cmd == "toggle" then
            self.db.profile.enabled = not self.db.profile.enabled
            if self.db.profile.enabled then
                self.Utils:Print("HUD |cff00ff00enabled|r.")
            else
                self.Utils:Print("HUD |cffff0000disabled|r.")
            end

        elseif cmd == "config" or cmd == "options" then
            -- Will open options panel when implemented
            self.Utils:Print("Configuration panel coming soon. Use /vh lock to reposition.")

        elseif cmd == "log" then
            local count = args[2] and tonumber(args[2]) or 20
            self.Utils:PrintRecentLog(count)

        elseif cmd == "clearlog" then
            self.Utils:ClearLog()

        elseif cmd == "debug" then
            self.db.profile.debugMode = not self.db.profile.debugMode
            local state = self.db.profile.debugMode and "enabled" or "disabled"
            self.Utils:Print("Debug mode " .. state)
            self.Utils:LogInfo("Debug mode", state)

        elseif cmd == "resource" or cmd == "res" then
            -- Cycle through resource display modes: none -> bar -> fill -> none
            local current = self.db.profile.icons.resourceDisplayMode or "bar"
            local newMode
            if current == "none" then
                newMode = "bar"
            elseif current == "bar" then
                newMode = "fill"
            else
                newMode = "none"
            end
            self.db.profile.icons.resourceDisplayMode = newMode
            self:SetOverride("icons.resourceDisplayMode", newMode)
            self.Utils:Print("Resource display mode: |cff00ff00" .. newMode .. "|r")

        elseif cmd == "scan" or cmd == "rescan" then
            local tracker = self:GetModule("SpellTracker")
            if tracker then
                tracker:FullRescan()
                self.Utils:Print("Spells rescanned.")
            end

        elseif cmd == "spec" then
            if self.LibSpellDB then
                -- Force re-detect
                local spec, points = self.LibSpellDB:DetectPlayerSpec()
                self.playerSpec = spec
                self.Utils:Print("Detected spec: |cff00ff00" .. (spec or "Unknown") .. "|r")
                self.Utils:Print("Talents: " .. (points[1] or 0) .. "/" .. (points[2] or 0) .. "/" .. (points[3] or 0))
                
                -- Trigger rescan if spec changed
                local tracker = self:GetModule("SpellTracker")
                if tracker then
                    tracker:FullRescan()
                end
            else
                self.Utils:Print("LibSpellDB not loaded")
            end

        elseif cmd == "show" then
            -- Force show a spell: /vh show <spellID>
            local spellID = args[2] and tonumber(args[2])
            if spellID then
                local tracker = self:GetModule("SpellTracker")
                if tracker then
                    tracker:SetOverride(spellID, true)
                    local name = GetSpellInfo(spellID) or "Unknown"
                    self.Utils:Print("Forcing spell to show: " .. name .. " (" .. spellID .. ")")
                end
            else
                self.Utils:Print("Usage: /vh show <spellID>")
            end

        elseif cmd == "hide" then
            -- Force hide a spell: /vh hide <spellID>
            local spellID = args[2] and tonumber(args[2])
            if spellID then
                local tracker = self:GetModule("SpellTracker")
                if tracker then
                    tracker:SetOverride(spellID, false)
                    local name = GetSpellInfo(spellID) or "Unknown"
                    self.Utils:Print("Forcing spell to hide: " .. name .. " (" .. spellID .. ")")
                end
            else
                self.Utils:Print("Usage: /vh hide <spellID>")
            end

        elseif cmd == "clear" then
            -- Clear spell override: /vh clear <spellID>
            local spellID = args[2] and tonumber(args[2])
            if spellID then
                local tracker = self:GetModule("SpellTracker")
                if tracker then
                    tracker:SetOverride(spellID, nil)
                    local name = GetSpellInfo(spellID) or "Unknown"
                    self.Utils:Print("Cleared override for: " .. name .. " (" .. spellID .. ")")
                end
            else
                self.Utils:Print("Usage: /vh clear <spellID>")
            end

        elseif cmd == "spells" then
            -- List all tracked spells
            local tracker = self:GetModule("SpellTracker")
            if tracker then
                local tracked = tracker:GetTrackedSpells()
                local count = 0
                print("|cff00ff00VeevHUD Tracked Spells:|r")
                for spellID, data in pairs(tracked) do
                    local name = GetSpellInfo(spellID) or "Unknown"
                    local tags = data.spellData.tags and table.concat(data.spellData.tags, ", ") or "none"
                    print(string.format("  |cffaaaaaa%d|r %s |cff888888(%s)|r", spellID, name, data.reason))
                    count = count + 1
                end
                print(string.format("|cff00ff00Total: %d spells|r", count))
            end

        elseif cmd == "cd" then
            -- Debug cooldown for a spell: /vh cd <spellID or name>
            local query = args[2]
            if query then
                local spellID = tonumber(query)
                local spellName
                
                if spellID then
                    spellName = GetSpellInfo(spellID)
                else
                    -- Treat as spell name
                    spellName = query
                    -- Try to find the spell ID
                    for i = 1, 500 do
                        local name = GetSpellBookItemName(i, BOOKTYPE_SPELL)
                        if not name then break end
                        if name:lower() == query:lower() then
                            spellName = name
                            break
                        end
                    end
                end
                
                print("|cff00ff00Cooldown Debug:|r " .. (spellName or query))
                
                -- Test by ID
                if spellID then
                    local startID, durID, enID = GetSpellCooldown(spellID)
                    print(string.format("  By ID (%d): start=%.1f, dur=%.1f, enabled=%s", 
                        spellID, startID or 0, durID or 0, tostring(enID)))
                end
                
                -- Test by name
                if spellName then
                    local startN, durN, enN = GetSpellCooldown(spellName)
                    print(string.format("  By Name (%s): start=%.1f, dur=%.1f, enabled=%s", 
                        spellName, startN or 0, durN or 0, tostring(enN)))
                end
                
                -- Test our wrapper
                if spellID then
                    local rem, dur, en = self.Utils:GetSpellCooldown(spellID)
                    print(string.format("  Utils wrapper: remaining=%.1f, duration=%.1f", rem or 0, dur or 0))
                end
            else
                self.Utils:Print("Usage: /vh cd <spellID or name>")
            end

        elseif cmd == "icon" then
            -- Debug icon state for a spell: /vh icon <spellID>
            local spellID = args[2] and tonumber(args[2])
            if spellID then
                local name = GetSpellInfo(spellID) or "Unknown"
                print("|cff00ff00Icon Debug:|r " .. name .. " (" .. spellID .. ")")
                
                local icons = self:GetModule("CooldownIcons")
                if icons and icons.rows then
                    local found = false
                    for _, rowFrame in ipairs(icons.rows) do
                        if rowFrame.icons then
                            for _, iconFrame in ipairs(rowFrame.icons) do
                                if iconFrame.spellID == spellID then
                                    found = true
                                    print("  isCoreRotation: " .. tostring(iconFrame.isCoreRotation or false))
                                    
                                    -- Check usability
                                    local isUsable, noMana = icons:IsSpellUsable(spellID)
                                    print("  IsSpellUsable: " .. tostring(isUsable) .. ", noMana: " .. tostring(noMana))
                                    
                                    -- Check combat state
                                    print("  inCombat: " .. tostring(UnitAffectingCombat("player")))
                                    
                                    -- Check icon state
                                    if iconFrame.icon then
                                        print("  icon:IsDesaturated: " .. tostring(iconFrame.icon:IsDesaturated()))
                                        print("  icon:GetAlpha: " .. string.format("%.2f", iconFrame:GetAlpha()))
                                    end
                                    
                                    -- Check tags
                                    if iconFrame.spellData and iconFrame.spellData.tags then
                                        print("  Tags: " .. table.concat(iconFrame.spellData.tags, ", "))
                                    end
                                end
                            end
                        end
                    end
                    if not found then
                        print("  Icon not found in HUD")
                    end
                end
            else
                self.Utils:Print("Usage: /vh icon <spellID>")
            end

        elseif cmd == "usable" then
            -- Debug IsUsableSpell for a spell: /vh usable <spellID or name>
            local query = args[2]
            if query then
                local spellID = tonumber(query)
                local spellName
                
                if spellID then
                    spellName = GetSpellInfo(spellID)
                else
                    spellName = query
                end
                
                print("|cff00ff00IsUsableSpell Debug:|r")
                
                -- Test by ID
                if spellID and IsUsableSpell then
                    local usableByID, noManaByID = IsUsableSpell(spellID)
                    print(string.format("  By ID (%d): usable=%s, noMana=%s", 
                        spellID, tostring(usableByID), tostring(noManaByID)))
                end
                
                -- Test by name
                if spellName and IsUsableSpell then
                    local usableByName, noManaByName = IsUsableSpell(spellName)
                    print(string.format("  By Name (%s): usable=%s, noMana=%s", 
                        spellName, tostring(usableByName), tostring(noManaByName)))
                end
                
                -- Test C_Spell API if available
                if spellID and C_Spell and C_Spell.IsSpellUsable then
                    local usableC, noManaC = C_Spell.IsSpellUsable(spellID)
                    print(string.format("  C_Spell.IsSpellUsable(%d): usable=%s, noMana=%s", 
                        spellID, tostring(usableC), tostring(noManaC)))
                end
                
                -- Show target health if relevant
                if UnitExists("target") then
                    local hp = UnitHealth("target")
                    local maxHp = UnitHealthMax("target")
                    local pct = maxHp > 0 and (hp / maxHp * 100) or 0
                    print(string.format("  Target health: %.1f%%", pct))
                else
                    print("  No target")
                end
            else
                self.Utils:Print("Usage: /vh usable <spellID or name>")
            end

        elseif cmd == "overlay" then
            -- Debug overlay state for a spell: /vh overlay <spellID>
            local spellID = args[2] and tonumber(args[2])
            if spellID then
                local name = GetSpellInfo(spellID) or "Unknown"
                print("|cff00ff00Overlay Debug:|r " .. name .. " (" .. spellID .. ")")
                
                -- Check if IsSpellOverlayed API exists
                if IsSpellOverlayed then
                    local overlayed = IsSpellOverlayed(spellID)
                    print("  IsSpellOverlayed API: " .. tostring(overlayed))
                else
                    print("  IsSpellOverlayed API: |cffff0000not available|r")
                end
                
                -- Check our tracking table
                local icons = self:GetModule("CooldownIcons")
                if icons and icons.activeOverlays then
                    local tracked = icons.activeOverlays[spellID]
                    print("  Event-tracked overlay: " .. tostring(tracked or false))
                end
                
                -- Check HasSpellActivationOverlay result
                if icons then
                    local result = icons:HasSpellActivationOverlay(spellID)
                    print("  HasSpellActivationOverlay: " .. tostring(result))
                end
                
                -- Check if frame has the spell
                if icons and icons.rows then
                    for _, rowFrame in ipairs(icons.rows) do
                        if rowFrame.icons then
                            for _, iconFrame in ipairs(rowFrame.icons) do
                                if iconFrame.spellID == spellID then
                                    if iconFrame.spellData and iconFrame.spellData.tags then
                                        print("  Tags: " .. table.concat(iconFrame.spellData.tags, ", "))
                                    end
                                end
                            end
                        end
                    end
                end
            else
                self.Utils:Print("Usage: /vh overlay <spellID>")
            end

        else
            self.Utils:Print("Unknown command. Type /vh help for usage.")
        end
    end
end
