--[[
    VeevHUD - Configuration System
    Placeholder for future AceConfig integration
]]

local ADDON_NAME, addon = ...

addon.Config = {}
local Config = addon.Config

-------------------------------------------------------------------------------
-- Configuration Panel (Basic)
-------------------------------------------------------------------------------

-- Will be expanded with AceConfig-3.0 in the future
-- For now, provides programmatic access to settings

function Config:Get(key)
    local db = addon.db.profile
    local keys = {strsplit(".", key)}

    local value = db
    for _, k in ipairs(keys) do
        if type(value) == "table" then
            value = value[k]
        else
            return nil
        end
    end

    return value
end

function Config:Set(key, value)
    local db = addon.db.profile
    local keys = {strsplit(".", key)}

    local target = db
    for i = 1, #keys - 1 do
        if type(target[keys[i]]) ~= "table" then
            target[keys[i]] = {}
        end
        target = target[keys[i]]
    end

    target[keys[#keys]] = value

    -- Notify modules of config change
    addon:OnConfigChanged(key, value)
end

-------------------------------------------------------------------------------
-- Config Change Notifications
-------------------------------------------------------------------------------

function addon:OnConfigChanged(key, value)
    -- Refresh relevant modules based on what changed
    local prefix = strsplit(".", key)

    for name, module in pairs(self.modules) do
        if module.OnConfigChanged then
            module:OnConfigChanged(key, value)
        end
    end
end

-------------------------------------------------------------------------------
-- Spell Overrides Management
-------------------------------------------------------------------------------

function Config:AddSpellOverride(spellID, enabled, position)
    local overrides = addon.db.profile.cooldownIcons.spellOverrides
    overrides[spellID] = {
        enabled = enabled,
        position = position,
    }
end

function Config:RemoveSpellOverride(spellID)
    addon.db.profile.cooldownIcons.spellOverrides[spellID] = nil
end

function Config:GetSpellOverride(spellID)
    return addon.db.profile.cooldownIcons.spellOverrides[spellID]
end

function Config:IsSpellEnabled(spellID)
    local override = self:GetSpellOverride(spellID)
    if override then
        return override.enabled
    end
    -- Default: enabled if in tracked categories
    return true
end
