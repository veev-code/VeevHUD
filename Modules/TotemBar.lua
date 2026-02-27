--[[
    VeevHUD - Totem Bar Module
    Dedicated element-slot display for Shaman totems.

    =====================================================================
    REQUIREMENTS
    =====================================================================

    1. Four dynamic element slots in fixed order: Fire, Earth, Water, Air
       (matches WoW's internal totem slot constants).
    2. Zero-CD totems (Windfury, Searing, Tremor, etc.) appear ONLY in
       element slots — they are removed from CooldownIcons rows.
    3. CD > 0 totems (Earthbind, Grounding, Fire Nova, Stoneclaw, Mana
       Tide, Elementals) keep their cooldown icons in the normal rows AND
       appear in element slots when active.
    4. Active state: full-color icon with duration countdown (spiral + text).
    5. Expired state: dimmed/desaturated icon of the last totem cast for
       that element.
    6. Never-cast state: slot is hidden (doesn't appear until first totem
       of that element is cast in the session).
    7. CD totem cooldown icons do NOT show aura active state (handled by
       CooldownIcons suppressing aura display for element-tagged totems).
    8. Layout element: positioned between Aura Tracker and Health Bar by
       default (configurable via Layout settings).
    9. Self-contained: all tracking via own CLEU registrations,
       independent of AuraState/SpellTracker.

    =====================================================================
]]

local ADDON_NAME, addon = ...

local TotemBar = {}
addon:RegisterModule("TotemBar", TotemBar)

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

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

-- Per-element state:
--   elementState[element] = {
--     active = { spellID, expiration, duration } or nil,
--     lastUsed = { spellID, name, icon } or nil,
--   }
TotemBar.elementState = {}

-- Spell lookup tables (built from LibSpellDB)
-- totemSpells[canonicalID] = { element, duration, name, icon, appliesBuff }
TotemBar.totemSpells = {}
-- rankToCanonical[anyRankOrCanonicalID] = canonicalID
TotemBar.rankToCanonical = {}
-- recallSpells[canonicalID] = true (spells with clearsTotems = true)
TotemBar.recallSpells = {}
-- buffToElement[buffSpellID] = element (reverse lookup for range checking)
TotemBar.buffToElement = {}

-- UI frames
TotemBar.slots = {}       -- element -> Button frame
TotemBar.container = nil

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function TotemBar:Initialize()
    -- Shaman only
    if addon.playerClass ~= "SHAMAN" then return end

    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants
    self.LibSpellDB = addon.LibSpellDB

    -- Initialize element state
    for _, element in ipairs(ELEMENT_ORDER) do
        self.elementState[element] = {}
    end

    -- Build totem data from LibSpellDB
    self:BuildTotemData()

    -- Register with layout system
    addon.Layout:RegisterElement("totemBar", self)

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

    self.Utils:LogDebug("TotemBar initialized")
end

-------------------------------------------------------------------------------
-- LibSpellDB Data
-------------------------------------------------------------------------------

function TotemBar:BuildTotemData()
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

    self.Utils:LogInfo("TotemBar: Built data for", count, "totems")
end

-------------------------------------------------------------------------------
-- CLEU Event Handlers
-------------------------------------------------------------------------------

function TotemBar:OnSpellSummon(subEvent, data)
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

    self.Utils:LogInfo("TotemBar: Totem placed", totemInfo.name, element, duration .. "s")

    -- Force UI update
    self:UpdateAllSlots()
    addon.Layout:Refresh()
end

function TotemBar:OnSpellCastSuccess(subEvent, data)
    if data.sourceGUID ~= self.playerGUID then return end
    if not data.spellID then return end

    -- Check for totem recall (Totemic Call)
    local canonicalID = self.rankToCanonical[data.spellID] or data.spellID
    if self.recallSpells[canonicalID] or self.recallSpells[data.spellID] then
        self:ClearAllActive()
        self.Utils:LogInfo("TotemBar: Totem recall detected, cleared all active totems")
    end
end

function TotemBar:OnPlayerTotemUpdate(event, slot)
    if not slot then return end

    local element = ELEMENT_ORDER[slot]
    if not element then return end

    local state = self.elementState[element]
    if not state or not state.active then return end

    local haveTotem, _, _, duration = GetTotemInfo(slot)
    if not haveTotem or duration == 0 then
        state.active = nil
        self.Utils:LogInfo("TotemBar: Totem destroyed (PLAYER_TOTEM_UPDATE) for", element)
        self:UpdateAllSlots()
        addon.Layout:Refresh()
    end
end

-------------------------------------------------------------------------------
-- Cleanup
-------------------------------------------------------------------------------

function TotemBar:CleanupExpired()
    local now = GetTime()
    local changed = false

    for i, element in ipairs(ELEMENT_ORDER) do
        local state = self.elementState[element]
        if state and state.active then
            -- Check both timer expiry AND GetTotemInfo as a safety net
            local haveTotem, _, _, duration = GetTotemInfo(i)
            if (not haveTotem or duration == 0) or state.active.expiration <= now then
                state.active = nil
                changed = true
            end
        end
    end

    if changed then
        self:UpdateAllSlots()
        addon.Layout:Refresh()
    end
end

function TotemBar:ClearAllActive()
    for _, element in ipairs(ELEMENT_ORDER) do
        local state = self.elementState[element]
        if state then
            state.active = nil
        end
    end
    self:UpdateAllSlots()
    addon.Layout:Refresh()
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

-- Returns true if the TotemBar is active and managing totem display
function TotemBar:IsActive()
    if addon.playerClass ~= "SHAMAN" then return false end
    local db = addon.db and addon.db.profile and addon.db.profile.totemBar
    return db and db.enabled
end

-------------------------------------------------------------------------------
-- Layout System Integration
-------------------------------------------------------------------------------

function TotemBar:GetLayoutHeight()
    if not self:IsActive() then return 0 end
    if not self.container then return 0 end

    -- Check if any slot is visible (has lastUsed data)
    local anyVisible = false
    for _, element in ipairs(ELEMENT_ORDER) do
        local state = self.elementState[element]
        if state and state.lastUsed then
            anyVisible = true
            break
        end
    end

    if not anyVisible then return 0 end

    local db = addon.db.profile.totemBar
    local _, iconHeight = self.Utils:GetIconDimensions(db.iconSize, db.iconAspectRatio)
    return iconHeight
end

function TotemBar:SetLayoutPosition(centerY)
    if not self.container then return end
    self.container:ClearAllPoints()
    self.container:SetPoint("CENTER", self.container:GetParent(), "CENTER", 0, centerY)
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function TotemBar:CreateFrames(parent)
    if addon.playerClass ~= "SHAMAN" then return end

    local db = addon.db.profile.totemBar
    if not db.enabled then return end

    local iconSize = db.iconSize
    local iconWidth, iconHeight = self.Utils:GetIconDimensions(iconSize, db.iconAspectRatio)
    local spacing = db.iconSpacing

    -- Container frame
    local container = CreateFrame("Frame", nil, parent)
    container:SetPoint("CENTER", parent, "CENTER", 0, 0)  -- Temporary; layout will reposition
    container:EnableMouse(false)
    self.container = container

    -- Size container for 4 slots (will resize dynamically based on visible count)
    local totalWidth = (4 * iconWidth) + (3 * spacing)
    container:SetSize(totalWidth, iconHeight)

    -- Create 4 element slot frames
    for i, element in ipairs(ELEMENT_ORDER) do
        self.slots[element] = self:CreateSlotFrame(container, element, i, iconWidth, iconHeight, spacing, db)
    end

    -- Register update ticker
    self.Events:RegisterUpdate(self, 0.1, self.UpdateAllSlots)

    self.Utils:LogDebug("TotemBar: Frames created")
end

function TotemBar:CreateSlotFrame(parent, element, index, iconWidth, iconHeight, spacing, db)
    local frame = CreateFrame("Button", nil, parent)
    frame:SetSize(iconWidth, iconHeight)
    frame:EnableMouse(false)
    frame.element = element

    -- Border (BACKGROUND layer)
    local border = frame:CreateTexture(nil, "BACKGROUND")
    border:SetTexture([[Interface\Buttons\WHITE8X8]])
    border:SetVertexColor(0, 0, 0, 1)
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    frame.border = border

    -- Icon texture (ARTWORK layer)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    frame.icon = icon

    -- Apply texcoords with zoom
    local zoomPerEdge = addon.db.profile.icons.iconZoom / 2
    local left, right, top, bottom = self.Utils:GetIconTexCoords(zoomPerEdge, addon.db.profile.totemBar.iconAspectRatio)
    icon:SetTexCoord(left, right, top, bottom)

    -- Cooldown spiral for duration
    local cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    cooldown:SetAllPoints(icon)
    cooldown:SetDrawEdge(false)
    cooldown:SetDrawBling(false)
    cooldown:SetDrawSwipe(true)
    cooldown:SetSwipeColor(0, 0, 0, 0.8)
    cooldown:SetReverse(true)  -- Fills as time passes
    cooldown:Hide()
    frame.cooldown = cooldown

    -- Hide external cooldown text (OmniCC, ElvUI)
    self.Utils:ConfigureCooldownText(cooldown, true)

    -- Text container (above cooldown)
    local textContainer = CreateFrame("Frame", nil, frame)
    textContainer:SetAllPoints(frame)
    textContainer:SetFrameLevel(frame:GetFrameLevel() + 10)

    -- Duration text (center)
    local fontSize = math.max(10, math.floor(db.iconSize * 0.38))
    local text = textContainer:CreateFontString(nil, "OVERLAY", nil, 7)
    text:SetFont(addon:GetFont(), fontSize, "OUTLINE")
    text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    text:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)
    frame.text = text

    -- Apply built-in icon styling
    addon.IconStyling:Apply(frame, db.iconSize, db.iconAspectRatio)

    -- Start hidden (never-cast state)
    frame:Hide()

    return frame
end

-------------------------------------------------------------------------------
-- Range Checking
-------------------------------------------------------------------------------

-- Scan player buffs and return a set of active buff spell IDs
function TotemBar:ScanPlayerBuffs()
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
function TotemBar:IsInRange(totemInfo, activeBuffs)
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
-- State Display
-------------------------------------------------------------------------------

function TotemBar:UpdateAllSlots()
    if not self.container then return end
    if not self:IsActive() then return end

    local db = addon.db.profile.totemBar
    local now = GetTime()

    -- Scan player buffs once for range checking
    local activeBuffs = self:ScanPlayerBuffs()

    for _, element in ipairs(ELEMENT_ORDER) do
        local frame = self.slots[element]
        local state = self.elementState[element]

        if not frame or not state then
            -- No frame or state for this element
        elseif state.active and state.active.expiration > now then
            -- ACTIVE STATE: icon with duration countdown
            local active = state.active
            local totemInfo = self.totemSpells[active.spellID]
            if totemInfo then
                frame.icon:SetTexture(totemInfo.icon)
                frame:Show()

                -- Range check: dim if out of range but keep timer running
                local inRange = self:IsInRange(totemInfo, activeBuffs)
                if inRange == false then
                    -- Out of range: dimmed but timer still visible
                    frame.icon:SetDesaturated(false)
                    frame:SetAlpha(EXPIRED_ALPHA)
                else
                    -- In range (or no buff to check): full brightness
                    frame.icon:SetDesaturated(false)
                    frame:SetAlpha(1)
                end

                -- Duration text
                local remaining = active.expiration - now
                if remaining > 0 then
                    frame.text:SetText(self.Utils:FormatCooldown(remaining))
                else
                    frame.text:SetText("")
                end

                -- Cooldown spiral
                local startTime = active.expiration - active.duration
                if frame.lastStart ~= startTime or frame.lastDuration ~= active.duration then
                    frame.cooldown:SetCooldown(startTime, active.duration)
                    frame.lastStart = startTime
                    frame.lastDuration = active.duration
                end
                frame.cooldown:Show()
            end

        elseif state.lastUsed then
            -- EXPIRED STATE: Dimmed/desaturated icon of last-used totem
            frame.icon:SetTexture(state.lastUsed.icon)
            frame.icon:SetDesaturated(true)
            frame:SetAlpha(EXPIRED_ALPHA)
            frame:Show()
            frame.text:SetText("")
            frame.cooldown:Hide()
            frame.lastStart = nil
            frame.lastDuration = nil

        else
            -- NEVER-CAST STATE: Hide slot entirely
            frame:Hide()
            frame.text:SetText("")
            frame.cooldown:Hide()
            frame.lastStart = nil
            frame.lastDuration = nil
        end
    end

    -- Reposition visible slots (center horizontally)
    self:RepositionSlots()
end

function TotemBar:RepositionSlots()
    if not self.container then return end

    local db = addon.db.profile.totemBar
    local iconWidth, iconHeight = self.Utils:GetIconDimensions(db.iconSize, db.iconAspectRatio)
    local spacing = db.iconSpacing

    -- Collect visible slots
    local visible = {}
    for _, element in ipairs(ELEMENT_ORDER) do
        local frame = self.slots[element]
        if frame and frame:IsShown() then
            table.insert(visible, frame)
        end
    end

    if #visible == 0 then return end

    -- Calculate total width and center offsets
    local totalWidth = (#visible * iconWidth) + ((#visible - 1) * spacing)
    self.container:SetSize(totalWidth, iconHeight)

    for i, frame in ipairs(visible) do
        local xOffset = (i - 1) * (iconWidth + spacing) - (totalWidth / 2) + (iconWidth / 2)
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", self.container, "CENTER", xOffset, 0)
    end
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

function TotemBar:Refresh()
    if addon.playerClass ~= "SHAMAN" then return end

    local db = addon.db.profile.totemBar

    -- Create frames if needed
    if not self.container and db.enabled and addon.hudFrame then
        self:CreateFrames(addon.hudFrame)
    end

    if self.container then
        -- Toggle visibility
        if db.enabled then
            self.container:Show()
        else
            self.container:Hide()
        end

        -- Update icon sizes
        local iconWidth, iconHeight = self.Utils:GetIconDimensions(db.iconSize, db.iconAspectRatio)
        local zoomPerEdge = addon.db.profile.icons.iconZoom / 2
        local left, right, top, bottom = self.Utils:GetIconTexCoords(zoomPerEdge, db.iconAspectRatio)

        for _, element in ipairs(ELEMENT_ORDER) do
            local frame = self.slots[element]
            if frame then
                frame:SetSize(iconWidth, iconHeight)
                if frame.icon then
                    frame.icon:SetTexCoord(left, right, top, bottom)
                end
                -- Update built-in style
                addon.IconStyling:Update(frame, db.iconSize, false, db.iconAspectRatio)
            end
        end
    end

    self:UpdateAllSlots()
    addon.Layout:Refresh()
end

function TotemBar:RefreshFonts(fontPath)
    local db = addon.db.profile.totemBar
    local fontSize = math.max(10, math.floor(db.iconSize * 0.38))
    local tc = addon.db.profile.appearance.textColor

    for _, element in ipairs(ELEMENT_ORDER) do
        local frame = self.slots[element]
        if frame and frame.text then
            frame.text:SetFont(fontPath, fontSize, "OUTLINE")
            frame.text:SetTextColor(tc.r, tc.g, tc.b)
        end
    end
end
