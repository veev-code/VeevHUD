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
-- Event Dispatch
-------------------------------------------------------------------------------

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if callbacks[event] then
        for owner, callback in pairs(callbacks[event]) do
            local success, err = pcall(callback, owner, event, ...)
            if not success then
                addon.Utils:Debug("Event error [" .. event .. "]: " .. tostring(err))
            end
        end
    end
end)

-------------------------------------------------------------------------------
-- Combat Log Event Handling (CLEU)
-------------------------------------------------------------------------------

local cleuCallbacks = {}
local cleuRegistered = false
-- Reusable table for CLEU event data (avoids allocation per event)
local cleuEventData = {}

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
