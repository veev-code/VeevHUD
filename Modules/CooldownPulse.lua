--[[
    VeevHUD - Cooldown Pulse Module
    Flashes a large ability icon in the center of the screen when it comes off cooldown.

    Design:
    - Hooks into GlowManager's COOLDOWN_READY addon event (fired when a tracked
      spell transitions from real cooldown → off cooldown)
    - Shared-cooldown dedup via recent cast tracking: when multiple spells share
      a cooldown (e.g. shaman shocks), only the actually-cast spell pulses
    - Per-row filtering via the standard ROW_SETTING pattern
    - Animation driven by a shared OnUpdate driver with eased alpha and scale
    - Frame pool: reuses pulse frames to avoid garbage
]]

local ADDON_NAME, addon = ...

local tremove = tremove
local tinsert = tinsert
local GetTime = GetTime
local UnitAffectingCombat = UnitAffectingCombat

local CooldownPulse = {}
CooldownPulse.addon = addon
addon:RegisterModule("CooldownPulse", CooldownPulse)

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local BASE_SIZE = 64        -- Fixed frame size (Masque hooks SetSize, so we scale instead)
local SIZE_SCALE = 1.5      -- How much grow/shrink deviates from iconSize
local INV_SIZE_SCALE = 1 / SIZE_SCALE  -- Precomputed reciprocal (0.667)

local GROW = addon.Constants.PULSE_EFFECT.GROW
local SHRINK = addon.Constants.PULSE_EFFECT.SHRINK
local NONE = addon.Constants.PULSE_EFFECT.NONE

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function CooldownPulse:Initialize()
    self.active = {}         -- Array of active pulse state tables
    self.framePool = {}      -- Recycled pulse frames
    self.frameCounter = 0    -- Unique frame names for Masque

    -- Track recent casts for shared-cooldown dedup: when multiple spells share
    -- a cooldown (e.g. shaman shocks), only pulse the one actually cast.
    -- Maps canonical spellID -> GetTime() of cast.
    self.recentCasts = {}
    self.recentCastsCount = 0

    -- Initialize Masque support if available
    local MSQ = LibStub and LibStub("Masque", true)
    if MSQ then
        self.masqueGroup = MSQ:Group("VeevHUD", "Cooldown Pulse")
    end

    -- Track player casts for shared-CD dedup
    addon.Events:RegisterEvent(self, "UNIT_SPELLCAST_SUCCEEDED", self.OnSpellCastSucceeded)

    -- Register once; handler checks enabled state
    addon.Events:RegisterAddonEvent(self, "COOLDOWN_READY", self.OnCooldownReady)
end

function CooldownPulse:CreateFrames()
    -- Frames are created on demand from the pool
end

function CooldownPulse:Refresh()
    local db = addon.db.profile.cooldownPulse
    -- Clear any in-flight pulses so stale settings don't linger
    self:StopAll()

    if not db.enabled then return end

    -- Update base scale on pooled frames for the new icon size
    for _, f in ipairs(self.framePool) do
        self:ApplyFrameSettings(f)
    end
end

-------------------------------------------------------------------------------
-- Frame Pool
-------------------------------------------------------------------------------

function CooldownPulse:AcquireFrame()
    local f = tremove(self.framePool)
    if f then
        self:ApplyFrameSettings(f)
        return f
    end

    -- Create Button frame (required for Masque compatibility)
    self.frameCounter = self.frameCounter + 1
    local buttonName = "VeevHUDCooldownPulse" .. self.frameCounter
    f = CreateFrame("Button", buttonName, UIParent)
    f:SetFrameStrata("HIGH")
    f:EnableMouse(false)

    -- Fixed base size — Masque hooks SetSize after AddButton, so we set size
    -- once before registration and use SetScale for the user's iconSize.
    f:SetSize(BASE_SIZE, BASE_SIZE)

    -- Icon texture with Masque-compatible references
    local icon = f:CreateTexture(buttonName .. "Icon", "ARTWORK")
    icon:SetAllPoints(f)
    f.icon = icon
    f.Icon = icon  -- Masque reference

    -- Normal texture for Masque (hidden by default)
    local normalTexture = f:CreateTexture(buttonName .. "NormalTexture", "OVERLAY")
    normalTexture:SetAllPoints()
    normalTexture:SetTexture([[Interface\Buttons\UI-Quickslot2]])
    normalTexture:SetAlpha(0)
    f:SetNormalTexture(normalTexture)
    f.NormalTexture = normalTexture

    -- Register with Masque if available
    if self.masqueGroup then
        self.masqueGroup:AddButton(f, {
            Icon = icon,
            Normal = normalTexture,
        })
        -- Masque re-shows the NormalTexture (border) after skinning — hide it
        normalTexture:SetAlpha(0)
    end

    self:ApplyFrameSettings(f)
    return f
end

function CooldownPulse:ReleaseFrame(f)
    f:SetAlpha(0)
    f:SetScale(f._baseScale or 1)
    f:Hide()
    f.icon:SetTexture(nil)
    tinsert(self.framePool, f)
end

function CooldownPulse:ApplyFrameSettings(f)
    local db = addon.db.profile.cooldownPulse
    -- Use scale for icon size (Masque hooks SetSize on skinned Button frames)
    f._baseScale = db.iconSize / BASE_SIZE
    f:SetScale(f._baseScale)

    -- Anchor position
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", db.anchor.x, db.anchor.y)

    -- Icon zoom (reuse shared utility for aspect ratio support)
    local iconsDb = addon.db.profile.icons
    local zoomPerEdge = iconsDb.iconZoom / 2
    local left, right, top, bottom = addon.Utils:GetIconTexCoords(zoomPerEdge, iconsDb.iconAspectRatio)
    f.icon:SetTexCoord(left, right, top, bottom)
end

-------------------------------------------------------------------------------
-- Shared-Cooldown Dedup
-------------------------------------------------------------------------------

function CooldownPulse:OnSpellCastSucceeded(event, unit, castGUID, spellID)
    if unit ~= "player" then return end
    -- Store by canonical (base) spell ID: UNIT_SPELLCAST_SUCCEEDED fires with
    -- rank IDs, but COOLDOWN_READY uses LibSpellDB base IDs.
    local baseID = addon.LibSpellDB and addon.LibSpellDB:GetCanonicalSpellID(spellID) or spellID
    if not self.recentCasts[baseID] then
        self.recentCastsCount = self.recentCastsCount + 1
    end
    self.recentCasts[baseID] = GetTime()

    -- Prune stale entries periodically (most classes have ~20-30 abilities)
    if self.recentCastsCount > 50 then
        local now = GetTime()
        for id, castTime in pairs(self.recentCasts) do
            if now - castTime > 300 then
                self.recentCasts[id] = nil
                self.recentCastsCount = self.recentCastsCount - 1
            end
        end
    end
end

function CooldownPulse:OnCooldownReady(event, spellID, texture, spellName, rowIndex, cdDuration)
    local db = addon.db.profile.cooldownPulse
    if not db.enabled then return end

    -- Combat filter
    if db.onlyInCombat and not UnitAffectingCombat("player") then return end

    -- Minimum cooldown filter
    if db.minCooldown > 0 and (cdDuration or 0) < db.minCooldown then return end

    -- Row filtering
    if not addon.Database:IsRowSettingEnabled(db.pulseRows, rowIndex) then
        return
    end

    if not texture then return end

    -- Shared-cooldown dedup: only pulse the spell that was actually cast.
    -- spellID is the canonical base ID from GlowManager; recentCasts stores
    -- canonical IDs via GetCanonicalSpellID().
    -- Sentinel IDs (trinkets, totems, stance) bypass dedup — they're synthetic
    -- and never share cooldowns with other spells.
    if spellID >= addon.Constants.SENTINEL_ID_MIN or self.recentCastsCount == 0 or self.recentCasts[spellID] then
        self:StartPulse(texture, db)
    end
    -- If we have cast history but no record for THIS spell, it came off CD
    -- due to a shared cooldown from another spell's cast — suppress the pulse.
    -- If we have no cast history at all (login/reload), allow the pulse so
    -- long cooldowns that were cast before the session still fire.
end

-------------------------------------------------------------------------------
-- Animation
-------------------------------------------------------------------------------

function CooldownPulse:StartPulse(texture, db)
    local f = self:AcquireFrame()

    -- Set icon
    f.icon:SetTexture(texture)

    -- Reset visual state
    f:SetAlpha(0)
    f:SetScale(f._baseScale or 1)
    f:Show()

    -- Create pulse state
    local fadeIn = db.fadeInTime
    local fadeOut = db.fadeOutTime
    local pulse = {
        frame = f,
        elapsed = 0,
        fadeIn = fadeIn,
        holdTime = db.holdTime,
        fadeOut = fadeOut,
        maxAlpha = db.maxAlpha,
        totalDuration = fadeIn + db.holdTime + fadeOut,
        animationIn = db.animationIn,
        animationOut = db.animationOut,
    }

    tinsert(self.active, pulse)

    -- Start the shared driver if not already running
    if not self.driverRunning then
        self.driverRunning = true
        if not self.driverFrame then
            self.driverFrame = CreateFrame("Frame")
        end
        self.driverFrame:SetScript("OnUpdate", function(_, elapsed)
            self:OnDriverUpdate(elapsed)
        end)
        self.driverFrame:Show()
    end
end

function CooldownPulse:OnDriverUpdate(elapsed)
    -- Update all active pulses (iterate backwards for safe removal)
    for i = #self.active, 1, -1 do
        local pulse = self.active[i]
        pulse.elapsed = pulse.elapsed + elapsed

        if pulse.elapsed >= pulse.totalDuration then
            -- Animation complete — recycle frame
            self:ReleaseFrame(pulse.frame)
            tremove(self.active, i)
        else
            -- Update visual state
            self:UpdatePulseVisuals(pulse)
        end
    end

    -- Stop driver when no active pulses
    if #self.active == 0 then
        self.driverFrame:SetScript("OnUpdate", nil)
        self.driverFrame:Hide()
        self.driverRunning = false
    end
end

function CooldownPulse:UpdatePulseVisuals(pulse)
    local t = pulse.elapsed
    local f = pulse.frame
    local fadeIn = pulse.fadeIn
    local fadeOut = pulse.fadeOut

    -- Alpha: fade in → hold → fade out (shared by all styles)
    local alpha
    if fadeIn > 0 and t < fadeIn then
        local progress = t / fadeIn
        local eased = 1 - (1 - progress) * (1 - progress)
        alpha = pulse.maxAlpha * eased
    elseif t < fadeIn + pulse.holdTime then
        alpha = pulse.maxAlpha
    else
        local progress = fadeOut > 0 and (t - fadeIn - pulse.holdTime) / fadeOut or 1
        local eased = progress * progress
        alpha = pulse.maxAlpha * (1 - eased)
    end
    f:SetAlpha(alpha)

    -- Size: each phase independently grows, shrinks, or stays static
    -- iconSize is the midpoint (what you see during hold)
    local animIn = pulse.animationIn
    local animOut = pulse.animationOut
    local sizeMultiplier = 1.0

    if animIn == animOut and animIn ~= NONE then
        -- Same direction both phases: single continuous interpolation (no midpoint stall)
        local p = t / pulse.totalDuration
        if animIn == GROW then
            sizeMultiplier = INV_SIZE_SCALE + (SIZE_SCALE - INV_SIZE_SCALE) * p
        else -- shrink
            sizeMultiplier = SIZE_SCALE + (INV_SIZE_SCALE - SIZE_SCALE) * p
        end
    else
        -- Mixed directions: use linear size interpolation per phase
        -- (easing on alpha already provides visual smoothness; easing on size
        -- causes a zero-velocity stall at the phase junction)
        if fadeIn > 0 and t < fadeIn then
            local p = t / fadeIn
            if animIn == GROW then
                sizeMultiplier = INV_SIZE_SCALE + (1 - INV_SIZE_SCALE) * p
            elseif animIn == SHRINK then
                sizeMultiplier = SIZE_SCALE + (1 - SIZE_SCALE) * p
            end
        elseif t >= fadeIn + pulse.holdTime and fadeOut > 0 then
            local p = (t - fadeIn - pulse.holdTime) / fadeOut
            if animOut == GROW then
                sizeMultiplier = 1 + (SIZE_SCALE - 1) * p
            elseif animOut == SHRINK then
                sizeMultiplier = 1 + (INV_SIZE_SCALE - 1) * p
            end
        end
    end

    -- Compose animation multiplier on top of the base scale (iconSize / BASE_SIZE).
    -- We use SetScale instead of SetSize because Masque hooks SetSize.
    -- SetScaleAnchored compensates for anchor offset drift.
    local baseScale = f._baseScale or 1
    addon.Animations:SetScaleAnchored(f, baseScale * sizeMultiplier)
end

function CooldownPulse:StopAll()
    for i = #self.active, 1, -1 do
        self:ReleaseFrame(self.active[i].frame)
        self.active[i] = nil
    end
    if self.driverFrame then
        self.driverFrame:SetScript("OnUpdate", nil)
        self.driverFrame:Hide()
    end
    self.driverRunning = false
end

return CooldownPulse
