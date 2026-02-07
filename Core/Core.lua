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
    
    -- Initialize saved variables with defaults (AceDB + legacy migration)
    self.Database:Initialize()

    -- Snapshot initial aspect ratio for Masque reload detection on profile changes.
    self._lastAspectRatio = self.db and self.db.profile and self.db.profile.icons
        and self.db.profile.icons.iconAspectRatio

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
    
    -- Initialize TextureManager (handles LibSharedMedia integration for bar textures)
    if self.TextureManager then
        self.TextureManager:Initialize()
    end
    
    -- Initialize RangeChecker (handles spell range detection)
    if self.RangeChecker then
        self.RangeChecker:Initialize()
    end
end

-------------------------------------------------------------------------------
-- Profile Change Handling (AceDB / LibDualSpec)
-------------------------------------------------------------------------------

function addon:OnProfileChanged()
    -- Refresh everything that depends on profile settings.
    -- This is triggered by manual profile switches and by LibDualSpec when specs change.
    if self.fatalError then return end

    -- Snapshot the previous aspect ratio before refreshing (profile is already switched).
    local prevAspectRatio = self._lastAspectRatio

    -- Update anchor/scale (safe if HUD isn't created yet).
    if self.hudFrame then
        self:UpdateHUDPosition()
    end

    -- Refresh fonts first so modules can pick up new font paths.
    if self.FontManager and self.FontManager.RefreshAllFonts then
        self.FontManager:RefreshAllFonts()
    end

    -- Refresh bar textures so modules can pick up new texture paths.
    -- (Modules also update textures in their own Refresh, but this ensures
    -- the TextureManager state is current before the module loop below.)
    if self.TextureManager and self.TextureManager.RefreshAllTextures then
        self.TextureManager:RefreshAllTextures()
    end

    -- Refresh all modules.
    for name, module in pairs(self.modules) do
        if module.Refresh then
            local success, err = pcall(module.Refresh, module)
            if not success then
                if self.Utils and self.Utils.LogError then
                    self.Utils:LogError("Error refreshing module", name, ":", err)
                end
            end
        end
    end

    -- Force a layout refresh (some modules only update gaps).
    if self.Layout then
        self.Layout:Refresh()
    end

    -- Ensure visibility/alpha is correct after changes.
    if self.UpdateVisibility then
        self:UpdateVisibility()
    end

    -- Track aspect ratio and prompt reload if Masque needs it.
    local newAspectRatio = self.db and self.db.profile and self.db.profile.icons
        and self.db.profile.icons.iconAspectRatio
    self._lastAspectRatio = newAspectRatio
    if prevAspectRatio and newAspectRatio and prevAspectRatio ~= newAspectRatio then
        local cooldownIcons = self:GetModule("CooldownIcons")
        if cooldownIcons and cooldownIcons.MasqueGroup then
            StaticPopup_Show("VEEVHUD_RELOAD_UI")
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
    
    -- Show any pending migration notices
    self.MigrationManager:Show()
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

function addon:IsProcEnabled(spellID)
    return self.Database:IsProcEnabled(spellID)
end

function addon:SetProcEnabled(spellID, enabled)
    self.Database:SetProcEnabled(spellID, enabled)
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
    self.hudFrame = hud
    self:UpdateHUDPosition()
    hud:SetFrameStrata("MEDIUM")
    hud:SetFrameLevel(10)
    hud:EnableMouse(false)  -- Always click-through (position via settings only)
    
    -- Apply global scale (compensated for UI scale)
    self:UpdateHUDScale()

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

-- Update HUD anchor position (called when offsets/profile change)
function addon:UpdateHUDPosition()
    if not self.hudFrame or not self.db or not self.db.profile then return end

    local db = self.db.profile.anchor or {}

    self.hudFrame:ClearAllPoints()
    self.hudFrame:SetPoint(
        db.point or "CENTER",
        UIParent,
        db.relativePoint or "CENTER",
        db.x or 0,
        db.y or -84
    )

    -- Reapply scale (also covers UI scale compensation).
    self:UpdateHUDScale()
end

function addon:UpdateVisibility()
    if not self.hudFrame then return end

    local shouldShow, targetAlpha = self.Utils:ShouldShowHUD()

    if shouldShow then
        self.hudFrame:Show()
        
        -- Start/update alpha animation if target changed
        if self.targetAlpha ~= targetAlpha then
            self.targetAlpha = targetAlpha
            -- Use Animations utility for consistent alpha transition
            if self.Animations then
                self.Animations:TransitionAlpha(self.hudFrame, targetAlpha, 6)
            else
                self.hudFrame:SetAlpha(targetAlpha)
            end
        end
    else
        self.hudFrame:Hide()
        self.targetAlpha = nil
        if self.Animations then
            self.Animations:StopAlphaTransition(self.hudFrame)
        end
    end
end

