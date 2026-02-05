--[[
    VeevHUD - Keybind Detection and Display
    Handles scanning action bars for spell keybinds and formatting for display.
    Supports Bartender4, ElvUI, Dominos, and default UI action bars.
]]

local ADDON_NAME, addon = ...

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
-- Cleared on ACTIONBAR_SLOT_CHANGED or UPDATE_BINDINGS
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

-- Check if a macro contains/casts a specific spell
-- Returns true if the macro's primary spell matches the target spellID
local function MacroContainsSpell(macroIndex, targetSpellID)
    if not macroIndex or not targetSpellID then return false end
    
    -- GetMacroSpell returns the spell name and ID of the spell the macro icon represents
    local spellName, _, spellID = GetMacroSpell(macroIndex)
    if spellID and spellID == targetSpellID then
        return true
    end
    
    -- Also check by spell name (for rank-less matching)
    if spellName then
        local targetName = GetSpellInfo(targetSpellID)
        if targetName and spellName == targetName then
            return true
        end
    end
    
    return false
end

-- Check if an action slot's icon matches a spell's icon
-- This is a fallback for macros where GetMacroSpell doesn't return the spell
local function SlotIconMatchesSpell(slot, targetSpellID)
    if not HasAction(slot) then return false end
    
    local actionTexture = GetActionTexture(slot)
    if not actionTexture then return false end
    
    local spellTexture = GetSpellTexture(targetSpellID)
    if not spellTexture then return false end
    
    -- Compare texture paths (normalize to handle path variations)
    -- Textures can be numbers (fileIDs) or strings (paths)
    if type(actionTexture) == "number" and type(spellTexture) == "number" then
        return actionTexture == spellTexture
    elseif type(actionTexture) == "string" and type(spellTexture) == "string" then
        -- Normalize paths for comparison (lowercase, strip interface prefix)
        local normAction = actionTexture:lower():gsub("interface\\icons\\", "")
        local normSpell = spellTexture:lower():gsub("interface\\icons\\", "")
        return normAction == normSpell
    end
    
    return false
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

-- Check if an action slot contains the target spell (directly, via macro, or by icon match)
local function SlotContainsSpell(slot, targetSpellID)
    local actionType, actionID = GetActionInfo(slot)
    
    if actionType == "spell" then
        -- Check by ID first, then by name for different ranks
        return SpellsMatch(actionID, targetSpellID)
    elseif actionType == "macro" then
        -- First try GetMacroSpell
        if MacroContainsSpell(actionID, targetSpellID) then
            return true
        end
        -- Fall back to icon matching for complex macros
        return SlotIconMatchesSpell(slot, targetSpellID)
    end
    
    return false
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
--   Slots 25-36:  Bottom Left Bar - MULTIACTIONBAR3BUTTON1-12
--   Slots 37-48:  Bottom Right Bar - MULTIACTIONBAR4BUTTON1-12
--   Slots 49-60:  Right Bar 1 - MULTIACTIONBAR2BUTTON1-12
--   Slots 61-72:  Right Bar 2 - MULTIACTIONBAR1BUTTON1-12
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
                    if button and button.action == targetSlot then
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
                    local buttonAction = button.action or (button._state_action)
                    if buttonAction == targetSlot then
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

-------------------------------------------------------------------------------
-- Main API
-------------------------------------------------------------------------------

-- Find the keybind for a spell by scanning all action bars
-- Handles direct spells AND macros that cast the spell
-- Supports Bartender4, ElvUI, and default UI
-- Returns the formatted keybind string (e.g., "SX") or nil if not found
function Keybinds:GetKeybindForSpell(spellID)
    if not spellID then return nil end
    
    -- Check cache first
    local cached = self._cache[spellID]
    if cached ~= nil then
        return cached or nil  -- cached is false if not found, or string if found
    end
    
    -- Determine max slots to scan based on addon
    local maxSlots = _G["Bartender4"] and MAX_SLOTS_BARTENDER4 or MAX_SLOTS_DEFAULT
    
    -- Scan all action bar slots
    for slot = 1, maxSlots do
        if SlotContainsSpell(slot, spellID) then
            local key = GetKeybindForSlot(slot)
            if key then
                local formatted = self:FormatKeybind(key)
                self._cache[spellID] = formatted
                return formatted
            end
            -- Found spell but no keybind on this slot - continue searching
        end
    end
    
    -- Not found or no keybind
    self._cache[spellID] = false
    return nil
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
    keybindText:SetFont(fontPath, fontSize, "OUTLINE")
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
    
    -- Get the spell ID (actualSpellID handles rank variants, etc.)
    local spellID = frame.actualSpellID or frame.spellID
    if not spellID then
        frame.keybindText:Hide()
        return
    end
    
    -- Look up and display the keybind
    local keybind = self:GetKeybindForSpell(spellID)
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
        frame.keybindText:SetFont(fontPath, fontSize, "OUTLINE")
    end
end
