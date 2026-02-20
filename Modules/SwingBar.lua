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
       - Hunter (all): Single ranged bar. Green (safe) -> Red (would clip).
         Optional 3-color mode: Green -> Yellow (Multi-Shot clips) -> Red.
       - Ret Paladin: Single MH bar. Neutral -> Green (last ~0.4s = twist window).
       - Enhancement Shaman: Dual MH+OH bars. Entire bar green (synced) or red (desynced).
       - Fury Warrior: Dual MH+OH bars. Entire bar green (synced) or red (desynced).
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
       - SPELL_EXTRA_ATTACKS: Guard flag prevents double-reset (Windfury, Sword Spec).
       - UNIT_SPELLCAST_SUCCEEDED: Hunter Auto Shot / Wand Shoot completion.
       - START/STOP_AUTOREPEAT_SPELL: Auto-attack toggle.
       - UNIT_INVENTORY_CHANGED: Weapon swap detection.

    7. KEY FORMULAS
       - Parry haste: timer = timer - (weaponSpeed * 0.4), floor at weaponSpeed * 0.2
       - Haste change: timer = timer * (newSpeed / oldSpeed) (preserves progress ratio)
       - Hunter clip boundary (2-color): steadyShotCastTime / rangedSpeed from right
       - Hunter clip boundary (3-color): multiShotCastTime / rangedSpeed from right
       - Ret twist window: last ~0.4s = starts at 1.0 - (0.4 / mainSpeed)
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
local GetWeaponEnchantInfo = GetWeaponEnchantInfo

local SwingBar = {}
addon:RegisterModule("SwingBar", SwingBar)

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

-- Spells that reset the melee swing timer when they land (SPELL_DAMAGE/SPELL_MISSED)
local SWING_RESET_SPELLS = {
    -- Warrior: Heroic Strike (all ranks) — replaces white hit with yellow
    [78]=true, [284]=true, [285]=true, [1608]=true,
    [11564]=true, [11565]=true, [11566]=true, [11567]=true,
    [25286]=true, [29707]=true, [30324]=true,
    -- Warrior: Cleave (all ranks) — same mechanic as Heroic Strike
    [845]=true, [7369]=true, [11608]=true, [11609]=true,
    [20569]=true, [25231]=true,
    -- Warrior: Slam (all ranks) — 1.5s cast, resets timer on completion
    [1464]=true, [8820]=true, [11604]=true, [11605]=true,
    [25241]=true, [25242]=true,
    -- Hunter: Raptor Strike (all ranks)
    [2973]=true, [14260]=true, [14261]=true, [14262]=true,
    [14263]=true, [14264]=true, [14265]=true, [14266]=true, [27014]=true,
    -- Druid: Maul (all ranks) — bear form only
    [6807]=true, [6808]=true, [6809]=true, [8972]=true,
    [9745]=true, [9880]=true, [9881]=true,
}

-- Auto Shot and Shoot (wand) spell IDs
local AUTO_SHOT_ID = 75
local SHOOT_ID = 5019

-- Fixed cast time for Auto Shot and Wand wind-up (520ms)
local AUTO_CAST_TIME = 0.52

-- Multi-Shot ranks (for Hunter 3-color zone calculation)
local MULTI_SHOT_IDS = {
    [2643]=true, [14288]=true, [14289]=true, [14290]=true,
    [25294]=true, [27021]=true,
}

-- Base cast times (scaled by haste in-game, but we read effective speed from API)
local STEADY_SHOT_CAST_TIME = 1.5
local MULTI_SHOT_CAST_TIME = 0.5

-- Ret Paladin seal twist window (seconds before swing)
local TWIST_WINDOW = 0.4

-- Windfury Totem detection: the totem applies a weapon enchant that pulses every ~5s,
-- so the remaining duration is always <10s. Consumables (Sharpening Stones, etc.) last
-- 30 minutes. This threshold cleanly separates totem enchants from consumable enchants.
local WF_TOTEM_ENCHANT_THRESHOLD = 30000  -- milliseconds

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
SwingBar.extraAttackGuard = false

-- Ranged state (Hunter + Wand)
SwingBar.rangedTimer = 0
SwingBar.rangedSpeed = 0
SwingBar.prevRangedSpeed = 0
SwingBar.autoRepeatActive = false
SwingBar.lastShotTime = 0

-- Class detection (set in Initialize)
SwingBar.isRanged = false
SwingBar.isHunter = false
SwingBar.isDualWieldSync = false
SwingBar.hasTwistWindow = false
SwingBar.hasWindfuryBuff = false

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

    -- Class detection
    self.isHunter = (class == "HUNTER")
    self.isWand = (class == "MAGE") or (class == "PRIEST") or (class == "WARLOCK")
    self.isRanged = self.isHunter  -- Wand classes start in melee mode, switch dynamically

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

    -- Hunter/Wand ranged tracking
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_SUCCEEDED", self.OnSpellCastSucceeded)
    self.Events:RegisterEvent(self, "START_AUTOREPEAT_SPELL", self.OnAutoRepeatStart)
    self.Events:RegisterEvent(self, "STOP_AUTOREPEAT_SPELL", self.OnAutoRepeatStop)

    -- Weapon changes
    self.Events:RegisterEvent(self, "UNIT_INVENTORY_CHANGED", self.OnInventoryChanged)

    -- Spec changes
    self.Events:RegisterEvent(self, "CHARACTER_POINTS_CHANGED", self.OnSpecChanged)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)

    self.Utils:LogDebug("SwingBar initialized for", class)
end

function SwingBar:UpdateSpecFeatures()
    local class = addon.playerClass
    local spec = addon.playerSpec

    self.isDualWieldSync = (class == "SHAMAN" and spec == "ENHANCEMENT")
                        or (class == "WARRIOR" and spec == "FURY")
    self.hasTwistWindow = (class == "PALADIN" and spec == "RETRIBUTION")
end

function SwingBar:OnSpecChanged()
    self:UpdateSpecFeatures()
end

function SwingBar:OnPlayerEnteringWorld()
    self:UpdateSpecFeatures()
    self:UpdateWeaponSpeeds()
    self:CheckWindfuryBuff()
end

-- Check for Windfury Totem weapon enchant via GetWeaponEnchantInfo().
-- Windfury Totem pulses every ~5s, refreshing a short-duration enchant on the MH.
-- Consumables (Sharpening Stones, Weightstones) last 30 min. The duration threshold
-- reliably distinguishes totem enchants from consumables for warriors.
function SwingBar:CheckWindfuryBuff()
    if addon.playerClass ~= "WARRIOR" then return end
    local hasMH, mhExp = GetWeaponEnchantInfo()
    self.hasWindfuryBuff = hasMH and mhExp and mhExp < WF_TOTEM_ENCHANT_THRESHOLD
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
            self.rangedSpeed = speed
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
        if speed and speed > 0 and speed ~= self.rangedSpeed then
            local oldSpeed = self.rangedSpeed
            self.rangedSpeed = speed
            speedChanged = true
            if oldSpeed > 0 and self.rangedTimer > 0 then
                self.rangedTimer = self.rangedTimer * (speed / oldSpeed)
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
    if self.extraAttackGuard then
        self.extraAttackGuard = false
        return
    end

    -- Determine MH or OH from CLEU field position 21
    local isOffHand = select(21, CombatLogGetCurrentEventInfo())

    self:UpdateWeaponSpeeds()

    if isOffHand then
        self.offTimer = self.offSpeed
    else
        self.mainTimer = self.mainSpeed
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
        if self.extraAttackGuard then
            self.extraAttackGuard = false
            return
        end

        local isOffHand = select(13, CombatLogGetCurrentEventInfo())

        self:UpdateWeaponSpeeds()

        if isOffHand then
            self.offTimer = self.offSpeed
        else
            self.mainTimer = self.mainSpeed
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

    local reduction = self.mainSpeed * 0.4
    local floor = self.mainSpeed * 0.2
    self.mainTimer = math_max(self.mainTimer - reduction, floor)
end

function SwingBar:OnSpellDamage(subEvent, data)
    if data.sourceGUID ~= self.playerGUID then return end
    if not data.spellID then return end

    if SWING_RESET_SPELLS[data.spellID] then
        self:UpdateWeaponSpeeds()
        self.mainTimer = self.mainSpeed
        self:OnSwingEvent()
    end
end

function SwingBar:OnSpellMissed(subEvent, data)
    if data.sourceGUID ~= self.playerGUID then return end
    if not data.spellID then return end

    if SWING_RESET_SPELLS[data.spellID] then
        self:UpdateWeaponSpeeds()
        self.mainTimer = self.mainSpeed
        self:OnSwingEvent()
    end
end

function SwingBar:OnExtraAttacks(subEvent, data)
    if data.sourceGUID ~= self.playerGUID then return end
    -- Set guard flag so the next SWING_DAMAGE doesn't reset the timer
    self.extraAttackGuard = true
end

function SwingBar:OnSpellCastSucceeded(event, unit, castGUID, spellID)
    if unit ~= "player" then return end

    if spellID == AUTO_SHOT_ID or spellID == SHOOT_ID then
        -- Auto Shot or Wand completed: reset ranged timer
        self:UpdateWeaponSpeeds()
        if self.rangedSpeed > 0 then
            self.rangedTimer = self.rangedSpeed
            self.lastShotTime = GetTime()
            self:OnSwingEvent()
        end
    end
end

function SwingBar:OnAutoRepeatStart()
    self.autoRepeatActive = true
    if self.isHunter and not addon.db.profile.swingBar.enableMeleeWeaving then
        self.isRanged = true
        self.lastDualState = nil  -- Force container size update
        self:UpdateContainerSize()
        addon.Layout:Refresh()  -- Bar height may change between ranged/melee
    end
    -- Wand classes: wanding switches display from melee to wand
    if self.isWand then self.isRanged = true end
    self:UpdateWeaponSpeeds()
    self:OnSwingEvent()
end

function SwingBar:OnAutoRepeatStop()
    self.autoRepeatActive = false
    if self.isHunter and not addon.db.profile.swingBar.enableMeleeWeaving then
        self.isRanged = false
        self.lastDualState = nil  -- Force container size update
        self:UpdateWeaponSpeeds()  -- Read melee weapon speeds
        self:UpdateContainerSize()
        addon.Layout:Refresh()  -- Bar height may change between ranged/melee
    end
    -- Wand classes: wanding stopped, switch back to melee display
    if self.isWand then self.isRanged = false end
end

function SwingBar:OnInventoryChanged(event, unit)
    if unit ~= "player" then return end
    self:UpdateWeaponSpeeds()
end

-------------------------------------------------------------------------------
-- Zone Backgrounds (colored segments behind the fill showing upcoming zones)
-------------------------------------------------------------------------------

-- Ensure a bar has the required zone background textures (created lazily)
-- Uses the same status bar texture as the fill for visual consistency
local function EnsureZoneTextures(bar, count)
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

-- Position a zone texture as a horizontal segment of the bar background
local function SetZoneSegment(bar, index, startFrac, endFrac, color, barWidth, alpha)
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

-- Update zone background positions based on current attack speed
function SwingBar:UpdateZoneMarkers()
    local db = addon.db.profile.swingBar

    -- Hunter clip zone backgrounds on ranged bar (not in melee mode)
    if self.isHunter and self.isRanged and self.mainBar and db.enableClipZones then
        local barWidth = db.width

        if self.rangedSpeed > 0 then
            local steadyBoundary = 1.0 - (STEADY_SHOT_CAST_TIME / self.rangedSpeed)
            if steadyBoundary < 0 then steadyBoundary = 0 end

            if db.hunterThreeColor then
                local multiBoundary = 1.0 - (MULTI_SHOT_CAST_TIME / self.rangedSpeed)
                if multiBoundary < 0 then multiBoundary = 0 end

                EnsureZoneTextures(self.mainBar, 2)
                SetZoneSegment(self.mainBar, 1, steadyBoundary, multiBoundary, db.cautionColor, barWidth, db.zoneAlpha)
                SetZoneSegment(self.mainBar, 2, multiBoundary, 1.0, db.dangerColor, barWidth, db.zoneAlpha)
            else
                EnsureZoneTextures(self.mainBar, 1)
                SetZoneSegment(self.mainBar, 1, steadyBoundary, 1.0, db.dangerColor, barWidth, db.zoneAlpha)
            end
        else
            EnsureZoneTextures(self.mainBar, 0)
        end
        return
    end

    -- Ret Paladin twist window background on melee bar
    if self.hasTwistWindow and self.mainBar and db.enableTwistWindow then
        local barWidth = db.width

        if self.mainSpeed > 0 then
            local twistThreshold = 1.0 - (TWIST_WINDOW / self.mainSpeed)
            if twistThreshold < 0 then twistThreshold = 0 end

            EnsureZoneTextures(self.mainBar, 1)
            SetZoneSegment(self.mainBar, 1, twistThreshold, 1.0, db.safeColor, barWidth, db.zoneAlpha)
        else
            EnsureZoneTextures(self.mainBar, 0)
        end
        return
    end

    -- No zone feature active — hide all
    if self.mainBar then
        EnsureZoneTextures(self.mainBar, 0)
    end
end

-------------------------------------------------------------------------------
-- Color Logic
-------------------------------------------------------------------------------

function SwingBar:GetFillColor(progress, isOffHand)
    local db = addon.db.profile.swingBar

    -- Dual-wield sync: entire bar colored by sync status
    -- Warriors only show sync colors when buffed by Windfury Totem (the main
    -- reason sync matters). Enhancement Shamans always self-imbue Windfury Weapon.
    local showSync = self.isDualWieldSync and self.hasOffHand and db.enableSyncColors
        and (addon.playerClass ~= "WARRIOR" or self.hasWindfuryBuff)
    if showSync then
        local delta = math_abs(self.mainTimer - self.offTimer)
        -- Wrap around swing period: when one timer just reset (e.g. 2.5s) while
        -- the other is about to fire (0.1s), they're actually 0.2s apart, not 2.4s.
        local period = math_max(self.mainSpeed, self.offSpeed)
        if period > 0 and delta > period / 2 then
            delta = period - delta
        end
        if delta <= db.syncThreshold then
            return db.safeColor
        else
            return db.dangerColor
        end
    end

    -- Hunter: green = safe to cast, colored zones warn of clip danger (ranged only)
    if self.isHunter and self.isRanged and self.rangedSpeed > 0 and db.enableClipZones then
        local steadyBoundary = 1.0 - (STEADY_SHOT_CAST_TIME / self.rangedSpeed)
        if steadyBoundary < 0 then steadyBoundary = 0 end

        if db.hunterThreeColor then
            local multiBoundary = 1.0 - (MULTI_SHOT_CAST_TIME / self.rangedSpeed)
            if multiBoundary < 0 then multiBoundary = 0 end

            if progress < steadyBoundary then
                return db.safeColor
            elseif progress < multiBoundary then
                return db.cautionColor
            else
                return db.dangerColor
            end
        else
            if progress < steadyBoundary then
                return db.safeColor
            else
                return db.dangerColor
            end
        end
    end

    -- Ret Paladin: green twist window at end
    if self.hasTwistWindow and self.mainSpeed > 0 and db.enableTwistWindow then
        local twistThreshold = 1.0 - (TWIST_WINDOW / self.mainSpeed)
        if twistThreshold < 0 then twistThreshold = 0 end
        if progress >= twistThreshold then
            return db.safeColor
        end
    end

    return db.color
end

-------------------------------------------------------------------------------
-- Auto-Hide Logic
-------------------------------------------------------------------------------

function SwingBar:UpdateVisibility()
    local now = GetTime()
    local db = addon.db.profile.swingBar
    local hasActiveTimer

    if self.isHunter and db.enableMeleeWeaving then
        -- Melee weaving: active if either ranged or melee timer is running
        hasActiveTimer = ((self.rangedTimer > 0) and self.autoRepeatActive)
                      or (self.mainTimer > 0)
    elseif self.isRanged then
        hasActiveTimer = (self.rangedTimer > 0) and self.autoRepeatActive
    else
        hasActiveTimer = (self.mainTimer > 0) or (self.offTimer > 0)
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
    self:CheckWindfuryBuff()
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
        -- Melee weaving: ranged bar (height) + melee bar (dualWieldHeight) + spacing
        return db.height + db.dualWieldHeight + db.dualWieldSpacing + 1
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
        spark:SetSize(db.sparkWidth, height + 6)
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
    text:SetTextColor(self.C.COLORS.TEXT.r, self.C.COLORS.TEXT.g, self.C.COLORS.TEXT.b)
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
            local rangedHeight = db.height
            local meleeHeight = db.dualWieldHeight
            local contentHeight = rangedHeight + meleeHeight + db.dualWieldSpacing

            self.container:SetSize(db.width, contentHeight)

            self.mainBar:SetSize(db.width, rangedHeight)
            self.mainBar:ClearAllPoints()
            self.mainBar:SetPoint("TOP", self.container, "TOP", 0, 0)

            self.offBar:SetSize(db.width, meleeHeight)
            self.offBar:ClearAllPoints()
            self.offBar:SetPoint("TOP", self.mainBar, "BOTTOM", 0, -db.dualWieldSpacing)
            self.offBar:Show()
        else
            -- Dual-wield: container holds bar content, border extends below
            local barHeight = db.dualWieldHeight
            local contentHeight = (barHeight * 2) + db.dualWieldSpacing

            self.container:SetSize(db.width, contentHeight)

            -- MH bar on top
            self.mainBar:SetSize(db.width, barHeight)
            self.mainBar:ClearAllPoints()
            self.mainBar:SetPoint("TOP", self.container, "TOP", 0, 0)

            -- OH bar below
            self.offBar:SetSize(db.width, barHeight)
            self.offBar:ClearAllPoints()
            self.offBar:SetPoint("TOP", self.mainBar, "BOTTOM", 0, -db.dualWieldSpacing)
            self.offBar:Show()
        end
    else
        -- Single: container holds bar content, border extends below
        local barHeight = self:GetSingleBarHeight(db)

        self.container:SetSize(db.width, barHeight)

        self.mainBar:SetSize(db.width, barHeight)
        self.mainBar:ClearAllPoints()
        self.mainBar:SetPoint("TOP", self.container, "TOP", 0, 0)

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
    self.hasteAccum = (self.hasteAccum or 0) + dt
    if self.hasteAccum >= 0.1 then
        self:CheckHasteChange()
        self.hasteAccum = 0
    end

    -- Throttle Windfury Totem weapon enchant check to ~1Hz
    self.wfCheckAccum = (self.wfCheckAccum or 0) + dt
    if self.wfCheckAccum >= 1.0 then
        self:CheckWindfuryBuff()
        self.wfCheckAccum = 0
    end

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
    self:UpdateWeaponSpeeds()
    addon.Layout:Refresh()
end

function SwingBar:RefreshFonts(fontPath)
    local db = addon.db.profile.swingBar

    if self.mainBar and self.mainBar.text then
        self.mainBar.text:SetFont(fontPath, db.textSize, "OUTLINE")
    end
    if self.offBar and self.offBar.text then
        self.offBar.text:SetFont(fontPath, db.textSize, "OUTLINE")
    end
end
