--[[
    VeevHUD - Buff Reminders Module
    
    Tracks long-duration buffs that should be maintained at all times.
    Separate from the main HUD - shows reminder icons when buffs are missing or expiring.
    
    Supports:
    - Self buffs (Inner Fire, Demon Armor, etc.)
    - Party/Raid buffs (Fortitude, MOTW, Battle Shout, etc.)
    - Weapon enchants (Shaman weapon buffs, Rogue poisons)
    - BuffGroup-aware checking (equivalent and exclusive groups)
]]

local ADDON_NAME, addon = ...
local C = addon.Constants

local BuffReminders = {}
addon:RegisterModule("BuffReminders", BuffReminders)

-- Combat state constants
local COMBAT_STATE = {
    ANY = "any",
    COMBAT = "combat",
    OOC = "ooc",
}

-- Track target constants
local TRACK_TARGET = {
    PLAYER = "player",
    PARTY = "party",
    RAID = "raid",
}

-- Check if offhand slot contains a weapon (not shield/held-in-offhand/empty)
local function HasOffhandWeapon()
    local itemID = GetInventoryItemID("player", 17)  -- INVSLOT_OFFHAND
    if not itemID then return false end
    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemID)
    return equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONOFFHAND"
end

-- Active reminders state
BuffReminders.reminders = {}      -- Array of active reminder configs
BuffReminders.activeAlerts = {}   -- spellID -> true for currently shown reminders
BuffReminders.iconPool = {}       -- Recycled icon frames
BuffReminders.visibleIcons = {}   -- Currently visible icon frames
BuffReminders.containerFrame = nil
BuffReminders.initialized = false
BuffReminders.iconCounter = 0     -- Unique frame names for Masque

-------------------------------------------------------------------------------
-- Computed Defaults Per Spell
-- These are the "smart defaults" computed from LibSpellDB data
-------------------------------------------------------------------------------

-- Determine if a spell is purgeable (Magic buff type = can be purged/dispelled)
-- Uses the dispelType field from LibSpellDB spell data
local function IsSpellPurgeable(spellData)
    if not spellData then return false end
    return spellData.dispelType == "Magic"
end

-- Compute default settings for a spell
function BuffReminders:GetSpellDefaults(spellID)
    local LibSpellDB = self.LibSpellDB
    if not LibSpellDB then return nil end
    
    local spellData = LibSpellDB:GetSpellInfo(spellID)
    if not spellData then return nil end
    
    local defaults = {
        enabled = not LibSpellDB:HasTag(spellID, "SITUATIONAL"),  -- Situational spells default to disabled
        timeRemaining = 0,  -- Remind when missing entirely
        minStacks = nil,    -- nil = don't check stacks
        combatState = COMBAT_STATE.ANY,
        trackTarget = TRACK_TARGET.PLAYER,
    }

    -- Spec relevance: disable by default for spells not relevant to current spec
    if defaults.enabled and LibSpellDB.IsSpellRelevantForSpec then
        if not LibSpellDB:IsSpellRelevantForSpec(spellID) then
            defaults.enabled = false
        end
    end

    -- excludeIfKnown: disable if player knows any conflicting spell
    -- (e.g., Soul Link knowledge disables Demonic Sacrifice reminder)
    if defaults.enabled and spellData.buffGroup then
        local groupInfo = LibSpellDB.BuffGroups[spellData.buffGroup]
        if groupInfo and groupInfo.excludeIfKnown then
            for _, excludeID in ipairs(groupInfo.excludeIfKnown) do
                if IsSpellKnown(excludeID) then
                    defaults.enabled = false
                    break
                end
            end
        end
    end
    
    -- Determine combat state default:
    -- Purgeable + long duration (>= 5 min): default OOC
    --   Rationale: expensive buffs like Fort/MOTW shouldn't nag mid-combat
    -- Purgeable + short duration (< 5 min): default ANY
    --   Rationale: cheap, frequent-refresh buffs (Battle Shout, etc.) need
    --   constant uptime and the reminder must work even in combat
    -- Non-purgeable: default ANY
    if IsSpellPurgeable(spellData) and spellData.duration and spellData.duration >= 300 then
        defaults.combatState = COMBAT_STATE.OOC
    end

    -- Talent-gated buff groups (e.g., Demonic Sacrifice) require a multi-step
    -- process that can't be done mid-combat → default OOC
    if spellData.buffGroup then
        local groupInfo = self.LibSpellDB and self.LibSpellDB.BuffGroups[spellData.buffGroup]
        if groupInfo and groupInfo.talentGate then
            defaults.combatState = COMBAT_STATE.OOC
        end
    end
    
    -- Flag whether this spell supports group tracking (Party/Raid).
    -- Permanent buffs (no duration) are auras/toggles — allies either have it
    -- from being in range or they don't. Party tracking is not meaningful.
    -- Default trackTarget is always PLAYER; users opt into Party/Raid.
    defaults.groupTrackable = false
    if spellData.duration and spellData.duration > 0 then
        local auraTarget = LibSpellDB:GetAuraTarget(spellID)
        if auraTarget == "ally" then
            defaults.groupTrackable = true
        elseif auraTarget == "none" then
            if spellData.tags then
                for _, tag in ipairs(spellData.tags) do
                    if tag == "BUFF" or tag == "LONG_BUFF" then
                        defaults.groupTrackable = true
                        break
                    end
                end
            end
        end
    end
    
    -- Stacks for charge-based spells
    -- Inner Fire has 20 charges, Water Shield has 3 charges
    -- We don't set a default minStacks - user can configure it
    
    return defaults
end

-- Get effective config for a spell (user override merged with defaults)
-- Config is stored per-spec: spellConfig[specKey][spellID]
function BuffReminders:GetSpellConfig(spellID)
    local defaults = self:GetSpellDefaults(spellID)
    if not defaults then return nil end

    local db = addon.db and addon.db.profile and addon.db.profile.buffReminders
    if not db then return defaults end

    local specKey = addon.Database:GetSpecKey()
    local specConfig = specKey and db.spellConfig[specKey]
    local userConfig = specConfig and specConfig[spellID]
    if not userConfig then return defaults end

    -- Merge user overrides onto defaults
    local config = {}
    for k, v in pairs(defaults) do
        config[k] = v
    end
    for k, v in pairs(userConfig) do
        config[k] = v
    end

    return config
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function BuffReminders:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.Animations = addon.Animations
    self.iconFactory = addon:GetModule("IconFrameFactory")
    self.LibSpellDB = addon.LibSpellDB
    self.playerClass = addon.playerClass
    self.playerGUID = UnitGUID("player")

    -- Initialize Masque support if available
    local MSQ = LibStub and LibStub("Masque", true)
    if MSQ then
        self.MasqueGroup = MSQ:Group("VeevHUD", "Buff Reminders")
    end

    if not self.LibSpellDB then
        self.Utils:LogError("BuffReminders: LibSpellDB not available")
        return
    end
    
    -- Build the list of buff reminders for this class
    self:BuildReminderList()
    
    self.initialized = true
    self.Utils:LogInfo("BuffReminders: Initialized with", #self.reminders, "reminders for", self.playerClass)
    for _, r in ipairs(self.reminders) do
        self.Utils:LogDebug("BuffReminders: Tracking spell", r.spellID, r.spellData.name or "?", "group:", r.buffGroup or "none")
    end
end

function BuffReminders:BuildReminderList()
    wipe(self.reminders)
    
    if not self.LibSpellDB then return end
    
    -- Get all LONG_BUFF spells for the player's class
    local longBuffs = self.LibSpellDB:GetSpellsByClassAndTag(self.playerClass, "LONG_BUFF")
    
    -- Track which buff groups we've already added (avoid duplicates)
    local seenGroups = {}
    
    for spellID, spellData in pairs(longBuffs) do
        local groupName = spellData.buffGroup
        
        if groupName then
            -- For grouped spells, add ONE entry per group using the group definition
            -- order (not random pairs() order) to pick a stable representative
            if not seenGroups[groupName] then
                seenGroups[groupName] = true
                local groupInfo = self.LibSpellDB.BuffGroups[groupName]
                if groupInfo then
                    -- Use first spell in the group definition as representative
                    local repSpellID = groupInfo.spells[1]
                    local repData = self.LibSpellDB:GetSpellInfo(repSpellID) or spellData
                    table.insert(self.reminders, {
                        spellID = repSpellID,
                        spellData = repData,
                        buffGroup = groupName,
                    })
                end
            end
        else
            -- Non-grouped spell: add directly (spec filtering handled by defaults)
            table.insert(self.reminders, {
                spellID = spellID,
                spellData = spellData,
                buffGroup = nil,
            })
        end
    end
    
    -- Sort by spell name for consistent ordering
    table.sort(self.reminders, function(a, b)
        local nameA = a.spellData.name or ""
        local nameB = b.spellData.name or ""
        return nameA < nameB
    end)
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function BuffReminders:CreateFrames(parent)
    if self.containerFrame then return end

    local container = CreateFrame("Frame", "VeevHUDBuffReminders", UIParent)
    container:SetSize(400, 60)
    container:SetFrameStrata("MEDIUM")
    container:SetFrameLevel(15)
    container:EnableMouse(false)
    self.containerFrame = container
    self.slideAnimator = self.Animations:CreateSlideAnimator(container, 12)

    -- Apply container-level alpha so all child icons inherit it
    self:UpdateAlpha()
    
    -- Position relative to HUD
    self:UpdatePosition()
    
    -- Start the update ticker (1 second interval) as safety net
    self.Events:RegisterUpdate(self, 1.0, self.OnUpdate)
    
    -- Register events for immediate response (throttled to once per frame)
    self.Events:RegisterEvent(self, "UNIT_AURA", self.OnUnitAura)
    self.Events:RegisterEvent(self, "GROUP_ROSTER_UPDATE", self.OnGroupChanged)
    self.Events:RegisterEvent(self, "PLAYER_REGEN_DISABLED", self.OnCombatChanged)
    self.Events:RegisterEvent(self, "PLAYER_REGEN_ENABLED", self.OnCombatChanged)
    self.Events:RegisterEvent(self, "PLAYER_UPDATE_RESTING", self.OnRestingChanged)
    self.Events:RegisterEvent(self, "SPELLS_CHANGED", self.OnSpellsChanged)
end

function BuffReminders:UpdatePosition()
    if not self.containerFrame then return end
    if not addon.hudFrame then
        self.Utils:LogDebug("BuffReminders: UpdatePosition - hudFrame is nil, cannot anchor")
        return
    end
    
    local db = addon.db and addon.db.profile and addon.db.profile.buffReminders
    if not db then return end
    
    local anchor = db.anchor
    self.containerFrame:ClearAllPoints()
    self.containerFrame:SetPoint(
        anchor.point,
        addon.hudFrame,
        anchor.relativePoint,
        anchor.x,
        anchor.y
    )
    
    -- Apply same scale as HUD
    local scale = self.Utils:GetEffectiveHUDScale()
    self.containerFrame:SetScale(scale)
end

function BuffReminders:UpdateAlpha()
    if not self.containerFrame then return end
    local db = addon.db.profile.buffReminders
    self.containerFrame:SetAlpha(db.alpha)
end

-------------------------------------------------------------------------------
-- Animation System (native WoW animation API)
-- No CooldownFrameTemplate on these icons, so Scale animations are safe.
-- Modeled after WeakAura presets: Shrink (start), Pulse (main), Grow (finish)
-------------------------------------------------------------------------------

local APPEAR_SCALE = 2.0           -- Shrink from 2x → 1x (WeakAura-style)
local APPEAR_DURATION = 0.5         -- 0.5s shrink-in
local PULSE_SCALE = 1.15            -- Pulse oscillates 1.0↔1.15 (noticeable breathing)
local PULSE_DURATION = 0.5          -- Half-cycle duration (full oscillation = 2x this)
local DISAPPEAR_SCALE = 2.0         -- Grow from 1x → 2x on disappear
local DISAPPEAR_DURATION = 0.5      -- 0.5s grow-out

-- Build all three animation groups on a frame (called once per icon)
-- Uses TBC-compatible Scale API: SetScale(x, y) animates from factor 1.0 to (x, y).
-- SetFromScale/SetToScale are NOT available in TBC Classic.
local function SetupAnimations(frame)
    local inverseScale = 1 / APPEAR_SCALE  -- 0.5

    -- 1. Start animation (Shrink in): Scale 2.0→1.0, Alpha 0→1
    -- Trick: OnPlay sets frame to 2.0x scale, then the Scale animation factor
    -- goes from 1.0 to (1/2.0), so visual = 2.0 * lerp(1.0, 0.5) = 2.0→1.0
    local startGroup = frame:CreateAnimationGroup()
    startGroup:SetToFinalAlpha(true)

    local startScale = startGroup:CreateAnimation("Scale")
    startScale:SetScale(inverseScale, inverseScale)
    startScale:SetDuration(APPEAR_DURATION)
    startScale:SetSmoothing("OUT")
    startScale:SetOrigin("CENTER", 0, 0)

    local startAlpha = startGroup:CreateAnimation("Alpha")
    startAlpha:SetFromAlpha(0)
    startAlpha:SetToAlpha(1)
    startAlpha:SetDuration(APPEAR_DURATION)

    startGroup:SetScript("OnPlay", function()
        frame:SetScale(APPEAR_SCALE)  -- Start big (2x)
    end)

    -- When shrink-in finishes, restore scale and start the pulse loop
    startGroup:SetScript("OnFinished", function()
        frame:SetScale(1)
        frame._brVisible = true
        -- frame is the visual child; check the positioning parent's visibility
        local posFrame = frame:GetParent()
        if posFrame:IsShown() and frame._brPulseGroup
           and addon.db.profile.buffReminders.pulseEnabled then
            frame._brPulseGroup:Play()
        end
    end)

    frame._brStartGroup = startGroup

    -- 2. Main animation (Pulse): Scale oscillates 1.0↔1.15
    -- Uses two ordered Scale animations with REPEAT instead of BOUNCE to avoid
    -- flicker at the reversal point. Order 1's effect persists while order 2 plays,
    -- so the transition at peak scale is seamless. The loop resets at 1.0 (invisible).
    local pulseGroup = frame:CreateAnimationGroup()
    pulseGroup:SetLooping("REPEAT")

    local pulseUp = pulseGroup:CreateAnimation("Scale")
    pulseUp:SetScale(PULSE_SCALE, PULSE_SCALE)
    pulseUp:SetDuration(PULSE_DURATION)
    pulseUp:SetSmoothing("IN_OUT")
    pulseUp:SetOrigin("CENTER", 0, 0)
    pulseUp:SetOrder(1)

    local pulseDown = pulseGroup:CreateAnimation("Scale")
    pulseDown:SetScale(1 / PULSE_SCALE, 1 / PULSE_SCALE)
    pulseDown:SetDuration(PULSE_DURATION)
    pulseDown:SetSmoothing("IN_OUT")
    pulseDown:SetOrigin("CENTER", 0, 0)
    pulseDown:SetOrder(2)

    frame._brPulseGroup = pulseGroup

    -- 3. Finish animation (Grow out): Scale 1.0→2.0, Alpha 1→0
    -- SetScale(2.0) naturally animates from 1.0x to 2.0x
    local finishGroup = frame:CreateAnimationGroup()
    finishGroup:SetToFinalAlpha(true)

    local finishScale = finishGroup:CreateAnimation("Scale")
    finishScale:SetScale(DISAPPEAR_SCALE, DISAPPEAR_SCALE)
    finishScale:SetDuration(DISAPPEAR_DURATION)
    finishScale:SetSmoothing("IN")
    finishScale:SetOrigin("CENTER", 0, 0)

    local finishAlpha = finishGroup:CreateAnimation("Alpha")
    finishAlpha:SetFromAlpha(1)
    finishAlpha:SetToAlpha(0)
    finishAlpha:SetDuration(DISAPPEAR_DURATION)

    -- When grow-out finishes, hide the frame and check if container can hide
    finishGroup:SetScript("OnFinished", function()
        frame:SetScale(1)
        frame:SetAlpha(0)
        -- frame is the visual child; hide the positioning parent
        local posFrame = frame:GetParent()
        posFrame:Hide()
        -- Clear slide state so it doesn't slide from a stale position when reused
        if BuffReminders.slideAnimator then
            BuffReminders.slideAnimator:ResetFrame(posFrame)
        end
        -- If no visible icons remain and no other frames are animating out, hide container
        local container = posFrame:GetParent()
        if container and container:IsShown() then
            local anyVisible = false
            for _, child in pairs(BuffReminders.iconPool) do
                if child:IsShown() then
                    anyVisible = true
                    break
                end
            end
            if not anyVisible then
                container:Hide()
            end
        end
    end)

    frame._brFinishGroup = finishGroup
end

-- Stop all animations on a frame (animations live on frame.visual)
local function AnimStopAll(frame)
    local v = frame.visual or frame
    if v._brStartGroup then v._brStartGroup:Stop() end
    if v._brPulseGroup then v._brPulseGroup:Stop() end
    if v._brFinishGroup then v._brFinishGroup:Stop() end
end

-- Start appear animation on a frame
local function AnimAppear(frame)
    AnimStopAll(frame)
    local v = frame.visual or frame
    v._brVisible = false
    v:SetAlpha(0)
    frame:Show()
    v:Show()
    v._brStartGroup:Play()
end

-- Start disappear animation on a frame (will Hide when done via OnFinished)
local function AnimDisappear(frame)
    local v = frame.visual or frame
    if v._brFinishGroup and v._brFinishGroup:IsPlaying() then return end
    AnimStopAll(frame)
    v._brVisible = false
    v:SetAlpha(1)
    v._brFinishGroup:Play()
end

-- Immediately stop and hide (no animation)
local function AnimStop(frame)
    AnimStopAll(frame)
    local v = frame.visual or frame
    v._brVisible = false
    v:SetAlpha(0)
    frame:Hide()
end

-- Check if a frame is in the pulsing (fully visible) state
local function AnimIsPulsing(frame)
    local v = frame.visual or frame
    return v._brPulseGroup and v._brPulseGroup:IsPlaying()
end

-- Check if a frame is actively animating in (shrink-in still playing)
local function AnimIsAppearing(frame)
    local v = frame.visual or frame
    return v._brStartGroup and v._brStartGroup:IsPlaying()
end

-------------------------------------------------------------------------------
-- Icon Creation and Management
-------------------------------------------------------------------------------

function BuffReminders:GetOrCreateIcon(key)
    if self.iconPool[key] then
        return self.iconPool[key]
    end

    local db = addon.db.profile.buffReminders
    local iconSize = db.iconSize

    -- Create wrapper+visual+textContainer via shared factory
    local buttonName = "VeevHUDBuff" .. self.iconCounter
    self.iconCounter = self.iconCounter + 1
    local frame = self.Utils:CreateWrapperIcon(self.containerFrame, buttonName, iconSize, iconSize)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(20)

    local visual = frame.visual
    local textContainer = frame.textContainer

    -- Register with Masque if available
    if self.MasqueGroup then
        self.MasqueGroup:AddButton(visual, {
            Icon = frame.icon,
            Normal = visual.NormalTexture,
        })
    end

    -- Cooldown/duration text (center, matching CooldownIcons style)
    local fontSize = math.max(14, math.floor(iconSize * 0.38))
    local text = textContainer:CreateFontString(nil, "OVERLAY", nil, 7)
    text:SetFont(addon:GetFont(), fontSize, "OUTLINE")
    text:SetPoint("CENTER", textContainer, "CENTER", 0, 0)
    text:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)
    text:SetShadowOffset(0.5, -0.5)
    text:SetShadowColor(0, 0, 0, 0.5)
    frame.text = text

    -- Stacks text (top right, matching CooldownIcons style)
    local stacksFontSize = math.max(10, math.floor(iconSize * 0.26))
    local stacks = textContainer:CreateFontString(nil, "OVERLAY", nil, 7)
    stacks:SetFont(addon:GetFont(), stacksFontSize, "OUTLINE")
    stacks:SetPoint("TOPRIGHT", textContainer, "TOPRIGHT", 2, 2)
    stacks:SetJustifyH("RIGHT")
    stacks:SetJustifyV("TOP")
    stacks:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)
    frame.stacks = stacks

    -- Build animation groups on the visual frame
    SetupAnimations(visual)

    -- Apply icon zoom texcoords (Masque compositing handled by factory)
    if self.iconFactory and frame.icon then
        self.iconFactory:ApplyTexCoords(
            {frame},
            addon.db.profile.icons.iconZoom,
            1.0,
            self.MasqueGroup
        )
    end

    frame:Hide()

    self.iconPool[key] = frame
    return frame
end

-- Apply icon zoom texcoords to all buff reminder icons.
-- Delegates to IconFrameFactory which handles Masque compositing.
function BuffReminders:ApplyIconTexCoords()
    if self.iconFactory then
        local icons = {}
        for _, frame in pairs(self.iconPool) do
            icons[#icons + 1] = frame
        end
        self.iconFactory:ApplyTexCoords(
            icons,
            addon.db.profile.icons.iconZoom,
            1.0,  -- BuffReminders uses square icons
            self.MasqueGroup
        )
    end
end

function BuffReminders:UpdateIconSize()
    local db = addon.db.profile.buffReminders
    local iconSize = db.iconSize
    local fontSize = math.max(14, math.floor(iconSize * 0.38))
    local stacksFontSize = math.max(10, math.floor(iconSize * 0.26))

    for _, frame in pairs(self.iconPool) do
        frame:SetSize(iconSize, iconSize)
        if frame.visual then
            frame.visual:SetSize(iconSize, iconSize)
        end
        if frame.textContainer then
            frame.textContainer:SetAllPoints(frame)
        end
        if frame.text then
            frame.text:SetFont(addon:GetFont(), fontSize, "OUTLINE")
            frame.text:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)
        end
        if frame.stacks then
            frame.stacks:SetFont(addon:GetFont(), stacksFontSize, "OUTLINE")
            frame.stacks:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)
        end
        -- Reset slide state so LayoutIcons snaps to positions at the new size
        if self.slideAnimator then
            self.slideAnimator:ResetFrame(frame)
        end
    end

    -- Tell Masque to re-apply skins at new icon sizes
    if self.MasqueGroup then
        self.MasqueGroup:ReSkin()
    end

    -- Apply icon zoom texcoords (must run after ReSkin for Masque compositing)
    self:ApplyIconTexCoords()
end

function BuffReminders:LayoutIcons()
    local db = addon.db.profile.buffReminders
    local iconSize = db.iconSize
    local spacing = db.iconSpacing

    local numVisible = #self.visibleIcons
    if numVisible == 0 then
        if self.containerFrame then
            self.containerFrame:Hide()
        end
        return
    end

    if self.containerFrame then
        self.containerFrame:Show()
    end

    if self.slideAnimator then
        self.slideAnimator:LayoutFrames(self.visibleIcons, iconSize, spacing, db.slideAnimation)
    end
end

-------------------------------------------------------------------------------
-- Buff Checking Logic
-------------------------------------------------------------------------------

-- Check if a buff (by name) is present on a unit
-- playerOnly: if true, only match buffs where source == "player"
function BuffReminders:IsBuffOnUnit(unit, spellID, playerOnly)
    if not UnitExists(unit) then return false, 0, 0 end

    local spellName = GetSpellInfo(spellID)
    if not spellName then return false, 0, 0 end

    -- Also check all rank names (they share the same name)
    for i = 1, 40 do
        local name, _, count, _, duration, expirationTime, source = UnitBuff(unit, i)
        if not name then break end

        if name == spellName then
            if playerOnly and source ~= "player" then
                -- Buff exists but not from player, keep searching
            else
                local remaining = 0
                if expirationTime and expirationTime > 0 then
                    remaining = expirationTime - GetTime()
                elseif duration == 0 then
                    remaining = 999999  -- Permanent buff
                end
                return true, remaining, count or 0
            end
        end
    end

    return false, 0, 0
end

-- Check if ANY spell in a buff group is active on a unit
function BuffReminders:IsBuffGroupOnUnit(unit, groupSpells, playerOnly)
    for _, groupSpellID in ipairs(groupSpells) do
        -- Get all rank spell IDs for this spell
        local spellName = GetSpellInfo(groupSpellID)
        if spellName then
            local found, remaining, stacks = self:IsBuffOnUnit(unit, groupSpellID, playerOnly)
            if found then
                return true, remaining, stacks
            end
        end
    end
    return false, 0, 0
end

-- Check if weapon enchants need reminding (for rogue poisons, shaman imbues)
-- Returns nil when no reminder needed, or a table with per-hand detail:
--   { needsMH = bool, needsOH = bool, mhRemaining = number|nil, ohRemaining = number|nil }
-- Uses HasOffhandWeapon() to distinguish OH weapons from shields/empty.
function BuffReminders:CheckWeaponEnchants(config)
    local db = addon.db.profile.buffReminders
    local checkMH = db.weaponEnchantMH
    local checkOH = db.weaponEnchantOH

    -- Both hands disabled — nothing to check
    if not checkMH and not checkOH then return nil end

    local hasMH, mhExp, _, _, hasOH, ohExp = GetWeaponEnchantInfo()
    local hasOHWeapon = HasOffhandWeapon()
    local result = { needsMH = false, needsOH = false, mhRemaining = nil, ohRemaining = nil }

    self.Utils:LogDebug("BuffReminders: CheckWeaponEnchants -"
        .. " hasMH=" .. tostring(hasMH)
        .. " mhExp=" .. tostring(mhExp)
        .. " hasOH=" .. tostring(hasOH)
        .. " ohExp=" .. tostring(ohExp)
        .. " hasOHWeapon=" .. tostring(hasOHWeapon))

    -- MH missing enchant
    if checkMH and not hasMH then
        result.needsMH = true
    end

    -- OH: only check if player has an offhand weapon (not shield/relic/empty)
    if checkOH and hasOHWeapon and not hasOH then
        result.needsOH = true
    end

    -- Expiration thresholds
    if config.timeRemaining and config.timeRemaining > 0 then
        if checkMH and hasMH then
            local r = (mhExp or 0) / 1000
            if r > 0 and r < config.timeRemaining then
                result.needsMH = true
                result.mhRemaining = r
            end
        end
        if checkOH and hasOH then
            local r = (ohExp or 0) / 1000
            if r > 0 and r < config.timeRemaining then
                result.needsOH = true
                result.ohRemaining = r
            end
        end
    end

    self.Utils:LogDebug("BuffReminders: CheckWeaponEnchants result -"
        .. " needsMH=" .. tostring(result.needsMH)
        .. " needsOH=" .. tostring(result.needsOH))

    if not result.needsMH and not result.needsOH then return nil end
    return result
end

-- Check if a buff needs reminding based on config
function BuffReminders:ShouldRemind(reminder)
    local spellID = reminder.spellID
    local spellData = reminder.spellData
    local config = self:GetSpellConfig(spellID)
    
    if not config or not config.enabled then
        return false
    end
    
    -- Check combat state
    local inCombat = UnitAffectingCombat("player")
    if config.combatState == COMBAT_STATE.COMBAT and not inCombat then
        self.Utils:LogDebug("BuffReminders: " .. (spellData.name or spellID) .. " - skipped (requires combat)")
        return false
    elseif config.combatState == COMBAT_STATE.OOC and inCombat then
        self.Utils:LogDebug("BuffReminders: " .. (spellData.name or spellID) .. " - skipped (requires OOC)")
        return false
    end
    
    -- Item-based weapon enchants (rogue poisons) bypass IsSpellKnown/IsUsableSpell.
    -- Poisons are applied via crafted items, so IsSpellKnown may not work for their spell IDs.
    -- Gate on player level instead and let GetWeaponEnchantInfo be the source of truth.
    if reminder.buffGroup then
        local groupInfo = self.LibSpellDB.BuffGroups[reminder.buffGroup]
        if groupInfo and groupInfo.weaponEnchant and groupInfo.itemBased then
            local playerLevel = UnitLevel("player")
            local minLevel = groupInfo.minLevel or 1
            if playerLevel < minLevel then
                self.Utils:LogDebug("BuffReminders: " .. reminder.buffGroup .. " - player level " .. playerLevel .. " < " .. minLevel)
                return false
            end
            return self:CheckWeaponEnchants(config)
        end
    end
    
    -- Talent-gated buff groups (e.g., Demonic Sacrifice).
    -- These buffs aren't castable spells, so IsSpellKnown/GetHighestKnownRank won't
    -- work on the buff IDs. Instead, check if the gating talent spell is known.
    if reminder.buffGroup then
        local groupInfo = self.LibSpellDB.BuffGroups[reminder.buffGroup]
        if groupInfo and groupInfo.talentGate then
            if not IsSpellKnown(groupInfo.talentGate) then
                self.Utils:LogDebug("BuffReminders: " .. reminder.buffGroup .. " - talent gate " .. groupInfo.talentGate .. " not known")
                return false
            end
            return self:CheckBuffOnPlayer(spellID, groupInfo.spells, config)
        end
    end

    -- For grouped spells, find the first known+usable spell across all group members.
    -- This avoids the problem where the representative spell isn't known but another
    -- spell in the group IS known (e.g., player knows Battle Shout but not Commanding Shout).
    local groupSpells = nil
    local activeSpellID = nil  -- The spell we'll use for known/usable checks
    
    if reminder.buffGroup then
        local groupInfo = self.LibSpellDB.BuffGroups[reminder.buffGroup]
        if groupInfo then
            groupSpells = groupInfo.spells
            -- Find first known+usable spell in the group
            local firstKnown = nil
            for _, gSpellID in ipairs(groupSpells) do
                local hr = self.LibSpellDB:GetHighestKnownRank(gSpellID)
                if hr and IsSpellKnown(hr) then
                    if not firstKnown then
                        firstKnown = gSpellID
                    end
                    local isUsable = IsUsableSpell(hr)
                    if isUsable then
                        activeSpellID = gSpellID
                        break
                    end
                end
            end
            if not activeSpellID then
                activeSpellID = firstKnown  -- Known but not usable (e.g., no resources)
            end
            if not activeSpellID then
                self.Utils:LogDebug("BuffReminders: group " .. reminder.buffGroup .. " - no spells known")
                return false
            end
        end
    end
    
    -- For non-grouped spells, check the spell directly
    if not activeSpellID then
        activeSpellID = spellID
    end
    
    -- Check if the active spell is known
    local highestRank = self.LibSpellDB:GetHighestKnownRank(activeSpellID)
    if not highestRank then
        self.Utils:LogDebug("BuffReminders: " .. (spellData.name or spellID) .. " - no highest rank found")
        return false
    end
    if not IsSpellKnown(highestRank) then
        self.Utils:LogDebug("BuffReminders: " .. (spellData.name or spellID) .. " - not known (rank " .. highestRank .. ")")
        return false
    end
    
    -- Check if spell is usable (has enough resources, correct form, etc.)
    local isUsable, notEnoughResources = IsUsableSpell(highestRank)
    if not isUsable then
        -- If only lacking resources, optionally still show the reminder
        local db = addon.db.profile.buffReminders
        if notEnoughResources and not db.respectResourceCost then
            -- Spell is known and valid, just can't afford it right now — still remind
        else
            self.Utils:LogDebug("BuffReminders: " .. (spellData.name or spellID) .. " - not usable (rank " .. highestRank .. ", noResources=" .. tostring(notEnoughResources) .. ")")
            return false
        end
    end
    
    -- Pet requirement check (e.g., Soul Link requires an alive pet)
    if self.LibSpellDB:HasTag(spellID, "REQUIRES_PET") then
        if not UnitExists("pet") or UnitIsDead("pet") then
            return false
        end
    end

    -- Spell-based weapon enchants (shaman imbues) pass through IsSpellKnown/IsUsableSpell above,
    -- then check actual enchant status via GetWeaponEnchantInfo instead of UnitBuff.
    if spellData.weaponEnchant then
        return self:CheckWeaponEnchants(config)
    end
    
    -- Check buff status based on track target
    local trackTarget = config.trackTarget or TRACK_TARGET.PLAYER
    
    if trackTarget == TRACK_TARGET.PLAYER then
        -- For exclusive groups (e.g., warrior shouts), check only the player's OWN buffs.
        -- Another player's buff shouldn't suppress the reminder — the player should still
        -- cast their own (possibly different) spell from the group.
        local playerOnly = false
        if reminder.buffGroup then
            local gi = self.LibSpellDB.BuffGroups[reminder.buffGroup]
            if gi and gi.relationship == "exclusive" then
                playerOnly = true
            end
        end
        return self:CheckBuffOnPlayer(activeSpellID, groupSpells, config, playerOnly)
    elseif trackTarget == TRACK_TARGET.PARTY or trackTarget == TRACK_TARGET.RAID then
        return self:CheckBuffOnGroup(activeSpellID, groupSpells, config, trackTarget)
    end
    
    return false
end

function BuffReminders:CheckBuffOnPlayer(spellID, groupSpells, config, playerOnly)
    local found, remaining, stacks

    if groupSpells then
        found, remaining, stacks = self:IsBuffGroupOnUnit("player", groupSpells, playerOnly)
    else
        found, remaining, stacks = self:IsBuffOnUnit("player", spellID, playerOnly)
    end
    
    if not found then
        self.Utils:LogDebug("BuffReminders: " .. (GetSpellInfo(spellID) or spellID) .. " - buff missing, SHOULD REMIND")
        return true  -- Buff missing entirely
    end
    
    -- Check time remaining threshold
    if config.timeRemaining and config.timeRemaining > 0 then
        if remaining < config.timeRemaining then
            return true
        end
    end
    
    -- Check stack threshold (OR with time remaining)
    if config.minStacks and config.minStacks > 0 then
        if stacks < config.minStacks then
            return true
        end
    end
    
    return false
end

function BuffReminders:CheckBuffOnGroup(spellID, groupSpells, config, trackTarget)
    -- Determine group size/type
    local isInRaid = IsInRaid()
    local isInGroup = IsInGroup()
    
    -- Intelligent downsize: raid -> party -> player
    if trackTarget == TRACK_TARGET.RAID and not isInRaid then
        if isInGroup then
            trackTarget = TRACK_TARGET.PARTY
        else
            return self:CheckBuffOnPlayer(spellID, groupSpells, config)
        end
    elseif trackTarget == TRACK_TARGET.PARTY and not isInGroup then
        return self:CheckBuffOnPlayer(spellID, groupSpells, config)
    end
    
    -- Check group members
    local prefix, count
    if trackTarget == TRACK_TARGET.RAID and isInRaid then
        prefix = "raid"
        count = GetNumGroupMembers()
    else
        prefix = "party"
        count = GetNumSubgroupMembers()
    end
    
    -- Always check player too
    local playerMissing = self:CheckBuffOnPlayer(spellID, groupSpells, config)
    if playerMissing then return true end
    
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            -- Skip dead
            if UnitIsDead(unit) or UnitIsGhost(unit) then
                -- Skip
            -- Skip disconnected
            elseif not UnitIsConnected(unit) then
                -- Skip
            -- Skip out of range (UnitIsVisible ~100 yards)
            elseif not UnitIsVisible(unit) then
                -- Skip
            else
                local found, remaining, stacks
                if groupSpells then
                    found, remaining, stacks = self:IsBuffGroupOnUnit(unit, groupSpells)
                else
                    found, remaining, stacks = self:IsBuffOnUnit(unit, spellID)
                end
                
                if not found then
                    return true  -- At least one group member missing the buff
                end
                
                -- Check thresholds
                if config.timeRemaining and config.timeRemaining > 0 and remaining < config.timeRemaining then
                    return true
                end
                if config.minStacks and config.minStacks > 0 and stacks < config.minStacks then
                    return true
                end
            end
        end
    end
    
    return false
end

-------------------------------------------------------------------------------
-- Update Loop
-------------------------------------------------------------------------------

function BuffReminders:OnUpdate()
    if not self.initialized then return end
    
    -- Don't interfere with preview while user is configuring settings
    if self._previewActive then return end
    
    local db = addon.db and addon.db.profile
    if not db then return end
    
    -- Feature disabled
    if not db.buffReminders or not db.buffReminders.enabled then
        self:HideAll()
        return
    end
    
    -- Master addon disabled
    if not db.enabled then
        self:HideAll()
        return
    end
    
    -- Global pre-reqs: not resting, not mounted, not on taxi
    local resting = IsResting()
    local mounted = IsMounted()
    local onTaxi = UnitOnTaxi("player")
    
    if resting and not db.buffReminders.showWhileResting then
        self:HideAll()
        return
    end
    if mounted and not db.buffReminders.showWhileMounted then
        self:HideAll()
        return
    end
    if onTaxi then
        self:HideAll()
        return
    end
    
    -- Check each reminder
    local newAlerts = {}
    local alertList = {}
    
    for _, reminder in ipairs(self.reminders) do
        local shouldRemind = self:ShouldRemind(reminder)
        if shouldRemind then
            local spellID = reminder.spellID

            if type(shouldRemind) == "table" and shouldRemind.needsMH ~= nil then
                -- Weapon enchant: separate alerts per hand with weapon icons
                if shouldRemind.needsMH then
                    local mhIcon = GetInventoryItemTexture("player", 16)  -- INVSLOT_MAINHAND
                    newAlerts["weaponMH"] = true
                    table.insert(alertList, {
                        spellID = spellID,
                        key = "weaponMH",
                        iconOverride = mhIcon,
                        reminder = reminder,
                        remaining = shouldRemind.mhRemaining,
                    })
                end
                if shouldRemind.needsOH then
                    local ohIcon = GetInventoryItemTexture("player", 17)  -- INVSLOT_OFFHAND
                    newAlerts["weaponOH"] = true
                    table.insert(alertList, {
                        spellID = spellID,
                        key = "weaponOH",
                        iconOverride = ohIcon,
                        reminder = reminder,
                        remaining = shouldRemind.ohRemaining,
                    })
                end
            else
                -- Normal buff reminder
                newAlerts[spellID] = true

                -- Determine which spell icon to show
                local displaySpellID = spellID

                -- For buff groups, show the best spell to cast
                if reminder.buffGroup then
                    displaySpellID = self:GetBestSpellForGroup(reminder.buffGroup, spellID)
                end

                -- Get highest known rank for icon
                local highestRank = self.LibSpellDB:GetHighestKnownRank(displaySpellID)

                -- Fetch remaining/stacks for text display (only meaningful
                -- when buff exists but is expiring or low on stacks)
                local config = self:GetSpellConfig(spellID)
                local alertRemaining, alertStacks
                if config then
                    local showTime = config.timeRemaining and config.timeRemaining > 0
                    local showStacks = config.minStacks and config.minStacks > 0
                    if showTime or showStacks then
                        local found, remaining, stacks
                        if reminder.buffGroup then
                            local groupInfo = self.LibSpellDB.BuffGroups[reminder.buffGroup]
                            if groupInfo then
                                found, remaining, stacks = self:IsBuffGroupOnUnit("player", groupInfo.spells)
                            end
                        else
                            found, remaining, stacks = self:IsBuffOnUnit("player", spellID)
                        end
                        if found then
                            if showTime and remaining < config.timeRemaining then
                                alertRemaining = remaining
                            end
                            if showStacks and stacks < config.minStacks then
                                alertStacks = stacks
                            end
                        end
                    end
                end

                table.insert(alertList, {
                    spellID = spellID,
                    displaySpellID = highestRank or displaySpellID,
                    reminder = reminder,
                    remaining = alertRemaining,
                    stacks = alertStacks,
                })
            end
        end
    end
    
    -- Update visible icons
    self:UpdateVisibleIcons(alertList)
    self.activeAlerts = newAlerts
end

-- Determine the best spell to show for a buff group
function BuffReminders:GetBestSpellForGroup(groupName, defaultSpellID)
    local groupInfo = self.LibSpellDB.BuffGroups[groupName]
    if not groupInfo then return defaultSpellID end
    
    if groupInfo.relationship == "equivalent" then
        -- For equivalent groups, prefer the group version if in a group
        local isInGroup = IsInGroup() or IsInRaid()
        if isInGroup then
            -- Find the "group" version (typically has longer duration or no auraTarget=ally)
            for _, gSpellID in ipairs(groupInfo.spells) do
                local sData = self.LibSpellDB:GetSpellInfo(gSpellID)
                if sData then
                    local at = self.LibSpellDB:GetAuraTarget(gSpellID)
                    if at == "none" then
                        -- "none" = raid-wide version
                        if IsSpellKnown(self.LibSpellDB:GetHighestKnownRank(gSpellID)) then
                            return gSpellID
                        end
                    end
                end
            end
        end
        -- Fall back to single-target version
        for _, gSpellID in ipairs(groupInfo.spells) do
            local hr = self.LibSpellDB:GetHighestKnownRank(gSpellID)
            if hr and IsSpellKnown(hr) then
                return gSpellID
            end
        end
    elseif groupInfo.relationship == "exclusive" then
        -- For exclusive groups, check user priority config, else use first known.
        -- cfg.priority stores the spell ID of the preferred spell (not a boolean).
        -- If the priority spell is already on the player from another source,
        -- suggest a different uncovered spell from the group instead.
        local db = addon.db and addon.db.profile and addon.db.profile.buffReminders
        local prioritySpellID = nil
        local specKey = addon.Database:GetSpecKey()
        local specConfig = specKey and db and db.spellConfig[specKey]
        if specConfig then
            for _, gSpellID in ipairs(groupInfo.spells) do
                local cfg = specConfig[gSpellID]
                if cfg and cfg.priority then
                    local hr = self.LibSpellDB:GetHighestKnownRank(cfg.priority)
                    if hr and IsSpellKnown(hr) then
                        prioritySpellID = cfg.priority
                        break
                    end
                end
            end
        end

        if prioritySpellID then
            -- Check if the priority spell is already active from another player
            local priorityCovered = self:IsBuffOnUnit("player", prioritySpellID)
            if priorityCovered then
                -- Priority is covered by someone else — suggest an uncovered spell
                for _, gSpellID in ipairs(groupInfo.spells) do
                    if gSpellID ~= prioritySpellID then
                        local hr = self.LibSpellDB:GetHighestKnownRank(gSpellID)
                        if hr and IsSpellKnown(hr) then
                            if not self:IsBuffOnUnit("player", gSpellID) then
                                return gSpellID
                            end
                        end
                    end
                end
            end
            return prioritySpellID
        end

        -- Default: first known spell in the group
        for _, gSpellID in ipairs(groupInfo.spells) do
            local hr = self.LibSpellDB:GetHighestKnownRank(gSpellID)
            if hr and IsSpellKnown(hr) then
                return gSpellID
            end
        end
    end
    
    return defaultSpellID
end

function BuffReminders:UpdateVisibleIcons(alertList)
    -- Build a set of currently active keys for diffing
    -- Uses alert.key (for weapon enchant MH/OH) or alert.spellID as fallback
    local newSpellSet = {}
    for _, alert in ipairs(alertList) do
        local alertKey = alert.key or alert.spellID
        newSpellSet[alertKey] = true
    end

    -- Animate out any previously visible icons that are no longer needed
    local hasDisappearing = false
    for _, frame in ipairs(self.visibleIcons) do
        if frame._brSpellID and not newSpellSet[frame._brSpellID] then
            AnimDisappear(frame)
            hasDisappearing = true
        end
    end
    wipe(self.visibleIcons)

    if #alertList == 0 then
        -- Don't hide container yet if grow-out animations are still playing;
        -- the OnFinished callback of each animation will hide the frame,
        -- and we'll check if container can be hidden on the next update tick.
        if not hasDisappearing and self.containerFrame then
            self.containerFrame:Hide()
        end
        return
    end

    -- Create/update icons for each alert, keyed so each alert
    -- gets a stable frame that persists across updates
    for i, alert in ipairs(alertList) do
        local alertKey = alert.key or alert.spellID
        local frame = self:GetOrCreateIcon(alertKey)
        local v = frame.visual or frame
        local wasAlreadyShown = frame:IsShown() and (AnimIsPulsing(frame) or AnimIsAppearing(frame) or v._brVisible)

        -- Tag the frame with its current key
        frame._brSpellID = alertKey

        -- Set icon texture: weapon enchant alerts use the weapon's inventory icon,
        -- normal alerts use the spell icon
        if alert.iconOverride then
            frame.icon:SetTexture(alert.iconOverride)
        else
            local _, _, spellIcon = GetSpellInfo(alert.displaySpellID)
            if spellIcon then
                frame.icon:SetTexture(spellIcon)
            end
        end

        -- Animate: appear with shrink-in (or keep pulsing if already shown)
        if not wasAlreadyShown then
            AnimAppear(frame)
        end

        -- Update duration/stacks text (after AnimAppear so frame is visible
        -- and font strings can resolve their anchor positions)
        if frame.text then
            if alert.remaining and alert.remaining > 0 and alert.remaining < 999999 then
                frame.text:SetText(self.Utils:FormatCooldown(alert.remaining))
            else
                frame.text:SetText("")
            end
        end
        if frame.stacks then
            if alert.stacks then
                frame.stacks:SetText(alert.stacks)
            else
                frame.stacks:SetText("")
            end
        end

        table.insert(self.visibleIcons, frame)
    end

    -- Layout all visible icons
    self:LayoutIcons()
end

function BuffReminders:HideAll()
    for _, frame in ipairs(self.visibleIcons) do
        AnimStop(frame)
    end
    wipe(self.visibleIcons)
    -- Also stop any lingering animations on pooled icons and clear slide state
    for _, frame in pairs(self.iconPool) do
        AnimStop(frame)
        if self.slideAnimator then
            self.slideAnimator:ResetFrame(frame)
        end
    end
    if self.slideAnimator then
        self.slideAnimator:Stop()
    end
    if self.containerFrame then
        self.containerFrame:Hide()
    end
end

-------------------------------------------------------------------------------
-- Throttled Update
-- Events fire rapidly (especially UNIT_AURA in combat). GetTime() returns the
-- same value within a single frame, so we use it to skip redundant checks.
-- The 1s ticker bypasses throttling as a safety net.
-------------------------------------------------------------------------------

function BuffReminders:ThrottledUpdate()
    local now = GetTime()
    if now == self._lastCheckTime then return end
    self._lastCheckTime = now
    self:OnUpdate()
end

-------------------------------------------------------------------------------
-- Event Handlers
-------------------------------------------------------------------------------

function BuffReminders:OnUnitAura(event, unit)
    if unit == "player" then
        self:ThrottledUpdate()
    end
end

function BuffReminders:OnGroupChanged()
    self:ThrottledUpdate()
end

function BuffReminders:OnCombatChanged()
    self:ThrottledUpdate()
end

function BuffReminders:OnRestingChanged()
    self:ThrottledUpdate()
end

function BuffReminders:OnSpellsChanged()
    -- Rebuild reminder list when spells change (leveling, respec)
    self:BuildReminderList()
    self:ThrottledUpdate()

    -- Rebuild Options UI spell list (spec key may have changed)
    local options = addon:GetModule("Options")
    if options and options.RebuildBuffReminderSpellArgs then
        options:RebuildBuffReminderSpellArgs()
    end
end

-------------------------------------------------------------------------------
-- Preview (shows a sample icon so users can see settings changes in real-time)
-------------------------------------------------------------------------------

-- A well-known spell icon per class for preview purposes
local PREVIEW_ICONS = {
    WARRIOR = 2457,     -- Battle Shout
    PALADIN = 19740,    -- Blessing of Might
    PRIEST = 1243,      -- Power Word: Fortitude
    DRUID = 1126,       -- Mark of the Wild
    MAGE = 1459,        -- Arcane Intellect
    WARLOCK = 28176,    -- Fel Armor
    SHAMAN = 24398,     -- Water Shield
    HUNTER = 19506,     -- Trueshot Aura
    ROGUE = 2823,       -- Deadly Poison
}

function BuffReminders:ShowPreview()
    if not self.initialized then return end
    if not self.containerFrame then return end

    -- Use a unique key that won't collide with spellID-keyed pool entries
    local frame = self:GetOrCreateIcon("preview")

    -- Pick an icon for this class
    local previewSpellID = PREVIEW_ICONS[self.playerClass] or 2457
    local _, _, spellIcon = GetSpellInfo(previewSpellID)
    if spellIcon then
        frame.icon:SetTexture(spellIcon)
    end

    -- Position at center of container
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", self.containerFrame, "CENTER", 0, 0)

    -- Apply current settings
    self:UpdateIconSize()
    self:UpdateAlpha()
    self:UpdatePosition()

    -- Show with animation
    self.containerFrame:Show()
    AnimAppear(frame)

    self._previewFrame = frame
    self._previewActive = true
end

function BuffReminders:HidePreview()
    if not self._previewActive then return end
    self._previewActive = false

    if self._previewFrame then
        AnimDisappear(self._previewFrame)
        self._previewFrame = nil
    end
end

function BuffReminders:IsPreviewActive()
    return self._previewActive == true
end

function BuffReminders:RefreshPreview()
    if not self._previewActive then return end
    if not self._previewFrame then return end

    self:UpdateIconSize()
    self:UpdateAlpha()
    self:UpdatePosition()
end

-------------------------------------------------------------------------------
-- Refresh (profile change, settings update)
-------------------------------------------------------------------------------

function BuffReminders:Refresh()
    if not self.initialized then return end
    
    self:BuildReminderList()
    self:UpdateIconSize()
    self:UpdatePosition()
    self:UpdateAlpha()

    -- If preview is active, refresh it instead of running normal update
    if self._previewActive then
        self:RefreshPreview()
        return
    end

    self:OnUpdate()
end
