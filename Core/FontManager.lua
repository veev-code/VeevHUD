--[[
    VeevHUD - Font Manager
    Handles font registration with LibSharedMedia and provides font utilities
]]

local ADDON_NAME, addon = ...

local FontManager = {}
addon.FontManager = FontManager

-- Reference to LibSharedMedia (set during initialization)
FontManager.LSM = nil

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function FontManager:Initialize()
    -- Get LibSharedMedia reference (optional - for custom fonts)
    if LibStub then
        self.LSM = LibStub:GetLibrary("LibSharedMedia-3.0", true)
        if self.LSM then
            -- Only register our bundled font if the name isn't already taken
            -- (avoids duplicates if another addon provides Expressway)
            if not self.LSM:IsValid("font", addon.Constants.BUNDLED_FONT_NAME) then
                self.LSM:Register("font", addon.Constants.BUNDLED_FONT_NAME, addon.Constants.BUNDLED_FONT)
                addon.Utils:Debug("FontManager: Registered", addon.Constants.BUNDLED_FONT_NAME, "with LibSharedMedia")
            else
                addon.Utils:Debug("FontManager:", addon.Constants.BUNDLED_FONT_NAME, "already registered in LibSharedMedia")
            end
        else
            addon.Utils:Debug("FontManager: LibSharedMedia not available, using bundled font only")
        end
    end
end

-------------------------------------------------------------------------------
-- Font Utilities
-------------------------------------------------------------------------------

-- Returns the font path for the currently configured font
-- Uses LibSharedMedia if available, falls back to bundled font otherwise
function FontManager:GetFont()
    local fontName = addon.db and addon.db.profile.appearance and addon.db.profile.appearance.font
    fontName = fontName or addon.Constants.BUNDLED_FONT_NAME
    
    -- Try to get font from LibSharedMedia (includes built-in WoW fonts)
    if self.LSM then
        local fontPath = self.LSM:Fetch("font", fontName)
        if fontPath then
            return fontPath
        end
    end
    
    -- Fallback to bundled font
    return addon.Constants.BUNDLED_FONT
end

-- Returns a sorted list of available font names
-- With LSM: includes built-in WoW fonts + custom fonts from other addons
-- Without LSM: only our bundled font
function FontManager:GetFontList()
    local fonts = {}
    
    if self.LSM then
        local list = self.LSM:List("font")
        if list then
            for _, name in ipairs(list) do
                table.insert(fonts, name)
            end
        end
    else
        -- No LSM - only our bundled font is available
        table.insert(fonts, addon.Constants.BUNDLED_FONT_NAME)
    end
    
    return fonts
end

-- Returns the font path for a specific font name
function FontManager:GetFontPath(fontName)
    if self.LSM then
        local path = self.LSM:Fetch("font", fontName)
        if path then
            return path
        end
    end
    
    -- Fallback to bundled font
    return addon.Constants.BUNDLED_FONT
end

-- Check if LibSharedMedia is available
function FontManager:HasLSM()
    return self.LSM ~= nil
end

-------------------------------------------------------------------------------
-- Font Refresh (called when font setting changes)
-------------------------------------------------------------------------------

-- Refresh fonts on all modules that use text
function FontManager:RefreshAllFonts()
    local fontPath = self:GetFont()
    
    -- Refresh bar modules (they already handle font in their Refresh methods)
    local healthBar = addon:GetModule("HealthBar")
    if healthBar and healthBar.Refresh then
        healthBar:Refresh()
    end
    
    local resourceBar = addon:GetModule("ResourceBar")
    if resourceBar and resourceBar.Refresh then
        resourceBar:Refresh()
    end
    
    -- Refresh icon-based modules
    local cooldownIcons = addon:GetModule("CooldownIcons")
    if cooldownIcons and cooldownIcons.RefreshFonts then
        cooldownIcons:RefreshFonts(fontPath)
    end
    
    local procTracker = addon:GetModule("ProcTracker")
    if procTracker and procTracker.RefreshFonts then
        procTracker:RefreshFonts(fontPath)
    end
end

-------------------------------------------------------------------------------
-- Convenience wrapper for addon-level access
-------------------------------------------------------------------------------

-- Allow addon:GetFont() as a shortcut
function addon:GetFont()
    return self.FontManager:GetFont()
end
