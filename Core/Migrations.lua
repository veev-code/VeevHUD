--[[
    VeevHUD - Migration System

    Consolidated, versioned migration system. Each migration is a numbered
    version with optional data logic and/or popup notification.

    How it works:
      - db.global.dataVersion tracks the last completed migration version.
      - On first encounter (dataVersion == nil), ALL users (new and existing)
        start at CURRENT_VERSION — legacy migrations are skipped.
      - Future migrations are added as sequential version entries.
      - Data migrations (run) always execute. Popups show after a 2s delay.

    Adding a new migration:
      1. Bump CURRENT_VERSION
      2. Add an entry to the migrations table:

         [5] = {
             -- Optional: data migration (always runs, even if popup is skipped)
             run = function(db)
                 -- modify db.profile, db.global, etc.
             end,
             -- Optional: conditional check for the popup
             -- Omit to always show. Return false to skip popup silently.
             check = function(db)
                 return shouldShow, extraData
             end,
             -- Optional: popup notification
             popup = {
                 title = "What Changed",
                 message = "Static explanation...",
                 -- Or dynamic: getMessage = function(extraData) return "..." end,
                 -- Optional: getExtraInfo = function(extraData) return "..." end,
                 buttons = {
                     { text = "Open Settings", action = function(extraData) ... end },
                     { text = "Got It" },
                 },
             },
         },
]]

local ADDON_NAME, addon = ...

addon.Migrations = {}
local Migrations = addon.Migrations

-------------------------------------------------------------------------------
-- Version Registry
-------------------------------------------------------------------------------

-- Bump this when adding new migrations.
-- Versions 1-4 are legacy (pre-dataVersion system). All users start at
-- CURRENT_VERSION on first encounter, so legacy versions never run.
local CURRENT_VERSION = 4

-- Migration definitions, keyed by version number.
-- Versions 1-4 (legacy) are intentionally omitted — they corresponded to:
--   v1: Aura Tracker rename popup
--   v2: UI scale compensation popup
--   v3: Buff Reminders feature popup + per-spec data migration
--   v4: Trinket Tracking feature popup
--
-- Future migrations start at version 5+.
local migrations = {
    -- Example:
    -- [5] = {
    --     run = function(db) ... end,
    --     popup = {
    --         title = "What Changed",
    --         message = "Explanation...",
    --         buttons = {{ text = "Got It" }},
    --     },
    -- },
}

-------------------------------------------------------------------------------
-- Initialization (called from Database:Initialize after AceDB:New)
-------------------------------------------------------------------------------

function Migrations:Initialize()
    local db = addon.db
    if not db or not db.global then return end

    if db.global.dataVersion == nil then
        -- First time on the versioned system (both new and existing users).
        -- All migrations 1-CURRENT_VERSION are legacy — skip them all.
        db.global.dataVersion = CURRENT_VERSION
    end

    self.pendingPopups = {}
end

-------------------------------------------------------------------------------
-- Run Pending Migrations (called from Core:OnPlayerLogin)
-------------------------------------------------------------------------------

function Migrations:Run()
    local db = addon.db
    if not db or not db.global then return end

    -- Skip for brand new users (haven't dismissed welcome popup yet)
    if not db.global.welcomeShown then return end

    local version = db.global.dataVersion
    if version >= CURRENT_VERSION then return end

    -- Run all migrations above current version
    for v = version + 1, CURRENT_VERSION do
        local migration = migrations[v]
        if migration then
            -- Data migration (always runs)
            if migration.run then
                local ok, err = pcall(migration.run, db)
                if not ok then
                    addon.Utils:LogError("Migration v" .. v .. " failed:", err)
                end
            end

            -- Queue popup if applicable
            if migration.popup then
                local shouldShow = true
                local extraData = nil
                if migration.check then
                    shouldShow, extraData = migration.check(db)
                end
                if shouldShow then
                    table.insert(self.pendingPopups, {
                        popup = migration.popup,
                        extraData = extraData,
                    })
                end
            end
        end
    end

    -- Mark all versions as done (data migrations are complete)
    db.global.dataVersion = CURRENT_VERSION

    -- Show queued popups after a delay (same timing as old system)
    if #self.pendingPopups > 0 then
        C_Timer.After(2, function()
            self:ShowNextPopup()
        end)
    end
end


-------------------------------------------------------------------------------
-- Popup Display
-------------------------------------------------------------------------------

function Migrations:ShowNextPopup()
    if #self.pendingPopups == 0 then return end

    local entry = table.remove(self.pendingPopups, 1)
    self:ShowDialog(entry.popup, entry.extraData)
end

function Migrations:CreateDialog()
    if self.dialog then return self.dialog end

    local dialog = CreateFrame("Frame", "VeevHUDMigrationDialog", UIParent, "BasicFrameTemplateWithInset")
    dialog:SetSize(460, 280)
    -- Position ~30% down from top to avoid hiding the HUD
    dialog:SetPoint("CENTER", UIParent, "CENTER", 0, UIParent:GetHeight() * 0.20)
    dialog:SetFrameStrata("DIALOG")
    dialog:SetMovable(true)
    dialog:EnableMouse(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
    dialog:Hide()

    -- Title
    local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -6)
    dialog.titleText = title

    -- Message
    local message = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    message:SetPoint("TOP", title, "BOTTOM", 0, -12)
    message:SetWidth(420)
    message:SetJustifyH("CENTER")
    message:SetSpacing(2)
    dialog.messageText = message

    -- Extra info (dimmer, below message)
    local extraInfo = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    extraInfo:SetPoint("TOP", message, "BOTTOM", 0, -8)
    extraInfo:SetWidth(420)
    extraInfo:SetJustifyH("CENTER")
    extraInfo:SetTextColor(0.7, 0.7, 0.7)
    dialog.extraInfoText = extraInfo

    dialog.buttons = {}

    self.dialog = dialog
    return dialog
end

function Migrations:ShowDialog(popup, extraData)
    local dialog = self:CreateDialog()

    -- Title
    dialog.titleText:SetText("|cff00ccffVeevHUD|r - " .. (popup.title or "Update"))

    -- Message (static or dynamic)
    local message = popup.message or ""
    if popup.getMessage then
        message = popup.getMessage(extraData) or message
    end
    dialog.messageText:SetText(message)

    -- Extra info (optional)
    local extra = ""
    if popup.getExtraInfo then
        extra = popup.getExtraInfo(extraData) or ""
    end
    dialog.extraInfoText:SetText(extra)

    -- Clear old buttons
    for _, btn in ipairs(dialog.buttons) do
        btn:Hide()
        btn:SetParent(nil)
    end
    wipe(dialog.buttons)

    -- Create buttons
    local buttonConfigs = popup.buttons or {{ text = "OK" }}
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
            if btnConfig.action then
                btnConfig.action(extraData)
            end
            dialog:Hide()
            self:ShowNextPopup()
        end)

        table.insert(dialog.buttons, btn)
    end

    dialog:Show()
end
