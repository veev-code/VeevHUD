--[[
    VeevHUD - Event Handling System
]]

local ADDON_NAME, addon = ...

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

function Events:UnregisterAllEvents(owner)
    for eventName, owners in pairs(callbacks) do
        if owners[owner] then
            self:UnregisterEvent(owner, eventName)
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

function Events:UnregisterCLEU(owner, subEvent)
    if cleuCallbacks[subEvent] then
        cleuCallbacks[subEvent][owner] = nil

        local hasCallbacks = false
        for _ in pairs(cleuCallbacks[subEvent]) do
            hasCallbacks = true
            break
        end

        if not hasCallbacks then
            cleuCallbacks[subEvent] = nil
        end
    end

    -- Check if any CLEU callbacks remain
    local anyCallbacks = false
    for _ in pairs(cleuCallbacks) do
        anyCallbacks = true
        break
    end

    if not anyCallbacks and cleuRegistered then
        eventFrame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        cleuRegistered = false
    end
end

-- Override the event handler to include CLEU dispatch
local originalOnEvent = eventFrame:GetScript("OnEvent")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subEvent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
              destGUID, destName, destFlags, destRaidFlags = CombatLogGetCurrentEventInfo()

        if cleuCallbacks[subEvent] then
            -- Get additional args based on sub-event
            local _, _, _, _, _, _, _, _, _, _, _, spellID, spellName, spellSchool = CombatLogGetCurrentEventInfo()

            for owner, callback in pairs(cleuCallbacks[subEvent]) do
                local success, err = pcall(callback, owner, subEvent, {
                    timestamp = timestamp,
                    sourceGUID = sourceGUID,
                    sourceName = sourceName,
                    sourceFlags = sourceFlags,
                    destGUID = destGUID,
                    destName = destName,
                    destFlags = destFlags,
                    spellID = spellID,
                    spellName = spellName,
                    spellSchool = spellSchool,
                })
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
-- Update Ticker System
-------------------------------------------------------------------------------

local updateCallbacks = {}
local updateTicker = nil

function Events:RegisterUpdate(owner, interval, callback)
    updateCallbacks[owner] = {
        interval = interval,
        callback = callback,
        elapsed = 0,
    }

    -- Start ticker if not running
    if not updateTicker then
        updateTicker = C_Timer.NewTicker(0.01, function()
            local now = GetTime()
            for owner, data in pairs(updateCallbacks) do
                data.elapsed = data.elapsed + 0.01
                if data.elapsed >= data.interval then
                    data.elapsed = 0
                    local success, err = pcall(data.callback, owner)
                    if not success then
                        addon.Utils:Debug("Update error: " .. tostring(err))
                    end
                end
            end
        end)
    end
end

function Events:UnregisterUpdate(owner)
    updateCallbacks[owner] = nil

    -- Stop ticker if no callbacks
    local hasCallbacks = false
    for _ in pairs(updateCallbacks) do
        hasCallbacks = true
        break
    end

    if not hasCallbacks and updateTicker then
        updateTicker:Cancel()
        updateTicker = nil
    end
end
