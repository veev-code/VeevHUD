--[[
    VeevHUD - Stance Tracker Module
    Tracks current stance/form/aura for Warriors, Druids, and Paladins.
    Renders as a single sentinel icon within CooldownIcons rows
    (like TrinketTracker/TotemTracker).

    =====================================================================
    REQUIREMENTS
    =====================================================================

    1. Single sentinel ID (C.STANCE_INDICATOR) representing current stance.
       Appears in SpellsOptions as a draggable entry.
    2. Default to Auxiliary Row (row 4), user can drag to any row.
    3. Supported classes:
       - Warrior: Battle Stance, Defensive Stance, Berserker Stance
       - Druid:   Bear Form, Cat Form, Travel Form, Moonkin Form, Aquatic Form
       - Paladin: Devotion Aura, Retribution Aura, etc.
    4. Icon always shows the CURRENT active stance/form/aura texture.
    5. If no stance is active, show a default "no stance" icon (dimmed).
    6. No duration tracking — stances are permanent until switched.
    7. Self-contained: uses GetShapeshiftForm / GetShapeshiftFormInfo API.
    8. CooldownIcons delegates to this module for setup + state updates.

    =====================================================================
]]

local _, addon = ...
local L = LibStub("AceLocale-3.0"):GetLocale("VeevHUD")

local StanceTracker = {}
addon:RegisterModule("StanceTracker", StanceTracker)

-- Cached API calls
local GetShapeshiftForm = GetShapeshiftForm
local GetShapeshiftFormInfo = GetShapeshiftFormInfo
local GetNumShapeshiftForms = GetNumShapeshiftForms

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

-- Supported classes
local SUPPORTED_CLASSES = {
    WARRIOR = true,
    DRUID   = true,
    PALADIN = true,
}

-- Default icon when no stance/form is active
local DEFAULT_ICONS = {
    WARRIOR = "Interface\\Icons\\Ability_Warrior_OffensiveStance",  -- Battle Stance
    DRUID   = "Interface\\Icons\\Ability_Druid_Maul",              -- Caster Form (generic druid)
    PALADIN = "Interface\\Icons\\Spell_Holy_DevotionAura",         -- Devotion Aura
}

-- Dimmed alpha for "no stance" state
local NO_STANCE_ALPHA = 0.3

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

-- Current active form/stance index (0 = none)
StanceTracker.currentFormIndex = 0

-- Current stance info cache
StanceTracker.currentIcon = nil
StanceTracker.currentName = nil

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function StanceTracker:Initialize()
    if not SUPPORTED_CLASSES[addon.playerClass] then return end

    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants

    self.playerClass = addon.playerClass
    self.defaultIcon = DEFAULT_ICONS[self.playerClass]

    -- Register for stance/form changes
    self.Events:RegisterEvent(self, "UPDATE_SHAPESHIFT_FORM", self.OnShapeshiftChange)
    self.Events:RegisterEvent(self, "UPDATE_SHAPESHIFT_FORMS", self.OnShapeshiftFormsChanged)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnShapeshiftChange)

    -- Read initial state
    self:UpdateCurrentStance()

    -- Register as an icon provider — CooldownIcons dispatches sentinel-icon
    -- injection/setup/update through this interface. Initialize's class
    -- early-return means unsupported classes never register.
    addon:RegisterIconProvider({
        name = "StanceTracker",
        order = 30,
        module = self,
        IsSentinel = function(id) return self:IsStanceSentinel(id) end,
        Setup = function(frame, spellID, rowConfig, rowIndex)
            self:SetupStanceIcon(frame, spellID, rowConfig, rowIndex)
        end,
        Update = function(frame, db)
            self:UpdateStanceIconState(frame, db)
            return false  -- No countdown text
        end,
    })

    self.Utils:LogDebug("StanceTracker initialized for", self.playerClass)
end

-------------------------------------------------------------------------------
-- Event Handlers
-------------------------------------------------------------------------------

function StanceTracker:OnShapeshiftChange()
    local changed = self:UpdateCurrentStance()
    -- Only rebuild rows when the indicator is actually injected — it's hidden
    -- by default, and stance dancing shouldn't trigger rebuilds while hidden
    if changed and self:IsIndicatorInjected() then
        -- Rebuild icons so the stance icon texture updates
        self:NotifyCooldownIcons()
    end
end

-- Form count changes (learning a new stance/form) alter injection eligibility,
-- so always rebuild regardless of indicator visibility.
function StanceTracker:OnShapeshiftFormsChanged()
    self:UpdateCurrentStance()
    self:NotifyCooldownIcons()
end

-------------------------------------------------------------------------------
-- State Management
-------------------------------------------------------------------------------

function StanceTracker:UpdateCurrentStance()
    local oldIndex = self.currentFormIndex
    local newIndex = GetShapeshiftForm() or 0

    self.currentFormIndex = newIndex

    if newIndex > 0 and newIndex <= (GetNumShapeshiftForms() or 0) then
        local icon, _, _, spellID = GetShapeshiftFormInfo(newIndex)
        -- Use spell-specific icon when available (druid stance bar returns generic textures)
        self.currentIcon = (spellID and GetSpellTexture(spellID)) or icon
        self.currentName = spellID and GetSpellInfo(spellID) or nil
    else
        self.currentIcon = nil
        self.currentName = nil
    end

    return oldIndex ~= newIndex
end

-------------------------------------------------------------------------------
-- Public API (called by CooldownIcons — parallels TrinketTracker/TotemTracker)
-------------------------------------------------------------------------------

--- Check if an ID is the stance sentinel
function StanceTracker:IsStanceSentinel(id)
    return self.C and id == self.C.STANCE_INDICATOR
end

--- Get display label for the sentinel
function StanceTracker:GetSentinelLabel()
    if self.playerClass == "WARRIOR" then
        return L["Stance"]
    elseif self.playerClass == "DRUID" then
        return L["Form"]
    elseif self.playerClass == "PALADIN" then
        return L["Aura"]
    end
    return L["Stance"]
end

--- Get current icon for the sentinel
function StanceTracker:GetSentinelIcon()
    return self.currentIcon or self.defaultIcon
end

--- Returns true if stance tracking is available for this class
function StanceTracker:IsActive()
    if not SUPPORTED_CLASSES[addon.playerClass] then return false end
    -- Active when the sentinel is not explicitly disabled
    local spellCfg = addon:GetSpellConfig()
    if not spellCfg then return true end
    local cfg = spellCfg[self.C.STANCE_INDICATOR]
    return not cfg or cfg.enabled ~= false
end

--- Returns true when the stance indicator is currently injected into a row.
--- Mirrors the InjectRowEntries gate: hidden by default, shown only when
--- explicitly enabled in Spell Config.
function StanceTracker:IsIndicatorInjected()
    if not self.C then return false end
    local spellCfg = addon:GetSpellConfig()
    local cfg = spellCfg and spellCfg[self.C.STANCE_INDICATOR]
    return (cfg and cfg.enabled) == true
end

--- Get the sentinel ID
function StanceTracker:GetSentinelID()
    return self.C and self.C.STANCE_INDICATOR
end

--- Get the default row for the stance sentinel
function StanceTracker:GetDefaultRow()
    return 4  -- Auxiliary row
end

-------------------------------------------------------------------------------
-- Row Injection (called by CooldownIcons:RebuildAllRows)
-------------------------------------------------------------------------------

--- Inject stance indicator entry into CooldownIcons row data.
--- Only injects when the player knows at least one stance/form/aura.
function StanceTracker:InjectRowEntries(iconsByRow, rowConfigs, spellCfg, spellAssignments)
    if not SUPPORTED_CLASSES[addon.playerClass] then return end
    if not self.C then return end
    local numForms = GetNumShapeshiftForms() or 0
    -- Druids have an implicit caster form, so 1 known form is already useful.
    -- Warriors/Paladins are always in a stance/aura, so only useful with 2+.
    local minForms = (addon.playerClass == "DRUID") and 1 or 2
    if numForms < minForms then return end

    local sentinelID = self.C.STANCE_INDICATOR
    local cfg = spellCfg[sentinelID] or {}

    -- Hidden by default: only show if user explicitly enabled it in Spell Config.
    -- (nil = default = hidden, true = explicitly enabled, false = explicitly disabled)
    if not cfg.enabled then
        spellAssignments[sentinelID] = cfg.rowIndex or 4
        return
    end

    -- Determine row: user override or default (Auxiliary = 4)
    local rowIndex = cfg.rowIndex or 4
    local rowConfig = rowConfigs[rowIndex]

    if rowConfig and rowConfig.enabled then
        if not iconsByRow[rowIndex] then
            iconsByRow[rowIndex] = {}
        end

        if #iconsByRow[rowIndex] < rowConfig.maxIcons then
            local icon = self:GetSentinelIcon()
            local label = self:GetSentinelLabel()
            table.insert(iconsByRow[rowIndex], {
                spellID = sentinelID,
                actualSpellID = sentinelID,
                spellData = {
                    tags = {},
                    icon = icon,
                    name = label,
                    cooldown = 0,
                    priority = 3000,  -- After totems (2000+)
                },
                customOrder = cfg.order,
                isStanceIndicator = true,
            })
            spellAssignments[sentinelID] = rowIndex
        end
    end
end

-------------------------------------------------------------------------------
-- Icon Setup (called by CooldownIcons:SetupIcon delegation)
-------------------------------------------------------------------------------

function StanceTracker:SetupStanceIcon(frame, sentinelID, rowConfig, rowIndex)
    frame.isStanceIndicator = true
    frame.spellID = sentinelID
    frame.actualSpellID = sentinelID
    frame.rowIndex = rowIndex or 4
    frame.spellData = {
        tags = {},
        name = self:GetSentinelLabel(),
    }

    -- Set icon texture
    local icon = self:GetSentinelIcon()
    frame.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")

    -- Configure cooldown text (OmniCC/ElvUI) based on row
    local renderer = addon:GetModule("IconRenderer")
    if renderer and frame.cooldown then
        renderer:ConfigureCooldownText(frame.cooldown, frame.rowIndex)
        frame.cooldown:SetDrawBling(false)  -- No bling for stances
    end
end

-------------------------------------------------------------------------------
-- Icon State Update (called every 0.05s by CooldownIcons delegation)
-------------------------------------------------------------------------------

function StanceTracker:UpdateStanceIconState(frame, db)
    local renderer = addon:GetModule("IconRenderer")
    local glowManager = addon:GetModule("GlowManager")

    -- Use the event-maintained stance cache instead of re-querying the
    -- shapeshift APIs every tick (UPDATE_SHAPESHIFT_FORM/FORMS and
    -- PLAYER_ENTERING_WORLD keep it fresh via UpdateCurrentStance)
    if self.currentFormIndex > 0 and self.currentIcon then
        -- ACTIVE STATE: full-color icon of current stance
        frame.icon:SetTexture(self.currentIcon)
        frame.actionableTime = 0  -- No sorting relevance

        if renderer then
            renderer:ApplyIconVisuals(frame, {
                showAuraActive = false,
                auraRemaining = 0,
                auraDuration = 0,
                stackCount = 0,
                cdRemaining = 0,
                cdDuration = 0,
                cdStartTime = 0,
                alpha = db.readyAlpha,
                desaturate = false,
                showSpinner = false,
                showText = false,
            }, db)
        end

        -- Clear any glow (stances don't glow)
        if glowManager then
            glowManager:UpdateIconGlow(frame, false, false, false)
            if frame.readyGlowActive then
                glowManager:HideReadyGlow(frame)
                frame.readyGlowActive = false
            end
        end
    else
        -- NO STANCE: dimmed default icon
        frame.icon:SetTexture(self.defaultIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
        frame.actionableTime = 0

        if renderer then
            renderer:ApplyIconVisuals(frame, {
                showAuraActive = false,
                auraRemaining = 0,
                auraDuration = 0,
                stackCount = 0,
                cdRemaining = 0,
                cdDuration = 0,
                cdStartTime = 0,
                alpha = NO_STANCE_ALPHA,
                desaturate = true,
                showSpinner = false,
                showText = false,
            }, db)
        end

        if glowManager then
            glowManager:UpdateIconGlow(frame, false, false, false)
            if frame.readyGlowActive then
                glowManager:HideReadyGlow(frame)
                frame.readyGlowActive = false
            end
        end
    end

    -- Resource display not applicable
    if frame.resourceBar then frame.resourceBar:Hide() end
    if frame.resourceFill then frame.resourceFill:Hide() end

    -- Range indicator not applicable
    if frame.rangeOverlay and frame.rangeOverlay:IsShown() then
        frame.rangeOverlay:Hide()
    end

    -- Queued highlight not applicable
    if frame.queuedHighlight and frame.queuedHighlight:IsShown() then
        frame.queuedHighlight:Hide()
    end
end

-------------------------------------------------------------------------------
-- Notify CooldownIcons
-------------------------------------------------------------------------------

function StanceTracker:NotifyCooldownIcons()
    local cooldownIcons = addon:GetModule("CooldownIcons")
    if cooldownIcons and cooldownIcons.RebuildAllRows then
        cooldownIcons:RebuildAllRows()
    end
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

function StanceTracker:Refresh()
    -- No-op: Stance icon is rendered by CooldownIcons, which rebuilds itself.
    -- State changes trigger NotifyCooldownIcons from event handlers.
end
