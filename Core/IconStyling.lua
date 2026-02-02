--[[
    VeevHUD - Icon Styling
    Built-in icon styling when Masque is not installed
    Uses the same textures as Masque's "Classic Enhanced" skin
]]

local ADDON_NAME, addon = ...

addon.IconStyling = {}
local IconStyling = addon.IconStyling

-------------------------------------------------------------------------------
-- Classic Enhanced Skin Constants
-------------------------------------------------------------------------------

-- Classic Enhanced skin texture paths (built into WoW client)
-- Tweaked for a more subtle appearance while maintaining proper proportions
local CLASSIC_ENHANCED = {
    Normal = [[Interface\Buttons\UI-Quickslot2]],      -- The action button border frame
    Backdrop = [[Interface\Buttons\UI-Quickslot]],     -- Empty slot background
    IconTexCoords = {0.07, 0.93, 0.07, 0.93},          -- Icon crop (7% from each edge)
    NormalSize = 62,                                    -- Border texture size (must be larger than icon to frame it)
    BackdropSize = 64,                                  -- Backdrop texture size
    NormalOffset = {0.5, -0.5},                         -- Border offset {x, y}
    BackdropAlpha = 0.4,                                -- Subtle backdrop visibility
    NormalAlpha = 0.8,                                  -- Slightly softer border
}

-------------------------------------------------------------------------------
-- Apply Built-in Style
-------------------------------------------------------------------------------

-- Apply built-in styling to an icon frame (when Masque is not installed)
-- frame: the icon button frame
-- size: base icon size
function IconStyling:Apply(frame, size)
    local Utils = addon.Utils
    local iconDb = addon.db.profile.icons
    
    size = size or frame.iconSize or iconDb.iconSize
    
    -- Get actual icon dimensions (may be non-square with aspect ratio)
    local iconWidth, iconHeight = Utils:GetIconDimensions(size)
    
    -- Calculate scale factors for width and height separately
    local scaleW = iconWidth / 36
    local scaleH = iconHeight / 36
    
    -- Apply icon TexCoords with configured zoom, adjusted for aspect ratio cropping
    -- iconZoom is total crop percentage; divide by 2 to get per-edge crop
    if frame.icon then
        local zoomPerEdge = iconDb.iconZoom / 2
        local left, right, top, bottom = Utils:GetIconTexCoords(zoomPerEdge)
        frame.icon:SetTexCoord(left, right, top, bottom)
    end
    
    -- Create backdrop (empty slot background) - sits behind everything
    if not frame.builtInBackdrop then
        local backdrop = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
        backdrop:SetTexture(CLASSIC_ENHANCED.Backdrop)
        frame.builtInBackdrop = backdrop
    end
    
    -- Apply subtle backdrop styling
    frame.builtInBackdrop:SetVertexColor(1, 1, 1, CLASSIC_ENHANCED.BackdropAlpha)
    
    -- Size and position backdrop (non-square for aspect ratio)
    local backdropWidth = CLASSIC_ENHANCED.BackdropSize * scaleW
    local backdropHeight = CLASSIC_ENHANCED.BackdropSize * scaleH
    frame.builtInBackdrop:SetSize(backdropWidth, backdropHeight)
    frame.builtInBackdrop:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.builtInBackdrop:Show()
    
    -- Create normal border (the classic action button frame)
    if not frame.builtInNormal then
        local normal = frame:CreateTexture(nil, "OVERLAY", nil, 1)
        normal:SetTexture(CLASSIC_ENHANCED.Normal)
        frame.builtInNormal = normal
    end
    
    -- Apply subtle border styling
    frame.builtInNormal:SetVertexColor(1, 1, 1, CLASSIC_ENHANCED.NormalAlpha)
    
    -- Size and position border (non-square for aspect ratio)
    local normalWidth = CLASSIC_ENHANCED.NormalSize * scaleW
    local normalHeight = CLASSIC_ENHANCED.NormalSize * scaleH
    local offsetX, offsetY = CLASSIC_ENHANCED.NormalOffset[1], CLASSIC_ENHANCED.NormalOffset[2]
    frame.builtInNormal:SetSize(normalWidth, normalHeight)
    frame.builtInNormal:SetPoint("CENTER", frame, "CENTER", offsetX, offsetY)
    frame.builtInNormal:Show()
    
    -- Store that we applied built-in style
    frame.hasBuiltInStyle = true
end

-------------------------------------------------------------------------------
-- Update Built-in Style
-------------------------------------------------------------------------------

-- Update built-in style when icon size changes
-- frame: the icon button frame
-- size: new base icon size
-- hasMasque: whether Masque is handling styling (skip if true)
function IconStyling:Update(frame, size, hasMasque)
    if frame.hasBuiltInStyle then
        local Utils = addon.Utils
        local iconDb = addon.db.profile.icons
        
        -- Recalculate sizes based on new icon size and aspect ratio
        size = size or frame.iconSize or iconDb.iconSize
        local iconWidth, iconHeight = Utils:GetIconDimensions(size)
        local scaleW = iconWidth / 36
        local scaleH = iconHeight / 36
        
        if frame.builtInBackdrop then
            local backdropWidth = CLASSIC_ENHANCED.BackdropSize * scaleW
            local backdropHeight = CLASSIC_ENHANCED.BackdropSize * scaleH
            frame.builtInBackdrop:SetSize(backdropWidth, backdropHeight)
        end
        
        if frame.builtInNormal then
            local normalWidth = CLASSIC_ENHANCED.NormalSize * scaleW
            local normalHeight = CLASSIC_ENHANCED.NormalSize * scaleH
            frame.builtInNormal:SetSize(normalWidth, normalHeight)
        end
    elseif not hasMasque then
        self:Apply(frame, size)
    end
end
