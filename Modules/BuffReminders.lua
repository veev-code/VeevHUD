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

local _, addon = ...
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

-- LibSpellDB `defaultTrackTarget` (raw string) → TRACK_TARGET enum
local DEFAULT_TRACK_TARGET = {
    raid = TRACK_TARGET.RAID,
    party = TRACK_TARGET.PARTY,
    player = TRACK_TARGET.PLAYER,
}

-- Split mode constants for mixed-target exclusive groups
local SPLIT_MODE = {
    SELF = "self",   -- Self-target spells (Water Shield, Lightning Shield)
    ALLY = "ally",   -- Ally-target spells (Earth Shield)
}
BuffReminders.SPLIT_MODE = SPLIT_MODE  -- Exposed for Options UI

-- Check if offhand slot contains a weapon (not shield/held-in-offhand/empty)
local function HasOffhandWeapon()
    local itemID = GetInventoryItemID("player", 17)  -- INVSLOT_OFFHAND
    if not itemID then return false end
    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemID)
    return equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONOFFHAND"
end

-- True when a found buff satisfies both configured thresholds (or threshold is unset/0).
local function BuffMeetsThresholds(remaining, stacks, config)
    if config.timeRemaining and config.timeRemaining > 0 and remaining < config.timeRemaining then
        return false
    end
    if config.minStacks and config.minStacks > 0 and stacks < config.minStacks then
        return false
    end
    return true
end

-- True when a group unit should be included in buff checks (alive, online, in range).
local function IsValidGroupUnit(unit)
    return UnitExists(unit) and not UnitIsDead(unit) and not UnitIsGhost(unit)
        and UnitIsConnected(unit) and UnitIsVisible(unit)
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
-- Mixed-Target Exclusive Group Detection
-- Cached per-group; result is session-static (LibSpellDB data doesn't change).
-------------------------------------------------------------------------------

BuffReminders._mixedTargetCache = {}

-- Check if an exclusive buff group has mixed auraTargets (some self, some ally).
-- Returns selfSpells, allySpells arrays if mixed, or nil, nil if not.
-- Results are cached — safe to call from hot paths like GetSpellDefaults.
function BuffReminders:GetMixedTargetSplit(groupName)
    local cached = self._mixedTargetCache[groupName]
    if cached ~= nil then
        if cached == false then return nil, nil end
        return cached[1], cached[2]
    end

    local LibSpellDB = self.LibSpellDB
    if not LibSpellDB then
        self._mixedTargetCache[groupName] = false
        return nil, nil
    end

    local groupInfo = LibSpellDB.BuffGroups[groupName]
    if not groupInfo or groupInfo.relationship ~= "exclusive" then
        self._mixedTargetCache[groupName] = false
        return nil, nil
    end

    local selfSpells, allySpells = {}, {}
    for _, gSpellID in ipairs(groupInfo.spells) do
        local at = LibSpellDB:GetAuraTarget(gSpellID)
        if at == "self" then
            table.insert(selfSpells, gSpellID)
        else
            -- "ally", "none", or nil all go into allySpells — only explicitly
            -- "self" spells are self-only. This prevents raid-wide buffs like
            -- Greater Blessings (auraTarget="none") from being misclassified.
            table.insert(allySpells, gSpellID)
        end
    end

    if #allySpells > 0 and #selfSpells > 0 then
        self._mixedTargetCache[groupName] = {selfSpells, allySpells}
        return selfSpells, allySpells
    end

    self._mixedTargetCache[groupName] = false
    return nil, nil
end

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
    
    -- OOC default for long buffs (5+ min) that are purgeable or LONG_BUFF-tagged.
    -- Short purgeable buffs (Battle Shout etc.) need in-combat reminders. Hunter
    -- aspects are LONG_BUFF but duration-less, so the gate keeps them on ANY.
    local hasLongDuration = spellData.duration and spellData.duration >= 300
    if hasLongDuration and (IsSpellPurgeable(spellData) or LibSpellDB:HasTag(spellID, "LONG_BUFF")) then
        defaults.combatState = COMBAT_STATE.OOC
    end

    -- CREATES_CONSUMABLE spells (Conjure Mana Gem, Create Healthstone) default OOC.
    -- Only the highest-known rank defaults to enabled; lower ranks are opt-in to
    -- avoid overwhelming the screen (e.g., 5 mana gem reminders at once).
    -- _highestConsumable is computed once in BuildReminderList (rebuilds on SPELLS_CHANGED).
    if LibSpellDB:HasTag(spellID, "CREATES_CONSUMABLE") then
        defaults.combatState = COMBAT_STATE.OOC
        if defaults.enabled and not self._highestConsumable[spellID] then
            defaults.enabled = false
        end
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
    
    -- For ally-target spells in mixed-target exclusive groups (e.g., Earth Shield
    -- in SHAMAN_SHIELD), default to party tracking. The split creates a separate
    -- reminder for the ally spell, and checking party members is the useful default.
    if spellData.buffGroup and defaults.groupTrackable then
        local selfSpells, allySpells = self:GetMixedTargetSplit(spellData.buffGroup)
        if selfSpells and allySpells then
            local auraTarget = LibSpellDB:GetAuraTarget(spellID)
            if auraTarget == "ally" then
                defaults.trackTarget = TRACK_TARGET.PARTY
            end
        end
    end

    -- Explicit per-spell default override from LibSpellDB. Used for ally-target
    -- buffs where player-self tracking is meaningless (e.g., Soulstone — only
    -- one exists raid-wide, so raid is the only meaningful default).
    if defaults.groupTrackable and spellData.defaultTrackTarget then
        defaults.trackTarget = DEFAULT_TRACK_TARGET[spellData.defaultTrackTarget] or defaults.trackTarget
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
        self.Utils:LogDebug("BuffReminders: Tracking spell", r.spellID, r.spellData.name or "?", "group:", r.buffGroup or "none", "split:", r.splitMode or "none")
    end
end

function BuffReminders:BuildReminderList()
    wipe(self.reminders)
    self._highestConsumable = {}  -- spellID -> true for the highest-known CREATES_CONSUMABLE rank
    self._buffNameSetCache = nil  -- invalidate on rebuild; spell names may have just become resolvable
    self.hasAllySplit = false

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
                    -- Check for mixed-target exclusive groups (e.g., SHAMAN_SHIELD
                    -- has Earth Shield on allies + Water/Lightning Shield on self).
                    -- Split into separate reminders so each can be tracked independently.
                    local selfSpells, allySpells = self:GetMixedTargetSplit(groupName)
                    if selfSpells and allySpells then
                        -- Self-target reminder (Water Shield / Lightning Shield)
                        local selfRep = selfSpells[1]
                        local selfData = self.LibSpellDB:GetSpellInfo(selfRep) or spellData
                        table.insert(self.reminders, {
                            spellID = selfRep,
                            spellData = selfData,
                            buffGroup = groupName,
                            splitMode = SPLIT_MODE.SELF,
                            splitSelfSpells = selfSpells,
                            splitAllySpells = allySpells,
                        })
                        -- Ally-target reminder(s) (Earth Shield)
                        for _, allyID in ipairs(allySpells) do
                            local allyData = self.LibSpellDB:GetSpellInfo(allyID) or spellData
                            table.insert(self.reminders, {
                                spellID = allyID,
                                spellData = allyData,
                                buffGroup = groupName,
                                splitMode = SPLIT_MODE.ALLY,
                                splitSelfSpells = selfSpells,
                                splitAllySpells = allySpells,
                            })
                        end
                        self.hasAllySplit = true
                    else
                        -- Normal: single reminder for the group
                        local repSpellID = groupInfo.spells[1]
                        local repData = self.LibSpellDB:GetSpellInfo(repSpellID) or spellData
                        table.insert(self.reminders, {
                            spellID = repSpellID,
                            spellData = repData,
                            buffGroup = groupName,
                        })
                    end
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
    
    -- Append CREATES_CONSUMABLE spells (Conjure Mana Gem, Create Healthstone).
    -- These are stock-restock reminders, not buff reminders — they fire when the
    -- created item's bag count is zero. They share the BuffReminders pipeline so
    -- they inherit per-spec config, combat-state gating, and the alert UI.
    local createsConsumable = self.LibSpellDB:GetSpellsByClassAndTag(self.playerClass, "CREATES_CONSUMABLE")
    if createsConsumable then
        -- Track spellIDs already added by the LONG_BUFF loop above to avoid duplicates
        local seenSpells = {}
        for _, r in ipairs(self.reminders) do
            seenSpells[r.spellID] = true
        end

        -- Find the highest requiredLevel among known CREATES_CONSUMABLE spells.
        -- Only that rank defaults to enabled; lower ranks are opt-in to avoid
        -- overwhelming the screen (e.g., 5 mana gem reminders at once).
        -- Computed once at build time (rebuilds on SPELLS_CHANGED).
        local highestKnownLevel  -- nil when no ranked consumable is known
        for _, cData in pairs(createsConsumable) do
            if cData.requiredLevel and IsSpellKnown(cData.spellID) then
                highestKnownLevel = math.max(highestKnownLevel or 0, cData.requiredLevel)
            end
        end

        for spellID, spellData in pairs(createsConsumable) do
            if not seenSpells[spellID] then
                -- Spells without requiredLevel (Healthstone) are always highest.
                -- Ranked spells: only the highest known rank is marked; if none
                -- are known yet, none are marked (all default to disabled).
                local isHighest = not spellData.requiredLevel
                    or (highestKnownLevel and spellData.requiredLevel >= highestKnownLevel)
                if isHighest then
                    self._highestConsumable[spellID] = true
                end
                table.insert(self.reminders, {
                    spellID = spellID,
                    spellData = spellData,
                    isConsumable = true,
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
    -- Bag changes drive CREATES_CONSUMABLE reminders (Conjure Mana Gem, Healthstone).
    -- Set a dirty flag so the next 1s ticker re-checks item counts, rather than
    -- running the full OnUpdate on every bag mutation (looting, vendoring, etc.).
    self.Events:RegisterEvent(self, "BAG_UPDATE_DELAYED", self.OnBagChanged)
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
    self.Utils:ApplyFontOutline(text, addon:GetFont(), fontSize, db)
    text:SetPoint("CENTER", textContainer, "CENTER", 0, 0)
    text:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)
    frame.text = text

    -- Stacks text (top right, matching CooldownIcons style)
    local stacksFontSize = math.max(10, math.floor(iconSize * 0.26))
    local stacks = textContainer:CreateFontString(nil, "OVERLAY", nil, 7)
    self.Utils:ApplyFontOutline(stacks, addon:GetFont(), stacksFontSize, db)
    stacks:SetPoint("TOPRIGHT", textContainer, "TOPRIGHT", 2, 2)
    stacks:SetJustifyH("RIGHT")
    stacks:SetJustifyV("TOP")
    stacks:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)
    frame.stacks = stacks

    -- Build animation groups on the visual frame
    SetupAnimations(visual)

    -- Apply full texcoords (no icon zoom for buff reminders — they're alerts, not ability icons)
    if self.iconFactory and frame.icon then
        self.iconFactory:ApplyTexCoords(
            {frame},
            0,
            1.0,
            self.MasqueGroup
        )
    end

    frame:Hide()

    self.iconPool[key] = frame
    return frame
end

-- Apply full texcoords to all buff reminder icons (no icon zoom — they're alerts, not ability icons).
-- Delegates to IconFrameFactory which handles Masque compositing.
function BuffReminders:ApplyIconTexCoords()
    if self.iconFactory then
        local icons = {}
        for _, frame in pairs(self.iconPool) do
            icons[#icons + 1] = frame
        end
        self.iconFactory:ApplyTexCoords(
            icons,
            0,
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
            self.Utils:ApplyFontOutline(frame.text, addon:GetFont(), fontSize, db)
            frame.text:SetTextColor(addon.db.profile.appearance.textColor.r, addon.db.profile.appearance.textColor.g, addon.db.profile.appearance.textColor.b)
        end
        if frame.stacks then
            self.Utils:ApplyFontOutline(frame.stacks, addon:GetFont(), stacksFontSize, db)
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

-- Soulstone/Healthstone-style cooldown lookup. Item-bag fallback to action-bar
-- slot so we still see the CD after the item is consumed.
function BuffReminders:GetItemBasedCooldown(reminder, spellID, spellData)
    local cdRemaining = self.LibSpellDB:GetItemCooldown(spellID)
    if cdRemaining and cdRemaining > 0 then
        return cdRemaining
    end

    local now = GetTime()
    local slot = reminder._actionBarSlot
    if slot then
        local start, dur = GetActionCooldown(slot)
        if start and start > 0 and dur > C.GCD_THRESHOLD then
            local remaining = (start + dur) - now
            if remaining > 0 then
                return remaining
            end
        end
    end

    if not slot or not reminder._actionBarSlotNextScan or now >= reminder._actionBarSlotNextScan then
        local newSlot = self.Utils:FindActionBarSlotForSpellOrItem(spellID, spellData)
        reminder._actionBarSlotNextScan = now + 5
        if newSlot and newSlot ~= slot then
            reminder._actionBarSlot = newSlot
            local start, dur = GetActionCooldown(newSlot)
            if start and start > 0 and dur > C.GCD_THRESHOLD then
                local remaining = (start + dur) - now
                if remaining > 0 then
                    return remaining
                end
            end
        end
    end

    return 0
end

-- Build the set of buff names to match for a spell. For spells with appliesBuff
-- (e.g., Soulstone — cast name "Create Soulstone" differs from buff name
-- "Soulstone Resurrection"), the set is the union of cast name + every
-- appliesBuff name. Cached per spellID since the result is deterministic and
-- this is called up to 40×/tick from CheckBuffOnGroup.
function BuffReminders:GetBuffNameSet(spellID)
    local cache = self._buffNameSetCache
    if not cache then
        cache = {}
        self._buffNameSetCache = cache
    end
    local nameSet = cache[spellID]
    if nameSet ~= nil then return nameSet end

    nameSet = {}
    local castName = GetSpellInfo(spellID)
    if castName then nameSet[castName] = true end

    local spellData = self.LibSpellDB:GetSpellInfo(spellID)
    if spellData and spellData.appliesBuff then
        for _, buffID in ipairs(spellData.appliesBuff) do
            local buffName = GetSpellInfo(buffID)
            if buffName then nameSet[buffName] = true end
        end
    end

    cache[spellID] = nameSet
    return nameSet
end

-- Check if a buff (by name) is present on a unit
-- playerOnly: if true, only match buffs where source == "player"
function BuffReminders:IsBuffOnUnit(unit, spellID, playerOnly)
    if not UnitExists(unit) then return false, 0, 0 end

    local nameSet = self:GetBuffNameSet(spellID)
    if not next(nameSet) then return false, 0, 0 end

    -- Also check all rank names (they share the same name)
    for i = 1, 40 do
        local name, _, count, _, duration, expirationTime, source = UnitBuff(unit, i)
        if not name then break end

        if nameSet[name] then
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

    -- Clear per-tick stash so an early return below doesn't leave stale state
    -- for OnUpdate to consume.
    reminder._cdRemaining = nil

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
    -- For split exclusive groups, restrict to the relevant spell subset.
    local groupSpells = nil
    local activeSpellID = nil  -- The spell we'll use for known/usable checks

    if reminder.buffGroup then
        local groupInfo = self.LibSpellDB.BuffGroups[reminder.buffGroup]
        if groupInfo then
            -- Determine which spells to search
            if reminder.splitMode == SPLIT_MODE.SELF then
                groupSpells = reminder.splitSelfSpells
            elseif reminder.splitMode == SPLIT_MODE.ALLY then
                groupSpells = nil  -- Single spell, no group search
            else
                groupSpells = groupInfo.spells
            end

            if groupSpells then
                -- Find first known+usable spell in the (possibly restricted) group
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
    
    -- Item-applied ally buff (Soulstone): UnitBuff source can be unreliable for
    -- item-applied auras, so gate on the use-cooldown instead. For these spells
    -- the item-CD duration equals the buff duration, so cdRemaining == buff
    -- remaining and the user's timeRemaining threshold still applies.
    local hasItemAppliedBuff = spellData.cooldownItemIDs
        and spellData.appliesBuff
        and spellData.itemCooldown
        and self.LibSpellDB:GetAuraTarget(spellID) == "ally"

    local hasItemInBag = false
    if hasItemAppliedBuff then
        local cdRemaining = self:GetItemBasedCooldown(reminder, spellID, spellData)
        local threshold = (config.timeRemaining and config.timeRemaining > 0) and config.timeRemaining or 0
        if cdRemaining > threshold then
            self.Utils:LogDebug("BuffReminders: " .. (spellData.name or spellID) .. " - on cooldown (" .. string.format("%.1f", cdRemaining) .. "s > threshold " .. threshold .. ")")
            return false
        end
        if self._bagDirty or reminder._cachedItemCount == nil then
            reminder._cachedItemCount = self.LibSpellDB:GetCreatedItemCount(spellID)
        end
        hasItemInBag = (reminder._cachedItemCount or 0) > 0
        if threshold > 0 and cdRemaining > 0 then
            reminder._cdRemaining = cdRemaining
        end
    end

    -- Check if spell is usable (has enough resources, correct form, etc.)
    local isUsable, notEnoughResources = IsUsableSpell(highestRank)
    local db = addon.db.profile.buffReminders
    if isUsable or hasItemInBag then
        -- ready to cast, or have an existing item to apply
    elseif notEnoughResources and not db.respectResourceCost and not hasItemAppliedBuff then
        -- known but can't afford right now — still remind (item-applied buffs opt out: nothing to act on)
    else
        self.Utils:LogDebug("BuffReminders: " .. (spellData.name or spellID) .. " - not usable (rank " .. highestRank .. ", noResources=" .. tostring(notEnoughResources) .. ")")
        return false
    end
    
    -- Most LONG_BUFF spells have no cooldown, but some (e.g., Fear Ward) have
    -- CD equal to duration — no point nagging when it's impossible to recast.
    if spellData.cooldown and spellData.cooldown > 0 then
        if addon.Utils:IsSpellOnRealCooldown(highestRank) then
            return false
        end
    end

    -- Pet requirement check (e.g., Soul Link requires an alive pet)
    if self.LibSpellDB:HasTag(spellID, "REQUIRES_PET") then
        if not UnitExists("pet") or UnitIsDead("pet") then
            return false
        end
    end

    -- CREATES_CONSUMABLE: remind when bag count of the created item is zero.
    -- Soul Shard / reagent gating is already handled by IsUsableSpell above
    -- (notEnoughResources path), so Create Healthstone correctly suppresses
    -- when no Soul Shard is in bags.
    if reminder.isConsumable then
        -- Item counts can only change on bag events; reuse cached result
        -- between bag changes to avoid redundant GetItemCount calls on
        -- every 1s tick.
        if self._bagDirty or reminder._cachedItemCount == nil then
            reminder._cachedItemCount = self.LibSpellDB:GetCreatedItemCount(spellID)
        end
        local count = reminder._cachedItemCount
        if not count then return false end
        return count == 0
    end

    -- Spell-based weapon enchants (shaman imbues) pass through IsSpellKnown/IsUsableSpell above,
    -- then check actual enchant status via GetWeaponEnchantInfo instead of UnitBuff.
    if spellData.weaponEnchant then
        return self:CheckWeaponEnchants(config)
    end
    
    -- Split suppression: if the ally-target spell (e.g., Earth Shield) is active
    -- ON THE PLAYER, the player made a deliberate choice to use it on self.
    -- Suppress BOTH the self-shield reminder (don't nag about Water Shield)
    -- AND the ally-target reminder (don't nag to put ES on a party member).
    if reminder.splitMode and reminder.splitAllySpells then
        for _, allySpellID in ipairs(reminder.splitAllySpells) do
            local found = self:IsBuffOnUnit("player", allySpellID, true)  -- playerOnly
            if found then
                self.Utils:LogDebug("BuffReminders: split suppressed (" .. reminder.splitMode .. ") - ally spell " .. allySpellID .. " active on player")
                return false
            end
        end
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
        if reminder.splitMode == SPLIT_MODE.ALLY then
            local shouldRemind, allyRemaining, allyStacks = self:CheckBuffOnAllies(activeSpellID, nil, config, trackTarget)
            -- Stash for OnUpdate alert display (avoids double group scan)
            reminder._allyRemaining = allyRemaining
            reminder._allyStacks = allyStacks
            return shouldRemind
        end
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

    return not BuffMeetsThresholds(remaining, stacks, config)
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

    -- Single-target ally buffs (e.g., Soulstone): only one instance of the
    -- player's own buff can exist, so finding it on ANY visible unit suffices.
    -- Filter by player source so another caster's buff doesn't suppress ours.
    if self.LibSpellDB:IsSingleTarget(spellID) and self.LibSpellDB:GetAuraTarget(spellID) == "ally" then
        local function unitHasOurBuff(unit)
            local found, remaining, stacks
            if groupSpells then
                found, remaining, stacks = self:IsBuffGroupOnUnit(unit, groupSpells, true)
            else
                found, remaining, stacks = self:IsBuffOnUnit(unit, spellID, true)
            end
            return found and BuffMeetsThresholds(remaining, stacks, config)
        end

        if unitHasOurBuff("player") then return false end
        for i = 1, count do
            local unit = prefix .. i
            if IsValidGroupUnit(unit) and unitHasOurBuff(unit) then return false end
        end
        return true
    end

    -- Always check player too
    local playerMissing = self:CheckBuffOnPlayer(spellID, groupSpells, config)
    if playerMissing then return true end

    for i = 1, count do
        local unit = prefix .. i
        if IsValidGroupUnit(unit) then
            local found, remaining, stacks
            if groupSpells then
                found, remaining, stacks = self:IsBuffGroupOnUnit(unit, groupSpells)
            else
                found, remaining, stacks = self:IsBuffOnUnit(unit, spellID)
            end

            if not found or not BuffMeetsThresholds(remaining, stacks, config) then
                return true  -- At least one group member missing or below threshold
            end
        end
    end

    return false
end

-- Check party/raid members (NOT player) for a buff. Used for ally-target
-- spells in split exclusive groups (e.g., Earth Shield on tank).
-- When solo, returns false (no allies to check = no reminder needed).
-- Returns shouldRemind, remaining, stacks — remaining/stacks are set when
-- the buff exists but is below thresholds (for alert text display).
function BuffReminders:CheckBuffOnAllies(spellID, groupSpells, config, trackTarget)
    local isInRaid = IsInRaid()
    local isInGroup = IsInGroup()

    -- Intelligent downsize: raid -> party -> solo
    if trackTarget == TRACK_TARGET.RAID and not isInRaid then
        if isInGroup then
            trackTarget = TRACK_TARGET.PARTY
        else
            return false  -- Solo, no allies to check
        end
    elseif trackTarget == TRACK_TARGET.PARTY and not isInGroup then
        return false  -- Solo, no allies to check
    end

    local prefix, count
    if trackTarget == TRACK_TARGET.RAID and isInRaid then
        prefix = "raid"
        count = GetNumGroupMembers()
    else
        prefix = "party"
        count = GetNumSubgroupMembers()
    end

    for i = 1, count do
        local unit = prefix .. i
        if IsValidGroupUnit(unit) then
            local found, remaining, stacks
            if groupSpells then
                found, remaining, stacks = self:IsBuffGroupOnUnit(unit, groupSpells)
            else
                found, remaining, stacks = self:IsBuffOnUnit(unit, spellID)
            end

            if found then
                if not BuffMeetsThresholds(remaining, stacks, config) then
                    return true, remaining, stacks  -- below threshold (carry for alert text)
                end
                return false  -- Buff found on an ally and thresholds OK
            end
        end
    end

    -- No ally has the buff — should remind
    return true
end

-------------------------------------------------------------------------------
-- Update Loop
-------------------------------------------------------------------------------

function BuffReminders:OnBagChanged()
    self._bagDirty = true
end

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

                -- For non-split buff groups, show the best spell to cast.
                -- Split reminders already show the correct spell directly.
                if reminder.buffGroup and not reminder.splitMode then
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
                        if reminder._cdRemaining then
                            -- Soulstone-style: CD remaining == buff remaining
                            remaining = reminder._cdRemaining
                            found = true
                        elseif reminder.splitMode == SPLIT_MODE.ALLY then
                            -- Use data stashed by CheckBuffOnAllies (avoids double scan)
                            remaining = reminder._allyRemaining
                            stacks = reminder._allyStacks
                            found = remaining or stacks
                        elseif reminder.splitMode == SPLIT_MODE.SELF and reminder.splitSelfSpells then
                            found, remaining, stacks = self:IsBuffGroupOnUnit("player", reminder.splitSelfSpells, true)
                        elseif reminder.buffGroup then
                            local groupInfo = self.LibSpellDB.BuffGroups[reminder.buffGroup]
                            if groupInfo then
                                found, remaining, stacks = self:IsBuffGroupOnUnit("player", groupInfo.spells)
                            end
                        else
                            found, remaining, stacks = self:IsBuffOnUnit("player", spellID)
                        end
                        if found then
                            if showTime and remaining and remaining < config.timeRemaining then
                                alertRemaining = remaining
                            end
                            if showStacks and stacks and stacks < config.minStacks then
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
    self._bagDirty = false
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
        -- For exclusive groups, suggest an uncovered spell to cast.
        -- Priority (cfg.priority) wins when uncovered; otherwise pick the
        -- first uncovered spell in group order. If all are covered, fall
        -- back to priority or group default.
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

        -- If priority is set and uncovered, use it directly
        if prioritySpellID and not self:IsBuffOnUnit("player", prioritySpellID) then
            return prioritySpellID
        end

        -- Otherwise find any uncovered spell; fall back to priority or group default
        for _, gSpellID in ipairs(groupInfo.spells) do
            local hr = self.LibSpellDB:GetHighestKnownRank(gSpellID)
            if hr and IsSpellKnown(hr) then
                if not self:IsBuffOnUnit("player", gSpellID) then
                    return gSpellID
                end
            end
        end
        return prioritySpellID or defaultSpellID
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
            addon.SoundManager:PlaySound(addon:GetBuffReminderSound(alertKey) or addon.db.profile.buffReminders.soundOnMissing)
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
    elseif self.hasAllySplit and unit ~= "target" and unit ~= "focus" then
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

-- Resolve a preview icon for a class from LibSpellDB (first BUFF by lowest spellID,
-- preferring LONG_BUFF, then any BUFF-tagged spell)
local previewIconCache = {}
local function GetPreviewSpellID(class)
    if previewIconCache[class] then return previewIconCache[class] end
    local LibSpellDB = LibStub and LibStub("LibSpellDB-1.0", true)
    if not LibSpellDB then return nil end

    -- Try LONG_BUFF first (30+ min class buffs), fall back to any BUFF
    for _, tag in ipairs({"LONG_BUFF", "BUFF"}) do
        local spells = LibSpellDB:GetSpellsByClassAndTag(class, tag)
        local lowest
        for id in pairs(spells) do
            if not lowest or id < lowest then lowest = id end
        end
        if lowest then
            previewIconCache[class] = lowest
            return lowest
        end
    end
    return nil
end

function BuffReminders:ShowPreview()
    if not self.initialized then return end
    if not self.containerFrame then return end

    -- Use a unique key that won't collide with spellID-keyed pool entries
    local frame = self:GetOrCreateIcon("preview")

    -- Pick an icon for this class (first LONG_BUFF or BUFF from LibSpellDB)
    local previewSpellID = GetPreviewSpellID(self.playerClass)
    if previewSpellID then
        local _, _, spellIcon = GetSpellInfo(previewSpellID)
        if spellIcon then
            frame.icon:SetTexture(spellIcon)
        end
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
