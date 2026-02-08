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

-- Active reminders state
BuffReminders.reminders = {}      -- Array of active reminder configs
BuffReminders.activeAlerts = {}   -- spellID -> true for currently shown reminders
BuffReminders.iconPool = {}       -- Recycled icon frames
BuffReminders.visibleIcons = {}   -- Currently visible icon frames
BuffReminders.containerFrame = nil
BuffReminders.initialized = false

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
function BuffReminders:GetSpellConfig(spellID)
    local defaults = self:GetSpellDefaults(spellID)
    if not defaults then return nil end
    
    local db = addon.db and addon.db.profile and addon.db.profile.buffReminders
    if not db then return defaults end
    
    local userConfig = db.spellConfig[spellID]
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
    self.LibSpellDB = addon.LibSpellDB
    self.playerClass = addon.playerClass
    self.playerGUID = UnitGUID("player")
    
    if not self.LibSpellDB then
        self.Utils:LogError("BuffReminders: LibSpellDB not available")
        return
    end
    
    -- Migrate stale settings from older versions
    self:MigrateSettings()
    
    -- Build the list of buff reminders for this class
    self:BuildReminderList()
    
    self.initialized = true
    self.Utils:LogInfo("BuffReminders: Initialized with", #self.reminders, "reminders for", self.playerClass)
    for _, r in ipairs(self.reminders) do
        self.Utils:LogDebug("BuffReminders: Tracking spell", r.spellID, r.spellData.name or "?", "group:", r.buffGroup or "none")
    end
end

function BuffReminders:MigrateSettings()
    local db = addon.db and addon.db.profile and addon.db.profile.buffReminders
    if not db then return end
    
    -- v1 → v2: Remove iconZoom (now always 0), reset alpha to new default
    if db.iconZoom ~= nil then
        db.iconZoom = nil
        self.Utils:LogDebug("BuffReminders: Migrated - removed iconZoom")
    end
    if db.alpha and db.alpha > 0.5 then
        -- Old default was 1.0; migrate to new semi-transparent default
        db.alpha = 0.25
        self.Utils:LogDebug("BuffReminders: Migrated - alpha reset to 0.25")
    end
    if db.iconSize and db.iconSize <= 64 then
        -- Old default was 64; migrate to new larger default
        db.iconSize = 128
        self.Utils:LogDebug("BuffReminders: Migrated - iconSize reset to 128")
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
            -- Non-grouped spell: add directly
            local shouldAdd = true
            
            -- Skip spells that are not relevant for current spec
            if spellData.specs and self.LibSpellDB.IsSpellRelevantForSpec then
                if not self.LibSpellDB:IsSpellRelevantForSpec(spellID) then
                    shouldAdd = false
                end
            end
            
            if shouldAdd then
                table.insert(self.reminders, {
                    spellID = spellID,
                    spellData = spellData,
                    buffGroup = nil,
                })
            end
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
    
    -- Container frame, anchored relative to the HUD
    local container = CreateFrame("Frame", "VeevHUDBuffReminders", UIParent)
    container:SetSize(400, 60)
    container:SetFrameStrata("MEDIUM")
    container:SetFrameLevel(15)
    container:EnableMouse(false)
    self.containerFrame = container
    
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
    local db = addon.db and addon.db.profile and addon.db.profile.buffReminders
    local alpha = db and db.alpha or 0.25
    self.containerFrame:SetAlpha(alpha)
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
        if frame:IsShown() and frame._brPulseGroup then
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
        frame:Hide()
        frame:SetAlpha(0)
        -- If no visible icons remain and no other frames are animating out, hide container
        local container = frame:GetParent()
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

-- Stop all animations on a frame
local function AnimStopAll(frame)
    if frame._brStartGroup then frame._brStartGroup:Stop() end
    if frame._brPulseGroup then frame._brPulseGroup:Stop() end
    if frame._brFinishGroup then frame._brFinishGroup:Stop() end
end

-- Start appear animation on a frame
local function AnimAppear(frame)
    AnimStopAll(frame)
    frame:SetAlpha(0)
    frame:Show()
    frame._brStartGroup:Play()
end

-- Start disappear animation on a frame (will Hide when done via OnFinished)
local function AnimDisappear(frame)
    if frame._brFinishGroup and frame._brFinishGroup:IsPlaying() then return end
    AnimStopAll(frame)
    frame:SetAlpha(1)
    frame._brFinishGroup:Play()
end

-- Immediately stop and hide (no animation)
local function AnimStop(frame)
    AnimStopAll(frame)
    frame:SetAlpha(0)
    frame:Hide()
end

-- Check if a frame is in the pulsing (fully visible) state
local function AnimIsPulsing(frame)
    return frame._brPulseGroup and frame._brPulseGroup:IsPlaying()
end

-- Check if a frame is actively animating in (shrink-in still playing)
local function AnimIsAppearing(frame)
    return frame._brStartGroup and frame._brStartGroup:IsPlaying()
end

-------------------------------------------------------------------------------
-- Icon Creation and Management
-------------------------------------------------------------------------------

function BuffReminders:GetOrCreateIcon(index)
    if self.iconPool[index] then
        return self.iconPool[index]
    end

    local db = addon.db and addon.db.profile and addon.db.profile.buffReminders
    local iconSize = db and db.iconSize or 64

    -- Frame for animations (scale/alpha)
    local frame = CreateFrame("Frame", nil, self.containerFrame)
    frame:SetSize(iconSize, iconSize)
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(20)

    -- Spell icon texture — no zoom, use the game's built-in icon border
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    frame.icon = icon

    -- Build animation groups (native WoW API - safe without CooldownFrameTemplate)
    SetupAnimations(frame)

    frame:Hide()

    self.iconPool[index] = frame
    return frame
end

function BuffReminders:UpdateIconSize()
    local db = addon.db and addon.db.profile and addon.db.profile.buffReminders
    local iconSize = db and db.iconSize or 64

    for _, frame in pairs(self.iconPool) do
        frame:SetSize(iconSize, iconSize)
    end
end

function BuffReminders:LayoutIcons()
    local db = addon.db and addon.db.profile and addon.db.profile.buffReminders
    local iconSize = db and db.iconSize or 64
    local spacing = db and db.iconSpacing or 8

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

    -- Calculate total width; use CENTER anchoring so scale doesn't cause drift
    local totalWidth = (numVisible * iconSize) + ((numVisible - 1) * spacing)
    local startX = -totalWidth / 2

    for i, frame in ipairs(self.visibleIcons) do
        frame:ClearAllPoints()
        -- CENTER anchor: scaling won't shift the icon's visual position
        local centerX = startX + (i - 1) * (iconSize + spacing) + iconSize / 2
        frame:SetPoint("CENTER", self.containerFrame, "CENTER", centerX, 0)
    end
end

-------------------------------------------------------------------------------
-- Buff Checking Logic
-------------------------------------------------------------------------------

-- Check if a buff (by name) is present on a unit
function BuffReminders:IsBuffOnUnit(unit, spellID)
    if not UnitExists(unit) then return false, 0, 0 end
    
    local spellName = GetSpellInfo(spellID)
    if not spellName then return false, 0, 0 end
    
    -- Also check all rank names (they share the same name)
    for i = 1, 40 do
        local name, _, count, _, duration, expirationTime = UnitBuff(unit, i)
        if not name then break end
        
        if name == spellName then
            local remaining = 0
            if expirationTime and expirationTime > 0 then
                remaining = expirationTime - GetTime()
            elseif duration == 0 then
                remaining = 999999  -- Permanent buff
            end
            return true, remaining, count or 0
        end
    end
    
    return false, 0, 0
end

-- Check if ANY spell in a buff group is active on a unit
function BuffReminders:IsBuffGroupOnUnit(unit, groupSpells)
    for _, groupSpellID in ipairs(groupSpells) do
        -- Get all rank spell IDs for this spell
        local spellName = GetSpellInfo(groupSpellID)
        if spellName then
            local found, remaining, stacks = self:IsBuffOnUnit(unit, groupSpellID)
            if found then
                return true, remaining, stacks
            end
        end
    end
    return false, 0, 0
end

-- Check if weapon enchants need reminding (for rogue poisons, shaman imbues)
-- Checks both MH and OH (if player is dual-wielding with a weapon in OH).
-- GetWeaponEnchantInfo returns nil for OH values when no OH weapon exists
-- (e.g., shield or empty), vs false when a weapon exists but has no enchant.
function BuffReminders:CheckWeaponEnchants(config)
    local hasMHEnchant, mhExpiration, _, hasOHEnchant, ohExpiration = GetWeaponEnchantInfo()
    
    -- Check main hand
    if not hasMHEnchant then
        self.Utils:LogDebug("BuffReminders: weapon enchant - MH missing enchant")
        return true
    end
    
    -- Check off hand: hasOHEnchant is nil if no OH weapon (shield/empty),
    -- false if OH weapon exists but has no enchant, true if enchanted.
    -- Only remind if there IS an OH weapon without an enchant.
    if hasOHEnchant == false then
        self.Utils:LogDebug("BuffReminders: weapon enchant - OH weapon exists but no enchant")
        return true
    end
    
    -- Check time remaining thresholds
    if config.timeRemaining and config.timeRemaining > 0 then
        local mhRemaining = (mhExpiration or 0) / 1000
        if mhRemaining > 0 and mhRemaining < config.timeRemaining then
            self.Utils:LogDebug("BuffReminders: weapon enchant - MH expiring soon (" .. mhRemaining .. "s)")
            return true
        end
        if hasOHEnchant then
            local ohRemaining = (ohExpiration or 0) / 1000
            if ohRemaining > 0 and ohRemaining < config.timeRemaining then
                self.Utils:LogDebug("BuffReminders: weapon enchant - OH expiring soon (" .. ohRemaining .. "s)")
                return true
            end
        end
    end
    
    return false
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
        self.Utils:LogDebug("BuffReminders: " .. (spellData.name or spellID) .. " - not usable (rank " .. highestRank .. ", noResources=" .. tostring(notEnoughResources) .. ")")
        return false
    end
    
    -- Spell-based weapon enchants (shaman imbues) pass through IsSpellKnown/IsUsableSpell above,
    -- then check actual enchant status via GetWeaponEnchantInfo instead of UnitBuff.
    if spellData.weaponEnchant then
        return self:CheckWeaponEnchants(config)
    end
    
    -- Check buff status based on track target
    local trackTarget = config.trackTarget or TRACK_TARGET.PLAYER
    
    if trackTarget == TRACK_TARGET.PLAYER then
        return self:CheckBuffOnPlayer(activeSpellID, groupSpells, config)
    elseif trackTarget == TRACK_TARGET.PARTY or trackTarget == TRACK_TARGET.RAID then
        return self:CheckBuffOnGroup(activeSpellID, groupSpells, config, trackTarget)
    end
    
    return false
end

function BuffReminders:CheckBuffOnPlayer(spellID, groupSpells, config)
    local found, remaining, stacks
    
    if groupSpells then
        found, remaining, stacks = self:IsBuffGroupOnUnit("player", groupSpells)
    else
        found, remaining, stacks = self:IsBuffOnUnit("player", spellID)
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
    
    if resting then
        self:HideAll()
        return
    end
    if mounted then
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
            newAlerts[spellID] = true
            
            -- Determine which spell icon to show
            local displaySpellID = spellID
            
            -- For buff groups, show the best spell to cast
            if reminder.buffGroup then
                displaySpellID = self:GetBestSpellForGroup(reminder.buffGroup, spellID)
            end
            
            -- Get highest known rank for icon
            local highestRank = self.LibSpellDB:GetHighestKnownRank(displaySpellID)
            
            table.insert(alertList, {
                spellID = spellID,
                displaySpellID = highestRank or displaySpellID,
                reminder = reminder,
            })
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
        -- For exclusive groups, check user priority config, else use first known
        local db = addon.db and addon.db.profile and addon.db.profile.buffReminders
        if db and db.spellConfig then
            for _, gSpellID in ipairs(groupInfo.spells) do
                local cfg = db.spellConfig[gSpellID]
                if cfg and cfg.priority then
                    local hr = self.LibSpellDB:GetHighestKnownRank(gSpellID)
                    if hr and IsSpellKnown(hr) then
                        return gSpellID
                    end
                end
            end
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
    -- Build a set of currently active spellIDs for diffing
    local newSpellSet = {}
    for _, alert in ipairs(alertList) do
        newSpellSet[alert.spellID] = true
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

    -- Create/update icons for each alert
    for i, alert in ipairs(alertList) do
        local frame = self:GetOrCreateIcon(i)
        local sameSpell = frame._brSpellID == alert.spellID
        local wasAlreadyShown = sameSpell and (AnimIsPulsing(frame) or AnimIsAppearing(frame))

        -- Tag the frame with its current spell
        frame._brSpellID = alert.spellID

        -- Set icon texture
        local _, _, spellIcon = GetSpellInfo(alert.displaySpellID)
        if spellIcon then
            frame.icon:SetTexture(spellIcon)
        end

        -- Animate: appear with shrink-in (or keep pulsing if already shown)
        if not wasAlreadyShown then
            AnimAppear(frame)
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
    -- Also stop any lingering animations on pooled icons
    for _, frame in pairs(self.iconPool) do
        AnimStop(frame)
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

    -- Use existing icon slot 1 or create one
    local frame = self:GetOrCreateIcon(999)  -- High index to avoid clashing with real icons

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
