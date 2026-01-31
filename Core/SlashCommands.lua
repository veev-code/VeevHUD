--[[
    VeevHUD - Slash Commands
    Handles all /vh and /veevhud command processing
]]

local ADDON_NAME, addon = ...

addon.SlashCommands = {}
local SlashCommands = addon.SlashCommands

-------------------------------------------------------------------------------
-- Registration
-------------------------------------------------------------------------------

function SlashCommands:Register()
    SLASH_VEEVHUD1 = "/veevhud"
    SLASH_VEEVHUD2 = "/vh"

    SlashCmdList["VEEVHUD"] = function(msg)
        self:HandleCommand(msg)
    end
end

-------------------------------------------------------------------------------
-- Command Handler
-------------------------------------------------------------------------------

function SlashCommands:HandleCommand(msg)
    local args = {}
    for word in msg:gmatch("%S+") do
        table.insert(args, word:lower())
    end

    local cmd = args[1] or "options"

    if cmd == "help" then
        self:ShowHelp()

    elseif cmd == "reset" then
        addon:ResetProfile()

    elseif cmd == "toggle" then
        addon.db.profile.enabled = not addon.db.profile.enabled
        if addon.db.profile.enabled then
            addon.Utils:Print("HUD |cff00ff00enabled|r.")
        else
            addon.Utils:Print("HUD |cffff0000disabled|r.")
        end

    elseif cmd == "config" or cmd == "options" then
        local options = addon:GetModule("Options")
        if options then
            options:Open()
        else
            addon.Utils:Print("Options module not loaded.")
        end

    elseif cmd == "log" then
        local count = args[2] and tonumber(args[2]) or 20
        addon.Utils:PrintRecentLog(count)

    elseif cmd == "clearlog" then
        addon.Utils:ClearLog()

    elseif cmd == "debug" then
        addon.db.profile.debugMode = not addon.db.profile.debugMode
        local state = addon.db.profile.debugMode and "enabled" or "disabled"
        addon.Utils:Print("Debug mode " .. state)
        if addon.db.profile.debugMode then
            addon.Utils:StartNewSession()
            addon.Utils:Print("Logging to SavedVariables. Use /vh log to view.")
        else
            addon.Utils:ClearLog()
        end

    elseif cmd == "scan" or cmd == "rescan" then
        local tracker = addon:GetModule("SpellTracker")
        if tracker then
            tracker:FullRescan()
            addon.Utils:Print("Spells rescanned.")
        end

    elseif cmd == "spec" then
        self:ShowSpec()

    elseif cmd == "spells" then
        self:ListTrackedSpells()

    elseif cmd == "cd" then
        self:DebugCooldown(args[2])

    elseif cmd == "icon" then
        self:DebugIcon(args[2])

    elseif cmd == "usable" then
        self:DebugUsable(args[2])

    elseif cmd == "overlay" then
        self:DebugOverlay(args[2])

    elseif cmd == "check" then
        self:CheckSpell(args[2])

    elseif cmd == "layout" then
        if addon.Layout and addon.Layout.PrintDebug then
            addon.Layout:PrintDebug()
        else
            addon.Utils:Print("Layout system not available.")
        end

    else
        addon.Utils:Print("Unknown command. Type /vh help for usage.")
    end
end

-------------------------------------------------------------------------------
-- Help
-------------------------------------------------------------------------------

function SlashCommands:ShowHelp()
    addon.Utils:Print("Commands:")
    print("  /vh options - Open settings panel")
    print("  /vh reset - Reset to defaults")
    print("  /vh toggle - Enable/disable HUD")
    print("  /vh spec - Show detected spec")
    print("  /vh scan - Force rescan spells")
    print("  /vh check <id> - Diagnose why a spell isn't showing")
    print("  /vh layout - Debug layout system positions")
    print("  /vh log [n] - Show log entries")
    print("  /vh debug - Toggle debug mode")
end

-------------------------------------------------------------------------------
-- Spec Display
-------------------------------------------------------------------------------

function SlashCommands:ShowSpec()
    if addon.LibSpellDB then
        local spec, points = addon.LibSpellDB:DetectPlayerSpec()
        addon.playerSpec = spec
        addon.Utils:Print("Detected spec: |cff00ff00" .. (spec or "Unknown") .. "|r")
        addon.Utils:Print("Talents: " .. (points[1] or 0) .. "/" .. (points[2] or 0) .. "/" .. (points[3] or 0))
        
        local tracker = addon:GetModule("SpellTracker")
        if tracker then
            tracker:FullRescan()
        end
    else
        addon.Utils:Print("LibSpellDB not loaded")
    end
end

-------------------------------------------------------------------------------
-- Spell Listing
-------------------------------------------------------------------------------

function SlashCommands:ListTrackedSpells()
    local tracker = addon:GetModule("SpellTracker")
    if tracker then
        local tracked = tracker:GetTrackedSpells()
        local count = 0
        print("|cff00ff00VeevHUD Tracked Spells:|r")
        for spellID, data in pairs(tracked) do
            local name = GetSpellInfo(spellID) or "Unknown"
            local tags = data.spellData.tags and table.concat(data.spellData.tags, ", ") or "none"
            print(string.format("  |cffaaaaaa%d|r %s |cff888888(%s)|r", spellID, name, data.reason))
            count = count + 1
        end
        print(string.format("|cff00ff00Total: %d spells|r", count))
    end
end

-------------------------------------------------------------------------------
-- Debug Commands
-------------------------------------------------------------------------------

function SlashCommands:DebugCooldown(query)
    if not query then
        addon.Utils:Print("Usage: /vh cd <spellID or name>")
        return
    end
    
    local spellID = tonumber(query)
    local spellName
    
    if spellID then
        spellName = GetSpellInfo(spellID)
    else
        spellName = query
        for i = 1, 500 do
            local name = GetSpellBookItemName(i, BOOKTYPE_SPELL)
            if not name then break end
            if name:lower() == query:lower() then
                spellName = name
                break
            end
        end
    end
    
    print("|cff00ff00Cooldown Debug:|r " .. (spellName or query))
    
    if spellID then
        local startID, durID, enID = GetSpellCooldown(spellID)
        print(string.format("  By ID (%d): start=%.1f, dur=%.1f, enabled=%s", 
            spellID, startID or 0, durID or 0, tostring(enID)))
    end
    
    if spellName then
        local startN, durN, enN = GetSpellCooldown(spellName)
        print(string.format("  By Name (%s): start=%.1f, dur=%.1f, enabled=%s", 
            spellName, startN or 0, durN or 0, tostring(enN)))
    end
    
    if spellID then
        local rem, dur, en = addon.Utils:GetSpellCooldown(spellID)
        print(string.format("  Utils wrapper: remaining=%.1f, duration=%.1f", rem or 0, dur or 0))
    end
end

function SlashCommands:DebugIcon(spellIDStr)
    local spellID = spellIDStr and tonumber(spellIDStr)
    if not spellID then
        addon.Utils:Print("Usage: /vh icon <spellID>")
        return
    end
    
    local name = GetSpellInfo(spellID) or "Unknown"
    print("|cff00ff00Icon Debug:|r " .. name .. " (" .. spellID .. ")")
    
    local icons = addon:GetModule("CooldownIcons")
    if icons and icons.rows then
        local found = false
        for _, rowFrame in ipairs(icons.rows) do
            if rowFrame.icons then
                for _, iconFrame in ipairs(rowFrame.icons) do
                    if iconFrame.spellID == spellID then
                        found = true
                        print("  isCoreRotation: " .. tostring(iconFrame.isCoreRotation or false))
                        
                        local isUsable, noMana = icons:IsSpellUsable(spellID)
                        print("  IsSpellUsable: " .. tostring(isUsable) .. ", noMana: " .. tostring(noMana))
                        print("  inCombat: " .. tostring(UnitAffectingCombat("player")))
                        
                        if iconFrame.icon then
                            print("  icon:IsDesaturated: " .. tostring(iconFrame.icon:IsDesaturated()))
                            print("  icon:GetAlpha: " .. string.format("%.2f", iconFrame:GetAlpha()))
                        end
                        
                        if iconFrame.spellData and iconFrame.spellData.tags then
                            print("  Tags: " .. table.concat(iconFrame.spellData.tags, ", "))
                        end
                    end
                end
            end
        end
        if not found then
            print("  Icon not found in HUD")
        end
    end
end

function SlashCommands:DebugUsable(query)
    if not query then
        addon.Utils:Print("Usage: /vh usable <spellID or name>")
        return
    end
    
    local spellID = tonumber(query)
    local spellName
    
    if spellID then
        spellName = GetSpellInfo(spellID)
    else
        spellName = query
    end
    
    print("|cff00ff00IsUsableSpell Debug:|r")
    
    if spellID and IsUsableSpell then
        local usableByID, noManaByID = IsUsableSpell(spellID)
        print(string.format("  By ID (%d): usable=%s, noMana=%s", 
            spellID, tostring(usableByID), tostring(noManaByID)))
    end
    
    if spellName and IsUsableSpell then
        local usableByName, noManaByName = IsUsableSpell(spellName)
        print(string.format("  By Name (%s): usable=%s, noMana=%s", 
            spellName, tostring(usableByName), tostring(noManaByName)))
    end
    
    if spellID and C_Spell and C_Spell.IsSpellUsable then
        local usableC, noManaC = C_Spell.IsSpellUsable(spellID)
        print(string.format("  C_Spell.IsSpellUsable(%d): usable=%s, noMana=%s", 
            spellID, tostring(usableC), tostring(noManaC)))
    end
    
    if UnitExists("target") then
        local hp = UnitHealth("target")
        local maxHp = UnitHealthMax("target")
        local pct = maxHp > 0 and (hp / maxHp * 100) or 0
        print(string.format("  Target health: %.1f%%", pct))
    else
        print("  No target")
    end
end

function SlashCommands:DebugOverlay(spellIDStr)
    local spellID = spellIDStr and tonumber(spellIDStr)
    if not spellID then
        addon.Utils:Print("Usage: /vh overlay <spellID>")
        return
    end
    
    local name = GetSpellInfo(spellID) or "Unknown"
    print("|cff00ff00Overlay Debug:|r " .. name .. " (" .. spellID .. ")")
    
    if IsSpellOverlayed then
        local overlayed = IsSpellOverlayed(spellID)
        print("  IsSpellOverlayed API: " .. tostring(overlayed))
    else
        print("  IsSpellOverlayed API: |cffff0000not available|r")
    end
    
    local icons = addon:GetModule("CooldownIcons")
    if icons and icons.activeOverlays then
        local tracked = icons.activeOverlays[spellID]
        print("  Event-tracked overlay: " .. tostring(tracked or false))
    end
    
    if icons then
        local result = icons:HasSpellActivationOverlay(spellID)
        print("  HasSpellActivationOverlay: " .. tostring(result))
    end
    
    if icons and icons.rows then
        for _, rowFrame in ipairs(icons.rows) do
            if rowFrame.icons then
                for _, iconFrame in ipairs(rowFrame.icons) do
                    if iconFrame.spellID == spellID then
                        if iconFrame.spellData and iconFrame.spellData.tags then
                            print("  Tags: " .. table.concat(iconFrame.spellData.tags, ", "))
                        end
                    end
                end
            end
        end
    end
end

function SlashCommands:CheckSpell(spellIDStr)
    local spellID = spellIDStr and tonumber(spellIDStr)
    if not spellID then
        addon.Utils:Print("Usage: /vh check <spellID>")
        return
    end
    
    local name = GetSpellInfo(spellID) or "Unknown"
    print("|cff00ff00Spell Check:|r " .. name .. " (" .. spellID .. ")")
    
    local LibSpellDB = addon.LibSpellDB
    local spellData = LibSpellDB and LibSpellDB:GetSpellInfo(spellID)
    if spellData then
        print("  In LibSpellDB: |cff00ff00yes|r")
        print("    Class: " .. (spellData.class or "unknown"))
        print("    Tags: " .. (spellData.tags and table.concat(spellData.tags, ", ") or "none"))
        print("    Specs: " .. (spellData.specs and table.concat(spellData.specs, ", ") or "all"))
        print("    Talent: " .. tostring(spellData.talent or false))
    else
        print("  In LibSpellDB: |cffff0000no|r (spell not in database)")
    end
    
    local playerSpec = LibSpellDB and LibSpellDB:GetPlayerSpec()
    print("  Detected spec: " .. (playerSpec or "unknown"))
    
    if LibSpellDB and LibSpellDB.IsSpellRelevantForSpec then
        local relevant = LibSpellDB:IsSpellRelevantForSpec(spellID)
        print("  Relevant for spec: " .. tostring(relevant))
    end
    
    local tracker = addon:GetModule("SpellTracker")
    if tracker then
        local known = tracker:IsSpellKnown(spellID, spellData or {})
        print("  IsSpellKnown: " .. tostring(known))
        
        local isTracked = tracker:IsSpellTracked(spellID)
        print("  IsTracked: " .. tostring(isTracked))
        
        local enabledTags = tracker:GetEnabledTags()
        local matchingTags = {}
        if spellData and spellData.tags then
            for _, tag in ipairs(spellData.tags) do
                if enabledTags[tag] then
                    table.insert(matchingTags, tag)
                end
            end
        end
        if #matchingTags > 0 then
            print("  Matching row tags: " .. table.concat(matchingTags, ", "))
        else
            print("  Matching row tags: |cffff0000none|r (not in any enabled row)")
        end
        
        if spellData and tracker.ShouldExcludeSpell then
            local excluded = tracker:ShouldExcludeSpell(spellData)
            print("  ShouldExclude: " .. tostring(excluded))
        end
    end
end
