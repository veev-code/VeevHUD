--[[
    VeevHUD - Texture Manager
    Handles statusbar texture registration with LibSharedMedia and provides texture utilities
]]

local ADDON_NAME, addon = ...

local TextureManager = {}
addon.TextureManager = TextureManager

-- Reference to LibSharedMedia (set during initialization)
TextureManager.LSM = nil

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function TextureManager:Initialize()
    -- Get LibSharedMedia reference (optional - for custom textures)
    if LibStub then
        self.LSM = LibStub:GetLibrary("LibSharedMedia-3.0", true)
        if self.LSM then
            -- Only register our bundled texture if the name isn't already taken
            -- (avoids duplicates if another addon provides the same texture)
            if not self.LSM:IsValid("statusbar", addon.Constants.BUNDLED_STATUSBAR_NAME) then
                self.LSM:Register("statusbar", addon.Constants.BUNDLED_STATUSBAR_NAME, addon.Constants.BUNDLED_STATUSBAR)
                addon.Utils:Debug("TextureManager: Registered", addon.Constants.BUNDLED_STATUSBAR_NAME, "with LibSharedMedia")
            else
                addon.Utils:Debug("TextureManager:", addon.Constants.BUNDLED_STATUSBAR_NAME, "already registered in LibSharedMedia")
            end
        else
            addon.Utils:Debug("TextureManager: LibSharedMedia not available, using bundled texture only")
        end
    end
end

-------------------------------------------------------------------------------
-- Texture Utilities
-------------------------------------------------------------------------------

-- Returns the texture path for the currently configured statusbar texture
-- Uses LibSharedMedia if available, falls back to bundled texture otherwise
function TextureManager:GetTexture()
    local textureName = addon.db and addon.db.profile.appearance and addon.db.profile.appearance.statusbarTexture
    textureName = textureName or addon.Constants.BUNDLED_STATUSBAR_NAME

    -- Try to get texture from LibSharedMedia (includes built-in WoW textures)
    if self.LSM then
        local texturePath = self.LSM:Fetch("statusbar", textureName)
        if texturePath then
            return texturePath
        end
    end

    -- Fallback to bundled texture
    return addon.Constants.BUNDLED_STATUSBAR
end

-- Returns a sorted list of available statusbar texture names
-- With LSM: includes built-in WoW textures + custom textures from other addons
-- Without LSM: only our bundled texture
function TextureManager:GetTextureList()
    local textures = {}

    if self.LSM then
        local list = self.LSM:List("statusbar")
        if list then
            for _, name in ipairs(list) do
                table.insert(textures, name)
            end
        end
    else
        -- No LSM - only our bundled texture is available
        table.insert(textures, addon.Constants.BUNDLED_STATUSBAR_NAME)
    end

    return textures
end

-- Returns the texture path for a specific texture name
function TextureManager:GetTexturePath(textureName)
    if self.LSM then
        local path = self.LSM:Fetch("statusbar", textureName)
        if path then
            return path
        end
    end

    -- Fallback to bundled texture
    return addon.Constants.BUNDLED_STATUSBAR
end

-- Check if LibSharedMedia is available
function TextureManager:HasLSM()
    return self.LSM ~= nil
end

-------------------------------------------------------------------------------
-- Texture Refresh (called when texture setting changes)
-------------------------------------------------------------------------------

-- Refresh textures on all modules that use status bars
function TextureManager:RefreshAllTextures()
    local texturePath = self:GetTexture()

    -- Refresh bar modules (they handle texture in their Refresh methods)
    local healthBar = addon:GetModule("HealthBar")
    if healthBar and healthBar.Refresh then
        healthBar:Refresh()
    end

    local resourceBar = addon:GetModule("ResourceBar")
    if resourceBar and resourceBar.Refresh then
        resourceBar:Refresh()
    end

    local comboPoints = addon:GetModule("ComboPoints")
    if comboPoints and comboPoints.Refresh then
        comboPoints:Refresh()
    end
end

-------------------------------------------------------------------------------
-- Convenience wrapper for addon-level access
-------------------------------------------------------------------------------

-- Allow addon:GetBarTexture() as a shortcut
function addon:GetBarTexture()
    return self.TextureManager:GetTexture()
end
