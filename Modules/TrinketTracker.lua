--[[
    VeevHUD - Trinket Tracker Module

    Manages trinket detection, classification, aura/cooldown tracking, and icon state.
    Maximally isolated: CooldownIcons delegates to this module for all trinket behavior.

    Design:
    - Two equipment slots (13/14) tracked as sentinel spell IDs
    - On-use trinkets auto-detected via GetItemSpell()
    - Proc trinkets use LibSpellDB trinket database
    - ICD tracked via CLEU SPELL_AURA_APPLIED timestamps
    - Display priority: on-use buff > proc buff > on-use CD > ICD > ready
]]

local ADDON_NAME, addon = ...

local TrinketTracker = {}
addon:RegisterModule("TrinketTracker", TrinketTracker)

-- Equipment slot IDs
local TRINKET_SLOT_1 = 13
local TRINKET_SLOT_2 = 14

-- Cached API calls
local GetInventoryItemID = GetInventoryItemID
local GetInventoryItemTexture = GetInventoryItemTexture
local GetInventoryItemCooldown = GetInventoryItemCooldown
local GetItemSpell = GetItemSpell
local GetItemInfo = GetItemInfo
local GetSpellInfo = GetSpellInfo
local UnitBuff = UnitBuff
local UnitGUID = UnitGUID
local GetTime = GetTime

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function TrinketTracker:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants
    self.LibSpellDB = addon.LibSpellDB

    -- Tracked trinket data per slot (nil if empty/untrackable)
    self.slots = {}

    -- Register events
    self.Events:RegisterEvent(self, "PLAYER_EQUIPMENT_CHANGED", self.OnEquipmentChanged)
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)

    -- Register CLEU for ICD tracking (proc buff applied to player)
    self.Events:RegisterCLEU(self, "SPELL_AURA_APPLIED", self.OnAuraApplied)

    self.Utils:LogInfo("TrinketTracker initialized")
end

function TrinketTracker:Enable()
    -- Initial scan of both trinket slots
    self:ScanSlot(TRINKET_SLOT_1)
    self:ScanSlot(TRINKET_SLOT_2)
end

function TrinketTracker:Refresh()
    -- Re-scan on profile/spec change
    self:ScanSlot(TRINKET_SLOT_1)
    self:ScanSlot(TRINKET_SLOT_2)
end

-------------------------------------------------------------------------------
-- Equipment Detection & Classification
-------------------------------------------------------------------------------

--- Scan a trinket slot and classify the equipped trinket.
function TrinketTracker:ScanSlot(slotID)
    local itemID = GetInventoryItemID("player", slotID)
    if not itemID then
        self.slots[slotID] = nil
        return
    end

    local sentinelID = (slotID == TRINKET_SLOT_1) and self.C.TRINKET_SLOT_13 or self.C.TRINKET_SLOT_14
    local icon = GetInventoryItemTexture("player", slotID)
    local itemName = GetItemInfo(itemID)

    -- Detect on-use via GetItemSpell
    local onUseSpellName, onUseSpellID = GetItemSpell(itemID)
    local hasOnUse = (onUseSpellName ~= nil)

    -- Detect proc via LibSpellDB trinket database
    local trinketData = self.LibSpellDB and self.LibSpellDB:GetTrinketInfo(itemID)
    local hasProc = (trinketData ~= nil and trinketData.procBuffID ~= nil)

    -- If trinket has neither on-use nor known proc, it's a stat-stick — don't track
    if not hasOnUse and not hasProc then
        self.slots[slotID] = nil
        return
    end

    -- Resolve proc buff name for UnitBuff scanning
    local procBuffName
    if hasProc then
        procBuffName = GetSpellInfo(trinketData.procBuffID)
    end

    self.slots[slotID] = {
        itemID = itemID,
        sentinelID = sentinelID,
        name = itemName or ("Trinket " .. (slotID == TRINKET_SLOT_1 and "1" or "2")),
        icon = icon,
        -- Classification
        hasOnUse = hasOnUse,
        hasProc = hasProc,
        -- On-use fields
        onUseSpellName = onUseSpellName,
        onUseSpellID = onUseSpellID,
        -- Proc fields
        procBuffID = hasProc and trinketData.procBuffID or nil,
        procBuffName = procBuffName,
        icd = hasProc and trinketData.icd or nil,
        onUseBuffID = trinketData and trinketData.onUseBuffID or nil,
        onTarget = hasProc and trinketData.onTarget or false,
        -- Runtime state
        lastProcTime = 0,
    }

    self.Utils:LogInfo("TrinketTracker: Slot", slotID, "=",
        self.slots[slotID].name,
        hasOnUse and "(on-use)" or "",
        hasProc and "(proc)" or "")
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

function TrinketTracker:OnPlayerEnteringWorld()
    -- Delay to ensure items are loaded
    if C_Timer and C_Timer.After then
        C_Timer.After(1, function()
            self:ScanSlot(TRINKET_SLOT_1)
            self:ScanSlot(TRINKET_SLOT_2)
            self:NotifyCooldownIcons()
        end)
    else
        self:ScanSlot(TRINKET_SLOT_1)
        self:ScanSlot(TRINKET_SLOT_2)
        self:NotifyCooldownIcons()
    end
end

function TrinketTracker:OnEquipmentChanged(event, slotID, hasItem)
    if slotID ~= TRINKET_SLOT_1 and slotID ~= TRINKET_SLOT_2 then return end

    -- Delay slightly to let item data load
    C_Timer.After(0.1, function()
        self:ScanSlot(slotID)
        self:NotifyCooldownIcons()
    end)
end

function TrinketTracker:OnAuraApplied(subEvent, cleuData)
    -- Only care about buffs on the player
    if cleuData.destGUID ~= UnitGUID("player") then return end

    local spellID = cleuData.spellID
    for _, slotData in pairs(self.slots) do
        if slotData and slotData.procBuffID and slotData.procBuffID == spellID then
            slotData.lastProcTime = GetTime()

            -- Play pop animation on proc trigger
            local cooldownIcons = addon:GetModule("CooldownIcons")
            if cooldownIcons then
                local frame = cooldownIcons:FindIconFrameBySentinel(slotData.sentinelID)
                if frame then
                    cooldownIcons:PlayCastFeedback(frame)
                end
            end
            return
        end
    end
end

--- Notify CooldownIcons to rebuild rows (trinket changed)
function TrinketTracker:NotifyCooldownIcons()
    local cooldownIcons = addon:GetModule("CooldownIcons")
    if cooldownIcons and cooldownIcons.RebuildAllRows then
        cooldownIcons:RebuildAllRows()
    end
end

-------------------------------------------------------------------------------
-- Public API (called by CooldownIcons)
-------------------------------------------------------------------------------

--- Check if an ID is a trinket sentinel
function TrinketTracker:IsTrinketSentinel(id)
    return id == self.C.TRINKET_SLOT_13 or id == self.C.TRINKET_SLOT_14
end

--- Get the equipment slot for a sentinel ID
function TrinketTracker:GetSlotForSentinel(sentinelID)
    if sentinelID == self.C.TRINKET_SLOT_13 then return TRINKET_SLOT_1 end
    if sentinelID == self.C.TRINKET_SLOT_14 then return TRINKET_SLOT_2 end
    return nil
end

--- Inject trinket entries into CooldownIcons row data.
-- Called during RebuildAllRows, after spell assignment.
function TrinketTracker:InjectRowEntries(iconsByRow, rowConfigs, spellCfg, spellAssignments)
    for _, slotID in ipairs({TRINKET_SLOT_1, TRINKET_SLOT_2}) do
        local slotData = self.slots[slotID]
        if slotData then
            local sentinelID = slotData.sentinelID
            local cfg = spellCfg[sentinelID] or {}

            -- Skip if explicitly disabled
            if cfg.enabled == false then
                -- still mark assignment so SpellsOptions knows its home
                spellAssignments[sentinelID] = cfg.rowIndex or 2
            else
                -- Determine row: user override, or first row with TRINKET tag, or Secondary (2)
                local rowIndex = cfg.rowIndex
                if not rowIndex then
                    for ri, rowConfig in ipairs(rowConfigs) do
                        for _, tag in ipairs(rowConfig.tags) do
                            if tag == "TRINKET" then
                                rowIndex = ri
                                break
                            end
                        end
                        if rowIndex then break end
                    end
                end
                rowIndex = rowIndex or 2  -- Fallback: Secondary row

                local rowConfig = rowConfigs[rowIndex]
                if rowConfig and rowConfig.enabled then
                    if not iconsByRow[rowIndex] then
                        iconsByRow[rowIndex] = {}
                    end

                    if #iconsByRow[rowIndex] < rowConfig.maxIcons then
                        table.insert(iconsByRow[rowIndex], {
                            spellID = sentinelID,
                            actualSpellID = sentinelID,
                            spellData = {
                                tags = {"TRINKET"},
                                icon = slotData.icon,
                                name = slotData.name,
                                cooldown = 0,
                                priority = 1000 + slotID,  -- After regular spells (default 999), slot 13 before 14
                            },
                            customOrder = cfg.order,
                            isTrinket = true,
                            trinketSlotID = slotID,
                        })
                        spellAssignments[sentinelID] = rowIndex
                    end
                end
            end
        end
    end
end

--- Get the default row for a trinket sentinel (for SpellsOptions)
function TrinketTracker:GetDefaultRow(sentinelID)
    return 2  -- Secondary row
end

--- Find the icon frame for an on-use trinket spell ID.
-- UNIT_SPELLCAST_SUCCEEDED fires with the on-use spell ID (not sentinel),
-- so CooldownIcons:FindIconFrameBySpellID won't match. This provides the fallback.
function TrinketTracker:FindFrameByOnUseSpellID(spellID)
    local cooldownIcons = addon:GetModule("CooldownIcons")
    if not cooldownIcons or not cooldownIcons.rows then return nil end

    for _, rowFrame in ipairs(cooldownIcons.rows) do
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

-------------------------------------------------------------------------------
-- Icon Setup (called by CooldownIcons:SetupIcon delegation)
-------------------------------------------------------------------------------

function TrinketTracker:SetupTrinketIcon(frame, sentinelID, rowConfig, rowIndex)
    local slotID = self:GetSlotForSentinel(sentinelID)
    local slotData = slotID and self.slots[slotID]

    frame.isTrinket = true
    frame.trinketSlotID = slotID
    frame.spellID = sentinelID
    frame.actualSpellID = sentinelID
    frame.rowIndex = rowIndex or 2
    frame.spellData = {
        tags = {"TRINKET"},
        name = slotData and slotData.name or "Trinket",
    }

    -- Set icon texture
    local texture
    if slotData then
        texture = slotData.icon or GetInventoryItemTexture("player", slotID)
    end
    frame.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")

    -- Store on-use spell ID for cast feedback lookup
    -- UNIT_SPELLCAST_SUCCEEDED fires with the on-use spell ID, not the sentinel
    frame.onUseSpellID = slotData and slotData.onUseSpellID or nil

    -- Clear spell-specific metadata that doesn't apply to trinkets
    frame.isReactive = false
    frame.isTotem = false
    frame.reactiveWindow = nil
    frame.reactiveWindowEvent = nil
    frame.dodgeReactive = nil

    -- Configure cooldown text (OmniCC/ElvUI) based on row
    local cooldownIcons = addon:GetModule("CooldownIcons")
    if cooldownIcons and frame.cooldown then
        cooldownIcons:ConfigureCooldownText(frame.cooldown, frame.rowIndex)

        local db = addon.db.profile.icons
        local blingEnabled = addon.Database:IsRowSettingEnabled(db.cooldownBlingRows, frame.rowIndex)
        frame.cooldown:SetDrawBling(blingEnabled)
    end
end

-------------------------------------------------------------------------------
-- Icon State Update (called every 0.05s by CooldownIcons delegation)
-------------------------------------------------------------------------------

function TrinketTracker:UpdateTrinketIconState(frame, db)
    local slotID = frame.trinketSlotID
    if not slotID then return end

    local slotData = self.slots[slotID]
    if not slotData then return end

    local now = GetTime()
    local C = self.C
    local GCD_THRESHOLD = C.GCD_THRESHOLD

    -- Refresh icon if trinket was swapped (texture might have changed)
    local currentItemID = GetInventoryItemID("player", slotID)
    if currentItemID and slotData.itemID and currentItemID ~= slotData.itemID then
        -- Trinket changed but ScanSlot hasn't run yet; skip this frame
        return
    end

    -- Initialize state variables
    local auraActive = false
    local auraRemaining, auraDuration = 0, 0
    local auraStacks = 0
    local cdRemaining, cdDuration, cdStartTime = 0, 0, 0

    -------------------------------------------------------------------
    -- PRIORITY 1: On-use buff active
    -------------------------------------------------------------------
    if slotData.hasOnUse then
        -- Try the override buff ID first, then scan by spell name
        local buffName = slotData.onUseSpellName
        local buffID = slotData.onUseBuffID
        local aura
        if buffID then
            aura = self.Utils:GetCachedBuff("player", buffID, buffName)
        elseif buffName then
            aura = self.Utils:GetCachedBuff("player", nil, buffName)
        end
        if aura and aura.expirationTime and aura.expirationTime > 0 then
            auraActive = true
            auraRemaining = aura.expirationTime - now
            auraDuration = aura.duration or 0
            auraStacks = aura.count or 0
            if auraRemaining <= 0 then
                auraActive = false
                auraRemaining, auraDuration, auraStacks = 0, 0, 0
            end
        end
    end

    -------------------------------------------------------------------
    -- PRIORITY 2: Proc buff active (only if on-use buff not showing)
    -------------------------------------------------------------------
    if not auraActive and slotData.hasProc and slotData.procBuffID then
        -- Target-applied procs (e.g., Fel Reaver's Piston HoT) use the same
        -- friendly-unit resolution as AuraTracker's FindBuffOnAlly (Inspiration etc.)
        local unit = slotData.onTarget and self.Utils:GetFriendlyBuffUnit() or "player"
        local aura = self.Utils:GetCachedBuff(unit, slotData.procBuffID, slotData.procBuffName)
        if aura and aura.expirationTime and aura.expirationTime > 0 then
            auraActive = true
            auraRemaining = aura.expirationTime - now
            auraDuration = aura.duration or 0
            auraStacks = aura.count or 0
            if auraRemaining <= 0 then
                auraActive = false
                auraRemaining, auraDuration, auraStacks = 0, 0, 0
            end
        end
    end

    -------------------------------------------------------------------
    -- PRIORITY 3: On-use cooldown
    -------------------------------------------------------------------
    if slotData.hasOnUse then
        local start, dur, enable = GetInventoryItemCooldown("player", slotID)
        if start and start > 0 and dur > GCD_THRESHOLD then
            cdRemaining = (start + dur) - now
            cdDuration = dur
            cdStartTime = start
            if cdRemaining <= 0 then
                cdRemaining, cdDuration, cdStartTime = 0, 0, 0
            end
        end
    end

    -------------------------------------------------------------------
    -- PRIORITY 4: ICD (synthetic cooldown after proc)
    -------------------------------------------------------------------
    if not auraActive and slotData.hasProc and slotData.icd and slotData.icd > 0
        and slotData.lastProcTime and slotData.lastProcTime > 0 then
        local icdRemaining = slotData.icd - (now - slotData.lastProcTime)
        -- Only show ICD if no on-use cooldown is active (on-use CD takes priority)
        if icdRemaining > GCD_THRESHOLD and cdRemaining <= 0 then
            cdRemaining = icdRemaining
            cdDuration = slotData.icd
            cdStartTime = slotData.lastProcTime
        end
    end

    -------------------------------------------------------------------
    -- Compute visual state
    -------------------------------------------------------------------
    local rowIndex = frame.rowIndex or 2
    local isOnActualCooldown = self.Utils:IsOnRealCooldown(cdRemaining, cdDuration)

    local alpha = db.readyAlpha
    local desaturate = false
    local showSpinner = false
    local showText = false
    local showGlow = false
    local showAuraActive = false
    local auraDisplayRemaining = 0
    local auraDisplayDuration = 0

    -- Actionable time for dynamic sorting
    frame.actionableTime = math.max(
        isOnActualCooldown and cdRemaining or 0,
        auraActive and auraRemaining or 0
    )

    if auraActive and auraRemaining > 0 then
        -- Buff/proc active: show aura state
        showAuraActive = true
        auraDisplayRemaining = auraRemaining
        auraDisplayDuration = auraDuration
        alpha = db.readyAlpha
        showGlow = true
        showSpinner = true
        showText = true
    elseif isOnActualCooldown then
        -- Cooldown active: dim + desaturate (lifts when ready glow is active)
        local dimOnCooldown = addon.Database:IsRowSettingEnabled(db.dimOnCooldown, rowIndex)
        if frame.readyGlowActive then
            alpha = db.readyAlpha
        elseif dimOnCooldown then
            alpha = db.cooldownAlpha
            desaturate = true
        end
        showSpinner = true
        showText = cdDuration >= 2
    end
    -- else: ready state (defaults are correct)

    -------------------------------------------------------------------
    -- Apply shared visual state (spiral, text, alpha, desat, stacks)
    -------------------------------------------------------------------
    local cooldownIcons = addon:GetModule("CooldownIcons")
    if cooldownIcons then
        cooldownIcons:ApplyIconVisuals(frame, {
            showAuraActive = showAuraActive,
            auraRemaining = auraDisplayRemaining,
            auraDuration = auraDisplayDuration,
            auraStacks = auraStacks,
            cdRemaining = cdRemaining,
            cdDuration = cdDuration,
            cdStartTime = cdStartTime,
            alpha = alpha,
            desaturate = desaturate,
            showSpinner = showSpinner,
            showText = showText,
        }, db)
    end

    -- Resource display (trinkets don't have resource costs)
    if frame.resourceBar then frame.resourceBar:Hide() end
    if frame.resourceFill then frame.resourceFill:Hide() end

    -- Glow (delegate to CooldownIcons for consistent glow rendering)
    if cooldownIcons then
        cooldownIcons:UpdateIconGlow(frame, showGlow, showAuraActive, false)

        -- Ready glow for on-use trinkets only (not ICD)
        if slotData.hasOnUse and not showAuraActive then
            local onUseRemaining, onUseDuration = 0, 0
            local start, dur = GetInventoryItemCooldown("player", slotID)
            if start and start > 0 and dur > C.GCD_THRESHOLD then
                onUseRemaining = (start + dur) - now
                onUseDuration = dur
                if onUseRemaining <= 0 then onUseRemaining, onUseDuration = 0, 0 end
            end
            cooldownIcons:UpdateReadyGlow(frame, frame.spellID, onUseRemaining, onUseDuration, true, false, db, false, true, false, 0, false)
        else
            if frame.readyGlowActive then
                cooldownIcons:HideReadyGlow(frame)
                frame.readyGlowActive = false
            end
        end
    end

    -- Range indicator not applicable to trinkets
    if frame.rangeOverlay and frame.rangeOverlay:IsShown() then
        frame.rangeOverlay:Hide()
    end

    -- Queued highlight not applicable to trinkets
    if frame.queuedHighlight and frame.queuedHighlight:IsShown() then
        frame.queuedHighlight:Hide()
    end
end
