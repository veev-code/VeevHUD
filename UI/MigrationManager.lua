--[[
    VeevHUD - Migration Manager
    
    Reusable system for showing one-time migration notices when addon behavior changes.
    Each migration defines: id, check function, title, message, and buttons.
    Migrations are shown in registration order, one at a time.
    
    Usage:
        addon.MigrationManager:Register({
            id = "unique_migration_id",
            check = function() return shouldShow, extraData end,
            title = "What Changed",
            message = "Explanation of the change...",
            -- Optional: dynamic message based on check() extraData
            getMessage = function(extraData) return "Dynamic message" end,
            buttons = {
                { text = "Do Something", action = function(extraData) ... end },
                { text = "Dismiss", action = nil },  -- nil action = just close
            }
        })
]]

local ADDON_NAME, addon = ...

addon.MigrationManager = {}
local MigrationManager = addon.MigrationManager

-- Registered migrations (in order)
local migrations = {}

-------------------------------------------------------------------------------
-- Registration
-------------------------------------------------------------------------------

function MigrationManager:Register(config)
    if not config.id then
        addon.Utils:LogError("MigrationManager: Migration missing 'id'")
        return
    end
    table.insert(migrations, config)
end

-------------------------------------------------------------------------------
-- Dialog Creation
-------------------------------------------------------------------------------

function MigrationManager:CreateDialog()
    if self.dialog then return self.dialog end
    
    local dialog = CreateFrame("Frame", "VeevHUDMigrationDialog", UIParent, "BasicFrameTemplateWithInset")
    dialog:SetSize(460, 280)
    -- Position ~30% down from top (instead of center) to avoid hiding the HUD
    dialog:SetPoint("CENTER", UIParent, "CENTER", 0, UIParent:GetHeight() * 0.20)
    dialog:SetFrameStrata("DIALOG")
    dialog:SetMovable(true)
    dialog:EnableMouse(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
    dialog:Hide()
    
    -- Title (centered in the title bar area)
    local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -6)
    dialog.titleText = title
    
    -- Message text
    local message = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    message:SetPoint("TOP", title, "BOTTOM", 0, -12)
    message:SetWidth(420)
    message:SetJustifyH("CENTER")
    message:SetSpacing(2)
    dialog.messageText = message
    
    -- Extra info text (for dynamic content like current values)
    local extraInfo = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    extraInfo:SetPoint("TOP", message, "BOTTOM", 0, -8)
    extraInfo:SetWidth(420)
    extraInfo:SetJustifyH("CENTER")
    extraInfo:SetTextColor(0.7, 0.7, 0.7)
    dialog.extraInfoText = extraInfo
    
    -- Button container (buttons are created dynamically)
    dialog.buttons = {}
    
    self.dialog = dialog
    return dialog
end

-- Configure dialog for a specific migration
function MigrationManager:ConfigureDialog(migration, extraData)
    local dialog = self:CreateDialog()
    
    -- Set title
    dialog.titleText:SetText("|cff00ccffVeevHUD|r - " .. (migration.title or "Update"))
    
    -- Set message (static or dynamic)
    local message = migration.message or ""
    if migration.getMessage then
        message = migration.getMessage(extraData) or message
    end
    dialog.messageText:SetText(message)
    
    -- Set extra info (optional)
    local extraInfo = ""
    if migration.getExtraInfo then
        extraInfo = migration.getExtraInfo(extraData) or ""
    end
    dialog.extraInfoText:SetText(extraInfo)
    
    -- Clear old buttons
    for _, btn in ipairs(dialog.buttons) do
        btn:Hide()
        btn:SetParent(nil)
    end
    wipe(dialog.buttons)
    
    -- Create new buttons
    local buttonConfigs = migration.buttons or {{ text = "OK", action = nil }}
    local numButtons = #buttonConfigs
    local buttonWidth = 160
    local buttonSpacing = 20
    local totalWidth = (buttonWidth * numButtons) + (buttonSpacing * (numButtons - 1))
    local startX = -totalWidth / 2 + buttonWidth / 2
    
    for i, btnConfig in ipairs(buttonConfigs) do
        local btn = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        btn:SetSize(buttonWidth, 26)
        btn:SetPoint("BOTTOM", startX + (i - 1) * (buttonWidth + buttonSpacing), 16)
        btn:SetText(btnConfig.text or "OK")
        
        btn:SetScript("OnClick", function()
            -- Mark migration as shown
            VeevHUDDB.migrationsShown = VeevHUDDB.migrationsShown or {}
            VeevHUDDB.migrationsShown[migration.id] = true
            
            -- Execute action if provided
            if btnConfig.action then
                btnConfig.action(extraData)
            end
            
            dialog:Hide()
            
            -- Show next migration if any
            self:ShowNext()
        end)
        
        table.insert(dialog.buttons, btn)
    end
    
    -- Handle X button close
    dialog:SetScript("OnHide", function()
        VeevHUDDB.migrationsShown = VeevHUDDB.migrationsShown or {}
        VeevHUDDB.migrationsShown[migration.id] = true
    end)
    
    return dialog
end

-------------------------------------------------------------------------------
-- Show Logic
-------------------------------------------------------------------------------

-- Find and show the next applicable migration
function MigrationManager:ShowNext()
    VeevHUDDB.migrationsShown = VeevHUDDB.migrationsShown or {}
    
    for _, migration in ipairs(migrations) do
        -- Skip if already shown
        if not VeevHUDDB.migrationsShown[migration.id] then
            -- Check if this migration applies
            local shouldShow, extraData = false, nil
            if migration.check then
                shouldShow, extraData = migration.check()
            end
            
            if shouldShow then
                local dialog = self:ConfigureDialog(migration, extraData)
                dialog:Show()
                return true
            else
                -- Migration doesn't apply, mark as shown so we don't check again
                VeevHUDDB.migrationsShown[migration.id] = true
            end
        end
    end
    
    return false
end

-- Entry point: show migrations after a delay
function MigrationManager:Show()
    -- Skip migrations for brand new users (they haven't seen welcome popup yet)
    -- Check this BEFORE the timer since welcomeShown gets set when welcome is dismissed
    if not VeevHUDDB.welcomeShown then
        return
    end
    
    -- Delay to ensure UI is loaded (and after welcome popup)
    C_Timer.After(2, function()
        self:ShowNext()
    end)
end
