--[[
    VeevHUD - Buff Reminders Click Overlay (opt-in, OFF by default)

    Adds click-to-cast to Buff Reminders: an invisible SecureActionButton "hit
    zone" is placed over each reminder icon so left-clicking it casts the
    missing buff. Zones exist ONLY out of combat.

    ============================================================================
    WHY THIS FILE IS SHAPED THE WAY IT IS — READ BEFORE CHANGING ANYTHING
    ============================================================================

    THE WOW CONSTRAINT MODEL (as of Anniversary Edition, 2026 — unlikely to
    ever change; this is deliberate anti-automation design, not an API gap):

    1. Casting a spell from a click REQUIRES SecureActionButtonTemplate.
       Insecure addon code can never cast. There is no halfway version.

    2. Secure (protected) frames FREEZE during combat lockdown. Insecure code
       cannot Show(), Hide(), SetPoint(), SetParent(), or SetAttribute() on
       them until combat ends. Every such call fires ADDON_ACTION_BLOCKED.

    3. Protection PROPAGATES: the parent chain of a protected frame becomes
       protected, and so does any frame a protected frame is ANCHORED to.
       This is the vector that burned us in v1.0.202/203: secure reminder
       buttons lived in a container that was SetPoint-anchored to the main
       HUD frame, so VeevHUDFrame itself became protected and the 0.1s
       visibility ticker spammed ADDON_ACTION_BLOCKED all combat long.

    4. The sanctioned in-combat mechanisms (state drivers / secure handlers)
       react ONLY to macro conditionals ([combat], [form], [@target,exists]…).
       They CANNOT see auras. There is deliberately no "[missingbuff:X]" —
       a clickable button driven by buff state would be a rotation bot.

    Buff reminders are definitionally aura-driven (icons appear when a buff
    drops, vanish when applied, re-sort as state changes), so a reminder icon
    that is ITSELF a secure button can never work: (2)+(4) forbid moving or
    toggling it mid-combat, which also caused the v1.0.202 "button stuck on a
    stale spell after the first click" bug (SetAttribute frozen in combat).

    THE STRATEGY (two independent layers):

    * VISUAL layer: the existing BuffReminders module, 100% untouched in
      nature — insecure, animated, free to appear/disappear/slide in combat.
    * CLICK layer (this module): per-buff invisible secure buttons that are
      synced to the visual icons ONLY while out of combat, and hidden during
      combat entirely by Blizzard's own secure state driver.

    THE FIVE RULES that make the old failure modes structurally impossible:

    R1 ISOLATION — the overlay container is parented AND anchored to UIParent
       only, positioned via absolute coordinates computed from the visual
       container's screen rect. It must NEVER be anchored to (or parented
       under) VeevHUDFrame, the BuffReminders container, or any HUD frame —
       per (3) that would protect the whole HUD again. Reading geometry
       (GetLeft/GetWidth/GetEffectiveScale) is always safe; anchoring is not.

    R2 COMBAT-HIDDEN — RegisterStateDriver(container, "visibility",
       "[combat] hide; show"). Blizzard's secure driver hides the entire
       click layer the instant combat starts and reshows it after; that is
       legal in combat because the SECURE system does it, not us. Result: in
       combat there are zero click zones — no stale zones, no clicks eaten,
       no icon/zone mismatch. Our own code never calls Show/Hide on the
       container; the driver owns container visibility.

    R3 DEFERRAL GATE — every mutation of the click layer funnels through
       RequestReconcile(), which no-ops into a dirty flag during combat and
       flushes on PLAYER_REGEN_ENABLED. We never even ATTEMPT a protected
       call in combat, so ADDON_ACTION_BLOCKED is unreachable by
       construction, not by luck. (With R2 active this gate is mostly belt-
       and-braces — keep it anyway; it is the structural guarantee.)

    R4 NO COMBAT ATTRIBUTES — spell attributes are (re)assigned only inside
       the OOC-gated sync. Buttons are keyed per alert, so an attribute never
       needs to change while clickable state is live. Kills the v1.0.202
       "stuck spell" class of bug.

    R5 PURE HIT ZONES — buttons render nothing (no texture/text/highlight).
       All visuals stay in the insecure layer. A zone exists only where a
       visible reminder icon currently is, sized exactly to the icon, so the
       click-through HUD philosophy is preserved: no reminders => no zones.

    CLICK ACTIONS (resolved by BuffReminders:GetClickAction):

    Although zones are static while clickable, per-click decisions ARE
    possible through the one sanctioned channel: MACRO CONDITIONALS, which
    the secure system evaluates at click time. Everything else (bag contents,
    known ranks, which hand is missing an enchant) is resolved by insecure
    code at OOC sync time into a static type="spell" or type="macro" action:

    * Self buffs        -> type="spell", unit="player" (must NOT take a
                           target: self-only spells error when cast @target)
    * Ally/raid buffs   -> "/cast [@target,help,nodead][@player] Name"
                           (Earth Shield on your friendly target, else self)
    * Weapon enchants   -> per-hand alerts already know the slot:
                           poisons "/use <best bag item>" + "/use 16|17",
                           imbues "/cast <imbue>" + "/use 16|17" (both use
                           the pending-item-target flow)
    * Soulstone-style   -> dual mode from bag state at sync time: apply the
                           held item via conditional-target /use, else cast
                           the create spell
    Names inside macrotext come from GetSpellInfo/GetItemInfo at runtime, so
    they are locale-correct (never hardcode English names).

    ACCEPTED LIMITATIONS (documented in the options UI):

    * Clicking works out of combat only. In combat, reminders are visual-only
      and clicks/drags pass through to the game world exactly as before.
      (Separately: many reminders VANISH in combat — that is the visual
      layer's per-spell combatState config, which defaults to "Out of Combat"
      for 5min+ LONG_BUFF/purgeable buffs and restock reminders. It predates
      this module and is user-adjustable per spell in the Spells tab. Do not
      "fix" it here.)
    * Right-click passes through to camera where SetPassThroughButtons exists
      (guarded — verify in-game per client build); otherwise right-clicks on
      a visible reminder icon are consumed while out of combat.
    * Once created, secure frames cannot be deleted. Disabling the option
      hides and detaches everything (hidden frames don't intercept mouse), so
      it is functionally complete without a /reload; the frames just linger
      inert until the next reload.

    A POSSIBLE FUTURE "TIER B" (combat clicking — closest to the reverted
    v1.0.202 behavior): drop R2 so zones persist during combat, freeze the
    visual sort order while in combat so a frozen zone can never sit under a
    DIFFERENT buff's icon, and accept documented quirks (mid-combat reminders
    not clickable until regen; cleared reminders leave an inert invisible
    zone until regen). R1/R3/R4/R5 stay mandatory. Do not ship Tier B without
    the sort-order freeze — that mismatch is the one genuinely dangerous
    quirk (clicking icon A casting spell B).
    ============================================================================
]]

local _, addon = ...

local ClickOverlay = {}
addon:RegisterModule("BuffRemindersClickOverlay", ClickOverlay)

ClickOverlay.buttons = {}          -- alertKey -> secure button (never destroyed; see header)
ClickOverlay.created = false       -- container + driver exist (lazy; only ever true after opt-in)
ClickOverlay.driverRegistered = false
ClickOverlay._dirty = false        -- reconcile requested while in combat; flushed on regen

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function ClickOverlay:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils

    self.Events:RegisterEvent(self, "PLAYER_REGEN_ENABLED", self.OnCombatEnded)
    -- Fired by BuffReminders whenever visible icons, layout, position, or
    -- size change. The overlay never polls; it reacts to the visual layer.
    self.Events:RegisterAddonEvent(self, "BUFF_REMINDERS_LAYOUT_CHANGED", self.OnLayoutChanged)

    self.initialized = true
    self:RequestReconcile()
end

function ClickOverlay:Refresh()
    self:RequestReconcile()
end

function ClickOverlay:OnLayoutChanged()
    self:RequestReconcile()
end

function ClickOverlay:OnCombatEnded()
    if self._dirty then
        self:RequestReconcile()
    end
end

function ClickOverlay:IsFeatureEnabled()
    local db = addon.db.profile
    return db.enabled and db.buffReminders.enabled and db.buffReminders.clickToCast
end

-------------------------------------------------------------------------------
-- R3: the combat deferral gate. THE ONLY entry point to the secure layer.
-- Everything below this function may assume it is running out of combat.
-------------------------------------------------------------------------------

function ClickOverlay:RequestReconcile()
    if not self.initialized then return end
    if InCombatLockdown() then
        self._dirty = true
        return
    end
    self._dirty = false
    self:ReconcileNow()
end

function ClickOverlay:ReconcileNow()
    if not self:IsFeatureEnabled() then
        self:Deactivate()
        return
    end

    self:EnsureCreated()

    -- R2: (re)register the secure visibility driver. Registration writes
    -- secure wiring, so it also lives behind the OOC gate.
    if not self.driverRegistered then
        RegisterStateDriver(self.container, "visibility", "[combat] hide; show")
        self.driverRegistered = true
        self.Utils:LogInfo("ClickOverlay: activated (combat-hide driver registered)")
    end

    self:SyncZones()
end

-- Hide everything and hand container visibility back to us (driver removed).
-- Hidden frames receive no mouse input, so this fully deactivates the feature
-- at runtime; the frames themselves persist until /reload (see header).
function ClickOverlay:Deactivate()
    if not self.created then return end
    self.follower:Hide()
    for _, btn in pairs(self.buttons) do
        btn:Hide()
    end
    if self.driverRegistered then
        UnregisterStateDriver(self.container, "visibility")
        self.driverRegistered = false
        self.Utils:LogInfo("ClickOverlay: deactivated")
    end
    self.container:Hide()
end

-------------------------------------------------------------------------------
-- Frame construction (lazy: users who never opt in get NO secure frames)
-------------------------------------------------------------------------------

function ClickOverlay:EnsureCreated()
    if self.created then return end

    -- R1: parented to UIParent, anchored to UIParent, scale 1 — its local
    -- coordinate space IS UIParent's, so zone math needs no scale conversion
    -- beyond visual-container effective scale -> UIParent effective scale.
    local container = CreateFrame("Frame", "VeevHUDClickOverlay", UIParent)
    container:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
    container:SetSize(1, 1)
    -- Above the reminder icons (MEDIUM/20) so zones win the mouse; below
    -- DIALOG so config windows and popups still sit on top.
    container:SetFrameStrata("MEDIUM")
    container:SetFrameLevel(40)
    self.container = container

    -- Slide follower: while the visual slide animation is running, re-sync
    -- zones every frame so they track the icons mid-flight instead of
    -- teleporting to the settled positions (which would briefly let a click
    -- land on the wrong neighbor). Plain INSECURE frame — it must never join
    -- the secure subtree; it only drives OOC-gated reconciles.
    local follower = CreateFrame("Frame")
    follower:Hide()
    follower:SetScript("OnUpdate", function(f)
        if InCombatLockdown() then f:Hide() return end
        ClickOverlay:RequestReconcile()
    end)
    self.follower = follower

    self.created = true
end

function ClickOverlay:AcquireButton(alertKey)
    local btn = self.buttons[alertKey]
    if btn then return btn end

    btn = CreateFrame("Button", "VeevHUDClickZone" .. tostring(alertKey),
        self.container, "SecureActionButtonTemplate")
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(41)

    -- Match the client's cast-on-down vs cast-on-up behavior. On builds where
    -- the cvar doesn't exist, GetCVarBool returns nil -> classic "up" clicks.
    -- Read once at creation; a cvar change mid-session applies after /reload.
    local castOnDown = GetCVarBool and GetCVarBool("ActionButtonUseKeyDown")
    btn:RegisterForClicks(castOnDown and "LeftButtonDown" or "LeftButtonUp")

    -- R4: action attributes (type/spell/macrotext) are assigned only inside
    -- the OOC-gated sync, from the descriptor BuffReminders:GetClickAction
    -- resolved. unit=player makes "spell" actions explicit self-casts; it is
    -- ignored by "macro" actions, whose conditional targeting is evaluated by
    -- the secure system at click time.
    btn:SetAttribute("unit", "player")

    -- R5 + camera: let right-clicks (camera turn) fall through to the world.
    -- Not guaranteed to exist on every classic-line build; guarded + pcall so
    -- absence degrades to "right-click on a visible reminder is consumed OOC".
    if btn.SetPassThroughButtons then
        pcall(btn.SetPassThroughButtons, btn, "RightButton")
    end

    self.buttons[alertKey] = btn
    return btn
end

-------------------------------------------------------------------------------
-- Zone sync (only ever runs out of combat, via the R3 gate)
-------------------------------------------------------------------------------

-- Mirror the click-eligible visible reminder icons into secure hit zones.
-- Position math reads the VISUAL layer's geometry (safe — read-only) and
-- converts to UIParent space. Icons mid-slide use the animator's LIVE offset
-- (frame._slideCurrentX), and the follower frame re-syncs every frame until
-- the slide settles, so zones track the icons rather than jumping ahead of
-- them. Actions come from the _clickAction descriptor stamped by
-- BuffReminders:GetClickAction (nil = not click-eligible).
function ClickOverlay:SyncZones()
    local wanted = {}  -- alertKey -> {x, y, size, action} in UIParent space

    local br = addon:GetModule("BuffReminders")
    local visual = br and br.containerFrame
    -- Preview icons are config-time fakes with no spell; show no zones while
    -- the user is previewing appearance settings.
    if visual and visual:IsShown() and not br:IsPreviewActive() then
        local left, bottom = visual:GetLeft(), visual:GetBottom()
        if left then
            -- visual-container local units -> UIParent local units
            local toUI = visual:GetEffectiveScale() / UIParent:GetEffectiveScale()
            local centerX = (left + visual:GetWidth() / 2) * toUI
            local centerY = (bottom + visual:GetHeight() / 2) * toUI
            local zoneSize = addon.db.profile.buffReminders.iconSize * toUI

            for _, frame in ipairs(br.visibleIcons) do
                local slideX = frame._slideCurrentX or frame._slideTargetX
                if frame._clickAction and slideX then
                    wanted[frame._brSpellID] = {
                        x = centerX + slideX * toUI,
                        y = centerY,
                        size = zoneSize,
                        action = frame._clickAction,
                    }
                end
            end
        end
    end

    -- Apply: reposition/rewire only what changed (this runs on every visual
    -- update tick while reminders are visible, and per frame during slides —
    -- keep it cheap and idempotent).
    local zoneCount = 0
    for alertKey, zone in pairs(wanted) do
        zoneCount = zoneCount + 1
        local btn = self:AcquireButton(alertKey)
        if btn._zoneX ~= zone.x or btn._zoneY ~= zone.y or btn._zoneSize ~= zone.size then
            btn._zoneX, btn._zoneY, btn._zoneSize = zone.x, zone.y, zone.size
            btn:ClearAllPoints()
            btn:SetPoint("CENTER", self.container, "BOTTOMLEFT", zone.x, zone.y)
            btn:SetSize(zone.size, zone.size)
        end
        -- R4: action attributes change only here (OOC by construction)
        local action = zone.action
        local sig = (action.kind == "spell") and ("s\1" .. action.spell)
            or ("m\1" .. action.macrotext)
        if btn._actionSig ~= sig then
            btn._actionSig = sig
            btn:SetAttribute("type", action.kind == "spell" and "spell" or "macro")
            if action.kind == "spell" then
                btn:SetAttribute("spell", action.spell)
            else
                btn:SetAttribute("macrotext", action.macrotext)
            end
        end
        btn:Show()
    end
    for alertKey, btn in pairs(self.buttons) do
        if not wanted[alertKey] then
            btn:Hide()
        end
    end

    -- Track in-flight slide animations frame-by-frame until they settle
    local animator = br and br.slideAnimator
    if animator and animator.running then
        self.follower:Show()
    else
        self.follower:Hide()
    end

    if addon.db.profile.debugMode then
        self.Utils:LogDebug("ClickOverlay: synced " .. zoneCount .. " zone(s)")
    end
end
