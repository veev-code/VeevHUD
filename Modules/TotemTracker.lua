--[[
    VeevHUD - Totem Tracker Module
    Tracks totem element state for Shamans. Renders as sentinel slot icons
    within CooldownIcons rows (like TrinketTracker).

    =====================================================================
    REQUIREMENTS
    =====================================================================

    1. Four element slots as sentinel IDs: Fire, Earth, Water, Air.
       Each appears in SpellsOptions as a draggable entry.
    2. Default to Auxiliary Row (row 4), user can drag to any row.
    3. Zero-CD totems are removed from CooldownIcons rows (managed by
       element slots).
    4. CD > 0 totems keep their cooldown icons in normal rows AND
       appear via element slots when active.
    5. Active state: full-color icon with duration countdown (spiral + text).
    6. Expired state: dimmed/desaturated icon of last-used totem.
    7. Never-cast state: slot hidden (not injected into row).
    8. Self-contained state tracking via CLEU, independent of AuraState.
    9. CooldownIcons delegates to this module for setup + state updates.

    =====================================================================
]]

local _, addon = ...

local TotemTracker = {}
addon:RegisterModule("TotemTracker", TotemTracker)

-- Cached API calls
local GetTime = GetTime
local GetTotemInfo = GetTotemInfo
local GetSpellInfo = GetSpellInfo
local UnitBuff = UnitBuff
local UnitGUID = UnitGUID

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

-- Element order matches WoW's internal slot constants:
-- FIRE_TOTEM_SLOT=1, EARTH_TOTEM_SLOT=2, WATER_TOTEM_SLOT=3, AIR_TOTEM_SLOT=4
local ELEMENT_ORDER = { "TOTEM_FIRE", "TOTEM_EARTH", "TOTEM_WATER", "TOTEM_AIR" }

-- Dimmed alpha for expired (last-used) totem slots
local EXPIRED_ALPHA = 0.3

-- Element tags to scan for in LibSpellDB
local ELEMENT_TAGS = {
    TOTEM_FIRE  = true,
    TOTEM_EARTH = true,
    TOTEM_WATER = true,
    TOTEM_AIR   = true,
}

-- Sentinel ID to element mapping
local SENTINEL_TO_ELEMENT -- initialized in Initialize() after C is available

-- Element to sentinel ID mapping
local ELEMENT_TO_SENTINEL -- initialized in Initialize()

-- Display labels for SpellsOptions
local SENTINEL_LABELS -- initialized in Initialize()

-- Default element icons (used in SpellsOptions and before first cast)
local ELEMENT_ICONS = {
    TOTEM_FIRE  = 135825,  -- Spell_Fire_SealOfFire
    TOTEM_EARTH = 136098,  -- Spell_Nature_StoneClawTotem
    TOTEM_WATER = 135861,  -- Spell_Nature_ManaTide
    TOTEM_AIR   = 136114,  -- Spell_Nature_InvisibilityTotem
}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

-- Per-element state:
--   elementState[element] = {
--     active = { spellID, expiration, duration } or nil,
--     lastUsed = { spellID, name, icon } or nil,
--   }
TotemTracker.elementState = {}

-- Spell lookup tables (built from LibSpellDB)
-- totemSpells[canonicalID] = { element, duration, name, icon, appliesBuff }
TotemTracker.totemSpells = {}
-- rankToCanonical[anyRankOrCanonicalID] = canonicalID
TotemTracker.rankToCanonical = {}
-- recallSpells[canonicalID] = true (spells with clearsTotems = true)
TotemTracker.recallSpells = {}
-- buffToElement[buffSpellID] = element (reverse lookup for range checking)
TotemTracker.buffToElement = {}

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function TotemTracker:Initialize()
    -- Shaman only
    if addon.playerClass ~= "SHAMAN" then return end

    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants
    self.LibSpellDB = addon.LibSpellDB

    local C = self.C

    -- Build sentinel lookup tables
    SENTINEL_TO_ELEMENT = {
        [C.TOTEM_SLOT_FIRE]  = "TOTEM_FIRE",
        [C.TOTEM_SLOT_EARTH] = "TOTEM_EARTH",
        [C.TOTEM_SLOT_WATER] = "TOTEM_WATER",
        [C.TOTEM_SLOT_AIR]   = "TOTEM_AIR",
    }

    ELEMENT_TO_SENTINEL = {
        TOTEM_FIRE  = C.TOTEM_SLOT_FIRE,
        TOTEM_EARTH = C.TOTEM_SLOT_EARTH,
        TOTEM_WATER = C.TOTEM_SLOT_WATER,
        TOTEM_AIR   = C.TOTEM_SLOT_AIR,
    }

    SENTINEL_LABELS = {
        [C.TOTEM_SLOT_FIRE]  = "Fire Totem",
        [C.TOTEM_SLOT_EARTH] = "Earth Totem",
        [C.TOTEM_SLOT_WATER] = "Water Totem",
        [C.TOTEM_SLOT_AIR]   = "Air Totem",
    }

    -- Initialize element state
    for _, element in ipairs(ELEMENT_ORDER) do
        self.elementState[element] = {}
    end

    -- Build totem data from LibSpellDB
    self:BuildTotemData()

    -- Register CLEU events for summon and recall tracking
    self.Events:RegisterCLEU(self, "SPELL_SUMMON", self.OnSpellSummon)
    self.Events:RegisterCLEU(self, "SPELL_CAST_SUCCESS", self.OnSpellCastSuccess)

    -- PLAYER_TOTEM_UPDATE is the reliable detection path for totem destruction.
    -- CLEU UNIT_DIED/UNIT_DESTROYED/UNIT_DISSIPATES do NOT fire for totems in TBC Anniversary.
    self.Events:RegisterEvent(self, "PLAYER_TOTEM_UPDATE", self.OnPlayerTotemUpdate)

    -- Periodic cleanup for expired totems
    self.cleanupTicker = C_Timer.NewTicker(1, function()
        self:CleanupExpired()
    end)

    self.playerGUID = UnitGUID("player")

    self.Utils:LogDebug("TotemTracker initialized")
end

-------------------------------------------------------------------------------
-- LibSpellDB Data
-------------------------------------------------------------------------------

function TotemTracker:BuildTotemData()
    if not self.LibSpellDB then return end

    wipe(self.totemSpells)
    wipe(self.rankToCanonical)
    wipe(self.recallSpells)
    wipe(self.buffToElement)

    -- Get all SHAMAN spells
    local allSpells = self.LibSpellDB:GetSpellsByClass("SHAMAN")
    if not allSpells then return end

    local count = 0
    for spellID, spellData in pairs(allSpells) do
        -- Check for totem recall spells (Totemic Call)
        if spellData.clearsTotems then
            local canonicalID = self.LibSpellDB:GetCanonicalSpellID(spellID) or spellID
            self.recallSpells[canonicalID] = true
            -- Map all ranks of recall spell
            if spellData.ranks then
                for _, rankID in ipairs(spellData.ranks) do
                    self.recallSpells[rankID] = true
                end
            end
        end

        -- Check for element-tagged totems
        local element = nil
        if spellData.tags then
            for _, tag in ipairs(spellData.tags) do
                if ELEMENT_TAGS[tag] then
                    element = tag
                    break
                end
            end
        end

        if element then
            local canonicalID = self.LibSpellDB:GetCanonicalSpellID(spellID) or spellID
            local spellName, _, spellIcon = GetSpellInfo(canonicalID)

            self.totemSpells[canonicalID] = {
                element = element,
                duration = spellData.duration or 120,
                name = spellName or spellData.name or tostring(canonicalID),
                icon = spellIcon,
                appliesBuff = spellData.appliesBuff,
            }

            -- Map canonical ID to itself
            self.rankToCanonical[canonicalID] = canonicalID

            -- Map all rank IDs to canonical
            if spellData.ranks then
                for _, rankID in ipairs(spellData.ranks) do
                    self.rankToCanonical[rankID] = canonicalID
                end
            end

            -- Build reverse buff lookup for range checking
            if spellData.appliesBuff then
                for _, buffID in ipairs(spellData.appliesBuff) do
                    self.buffToElement[buffID] = element
                end
            end

            count = count + 1
        end
    end

    self.Utils:LogInfo("TotemTracker: Built data for", count, "totems")
end

-------------------------------------------------------------------------------
-- CLEU Event Handlers
-------------------------------------------------------------------------------

function TotemTracker:OnSpellSummon(subEvent, data)
    if data.sourceGUID ~= self.playerGUID then return end

    local spellID = data.spellID
    if not spellID then return end

    -- Resolve to canonical ID
    local canonicalID = self.rankToCanonical[spellID]
    if not canonicalID then return end

    local totemInfo = self.totemSpells[canonicalID]
    if not totemInfo then return end

    local element = totemInfo.element
    local state = self.elementState[element]
    if not state then return end

    -- Set active state (use rank-specific duration when available, e.g. Searing Totem)
    local duration
    if self.LibSpellDB and self.LibSpellDB.GetSpellDuration then
        duration = self.LibSpellDB:GetSpellDuration(spellID)
    end
    duration = duration or totemInfo.duration
    state.active = {
        spellID = canonicalID,
        expiration = GetTime() + duration,
        duration = duration,
    }

    -- Update last-used (persists after expiry)
    state.lastUsed = {
        spellID = canonicalID,
        name = totemInfo.name,
        icon = totemInfo.icon,
    }

    self.Utils:LogInfo("TotemTracker: Totem placed", totemInfo.name, element, duration .. "s")

    -- Trigger CooldownIcons rebuild so never-cast slots appear
    self:NotifyCooldownIcons()
end

function TotemTracker:OnSpellCastSuccess(subEvent, data)
    if data.sourceGUID ~= self.playerGUID then return end
    if not data.spellID then return end

    -- Check for totem recall (Totemic Call)
    local canonicalID = self.rankToCanonical[data.spellID] or data.spellID
    if self.recallSpells[canonicalID] or self.recallSpells[data.spellID] then
        self:ClearAllActive()
        self.Utils:LogInfo("TotemTracker: Totem recall detected, cleared all active totems")
    end
end

function TotemTracker:OnPlayerTotemUpdate(event, slot)
    if not slot then return end

    local element = ELEMENT_ORDER[slot]
    if not element then return end

    local state = self.elementState[element]
    if not state or not state.active then return end

    local haveTotem, _, _, duration = GetTotemInfo(slot)
    if not haveTotem or duration == 0 then
        state.active = nil
        self.Utils:LogInfo("TotemTracker: Totem destroyed (PLAYER_TOTEM_UPDATE) for", element)
    end
end

-------------------------------------------------------------------------------
-- Cleanup
-------------------------------------------------------------------------------

function TotemTracker:CleanupExpired()
    local now = GetTime()

    for i, element in ipairs(ELEMENT_ORDER) do
        local state = self.elementState[element]
        if state and state.active then
            -- Check both timer expiry AND GetTotemInfo as a safety net
            local haveTotem, _, _, duration = GetTotemInfo(i)
            if (not haveTotem or duration == 0) or state.active.expiration <= now then
                state.active = nil
            end
        end
    end
end

function TotemTracker:ClearAllActive()
    for _, element in ipairs(ELEMENT_ORDER) do
        local state = self.elementState[element]
        if state then
            state.active = nil
        end
    end
end

-------------------------------------------------------------------------------
-- Range Checking
-------------------------------------------------------------------------------

-- Scan player buffs and return a set of active buff spell IDs
function TotemTracker:ScanPlayerBuffs()
    local activeBuffs = self._activeBuffs or {}
    wipe(activeBuffs)
    self._activeBuffs = activeBuffs

    for i = 1, 40 do
        local _, _, _, _, _, _, _, _, _, spellID = UnitBuff("player", i)
        if not spellID then break end
        if self.buffToElement[spellID] then
            activeBuffs[spellID] = true
        end
    end

    return activeBuffs
end

-- Check if player is in range of a specific totem (has its buff)
-- Returns true if in range, false if out of range, nil if no buff to check
function TotemTracker:IsInRange(totemInfo, activeBuffs)
    local appliesBuff = totemInfo.appliesBuff
    if not appliesBuff then return nil end  -- No buff to check (damage/utility totem)

    for _, buffID in ipairs(appliesBuff) do
        if activeBuffs[buffID] then
            return true
        end
    end

    return false
end

-------------------------------------------------------------------------------
-- Public API (called by CooldownIcons — parallels TrinketTracker pattern)
-------------------------------------------------------------------------------

--- Check if an ID is a totem sentinel
function TotemTracker:IsTotemSentinel(id)
    return SENTINEL_TO_ELEMENT and SENTINEL_TO_ELEMENT[id] ~= nil
end

--- Get element string for a sentinel ID
function TotemTracker:GetElementForSentinel(sentinelID)
    return SENTINEL_TO_ELEMENT and SENTINEL_TO_ELEMENT[sentinelID]
end

--- Get sentinel ID for an element string
function TotemTracker:GetSentinelForElement(element)
    return ELEMENT_TO_SENTINEL and ELEMENT_TO_SENTINEL[element]
end

--- Get display label for a sentinel ID
function TotemTracker:GetSentinelLabel(sentinelID)
    return SENTINEL_LABELS and SENTINEL_LABELS[sentinelID]
end

--- Get default icon for a sentinel (element placeholder or last-used)
function TotemTracker:GetSentinelIcon(sentinelID)
    local element = self:GetElementForSentinel(sentinelID)
    if not element then return nil end

    local state = self.elementState[element]
    if state and state.lastUsed and state.lastUsed.icon then
        return state.lastUsed.icon
    end

    return ELEMENT_ICONS[element]
end

--- Returns true if totem element slots are active (Shaman with at least one slot enabled)
function TotemTracker:IsActive()
    if addon.playerClass ~= "SHAMAN" then return false end
    -- Active when any totem sentinel is not explicitly disabled
    local spellCfg = addon:GetSpellConfig()
    if not spellCfg then return true end  -- No config = defaults = enabled
    for sentinelID in pairs(SENTINEL_TO_ELEMENT or {}) do
        local cfg = spellCfg[sentinelID]
        if not cfg or cfg.enabled ~= false then
            return true  -- At least one slot is enabled
        end
    end
    return false
end

--- Get the ordered list of sentinel IDs
function TotemTracker:GetSentinelIDs()
    local C = self.C
    return { C.TOTEM_SLOT_FIRE, C.TOTEM_SLOT_EARTH, C.TOTEM_SLOT_WATER, C.TOTEM_SLOT_AIR }
end

--- Get the default row for totem sentinels (for SpellsOptions)
function TotemTracker:GetDefaultRow(sentinelID)
    return 4  -- Auxiliary row
end

-------------------------------------------------------------------------------
-- Row Injection (called by CooldownIcons:RebuildAllRows)
-------------------------------------------------------------------------------

--- Inject totem element entries into CooldownIcons row data.
-- Only injects slots that have lastUsed state (never-cast slots are hidden).
function TotemTracker:InjectRowEntries(iconsByRow, rowConfigs, spellCfg, spellAssignments)
    if not SENTINEL_TO_ELEMENT then return end

    for slotIndex, element in ipairs(ELEMENT_ORDER) do
        local sentinelID = ELEMENT_TO_SENTINEL[element]
        local state = self.elementState[element]

        -- Only inject slots that have been used at least once this session
        if state and state.lastUsed then
            local cfg = spellCfg[sentinelID] or {}

            -- Skip if explicitly disabled
            if cfg.enabled == false then
                spellAssignments[sentinelID] = cfg.rowIndex or 4
            else
                -- Determine row: user override or default (Auxiliary = 4)
                local rowIndex = cfg.rowIndex or 4
                local rowConfig = rowConfigs[rowIndex]

                if rowConfig and rowConfig.enabled then
                    if not iconsByRow[rowIndex] then
                        iconsByRow[rowIndex] = {}
                    end

                    if #iconsByRow[rowIndex] < rowConfig.maxIcons then
                        local icon = state.lastUsed.icon or ELEMENT_ICONS[element]
                        table.insert(iconsByRow[rowIndex], {
                            spellID = sentinelID,
                            actualSpellID = sentinelID,
                            spellData = {
                                tags = {},
                                icon = icon,
                                name = SENTINEL_LABELS[sentinelID],
                                cooldown = 0,
                                priority = 2000 + slotIndex,  -- After trinkets (1000+)
                            },
                            customOrder = cfg.order,
                            isTotemSlot = true,
                            totemElement = element,
                        })
                        spellAssignments[sentinelID] = rowIndex
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Icon Setup (called by CooldownIcons:SetupIcon delegation)
-------------------------------------------------------------------------------

-- Note: CooldownIcons:ResetIconState(frame) is called before this method.
function TotemTracker:SetupTotemIcon(frame, sentinelID, rowConfig, rowIndex)
    local element = self:GetElementForSentinel(sentinelID)
    local state = element and self.elementState[element]

    frame.isTotemSlot = true
    frame.totemElement = element
    frame.spellID = sentinelID
    frame.actualSpellID = sentinelID
    frame.rowIndex = rowIndex or 4
    frame.spellData = {
        tags = {},
        name = SENTINEL_LABELS[sentinelID] or "Totem",
    }

    -- Set icon texture from last-used or element placeholder
    local icon
    if state and state.lastUsed then
        icon = state.lastUsed.icon
    end
    frame.icon:SetTexture(icon or ELEMENT_ICONS[element] or "Interface\\Icons\\INV_Misc_QuestionMark")

    -- Configure cooldown text (OmniCC/ElvUI) based on row
    local renderer = addon:GetModule("IconRenderer")
    if renderer and frame.cooldown then
        renderer:ConfigureCooldownText(frame.cooldown, frame.rowIndex)

        local db = addon.db.profile.icons
        local blingEnabled = addon.Database:IsRowSettingEnabled(db.cooldownBlingRows, frame.rowIndex)
        frame.cooldown:SetDrawBling(blingEnabled)
    end
end

-------------------------------------------------------------------------------
-- Icon State Update (called every 0.05s by CooldownIcons delegation)
-------------------------------------------------------------------------------

function TotemTracker:UpdateTotemIconState(frame, db)
    local element = frame.totemElement
    if not element then return end

    local state = self.elementState[element]
    if not state then return end

    local now = GetTime()
    local renderer = addon:GetModule("IconRenderer")
    local glowManager = addon:GetModule("GlowManager")

    -- Scan player buffs for range checking (cached per update cycle)
    if not self._lastBuffScanTime or (now - self._lastBuffScanTime) > 0.1 then
        self._lastBuffScanTime = now
        self:ScanPlayerBuffs()
    end
    local activeBuffs = self._activeBuffs or {}

    if state.active and state.active.expiration > now then
        -- ACTIVE STATE: full-color icon with duration countdown
        local active = state.active
        local totemInfo = self.totemSpells[active.spellID]
        if not totemInfo then return end

        -- Update icon texture (may change if a different totem was placed)
        frame.icon:SetTexture(totemInfo.icon)

        -- Range check: dim if out of range
        local inRange = self:IsInRange(totemInfo, activeBuffs)
        local alpha = (inRange == false) and EXPIRED_ALPHA or db.readyAlpha

        -- Duration tracking
        local remaining = active.expiration - now
        local startTime = active.expiration - active.duration

        -- Actionable time for dynamic sorting
        frame.actionableTime = remaining

        if renderer then
            renderer:ApplyIconVisuals(frame, {
                showAuraActive = true,
                auraRemaining = remaining,
                auraDuration = active.duration,
                auraStacks = 0,
                cdRemaining = 0,
                cdDuration = 0,
                cdStartTime = 0,
                alpha = alpha,
                desaturate = false,
                showSpinner = true,
                showText = true,
            }, db)
        end

        -- Aura glow for active totem (respects aura tracking toggle)
        if glowManager then
            local showGlow = db.showAuraTracking
            glowManager:UpdateIconGlow(frame, showGlow, showGlow, false)
        end

    elseif state.lastUsed then
        -- EXPIRED STATE: dimmed/desaturated icon of last-used totem
        frame.icon:SetTexture(state.lastUsed.icon)
        frame.actionableTime = 0

        if renderer then
            renderer:ApplyIconVisuals(frame, {
                showAuraActive = false,
                auraRemaining = 0,
                auraDuration = 0,
                auraStacks = 0,
                cdRemaining = 0,
                cdDuration = 0,
                cdStartTime = 0,
                alpha = EXPIRED_ALPHA,
                desaturate = true,
                showSpinner = false,
                showText = false,
            }, db)
        end

        -- Clear glow for expired totem
        if glowManager then
            glowManager:UpdateIconGlow(frame, false, false, false)
            if frame.readyGlowActive then
                glowManager:HideReadyGlow(frame)
                frame.readyGlowActive = false
            end
        end
    end

    -- Resource display not applicable to totems
    if frame.resourceBar then frame.resourceBar:Hide() end
    if frame.resourceFill then frame.resourceFill:Hide() end

    -- Range indicator not applicable to totems (we handle range via buff check above)
    if frame.rangeOverlay and frame.rangeOverlay:IsShown() then
        frame.rangeOverlay:Hide()
    end

    -- Queued highlight not applicable to totems
    if frame.queuedHighlight and frame.queuedHighlight:IsShown() then
        frame.queuedHighlight:Hide()
    end
end

-------------------------------------------------------------------------------
-- Notify CooldownIcons
-------------------------------------------------------------------------------

function TotemTracker:NotifyCooldownIcons()
    local cooldownIcons = addon:GetModule("CooldownIcons")
    if cooldownIcons and cooldownIcons.RebuildAllRows then
        cooldownIcons:RebuildAllRows()
    end
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

function TotemTracker:Refresh()
    -- No-op: Totem slots are rendered by CooldownIcons, which rebuilds itself.
    -- State changes (summon/destroy) trigger NotifyCooldownIcons from event handlers.
end
