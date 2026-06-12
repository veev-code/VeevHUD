--[[
    VeevHUD - Event Handling System
]]

local _, addon = ...

-- Localized WoW API functions (hot path)
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo

addon.Events = {}
local Events = addon.Events

-- Event frame
local eventFrame = CreateFrame("Frame")

-- Registered callbacks: eventName -> { [owner] = callback }
local callbacks = {}

-------------------------------------------------------------------------------
-- Event Registration
--
-- CALLBACK CONTRACT: callbacks are invoked as callback(owner, event, ...).
-- Method references (self.OnFoo) absorb `owner` as their implicit self;
-- anonymous closures MUST declare a leading owner parameter.
-------------------------------------------------------------------------------

function Events:RegisterEvent(owner, eventName, callback)
    if not callbacks[eventName] then
        callbacks[eventName] = {}
        eventFrame:RegisterEvent(eventName)
    end

    callbacks[eventName][owner] = callback
end

function Events:UnregisterEvent(owner, eventName)
    if callbacks[eventName] then
        callbacks[eventName][owner] = nil

        -- Unregister from frame if no more callbacks
        local hasCallbacks = false
        for _ in pairs(callbacks[eventName]) do
            hasCallbacks = true
            break
        end

        if not hasCallbacks then
            eventFrame:UnregisterEvent(eventName)
            callbacks[eventName] = nil
        end
    end
end

-------------------------------------------------------------------------------
-- Combat Log Event Handling (CLEU)
-------------------------------------------------------------------------------

local cleuCallbacks = {}
local cleuRegistered = false
-- Reusable table for CLEU event data (avoids allocation per event)
local cleuEventData = {}

-- CLEU prefix → position of the first suffix argument.
-- Base fields are 1-11. SWING has no prefix params; SPELL_*/RANGE_* add
-- spellID/spellName/spellSchool (12-14); ENVIRONMENTAL adds environmentalType (12).
local CLEU_SUFFIX_START = setmetatable({}, { __index = function(t, subEvent)
    local start
    if subEvent:find("^SWING_") then
        start = 12
    elseif subEvent:find("^ENVIRONMENTAL_") then
        start = 13
    else
        start = 15 -- SPELL_*, SPELL_PERIODIC_*, SPELL_BUILDING_*, RANGE_*
    end
    rawset(t, subEvent, start)
    return start
end })

function Events:RegisterCLEU(owner, subEvent, callback)
    if not cleuCallbacks[subEvent] then
        cleuCallbacks[subEvent] = {}
    end

    cleuCallbacks[subEvent][owner] = callback

    -- Register CLEU if first callback
    if not cleuRegistered then
        eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        cleuRegistered = true
    end
end

-- Event handler includes CLEU dispatch
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subEvent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
              destGUID, destName, destFlags, destRaidFlags, spellID, spellName, spellSchool = CombatLogGetCurrentEventInfo()

        if cleuCallbacks[subEvent] then
            -- Reuse table to avoid per-event allocation
            cleuEventData.timestamp = timestamp
            cleuEventData.sourceGUID = sourceGUID
            cleuEventData.sourceName = sourceName
            cleuEventData.sourceFlags = sourceFlags
            cleuEventData.destGUID = destGUID
            cleuEventData.destName = destName
            cleuEventData.destFlags = destFlags
            cleuEventData.spellID = spellID
            cleuEventData.spellName = spellName
            cleuEventData.spellSchool = spellSchool

            -- Suffix arguments, aligned to the sub-event's suffix start so
            -- handlers never hand-count absolute CLEU positions. Meaning is
            -- suffix-specific, e.g.:
            --   SWING_DAMAGE:        s1=amount .. s10=isOffHand
            --   SWING_MISSED:        s1=missType, s2=isOffHand
            --   SPELL_MISSED:        s1=missType
            --   SPELL_EXTRA_ATTACKS: s1=amount
            --   SPELL_ENERGIZE:      s1=amount, s2=overEnergize, s3=powerType
            cleuEventData.s1, cleuEventData.s2, cleuEventData.s3, cleuEventData.s4,
            cleuEventData.s5, cleuEventData.s6, cleuEventData.s7, cleuEventData.s8,
            cleuEventData.s9, cleuEventData.s10 = select(CLEU_SUFFIX_START[subEvent], CombatLogGetCurrentEventInfo())

            for owner, callback in pairs(cleuCallbacks[subEvent]) do
                local success, err = pcall(callback, owner, subEvent, cleuEventData)
                if not success then
                    addon.Utils:Debug("CLEU error [" .. subEvent .. "]: " .. tostring(err))
                end
            end
        end
    elseif callbacks[event] then
        for owner, callback in pairs(callbacks[event]) do
            local success, err = pcall(callback, owner, event, ...)
            if not success then
                addon.Utils:Debug("Event error [" .. event .. "]: " .. tostring(err))
            end
        end
    end
end)

-------------------------------------------------------------------------------
-- Addon Event Bus (internal module-to-module communication)
-------------------------------------------------------------------------------

local addonCallbacks = {} -- eventName -> { {owner, callback}, ... }

function Events:RegisterAddonEvent(owner, eventName, callback)
    if not addonCallbacks[eventName] then
        addonCallbacks[eventName] = {}
    end
    -- Replace any existing registration for this owner — prevents double-fire
    -- if a module re-registers across Refresh/lifecycle cycles
    for _, entry in ipairs(addonCallbacks[eventName]) do
        if entry.owner == owner then
            entry.callback = callback
            return
        end
    end
    table.insert(addonCallbacks[eventName], { owner = owner, callback = callback })
end

function Events:FireAddonEvent(eventName, ...)
    local cbs = addonCallbacks[eventName]
    if not cbs then return end
    for _, entry in ipairs(cbs) do
        local ok, err = pcall(entry.callback, entry.owner, eventName, ...)
        if not ok then
            addon.Utils:LogError("Addon event error [" .. eventName .. "]:", tostring(err))
        end
    end
end

-------------------------------------------------------------------------------
-- Update Ticker System
-------------------------------------------------------------------------------

local updateCallbacks = {}

function Events:RegisterUpdate(owner, interval, callback)
    -- Cancel existing ticker for this owner
    if updateCallbacks[owner] and updateCallbacks[owner].ticker then
        updateCallbacks[owner].ticker:Cancel()
    end

    updateCallbacks[owner] = {
        interval = interval,
        callback = callback,
        ticker = C_Timer.NewTicker(interval, function()
            local success, err = pcall(callback, owner)
            if not success then
                addon.Utils:LogError("Update error:", tostring(err))
            end
        end),
    }
end

function Events:UnregisterUpdate(owner)
    if updateCallbacks[owner] then
        if updateCallbacks[owner].ticker then
            updateCallbacks[owner].ticker:Cancel()
        end
        updateCallbacks[owner] = nil
    end
end
