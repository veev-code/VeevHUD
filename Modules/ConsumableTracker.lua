--[[
    VeevHUD - Consumable Tracker Module

    Manages user-configured consumable tracking with cooldown and count display.
    Supports potions (shared 2-min CD) and other consumables (Dark Rune, sappers, etc.).
    Follows TrinketTracker's delegation pattern: CooldownIcons delegates to this
    module for all consumable icon behavior.

    Design:
    - Dynamic N slots: users add/remove consumables via Options UI
    - Each item gets a sentinel ID: CONSUMABLE_SENTINEL_BASE + itemID
    - Bag scanning discovers potions; LibSpellDB provides fallback lists for both
    - Display priority: buff active > item cooldown > ready
    - Count overlay shows current bag quantity
]]

local _, addon = ...

local ConsumableTracker = {}
addon:RegisterModule("ConsumableTracker", ConsumableTracker)

-- Cached API calls
local GetItemInfo = GetItemInfo
local GetTime = GetTime
local C_Container = C_Container
local C_Item = C_Item

-- GCD threshold for filtering cooldown display
local GCD_THRESHOLD  -- initialized from Constants

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function ConsumableTracker:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants
    self.LibSpellDB = addon.LibSpellDB

    GCD_THRESHOLD = self.C.GCD_THRESHOLD

    -- Cache module references for hot-path usage (avoid per-frame GetModule lookups)
    self.renderer = addon:GetModule("IconRenderer")
    self.glowManager = addon:GetModule("GlowManager")

    -- Runtime consumable data keyed by itemID
    self.consumables = {}

    -- Reusable state table for ApplyIconVisuals (avoids per-frame allocation)
    self._visualState = {}

    -- Register events
    self.Events:RegisterEvent(self, "PLAYER_ENTERING_WORLD", self.OnPlayerEnteringWorld)

    -- Register as an icon provider — CooldownIcons dispatches sentinel-icon
    -- injection/setup/update through this interface
    addon:RegisterIconProvider({
        name = "ConsumableTracker",
        order = 40,
        module = self,
        IsSentinel = function(id) return self:IsConsumableSentinel(id) end,
        Setup = function(frame, spellID, rowConfig, rowIndex)
            self:SetupConsumableIcon(frame, spellID, rowConfig, rowIndex)
        end,
        Update = function(frame, db)
            self:UpdateConsumableIconState(frame, db)
            -- Needs periodic refresh while countdown text is showing
            local text = frame.text and frame.text:GetText()
            return text and text ~= ""
        end,
    })

    self.Utils:LogInfo("ConsumableTracker initialized")
end

function ConsumableTracker:Refresh()
    self:LoadAllConsumables()
end

-------------------------------------------------------------------------------
-- Consumable Management
-------------------------------------------------------------------------------

-- Shared empty result for specs with no configured items. Read-only by
-- contract — vivifying per-spec tables on read littered SavedVariables with
-- empty entries for every spec the character ever passed through.
local EMPTY_ITEMS = {}

--- Get the configured items list for the current spec (read-only; may be empty).
function ConsumableTracker:GetConfiguredItems()
    local specKey = addon.Database:GetSpecKey()
    local items = addon.db.profile.consumableTracker.items
    return items[specKey] or EMPTY_ITEMS
end

--- Get (creating if missing) the mutable configured items list for the spec.
-- Only mutation paths (add/remove) may vivify the per-spec table.
function ConsumableTracker:GetOrCreateConfiguredItems()
    local specKey = addon.Database:GetSpecKey()
    local items = addon.db.profile.consumableTracker.items
    if not items[specKey] then
        items[specKey] = {}
    end
    return items[specKey]
end

function ConsumableTracker:LoadAllConsumables()
    wipe(self.consumables)

    local configured = self:GetConfiguredItems()
    for _, entry in ipairs(configured) do
        if entry.itemID then
            self:LoadConsumable(entry.itemID)
        end
    end
end

function ConsumableTracker:LoadConsumable(itemID)
    local sentinelID = self.C.CONSUMABLE_SENTINEL_BASE + itemID

    local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(itemID)

    -- Detect if the item applies a buff (for duration tracking).
    -- Only use LibSpellDB data — GetItemSpell returns the trigger spell (hidden passive),
    -- not the visible buff, so it cannot be used for UnitBuff tracking.
    local buffSpellID
    local itemInfo = self.LibSpellDB:GetPotionInfo(itemID) or self.LibSpellDB:GetConsumableInfo(itemID)
    if itemInfo and itemInfo.buffSpellID then
        buffSpellID = itemInfo.buffSpellID
    end

    self.consumables[itemID] = {
        itemID = itemID,
        sentinelID = sentinelID,
        name = itemName or ("Item " .. itemID),
        icon = itemIcon,
        buffSpellID = buffSpellID,
    }

    -- Retry if item data wasn't cached yet
    if not itemName and C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
        C_Timer.After(1, function()
            if self.consumables[itemID] then
                local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemID)
                if name then
                    self.consumables[itemID].name = name
                    self.consumables[itemID].icon = icon
                    self:NotifyCooldownIcons()
                end
            end
        end)
    end

    return self.consumables[itemID]
end

function ConsumableTracker:AddConsumable(itemID)
    if not itemID then return end

    -- Check for duplicates (mutable accessor: this is the one path allowed
    -- to vivify the per-spec table — never insert into the shared read-only
    -- empty result from GetConfiguredItems)
    local configured = self:GetOrCreateConfiguredItems()
    for _, entry in ipairs(configured) do
        if entry.itemID == itemID then return end
    end

    table.insert(configured, { itemID = itemID })
    self:LoadConsumable(itemID)
    self:NotifyCooldownIcons()
end

function ConsumableTracker:RemoveConsumable(itemID)
    if not itemID then return end

    -- Remove from profile
    local configured = self:GetConfiguredItems()
    for i = #configured, 1, -1 do
        if configured[i].itemID == itemID then
            table.remove(configured, i)
        end
    end

    -- Remove runtime data
    self.consumables[itemID] = nil

    -- Clean up spellConfig entries for this sentinel.
    -- spellConfig itself can be nil: clearing the last override cascade-nils
    -- the whole table (Database:SetSpellConfigOverride), and AceDB only
    -- re-copies defaults at profile load.
    local sentinelID = self.C.CONSUMABLE_SENTINEL_BASE + itemID
    local specKey = addon.Database:GetSpecKey()
    if specKey and addon.db.profile.spellConfig then
        local spellCfg = addon.db.profile.spellConfig[specKey]
        if spellCfg then
            spellCfg[sentinelID] = nil
        end
    end

    self:NotifyCooldownIcons()
end

--- Build a set of currently configured item IDs for exclusion from dropdowns.
function ConsumableTracker:GetConfiguredItemSet()
    local configured = {}
    for _, entry in ipairs(self:GetConfiguredItems()) do
        configured[entry.itemID] = true
    end
    return configured
end

-------------------------------------------------------------------------------
-- Bag Scanning (for dropdown population)
-------------------------------------------------------------------------------

--- Scan bags for potions (itemSubClassID 1).
-- @return array of { itemID, name, icon, count } sorted by count desc then name
function ConsumableTracker:ScanBagsForPotions()
    local found = {}  -- itemID -> { itemID, name, icon, count }

    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
            if containerInfo and containerInfo.itemID then
                local itemID = containerInfo.itemID
                if not found[itemID] then
                    local itemName, _, _, _, _, _, _, _, _, itemIcon, _, itemClassID, itemSubClassID = GetItemInfo(itemID)
                    -- itemClassID 0 = Consumable, itemSubClassID 1 = Potion
                    if itemClassID == 0 and itemSubClassID == 1 then
                        local count = C_Item.GetItemCount(itemID)
                        found[itemID] = {
                            itemID = itemID,
                            name = itemName or "",
                            icon = itemIcon,
                            count = count,
                        }
                    end
                end
            end
        end
    end

    -- Convert to sorted array
    local result = {}
    for _, data in pairs(found) do
        table.insert(result, data)
    end

    table.sort(result, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)

    return result
end

--- Get all available potion choices (bag scan + LibSpellDB fallback), excluding already-configured.
-- @return array of { itemID, name, icon, count }
function ConsumableTracker:GetAllPotionChoices()
    local bagPotions = self:ScanBagsForPotions()

    -- Index bag potions by itemID for dedup
    local seen = {}
    for _, data in ipairs(bagPotions) do
        seen[data.itemID] = true
    end

    -- Add LibSpellDB potions not in bags
    local libPotions = self.LibSpellDB:GetAllPotions()
    local fallbackEntries = {}
    for itemID, _ in pairs(libPotions) do
        if not seen[itemID] then
            local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(itemID)
            if itemName then
                table.insert(fallbackEntries, {
                    itemID = itemID,
                    name = itemName,
                    icon = itemIcon,
                    count = 0,
                })
                seen[itemID] = true
            else
                C_Item.RequestLoadItemDataByID(itemID)
            end
        end
    end

    -- Sort fallback alphabetically
    table.sort(fallbackEntries, function(a, b) return a.name < b.name end)

    -- Merge: bag potions first (by count), then fallback (alphabetical)
    local result = {}
    local configured = self:GetConfiguredItemSet()

    for _, data in ipairs(bagPotions) do
        if not configured[data.itemID] then
            table.insert(result, data)
        end
    end
    for _, data in ipairs(fallbackEntries) do
        if not configured[data.itemID] then
            table.insert(result, data)
        end
    end

    return result
end

--- Get all available consumable choices (LibSpellDB only), excluding already-configured.
-- @return array of { itemID, name, icon, count }
function ConsumableTracker:GetAllOtherConsumableChoices()
    local libConsumables = self.LibSpellDB:GetAllConsumables()
    local configured = self:GetConfiguredItemSet()

    local result = {}
    for itemID, _ in pairs(libConsumables) do
        if not configured[itemID] then
            local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(itemID)
            if itemName then
                local count = C_Item.GetItemCount(itemID)
                table.insert(result, {
                    itemID = itemID,
                    name = itemName,
                    icon = itemIcon,
                    count = count,
                })
            else
                C_Item.RequestLoadItemDataByID(itemID)
            end
        end
    end

    table.sort(result, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)

    return result
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

function ConsumableTracker:OnPlayerEnteringWorld()
    C_Timer.After(1, function()
        self:LoadAllConsumables()
        self:NotifyCooldownIcons()
        self:PreloadDropdownItems()
    end)
end

--- Request client-side load of all potion/consumable item data so the
-- "Add Potion" / "Add Consumable" dropdowns are fully populated the first
-- time the user opens them. GetItemInfo returns nil for uncached items
-- (and the entry is skipped) until WoW finishes loading the item.
function ConsumableTracker:PreloadDropdownItems()
    if not C_Item or not C_Item.RequestLoadItemDataByID then return end
    local potions = self.LibSpellDB:GetAllPotions()
    for itemID in pairs(potions) do
        C_Item.RequestLoadItemDataByID(itemID)
    end
    local consumables = self.LibSpellDB:GetAllConsumables()
    for itemID in pairs(consumables) do
        C_Item.RequestLoadItemDataByID(itemID)
    end
end

--- Notify CooldownIcons to rebuild rows.
function ConsumableTracker:NotifyCooldownIcons()
    local cooldownIcons = addon:GetModule("CooldownIcons")
    if cooldownIcons and cooldownIcons.RebuildAllRows then
        cooldownIcons:RebuildAllRows()
    end
end

-------------------------------------------------------------------------------
-- Public API (called by CooldownIcons)
-------------------------------------------------------------------------------

--- Check if an ID is a consumable sentinel.
function ConsumableTracker:IsConsumableSentinel(id)
    local base = self.C.CONSUMABLE_SENTINEL_BASE
    return id >= base and id < base + 1000000
end

--- Get consumable runtime data by item ID.
function ConsumableTracker:GetConsumableData(itemID)
    return self.consumables[itemID]
end

function ConsumableTracker:GetConsumableForSentinel(sentinelID)
    local itemID = sentinelID - self.C.CONSUMABLE_SENTINEL_BASE
    return self.consumables[itemID]
end

--- Inject consumable entries into CooldownIcons row data.
-- Called during RebuildAllRows, after spell assignment.
function ConsumableTracker:InjectRowEntries(iconsByRow, rowConfigs, spellCfg, spellAssignments)
    local configured = self:GetConfiguredItems()

    for _, entry in ipairs(configured) do
        local itemID = entry.itemID
        local consumableData = self.consumables[itemID]
        -- Lazy-load: spec switches mid-session reach here with items the
        -- runtime never loaded (LoadAllConsumables only runs at PEW/Refresh
        -- for the spec active at the time). Load on first sight so the new
        -- spec's consumables appear without a loading screen.
        if not consumableData and itemID then
            self:LoadConsumable(itemID)
            consumableData = self.consumables[itemID]
        end
        if consumableData then
            local sentinelID = consumableData.sentinelID
            local cfg = spellCfg[sentinelID] or {}

            if cfg.enabled == false then
                -- Disabled but still record assignment for SpellsOptions
                spellAssignments[sentinelID] = cfg.rowIndex or 2
            else
                local rowIndex = cfg.rowIndex or 2  -- Default: Secondary row

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
                                tags = {"POTION"},
                                icon = consumableData.icon,
                                name = consumableData.name,
                                cooldown = 0,
                                priority = 2000 + itemID,  -- After trinkets (1000+), stable per-item
                            },
                            customOrder = cfg.order,
                            isConsumable = true,
                            consumableItemID = itemID,
                        })
                        spellAssignments[sentinelID] = rowIndex
                    end
                end
            end
        end
    end
end

--- Get the default row for a consumable sentinel (for SpellsOptions).
function ConsumableTracker:GetDefaultRow(sentinelID)
    return 2  -- Secondary row
end

-------------------------------------------------------------------------------
-- Icon Setup (called by CooldownIcons:SetupIcon delegation)
-------------------------------------------------------------------------------

function ConsumableTracker:SetupConsumableIcon(frame, sentinelID, rowConfig, rowIndex)
    local consumableData = self:GetConsumableForSentinel(sentinelID)

    frame.isConsumable = true
    frame.consumableItemID = consumableData and consumableData.itemID or nil
    frame.spellID = sentinelID
    frame.actualSpellID = sentinelID
    frame.rowIndex = rowIndex or 2
    frame.spellData = {
        tags = {"POTION"},
        name = consumableData and consumableData.name or "Consumable",
    }

    -- Set icon texture
    local texture = consumableData and consumableData.icon
    frame.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")

    -- Configure cooldown text (OmniCC/ElvUI) based on row
    if self.renderer and frame.cooldown then
        local renderer = self.renderer
        renderer:ConfigureCooldownText(frame.cooldown, frame.rowIndex)

        local db = addon.db.profile.icons
        local blingEnabled = addon.Database:IsRowSettingEnabled(db.cooldownBlingRows, frame.rowIndex)
        frame.cooldown:SetDrawBling(blingEnabled)
    end

    -- Run first visual update immediately to avoid stale alpha/desat/spiral
    -- from the previous frame assignment persisting until the next 0.05s tick
    self:UpdateConsumableIconState(frame, addon.db.profile.icons)
end

-------------------------------------------------------------------------------
-- Icon State Update (called every 0.05s by CooldownIcons delegation)
-------------------------------------------------------------------------------

function ConsumableTracker:UpdateConsumableIconState(frame, db)
    local itemID = frame.consumableItemID
    if not itemID then return end

    local consumableData = self.consumables[itemID]
    if not consumableData then return end

    local now = GetTime()

    -- Initialize state variables
    local auraActive = false
    local auraRemaining, auraDuration = 0, 0
    local stackCount = 0
    local cdRemaining, cdDuration, cdStartTime = 0, 0, 0

    -------------------------------------------------------------------
    -- PRIORITY 1: Buff active (if consumable applies a trackable buff)
    -------------------------------------------------------------------
    if consumableData.buffSpellID then
        -- Match by spell ID only — the buff name (e.g. "Haste") is often generic
        -- and collides with unrelated effects from trinkets, enchants, and procs.
        -- LibSpellDB authoritatively maps each consumable to its specific buff ID.
        local aura = self.Utils:GetCachedBuff("player", consumableData.buffSpellID, nil)
        if aura and aura.expirationTime and aura.expirationTime > 0 then
            auraActive = true
            auraRemaining = aura.expirationTime - now
            auraDuration = aura.duration or 0
            stackCount = aura.count or 0
            if auraRemaining <= 0 then
                auraActive = false
                auraRemaining, auraDuration, stackCount = 0, 0, 0
            end
        end
    end

    -------------------------------------------------------------------
    -- PRIORITY 2: Item cooldown
    -------------------------------------------------------------------
    local start, dur = C_Container.GetItemCooldown(itemID)
    if start and start > 0 and dur > GCD_THRESHOLD then
        cdRemaining = (start + dur) - now
        cdDuration = dur
        cdStartTime = start
        if cdRemaining <= 0 then
            cdRemaining, cdDuration, cdStartTime = 0, 0, 0
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

    -- Bag count — read live for instant feedback (C_Item.GetItemCount is a fast C-side call)
    local count = C_Item.GetItemCount(itemID)
    local outOfStock = (count == 0)
    if stackCount == 0 and db.showConsumableCount and count > 0 then
        stackCount = count
    end

    -- Actionable time for dynamic sorting
    frame.actionableTime = math.max(
        isOnActualCooldown and cdRemaining or 0,
        auraActive and auraRemaining or 0
    )

    if auraActive and auraRemaining > 0 then
        -- Buff active: show aura state
        showAuraActive = true
        auraDisplayRemaining = auraRemaining
        auraDisplayDuration = auraDuration
        alpha = db.readyAlpha
        showGlow = true
        showSpinner = true
        showText = true
    elseif isOnActualCooldown then
        -- Cooldown active: dim + desaturate
        local dimOnCooldown = addon.Database:IsRowSettingEnabled(db.dimOnCooldown, rowIndex)
        if frame.readyGlowActive then
            alpha = db.readyAlpha
        elseif dimOnCooldown then
            alpha = db.cooldownAlpha
            desaturate = true
        end
        showSpinner = true
        showText = cdDuration >= 2
    elseif outOfStock then
        -- Out of stock: dim + desaturate
        alpha = db.cooldownAlpha
        desaturate = true
    end

    -------------------------------------------------------------------
    -- Apply visual state
    -------------------------------------------------------------------
    local renderer = self.renderer
    local glowManager = self.glowManager

    if renderer then
        local vs = self._visualState
        vs.showAuraActive = showAuraActive
        vs.auraRemaining = auraDisplayRemaining
        vs.auraDuration = auraDisplayDuration
        vs.stackCount = stackCount
        vs.cdRemaining = cdRemaining
        vs.cdDuration = cdDuration
        vs.cdStartTime = cdStartTime
        vs.alpha = alpha
        vs.desaturate = desaturate
        vs.showSpinner = showSpinner
        vs.showText = showText
        renderer:ApplyIconVisuals(frame, vs, db)
    end

    -- Resource display not applicable to consumables
    if frame.resourceBar then frame.resourceBar:Hide() end
    if frame.resourceFill then frame.resourceFill:Hide() end

    -- Glow
    if glowManager then
        glowManager:UpdateIconGlow(frame, showGlow, showAuraActive, false)

        glowManager:UpdateCooldownPulse(frame, frame.spellID, cdRemaining, cdDuration)
        if not showAuraActive then
            glowManager:UpdateReadyGlow(frame, frame.spellID, cdRemaining, cdDuration, true, false, db, false, true, false, 0, false)
        else
            glowManager:SuppressReadyGlow(frame, cdRemaining, cdDuration, true)
        end
    end

    -- Range/queued indicators not applicable to consumables
    if frame.rangeOverlay and frame.rangeOverlay:IsShown() then
        frame.rangeOverlay:Hide()
    end
    if frame.queuedHighlight and frame.queuedHighlight:IsShown() then
        frame.queuedHighlight:Hide()
    end
end
