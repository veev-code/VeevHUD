--[[
    VeevHUD - Glow Manager Module
    Owns all glow visual effects and proc overlay state.

    Provides composable glow services for any icon-based module:
    - Proc overlay glow (WoW's spell activation system)
    - Aura pixel glow (animated border for active buffs/debuffs)
    - Permanent buff glow (static golden border for stance/stealth)
    - Ready glow (anticipation glow when ability is about to become usable)

    Used by CooldownIcons and TrinketTracker through the shared rendering pipeline.

    Ready Glow Requirements: See CooldownIcons.lua header comments for full spec.
]]

local _, addon = ...
local C = addon.Constants

-- Localized WoW API functions (hot path)
local GetTime = GetTime
local UnitAffectingCombat = UnitAffectingCombat
local IsSpellOverlayed = IsSpellOverlayed
local ActionButton_ShowOverlayGlow = ActionButton_ShowOverlayGlow
local ActionButton_HideOverlayGlow = ActionButton_HideOverlayGlow

local GlowManager = {}
addon:RegisterModule("GlowManager", GlowManager)

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function GlowManager:Initialize()
    self.Utils = addon.Utils
    self.C = addon.Constants
    self.Events = addon.Events

    -- Track active spell overlays (procs)
    self.activeOverlays = {}

    -- Track cooldown pulse fired state per spell ID (not per frame,
    -- since row rebuilds can create multiple frames for the same spell)
    self.cooldownPulseFired = {}

    -- Whether Masque is active (set by CooldownIcons after Masque init)
    self.masqueEnabled = false

    -- Register for spell activation overlay events (procs)
    self.Events:RegisterEvent(self, "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", self.OnOverlayShow)
    self.Events:RegisterEvent(self, "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", self.OnOverlayHide)
end

-- Called by CooldownIcons after Masque initialization
function GlowManager:SetMasqueEnabled(enabled)
    self.masqueEnabled = enabled
end

-------------------------------------------------------------------------------
-- Overlay Events
-------------------------------------------------------------------------------

function GlowManager:OnOverlayShow(event, spellID)
    if spellID then
        self.activeOverlays[spellID] = true
        addon.Events:FireAddonEvent("OVERLAY_STATE_CHANGED")
    end
end

function GlowManager:OnOverlayHide(event, spellID)
    if spellID then
        self.activeOverlays[spellID] = nil
        addon.Events:FireAddonEvent("OVERLAY_STATE_CHANGED")
    end
end

-------------------------------------------------------------------------------
-- Overlay Query
-------------------------------------------------------------------------------

-- Check if spell has activation overlay (proc is active)
function GlowManager:HasSpellActivationOverlay(spellID)
    -- Check our event-tracked table first
    if self.activeOverlays[spellID] then
        return true
    end
    -- Fallback to API if available
    if IsSpellOverlayed then
        return IsSpellOverlayed(spellID)
    end
    return false
end

-------------------------------------------------------------------------------
-- Icon Glow
-------------------------------------------------------------------------------

-- Update glow effect on icon
-- glowStyle: "aura" (timed aura), "permanent" (permanent buff), or nil (proc/ready glow)
function GlowManager:UpdateIconGlow(frame, showGlow, isAuraActive, isPermanentBuff)
    if showGlow then
        local glowType = isPermanentBuff and "permanent" or (isAuraActive and "aura" or "normal")
        local iconAlpha = frame.iconAlpha or 1

        -- Check if glow is already showing with correct type AND same alpha
        -- We need to refresh the glow if alpha changed
        if frame.glowActive and frame.glowType == glowType and frame.glowAlpha == iconAlpha then
            return
        end

        -- Hide existing glow first if type or alpha changed
        if frame.glowActive then
            self:HideGlow(frame)
        end

        if isPermanentBuff then
            -- Permanent buff: Use subtle static glow (like default UI)
            self:ShowPermanentBuffGlow(frame)
        elseif isAuraActive then
            -- Timed aura active: Use pixel glow (animated border)
            self:ShowAuraGlow(frame)
        else
            -- Normal glow: Use standard overlay glow
            if ActionButton_ShowOverlayGlow then
                ActionButton_ShowOverlayGlow(frame)
            elseif self.masqueEnabled and frame.NormalTexture then
                -- Fallback glow only when Masque is active
                frame.NormalTexture:SetVertexColor(1, 1, 0.3)
            end
        end

        frame.glowActive = true
        frame.glowType = glowType
        frame.glowAlpha = iconAlpha
    else
        if frame.glowActive then
            self:HideGlow(frame)
            frame.glowActive = false
            frame.glowType = nil
            frame.glowAlpha = nil
        end
    end
end

-------------------------------------------------------------------------------
-- Permanent Buff Glow
-------------------------------------------------------------------------------

-- Show static glow for permanent buffs (like Shadowform, Stealth)
-- Mimics the subtle glow effect from the default UI action buttons
function GlowManager:ShowPermanentBuffGlow(frame)
    local iconAlpha = frame.iconAlpha or 1

    -- Create the static glow overlay if it doesn't exist
    if not frame.permanentGlow then
        frame.permanentGlow = frame:CreateTexture(nil, "OVERLAY", nil, 1)
        frame.permanentGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        frame.permanentGlow:SetBlendMode("ADD")
        -- Offset Y slightly upward to center the glow visually (texture has asymmetric glow)
        frame.permanentGlow:SetPoint("CENTER", frame, "CENTER", 0, 1)
    end

    -- Size it slightly larger than the icon for a subtle border glow
    -- Use width (larger dimension with aspect ratio) for proper coverage
    local iconDb = addon.db.profile.icons
    local glowWidth = (frame.iconWidth or frame.iconSize or iconDb.iconSize) * 1.5
    local glowHeight = (frame.iconHeight or frame.iconSize or iconDb.iconSize) * 1.5
    frame.permanentGlow:SetSize(glowWidth, glowHeight)

    -- Golden/yellow color to match the default UI active state
    frame.permanentGlow:SetVertexColor(1.0, 0.82, 0.0, 0.6 * iconAlpha)
    frame.permanentGlow:Show()
end

-------------------------------------------------------------------------------
-- Aura Glow
-------------------------------------------------------------------------------

function GlowManager:ShowAuraGlow(frame)
    -- Get icon's current alpha so glow respects Ready/Cooldown Alpha settings
    local iconAlpha = frame.iconAlpha or 1

    -- Scale glow line length proportional to icon size (reference: 56px Primary Row)
    local iconSize = frame.iconSize or 56
    local scale = iconSize / 56
    local length = math.max(4, math.floor(10 * scale + 0.5))
    local offset = math.min(-1, math.floor(-2 * scale + 0.5))

    -- Use shared utility for LibCustomGlow pixel glow
    -- Color #ffcfaf (peachy gold), offset inward proportional to icon size
    local color = {1.0, 0.812, 0.686, iconAlpha}
    if self.Utils:ShowPixelGlow(frame, color, "aura", 8, 0.1, length, 1, offset, offset) then
        return
    end

    -- Fallback: Create simple pixel border for aura active state
    if not frame.pixelGlow then
        frame.pixelGlow = {}
        local r, g, b, a = 1, 0.82, 0, iconAlpha  -- Golden yellow with icon alpha
        local thickness = 2
        local offset = 1  -- Offset from icon edge

        -- Helper to set solid color (compatible with Classic)
        local function SetSolidColor(tex, r, g, b, a)
            tex:SetTexture("Interface\\Buttons\\WHITE8X8")
            tex:SetVertexColor(r, g, b, a)
        end

        -- Top border
        frame.pixelGlow.top = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        SetSolidColor(frame.pixelGlow.top, r, g, b, a)
        frame.pixelGlow.top:SetPoint("TOPLEFT", frame, "TOPLEFT", -offset, offset)
        frame.pixelGlow.top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", offset, offset)
        frame.pixelGlow.top:SetHeight(thickness)

        -- Bottom border
        frame.pixelGlow.bottom = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        SetSolidColor(frame.pixelGlow.bottom, r, g, b, a)
        frame.pixelGlow.bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -offset, -offset)
        frame.pixelGlow.bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", offset, -offset)
        frame.pixelGlow.bottom:SetHeight(thickness)

        -- Left border
        frame.pixelGlow.left = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        SetSolidColor(frame.pixelGlow.left, r, g, b, a)
        frame.pixelGlow.left:SetPoint("TOPLEFT", frame, "TOPLEFT", -offset, offset - thickness)
        frame.pixelGlow.left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -offset, -offset + thickness)
        frame.pixelGlow.left:SetWidth(thickness)

        -- Right border
        frame.pixelGlow.right = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        SetSolidColor(frame.pixelGlow.right, r, g, b, a)
        frame.pixelGlow.right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", offset, offset - thickness)
        frame.pixelGlow.right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", offset, -offset + thickness)
        frame.pixelGlow.right:SetWidth(thickness)
    end

    -- Show all border pieces
    for _, tex in pairs(frame.pixelGlow) do
        tex:Show()
    end

    -- Hide old auraGlow if exists
    if frame.auraGlow then
        frame.auraGlow:Hide()
    end
end

-------------------------------------------------------------------------------
-- Hide Glow
-------------------------------------------------------------------------------

function GlowManager:HideGlow(frame)
    -- Hide overlay glow
    if ActionButton_HideOverlayGlow then
        ActionButton_HideOverlayGlow(frame)
    end

    -- Stop LibCustomGlow pixel glow (via shared utility)
    self.Utils:HidePixelGlow(frame, "aura")

    -- Hide fallback pixel glow borders
    if frame.pixelGlow then
        for _, tex in pairs(frame.pixelGlow) do
            tex:Hide()
        end
    end

    -- Hide old auraGlow if exists
    if frame.auraGlow then
        frame.auraGlow:Hide()
    end

    -- Hide permanent buff glow
    if frame.permanentGlow then
        frame.permanentGlow:Hide()
    end

    -- Reset border color (only when Masque is active)
    if self.masqueEnabled and frame.NormalTexture then
        frame.NormalTexture:SetVertexColor(1, 1, 1)
    end
end

-------------------------------------------------------------------------------
-- Ready Glow
-------------------------------------------------------------------------------

-- Track cooldown transitions and fire COOLDOWN_READY for CooldownPulse.
-- Called unconditionally (even when aura is active) so lockout spells like
-- PW:S still pulse when Weakened Soul expires while the shield buff remains.
function GlowManager:UpdateCooldownPulse(frame, spellID, remaining, duration)
    local isOnRealCooldown = self.Utils:IsOnRealCooldown(remaining, duration)
    local wasOnRealCooldown = frame.wasOnRealCooldown or false

    -- Reset pulse tracking when ability goes on cooldown
    if isOnRealCooldown and not wasOnRealCooldown then
        self.cooldownPulseFired[spellID] = false
    end

    if not self.cooldownPulseFired[spellID] then
        local preTrigger = addon.db.profile.cooldownPulse.preTriggerTime
        local shouldFire = false
        if wasOnRealCooldown and not isOnRealCooldown then
            shouldFire = true
        elseif preTrigger > 0 and isOnRealCooldown and remaining <= preTrigger then
            shouldFire = true
        end
        if shouldFire then
            self.cooldownPulseFired[spellID] = true
            local texture = frame.icon and frame.icon:GetTexture()
            local spellName = frame.actualSpellID and C_Spell.GetSpellName(frame.actualSpellID)
            addon.Events:FireAddonEvent("COOLDOWN_READY", spellID, texture, spellName, frame.rowIndex or 1, duration)
        end
    end

end

-- Sync state and suppress ready glow when aura is active.
-- Called when UpdateReadyGlow is skipped (aura active branch) so that
-- UpdateCooldownPulse sees correct transitions next tick.
function GlowManager:SuppressReadyGlow(frame, remaining, duration, isUsable)
    frame.wasOnRealCooldown = self.Utils:IsOnRealCooldown(remaining, duration)
    frame.wasUsable = isUsable
    if frame.readyGlowActive then
        self:HideReadyGlow(frame)
        frame.readyGlowActive = false
    end
end

-- Update the "ready glow" - shows when ability becomes ready
-- See CooldownIcons.lua header for full requirements spec (R1-R11).
function GlowManager:UpdateReadyGlow(frame, spellID, remaining, duration, isUsable, isReactive, db, lockoutIsLimitingFactor, canAfford, predictionIsLimitingFactor, predictionRemaining, dodgeGlowOverride)
    local glowRows = db.readyGlowRows
    local rowIndex = frame.rowIndex or 1
    local now = GetTime()

    -- Check row-based setting first
    local enabledForRow = addon.Database:IsRowSettingEnabled(glowRows, rowIndex)

    -- Disabled or not enabled for this row: hide any active glow and return (unless reactive or dodge override)
    if not enabledForRow and not isReactive and not dodgeGlowOverride then
        if frame.readyGlowActive then
            self:HideReadyGlow(frame)
            frame.readyGlowActive = false
        end
        return
    end

    -- Determine effective mode per row:
    -- Reactive abilities (Execute, Overpower) always use "always" behavior
    -- Otherwise, check readyGlowAlwaysRows to see if this row uses persistent glow
    local alwaysForRow = addon.Database:IsRowSettingEnabled(db.readyGlowAlwaysRows, rowIndex)
    local effectiveMode = (isReactive or alwaysForRow) and C.GLOW_MODE.ALWAYS or C.GLOW_MODE.ONCE

    local isOnRealCooldown = self.Utils:IsOnRealCooldown(remaining, duration)
    local readyGlowThreshold = db.readyGlowThreshold
    local isAlmostReady = remaining > 0 and remaining <= readyGlowThreshold and isOnRealCooldown
    local isOffCooldown = self.Utils:IsOffCooldown(remaining, duration)

    -- Check if prediction is almost complete (Resource Timer mode for energy/mana)
    -- When prediction is the limiting factor and almost ready, treat as almost ready
    local isPredictionAlmostReady = predictionIsLimitingFactor and predictionRemaining > 0 and predictionRemaining <= readyGlowThreshold

    -- When lockout is the limiting factor and almost expired, treat as usable for glow purposes
    -- The WoW API reports isUsable=false while lockout is active, but we want to trigger
    -- the "almost ready" glow when the lockout has <1s remaining (if resources allow)
    local effectiveUsable = isUsable
    if lockoutIsLimitingFactor and isAlmostReady and canAfford then
        effectiveUsable = true
    end
    -- Similarly, when prediction is almost complete, treat as usable for glow purposes
    -- The ability will become usable in <1s when we have enough resources
    if isPredictionAlmostReady then
        effectiveUsable = true
        -- Also treat as "almost ready" for the glow trigger
        isAlmostReady = true
    end
    -- Dodge-reactive override: when target dodges, treat as usable for glow even if wrong stance
    -- (e.g., Overpower while in Berserker Stance - signals "swap stance and use this!")
    if dodgeGlowOverride then
        effectiveUsable = true
    end

    -- Track previous states
    local wasOnRealCooldown = frame.wasOnRealCooldown or false
    local wasUsable = frame.wasUsable or false

    -- Detect when ability goes on cooldown (used) -> reset tracking for ALL abilities
    if isOnRealCooldown and not wasOnRealCooldown then
        frame.readyGlowShown = false
        frame.readyGlowExpires = nil
    end

    local inCombat = UnitAffectingCombat("player")

    -- Reset glow tracking based on effective mode
    if effectiveMode == C.GLOW_MODE.ALWAYS then
        -- Reset glow when usability changes (allows re-triggering)
        if effectiveUsable and not wasUsable then
            frame.readyGlowShown = false
        end
    end
    -- "once" mode: readyGlowShown stays true until ability is used (goes on CD)

    -- Check if ready glow should be triggered
    -- IMPORTANT: canAfford is required in addition to effectiveUsable because
    -- WoW's IsUsableSpell is unreliable during cooldowns -- it may return true
    -- even when the player lacks the resources (rage/mana/energy) to cast.
    -- canAfford uses the addon's own power cost calculation which is always accurate.
    local showReadyGlow = false

    if not frame.readyGlowShown then
        local glowDuration = db.readyGlowDuration

        -- Condition 1: <1s remaining on CD AND usable AND can afford
        if isAlmostReady and effectiveUsable and canAfford and inCombat then
            showReadyGlow = true
            frame.readyGlowShown = true
            frame.readyGlowExpires = now + glowDuration

        -- Condition 2: Just became usable while off CD (canAfford is implicit in effectiveUsable when off CD)
        elseif isOffCooldown and effectiveUsable and canAfford and not wasUsable and inCombat then
            showReadyGlow = true
            frame.readyGlowShown = true
            frame.readyGlowExpires = now + glowDuration
        end
    end

    -- Check if existing ready glow should continue
    -- Cancel early if player can no longer afford the spell (e.g. spent rage on something else)
    if not canAfford then
        frame.readyGlowExpires = nil
    elseif frame.readyGlowExpires and frame.readyGlowExpires > now then
        showReadyGlow = true
    elseif frame.readyGlowExpires and frame.readyGlowExpires <= now then
        -- Glow expired
        frame.readyGlowExpires = nil
    end

    -- Update stored state for next frame
    frame.wasOnRealCooldown = isOnRealCooldown
    frame.wasUsable = isUsable

    -- Show or hide the ready glow
    if showReadyGlow then
        if not frame.readyGlowActive then
            self:ShowReadyGlow(frame)
            frame.readyGlowActive = true
        end
    else
        if frame.readyGlowActive then
            self:HideReadyGlow(frame)
            frame.readyGlowActive = false
        end
    end
end

function GlowManager:ShowReadyGlow(frame)
    self.Utils:ShowButtonGlow(frame)
end

function GlowManager:HideReadyGlow(frame)
    self.Utils:HideButtonGlow(frame)
end
