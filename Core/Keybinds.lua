--[[
    VeevHUD - Keybind Detection and Display
    Handles scanning action bars for spell keybinds and formatting for display.
    Supports Bartender4, ElvUI, Dominos, and default UI action bars.
]]

local _, addon = ...

addon.Keybinds = {}
local Keybinds = addon.Keybinds

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------

-- Maximum action slots to scan (Bartender4 can have up to 180)
local MAX_SLOTS_DEFAULT = 120
local MAX_SLOTS_BARTENDER4 = 180

-------------------------------------------------------------------------------
-- Cache
-------------------------------------------------------------------------------

-- Keybind lookup cache: spellID -> formatted keybind string or false (not found)
-- Item/trinket lookups use string keys ("inventory:14", "item:12345").
-- Cleared on action-bar, binding, and macro updates.
Keybinds._cache = {}

-- Clear the keybind cache (called when action bar or bindings change)
function Keybinds:ClearCache()
    wipe(self._cache)
end

-------------------------------------------------------------------------------
-- Action Bar Addon Detection
-------------------------------------------------------------------------------

-- Detect which action bar addon is being used
local function GetActionBarAddon()
    if _G["Bartender4"] then
        return "Bartender4"
    elseif _G["ElvUI"] and _G["ElvUI_Bar1Button1"] then
        return "ElvUI"
    elseif _G["Dominos"] then
        return "Dominos"
    end
    return "Default"
end

-------------------------------------------------------------------------------
-- Keybind Formatting
-------------------------------------------------------------------------------

-- Format a key binding to a short display string
-- Example: "SHIFT-X" -> "SX", "CTRL-ALT-1" -> "CA1", "MOUSEWHEELDOWN" -> "WD"
function Keybinds:FormatKeybind(key)
    if not key then return nil end
    
    key = key:upper()
    key = key:gsub(" ", "")
    
    -- Modifier keys -> single letters (order matters for gsub)
    key = key:gsub("CTRL%-", "C")
    key = key:gsub("ALT%-", "A")
    key = key:gsub("SHIFT%-", "S")
    key = key:gsub("META%-", "M")  -- Command key on Mac
    
    -- NumPad prefix
    key = key:gsub("NUMPAD", "N")
    
    -- Math operators
    key = key:gsub("PLUS", "+")
    key = key:gsub("MINUS", "-")
    key = key:gsub("MULTIPLY", "*")
    key = key:gsub("DIVIDE", "/")
    
    -- Special keys
    key = key:gsub("BACKSPACE", "BS")
    key = key:gsub("CAPSLOCK", "Cp")
    key = key:gsub("CLEAR", "Cl")
    key = key:gsub("DELETE", "Del")
    key = key:gsub("END", "En")
    key = key:gsub("HOME", "HM")
    key = key:gsub("INSERT", "Ins")
    key = key:gsub("NUMLOCK", "NL")
    key = key:gsub("PAGEDOWN", "PD")
    key = key:gsub("PAGEUP", "PU")
    key = key:gsub("SCROLLLOCK", "SL")
    key = key:gsub("SPACEBAR", "Sp")
    key = key:gsub("SPACE", "Sp")
    key = key:gsub("TAB", "Tb")
    
    -- Mouse buttons (do these before generic BUTTON replacement)
    key = key:gsub("MOUSEWHEELDOWN", "WD")
    key = key:gsub("MOUSEWHEELUP", "WU")
    key = key:gsub("BUTTON", "M")  -- Mouse buttons: BUTTON1 -> M1, etc.
    
    -- Arrow keys
    key = key:gsub("DOWNARROW", "Dn")
    key = key:gsub("LEFTARROW", "Lf")
    key = key:gsub("RIGHTARROW", "Rt")
    key = key:gsub("UPARROW", "Up")
    
    return key
end

-------------------------------------------------------------------------------
-- Spell Detection in Action Slots
-------------------------------------------------------------------------------

-- Get the macro body across clients. Some builds return body as the third
-- result, while others may expose it later in the return list.
local function GetMacroBody(macroIndex)
    if not macroIndex then return nil end

    local _, _, body, _, body5 = GetMacroInfo(macroIndex)
    if type(body) == "string" then
        return body
    end
    if type(body5) == "string" then
        return body5
    end
    return nil
end

-- Check if an action slot's icon matches a spell's icon
-- This is a fallback for macros where GetMacroSpell doesn't return the spell
local function SlotIconSpellScore(slot, targetSpellID)
    if not HasAction(slot) then return nil end
    
    local actionTexture = GetActionTexture(slot)
    if not actionTexture then return nil end
    
    local spellTexture = GetSpellTexture(targetSpellID)
    if not spellTexture then return nil end
    
    -- Compare texture paths (normalize to handle path variations)
    -- Textures can be numbers (fileIDs) or strings (paths)
    if type(actionTexture) == "number" and type(spellTexture) == "number" then
        return actionTexture == spellTexture and 20 or nil
    elseif type(actionTexture) == "string" and type(spellTexture) == "string" then
        -- Normalize paths for comparison (lowercase, strip interface prefix)
        local normAction = actionTexture:lower():gsub("interface\\icons\\", "")
        local normSpell = spellTexture:lower():gsub("interface\\icons\\", "")
        return normAction == normSpell and 20 or nil
    end
    
    return nil
end

-- Check if two spells are the same (accounting for different ranks in Classic)
-- Returns true if the spells have the same base name
local function SpellsMatch(spellID1, spellID2)
    if spellID1 == spellID2 then return true end
    if not spellID1 or not spellID2 then return false end
    
    -- Compare by spell name to handle different ranks
    local name1 = GetSpellInfo(spellID1)
    local name2 = GetSpellInfo(spellID2)
    
    return name1 and name2 and name1 == name2
end

local function StripMacroConditionals(text)
    if not text then return "" end

    -- Remove option blocks before parsing arguments:
    -- /cast [combat,@player] Mortal Strike -> /cast Mortal Strike
    return text:gsub("%b[]%s*", "")
end

local function TextContainsSpellName(text, spellName)
    if not text or not spellName then return false end

    local startIndex = text:find(spellName, 1, true)
    if not startIndex then return false end

    local beforeIndex = startIndex - 1
    local afterIndex = startIndex + #spellName
    local beforeOK = beforeIndex < 1 or not text:sub(beforeIndex, beforeIndex):match("[%w]")
    local afterOK = afterIndex > #text or not text:sub(afterIndex, afterIndex):match("[%w]")
    return beforeOK and afterOK
end

local function MacroConditionPenalty(segment)
    if not segment then return 0 end

    local lower = segment:lower()
    local penalty = 0
    if lower:find("@focus", 1, true) or lower:find("target=focus", 1, true) or lower:find("target:focus", 1, true) then
        penalty = penalty + 25
    end
    if lower:find("@mouseover", 1, true) or lower:find("target=mouseover", 1, true) or lower:find("target:mouseover", 1, true) then
        penalty = penalty + 12
    end
    if lower:find("mod:", 1, true) or lower:find("modifier:", 1, true) then
        penalty = penalty + 12
    end
    if lower:find("stance:", 1, true) or lower:find("nostance:", 1, true)
        or lower:find("combat", 1, true) or lower:find("nocombat", 1, true) then
        penalty = penalty + 3
    end

    return penalty
end

local function MacroCommandFromLine(line)
    if not line then return nil end

    local command, args = line:match("^%s*/([%a%d]+)%s*(.*)$")
    if command then
        return command:lower(), args or ""
    end

    args = line:match("^%s*#showtooltip%s*(.*)$")
    if args then
        return "#showtooltip", args
    end
    return nil
end

local function MacroSegmentSpellScore(segment, targetNameLower, baseScore)
    if not segment or not targetNameLower then return nil end

    local stripped = StripMacroConditionals(segment:lower())
    stripped = stripped:gsub("[,;]", " ")

    -- Castsequence options such as "reset=120" are not spell names.
    while stripped:match("^%s*[%w_:]+=%S+%s+") do
        stripped = stripped:gsub("^%s*[%w_:]+=%S+%s+", "", 1)
    end

    if TextContainsSpellName(stripped, targetNameLower) then
        return baseScore - MacroConditionPenalty(segment)
    end
    return nil
end

local function MacroBodySpellScore(body, targetSpellID)
    if not body or not targetSpellID then return nil end

    local targetName = GetSpellInfo(targetSpellID)
    if not targetName then return nil end

    local targetNameLower = targetName:lower()
    local bestScore
    local tooltipMatches = false
    for line in body:gmatch("[^\r\n]+") do
        local command, args = MacroCommandFromLine(line)
        local baseScore
        if command == "cast" then
            baseScore = 95
        elseif command == "castsequence" then
            baseScore = 82
        elseif command == "#showtooltip" then
            baseScore = 1
        end

        if baseScore and args then
            for segment in args:gmatch("[^;]+") do
                local score = MacroSegmentSpellScore(segment, targetNameLower, baseScore)
                if score then
                    if command == "#showtooltip" then
                        tooltipMatches = true
                    elseif not bestScore or score > bestScore then
                        bestScore = score
                    end
                end
            end
        end
    end

    if bestScore and tooltipMatches then
        bestScore = bestScore + 4
    end
    return bestScore
end

local function MacroSpellAPIScore(macroIndex, targetSpellID)
    if not macroIndex or not targetSpellID then return nil end

    -- GetMacroSpell's signature differs by client: modern Classic returns
    -- just the spellID; legacy clients returned (name, rank, spellID).
    -- The old 3-return destructure put a number in the name slot and nil in
    -- the ID slot, so macro keybinds never matched.
    local first, _, third = GetMacroSpell(macroIndex)
    local macroSpellID = type(first) == "number" and first or third

    if macroSpellID then
        if macroSpellID == targetSpellID then
            return 70
        end
        local macroName = GetSpellInfo(macroSpellID)
        local targetName = GetSpellInfo(targetSpellID)
        if macroName and targetName and macroName == targetName then
            return 65
        end
    elseif type(first) == "string" then
        local targetName = GetSpellInfo(targetSpellID)
        if targetName and first == targetName then
            return 60
        end
    end

    return nil
end

local function MacroSpellScore(macroIndex, targetSpellID, slot)
    local body = GetMacroBody(macroIndex)
    local bodyMissing = body == nil
    if bodyMissing then
        local fallbackScore = MacroSpellAPIScore(macroIndex, targetSpellID)
            or SlotIconSpellScore(slot, targetSpellID)
        return fallbackScore, fallbackScore ~= nil
    end

    local score = MacroBodySpellScore(body, targetSpellID)
    if score then
        local macroName = GetMacroInfo(macroIndex)
        local targetName = GetSpellInfo(targetSpellID)
        if macroName and targetName then
            local macroLower = macroName:lower()
            local targetLower = targetName:lower()
            if macroLower == targetLower then
                score = score + 6
            elseif macroLower:find(targetLower, 1, true) then
                score = score + 3
            end
        end
    end

    return score, false
end

local function GetSlotSpellScore(slot, targetSpellID)
    local actionType, actionID = GetActionInfo(slot)

    if actionType == "spell" then
        if actionID == targetSpellID then
            -- Direct spell actions are a strong match, but not unbeatable:
            -- hidden stance/page copies can otherwise override the macro the
            -- player actually bound on the visible bar. Visible buttons still
            -- win through the +35 visible-button candidate bonus.
            return 94, false
        elseif SpellsMatch(actionID, targetSpellID) then
            return 88, false
        end
    elseif actionType == "macro" then
        return MacroSpellScore(actionID, targetSpellID, slot)
    end

    return nil, false
end

local function MacroSegmentItemScore(segment, targetItemID, targetNameLower, baseScore)
    if not segment or not targetItemID then return nil end

    local stripped = StripMacroConditionals(segment:lower())
    stripped = stripped:match("^%s*(.-)%s*$") or ""

    -- Castsequence options such as "reset=120" are not item references.
    while stripped:match("^%s*[%w_:]+=%S+%s+") do
        stripped = stripped:gsub("^%s*[%w_:]+=%S+%s+", "", 1)
    end

    local targetText = tostring(targetItemID)
    for itemText in stripped:gmatch("item:(%d+)") do
        if itemText == targetText then
            return baseScore - MacroConditionPenalty(segment)
        end
    end

    -- WoW also accepts a bare item ID in /use commands.
    for numberText in stripped:gmatch("%f[%d](%d+)%f[%D]") do
        if numberText == targetText then
            return baseScore - MacroConditionPenalty(segment)
        end
    end

    if targetNameLower and TextContainsSpellName(stripped, targetNameLower) then
        return baseScore - MacroConditionPenalty(segment)
    end

    return nil
end

local function MacroBodyItemScore(body, targetItemID)
    if not body or not targetItemID then return nil end

    local targetName = GetItemInfo(targetItemID)
    local targetNameLower = targetName and targetName:lower() or nil
    local bestScore
    local tooltipMatches = false

    for line in body:gmatch("[^\r\n]+") do
        local command, args = MacroCommandFromLine(line)
        local baseScore
        if command == "use" or command == "use13" or command == "use14" then
            baseScore = 95
        elseif command == "castsequence" then
            baseScore = 82
        elseif command == "#showtooltip" then
            baseScore = 1
        end

        if baseScore and args then
            for segment in args:gmatch("[^;]+") do
                local score = MacroSegmentItemScore(segment, targetItemID, targetNameLower, baseScore)
                if score then
                    if command == "#showtooltip" then
                        tooltipMatches = true
                    elseif not bestScore or score > bestScore then
                        bestScore = score
                    end
                end
            end
        end
    end

    if bestScore and tooltipMatches then
        bestScore = bestScore + 4
    end
    return bestScore
end

local function MacroItemScore(macroIndex, targetItemID)
    if not macroIndex or not targetItemID then return nil, false end

    local body = GetMacroBody(macroIndex)
    if not body then return nil, true end

    return MacroBodyItemScore(body, targetItemID), false
end

local function GetSlotItemScore(slot, targetItemID)
    local actionType, actionID = GetActionInfo(slot)

    if actionType == "item" and tonumber(actionID) == targetItemID then
        return 94, false
    elseif actionType == "macro" then
        return MacroItemScore(actionID, targetItemID)
    end

    return nil, false
end

-- Check if an action slot contains the target spell directly, via macro body,
-- via GetMacroSpell, or as a low-confidence icon fallback.
local function SlotContainsSpell(slot, targetSpellID)
    local score = GetSlotSpellScore(slot, targetSpellID)
    return score ~= nil
end

local function IsUseCommandLine(line)
    if not line then return false end

    line = line:match("^%s*(.-)%s*$")
    return line:match("^/use%s+")
        or line:match("^/use13%s+")
        or line:match("^/use14%s+")
        or line:match("^/cast%s+")
        or line:match("^/castsequence%s+")
end

-- Check whether a macro body uses an equipment slot directly, e.g.:
--   /use 14
--   /use [combat] 13
--   /castsequence reset=120 13, 14
local function MacroContainsInventorySlot(macroIndex, inventorySlot)
    if not macroIndex or not inventorySlot then return nil, false end

    local body = GetMacroBody(macroIndex)
    if not body then return nil, true end

    local slotText = tostring(inventorySlot)
    local bestScore
    for line in body:gmatch("[^\r\n]+") do
        line = line:lower()
        if IsUseCommandLine(line) then
            local args = StripMacroConditionals(line)
            args = args:gsub("[,;]", " ")
            for token in args:gmatch("%S+") do
                if token == slotText then
                    local score = 95 - MacroConditionPenalty(line)
                    if not bestScore or score > bestScore then
                        bestScore = score
                    end
                end
            end
        end
    end

    return bestScore, false
end

-- Check if an action slot activates an inventory slot directly.
local function SlotContainsInventorySlot(slot, inventorySlot, equippedItemID)
    local actionType, actionID = GetActionInfo(slot)

    if actionType == "item" and equippedItemID and tonumber(actionID) == equippedItemID then
        return 94, false
    elseif actionType == "macro" then
        local slotScore, bodyMissing = MacroContainsInventorySlot(actionID, inventorySlot)
        if slotScore or bodyMissing then
            return slotScore, bodyMissing
        end
        return MacroItemScore(actionID, equippedItemID)
    end

    return nil, false
end

local function GetButtonAction(button)
    if not button then return nil end

    local action = button.action or button._state_action
    if not action and button.GetAttribute then
        action = button:GetAttribute("action")
    end

    return tonumber(action) or action
end

-------------------------------------------------------------------------------
-- Keybind Retrieval (Per Addon)
-------------------------------------------------------------------------------

-- Get keybind for a slot using Bartender4's binding system
local function GetBartender4Keybind(slot)
    -- Bartender4 can use several binding formats, try them all
    -- Format 1: "CLICK BT4Button{slot}:Keybind" (primary)
    local key = GetBindingKey("CLICK BT4Button" .. slot .. ":Keybind")
    if key then return key end
    
    -- Format 2: "CLICK BT4Button{slot}:LeftButton" (alternative)
    key = GetBindingKey("CLICK BT4Button" .. slot .. ":LeftButton")
    if key then return key end
    
    -- Format 3: Check if there's a Bartender4 button object with binding info
    local btn = _G["BT4Button" .. slot]
    if btn then
        -- Try to get binding from the button's config
        if btn.config and btn.config.keyBoundTarget then
            key = GetBindingKey(btn.config.keyBoundTarget)
            if key then return key end
        end
        -- Try click binding with button name
        key = GetBindingKey("CLICK " .. btn:GetName() .. ":LeftButton")
        if key then return key end
    end
    
    return nil
end

-- Get keybind for a slot using ElvUI's binding system
local function GetElvUIKeybind(slot)
    -- ElvUI bar/button mapping
    local bar = math.ceil(slot / 12)
    local button = ((slot - 1) % 12) + 1
    
    local btn = _G["ElvUI_Bar" .. bar .. "Button" .. button]
    if btn then
        -- ElvUI's bar→action-page mapping is configurable, so the
        -- name-derived button may hold a DIFFERENT action slot — trusting it
        -- blindly would display the wrong keybind. Only use it when its
        -- action matches; otherwise fall through to the generic button scan.
        local btnAction = GetButtonAction(btn)
        if btnAction and btnAction ~= slot then
            return nil
        end
        -- ElvUI stores binding info on the button
        local binding = btn.bindstring or btn.keyBoundTarget
        if binding then
            return GetBindingKey(binding)
        end
        -- Fallback to click binding
        local clickBinding = "CLICK " .. btn:GetName() .. ":LeftButton"
        return GetBindingKey(clickBinding)
    end
    return nil
end

-- Get keybind for a slot using default UI binding names
-- Classic action bar slot layout:
--   Slots 1-12:   Main Action Bar (page 1) - ACTIONBUTTON1-12
--   Slots 13-24:  Main Action Bar (page 2) - ACTIONBUTTON1-12 (same bindings, different page)
--   Slots 25-36:  Right Bar (MultiBarRight) - MULTIACTIONBAR3BUTTON1-12
--   Slots 37-48:  Right Bar 2 (MultiBarLeft) - MULTIACTIONBAR4BUTTON1-12
--   Slots 49-60:  Bottom Right Bar (MultiBarBottomRight) - MULTIACTIONBAR2BUTTON1-12
--   Slots 61-72:  Bottom Left Bar (MultiBarBottomLeft) - MULTIACTIONBAR1BUTTON1-12
--   Slots 73-120: Additional pages (7-10), use ACTIONBUTTON with page switching
local function GetDefaultUIKeybind(slot)
    local bindingName
    
    if slot >= 1 and slot <= 12 then
        bindingName = "ACTIONBUTTON" .. slot
    elseif slot >= 13 and slot <= 24 then
        bindingName = "ACTIONBUTTON" .. (slot - 12)
    elseif slot >= 25 and slot <= 36 then
        bindingName = "MULTIACTIONBAR3BUTTON" .. (slot - 24)
    elseif slot >= 37 and slot <= 48 then
        bindingName = "MULTIACTIONBAR4BUTTON" .. (slot - 36)
    elseif slot >= 49 and slot <= 60 then
        bindingName = "MULTIACTIONBAR2BUTTON" .. (slot - 48)
    elseif slot >= 61 and slot <= 72 then
        bindingName = "MULTIACTIONBAR1BUTTON" .. (slot - 60)
    elseif slot >= 73 and slot <= 120 then
        bindingName = "ACTIONBUTTON" .. (1 + (slot - 73) % 12)
    end
    
    if bindingName then
        return GetBindingKey(bindingName)
    end
    return nil
end

-- Try to get keybind by scanning all visible action buttons for a matching action
-- This is a fallback that works with any action bar addon
local function GetKeybindByButtonScan(targetSlot)
    -- Common button name patterns used by various addons
    local buttonPatterns = {
        "BT4Button%d",           -- Bartender4
        "ActionButton%d",        -- Default UI
        "MultiBarBottomLeftButton%d",
        "MultiBarBottomRightButton%d",
        "MultiBarRightButton%d",
        "MultiBarLeftButton%d",
        "ElvUI_Bar%dButton%d",   -- ElvUI
        "DominosActionButton%d", -- Dominos
    }
    
    -- Check numbered buttons 1-12 for each pattern
    for _, pattern in ipairs(buttonPatterns) do
        if pattern:find("%%d.*%%d") then
            -- Two %d pattern (like ElvUI)
            for bar = 1, 10 do
                for btn = 1, 12 do
                    local buttonName = pattern:format(bar, btn)
                    local button = _G[buttonName]
                    if button and GetButtonAction(button) == targetSlot then
                        -- Found the button, now get its keybind
                        local key = GetBindingKey("CLICK " .. buttonName .. ":LeftButton")
                            or GetBindingKey("CLICK " .. buttonName .. ":Keybind")
                        if key then return key end
                    end
                end
            end
        else
            -- Single %d pattern
            for i = 1, 180 do
                local buttonName = pattern:format(i)
                local button = _G[buttonName]
                if button then
                    if GetButtonAction(button) == targetSlot then
                        local key = GetBindingKey("CLICK " .. buttonName .. ":LeftButton")
                            or GetBindingKey("CLICK " .. buttonName .. ":Keybind")
                        if key then return key end
                    end
                end
            end
        end
    end
    
    return nil
end

-- Get the keybind for a specific action slot, handling different action bar addons
local function GetKeybindForSlot(slot)
    local barAddon = GetActionBarAddon()
    local key

    -- Prefer the button currently displaying this action slot. This matters for
    -- paged/stance bars where action slot 73 may be shown on BT4Button1.
    key = GetKeybindByButtonScan(slot)
    if key then return key end
    
    if barAddon == "Bartender4" then
        -- Try Bartender4 binding first
        key = GetBartender4Keybind(slot)
        if key then return key end
    elseif barAddon == "ElvUI" then
        key = GetElvUIKeybind(slot)
        if key then return key end
    end
    
    -- Try default UI bindings
    key = GetDefaultUIKeybind(slot)
    if key then return key end
    
    -- Last resort: scan all buttons to find one with this action
    return GetKeybindByButtonScan(slot)
end

local function GetInventorySlotKeybind(inventorySlot)
    local bindingName

    if inventorySlot == 13 then
        bindingName = "USETRINKET1"
    elseif inventorySlot == 14 then
        bindingName = "USETRINKET2"
    end

    if bindingName then
        return GetBindingKey(bindingName)
    end
    return nil
end

local function GetKeyModifierPenalty(key)
    if not key then return 0 end

    local upper = key:upper()
    local penalty = 0
    if upper:find("SHIFT%-") then penalty = penalty + 8 end
    if upper:find("CTRL%-") then penalty = penalty + 8 end
    if upper:find("ALT%-") then penalty = penalty + 8 end
    if upper:find("META%-") then penalty = penalty + 8 end
    return penalty
end

local function ConsiderKeybindCandidate(best, slot, key, matchScore, visible)
    if not key or not matchScore then return best end

    local modifierPenalty = GetKeyModifierPenalty(key)
    local candidate = {
        slot = slot,
        key = key,
        matchScore = matchScore,
        modifierPenalty = modifierPenalty,
        adjustedScore = matchScore + (visible and 35 or 0) - modifierPenalty,
    }

    if not best then return candidate end
    if candidate.adjustedScore ~= best.adjustedScore then
        return candidate.adjustedScore > best.adjustedScore and candidate or best
    end
    if candidate.matchScore ~= best.matchScore then
        return candidate.matchScore > best.matchScore and candidate or best
    end
    if candidate.modifierPenalty ~= best.modifierPenalty then
        return candidate.modifierPenalty < best.modifierPenalty and candidate or best
    end
    return candidate.slot < best.slot and candidate or best
end

local function AddSlotCandidate(best, slot, matchScore)
    local key = GetKeybindByButtonScan(slot)
    if key then
        return ConsiderKeybindCandidate(best, slot, key, matchScore, true)
    end

    key = GetKeybindForSlot(slot)
    if key then
        return ConsiderKeybindCandidate(best, slot, key, matchScore, false)
    end

    return best
end

-------------------------------------------------------------------------------
-- Main API
-------------------------------------------------------------------------------

-- Find the keybind for a spell by scanning all action bars
-- Handles direct spells AND macros that cast the spell
-- Supports Bartender4, ElvUI, and default UI
-- Returns the formatted keybind string (e.g., "SX") or nil if not found
--
-- Candidate scoring keeps displayed keys aligned with paged/stance buttons,
-- prefers macro bodies over icon guesses, and breaks ties toward unmodified
-- binds (B over Shift-B).
function Keybinds:GetKeybindForSpell(spellID)
    if not spellID then return nil end

    -- Check cache first
    local cached = self._cache[spellID]
    if cached ~= nil then
        return cached or nil  -- cached is false if not found, or string if found
    end

    -- Determine max slots to scan based on addon
    local maxSlots = _G["Bartender4"] and MAX_SLOTS_BARTENDER4 or MAX_SLOTS_DEFAULT

    local best
    local sawUnloadedMacro = false
    for slot = 1, maxSlots do
        local matchScore, bodyMissing = GetSlotSpellScore(slot, spellID)
        if bodyMissing then
            sawUnloadedMacro = true
        end
        if matchScore then
            best = AddSlotCandidate(best, slot, matchScore)
        end
    end

    if best then
        if sawUnloadedMacro then
            return nil
        end

        local formatted = self:FormatKeybind(best.key)
        if not sawUnloadedMacro then
            self._cache[spellID] = formatted
        end
        return formatted
    end

    -- Not found or no keybind
    if not sawUnloadedMacro then
        self._cache[spellID] = false
    end
    return nil
end

-- Find the keybind for an item placed directly on an action bar or referenced
-- by an item-aware macro (/use itemID, /use item:itemID, or /use Item Name).
function Keybinds:GetKeybindForItem(itemID)
    itemID = tonumber(itemID)
    if not itemID then return nil end

    local cacheKey = "item:" .. itemID
    local cached = self._cache[cacheKey]
    if cached ~= nil then
        return cached or nil
    end

    local maxSlots = _G["Bartender4"] and MAX_SLOTS_BARTENDER4 or MAX_SLOTS_DEFAULT
    local best
    local sawUnloadedMacro = false

    for slot = 1, maxSlots do
        local matchScore, bodyMissing = GetSlotItemScore(slot, itemID)
        if bodyMissing then
            sawUnloadedMacro = true
        end
        if matchScore then
            best = AddSlotCandidate(best, slot, matchScore)
        end
    end

    if best then
        if sawUnloadedMacro then
            return nil
        end

        local formatted = self:FormatKeybind(best.key)
        self._cache[cacheKey] = formatted
        return formatted
    end

    if not sawUnloadedMacro then
        self._cache[cacheKey] = false
    end
    return nil
end

-- Find the keybind for an inventory slot by scanning action bars for:
--   - the currently equipped item placed directly on an action bar
--   - a macro that activates the slot directly, e.g. /use 13 or /use 14
--   - a macro that activates the currently equipped item by ID or name
function Keybinds:GetKeybindForInventorySlot(inventorySlot)
    if not inventorySlot then return nil end

    local equippedItemID = GetInventoryItemID("player", inventorySlot) or 0
    local cacheKey = "inventory:" .. inventorySlot .. ":" .. equippedItemID
    local cached = self._cache[cacheKey]
    if cached ~= nil then
        return cached or nil
    end

    local maxSlots = _G["Bartender4"] and MAX_SLOTS_BARTENDER4 or MAX_SLOTS_DEFAULT

    local best
    local sawUnloadedMacro = false
    for slot = 1, maxSlots do
        local matchScore, bodyMissing = SlotContainsInventorySlot(slot, inventorySlot, equippedItemID)
        if bodyMissing then
            sawUnloadedMacro = true
        end
        if matchScore then
            best = AddSlotCandidate(best, slot, matchScore)
        end
    end

    if best then
        if sawUnloadedMacro then
            return nil
        end

        local formatted = self:FormatKeybind(best.key)
        if not sawUnloadedMacro then
            self._cache[cacheKey] = formatted
        end
        return formatted
    end

    if not sawUnloadedMacro then
        local key = GetInventorySlotKeybind(inventorySlot)
        if key then
            local formatted = self:FormatKeybind(key)
            self._cache[cacheKey] = formatted
            return formatted
        end

        self._cache[cacheKey] = false
    end
    return nil
end

-------------------------------------------------------------------------------
-- Debug
-------------------------------------------------------------------------------

local function ResolveSpellQuery(query)
    if not query or query == "" then return nil end

    local spellID = tonumber(query)
    if spellID then
        return spellID, GetSpellInfo(spellID)
    end

    local name, _, _, _, _, _, resolvedID = GetSpellInfo(query)
    if resolvedID then
        return resolvedID, name
    end

    local lowerQuery = query:lower()
    for i = 1, 500 do
        local spellName = GetSpellBookItemName(i, BOOKTYPE_SPELL)
        if not spellName then break end
        if spellName:lower() == lowerQuery then
            local _, spellBookID = GetSpellBookItemInfo(i, BOOKTYPE_SPELL)
            if spellBookID then
                return spellBookID, spellName
            end
        end
    end

    return nil
end

local function SafeText(value)
    if value == nil then return "nil" end
    return tostring(value)
end

local function GetMacroDebugInfo(actionType, actionID)
    if actionType ~= "macro" or not actionID then
        return nil, nil
    end

    local macroName, _, body = GetMacroInfo(actionID)
    if type(body) ~= "string" then
        body = GetMacroBody(actionID)
    end
    if type(body) == "string" then
        body = body:gsub("[\r\n]+", " / ")
        if #body > 180 then
            body = body:sub(1, 177) .. "..."
        end
    end

    return macroName, body
end

function Keybinds:DebugSpellKeybind(query)
    local spellID, spellName = ResolveSpellQuery(query)
    if not spellID then
        addon.Utils:Print("Usage: /vh keybind <spellID or spell name>")
        return
    end

    self:ClearCache()
    local final = self:GetKeybindForSpell(spellID)
    print("|cff00ff00VeevHUD Keybind Debug:|r " .. (spellName or "?") .. " (" .. spellID .. ") final=" .. SafeText(final))

    local maxSlots = _G["Bartender4"] and MAX_SLOTS_BARTENDER4 or MAX_SLOTS_DEFAULT
    local count = 0
    for slot = 1, maxSlots do
        local matchScore, bodyMissing = GetSlotSpellScore(slot, spellID)
        if matchScore or bodyMissing then
            count = count + 1
            local actionType, actionID = GetActionInfo(slot)
            local visibleKey = GetKeybindByButtonScan(slot)
            local fallbackKey = GetKeybindForSlot(slot)
            local macroName, macroBody = GetMacroDebugInfo(actionType, actionID)
            local visibleCandidate = visibleKey and ConsiderKeybindCandidate(nil, slot, visibleKey, matchScore or 0, true)
            local fallbackCandidate = fallbackKey and ConsiderKeybindCandidate(nil, slot, fallbackKey, matchScore or 0, false)

            print(string.format(
                "  slot=%d type=%s id=%s score=%s missingBody=%s visibleKey=%s visibleAdj=%s fallbackKey=%s fallbackAdj=%s macro=%s",
                slot,
                SafeText(actionType),
                SafeText(actionID),
                SafeText(matchScore),
                SafeText(bodyMissing),
                SafeText(visibleKey),
                SafeText(visibleCandidate and visibleCandidate.adjustedScore),
                SafeText(fallbackKey),
                SafeText(fallbackCandidate and fallbackCandidate.adjustedScore),
                SafeText(macroName)
            ))
            if macroBody then
                print("    " .. macroBody)
            end
        end
    end

    if count == 0 then
        print("  No matching action slots found.")
    end
end

-------------------------------------------------------------------------------
-- Keybind Text Display
-------------------------------------------------------------------------------

-- Text color for keybind display (neutral off-white to contrast with warm cooldown text)
local KEYBIND_TEXT_COLOR = { r = 0.9, g = 0.9, b = 0.9, a = 0.9 }

-- Create a keybind text FontString on a frame
-- Returns the FontString, positioned at bottom-right inside the icon
-- textParent: the frame to parent the FontString to (usually a text overlay frame)
-- fontPath: path to the font file
-- fontSize: font size in pixels
-- iconSize: size of the icon for proportional positioning
function Keybinds:CreateKeybindText(frame, textParent, fontPath, fontSize, iconSize)
    local offsetX = math.floor(iconSize * 0.10)  -- ~10% from right edge
    local offsetY = math.floor(iconSize * 0.10)  -- ~10% from bottom edge
    
    local keybindText = textParent:CreateFontString(nil, "OVERLAY", nil, 6)
    addon.Utils:ApplyFontOutline(keybindText, fontPath, fontSize, addon.db.profile.icons)
    keybindText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -offsetX, offsetY)
    keybindText:SetJustifyH("RIGHT")
    keybindText:SetJustifyV("BOTTOM")
    keybindText:SetTextColor(KEYBIND_TEXT_COLOR.r, KEYBIND_TEXT_COLOR.g, KEYBIND_TEXT_COLOR.b, KEYBIND_TEXT_COLOR.a)
    keybindText:Hide()  -- Hidden by default (setting is off)
    
    return keybindText
end

-- Update keybind text visibility and content for a single icon frame
-- frame: must have .keybindText, .spellID (or .actualSpellID), and .rowIndex properties
-- showKeybindSetting: the row setting value (e.g., "none", "primary", "all")
-- Uses addon.Database:IsRowSettingEnabled for proper row matching
function Keybinds:UpdateKeybindText(frame, showKeybindSetting)
    if not frame or not frame.keybindText then return end
    
    local rowIndex = frame.rowIndex or 1
    
    -- Check if keybind display is enabled for this row
    if not addon.Database:IsRowSettingEnabled(showKeybindSetting, rowIndex) then
        frame.keybindText:Hide()
        return
    end
    
    local keybind
    if frame.isTrinket and frame.trinketSlotID then
        keybind = self:GetKeybindForInventorySlot(frame.trinketSlotID)
    elseif frame.isConsumable and frame.consumableItemID then
        keybind = self:GetKeybindForItem(frame.consumableItemID)
    else
        -- Get the spell ID (actualSpellID handles rank variants, etc.)
        local spellID = frame.actualSpellID or frame.spellID
        if spellID then
            keybind = self:GetKeybindForSpell(spellID)
        end
    end
    
    if keybind then
        frame.keybindText:SetText(keybind)
        frame.keybindText:Show()
    else
        frame.keybindText:Hide()
    end
end

-- Update keybind text font (called when global font or keybind size changes)
-- frame: must have .keybindText property
-- fontPath: path to the font file
-- fontSize: font size in pixels
function Keybinds:UpdateKeybindFont(frame, fontPath, fontSize)
    if frame and frame.keybindText then
        addon.Utils:ApplyFontOutline(frame.keybindText, fontPath, fontSize, addon.db.profile.icons)
    end
end
