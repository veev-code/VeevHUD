--[[
    VeevHUD - Cooldown Icons Module
    Displays tracked spells organized in category rows
    
    Design:
    - All tracked spells are always visible
    - Ready spells: 100% alpha
    - On cooldown: 30% alpha with cooldown spiral
    - No resources: desaturated (like default action bars)
]]

--[[
    Ready Glow Requirements
    =======================
    The ready glow is a proc-style animated glow that signals when an ability
    is about to become (or has just become) usable. See UpdateReadyGlow().

    R1. Usability gate
        The glow only shows when ALL of these are true:
        - The spell is coming off cooldown (within the anticipation threshold)
          OR has just become usable while off cooldown.
        - The spell is usable per WoW's IsUsableSpell (stance, conditions, etc.).
        - The player can afford it (canAfford — the addon's own resource check,
          since WoW's API is unreliable for resources during cooldowns).

    R3. Combat: start-only gate
        The glow may only START while in combat. Leaving combat does NOT
        terminate an active glow — it runs until its configured duration expires
        or the player can no longer afford the spell.

    R4. Reactive abilities always re-trigger
        Reactive abilities (Execute, Overpower, etc.) always use "always" mode
        regardless of the Re-trigger row setting. They re-glow every time they
        become usable. Dodge-reactive procs (Overpower) go further: the glow is
        level-triggered, showing the entire time the dodge window is usable
        (dodgeWindowUsable: can afford + current lockout ends before the window
        expires) rather than firing on usability edges. Re-procs that refresh
        an active window produce no usability transition, so edge detection
        alone would miss them.

    R5. Once-mode behavior
        When Re-trigger is disabled for a row, the glow plays only once per
        cooldown cycle. If an ability becomes ready outside of combat, no glow
        is shown, and re-entering combat does NOT retroactively trigger it.

    R6. Dim interaction
        When "dim on cooldown" is active for a row, the dim and desaturation are
        lifted while the ready glow is showing. Uses frame.readyGlowActive
        (previous frame's state) as a single source of truth — no duplicated
        condition logic between the dim system and the glow system.

    R7. Configurable anticipation
        The "almost ready" threshold is configurable via db.readyGlowThreshold
        (default 0.5s, range 0–2.0s, "Anticipation" slider in Options).
        Controls how early the glow triggers before cooldown completion.

    R8. Aura suppression
        When a spell's aura (buff/debuff) is active, the ready glow is
        suppressed — the aura has its own glow. wasUsable is preserved during
        aura display to prevent false "just became usable" re-triggers when the
        aura ends.

    R9. Early cancellation on resource loss
        If an active glow is running and the player can no longer afford the
        spell (e.g., spent rage on another ability), the glow cancels
        immediately rather than running to expiry.

    R10. Lockout anticipation
        When an ability lockout (e.g., Weakened Soul, or a school lockout from
        an interrupt) is the limiting factor and nearly expired, the glow treats
        the spell as usable for anticipation purposes. WoW's API reports
        isUsable=false during lockouts, but we override this when the lockout
        has less than the anticipation threshold remaining and the player can
        afford the spell.

    R11. Cooldown reset clears tracking
        When an ability goes on cooldown (i.e., is cast), readyGlowShown resets.
        This allows the glow to trigger fresh on the next cooldown cycle.
]]

local _, addon = ...
local C = addon.Constants

-- Localized WoW API functions (hot path)
local GetTime = GetTime
local GetSpellInfo = GetSpellInfo
local UnitExists = UnitExists
local IsCurrentSpell = IsCurrentSpell
local UnitGUID = UnitGUID

local CooldownIcons = {}
addon:RegisterModule("CooldownIcons", CooldownIcons)

-- Row containers
CooldownIcons.rows = {}

-- Icon pool per row
CooldownIcons.iconsByRow = {}

-- Spell to row assignment cache
CooldownIcons.spellAssignments = {}

-- Feral druid form tracking (session state, default to cat)
CooldownIcons.activeFeralForm = "CAT"

-- Masque support
CooldownIcons.Masque = nil
CooldownIcons.MasqueGroups = {}  -- Per-row Masque groups: [rowIndex] = MSQ:Group()

-- Tick gating: skip the 0.05s ticker when no icons have active timers.
-- Events (SPELL_UPDATE_COOLDOWN, UNIT_POWER_UPDATE, etc.) call UpdateAllIcons()
-- directly for state changes; the ticker only exists for smooth timer text countdown.
CooldownIcons._hasActiveTimers = true  -- Conservative default; recalculated each UpdateAllIcons

-- Reusable table for ApplyIconVisuals (avoids per-icon per-tick allocation)
local visualState = {}

-- Per-icon error isolation: throttled error tracking to avoid chat spam
local iconErrorCounts = {}
local ICON_ERROR_LOG_LIMIT = 3  -- Only log first N errors per spell per session

local function iconErrorHandler(err)
    return tostring(err) .. "\n" .. debugstack(2, 5, 0)
end



-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function CooldownIcons:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants
    self.Animations = addon.Animations

    -- Cache rendering layer module references
    self.renderer = addon:GetModule("IconRenderer")
    self.glowManager = addon:GetModule("GlowManager")

    -- Cache state engine module reference (state production / game state queries)
    self.stateEngine = addon:GetModule("IconStateEngine")

    -- Cache spell assignment module reference (spell-to-row logic)
    self.spellAssignment = addon:GetModule("SpellAssignment")

    -- Cache aura state module reference (target context + aura queries)
    self.auraState = addon:GetModule("AuraState")

    -- Cache icon frame factory reference (frame construction)
    self.iconFactory = addon:GetModule("IconFrameFactory")

    -- Cache totem tracker reference (RebuildAllRows context + totem aura suppression)
    self.totemTracker = addon:GetModule("TotemTracker")

    -- Icon providers (trinkets, totems, stance, consumables) registered
    -- themselves during their Initialize, which MODULE_ORDER runs before
    -- ours. All sentinel-icon dispatch goes through this sorted list —
    -- adding a new sentinel type is one registration, not a 4-site edit.
    self.iconProviders = addon.iconProviders
    table.sort(self.iconProviders, function(a, b) return a.order < b.order end)

    -- Initialize Masque support if available
    self:InitializeMasque()

    -- Share Masque availability with GlowManager
    if self.Masque and self.glowManager then
        self.glowManager:SetMasqueEnabled(true)
    end

    -- Check LibCustomGlow availability (shared via Utils)
    if self.Utils:GetLibCustomGlow() then
        self.Utils:LogInfo("LibCustomGlow support enabled")
    end

    -- Register for updates
    self.Events:RegisterEvent(self, "SPELL_UPDATE_COOLDOWN", self.OnSpellUpdate)
    self.Events:RegisterEvent(self, "SPELL_UPDATE_USABLE", self.OnSpellUpdate)
    self.Events:RegisterEvent(self, "UNIT_POWER_UPDATE", self.OnPowerUpdate)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)

    -- Subscribe to overlay state changes from GlowManager (decoupled via addon event bus)
    self.Events:RegisterAddonEvent(self, "OVERLAY_STATE_CHANGED", function()
        self:UpdateAllIcons()
    end)

    -- Subscribe to aura state changes from AuraState (decoupled via addon event bus)
    self.Events:RegisterAddonEvent(self, "AURA_STATE_CHANGED", function()
        self:UpdateAllIcons()
    end)

    -- Register for spell cast events (for cast feedback animation)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_SUCCEEDED", self.OnSpellCastSucceeded)
    
    -- Register for target changes (for target lockout debuff tracking like PWS/Weakened Soul)
    self.Events:RegisterEvent(self, "PLAYER_TARGET_CHANGED", self.OnSpellUpdate)
    self.Events:RegisterEvent(self, "UNIT_TARGET", self.OnUnitTarget)
    
    -- Register for range check updates (throttled by RangeChecker module)
    if addon.RangeChecker then
        addon.RangeChecker:RegisterCallback(self, self.OnRangeUpdate)
    end

    -- Register for reactive window refresh events (e.g., PARTY_KILL refreshes Victory Rush)
    self.Events:RegisterCLEU(self, "PARTY_KILL", self.OnReactiveWindowEvent)

    -- Register for dodge detection (Overpower dodge-reactive glow)
    self.Events:RegisterCLEU(self, "SWING_MISSED", self.OnCombatMissEvent)
    self.Events:RegisterCLEU(self, "SPELL_MISSED", self.OnCombatMissEvent)

    -- Register for queued spell changes (Heroic Strike, Cleave, Maul, etc.)
    -- CURRENT_SPELL_CAST_CHANGED fires when a spell's "current" status changes
    -- Uses a lightweight handler that only toggles highlight textures (no full icon recompute)
    self.Events:RegisterEvent(self, "CURRENT_SPELL_CAST_CHANGED", self.OnCurrentSpellChanged)

    -- Register for action bar and keybind changes (for keybind text display)
    self.Events:RegisterEvent(self, "ACTIONBAR_SLOT_CHANGED", self.OnActionBarChanged)
    self.Events:RegisterEvent(self, "UPDATE_BINDINGS", self.OnBindingsChanged)
    self.Events:RegisterEvent(self, "UPDATE_MACROS", self.OnActionBarChanged)
    self.Events:RegisterEvent(self, "ACTIONBAR_PAGE_CHANGED", self.OnActionBarChanged)
    self.Events:RegisterEvent(self, "ACTIONBAR_SHOWGRID", self.OnActionBarChanged)
    self.Events:RegisterEvent(self, "ACTIONBAR_HIDEGRID", self.OnActionBarChanged)

    -- Feral druid form tracking: rebuild rows when switching between cat/bear
    if addon.playerClass == self.C.CLASS.DRUID then
        self.Events:RegisterEvent(self, "UPDATE_SHAPESHIFT_FORM", self.OnShapeshiftFormChanged)
    end

    self.Utils:LogInfo("CooldownIcons initialized")
end

function CooldownIcons:InitializeMasque()
    local MSQ = LibStub and LibStub("Masque", true)
    if MSQ then
        self.Masque = MSQ
        local rowConfigs = addon.Constants.DEFAULTS.profile.rows
        for rowIndex, rowConfig in ipairs(rowConfigs) do
            self.MasqueGroups[rowIndex] = MSQ:Group("VeevHUD", rowConfig.name)
        end
        self.Utils:LogInfo("Masque support enabled - per-row groups created")
    else
        self.Utils:LogDebug("Masque not found, using built-in Classic Enhanced style")
    end
end

function CooldownIcons:OnPlayerEnteringWorld()
    C_Timer.After(2, function()
        addon.Keybinds:ClearCache()
        self:RebuildAllRows()
        self:UpdateAllIcons()
        self:UpdateAllKeybindText()
    end)

    C_Timer.After(5, function()
        addon.Keybinds:ClearCache()
        self:UpdateAllKeybindText()
    end)
end

function CooldownIcons:OnShapeshiftFormChanged()
    local form = self.C.GetDruidForm()
    local newFeralForm
    if form == "CAT" then
        newFeralForm = "CAT"
    elseif form == "BEAR" then
        newFeralForm = "BEAR"
    end
    -- Only update if switching between cat/bear (ignore caster/travel/aquatic)
    if newFeralForm and newFeralForm ~= self.activeFeralForm then
        self.activeFeralForm = newFeralForm
        self.Utils:LogDebug("CooldownIcons: Feral form changed to", newFeralForm)
        self:RebuildAllRows()
        self:UpdateAllIcons()
        self:RepositionRows()
        self:RefreshIconPositions()
    end
end

function CooldownIcons:OnSpellUpdate()
    self:UpdateAllIcons()
end

function CooldownIcons:OnPowerUpdate(event, unit)
    if unit == "player" then
        self:UpdateAllIcons()
    end
end

function CooldownIcons:OnUnitTarget(event, unit)
    -- Update when target's target changes (for targettarget lockout tracking)
    if unit == "target" then
        self:UpdateAllIcons()
    end
end

function CooldownIcons:OnRangeUpdate()
    -- Called by RangeChecker on throttled interval (0.1s) or target change
    -- RangeChecker already handles target existence check
    local db = addon.db.profile.icons
    local showRangeOn = db.showRangeIndicator
    
    -- Skip if range indicator is completely disabled
    if showRangeOn == "none" then
        return
    end
    
    self:UpdateAllRangeIndicators()
end

function CooldownIcons:OnActionBarChanged(event, slot)
    -- Action bar slot changed - clear keybind cache and update
    addon.Keybinds:ClearCache()
    self:UpdateAllKeybindText()
end

function CooldownIcons:OnBindingsChanged()
    -- Keybindings changed - clear cache and update
    addon.Keybinds:ClearCache()
    self:UpdateAllKeybindText()
end

-- Lightweight handler for CURRENT_SPELL_CAST_CHANGED
-- Only toggles queued highlight textures — no full icon state recompute
function CooldownIcons:OnCurrentSpellChanged()
    if not IsCurrentSpell then return end
    local showQueued = addon.db.profile.icons.showQueuedHighlight
    for rowIndex, rowFrame in pairs(self.rows or {}) do
        if rowFrame then
            for _, frame in ipairs(rowFrame.icons) do
                if frame.queuedHighlight and frame.actualSpellID then
                    local isQueued = showQueued and IsCurrentSpell(frame.actualSpellID)
                    if isQueued then
                        if not frame.queuedHighlight:IsShown() then
                            frame.queuedHighlight:Show()
                        end
                    else
                        if frame.queuedHighlight:IsShown() then
                            frame.queuedHighlight:Hide()
                        end
                    end
                end
            end
        end
    end
end

function CooldownIcons:OnSpellCastSucceeded(event, unit, castGUID, spellID)
    if unit ~= "player" then return end

    -- Find the icon frame for this spell
    local frame = self:FindIconFrameBySpellID(spellID)

    -- Fallback: on-use trinket spell IDs don't match sentinel IDs
    if not frame then
        frame = self:FindIconFrameByOnUseSpellID(spellID)
    end

    if frame then
        self.renderer:PlayCastFeedback(frame)

        -- Clear reactive window timer immediately on cast (e.g., Victory Rush used)
        -- Note: do NOT reset reactiveWindowWasUsable here — the API may still report
        -- isUsable=true for a tick after cast, which would cause a false timer restart.
        -- Kill-refreshes are handled by OnReactiveWindowEvent (PARTY_KILL) instead.
        if frame.reactiveWindow and frame.reactiveWindowExpires then
            frame.reactiveWindowStart = nil
            frame.reactiveWindowExpires = nil
        end

        -- Start timed effect countdown on cast (Flamestrike, Distract, Consecration)
        if frame.timedEffectDuration then
            local now = GetTime()
            frame.timedEffectStart = now
            frame.timedEffectExpires = now + frame.timedEffectDuration
            -- A countdown just started: wake the gated ticker to render it
            self._hasActiveTimers = true
        end
    end

    -- Check if this spell is part of a shared cooldown group
    -- If so, and it's not the displayed spell, set an override to show this spell's buff
    self:HandleSharedCooldownCast(spellID)

    -- Check if this spell belongs to an exclusive BuffGroup (e.g., warlock curses)
    -- If so, swap the icon to show the actually-used ability
    self:HandleExclusiveGroupCast(spellID)
end

-- Handle CLEU events that refresh reactive windows (e.g., PARTY_KILL refreshes Victory Rush)
-- Scans visible icons for matching reactiveWindowEvent and resets their timer
-- Gates on IsSpellUsable so non-qualifying kills are ignored (e.g., grey mobs don't grant VR).
-- Limitation: if the window is already active, IsSpellUsable is true regardless of kill quality,
-- so a grey mob kill during an active window will incorrectly refresh the timer. There is no API
-- to distinguish "kill yielded xp/honor" from "kill didn't", so this is the best we can do.
function CooldownIcons:OnReactiveWindowEvent(subEvent, data)
    if data.sourceGUID ~= addon.playerGUID then return end

    local windowStarted = false
    for _, row in ipairs(self.rows or {}) do
        for _, frame in ipairs(row.icons or {}) do
            if frame.reactiveWindowEvent == subEvent and frame.reactiveWindow then
                local actualSpellID = frame.actualSpellID or frame.spellID
                if self.stateEngine:IsSpellUsable(actualSpellID) then
                    frame.reactiveWindowStart = GetTime()
                    frame.reactiveWindowExpires = GetTime() + frame.reactiveWindow
                    windowStarted = true
                end
            end
        end
    end

    -- A countdown just started: make sure the gated ticker is awake to render it
    if windowStarted then
        self._hasActiveTimers = true
    end
end

-- Handle CLEU miss events for dodge-reactive abilities (e.g., Overpower)
-- When the player's attack is dodged, records which target dodged and when.
-- This enables a stance-independent ready glow so the player knows to swap stance and use Overpower.
-- Target-specific: WW dodged by off-target → tab to that target → glow appears.
function CooldownIcons:OnCombatMissEvent(subEvent, data)
    if data.sourceGUID ~= addon.playerGUID then return end

    -- missType is the first suffix argument for both SWING_MISSED and SPELL_MISSED
    local missType = data.s1

    if missType ~= "DODGE" then return end

    -- Get dodge window duration from any dodge-reactive frame
    local dodgeDuration
    for _, row in ipairs(self.rows or {}) do
        for _, frame in ipairs(row.icons or {}) do
            if frame.dodgeReactive then
                dodgeDuration = frame.dodgeReactive
                break
            end
        end
        if dodgeDuration then break end
    end

    if dodgeDuration then
        self.stateEngine:RecordDodge(data.destGUID, GetTime() + dodgeDuration)
    end
end

-- Handle when a shared cooldown spell is cast that isn't the displayed one
-- Simply swap the icon to show the actually-used ability (buff + cooldown)
function CooldownIcons:HandleSharedCooldownCast(castSpellID)
    local LibSpellDB = addon.LibSpellDB
    if not LibSpellDB then return end

    local groupName, groupInfo = LibSpellDB:GetSharedCooldownGroup(castSpellID)
    if not groupName or not groupInfo then return end

    -- Persist so the icon survives /reload (per-spec via specKey)
    local currentOverride = addon.Database:GetSharedCooldownOverride(groupName)
    if currentOverride ~= castSpellID then
        addon.Database:SetSharedCooldownOverride(groupName, castSpellID)
    end

    -- Find if we have an icon tracking any spell from this group
    for _, rowFrame in ipairs(self.rows or {}) do
        if rowFrame.icons then
            for _, iconFrame in ipairs(rowFrame.icons) do
                if iconFrame:IsShown() and iconFrame.spellID then
                    -- Check if this icon's spell is in the same shared CD group
                    local iconGroup = LibSpellDB:GetSharedCooldownGroup(iconFrame.spellID)
                    if iconGroup == groupName and iconFrame.spellID ~= castSpellID then
                        -- Different spell from same group was cast!
                        -- Swap the icon to show the used ability instead
                        local castSpellData = LibSpellDB:GetSpellInfo(castSpellID)
                        if castSpellData then
                            -- Update icon to the cast spell (permanent swap)
                            local texture = castSpellData.icon or self.Utils:GetSpellTexture(castSpellID)
                            iconFrame.icon:SetTexture(texture)
                            iconFrame.spellID = castSpellID
                            iconFrame.spellData = castSpellData
                            self.Utils:Debug("SharedCD swap: now showing", castSpellID, "instead of original")
                        end
                    end
                end
            end
        end
    end
end

-- Handle when an exclusive BuffGroup spell is cast that isn't the displayed one.
-- Mirrors HandleSharedCooldownCast: swap the icon to show the actually-used ability.
-- E.g., icon shows Curse of Agony but player casts Curse of Elements → swap to CoE.
function CooldownIcons:HandleExclusiveGroupCast(castSpellID)
    local LibSpellDB = addon.LibSpellDB
    if not LibSpellDB then return end

    -- Resolve the cast spell (may be a rank ID) to its canonical data and BuffGroup
    local castSpellData = LibSpellDB:GetSpellInfo(castSpellID)
    if not castSpellData then return end

    local groupName, groupInfo = LibSpellDB:GetBuffGroup(castSpellData.spellID)
    if not groupName or not groupInfo or groupInfo.relationship ~= "exclusive" then return end

    local castCanonicalID = castSpellData.spellID
    local castAuraTarget = LibSpellDB:GetAuraTarget(castCanonicalID) or "self"

    -- Find if we have an icon tracking a different spell from this group (same auraTarget).
    -- Only swap within the same auraTarget — e.g., don't swap an ally Earth Shield icon
    -- when the player casts a self Water Shield (they track different units).
    for _, rowFrame in ipairs(self.rows or {}) do
        if rowFrame.icons then
            for _, iconFrame in ipairs(rowFrame.icons) do
                if iconFrame:IsShown() and iconFrame.spellID then
                    local iconGroup = LibSpellDB:GetBuffGroupRelationship(iconFrame.spellID) == "exclusive"
                        and select(1, LibSpellDB:GetBuffGroup(iconFrame.spellID))
                    local iconAuraTarget = LibSpellDB:GetAuraTarget(iconFrame.spellID) or "self"
                    if iconGroup == groupName and iconAuraTarget == castAuraTarget and iconFrame.spellID ~= castCanonicalID then
                        -- Different spell from same exclusive group was cast — swap the icon
                        local texture = castSpellData.icon or self.Utils:GetSpellTexture(castSpellID)
                        iconFrame.icon:SetTexture(texture)
                        iconFrame.spellID = castCanonicalID
                        iconFrame.actualSpellID = castSpellID  -- Rank ID for WoW API calls
                        iconFrame.spellData = castSpellData
                        self.renderer:PlayCastFeedback(iconFrame)
                        self.Utils:Debug("ExclusiveGroup swap: now showing", castCanonicalID, "instead of original")
                        return
                    end
                end
            end
        end
    end
end


-- Find icon frame by spell ID (checks ranks too)
function CooldownIcons:FindIconFrameBySpellID(spellID)
    local LibSpellDB = addon.LibSpellDB
    local canonicalID = LibSpellDB and LibSpellDB:GetCanonicalSpellID(spellID) or spellID
    
    for _, rowFrame in ipairs(self.rows or {}) do
        if rowFrame.icons then
            for _, iconFrame in ipairs(rowFrame.icons) do
                if iconFrame.spellID == canonicalID or iconFrame.spellID == spellID then
                    return iconFrame
                end
                -- Check ranks
                if iconFrame.spellData and iconFrame.spellData.ranks then
                    for _, rankID in ipairs(iconFrame.spellData.ranks) do
                        if rankID == spellID then
                            return iconFrame
                        end
                    end
                end
            end
        end
    end
    return nil
end

--- Find an icon frame by its trinket on-use spell ID (cast feedback routing).
-- Owned here (not in TrinketTracker) — iterating row/icon internals is this
-- module's business.
function CooldownIcons:FindIconFrameByOnUseSpellID(spellID)
    for _, rowFrame in ipairs(self.rows or {}) do
        if rowFrame.icons then
            for _, iconFrame in ipairs(rowFrame.icons) do
                if iconFrame.onUseSpellID and iconFrame.onUseSpellID == spellID then
                    return iconFrame
                end
            end
        end
    end
    return nil
end

--- Find an icon frame by sentinel spell ID (used for trinket proc pop animation).
function CooldownIcons:FindIconFrameBySentinel(sentinelID)
    for _, rowFrame in ipairs(self.rows or {}) do
        if rowFrame.icons then
            for _, iconFrame in ipairs(rowFrame.icons) do
                if iconFrame.spellID == sentinelID then
                    return iconFrame
                end
            end
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function CooldownIcons:CreateFrames(parent)
    local db = addon.db and addon.db.profile and addon.db.profile.icons

    if not db then 
        self.Utils:LogInfo("CooldownIcons: no config")
        return 
    end

    -- Main container for all rows (transparent parent frame for organizational purposes).
    -- Row frames are children of the container but positioned absolutely by Layout.lua.
    local container = CreateFrame("Frame", "VeevHUDIconContainer", parent)
    container:SetSize(400, 800)
    container:SetPoint("CENTER", parent, "CENTER", 0, 0)
    container:EnableMouse(false)  -- Click-through
    self.container = container

    self.Utils:LogInfo("CooldownIcons: Container created")

    -- Create row frames
    local success, err = pcall(function()
        self:CreateRowFrames()
    end)
    if not success then
        self.Utils:LogError("CooldownIcons: CreateRowFrames failed:", err)
    end

    -- Apply texcoords after all icons are created (handles Masque compositing)
    self:ApplyIconTexCoords()

    -- Start update ticker (gated — skips when no icons have active timers)
    self.Events:RegisterUpdate(self, 0.05, self.OnUpdateTick)
end

-- Apply texcoords to all icons based on current aspect ratio and zoom settings.
-- When Masque is active, reads Masque's texcoords and applies VeevHUD zoom on top
-- (WeakAuras-style compositing so both the Masque skin and VeevHUD's iconZoom coexist).
function CooldownIcons:ApplyIconTexCoords()
    local iconDb = addon.db.profile.icons
    local rowConfigs = addon.db.profile.rows
    for rowIndex, rowFrame in ipairs(self.rows or {}) do
        if rowFrame.icons then
            local rowConfig = rowConfigs[rowIndex] or {}
            local aspectRatio = rowConfig.iconAspectRatio or iconDb.iconAspectRatio
            self.iconFactory:ApplyTexCoords(rowFrame.icons, iconDb.iconZoom, aspectRatio, self.MasqueGroups[rowIndex])
        end
    end
end

function CooldownIcons:CreateRowFrames()
    local rowConfigs = addon.db and addon.db.profile and addon.db.profile.rows
    local iconDb = addon.db and addon.db.profile and addon.db.profile.icons
    
    if not rowConfigs then
        self.Utils:LogError("CooldownIcons: No rows config found")
        return
    end
    if not iconDb then
        self.Utils:LogError("CooldownIcons: No icons config found")
        return
    end
    
    self.Utils:LogInfo("CooldownIcons: Creating", #rowConfigs, "row frames")

    -- Row frames are created for ALL configured rows, including disabled ones
    -- (they stay hidden with zero layout height). A row disabled at startup
    -- must still get a frame so self.rows stays dense — ipairs traversals
    -- (Refresh, font updates, swap handlers, ...) would otherwise stop at the
    -- hole — and so the row can be re-enabled live from Options.
    for rowIndex, rowConfig in ipairs(rowConfigs) do
        -- Use per-row settings or fall back to global
        local rowIconSize = rowConfig.iconSize or iconDb.iconSize
        -- Use explicit nil check since 0 is a valid spacing value
        local rowIconSpacing = rowConfig.iconSpacing
        if rowIconSpacing == nil then
            rowIconSpacing = iconDb.iconSpacing
        end

        -- Get width/height based on aspect ratio (per-row override or global fallback)
        local rowAspectRatio = rowConfig.iconAspectRatio or iconDb.iconAspectRatio
        local rowIconWidth, rowIconHeight = self.Utils:GetIconDimensions(rowIconSize, rowAspectRatio)

        self.Utils:LogInfo("Row", rowIndex, rowConfig.name, "iconSize:", rowIconSize, "iconWidth:", rowIconWidth, "maxIcons:", rowConfig.maxIcons)

        local rowFrame = CreateFrame("Frame", nil, self.container)
        rowFrame:SetSize(rowConfig.maxIcons * (rowIconWidth + rowIconSpacing), rowIconHeight)
        rowFrame:SetPoint("TOP", addon.hudFrame, "CENTER", 0, 0)  -- Placeholder; Layout will position
        rowFrame:EnableMouse(false)  -- Click-through
        rowFrame.iconSize = rowIconSize
        rowFrame.iconWidth = rowIconWidth
        rowFrame.iconHeight = rowIconHeight
        rowFrame.iconSpacing = rowIconSpacing
        rowFrame.iconsPerRow = rowConfig.iconsPerRow or rowConfig.maxIcons
        rowFrame.flowLayout = rowConfig.flowLayout

        rowFrame.config = rowConfig
        rowFrame.icons = {}

        -- Pre-create icon frames for this row
        local rowMasqueGroup = self.MasqueGroups[rowIndex]
        for i = 1, rowConfig.maxIcons do
            local icon = self.iconFactory:CreateIconFrame(rowFrame, i, rowIconSize)
            if rowMasqueGroup then
                self.iconFactory:RegisterWithMasque(icon, rowMasqueGroup)
            else
                self.iconFactory:ApplyFallbackStyle(icon, rowIconSize, rowAspectRatio)
            end
            icon:Hide()
            rowFrame.icons[i] = icon
        end

        -- Create slide animator for dynamic sort animations (shared driver, composes with punch)
        rowFrame.slideAnimator = self.Animations:CreateSlideAnimator(rowFrame, 20)

        self.rows[rowIndex] = rowFrame
        self.iconsByRow[rowIndex] = {}
    end

    -- Register each icon row with the Layout system
    self:RegisterRowsWithLayout()
end

-------------------------------------------------------------------------------
-- Layout Integration
-------------------------------------------------------------------------------

-- Map row indices to layout element keys
local ROW_LAYOUT_KEYS = { "primaryRow", "secondaryRow", "utilityRow", "auxiliaryRow" }

-- Register all icon rows as layout elements
function CooldownIcons:RegisterRowsWithLayout()
    for rowIndex, key in ipairs(ROW_LAYOUT_KEYS) do
        local ri = rowIndex  -- capture for closure
        addon.Layout:RegisterRowElement(key,
            function() return self:GetRowHeight(ri) end,
            function(topY) self:SetRowPosition(ri, topY) end
        )
    end
end

-- Get the pixel height of an icon row (accounting for flow-wrap).
-- Returns 0 if the row is disabled, not created, or has no icons.
function CooldownIcons:GetRowHeight(rowIndex)
    local rowFrame = self.rows and self.rows[rowIndex]
    if not rowFrame then return 0 end

    local rowConfig = addon.db.profile.rows[rowIndex]
    if not rowConfig or not rowConfig.enabled then return 0 end

    local iconHeight = rowFrame.iconHeight or rowFrame.iconSize
    local actualIconCount = self.iconsByRow[rowIndex] and #self.iconsByRow[rowIndex] or 0

    if actualIconCount == 0 then return 0 end

    if rowFrame.flowLayout and rowFrame.iconsPerRow and actualIconCount > 0 then
        local actualRows = math.ceil(actualIconCount / rowFrame.iconsPerRow)
        local rowSpacing = addon.db.profile.icons.rowSpacing
        return actualRows * (iconHeight + rowSpacing) - rowSpacing
    end

    return iconHeight
end

-- Position an icon row at the given Y offset (top edge, relative to hudFrame center).
function CooldownIcons:SetRowPosition(rowIndex, topY)
    local rowFrame = self.rows and self.rows[rowIndex]
    if not rowFrame then return end

    rowFrame:ClearAllPoints()
    rowFrame:SetPoint("TOP", addon.hudFrame, "CENTER", 0, topY)
end


-------------------------------------------------------------------------------
-- Spell Assignment to Rows
-------------------------------------------------------------------------------

function CooldownIcons:OnTrackedSpellsChanged()
    self:RebuildAllRows()
    self:UpdateAllIcons()
    -- Ensure rows are repositioned after icon count changes
    -- (RebuildAllRows already calls this, but call again to be safe after UpdateAllIcons)
    self:RepositionRows()
    -- Force icon repositioning within rows after row frames are repositioned
    self:RefreshIconPositions()
end

-- Force all icons to be repositioned within their row frames
-- Called after RepositionRows to ensure icons are in correct positions
function CooldownIcons:RefreshIconPositions()
    local db = addon.db.profile.icons
    for rowIndex, rowFrame in pairs(self.rows or {}) do
        if rowFrame then
            local spells = self.iconsByRow[rowIndex] or {}
            local iconCount = #spells
            if iconCount > 0 then
                self:PositionRowIcons(rowFrame, iconCount, db)
            end
        end
    end
end


-- Get the default row for a spell based on tag matching (used by SpellsOptions)
function CooldownIcons:GetDefaultRowForSpell(spellID)
    local LibSpellDB = addon.LibSpellDB
    if not LibSpellDB then return nil end
    
    -- Also check if this spell is spec-relevant
    if not LibSpellDB:IsSpellRelevantForSpec(spellID) then
        return nil  -- Not relevant for current spec
    end
    
    local rowConfigs = addon.db.profile.rows
    
    -- Check all rows (including disabled) to find the spell's natural home.
    -- This is used by the Spell Config UI to show correct row assignments.
    for rowIndex, rowConfig in ipairs(rowConfigs) do
        for _, requiredTag in ipairs(rowConfig.tags) do
            if LibSpellDB:HasTag(spellID, requiredTag) then
                return rowIndex
            end
        end
    end
    
    return nil  -- No matching row tags
end

-- Get spell config override for a specific spell
function CooldownIcons:GetSpellConfig(spellID)
    return addon:GetSpellConfigForSpell(spellID)
end

function CooldownIcons:RebuildAllRows()
    local tracker = addon:GetModule("SpellTracker")
    if not tracker then
        self.Utils:LogError("CooldownIcons: SpellTracker not found")
        return
    end

    local trackedSpells = tracker:GetTrackedSpells()
    if not addon.LibSpellDB then
        self.Utils:LogError("CooldownIcons: LibSpellDB not found")
        return
    end

    -- Invalidate the per-frame update memo: assignments are about to change,
    -- so the next UpdateAllIcons must run even if one already ran this frame.
    self._lastUpdateTime = nil

    -- Reset dynamic sort animation state before rebuilding
    self:ResetDynamicSortPositions()

    local spellCount = 0
    for _ in pairs(trackedSpells) do spellCount = spellCount + 1 end
    self.Utils:LogInfo("CooldownIcons: Rebuilding with", spellCount, "tracked spells")

    -- Build runtime context for assignment
    local context = {
        isDruid = addon.playerClass == "DRUID",
        activeFeralForm = self.activeFeralForm,
        totemBarActive = self.totemTracker and self.totemTracker.IsActive and self.totemTracker:IsActive(),
    }

    -- Delegate spell-to-row assignment to SpellAssignment module
    local rowConfigs = addon.db.profile.rows
    local spellCfg = addon:GetSpellConfig()
    local iconsByRow, spellAssignments = self.spellAssignment:AssignAllSpells(
        trackedSpells, rowConfigs, spellCfg, context)

    self.iconsByRow = iconsByRow
    self.spellAssignments = spellAssignments

    -- Inject sentinel entries via the icon-provider registry (trinkets,
    -- totems, stance indicator, consumables). All are injected after
    -- AssignAllSpells sorts, so a re-sort is needed for customOrder
    -- overrides like user-configured position to apply.
    local injected = false
    for _, provider in ipairs(self.iconProviders) do
        if not provider.ShouldInject or provider.ShouldInject() then
            provider.module:InjectRowEntries(self.iconsByRow, rowConfigs, spellCfg, self.spellAssignments)
            injected = true
        end
    end
    if injected then
        self.spellAssignment:_SortRowSpells(self.iconsByRow)
    end

    -- Update icons to show assigned spells
    self:UpdateRowIcons()

    -- Reposition rows based on actual icon counts (important for flow layout rows)
    self:RepositionRows()

    self.Utils:LogInfo("CooldownIcons: Rebuilt rows")
    for rowIndex, spells in pairs(self.iconsByRow) do
        if #spells > 0 then
            local rowConfig = rowConfigs[rowIndex]
            self.Utils:LogDebug("  Row", rowIndex, "(" .. (rowConfig and rowConfig.name or "?") .. "):", #spells, "spells")
        end
    end
end

-- Reposition row frames based on actual icon counts.
-- Delegates to Layout:Refresh() which queries GetRowHeight() and calls SetRowPosition().
function CooldownIcons:RepositionRows()
    if not self.rows then return end

    -- Update row frame heights for icons positioned correctly within each row
    for rowIndex, rowFrame in pairs(self.rows) do
        if rowFrame then
            local iconHeight = rowFrame.iconHeight or rowFrame.iconSize
            rowFrame:SetHeight(iconHeight)
        end
    end

    -- Let the unified layout system handle all vertical positioning
    addon.Layout:Refresh()
end

function CooldownIcons:UpdateRowIcons()
    local db = addon.db.profile.icons
    local rowConfigs = addon.db.profile.rows

    for rowIndex, rowFrame in pairs(self.rows) do
        if rowFrame then
            local spells = self.iconsByRow[rowIndex] or {}
            local iconCount = #spells
            
            -- Get row config for per-row settings
            local rowConfig = rowConfigs[rowIndex]

            -- Position and show icons for this row
            for i, iconFrame in ipairs(rowFrame.icons) do
                local shouldShow = i <= iconCount
                
                if shouldShow then
                    local spellInfo = spells[i]
                    self:SetupIcon(iconFrame, spellInfo.spellID, spellInfo.actualSpellID, spellInfo.spellData, rowConfig, rowIndex)
                    -- Store default sort order for stable sorting when using dynamic sort
                    iconFrame.defaultSortOrder = spellInfo.customOrder or spellInfo.defaultOrder or i
                    iconFrame:SetAlpha(iconFrame.iconAlpha or 1)
                    iconFrame:Show()
                else
                    iconFrame:Hide()
                    iconFrame.defaultSortOrder = nil
                end
            end

            -- Center the icons in the row
            self:PositionRowIcons(rowFrame, iconCount, db)
        end
    end
end

function CooldownIcons:PositionRowIcons(rowFrame, count, db)
    if count == 0 then
        rowFrame:Hide()
        return
    end

    rowFrame:Show()

    -- Use per-row settings (set during creation)
    local size = rowFrame.iconSize or db.iconSize
    local iconWidth = rowFrame.iconWidth or size
    local iconHeight = rowFrame.iconHeight or size
    -- Use explicit nil check since 0 is a valid spacing value
    local spacing = rowFrame.iconSpacing
    if spacing == nil then
        spacing = db.iconSpacing
    end
    local iconsPerRow = rowFrame.iconsPerRow or count  -- Default to all on one row
    local flowLayout = rowFrame.flowLayout or false
    local rowSpacing = db.rowSpacing  -- Vertical spacing between wrapped rows

    if flowLayout then
        -- Flow layout rows always use TOP anchor for consistency
        -- This ensures position doesn't jump when transitioning between 1 row and multiple rows
        if count > iconsPerRow then
            -- Multi-row flow layout
            self:PositionFlowLayout(rowFrame, count, iconWidth, iconHeight, spacing, iconsPerRow, rowSpacing)
        else
            -- Single row but still flow layout - use TOP anchor like multi-row
            local totalWidth = count * iconWidth + (count - 1) * spacing
            local startX = -totalWidth / 2 + iconWidth / 2

            for i = 1, count do
                local frame = rowFrame.icons[i]
                if frame and frame:IsShown() then
                    local x = startX + (i - 1) * (iconWidth + spacing)
                    frame:ClearAllPoints()
                    frame:SetPoint("TOP", rowFrame, "TOP", x, 0)
                    self.Animations:UpdatePunchBase(frame)
                end
            end
        end
    else
        -- Non-flow rows: delegate to slide animator (same centering math,
        -- initializes _slideCurrentX for smooth first dynamic sort transition,
        -- and composes with punch animation automatically)
        local animator = rowFrame.slideAnimator
        if animator then
            local visibleIcons = {}
            for i = 1, count do
                local frame = rowFrame.icons[i]
                if frame and frame:IsShown() then
                    visibleIcons[#visibleIcons + 1] = frame
                end
            end
            animator:LayoutFrames(visibleIcons, iconWidth, spacing, false)
        end
    end
end

function CooldownIcons:PositionFlowLayout(rowFrame, count, iconWidth, iconHeight, spacing, iconsPerRow, rowSpacing)
    -- Enforce minimum of 2 icons per row for flow layout to work properly
    if iconsPerRow < 2 then iconsPerRow = 2 end
    
    -- Calculate how many rows we need
    local numRows = math.ceil(count / iconsPerRow)
    
    -- Use rowSpacing for vertical gap between wrapped rows
    local verticalSpacing = rowSpacing
    local rowHeight = iconHeight + verticalSpacing
    
    -- Build row distribution: fill from top, last row gets the remainder
    local rowIconCounts = {}
    local remaining = count
    for r = 1, numRows do
        local iconsThisRow = math.min(iconsPerRow, remaining)
        rowIconCounts[r] = iconsThisRow
        remaining = remaining - iconsThisRow
    end
    
    -- Ensure last row has at least ceil(iconsPerRow/2) icons to avoid sparse trailing rows
    -- Steal the deficit from the second-to-last row, but keep it >= last row (top-heavy)
    if numRows > 1 then
        local minLastRow = math.ceil(iconsPerRow / 2)
        local lastRow = rowIconCounts[numRows]
        local prevRow = rowIconCounts[numRows - 1]
        if lastRow < minLastRow then
            local deficit = minLastRow - lastRow
            -- Only steal as much as keeps the previous row >= the new last row
            local maxSteal = prevRow - minLastRow
            if maxSteal < 0 then maxSteal = 0 end
            local steal = math.min(deficit, maxSteal)
            if steal > 0 then
                rowIconCounts[numRows - 1] = prevRow - steal
                rowIconCounts[numRows] = lastRow + steal
            end
        end
    end
    
    local iconIndex = 1
    for row = 1, numRows do
        local iconsThisRow = rowIconCounts[row] or 0
        local rowWidth = iconsThisRow * iconWidth + (iconsThisRow - 1) * spacing
        local startX = -rowWidth / 2 + iconWidth / 2
        local yOffset = -(row - 1) * rowHeight
        
        for col = 1, iconsThisRow do
            local frame = rowFrame.icons[iconIndex]
            if frame and frame:IsShown() then
                local x = startX + (col - 1) * (iconWidth + spacing)
                frame:ClearAllPoints()
                frame:SetPoint("TOP", rowFrame, "TOP", x, yOffset)
                self.Animations:UpdatePunchBase(frame)
            end
            iconIndex = iconIndex + 1
        end
    end
    
    -- Update row frame height to accommodate all rows
    rowFrame:SetHeight(numRows * rowHeight)
end

-------------------------------------------------------------------------------
-- Icon Setup and Updates
-------------------------------------------------------------------------------

--- Reset all runtime state on an icon frame.
-- Called before every SetupIcon to ensure a clean slate when frames are reused
-- across RebuildAllRows calls (e.g., a frame that was a trinket is now a spell).
-- Each field is grouped by the system that writes it.
--
-- SYNC CONTRACT: Any module that writes frame.X during update/setup MUST have
-- a corresponding reset here. Writers:
--   CooldownIcons  (SetupIcon)          — identity/routing fields
--   IconStateEngine (_Compute* methods) — cooldown cache, prediction, reactive
--   IconRenderer    (ApplyIconVisuals, UpdateResourceDisplay) — renderer cache, resource display
--   GlowManager     (Show/HideGlow/ReadyGlow) — glow tracking flags
--   Animations      (TransitionAlpha)   — alpha transition
--   TrinketTracker  (SetupTrinketIcon)  — trinket identity (isTrinket, trinketSlotID, onUseSpellID)
--   TotemTracker     (SetupTotemIcon)    — totem identity (isTotemSlot, totemElement)
--   StanceTracker    (SetupStanceIcon)  — stance identity (isStanceIndicator)
--
-- NOT reset (intentionally):
--   Structural children (icon, cooldown, text, charges, stacks) — created once by IconFrameFactory
--   Slide positions (_slideCurrentX, _slideTargetX) — reset by ResetDynamicSortPositions()
function CooldownIcons:ResetIconState(frame)
    -- Identity / routing (prevents stale provider delegation)
    frame._iconProvider = nil
    frame.isTrinket = false
    frame.trinketSlotID = nil
    frame.onUseSpellID = nil
    frame.isTotemSlot = false
    frame.totemElement = nil
    frame.isStanceIndicator = false
    frame.isConsumable = false
    frame.consumableItemID = nil

    -- Clear stale visual text from previous assignment
    if frame.stacks then frame.stacks:SetText("") end

    -- Cooldown cache (IconStateEngine:_ComputeCooldownState)
    frame.itemCdStart = nil
    frame.itemCdDuration = nil
    frame.actionBarSlot = nil
    frame.actionBarSlotNextScan = nil
    frame.itemWasAvailable = nil
    frame.actualCdStart = nil
    frame.actualCdDuration = nil

    -- Resource prediction (IconStateEngine:_ComputePredictionState)
    frame.predictionActive = false
    frame.predictionStartTime = nil
    frame.predictionDuration = nil
    frame.predictionFallback = false
    frame.predictionLastPower = nil
    frame.gcdContinueText = nil

    -- Reactive window (IconStateEngine:_ComputeCooldownState)
    frame.reactiveWindowStart = nil
    frame.reactiveWindowExpires = nil
    frame.reactiveWindowWasUsable = nil

    -- Timed effect (IconStateEngine:_ComputeVisualFlags)
    frame.timedEffectStart = nil
    frame.timedEffectExpires = nil

    -- Dynamic sort
    frame.actionableTime = nil

    -- Glow tracking (GlowManager) — hide visuals then clear flags
    if frame.readyGlowActive and self.glowManager then
        self.glowManager:HideReadyGlow(frame)
    end
    if frame.glowActive and self.glowManager then
        self.glowManager:HideGlow(frame)
    end
    frame.readyGlowShown = nil
    frame.readyGlowExpires = nil
    frame.readyGlowActive = false
    frame.readyGlowSoundPlayed = nil
    frame.wasOnRealCooldown = nil
    frame.wasUsable = nil
    frame.lastCooldownDuration = nil
    frame.glowActive = false
    frame.glowType = nil
    frame.glowAlpha = nil

    -- Renderer cache (IconRenderer)
    frame.lastCdStart = nil
    frame.lastCdDuration = nil
    frame._wasRealCooldown = nil
    frame._lastCastFeedbackTime = nil
    frame._textBucket = nil
    if frame.text then frame.text:SetText("") end
    frame.iconAlpha = nil
    if frame._dimTimer then
        frame._dimTimer:Cancel()
        frame._dimTimer = nil
    end
    if frame.cooldown then
        frame.cooldown:SetCooldown(0, 0)
    end

    -- Resource display cache (IconRenderer:UpdateResourceDisplay)
    frame.resourceTarget = nil
    frame.resourceCurrent = nil
    frame.resourcePowerColor = nil
    frame.resourceIconSize = nil
    frame.resourceIconWidth = nil
    frame.resourceIconHeight = nil
    frame.resourceDisplayMode = nil

    -- Alpha transition (Animations)
    if addon.Animations then
        addon.Animations:StopAlphaTransition(frame)
    end

    -- Range indicator
    frame.rangeWantShow = nil
    if frame.rangeFrame then
        frame.rangeFrame.fadeIn:Stop()
        frame.rangeFrame.fadeOut:Stop()
        frame.rangeFrame:SetAlpha(0)
        frame.rangeFrame:Hide()
    end
end

function CooldownIcons:SetupIcon(frame, spellID, actualSpellID, spellData, rowConfig, rowIndex)
    -- Reset all runtime state from previous spell assignment
    self:ResetIconState(frame)

    -- Sentinel icons (trinkets, totems, stance, consumables): delegate setup
    -- to the owning provider and remember it for per-tick update dispatch
    for _, provider in ipairs(self.iconProviders) do
        if provider.IsSentinel(spellID) then
            frame._iconProvider = provider
            provider.Setup(frame, spellID, rowConfig, rowIndex)
            return
        end
    end

    -- If the player previously used a different spell from this shared CD group
    -- (e.g., Arms warrior uses Recklessness instead of Retaliation), swap at setup time
    local overrideSpellID, overrideData = addon.Database:ResolveSharedCooldownOverride(spellID)
    if overrideSpellID then
        spellID = overrideSpellID
        actualSpellID = overrideSpellID
        spellData = overrideData
        self.Utils:Debug("SharedCD override: showing", spellID)
    end

    -- spellID = canonical ID for identification and tag lookups
    -- actualSpellID = the actual rank ID the player knows (for WoW API calls)
    local texture = spellData.icon or self.Utils:GetSpellTexture(actualSpellID or spellID)
    frame.icon:SetTexture(texture)
    frame.spellID = spellID  -- Canonical ID
    frame.actualSpellID = actualSpellID or spellID  -- For GetSpellCooldown, etc.
    frame.spellData = spellData
    frame.rowIndex = rowIndex or 1
    -- dimOnCooldown is now determined dynamically in UpdateIcon based on global setting
    
    -- Configure external cooldown text (OmniCC, ElvUI) based on row assignment
    -- This allows OmniCC to show text on rows where VeevHUD doesn't
    if frame.cooldown then
        self.renderer:ConfigureCooldownText(frame.cooldown, frame.rowIndex)
        
        -- Configure bling effect per-row
        local db = addon.db.profile.icons
        local blingEnabled = addon.Database:IsRowSettingEnabled(db.cooldownBlingRows, frame.rowIndex)
        frame.cooldown:SetDrawBling(blingEnabled)
    end
    
    -- Check if this is a reactive spell (Execute, Revenge, Overpower)
    -- These allow repeated ready glows based on condition changes (e.g., target HP)
    -- Also check if this is an element-tagged totem (for TotemTracker aura suppression)
    frame.isReactive = false
    frame.isTotem = false
    if spellData.tags then
        for _, tag in ipairs(spellData.tags) do
            if tag == "REACTIVE" then
                frame.isReactive = true
            elseif tag == "TOTEM_EARTH" or tag == "TOTEM_FIRE" or tag == "TOTEM_WATER" or tag == "TOTEM_AIR" then
                frame.isTotem = true
            end
        end
    end

    -- Check if this reactive spell has a timed usability window (e.g., Victory Rush: 20s after kill)
    -- When non-nil, we show a synthetic aura countdown when the spell becomes usable
    frame.reactiveWindow = nil
    frame.reactiveWindowEvent = nil
    if frame.isReactive and addon.LibSpellDB then
        frame.reactiveWindow = addon.LibSpellDB:GetReactiveWindow(spellID)
        if frame.reactiveWindow then
            local spellInfo = addon.LibSpellDB:GetSpellInfo(spellID)
            frame.reactiveWindowEvent = spellInfo and spellInfo.reactiveWindowEvent
        end
    end

    -- Check if this spell is a timed effect (e.g., Flamestrike 8s ground fire, Distract 10s)
    -- When set, OnSpellCastSucceeded starts a synthetic aura countdown using the spell's duration
    frame.timedEffectDuration = nil
    if addon.LibSpellDB and addon.LibSpellDB:IsTimedEffect(spellID) then
        frame.timedEffectDuration = spellData.duration
    end

    -- Cache reagent info for usability + stack count (IsUsableSpell doesn't check reagents in Classic)
    -- reagentItemID: current rank's reagent (for default count + usability)
    -- reagentAllItemIDs: all ranks' reagents (for "count all ranks" option + usability fallback)
    frame.reagentItemID = addon.LibSpellDB and addon.LibSpellDB:GetReagentItemID(actualSpellID or spellID) or nil
    frame.reagentAllItemIDs = addon.LibSpellDB and addon.LibSpellDB:GetAllReagentItemIDs(spellID) or nil

    -- Check if this spell has dodge-reactive glow (e.g., Overpower)
    -- When set, CLEU dodge detection stores per-target windows in stateEngine.dodgeWindows for stance-independent glow
    frame.dodgeReactive = nil
    if addon.LibSpellDB then
        frame.dodgeReactive = addon.LibSpellDB:GetDodgeReactive(spellID)
    end

    -- Update keybind text for this icon
    self:UpdateKeybindText(frame)
end

-------------------------------------------------------------------------------
-- Keybind Text Display
-------------------------------------------------------------------------------

-- Update keybind text for a single icon
function CooldownIcons:UpdateKeybindText(frame)
    local db = addon.db.profile.icons
    addon.Keybinds:UpdateKeybindText(frame, db.showKeybindText)
end

-- Update keybind text for all visible icons
function CooldownIcons:UpdateAllKeybindText()
    if not self.rows then return end
    
    for rowIndex, rowFrame in pairs(self.rows) do
        if rowFrame and rowFrame.icons then
            for _, iconFrame in ipairs(rowFrame.icons) do
                if iconFrame:IsShown() and iconFrame.spellID then
                    self:UpdateKeybindText(iconFrame)
                end
            end
        end
    end
end

-- Ticker-only entry point with idle gating.
-- The 0.05s ticker calls this; event handlers call UpdateAllIcons() directly.
function CooldownIcons:OnUpdateTick()
    if not self._hasActiveTimers then return end
    -- Skip the full pipeline while the HUD is hidden (flight paths, hidden
    -- out of combat). Events still call UpdateAllIcons directly, and the
    -- next tick after re-show resumes normal updates.
    if addon.hudFrame and not addon.hudFrame:IsVisible() then return end
    self:UpdateAllIcons()
end

function CooldownIcons:UpdateAllIcons()
    if not self.rows then return end

    -- Coalesce to one full recompute per frame: cooldown/usability/power
    -- events, aura notifications, and the ticker can all request an update in
    -- the same frame (GetTime() is frame-constant). When skipping, force the
    -- ticker back on so state changed by this caller is recomputed next tick.
    local now = GetTime()
    if self._lastUpdateTime == now then
        self._hasActiveTimers = true
        return
    end
    self._lastUpdateTime = now

    self.stateEngine:SetTime(now)
    local db = addon.db.profile.icons

    -- Cache target context once for all aura checks this cycle
    local auraTracker = self.auraState
    if auraTracker and auraTracker.CacheTargetContext then
        auraTracker:CacheTargetContext()
    end

    local hasActiveTimers = false

    for rowIndex, rowFrame in pairs(self.rows) do
        if rowFrame then
            for _, iconFrame in ipairs(rowFrame.icons) do
                if iconFrame:IsShown() and iconFrame.spellID then
                    local ok, result = xpcall(self.UpdateIconState, iconErrorHandler, self, iconFrame, db)
                    if ok then
                        if result then hasActiveTimers = true end
                    else
                        -- Per-icon error isolation: log throttled, continue to next icon
                        local sid = iconFrame.spellID or 0
                        iconErrorCounts[sid] = (iconErrorCounts[sid] or 0) + 1
                        if iconErrorCounts[sid] <= ICON_ERROR_LOG_LIMIT then
                            self.Utils:LogError("UpdateIconState error [spell " .. tostring(sid) .. "]:", result)
                        end
                        hasActiveTimers = true  -- Keep ticking to allow retry
                    end
                end
            end
        end
    end

    -- Apply dynamic sorting to configured rows
    local dynamicSortRows = db.dynamicSortRows
    if dynamicSortRows ~= "none" then
        self:ApplyDynamicSorting(dynamicSortRows)
    end

    -- Update tick gating flag: skip future ticker calls when no timers are active
    -- Check if any row's slide animator is still running
    if not hasActiveTimers then
        for _, rowFrame in pairs(self.rows) do
            if rowFrame and rowFrame.slideAnimator and rowFrame.slideAnimator.running then
                hasActiveTimers = true
                break
            end
        end
    end
    self._hasActiveTimers = hasActiveTimers
end

-- Determine which rows should have dynamic sorting based on setting
function CooldownIcons:ShouldDynamicSortRow(rowIndex, dynamicSortRows)
    return addon.Database:IsRowSettingEnabled(dynamicSortRows, rowIndex)
end

-- Apply dynamic sorting to all configured rows
function CooldownIcons:ApplyDynamicSorting(dynamicSortRows)
    for rowIndex, rowFrame in pairs(self.rows) do
        if rowFrame and self:ShouldDynamicSortRow(rowIndex, dynamicSortRows) then
            self:SortRowByTimeRemaining(rowFrame, rowIndex)
        end
    end
end

-------------------------------------------------------------------------------
-- Dynamic Sorting by Time Remaining
-------------------------------------------------------------------------------

-- Reusable tables for sorting (avoids GC pressure from allocating every frame)
-- Per-row caches to support multi-row dynamic sorting
local dynamicSortCache = {}
local previousSortOrder = {}  -- previousSortOrder[rowIndex] = { spellID1, spellID2, ... }

-- Comparison function for sorting (defined once, not as closure each frame)
local function compareByActionableTime(a, b)
    local timeA = a.actionableTime or 0
    local timeB = b.actionableTime or 0
    if timeA ~= timeB then
        return timeA < timeB
    end
    -- Tie-breaker: use default order (stored during RebuildAllRows)
    local orderA = a.defaultSortOrder or a.spellID or 0
    local orderB = b.defaultSortOrder or b.spellID or 0
    return orderA < orderB
end

-- Sort a specific row by "actionable time" (least time remaining first)
-- This is useful for DOT-tracking classes to see which ability needs attention soonest
-- Optimized to minimize GC pressure and skip work when order hasn't changed
function CooldownIcons:SortRowByTimeRemaining(rowFrame, rowIndex)
    if not rowFrame then return end
    
    local db = addon.db.profile.icons
    local useAnimation = db.dynamicSortAnimation
    
    -- Reuse cached table (wipe and refill instead of allocating new)
    wipe(dynamicSortCache)
    for _, iconFrame in ipairs(rowFrame.icons) do
        if iconFrame:IsShown() and iconFrame.spellID then
            dynamicSortCache[#dynamicSortCache + 1] = iconFrame
        end
    end
    
    local iconCount = #dynamicSortCache
    if iconCount == 0 then return end
    
    -- Sort by actionable time (ascending - least time remaining first)
    table.sort(dynamicSortCache, compareByActionableTime)
    
    -- Initialize per-row previous order cache if needed
    if not previousSortOrder[rowIndex] then
        previousSortOrder[rowIndex] = {}
    end
    local prevOrder = previousSortOrder[rowIndex]
    
    -- Check if sort order actually changed (compare spellIDs in order)
    local orderChanged = false
    if #prevOrder ~= iconCount then
        orderChanged = true
    else
        for i = 1, iconCount do
            if prevOrder[i] ~= dynamicSortCache[i].spellID then
                orderChanged = true
                break
            end
        end
    end
    
    -- Update previous order cache
    if orderChanged then
        wipe(prevOrder)
        for i = 1, iconCount do
            prevOrder[i] = dynamicSortCache[i].spellID
        end
    end
    
    -- Skip repositioning if order hasn't changed and all icons have positions
    -- (Animation mode still needs to run to handle ongoing animations)
    if not orderChanged and not useAnimation then
        -- Verify all icons have valid positions before skipping
        local allPositioned = true
        for i = 1, iconCount do
            if not dynamicSortCache[i]._slideCurrentX then
                allPositioned = false
                break
            end
        end
        if allPositioned then
            return
        end
    end

    -- Use per-row settings
    local iconWidth = rowFrame.iconWidth or db.iconSize
    local spacing = rowFrame.iconSpacing
    if spacing == nil then
        spacing = db.iconSpacing
    end

    -- Delegate positioning and animation to the shared slide animator
    local animator = rowFrame.slideAnimator
    if animator then
        animator:LayoutFrames(dynamicSortCache, iconWidth, spacing, useAnimation)
    end
end

-- Reset dynamic sort position tracking (called when rebuilding rows)
function CooldownIcons:ResetDynamicSortPositions()
    for rowIndex, rowFrame in pairs(self.rows or {}) do
        if rowFrame then
            local animator = rowFrame.slideAnimator
            if animator then
                animator:Stop()
                for _, iconFrame in ipairs(rowFrame.icons) do
                    animator:ResetFrame(iconFrame)
                end
            end
        end
    end

    -- Clear cached sort order for all rows
    wipe(previousSortOrder)
end

function CooldownIcons:UpdateIconState(frame, db)
    -- Sentinel icons: delegate entirely to the owning provider, which
    -- returns whether the icon needs periodic ticker refresh
    local provider = frame._iconProvider
    if provider then
        return provider.Update(frame, db)
    end

    if not frame.spellID then return end

    -- Compute all state (aura, cooldown, prediction, visual flags, glow params)
    -- The state engine queries WoW APIs; this orchestrator only reads its output.
    local s = self.stateEngine:ComputeIconState(frame, db)

    -- Apply BuffGroup swap (state engine signals via swapTexture; orchestrator owns frame mutation)
    if s.swapTexture then
        frame.icon:SetTexture(s.swapTexture)
        frame.spellID = s.spellID
        frame.actualSpellID = s.actualSpellID
        frame.spellData = s.spellData
    end

    -- Temporary lockout texture swap (e.g. Hypothermia icon on Ice Block)
    if s.lockoutTexture then
        if not frame._savedTexture then
            frame._savedTexture = frame.icon:GetTexture()
        end
        frame.icon:SetTexture(s.lockoutTexture)
    elseif frame._savedTexture then
        frame.icon:SetTexture(frame._savedTexture)
        frame._savedTexture = nil
    end

    -- 1. Apply rendering (spiral, text, alpha, desat, stacks, charges)
    visualState.showAuraActive = s.showAuraActive
    visualState.isProcWindow = s.isProcWindow
    visualState.auraRemaining = s.auraDisplayRemaining
    visualState.auraDuration = s.auraDisplayDuration
    visualState.stackCount = s.stackCount
    visualState.cdRemaining = s.remaining
    visualState.cdDuration = s.duration
    visualState.cdStartTime = s.cdStartTime
    visualState.alpha = s.alpha
    visualState.desaturate = s.desaturate
    visualState.showSpinner = s.showSpinner
    visualState.showGCDSpinner = s.showGCDSpinner
    visualState.showText = s.showText
    visualState.showPrediction = s.showPredictionSpiral
    visualState.predictionRemaining = s.predictionRemaining
    visualState.predictionDuration = s.predictionDuration
    visualState.predictionStartTime = s.predictionStartTime
    visualState.gcdContinueText = s.gcdContinueText
    visualState.charges = s.charges
    visualState.hasCharges = s.hasCharges
    self.renderer:ApplyIconVisuals(frame, visualState, db)

    -- 2. Resource display
    self.renderer:UpdateResourceDisplay(frame, s.spellID, s.remaining, s.hasResourceCost, s.resourcePercent, s.powerColor, db, s.showPredictionSpiral, s.inPredictionFallback, s.isOnActualCooldown)

    -- 3. Glow (aura active / permanent buff / normal)
    self.glowManager:UpdateIconGlow(frame, s.showGlow, s.showAuraActive, s.isPermanentBuffActive)

    -- 4. Cooldown pulse (runs unconditionally — lockout spells like PW:S need
    --    pulse even when aura is active, e.g. Weakened Soul expires while shield remains)
    self.glowManager:UpdateCooldownPulse(frame, s.spellID, s.remaining, s.duration)

    -- 5. Ready glow (proc-style glow when ability becomes usable)
    -- Dodge-reactive procs (Overpower) keep the proc-overlay glow the whole time
    -- the window is usable — including while the green window countdown shows. The
    -- `or s.dodgeWindowUsable` bypasses the aura-active suppression that would
    -- otherwise drop the glow when the synthetic window aura is active.
    if not s.showAuraActive or s.dodgeWindowUsable then
        self.glowManager:UpdateReadyGlow(frame, s.spellID, s.remaining, s.duration, s.isUsable, s.isReactive, db, s.lockoutIsLimitingFactor, s.canAfford, s.predictionIsLimitingFactor, s.predictionRemaining, s.dodgeWindowUsable)
    else
        self.glowManager:SuppressReadyGlow(frame, s.remaining, s.duration, s.isUsable)
    end

    -- 5. Range indicator
    self:UpdateRangeIndicator(frame, s.actualSpellID, db)

    -- 6. Queued spell highlight
    if frame.queuedHighlight then
        if s.isQueued then
            if not frame.queuedHighlight:IsShown() then
                frame.queuedHighlight:Show()
            end
        else
            if frame.queuedHighlight:IsShown() then
                frame.queuedHighlight:Hide()
            end
        end
    end

    -- Return true if this icon has time-based state needing periodic refresh
    -- (cooldown spiral, prediction spiral, timed aura counting down, or resource fill active)
    return s.showSpinner or s.showPredictionSpiral
        or (s.showAuraActive and s.auraDisplayRemaining and s.auraDisplayRemaining > 0)
        or s.dodgeWindowUsable
        or (s.hasResourceCost and not s.canAfford)
end

-- State computation (ComputeAuraState, ComputeCooldownState, ComputePredictionState,
-- ComputeVisualFlags) has been extracted to IconStateEngine.lua.
-- CooldownIcons:UpdateIconState is now a pure consumption orchestrator.

-------------------------------------------------------------------------------
-- Range Indicator
-------------------------------------------------------------------------------

-- Update range indicator overlay on an icon
-- Shows a red tint when the target is out of range of the spell
-- Shows when ability is usable (has resources/conditions) even if on cooldown - gives positioning heads-up
-- Hides when: aura is active (tracking it), or ability is unusable (resource indicators take priority)
-- Visual hierarchy: grey = unusable, red = out of range, normal = ready
function CooldownIcons:UpdateRangeIndicator(frame, spellID, db)
    if not frame.rangeFrame then return end
    
    -- Check if range indicator is enabled for this row
    local rowIndex = frame.rowIndex or 1
    local showForRow = addon.Database:IsRowSettingEnabled(db.showRangeIndicator, rowIndex)
    
    if not showForRow then
        frame.rangeFrame.fadeIn:Stop()
        frame.rangeFrame.fadeOut:Stop()
        frame.rangeFrame:SetAlpha(0)
        frame.rangeFrame:Hide()
        frame.rangeWantShow = false
        return
    end
    
    -- Check if we have a target at all
    local hasTarget = UnitExists("target")
    
    -- Determine if we should show the range indicator
    local shouldShow = false
    
    if hasTarget then
        -- Skip if this spell has an active aura (buff/debuff already applied)
        local auraTracker = addon:GetModule("AuraState")
        local hasActiveAura = auraTracker and auraTracker:IsAuraActive(frame.spellID)
        
        -- Skip if player has an active buff from this spell (self-buffs, permanent buffs)
        -- Respect cooldownPriority flag for spells where the buff is incidental (e.g., Bloodthirst healing)
        local actualSpellID = frame.actualSpellID or frame.spellID
        local spellData = frame.spellData
        local shouldCheckBuff = not (spellData and spellData.cooldownPriority)
        local isBuffActive = shouldCheckBuff and self.stateEngine:GetPlayerBuff(actualSpellID)
        
        -- Skip if ability is not usable (resources, conditions, etc.)
        -- This ensures range doesn't compete with resource indicators
        -- Note: We DO show range during cooldown if otherwise usable (gives heads-up on positioning)
        local isUsable = self.stateEngine:IsSpellUsable(actualSpellID)
        
        if not hasActiveAura and not isBuffActive and isUsable then
            -- Check range - only show if explicitly out of range (false)
            local RangeChecker = addon.RangeChecker
            local inRange = RangeChecker and RangeChecker:IsSpellInRange(spellID, "target")
            shouldShow = (inRange == false)
        end
    end
    
    -- Track state transitions
    local wasShowing = frame.rangeWantShow or false
    frame.rangeWantShow = shouldShow
    
    if shouldShow and not wasShowing then
        -- Fade in - stop any existing animation first to ensure clean state
        frame.rangeFrame.fadeOut:Stop()
        frame.rangeFrame.fadeIn:Stop()
        frame.rangeFrame:Show()
        frame.rangeFrame:SetAlpha(0)
        frame.rangeFrame.fadeIn:Play()
    elseif not shouldShow and wasShowing then
        if hasTarget then
            -- Target exists but we're now in range: fade out smoothly
            frame.rangeFrame.fadeIn:Stop()
            frame.rangeFrame.fadeOut:Stop()
            frame.rangeFrame:SetAlpha(1)
            frame.rangeFrame.fadeOut:Play()
        else
            -- No target: instant hide (no animation) to avoid flicker
            frame.rangeFrame.fadeIn:Stop()
            frame.rangeFrame.fadeOut:Stop()
            frame.rangeFrame:SetAlpha(0)
            frame.rangeFrame:Hide()
        end
    end
end

-- Force update range for all visible icons (called on throttled timer via RangeChecker callback)
function CooldownIcons:UpdateAllRangeIndicators()
    local db = addon.db.profile.icons
    
    for _, rowFrame in ipairs(self.rows or {}) do
        if rowFrame.icons then
            for _, iconFrame in ipairs(rowFrame.icons) do
                if iconFrame:IsShown() and iconFrame.spellID then
                    local actualSpellID = iconFrame.actualSpellID or iconFrame.spellID
                    self:UpdateRangeIndicator(iconFrame, actualSpellID, db)
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

function CooldownIcons:Refresh()
    -- Update cached row settings from current config before rebuilding
    local rowConfigs = addon.db.profile.rows
    local iconDb = addon.db.profile.icons
    
    for rowIndex, rowFrame in ipairs(self.rows or {}) do
        local rowConfig = rowConfigs[rowIndex] or {}
        local size = rowConfig.iconSize or iconDb.iconSize
        local rowAspectRatio = rowConfig.iconAspectRatio or iconDb.iconAspectRatio
        local iconWidth, iconHeight = self.Utils:GetIconDimensions(size, rowAspectRatio)

        rowFrame.iconSize = size
        rowFrame.iconWidth = iconWidth
        rowFrame.iconHeight = iconHeight
        -- Use explicit nil check since 0 is a valid spacing value
        local newSpacing = rowConfig.iconSpacing
        if newSpacing == nil then
            newSpacing = iconDb.iconSpacing
        end
        rowFrame.iconSpacing = newSpacing
        rowFrame.iconsPerRow = rowConfig.iconsPerRow or rowConfig.maxIcons
        rowFrame.flowLayout = rowConfig.flowLayout
        
        -- Update row frame size to match new icon dimensions
        local maxIcons = rowConfig.maxIcons
        rowFrame:SetSize(maxIcons * (iconWidth + newSpacing), iconHeight)
        
        -- Update icon sizes and config
        for _, icon in ipairs(rowFrame.icons or {}) do
            icon:SetSize(iconWidth, iconHeight)
            icon.iconSize = size
            icon.iconWidth = iconWidth
            icon.iconHeight = iconHeight
            
            if icon.cooldown then
                self.renderer:ConfigureCooldownText(icon.cooldown, icon.rowIndex)
                -- Clear cached cooldown values to force re-apply of spiral settings
                icon.lastCdStart = nil
                icon.lastCdDuration = nil
            end
            
            -- Update built-in style if Masque is not installed
            addon.IconStyling:Update(icon, size, self.MasqueGroups[rowIndex] ~= nil, rowAspectRatio)
        end
        
    end

    -- Tell Masque to re-apply skins at new icon sizes (per-row groups)
    for _, group in pairs(self.MasqueGroups) do
        group:ReSkin()
    end

    self:RebuildAllRows()
    self:RefreshFonts(addon:GetFont())
    self:UpdateAllIcons()

    -- Reapply texcoords (handles Masque compositing)
    self:ApplyIconTexCoords()
    
    -- Update cooldown bling setting on all icons (per-row)
    for rowIndex, rowFrame in ipairs(self.rows or {}) do
        local blingEnabled = addon.Database:IsRowSettingEnabled(iconDb.cooldownBlingRows, rowIndex)
        for _, iconFrame in ipairs(rowFrame.icons or {}) do
            if iconFrame.cooldown then
                iconFrame.cooldown:SetDrawBling(blingEnabled)
            end
        end
    end
    
    -- Final repositioning based on actual icon counts (overrides the estimated positions above)
    -- Use ForceRefresh since config changes (gaps, etc.) may not affect element heights
    addon.Layout:ForceRefresh()
end

function CooldownIcons:RefreshFonts(fontPath)
    local db = addon.db.profile.icons
    local tc = addon.db.profile.appearance.textColor

    -- Update fonts and text color on all icon text elements
    for _, rowFrame in ipairs(self.rows or {}) do
        for _, iconFrame in ipairs(rowFrame.icons or {}) do
            local size = iconFrame.iconSize or iconFrame:GetHeight()

            -- Cooldown text
            if iconFrame.text then
                local fontSize = math.max(14, math.floor(size * 0.38))
                self.Utils:ApplyFontOutline(iconFrame.text, fontPath, fontSize, db)
                iconFrame.text:SetTextColor(tc.r, tc.g, tc.b)
            end

            -- Charges text
            if iconFrame.charges then
                local chargesFontSize = math.max(9, math.floor(size * 0.24))
                self.Utils:ApplyFontOutline(iconFrame.charges, fontPath, chargesFontSize, db)
            end

            -- Stacks text
            if iconFrame.stacks then
                local stacksFontSize = math.max(10, math.floor(size * 0.26))
                self.Utils:ApplyFontOutline(iconFrame.stacks, fontPath, stacksFontSize, db)
                iconFrame.stacks:SetTextColor(tc.r, tc.g, tc.b)
            end
            
            -- Keybind text
            addon.Keybinds:UpdateKeybindFont(iconFrame, fontPath, db.keybindTextSize)
        end
    end
end
