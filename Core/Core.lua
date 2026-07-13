--[[
    VeevHUD - Core Addon Framework
]]

local ADDON_NAME, addon = ...
local L = LibStub("AceLocale-3.0"):GetLocale("VeevHUD")

-- Make addon accessible globally for debugging
_G.VeevHUD = addon

-- Core addon object
addon.name = ADDON_NAME
addon.version = nil  -- Set in ADDON_LOADED when API is available

-- Module registry
addon.modules = {}

-- Deterministic module lifecycle order, shared by InitializeModules and
-- OnProfileChanged. pairs() iteration order is undefined, and lifecycle
-- methods have real dependencies: SpellTracker before AuraState (aura
-- mappings read tracked spells), and the icon trackers before CooldownIcons
-- (RebuildAllRows consumes their runtime data). Modules not listed are
-- handled by a catch-all pass afterward.
local MODULE_ORDER = {
    "SpellTracker", "AuraState", "SpellAssignment", "IconStateEngine",
    "IconFrameFactory", "IconRenderer", "GlowManager",
    "TrinketTracker", "ConsumableTracker", "TotemTracker", "StanceTracker",
    "CooldownIcons",
    "AuraTracker", "BuffReminders",
    "ResourceBar", "HealthBar", "PetHealthBar", "ComboPoints", "SwingBar",
}

-- Libraries
addon.LibSpellDB = nil  -- Set on load

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Entering combat
frame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- Leaving combat
frame:RegisterEvent("UI_SCALE_CHANGED")       -- Player changed UI scale in settings
frame:RegisterEvent("DISPLAY_SIZE_CHANGED")   -- Resolution/window changes move UIParent's scale without UI_SCALE_CHANGED

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        self:UnregisterEvent("ADDON_LOADED")
        addon:OnAddonLoaded()
    elseif event == "PLAYER_LOGIN" then
        addon:OnPlayerLogin()
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        if event == "PLAYER_REGEN_DISABLED" then
            local cooldownIcons = addon:GetModule("CooldownIcons")
            if cooldownIcons and cooldownIcons.IsPositionEditMode
                    and cooldownIcons:IsPositionEditMode() then
                cooldownIcons:SetPositionEditMode(false)
            end
        end
        -- Combat state changed, update HUD visibility/alpha immediately
        addon:UpdateVisibility()
    elseif event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
        -- Reapply HUD scale to compensate for new effective UI scale
        addon:UpdateHUDScale()
    end
end)

function addon:OnAddonLoaded()
    -- Set version from TOC metadata (API available now)
    -- Handle different API names across WoW versions
    local getMetadata = GetAddOnMetadata or (C_AddOns and C_AddOns.GetAddOnMetadata)
    self.version = getMetadata and getMetadata(ADDON_NAME, "Version") or "unknown"
    self.Constants.VERSION = self.version
    
    -- Initialize saved variables with defaults (AceDB + legacy migration)
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
    
    -- Initialize TextureManager (handles LibSharedMedia integration for bar textures)
    if self.TextureManager then
        self.TextureManager:Initialize()
    end

    -- Initialize SoundManager (handles LibSharedMedia integration for sound playback)
    if self.SoundManager then
        self.SoundManager:Initialize()
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

    -- Signal to the safety wrapper (Database.lua) that the AceDB callback fired.
    -- The wrapper only calls OnProfileChanged manually when this flag stays false.
    self._profileCallbackFired = true

    -- Migrate old gap settings for the new profile (idempotent)
    self.Database:MigrateLayoutGaps()

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

    -- Refresh modules in deterministic order (see MODULE_ORDER — trackers
    -- must refresh before CooldownIcons so RebuildAllRows sees fresh data).
    for _, name in ipairs(MODULE_ORDER) do
        local module = self.modules[name]
        if module and module.Refresh then
            local success, err = pcall(module.Refresh, module)
            if not success then
                if self.Utils and self.Utils.LogError then
                    self.Utils:LogError("Error refreshing module", name, ":", err)
                end
            end
        end
    end
    -- Catch any modules not in the explicit list (future-proofing)
    for name, module in pairs(self.modules) do
        if module.Refresh and not tContains(MODULE_ORDER, name) then
            local success, err = pcall(module.Refresh, module)
            if not success then
                if self.Utils and self.Utils.LogError then
                    self.Utils:LogError("Error refreshing module", name, ":", err)
                end
            end
        end
    end

    -- Force a layout refresh (profile switch can change gaps without changing heights).
    if self.Layout then
        self.Layout:ForceRefresh()
    end

    -- Ensure visibility/alpha is correct after changes.
    if self.UpdateVisibility then
        self:UpdateVisibility()
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
    self.Utils:Print(L["v%s loaded. Type |cff00ff00/vh|r for options."]:format(self.version))
    
    -- Show welcome popup on first load
    self.WelcomePopup:Show()
    
    -- Run any pending versioned migrations
    self.Migrations:Run()
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

-- Format spec key "PRIEST_HOLY" or "HUNTER_BEAST_MASTERY" for display.
-- Class token is always a single word; spec token may contain underscores.
function addon:FormatSpecKey(specKey)
    specKey = specKey or self:GetSpecKey()
    local class, spec = specKey:match("^(%a+)_(.+)$")
    if not class then return specKey end
    local function titleCase(s) return s:sub(1,1):upper() .. s:sub(2):lower() end
    -- Convert underscored spec tokens like "BEAST_MASTERY" to "Beast Mastery"
    local specWords = {}
    for word in spec:gmatch("[^_]+") do
        table.insert(specWords, titleCase(word))
    end
    return table.concat(specWords, " ") .. " " .. titleCase(class)
end

--- Format a spec label with icon and class color for use in descriptions.
-- Returns e.g. "|T134940:14|t |cFFC79C6EArms Warrior|r"
function addon:FormatSpecLabel(specKey)
    specKey = specKey or self:GetSpecKey()
    if not specKey then return nil end

    local name = self:FormatSpecKey(specKey)
    local class, spec = specKey:match("^(%a+)_(.+)$")

    -- Icon from LibSpellDB talent tree tab
    local icon = self.LibSpellDB and spec and self.LibSpellDB:GetSpecIcon(class, spec)
    local iconStr = icon and ("|T" .. icon .. ":14|t ") or ""

    -- Class color
    local coloredName
    local color = self.Constants.CLASS_COLORS[class]
    if color then
        local hex = string.format("|cFF%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255)
        coloredName = hex .. name .. "|r"
    else
        coloredName = name
    end

    return iconStr .. coloredName
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

function addon:IsAuraEnabled(spellID)
    return self.Database:IsAuraEnabled(spellID)
end

function addon:SetAuraEnabled(spellID, enabled)
    self.Database:SetAuraEnabled(spellID, enabled)
end

function addon:GetAuraSourceFilter(spellID, auraSource)
    return self.Database:GetAuraSourceFilter(spellID, auraSource)
end

function addon:SetAuraSourceFilter(spellID, filter, auraSource)
    self.Database:SetAuraSourceFilter(spellID, filter, auraSource)
end

function addon:IsAuraGlowEnabled(spellID)
    return self.Database:IsAuraGlowEnabled(spellID)
end

function addon:SetAuraGlowEnabled(spellID, enabled)
    self.Database:SetAuraGlowEnabled(spellID, enabled)
end

function addon:GetAuraDisplayMode(spellID)
    return self.Database:GetAuraDisplayMode(spellID)
end

function addon:SetAuraDisplayMode(spellID, mode)
    self.Database:SetAuraDisplayMode(spellID, mode)
end

function addon:GetAuraBarColor(spellID)
    return self.Database:GetAuraBarColor(spellID)
end

function addon:SetAuraBarColor(spellID, r, g, b)
    self.Database:SetAuraBarColor(spellID, r, g, b)
end

function addon:ClearAuraBarColor(spellID)
    self.Database:ClearAuraBarColor(spellID)
end

function addon:GetAuraSound(spellID)
    return self.Database:GetAuraSound(spellID)
end

function addon:SetAuraSound(spellID, soundName)
    self.Database:SetAuraSound(spellID, soundName)
end

function addon:GetAuraSoundOnRefresh(spellID)
    return self.Database:GetAuraSoundOnRefresh(spellID)
end

function addon:SetAuraSoundOnRefresh(spellID, enabled)
    self.Database:SetAuraSoundOnRefresh(spellID, enabled)
end

function addon:GetBuffReminderSound(spellID)
    return self.Database:GetBuffReminderSound(spellID)
end

function addon:SetBuffReminderSound(spellID, soundName)
    self.Database:SetBuffReminderSound(spellID, soundName)
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

-- Icon providers: modules that inject sentinel-ID icons into CooldownIcons
-- rows (trinkets, totems, stance indicator, consumables). Each provider
-- registers from its Initialize (MODULE_ORDER runs providers before
-- CooldownIcons); CooldownIcons dispatches injection/setup/update through
-- the list instead of hardcoding every tracker at four call sites.
-- Provider shape: { name, order, module, IsSentinel(id), Setup(frame, id,
-- rowConfig, rowIndex), Update(frame, db) -> wantsTick, ShouldInject()? }
addon.iconProviders = {}
function addon:RegisterIconProvider(provider)
    table.insert(self.iconProviders, provider)
end

function addon:GetModule(name)
    return self.modules[name]
end

function addon:InitializeModules()
    local function initOne(name, module)
        if module and module.Initialize then
            local success, err = pcall(module.Initialize, module)
            if not success then
                self.Utils:Print("|cffff0000Error initializing module " .. name .. ":|r " .. tostring(err))
            end
        end
    end

    -- Deterministic order first (same list as Refresh), then any stragglers
    for _, name in ipairs(MODULE_ORDER) do
        initOne(name, self.modules[name])
    end
    for name, module in pairs(self.modules) do
        if not tContains(MODULE_ORDER, name) then
            initOne(name, module)
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
            local ok, err = pcall(module.CreateFrames, module, self.hudFrame)
            if not ok then
                self.Utils:LogError("Error creating frames for", name, ":", err)
            end
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

    -- Independently positioned rows are anchored to UIParent while inheriting
    -- the HUD's scale, so their offsets must be reapplied after scale changes.
    local cooldownIcons = self:GetModule("CooldownIcons")
    if cooldownIcons and cooldownIcons.RefreshIndependentRowPositions then
        cooldownIcons:RefreshIndependentRowPositions()
    end

    -- BuffReminders is parented to UIParent (not hudFrame) for independent visibility,
    -- so it doesn't inherit the HUD scale automatically and needs a manual update
    local br = self:GetModule("BuffReminders")
    if br and br.UpdatePosition then
        br:UpdatePosition()
    end
end

-- Update HUD anchor position (called when offsets/profile change)
function addon:UpdateHUDPosition()
    if not self.hudFrame or not self.db or not self.db.profile then return end

    local db = self.db.profile.anchor

    self.hudFrame:ClearAllPoints()
    self.hudFrame:SetPoint(
        db.point,
        UIParent,
        db.relativePoint,
        db.x,
        db.y
    )

    -- Reapply scale (also covers UI scale compensation).
    self:UpdateHUDScale()
end

function addon:UpdateVisibility()
    if not self.hudFrame then return end

    local shouldShow, targetAlpha = self.Utils:ShouldShowHUD()

    if shouldShow then
        self.hudFrame:Show()
        -- TransitionAlpha no-ops when already at target
        if self.Animations then
            self.Animations:TransitionAlpha(self.hudFrame, targetAlpha, 6)
        else
            self.hudFrame:SetAlpha(targetAlpha)
        end
    else
        self.hudFrame:Hide()
        if self.Animations then
            self.Animations:StopAlphaTransition(self.hudFrame)
        end
    end
end

