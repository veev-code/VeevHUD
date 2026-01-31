--[[
    VeevHUD - Core Addon Framework
]]

local ADDON_NAME, addon = ...

-- Make addon accessible globally for debugging
_G.VeevHUD = addon

-- Core addon object
addon.name = ADDON_NAME
addon.version = nil  -- Set in ADDON_LOADED when API is available

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
frame:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Entering combat
frame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- Leaving combat

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        addon:OnAddonLoaded()
    elseif event == "PLAYER_LOGIN" then
        addon:OnPlayerLogin()
    elseif event == "PLAYER_LOGOUT" then
        addon:OnPlayerLogout()
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        -- Combat state changed, update HUD visibility/alpha immediately
        addon:UpdateVisibility()
    end
end)

-------------------------------------------------------------------------------
-- Welcome Popup (shown once on first load)
-------------------------------------------------------------------------------

local DISCORD_URL = "https://discord.gg/HuSXTa5XNq"

function addon:CreateWelcomeDialog()
    if self.welcomeDialog then return self.welcomeDialog end
    
    local dialog = CreateFrame("Frame", "VeevHUDWelcomeDialog", UIParent, "BasicFrameTemplateWithInset")
    dialog:SetSize(400, 240)
    dialog:SetPoint("CENTER")
    dialog:SetFrameStrata("DIALOG")
    dialog:SetMovable(true)
    dialog:EnableMouse(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
    dialog:Hide()
    
    -- Title
    local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -8)
    title:SetText("|cff00ccffVeevHUD|r")
    
    -- Message text
    local message = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    message:SetPoint("TOP", title, "BOTTOM", 0, -12)
    message:SetWidth(360)
    message:SetJustifyH("CENTER")
    message:SetText("Thanks for trying VeevHUD!\n\n" ..
                   "Type |cff00ff00/vh|r to open settings.\n\n" ..
                   "This addon is under active development.\n" ..
                   "Your feedback helps shape its future.\n\n" ..
                   "Join the |cffffffffVeev Addons Discord|r for suggestions,\n" ..
                   "bug reports, and updates:")
    
    -- URL edit box (for copy/paste)
    local editBox = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
    editBox:SetSize(300, 20)
    editBox:SetPoint("TOP", message, "BOTTOM", 0, -12)
    editBox:SetAutoFocus(false)
    editBox:SetText(DISCORD_URL)
    editBox:SetScript("OnEditFocusGained", function(self)
        self:HighlightText()
    end)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    editBox:SetScript("OnTextChanged", function(self)
        -- Prevent editing - always reset to the URL
        self:SetText(DISCORD_URL)
        self:HighlightText()
    end)
    
    -- Instructions
    local instructions = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    instructions:SetPoint("TOP", editBox, "BOTTOM", 0, -4)
    instructions:SetText("|cff888888Click the link above, then Ctrl+C to copy|r")
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
    closeBtn:SetSize(120, 24)
    closeBtn:SetPoint("BOTTOM", 0, 12)
    closeBtn:SetText("Got it!")
    closeBtn:SetScript("OnClick", function()
        VeevHUDDB.welcomeShown = true
        dialog:Hide()
    end)
    
    -- Also mark as shown when closing via X button
    dialog:SetScript("OnHide", function()
        VeevHUDDB.welcomeShown = true
    end)
    
    self.welcomeDialog = dialog
    return dialog
end

function addon:ShowWelcomePopup()
    if not VeevHUDDB.welcomeShown then
        -- Delay slightly to ensure UI is fully loaded
        C_Timer.After(1, function()
            local dialog = self:CreateWelcomeDialog()
            dialog:Show()
            -- Auto-select the URL for easy copying
            local editBox = dialog:GetChildren()
            for i = 1, dialog:GetNumChildren() do
                local child = select(i, dialog:GetChildren())
                if child:IsObjectType("EditBox") then
                    child:SetFocus()
                    child:HighlightText()
                    break
                end
            end
        end)
    end
end

function addon:OnAddonLoaded()
    -- Set version from TOC metadata (API available now)
    -- Handle different API names across WoW versions
    local getMetadata = GetAddOnMetadata or (C_AddOns and C_AddOns.GetAddOnMetadata)
    self.version = getMetadata and getMetadata(ADDON_NAME, "Version") or "1.0.5"
    self.Constants.VERSION = self.version
    
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
    
    -- Initialize FontManager (handles LibSharedMedia integration)
    if self.FontManager then
        self.FontManager:Initialize()
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
            self.Utils:LogInfo("Player spec:", spec or "Unknown", "(" .. (points[1] or 0) .. "/" .. (points[2] or 0) .. "/" .. (points[3] or 0) .. ")")
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
    
    -- Show welcome popup on first load
    self:ShowWelcomePopup()
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

-- Helper to convert a key to number if it looks like one (for array tables like rows)
local function ToKeyType(key)
    local num = tonumber(key)
    return num or key
end

-- Save a user override (only saves the specific changed value)
function addon:SetOverride(path, value)
    local overrides = VeevHUDDB.overrides
    local keys = {strsplit(".", path)}
    
    -- Navigate to the parent table, creating as needed
    for i = 1, #keys - 1 do
        local key = ToKeyType(keys[i])
        if not overrides[key] then
            overrides[key] = {}
        end
        overrides = overrides[key]
    end
    
    -- Set the value
    overrides[ToKeyType(keys[#keys])] = value
    
    -- Rebuild live profile
    self:RebuildLiveProfile()
end

-- Clear a specific override (revert to default)
function addon:ClearOverride(path)
    local overrides = VeevHUDDB.overrides
    local keys = {strsplit(".", path)}
    
    -- Navigate to the parent
    for i = 1, #keys - 1 do
        local key = ToKeyType(keys[i])
        if not overrides[key] then
            return -- Path doesn't exist, nothing to clear
        end
        overrides = overrides[key]
    end
    
    -- Clear the value
    overrides[ToKeyType(keys[#keys])] = nil
    
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
-- Spell Config Helpers
-------------------------------------------------------------------------------

-- Get the specKey for the current player (e.g., "WARRIOR_FURY")
function addon:GetSpecKey()
    local class = self.playerClass or "UNKNOWN"
    local spec = self.playerSpec or "UNKNOWN"
    return class .. "_" .. spec
end

-- Get spellConfig for current spec (read from live profile, safe nil handling)
function addon:GetSpellConfig(specKey)
    specKey = specKey or self:GetSpecKey()
    local spellCfgAll = self.db and self.db.profile and self.db.profile.spellConfig or {}
    return spellCfgAll[specKey] or {}
end

-- Get spellConfig override for a specific spell
function addon:GetSpellConfigForSpell(spellID, specKey)
    local spellCfg = self:GetSpellConfig(specKey)
    return spellCfg[spellID] or {}
end

-- Set a spellConfig override (writes to VeevHUDDB.overrides and rebuilds profile)
function addon:SetSpellConfigOverride(spellID, field, value, specKey)
    specKey = specKey or self:GetSpecKey()
    
    -- Initialize nested tables in overrides
    VeevHUDDB.overrides.spellConfig = VeevHUDDB.overrides.spellConfig or {}
    VeevHUDDB.overrides.spellConfig[specKey] = VeevHUDDB.overrides.spellConfig[specKey] or {}
    VeevHUDDB.overrides.spellConfig[specKey][spellID] = VeevHUDDB.overrides.spellConfig[specKey][spellID] or {}
    
    if value == nil then
        -- Remove override
        VeevHUDDB.overrides.spellConfig[specKey][spellID][field] = nil
        -- Clean up empty tables
        if next(VeevHUDDB.overrides.spellConfig[specKey][spellID]) == nil then
            VeevHUDDB.overrides.spellConfig[specKey][spellID] = nil
        end
        if next(VeevHUDDB.overrides.spellConfig[specKey]) == nil then
            VeevHUDDB.overrides.spellConfig[specKey] = nil
        end
        if next(VeevHUDDB.overrides.spellConfig) == nil then
            VeevHUDDB.overrides.spellConfig = nil
        end
    else
        VeevHUDDB.overrides.spellConfig[specKey][spellID][field] = value
    end
    
    -- Rebuild live profile
    self:RebuildLiveProfile()
end

-- Clear all spellConfig overrides for a specific spell
function addon:ClearSpellConfigOverride(spellID, specKey)
    specKey = specKey or self:GetSpecKey()
    
    if VeevHUDDB.overrides.spellConfig and VeevHUDDB.overrides.spellConfig[specKey] then
        VeevHUDDB.overrides.spellConfig[specKey][spellID] = nil
        if next(VeevHUDDB.overrides.spellConfig[specKey]) == nil then
            VeevHUDDB.overrides.spellConfig[specKey] = nil
        end
        if VeevHUDDB.overrides.spellConfig and next(VeevHUDDB.overrides.spellConfig) == nil then
            VeevHUDDB.overrides.spellConfig = nil
        end
    end
    
    self:RebuildLiveProfile()
end

-- Check if a spell has any overrides (for showing "modified" indicator)
function addon:IsSpellConfigModified(spellID, specKey)
    specKey = specKey or self:GetSpecKey()
    local overrides = VeevHUDDB.overrides.spellConfig
    if overrides and overrides[specKey] and overrides[specKey][spellID] then
        local cfg = overrides[specKey][spellID]
        return cfg.enabled ~= nil or cfg.rowIndex ~= nil or cfg.order ~= nil
    end
    return false
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
    hud:EnableMouse(false)  -- Always click-through (position via settings only)
    
    -- Apply global scale
    local scale = self.db.profile.icons.scale or 1.0
    hud:SetScale(scale)

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
    
    -- Trigger initial layout to position all elements
    if self.Layout then
        self.Layout:Refresh()
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

    local shouldShow, targetAlpha = self.Utils:ShouldShowHUD()

    if shouldShow then
        self.hudFrame:Show()
        
        -- Start/update alpha animation if target changed
        if self.targetAlpha ~= targetAlpha then
            self.targetAlpha = targetAlpha
            self:StartAlphaAnimation()
        end
    else
        self.hudFrame:Hide()
        self.targetAlpha = nil
        self:StopAlphaAnimation()
    end
end

-- Start or continue animating HUD alpha toward target
function addon:StartAlphaAnimation()
    if not self.hudFrame or self.alphaAnimating then return end
    
    self.alphaAnimating = true
    local fadeSpeed = 6  -- Higher = faster fade
    local minStep = 0.02  -- Minimum alpha change per frame to prevent getting stuck
    
    self.hudFrame:SetScript("OnUpdate", function(frame, elapsed)
        if not self.targetAlpha then
            self:StopAlphaAnimation()
            return
        end
        
        local currentAlpha = frame:GetAlpha()
        local diff = self.targetAlpha - currentAlpha
        
        -- If close enough, snap to target and stop
        if math.abs(diff) < 0.01 then
            frame:SetAlpha(self.targetAlpha)
            self:StopAlphaAnimation()
            return
        end
        
        -- Lerp toward target (ease-out) with minimum step to prevent getting stuck
        local step = diff * math.min(1, elapsed * fadeSpeed)
        -- Ensure minimum step size (in the correct direction)
        if math.abs(step) < minStep then
            step = diff > 0 and minStep or -minStep
        end
        local newAlpha = math.max(0, math.min(1, currentAlpha + step))
        frame:SetAlpha(newAlpha)
    end)
end

function addon:StopAlphaAnimation()
    if self.hudFrame then
        self.hudFrame:SetScript("OnUpdate", nil)
    end
    self.alphaAnimating = false
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

        local cmd = args[1] or "options"

        if cmd == "help" then
            self.Utils:Print("Commands:")
            print("  /vh options - Open settings panel")
            print("  /vh reset - Reset to defaults")
            print("  /vh toggle - Enable/disable HUD")
            print("  /vh spec - Show detected spec")
            print("  /vh scan - Force rescan spells")
            print("  /vh resource - Cycle resource display (none/bar/fill)")
            print("  /vh show <id> - Force show a spell")
            print("  /vh hide <id> - Force hide a spell")
            print("  /vh clear <id> - Remove spell override")
            print("  /vh check <id> - Diagnose why a spell isn't showing")
            print("  /vh layout - Debug layout system positions")
            print("  /vh log [n] - Show log entries")
            print("  /vh debug - Toggle debug mode")

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
            -- Open the Blizzard settings panel
            local options = self:GetModule("Options")
            if options then
                options:Open()
            else
                self.Utils:Print("Options module not loaded.")
            end

        elseif cmd == "log" then
            local count = args[2] and tonumber(args[2]) or 20
            self.Utils:PrintRecentLog(count)

        elseif cmd == "clearlog" then
            self.Utils:ClearLog()

        elseif cmd == "debug" then
            self.db.profile.debugMode = not self.db.profile.debugMode
            local state = self.db.profile.debugMode and "enabled" or "disabled"
            self.Utils:Print("Debug mode " .. state)
            if self.db.profile.debugMode then
                -- Start logging session when debug mode is enabled
                self.Utils:StartNewSession()
                self.Utils:Print("Logging to SavedVariables. Use /vh log to view.")
            else
                -- Clear log from SavedVariables when debug mode is disabled
                self.Utils:ClearLog()
            end

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

        elseif cmd == "check" then
            -- Diagnose why a spell isn't showing: /vh check <spellID>
            local spellID = args[2] and tonumber(args[2])
            if spellID then
                local name = GetSpellInfo(spellID) or "Unknown"
                print("|cff00ff00Spell Check:|r " .. name .. " (" .. spellID .. ")")
                
                -- Check if LibSpellDB knows about it
                local LibSpellDB = self.LibSpellDB
                local spellData = LibSpellDB and LibSpellDB:GetSpellInfo(spellID)
                if spellData then
                    print("  In LibSpellDB: |cff00ff00yes|r")
                    print("    Class: " .. (spellData.class or "unknown"))
                    print("    Tags: " .. (spellData.tags and table.concat(spellData.tags, ", ") or "none"))
                    print("    Specs: " .. (spellData.specs and table.concat(spellData.specs, ", ") or "all"))
                    print("    Talent: " .. tostring(spellData.talent or false))
                else
                    print("  In LibSpellDB: |cffff0000no|r (spell not in database)")
                end
                
                -- Check current spec
                local playerSpec = LibSpellDB and LibSpellDB:GetPlayerSpec()
                print("  Detected spec: " .. (playerSpec or "unknown"))
                
                -- Check if spec relevant
                if LibSpellDB and LibSpellDB.IsSpellRelevantForSpec then
                    local relevant = LibSpellDB:IsSpellRelevantForSpec(spellID)
                    print("  Relevant for spec: " .. tostring(relevant))
                end
                
                -- Check if known
                local tracker = self:GetModule("SpellTracker")
                if tracker then
                    local known = tracker:IsSpellKnown(spellID, spellData or {})
                    print("  IsSpellKnown: " .. tostring(known))
                    
                    -- Check if tracked
                    local isTracked = tracker:IsSpellTracked(spellID)
                    print("  IsTracked: " .. tostring(isTracked))
                    
                    -- Check enabled tags
                    local enabledTags = tracker:GetEnabledTags()
                    local matchingTags = {}
                    if spellData and spellData.tags then
                        for _, tag in ipairs(spellData.tags) do
                            if enabledTags[tag] then
                                table.insert(matchingTags, tag)
                            end
                        end
                    end
                    if #matchingTags > 0 then
                        print("  Matching row tags: " .. table.concat(matchingTags, ", "))
                    else
                        print("  Matching row tags: |cffff0000none|r (not in any enabled row)")
                    end
                    
                    -- Check exclusion
                    if spellData and tracker.ShouldExcludeSpell then
                        local excluded = tracker:ShouldExcludeSpell(spellData)
                        print("  ShouldExclude: " .. tostring(excluded))
                    end
                end
            else
                self.Utils:Print("Usage: /vh check <spellID>")
            end

        elseif cmd == "layout" then
            -- Debug layout system: /vh layout
            if self.Layout and self.Layout.PrintDebug then
                self.Layout:PrintDebug()
            else
                self.Utils:Print("Layout system not available.")
            end

        else
            self.Utils:Print("Unknown command. Type /vh help for usage.")
        end
    end
end
