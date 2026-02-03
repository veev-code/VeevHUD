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
frame:RegisterEvent("UI_SCALE_CHANGED")       -- Player changed UI scale in settings

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
    elseif event == "UI_SCALE_CHANGED" then
        -- Reapply HUD scale to compensate for new UI scale
        addon:UpdateHUDScale()
    end
end)

function addon:OnAddonLoaded()
    -- Set version from TOC metadata (API available now)
    -- Handle different API names across WoW versions
    local getMetadata = GetAddOnMetadata or (C_AddOns and C_AddOns.GetAddOnMetadata)
    self.version = getMetadata and getMetadata(ADDON_NAME, "Version") or "1.0.5"
    self.Constants.VERSION = self.version
    
    -- Initialize saved variables with defaults
    VeevHUDDB = VeevHUDDB or {}
    self.Database:Initialize()

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
    
    -- Initialize RangeChecker (handles spell range detection)
    if self.RangeChecker then
        self.RangeChecker:Initialize()
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
    self.SlashCommands:Register()

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
    self.WelcomePopup:Show()
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
-- Database API (delegates to Core/Database.lua)
-------------------------------------------------------------------------------
function addon:SetOverride(path, value)
    self.Database:SetOverride(path, value)
end

function addon:ClearOverride(path)
    self.Database:ClearOverride(path)
end

function addon:ResetProfile()
    self.Database:ResetProfile()
end

function addon:GetSpecKey()
    return self.Database:GetSpecKey()
end

function addon:GetSpellConfig(specKey)
    return self.Database:GetSpellConfig(specKey)
end

function addon:GetSpellConfigForSpell(spellID, specKey)
    return self.Database:GetSpellConfigForSpell(spellID, specKey)
end

function addon:SetSpellConfigOverride(spellID, field, value, specKey)
    self.Database:SetSpellConfigOverride(spellID, field, value, specKey)
end

function addon:ClearSpellConfigOverride(spellID, specKey)
    self.Database:ClearSpellConfigOverride(spellID, specKey)
end

function addon:IsSpellConfigModified(spellID, specKey)
    return self.Database:IsSpellConfigModified(spellID, specKey)
end

function addon:GetDefaultValue(path)
    return self.Database:GetDefaultValue(path)
end

function addon:GetSettingValue(path)
    return self.Database:GetSettingValue(path)
end

function addon:IsSettingOverridden(path)
    return self.Database:IsSettingOverridden(path)
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
    
    -- Apply global scale (compensated for UI scale)
    local scale = self.Utils:GetEffectiveHUDScale()
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

-- Update HUD scale (called when UI scale changes or user adjusts Global Scale)
function addon:UpdateHUDScale()
    if not self.hudFrame then return end
    local scale = self.Utils:GetEffectiveHUDScale()
    self.hudFrame:SetScale(scale)
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

