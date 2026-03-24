--[[
    VeevHUD - Sound Manager
    Handles sound playback via LibSharedMedia
]]

local _, addon = ...

local GetTime = GetTime

local SoundManager = {}
addon.SoundManager = SoundManager

SoundManager.lastPlayTimes = {}
SoundManager.inLoadingScreen = false

local DEBOUNCE_INTERVAL = 0.1

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function SoundManager:Initialize()
    if LibStub then
        self.LSM = LibStub:GetLibrary("LibSharedMedia-3.0", true)
        if self.LSM then
            addon.Utils:Debug("SoundManager: LibSharedMedia available for sound playback")
        else
            addon.Utils:Debug("SoundManager: LibSharedMedia not available, sound disabled")
        end
    end

    addon.Events:RegisterEvent(self, "LOADING_SCREEN_ENABLED", function()
        self.inLoadingScreen = true
    end)
    addon.Events:RegisterEvent(self, "LOADING_SCREEN_DISABLED", function()
        self.inLoadingScreen = false
    end)

    -- Re-register persisted Sound Kit IDs with LSM
    local saved = addon.db and addon.db.profile and addon.db.profile.sound.registeredKitIDs
    if saved and self.LSM then
        for kitID in pairs(saved) do
            self:RegisterSoundKitID(kitID, true)
        end
    end
end

-------------------------------------------------------------------------------
-- Sound Kit ID Registration
-------------------------------------------------------------------------------

function SoundManager:RegisterSoundKitID(kitID, skipPersist)
    kitID = tonumber(kitID)
    if not kitID or not self.LSM then return nil end

    local name = "!Kit " .. kitID
    if not self.LSM:IsValid("sound", name) then
        self.LSM:Register("sound", name, kitID)
    end

    if not skipPersist and addon.db then
        addon.db.profile.sound.registeredKitIDs[kitID] = true
    end

    return name
end

-------------------------------------------------------------------------------
-- Playback
-------------------------------------------------------------------------------

function SoundManager:PlaySound(soundName)
    if not soundName or soundName == "None" or soundName == "" then return end
    if not self.LSM then return end

    if self.inLoadingScreen then return end

    local now = GetTime()
    local lastTime = self.lastPlayTimes[soundName]
    if lastTime and now - lastTime < DEBOUNCE_INTERVAL then return end

    local path = self.LSM:Fetch("sound", soundName)
    if path then
        local channel = addon.db.profile.sound.channel
        if type(path) == "number" then
            -- Sound Kit ID (registered via RegisterSoundKitID or by other addons)
            PlaySound(path, channel)
        else
            PlaySoundFile(path, channel)
        end
        self.lastPlayTimes[soundName] = now
    end
end
