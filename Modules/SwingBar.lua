--[[
    VeevHUD - Swing Bar Module
    Weapon swing timer with class-specific colored zones.

    =====================================================================
    REQUIREMENTS
    =====================================================================

    1. VISUAL DESIGN
       A thin progress bar that fills left-to-right as the swing timer
       counts down. The fill color changes based on class-specific zones
       to communicate actionable timing information. No text by default.
       Auto-hides when no active timer to conserve screen real estate.

    2. VISUAL LANGUAGE (consistent across all classes)
       - Neutral (white) = waiting, nothing to do
       - Green = "safe to act" or "act NOW"
       - Red = "don't act" or "danger"
       - Yellow (Hunter option) = "some casts OK, but Multi-Shot would clip"

    3. CLASS-SPECIFIC BEHAVIOR
       - Hunter (all): Single ranged bar. Zones only visible while auto-shot active.
         If Steady Shot known: 3-zone Green -> Yellow -> Red.
         If not (< level 62): 2-zone Green -> Red.
         Green = safe to cast + move, Yellow = Steady clips but instants OK,
         Red = don't move or cast Multi-Shot (auto-shot animation playing).
       - Ret Paladin: Single MH bar. Neutral -> Yellow (prep Command) -> Green (cast Blood).
         Red override when twist is impossible (GCD lockout or Command not prepped).
       - Enhancement Shaman: Dual MH+OH bars. Entire bar green (synced) or red (desynced).
       - Fury Warrior: Dual MH+OH bars. Entire bar green (desynced) or red (synced).
       - Arms Warrior: Single MH bar. Neutral only (fill itself signals timing).
       - Prot Warrior: Single MH bar. Neutral only.
       - Rogue (all): Single or dual bar. Neutral only.
       - Prot/Holy Paladin: Single MH bar. Neutral only.
       - Mage/Priest/Warlock: Single bar. Mutually exclusive melee/wand (most recent shown).
       - Druid: Single bar. Neutral only.

    4. AUTO-HIDE
       - Bar appears when a swing timer starts.
       - Bar hides after hideDelay seconds (default 1.5s) with no active timer.
       - Respects VeevHUD's existing out-of-combat alpha system.
       - Hunter: visible when auto-shot is active.
       - Wand users: visible only while wanding (START/STOP_AUTOREPEAT_SPELL).

    5. DIMENSIONS
       - Single bar: 4px height (default).
       - Dual-wield: 3px per bar, 1px gap = 7px total.
       - Width: 230px (matches resource bar).
       - Spark: optional at fill edge.

    6. SWING TRACKING (CLEU-driven)
       - SWING_DAMAGE / SWING_MISSED: Reset MH or OH timer.
       - SPELL_DAMAGE / SPELL_MISSED: Swing reset spells (HS, Cleave, Slam, Maul, Raptor Strike).
       - SPELL_EXTRA_ATTACKS: Counter prevents double-reset (Windfury, Sword Spec).
       - UNIT_SPELLCAST_START: Cast-time spells reset melee swing timer.
       - UNIT_SPELLCAST_SUCCEEDED: Wand Shoot completion (+ strategy: Hunter Auto Shot).
       - START/STOP_AUTOREPEAT_SPELL: Auto-attack toggle.
       - UNIT_INVENTORY_CHANGED: Weapon swap detection.
       - UNIT_SPELLCAST_FAILED_QUIET: Hunter auto-shot fail → +0.5s re-queue delay.

    7. HUNTER-SPECIFIC EDGE CASES
       - Feign Death: +0.15s penalty on ranged speed, timer resets on movement/jump out.
       - Movement cancel: moving during auto-shot cast phase (last ~0.52s) resets timer.
       - Auto-shot fail: client adds 0.5s delay before retrying (out of range, LoS, etc.).
       - Auto-cast time scales with haste: 0.52 * (hastedSpeed / baseSpeed).

    9. KEY FORMULAS
       - Parry haste: timer = timer - (weaponSpeed * 0.4), floor at weaponSpeed * 0.2
       - Haste change: timer = timer * (newSpeed / oldSpeed) (preserves progress ratio)
       - Hunter yellow boundary: steadyShotCastTime / rangedBaseSpeed from right
       - Hunter red boundary: max(multiShotCast, autoCastAnim) / rangedBaseSpeed from right
       - Ret twist window: last ~0.4s = starts at 1.0 - (0.4 / mainSpeed)
       - Ret prep deadline: 1.0 - ((0.4 + 1.5) / mainSpeed) = last GCD before twist zone
       - Sync delta: abs(mainTimer - offTimer) wrapped around swing period, compared to syncThreshold

    8. LAYOUT
       - Layout element positioned between Combo Points and Primary Row.
       - GetLayoutHeight() returns 0 when hidden (layout collapses seamlessly).
       - Self-contained: all tracking via own CLEU registrations.

    =====================================================================
]]

local ADDON_NAME, addon = ...

-- Localized WoW API functions (hot path)
local GetTime = GetTime
local UnitAttackSpeed = UnitAttackSpeed
local UnitRangedDamage = UnitRangedDamage
local UnitGUID = UnitGUID
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
local select = select
local math_abs = math.abs
local math_max = math.max

local SwingBar = {}
addon:RegisterModule("SwingBar", SwingBar)

-- Class-specific strategies loaded by SwingBarHunter.lua / SwingBarPaladin.lua
addon.SwingBarStrategies = addon.SwingBarStrategies or {}

-- Dispatch a strategy hook: CallStrategy(self, "HookName", ...) -> return value or nil
local function CallStrategy(sb, hookName, ...)
    local s = sb.strategy
    if s and s[hookName] then
        return s[hookName](s, sb, ...)
    end
end

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

-- Spells that reset the melee swing timer when they land (SPELL_DAMAGE/SPELL_MISSED).
-- Built dynamically from LibSpellDB's SWING_RESET tag at init time.
local SWING_RESET_SPELLS = {}

local function BuildSwingResetLookup()
    local lib = addon.LibSpellDB
    if not lib then return end
    local tagged = lib:GetSpellsByTag("SWING_RESET")
    for spellID in pairs(tagged) do
        local allRanks = lib:GetAllRankIDs(spellID)
        for rankID in pairs(allRanks) do
            SWING_RESET_SPELLS[rankID] = true
        end
    end
end

-- Wand Shoot spell ID (core handles wand generically)
local SHOOT_ID = 5019

-- Spark texture extends this many pixels above/below the bar
local SPARK_OVERFLOW = 6

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

-- Melee state
SwingBar.mainTimer = 0
SwingBar.mainSpeed = 0
SwingBar.prevMainSpeed = 0
SwingBar.offTimer = 0
SwingBar.offSpeed = 0
SwingBar.prevOffSpeed = 0
SwingBar.hasOffHand = false
SwingBar.extraAttacksPending = 0

-- Ranged state (Hunter + Wand)
SwingBar.rangedTimer = 0
SwingBar.rangedSpeed = 0
SwingBar.prevRangedSpeed = 0
SwingBar.autoRepeatActive = false
SwingBar.feignPenalty = 0          -- Written by Hunter strategy; read in speed calc (harmless 0 default)
SwingBar.hasteAccum = 0            -- Accumulator for throttled haste checks

-- Class detection (set in Initialize, refined by strategies)
SwingBar.isRanged = false
SwingBar.isHunter = false
SwingBar.isWand = false
SwingBar.isDualWieldSync = false
SwingBar.invertSyncColors = false  -- Warriors invert sync color meaning
SwingBar.hasTwistWindow = false    -- Set by Paladin strategy

-- Visibility
SwingBar.lastActiveTime = 0
SwingBar.isVisible = false
SwingBar.playerGUID = nil

-- UI frames
SwingBar.container = nil
SwingBar.mainBar = nil
SwingBar.offBar = nil

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function SwingBar:Initialize()
    local class = addon.playerClass

    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants

    self.playerGUID = UnitGUID("player")

    -- Build swing reset lookup from LibSpellDB
    BuildSwingResetLookup()

    -- Class detection
    self.isHunter = (class == "HUNTER")
    self.isWand = (class == "MAGE") or (class == "PRIEST") or (class == "WARLOCK")
    self.isRanged = self.isHunter  -- Wand classes start in melee mode, switch dynamically

    -- Select class-specific strategy (loaded by SwingBarHunter/Paladin.lua)
    self.strategy = addon.SwingBarStrategies[class]

    -- Spec-dependent features (updated on spec change)
    self:UpdateSpecFeatures()

    -- Register with layout system
    addon.Layout:RegisterElement("swingBar", self)

    -- Register CLEU events
    self.Events:RegisterCLEU(self, "SWING_DAMAGE", self.OnSwingDamage)
    self.Events:RegisterCLEU(self, "SWING_MISSED", self.OnSwingMissed)
    self.Events:RegisterCLEU(self, "SPELL_DAMAGE", self.OnSpellDamage)
    self.Events:RegisterCLEU(self, "SPELL_MISSED", self.OnSpellMissed)
    self.Events:RegisterCLEU(self, "SPELL_EXTRA_ATTACKS", self.OnExtraAttacks)

    -- Ranged tracking (Hunter auto-shot, Wand shoot)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_SUCCEEDED", self.OnSpellCastSucceeded)
    self.Events:RegisterEvent(self, "START_AUTOREPEAT_SPELL", self.OnAutoRepeatStart)
    self.Events:RegisterEvent(self, "STOP_AUTOREPEAT_SPELL", self.OnAutoRepeatStop)

    -- Cast-time spells reset the melee swing timer (universal WoW mechanic)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_START", self.OnCastStart)

    -- Weapon changes
    self.Events:RegisterEvent(self, "UNIT_INVENTORY_CHANGED", self.OnInventoryChanged)

    -- Spec changes
    self.Events:RegisterEvent(self, "CHARACTER_POINTS_CHANGED", self.OnSpecChanged)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)

    -- Strategy-specific initialization (extra events, state, hooks)
    CallStrategy(self, "OnInitialize")

    self.Utils:LogDebug("SwingBar initialized for", class)
end

function SwingBar:UpdateSpecFeatures()
    local class = addon.playerClass
    local spec = addon.playerSpec

    self.isDualWieldSync = (class == "SHAMAN" and spec == "ENHANCEMENT")
                        or (class == "WARRIOR" and spec == "FURY")
    self.invertSyncColors = (class == "WARRIOR")

    CallStrategy(self, "OnUpdateSpecFeatures")
end

function SwingBar:OnSpecChanged()
    self:UpdateSpecFeatures()
end

function SwingBar:OnPlayerEnteringWorld()
    self:UpdateSpecFeatures()
    self:UpdateWeaponSpeeds()
    CallStrategy(self, "OnPlayerEnteringWorld")
end

-------------------------------------------------------------------------------
-- Weapon Speed Tracking
-------------------------------------------------------------------------------

function SwingBar:UpdateWeaponSpeeds()
    local meleeWeaving = self.isHunter and addon.db.profile.swingBar.enableMeleeWeaving

    if self.isRanged or self.isWand then
        local speed = UnitRangedDamage("player")
        if speed and speed > 0 then
            self.prevRangedSpeed = self.rangedSpeed
            self.rangedSpeed = speed + self.feignPenalty
        end
    end

    -- Also read melee speeds for melee weaving and wand classes
    if not self.isRanged or meleeWeaving or self.isWand then
        local mainSpeed, offSpeed = UnitAttackSpeed("player")
        if mainSpeed and mainSpeed > 0 then
            self.prevMainSpeed = self.mainSpeed
            self.mainSpeed = mainSpeed
        end
        if offSpeed and offSpeed > 0 then
            self.prevOffSpeed = self.offSpeed
            self.offSpeed = offSpeed
            self.hasOffHand = true
        else
            if not meleeWeaving then
                self.hasOffHand = false
            end
        end
    end

    self:UpdateZoneMarkers()
end

-- Adjust timers when weapon speed changes (haste buffs like Flurry, Rapid Fire)
function SwingBar:CheckHasteChange()
    local speedChanged = false
    local meleeWeaving = self.isHunter and addon.db.profile.swingBar.enableMeleeWeaving

    if self.isRanged or self.isWand then
        local speed = UnitRangedDamage("player")
        if speed and speed > 0 then
            -- Apply feign penalty on top of API speed
            local effectiveSpeed = speed + self.feignPenalty
            if effectiveSpeed ~= self.rangedSpeed then
                local oldSpeed = self.rangedSpeed
                self.rangedSpeed = effectiveSpeed
                speedChanged = true
                if oldSpeed > 0 and self.rangedTimer > 0 then
                    self.rangedTimer = self.rangedTimer * (effectiveSpeed / oldSpeed)
                end
            end
        end
    end

    if not self.isRanged or meleeWeaving or self.isWand then
        local mainSpeed, offSpeed = UnitAttackSpeed("player")
        if mainSpeed and mainSpeed > 0 and mainSpeed ~= self.mainSpeed then
            local oldSpeed = self.mainSpeed
            self.mainSpeed = mainSpeed
            speedChanged = true
            if oldSpeed > 0 and self.mainTimer > 0 then
                self.mainTimer = self.mainTimer * (mainSpeed / oldSpeed)
            end
        end
        if offSpeed and offSpeed > 0 and offSpeed ~= self.offSpeed then
            local oldSpeed = self.offSpeed
            self.offSpeed = offSpeed
            self.hasOffHand = true
            speedChanged = true
            if oldSpeed > 0 and self.offTimer > 0 then
                self.offTimer = self.offTimer * (offSpeed / oldSpeed)
            end
        elseif not offSpeed then
            if not meleeWeaving then
                self.hasOffHand = false
            end
        end
    end

    if speedChanged then
        self:UpdateZoneMarkers()
    end
end

-------------------------------------------------------------------------------
-- CLEU Event Handlers
-------------------------------------------------------------------------------

-- Consolidates main-hand swing timer reset + strategy notification.
-- Called from all swing reset sources (CLEU damage, spell resets, cast-time resets).
function SwingBar:ResetMainSwing()
    self.mainTimer = self.mainSpeed
    CallStrategy(self, "OnSwingReset")
end

-- Called from event handlers when a new swing is detected.
-- Ensures the container is visible so OnUpdate fires for smooth animation.
function SwingBar:OnSwingEvent()
    self.lastActiveTime = GetTime()
    if not self.isVisible then
        self:ShowBar()
    end
end

function SwingBar:OnSwingDamage(subEvent, data)
    if data.sourceGUID ~= self.playerGUID then return end

    -- Extra attack guard: if an extra attack (Windfury, Sword Spec) just fired,
    -- don't reset the timer for the extra attack's SWING_DAMAGE
    if self.extraAttacksPending > 0 then
        self.extraAttacksPending = self.extraAttacksPending - 1
        return
    end

    -- Determine MH or OH from CLEU field position 21
    local isOffHand = select(21, CombatLogGetCurrentEventInfo())

    self:UpdateWeaponSpeeds()

    if isOffHand then
        self.offTimer = self.offSpeed
    else
        self:ResetMainSwing()
    end

    -- Wand classes: melee swing switches display from wand to melee
    if self.isWand then self.isRanged = false end

    self:OnSwingEvent()
end

function SwingBar:OnSwingMissed(subEvent, data)
    -- SWING_MISSED: missType at position 12, isOffHand at position 13
    local missType = select(12, CombatLogGetCurrentEventInfo())

    -- Case 1: Player's swing missed → reset swing timer
    if data.sourceGUID == self.playerGUID then
        if self.extraAttacksPending > 0 then
            self.extraAttacksPending = self.extraAttacksPending - 1
            return
        end

        local isOffHand = select(13, CombatLogGetCurrentEventInfo())

        self:UpdateWeaponSpeeds()

        if isOffHand then
            self.offTimer = self.offSpeed
        else
            self:ResetMainSwing()
        end

        -- Wand classes: melee swing switches display from wand to melee
        if self.isWand then self.isRanged = false end

        self:OnSwingEvent()
        return
    end

    -- Case 2: Enemy swing missed player with PARRY → apply parry haste
    if data.destGUID == self.playerGUID and missType == "PARRY" then
        self:ApplyParryHaste()
    end
end

function SwingBar:ApplyParryHaste()
    if self.mainTimer <= 0 or self.mainSpeed <= 0 then return end

    -- If swing timer is already below 20% of weapon speed, parry haste does nothing
    local floor = self.mainSpeed * 0.2
    if self.mainTimer <= floor then return end

    local reduction = self.mainSpeed * 0.4
    self.mainTimer = math_max(self.mainTimer - reduction, floor)
end

function SwingBar:OnSpellDamage(subEvent, data)
    if data.sourceGUID ~= self.playerGUID then return end
    if not data.spellID then return end

    if SWING_RESET_SPELLS[data.spellID] then
        self:UpdateWeaponSpeeds()
        self:ResetMainSwing()
        self:OnSwingEvent()
    end
end

function SwingBar:OnSpellMissed(subEvent, data)
    if data.sourceGUID ~= self.playerGUID then return end
    if not data.spellID then return end

    if SWING_RESET_SPELLS[data.spellID] then
        self:UpdateWeaponSpeeds()
        self:ResetMainSwing()
        self:OnSwingEvent()
    end
end

function SwingBar:OnExtraAttacks(subEvent, data)
    if data.sourceGUID ~= self.playerGUID then return end
    -- Increment pending counter so subsequent extra attack SWING_DAMAGEs don't reset the timer
    local amount = select(16, CombatLogGetCurrentEventInfo()) or 1
    self.extraAttacksPending = self.extraAttacksPending + amount
end

-- Cast-time spells reset the melee swing timer on cast start (universal WoW mechanic).
-- UNIT_SPELLCAST_START only fires for cast-time spells (not instant, not channeled).
function SwingBar:OnCastStart(event, unit)
    if unit ~= "player" then return end
    if self.mainTimer > 0 then
        self:UpdateWeaponSpeeds()
        self:ResetMainSwing()
        self:OnSwingEvent()
    end
end

function SwingBar:OnSpellCastSucceeded(event, unit, castGUID, spellID)
    if unit ~= "player" then return end

    -- Strategy handles class-specific spells first (Hunter: Auto Shot, Feign Death, etc.)
    if CallStrategy(self, "OnSpellCastSucceeded", spellID) then return end

    -- Wand Shoot completed: reset ranged timer
    if spellID == SHOOT_ID then
        self:UpdateWeaponSpeeds()
        if self.rangedSpeed > 0 then
            self.rangedTimer = self.rangedSpeed
            self:OnSwingEvent()
        end
    end
end

function SwingBar:OnAutoRepeatStart()
    self.autoRepeatActive = true
    CallStrategy(self, "OnAutoRepeatStart")
    -- Wand classes: wanding switches display from melee to wand
    if self.isWand then self.isRanged = true end
    self:UpdateWeaponSpeeds()
    self:UpdateZoneMarkers()
    self:OnSwingEvent()
end

function SwingBar:OnAutoRepeatStop()
    self.autoRepeatActive = false
    CallStrategy(self, "OnAutoRepeatStop")
    self:UpdateZoneMarkers()
    -- Wand classes: wanding stopped, switch back to melee display
    if self.isWand then self.isRanged = false end
end

function SwingBar:OnInventoryChanged(event, unit)
    if unit ~= "player" then return end
    CallStrategy(self, "OnInventoryChanged")
    self:UpdateWeaponSpeeds()
end

-------------------------------------------------------------------------------
-- Zone Backgrounds (colored segments behind the fill showing upcoming zones)
-------------------------------------------------------------------------------

-- Ensure a bar has the required zone background textures (created lazily).
-- Promoted to SwingBar method so strategies can call it.
function SwingBar:EnsureZoneTextures(bar, count)
    if not bar._zones then bar._zones = {} end
    local barTexture = bar:GetStatusBarTexture():GetTexture()
    for i = 1, count do
        if not bar._zones[i] then
            local tex = bar:CreateTexture(nil, "BORDER")
            tex:SetTexture(barTexture)
            tex:Hide()
            bar._zones[i] = tex
        else
            bar._zones[i]:SetTexture(barTexture)
        end
    end
    -- Hide extras
    for i = count + 1, #bar._zones do
        bar._zones[i]:Hide()
    end
end

-- Position a zone texture as a horizontal segment of the bar background.
function SwingBar:SetZoneSegment(bar, index, startFrac, endFrac, color, barWidth, alpha)
    local tex = bar._zones[index]
    if startFrac >= endFrac then
        tex:Hide()
        return
    end
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT", bar, "TOPLEFT", barWidth * startFrac, 0)
    tex:SetPoint("BOTTOMRIGHT", bar, "TOPLEFT", barWidth * endFrac, -bar:GetHeight())
    tex:SetVertexColor(color.r, color.g, color.b, alpha)
    tex:Show()
end

-- Update zone background positions based on current attack speed.
-- Strategy provides class-specific zones; core falls through to "no zones."
function SwingBar:UpdateZoneMarkers()
    local db = addon.db.profile.swingBar

    -- Delegate to strategy (Hunter clip zones, Paladin twist zones, etc.)
    if self.mainBar and CallStrategy(self, "UpdateZoneMarkers", self.mainBar, db) then
        return
    end

    -- No zone feature active — hide all
    if self.mainBar then
        self:EnsureZoneTextures(self.mainBar, 0)
    end
end

-------------------------------------------------------------------------------
-- Color Logic
-------------------------------------------------------------------------------

function SwingBar:GetFillColor(progress, isOffHand)
    local db = addon.db.profile.swingBar

    -- Dual-wield sync: entire bar colored by sync status.
    -- Enhancement Shamans want sync (Flurry charge efficiency): green = synced, red = desynced.
    -- Fury Warriors want desync (HS queue removes OH miss penalty): inverted.
    if self.isDualWieldSync and self.hasOffHand and db.enableSyncColors then
        local delta = math_abs(self.mainTimer - self.offTimer)
        local period = math_max(self.mainSpeed, self.offSpeed)
        if period > 0 and delta > period / 2 then
            delta = period - delta
        end
        if delta <= db.syncThreshold then
            return self.invertSyncColors and db.dangerColor or db.safeColor
        else
            return self.invertSyncColors and db.safeColor or db.dangerColor
        end
    end

    -- Strategy-provided fill color (Hunter clip zones, Paladin twist zones)
    local strategyColor = CallStrategy(self, "GetFillColor", progress, isOffHand, db)
    if strategyColor then return strategyColor end

    return db.color
end

-------------------------------------------------------------------------------
-- Auto-Hide Logic
-------------------------------------------------------------------------------

function SwingBar:UpdateVisibility()
    local now = GetTime()
    local db = addon.db.profile.swingBar

    -- Strategy can override active timer detection (e.g., Hunter melee weaving)
    local hasActiveTimer = CallStrategy(self, "GetActiveTimerOverride", db)
    if hasActiveTimer == nil then
        if self.isRanged then
            hasActiveTimer = (self.rangedTimer > 0) and self.autoRepeatActive
        else
            hasActiveTimer = (self.mainTimer > 0) or (self.offTimer > 0)
        end
    end

    if hasActiveTimer then
        self.lastActiveTime = now
        if not self.isVisible then
            self:ShowBar()
        end
    elseif self.isVisible and (now - self.lastActiveTime) > db.hideDelay then
        self:HideBar()
    end
end

function SwingBar:ShowBar()
    self.isVisible = true
    if self.container then
        self.container:Show()
    end
    addon.Layout:Refresh()
end

function SwingBar:HideBar()
    self.isVisible = false
    if self.container then
        self.container:Hide()
    end
    addon.Layout:Refresh()
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

function SwingBar:IsActive()
    local db = addon.db and addon.db.profile and addon.db.profile.swingBar
    return db and db.enabled
end

-------------------------------------------------------------------------------
-- Layout System Integration
-------------------------------------------------------------------------------

function SwingBar:GetLayoutHeight()
    if not self:IsActive() then return 0 end
    if not self.isVisible then return 0 end
    if not self.container then return 0 end

    local db = addon.db.profile.swingBar

    local meleeWeaving = self.isHunter and db.enableMeleeWeaving
    if meleeWeaving then
        -- Melee weaving: ranged bar (classHeight) + melee bar (dualWieldHeight) + spacing
        return self:GetSingleBarHeight(db) + db.dualWieldHeight + db.dualWieldSpacing + 1
    elseif self.hasOffHand and not self.isRanged then
        -- Dual-wield: two bars + spacing + bottom border (skipTop: 1px bottom only)
        return (db.dualWieldHeight * 2) + db.dualWieldSpacing + 1
    else
        -- Single bar + bottom border (skipTop: 1px bottom only)
        return self:GetSingleBarHeight(db) + 1
    end
end

-- Uses topY to anchor from top edge (skipTop border = no top overhang).
function SwingBar:SetLayoutPosition(centerY, topY)
    if not self.container then return end
    self.container:ClearAllPoints()
    self.container:SetPoint("TOP", self.container:GetParent(), "CENTER", 0, topY)
end

-- Toggle top border edge visibility (called by Layout when bar adjacency changes)
function SwingBar:SetTopBorderShown(show)
    if self.mainBar and self.mainBar.border then
        self.mainBar.border:SetTopEdgeShown(show)
    end
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function SwingBar:CreateFrames(parent)
    local db = addon.db.profile.swingBar
    if not db.enabled then return end

    -- Container frame
    local container = CreateFrame("Frame", nil, parent)
    container:SetPoint("CENTER", parent, "CENTER", 0, 0)
    container:EnableMouse(false)
    container:Hide()  -- Start hidden (auto-hide)
    self.container = container

    -- Create main hand / ranged bar
    self:CreateBarFrame("main", container, db)

    -- Create off-hand bar (may be shown/hidden dynamically)
    -- Wand classes never dual-wield; hunters and melee classes might
    if not self.isWand then
        self:CreateBarFrame("off", container, db)
    end

    -- Update container size
    self:UpdateContainerSize()

    -- Use OnUpdate for frame-rate synced smooth animation (not C_Timer.NewTicker)
    container:SetScript("OnUpdate", function(_, elapsed)
        self:UpdateBars(elapsed)
    end)

    self.Utils:LogDebug("SwingBar: Frames created")
end

-- Get effective single-bar height (wand classes use smaller wandHeight)
function SwingBar:GetSingleBarHeight(db)
    if self.isWand then return db.wandHeight end
    local specHeight = db.specHeight[addon.playerSpec]
    if specHeight then return specHeight end
    local classHeight = db.classHeight[addon.playerClass]
    if classHeight then return classHeight end
    return db.height
end

function SwingBar:CreateBarFrame(barType, parent, db)
    local height = self.hasOffHand and db.dualWieldHeight or self:GetSingleBarHeight(db)

    local bar = self.Utils:CreateStatusBar(parent, db.width, height)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)

    -- Border (skipTop: bar above provides the separator)
    local border = self.Utils:CreateBarBorder(bar, true)
    bar.border = border

    -- Gradient overlay
    local appearanceDb = addon.db.profile.appearance
    if appearanceDb.showGradient then
        local gradient = self.Utils:CreateBarGradient(bar)
        bar.gradient = gradient
    end

    -- Spark texture
    if db.showSpark then
        local spark = bar:CreateTexture(nil, "OVERLAY")
        spark:SetTexture([[Interface\CastingBar\UI-CastingBar-Spark]])
        spark:SetBlendMode("ADD")
        spark:SetSize(db.sparkWidth, height + SPARK_OVERFLOW)
        spark:SetPoint("CENTER", bar, "LEFT", 0, 0)
        spark:SetAlpha(0.9)
        bar.spark = spark
    end

    -- Optional timer text
    local textContainer = CreateFrame("Frame", nil, bar)
    textContainer:SetAllPoints(bar)
    textContainer:SetFrameLevel(bar:GetFrameLevel() + 5)

    local text = textContainer:CreateFontString(nil, "OVERLAY")
    text:SetFont(addon:GetFont(), db.textSize, "OUTLINE")
    text:SetPoint("CENTER", bar, "CENTER", 0, 0)
    text:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)
    bar.text = text

    -- Set fill color to neutral
    local c = db.color
    bar:SetStatusBarColor(c.r, c.g, c.b)

    if barType == "main" then
        self.mainBar = bar
    else
        self.offBar = bar
    end

    return bar
end

local function ResizeSpark(bar, barHeight, sparkWidth)
    if bar.spark then
        bar.spark:SetSize(sparkWidth, barHeight + SPARK_OVERFLOW)
    end
end

function SwingBar:UpdateContainerSize()
    if not self.container then return end

    -- Skip if dual-wield state hasn't changed
    local meleeWeaving = self.isHunter and addon.db.profile.swingBar.enableMeleeWeaving
    local isDual = (meleeWeaving and self.offBar)
                or (self.hasOffHand and not self.isRanged and self.offBar)
    if isDual == self.lastDualState then return end
    self.lastDualState = isDual

    local db = addon.db.profile.swingBar

    if isDual then
        if meleeWeaving then
            -- Melee weaving: ranged bar (full height) on top, melee bar (small) below
            local rangedHeight = self:GetSingleBarHeight(db)
            local meleeHeight = db.dualWieldHeight
            local contentHeight = rangedHeight + meleeHeight + db.dualWieldSpacing

            self.container:SetSize(db.width, contentHeight)

            self.mainBar:SetSize(db.width, rangedHeight)
            self.mainBar:ClearAllPoints()
            self.mainBar:SetPoint("TOP", self.container, "TOP", 0, 0)
            ResizeSpark(self.mainBar, rangedHeight, db.sparkWidth)

            self.offBar:SetSize(db.width, meleeHeight)
            self.offBar:ClearAllPoints()
            self.offBar:SetPoint("TOP", self.mainBar, "BOTTOM", 0, -db.dualWieldSpacing)
            self.offBar:Show()
            ResizeSpark(self.offBar, meleeHeight, db.sparkWidth)
        else
            -- Dual-wield: container holds bar content, border extends below
            local barHeight = db.dualWieldHeight
            local contentHeight = (barHeight * 2) + db.dualWieldSpacing

            self.container:SetSize(db.width, contentHeight)

            -- MH bar on top
            self.mainBar:SetSize(db.width, barHeight)
            self.mainBar:ClearAllPoints()
            self.mainBar:SetPoint("TOP", self.container, "TOP", 0, 0)
            ResizeSpark(self.mainBar, barHeight, db.sparkWidth)

            -- OH bar below
            self.offBar:SetSize(db.width, barHeight)
            self.offBar:ClearAllPoints()
            self.offBar:SetPoint("TOP", self.mainBar, "BOTTOM", 0, -db.dualWieldSpacing)
            self.offBar:Show()
            ResizeSpark(self.offBar, barHeight, db.sparkWidth)
        end
    else
        -- Single: container holds bar content, border extends below
        local barHeight = self:GetSingleBarHeight(db)

        self.container:SetSize(db.width, barHeight)

        self.mainBar:SetSize(db.width, barHeight)
        self.mainBar:ClearAllPoints()
        self.mainBar:SetPoint("TOP", self.container, "TOP", 0, 0)
        ResizeSpark(self.mainBar, barHeight, db.sparkWidth)

        if self.offBar then
            self.offBar:Hide()
        end
    end
end

-------------------------------------------------------------------------------
-- Bar Update (OnUpdate, every frame)
-------------------------------------------------------------------------------

function SwingBar:UpdateBars(dt)
    if not self.container then return end
    if not self:IsActive() then return end

    local db = addon.db.profile.swingBar

    -- Throttle haste check to ~10Hz (API call, not needed every frame)
    self.hasteAccum = self.hasteAccum + dt
    if self.hasteAccum >= 0.1 then
        self:CheckHasteChange()
        self.hasteAccum = 0
    end

    -- Strategy pre-update (Hunter: movement detection, Feign Death resume)
    CallStrategy(self, "OnPreUpdate", dt, db)

    -- Decrement timers
    local meleeWeaving = self.isHunter and db.enableMeleeWeaving

    if self.isRanged or self.isWand then
        if self.rangedTimer > 0 then
            self.rangedTimer = self.rangedTimer - dt
            if self.rangedTimer < 0 then self.rangedTimer = 0 end
        end
    end

    if not self.isRanged or meleeWeaving or self.isWand then
        if self.mainTimer > 0 then
            self.mainTimer = self.mainTimer - dt
            if self.mainTimer < 0 then self.mainTimer = 0 end
        end
        if self.offTimer > 0 then
            self.offTimer = self.offTimer - dt
            if self.offTimer < 0 then self.offTimer = 0 end
        end
    end

    -- Strategy post-timer-update (Paladin: GCD/seal polling)
    CallStrategy(self, "OnPostTimerUpdate")

    -- Update visibility (auto-hide)
    self:UpdateVisibility()

    if not self.isVisible then return end

    -- Update main / ranged bar
    if self.mainBar then
        local timer, speed
        if self.isRanged then
            timer = self.rangedTimer
            speed = self.rangedSpeed
        else
            timer = self.mainTimer
            speed = self.mainSpeed
        end

        if speed > 0 then
            local progress
            -- Melee weaving: show ranged bar as empty when auto-shot isn't running
            if meleeWeaving and timer == 0 and not self.autoRepeatActive then
                progress = 0
            else
                progress = 1.0 - (timer / speed)
                if progress < 0 then progress = 0 end
                if progress > 1 then progress = 1 end
            end

            self.mainBar:SetValue(progress)

            -- Color
            local c = self:GetFillColor(progress, false)
            self.mainBar:SetStatusBarColor(c.r, c.g, c.b)

            -- Spark position
            if self.mainBar.spark then
                local barWidth = self.mainBar:GetWidth()
                self.mainBar.spark:SetPoint("CENTER", self.mainBar, "LEFT", barWidth * progress, 0)
                self.mainBar.spark:SetShown(progress > 0 and progress < 1)
            end

            -- Text
            if db.showText and timer > 0 then
                self.mainBar.text:SetText(self.Utils:FormatCooldown(timer))
            else
                self.mainBar.text:SetText("")
            end
        else
            self.mainBar:SetValue(0)
            self.mainBar.text:SetText("")
            if self.mainBar.spark then
                self.mainBar.spark:Hide()
            end
        end
    end

    -- Update off-hand / melee weaving bar
    local showOffBar = false
    local offTimer, offSpeed

    if meleeWeaving and self.offBar then
        -- Melee weaving: off-bar shows melee swing timer
        showOffBar = true
        offTimer = self.mainTimer
        offSpeed = self.mainSpeed
    elseif self.offBar and self.hasOffHand and not self.isRanged then
        -- Normal dual-wield: off-bar shows OH timer
        showOffBar = true
        offTimer = self.offTimer
        offSpeed = self.offSpeed
    end

    if showOffBar then
        if offSpeed > 0 then
            local progress
            -- Melee weaving: show melee bar as empty when not actively swinging
            if meleeWeaving and offTimer == 0 then
                progress = 0
            else
                progress = 1.0 - (offTimer / offSpeed)
                if progress < 0 then progress = 0 end
                if progress > 1 then progress = 1 end
            end

            self.offBar:SetValue(progress)

            -- Color: melee weaving uses base color, dual-wield uses sync logic
            local c = meleeWeaving and db.color or self:GetFillColor(progress, true)
            self.offBar:SetStatusBarColor(c.r, c.g, c.b)

            -- Spark position
            if self.offBar.spark then
                local barWidth = self.offBar:GetWidth()
                self.offBar.spark:SetPoint("CENTER", self.offBar, "LEFT", barWidth * progress, 0)
                self.offBar.spark:SetShown(progress > 0 and progress < 1)
            end

            -- Text
            if db.showText and offTimer > 0 then
                self.offBar.text:SetText(self.Utils:FormatCooldown(offTimer))
            else
                self.offBar.text:SetText("")
            end
        else
            self.offBar:SetValue(0)
            self.offBar.text:SetText("")
            if self.offBar.spark then
                self.offBar.spark:Hide()
            end
        end
    end

    -- Update container size if dual-wield state changed
    self:UpdateContainerSize()
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

function SwingBar:Refresh()
    local db = addon.db.profile.swingBar

    -- Create frames if needed
    if not self.container and db.enabled and addon.hudFrame then
        self:CreateFrames(addon.hudFrame)
    end

    if self.container then
        if db.enabled then
            -- Force bar dimensions update
            self.lastDualState = nil
            self:UpdateContainerSize()

            -- Update spark visibility
            if self.mainBar and self.mainBar.spark then
                self.mainBar.spark:SetShown(db.showSpark)
            end
            if self.offBar and self.offBar.spark then
                self.offBar.spark:SetShown(db.showSpark)
            end

            -- Restore visibility state
            if self.isVisible then
                self.container:Show()
            else
                self.container:Hide()
            end
        else
            self.container:Hide()
        end
    end

    self:UpdateSpecFeatures()
    CallStrategy(self, "OnRefresh", db)

    self:UpdateWeaponSpeeds()
    addon.Layout:Refresh()
end

function SwingBar:RefreshFonts(fontPath)
    local db = addon.db.profile.swingBar
    local tc = addon.db.profile.appearance.textColor

    if self.mainBar and self.mainBar.text then
        self.mainBar.text:SetFont(fontPath, db.textSize, "OUTLINE")
        self.mainBar.text:SetTextColor(tc.r, tc.g, tc.b)
    end
    if self.offBar and self.offBar.text then
        self.offBar.text:SetFont(fontPath, db.textSize, "OUTLINE")
        self.offBar.text:SetTextColor(tc.r, tc.g, tc.b)
    end
end
