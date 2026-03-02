--[[
    VeevHUD - Spell Assignment Module
    Pure spell-to-row assignment logic. Takes tracked spells + config,
    returns spell-to-row assignments. No UI, no events, no frame access.

    Extracted from CooldownIcons:RebuildAllRows to enforce Layer 2 (Logic)
    separation from Layer 4 (Orchestration).
]]

local ADDON_NAME, addon = ...

local SpellAssignment = {}
addon:RegisterModule("SpellAssignment", SpellAssignment)

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function SpellAssignment:Initialize()
    self.Utils = addon.Utils
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

-- Assign all tracked spells to rows based on tags, overrides, and filtering rules.
-- Returns: iconsByRow (table), spellAssignments (table)
--
-- @param trackedSpells  Dict of {spellID → {spellData, actualSpellID}} from SpellTracker
-- @param rowConfigs     Array of row configs from addon.db.profile.rows
-- @param spellCfg       Dict of {spellID → {rowIndex, order, druidForm}} from spell config
-- @param context        Runtime state: { isFeralDruid, activeFeralForm, totemBarActive }
function SpellAssignment:AssignAllSpells(trackedSpells, rowConfigs, spellCfg, context)
    local LibSpellDB = addon.LibSpellDB
    if not LibSpellDB then
        return {}, {}
    end

    local iconsByRow = {}
    local spellAssignments = {}

    -- Phase 1: Collapse exclusive BuffGroup members into one representative
    local skipExclusiveSpells = self:_CollapseExclusiveGroups(trackedSpells, rowConfigs, spellCfg)

    -- Phase 2: Assign each tracked spell to a row
    for spellID, trackedData in pairs(trackedSpells) do
        local spellData = trackedData.spellData
        local cfg = spellCfg[spellID] or {}

        -- Skip checks
        if skipExclusiveSpells[spellID] then
            -- Excluded by exclusive group collapse
        elseif self:_ShouldSkipForDruidForm(spellID, cfg, context, LibSpellDB) then
            -- Wrong feral form
        elseif self:_ShouldSkipForTotemBar(spellID, spellData, context, LibSpellDB) then
            -- TotemBar handles this totem
        else
            self:_AssignSpellToRow(spellID, trackedData, cfg, rowConfigs, iconsByRow, spellAssignments, LibSpellDB)
        end
    end

    -- Phase 3: Sort spells within each row
    self:_SortRowSpells(iconsByRow)

    return iconsByRow, spellAssignments
end

-------------------------------------------------------------------------------
-- Internal: Exclusive BuffGroup Collapse
-- Groups tracked spells by BuffGroup (respecting auraTarget), picks one
-- representative per group, marks the rest for skipping.
-------------------------------------------------------------------------------

function SpellAssignment:_CollapseExclusiveGroups(trackedSpells, rowConfigs, spellCfg)
    local LibSpellDB = addon.LibSpellDB
    local skipExclusiveSpells = {}

    -- Group tracked spells by their exclusive BuffGroup, sub-grouped by auraTarget.
    -- Spells with different auraTargets (e.g., Earth Shield=ally vs Water Shield=self)
    -- can coexist on different units, so they must NOT collapse together.
    local exclusiveGroups = {}  -- subKey -> {spellID, ...}
    for spellID, trackedData in pairs(trackedSpells) do
        local groupName, groupInfo = LibSpellDB:GetBuffGroup(spellID)
        if groupName and groupInfo and groupInfo.relationship == "exclusive" then
            local auraTarget = LibSpellDB:GetAuraTarget(spellID) or "self"
            local subKey = groupName .. "|" .. auraTarget
            if not exclusiveGroups[subKey] then
                exclusiveGroups[subKey] = {}
            end
            table.insert(exclusiveGroups[subKey], {
                spellID = spellID,
                spellData = trackedData.spellData,
            })
        end
    end

    -- For each group with 2+ tracked members, pick the best representative
    for groupName, members in pairs(exclusiveGroups) do
        if #members >= 2 then
            -- Pick representative: spellConfig rowIndex override > highest-priority row > priority > spellID
            local bestSpellID = nil
            local bestRowIndex = 999
            local bestPriority = 999

            for _, member in ipairs(members) do
                local cfg = spellCfg[member.spellID] or {}

                -- Determine effective row index (lower = higher priority)
                local rowIndex = 999
                if cfg.rowIndex then
                    -- Use actual override row (consistent with UI representative selection)
                    rowIndex = cfg.rowIndex
                else
                    -- Find natural row by tag matching (same logic as main assignment)
                    for ri, rowConfig in ipairs(rowConfigs) do
                        for _, tag in ipairs(rowConfig.tags) do
                            if LibSpellDB:HasTag(member.spellID, tag) then
                                rowIndex = ri
                                break
                            end
                        end
                        if rowIndex < 999 then break end
                    end
                end

                local priority = member.spellData.priority or 999

                -- Lower rowIndex wins, then lower priority, then lower spellID
                if not bestSpellID
                    or rowIndex < bestRowIndex
                    or (rowIndex == bestRowIndex and priority < bestPriority)
                    or (rowIndex == bestRowIndex and priority == bestPriority and member.spellID < bestSpellID) then
                    bestSpellID = member.spellID
                    bestRowIndex = rowIndex
                    bestPriority = priority
                end
            end

            -- Mark all non-representative members for skipping
            for _, member in ipairs(members) do
                if member.spellID ~= bestSpellID then
                    skipExclusiveSpells[member.spellID] = true
                end
            end

            self.Utils:LogDebug("ExclusiveGroup", groupName .. ": representative", bestSpellID,
                "(" .. #members .. " members, skipping " .. (#members - 1) .. ")")
        end
    end

    return skipExclusiveSpells
end

-------------------------------------------------------------------------------
-- Internal: Druid Form Filtering
-- Returns true if spell should be skipped for the current feral form.
-------------------------------------------------------------------------------

function SpellAssignment:_ShouldSkipForDruidForm(spellID, cfg, context, LibSpellDB)
    if not context.isFeralDruid then return false end

    local formOverride = cfg.druidForm  -- "CAT", "BEAR", "ANY", or nil
    if formOverride == "ANY" then
        return false
    elseif formOverride == "CAT" then
        return context.activeFeralForm ~= "CAT"
    elseif formOverride == "BEAR" then
        return context.activeFeralForm ~= "BEAR"
    else
        -- Default: tag-based filtering
        local isCatSpell = LibSpellDB:HasTag(spellID, "CAT_FORM")
        local isBearSpell = LibSpellDB:HasTag(spellID, "BEAR_FORM")
        if (isCatSpell and context.activeFeralForm ~= "CAT") or
           (isBearSpell and context.activeFeralForm ~= "BEAR") then
            return true
        end
    end

    return false
end

-------------------------------------------------------------------------------
-- Internal: TotemBar Filtering
-- Returns true if spell should be skipped because TotemBar handles it.
-- Skips zero-CD element-tagged totems when TotemBar is active.
-------------------------------------------------------------------------------

function SpellAssignment:_ShouldSkipForTotemBar(spellID, spellData, context, LibSpellDB)
    if not context.totemBarActive then return false end

    local hasElementTag = LibSpellDB:HasTag(spellID, "TOTEM_EARTH")
        or LibSpellDB:HasTag(spellID, "TOTEM_FIRE")
        or LibSpellDB:HasTag(spellID, "TOTEM_WATER")
        or LibSpellDB:HasTag(spellID, "TOTEM_AIR")

    if hasElementTag and (spellData.cooldown or 0) == 0 then
        return true
    end

    return false
end

-------------------------------------------------------------------------------
-- Internal: Single Spell Assignment
-- Assigns one spell to a row via override path or tag-match path.
-------------------------------------------------------------------------------

function SpellAssignment:_AssignSpellToRow(spellID, trackedData, cfg, rowConfigs, iconsByRow, spellAssignments, LibSpellDB)
    local spellData = trackedData.spellData
    local assigned = false

    -- Override path: spell has explicit row assignment in spellConfig
    if cfg.rowIndex then
        local rowIndex = cfg.rowIndex
        local rowConfig = rowConfigs[rowIndex]

        -- If the overridden row is disabled, skip the spell entirely (don't spill to other rows)
        if rowConfig and rowConfig.enabled then
            if not iconsByRow[rowIndex] then
                iconsByRow[rowIndex] = {}
            end

            if #iconsByRow[rowIndex] < rowConfig.maxIcons then
                table.insert(iconsByRow[rowIndex], {
                    spellID = spellID,
                    actualSpellID = trackedData.actualSpellID or spellID,
                    spellData = spellData,
                    customOrder = cfg.order,
                })
                spellAssignments[spellID] = rowIndex
                assigned = true
            end
        else
            assigned = true  -- Treat as assigned so it doesn't fall through
        end
    end

    -- Tag-match path: find first matching row based on tags.
    -- Match against ALL rows (including disabled) to find the spell's natural home.
    -- If that row is disabled, the spell is hidden — not moved to another row.
    if not assigned then
        for rowIndex, rowConfig in ipairs(rowConfigs) do
            if not assigned then
                for _, requiredTag in ipairs(rowConfig.tags) do
                    if LibSpellDB:HasTag(spellID, requiredTag) then
                        -- This is the spell's natural row
                        if rowConfig.enabled then
                            if not iconsByRow[rowIndex] then
                                iconsByRow[rowIndex] = {}
                            end

                            if #iconsByRow[rowIndex] < rowConfig.maxIcons then
                                table.insert(iconsByRow[rowIndex], {
                                    spellID = spellID,
                                    actualSpellID = trackedData.actualSpellID or spellID,
                                    spellData = spellData,
                                    customOrder = cfg.order,
                                })
                                spellAssignments[spellID] = rowIndex
                            end
                        end
                        -- Whether enabled or not, this was the natural row — stop looking
                        assigned = true
                        break
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Internal: Within-Row Sorting
-- Two-pass sort: first by priority/cooldown/spellID (stable), then by
-- custom order overrides. Assigns defaultOrder for tie-breaking.
-------------------------------------------------------------------------------

function SpellAssignment:_SortRowSpells(iconsByRow)
    for rowIndex, spells in pairs(iconsByRow) do
        -- Pass 1: sort by priority/cooldown/spellID to establish default order
        table.sort(spells, function(a, b)
            local priorityA = a.spellData.priority or 999
            local priorityB = b.spellData.priority or 999
            if priorityA ~= priorityB then
                return priorityA < priorityB
            end
            local cdA = a.spellData.cooldown or 0
            local cdB = b.spellData.cooldown or 0
            if cdA ~= cdB then
                return cdA < cdB
            end
            return a.spellID < b.spellID
        end)

        -- Assign default order indices
        for i, spell in ipairs(spells) do
            spell.defaultOrder = i
        end

        -- Pass 2: re-sort applying custom order overrides
        table.sort(spells, function(a, b)
            local orderA = a.customOrder or a.defaultOrder
            local orderB = b.customOrder or b.defaultOrder
            return orderA < orderB
        end)
    end
end
