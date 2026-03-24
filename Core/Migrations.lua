--[[
    VeevHUD - Migration System

    Consolidated, versioned migration system. Each migration is a numbered
    version with optional data logic and/or popup notification.

    How it works:
      - db.global.dataVersion tracks the last completed migration version (popups).
      - db.profile._dataVersion tracks per-profile data migration progress, so
        each character's profile gets migrated even if another character logged
        in first and bumped the global version.
      - On first encounter (dataVersion == nil), ALL users (new and existing)
        start at CURRENT_VERSION — legacy migrations are skipped.
      - Future migrations are added as sequential version entries.
      - Data migrations (run) execute per-profile. Popups show once per account.

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
local CURRENT_VERSION = 8

-- Migration definitions, keyed by version number.
-- Versions 1-4 (legacy) are intentionally omitted — they corresponded to:
--   v1: Aura Tracker rename popup
--   v2: UI scale compensation popup
--   v3: Buff Reminders feature popup + per-spec data migration
--   v4: Trinket Tracking feature popup
--
-- Future migrations start at version 5+.
local migrations = {
    -- v5: Auxiliary Row + Totem Element Slots
    -- Converts standalone Totem Bar into icon row slots within a new 4th row.
    [5] = {
        run = function(db)
            local profile = db.profile
            if not profile then return end

            -- 1. Add 4th row (Auxiliary) if rows only has 3 entries
            if profile.rows and #profile.rows == 3 then
                profile.rows[4] = {
                    name = "Auxiliary",
                    tags = {},
                    maxIcons = 24,
                    enabled = true,
                    iconSize = 36,
                    flowLayout = false,
                    iconsPerRow = 6,
                }

                -- Copy icon size from old totemBar config if user customized it
                if profile.totemBar and profile.totemBar.iconSize then
                    profile.rows[4].iconSize = profile.totemBar.iconSize
                end
            end

            -- 2. Replace "totemBar" with "auxiliaryRow" in layout.elementOrder
            if profile.layout and profile.layout.elementOrder then
                for i, key in ipairs(profile.layout.elementOrder) do
                    if key == "totemBar" then
                        profile.layout.elementOrder[i] = "auxiliaryRow"
                        break
                    end
                end
            end

            -- 3. Copy totemBar gap to auxiliaryRow gap
            if profile.layout and profile.layout.gaps then
                if profile.layout.gaps.totemBar then
                    profile.layout.gaps.auxiliaryRow = profile.layout.gaps.totemBar
                    profile.layout.gaps.totemBar = nil
                end
            end

            -- 4. If user had totemBar disabled, disable all 4 totem sentinels
            -- Only shaman profiles have totemBar.enabled explicitly set to false
            -- (AceDB defaults it to true, so non-shamans never match)
            if profile.totemBar and profile.totemBar.enabled == false then
                if profile.spellConfig then
                    for specKey, specCfg in pairs(profile.spellConfig) do
                        if type(specCfg) == "table" then
                            specCfg[9999901] = specCfg[9999901] or {}
                            specCfg[9999901].enabled = false
                            specCfg[9999902] = specCfg[9999902] or {}
                            specCfg[9999902].enabled = false
                            specCfg[9999903] = specCfg[9999903] or {}
                            specCfg[9999903].enabled = false
                            specCfg[9999904] = specCfg[9999904] or {}
                            specCfg[9999904].enabled = false
                        end
                    end
                end
            end

            -- 5. Clean up stale legacy migration tracking (replaced by dataVersion)
            if db.global and db.global.migrationsShown then
                db.global.migrationsShown = nil
            end
        end,
        popup = {
            title = "New: Auxiliary Row",
            message = "A new 4th icon row — the Auxiliary Row — is now available. Use it to separate spells you want visually distinct from your main rows, like tracking totems, trinkets, or niche abilities in their own group.\n\nDrag spells into it via Spell Configuration (/vh spells). By default it sits above the Health Bar, but you can reposition it in the Layout tab. It has its own icon size and aspect ratio settings under Ability Rows.\n\nFor Shamans, totem element slots now live here instead of the old standalone Totem Bar. Warriors, Druids, and Paladins get a stance/form/aura indicator showing your current active state.\n\nThe row collapses automatically when empty.",
            buttons = {
                { text = "Got It" },
            },
        },
    },

    -- v6: Cooldown Pulse feature announcement
    [6] = {
        popup = {
            title = "New: Cooldown Pulse",
            message = "Cooldown Pulse is a new feature — inspired by addons like Doom_CooldownPulse — that flashes a large ability icon in the center of your screen when it comes off cooldown.\n\nYou can choose which rows trigger pulses (default: all rows), adjust the icon size, opacity, and animation style — or disable it entirely.\n\nConfigure it in the new Cooldown Pulse tab.",
            buttons = {
                { text = "Open Settings", action = function()
                    C_Timer.After(0.1, function()
                        if addon.Options then
                            addon.Options:Open()
                            local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
                            if AceConfigDialog then
                                AceConfigDialog:SelectGroup(ADDON_NAME, "cooldownPulse")
                            end
                        end
                    end)
                end },
                { text = "Got It" },
            },
        },
    },

    -- v8: Sound Notifications feature announcement
    [8] = {
        popup = {
            title = "New: Sound Notifications",
            message = "VeevHUD can now play sounds for combat events. All sounds default to silent — configure the ones you want.\n\n"
                .. "Supported on: proc activation (Aura Tracker), ability ready (Spell Config > Ready Glow Sound), and missing buff alerts (Buff Reminders). Each supports per-spell overrides.\n\n"
                .. "Sounds come from LibSharedMedia (WeakAuras, SharedMedia packs, etc.). You can also register WoW Sound Kit IDs in General > Sound.",
            buttons = {
                { text = "Open Settings", action = function()
                    C_Timer.After(0.1, function()
                        if addon.Options then
                            addon.Options:Open()
                        end
                    end)
                end },
                { text = "Got It" },
            },
        },
    },

    -- v7: Default icon clutter reduction across all classes
    [7] = {
        popup = {
            title = "Cleaner Default Icons",
            message = "Default icon setups have been streamlined across all classes to reduce clutter out of the box.\n\nSituational and niche abilities (melee attacks for hunters, creature-type-specific spells, threat drops, etc.) are now hidden by default. Spammable filler abilities with no meaningful cooldown are also excluded.\n\nAll hidden spells can be re-enabled at any time via Spell Configuration — just drag them into the row you want.",
            buttons = {
                { text = "Spell Configuration", action = function()
                    C_Timer.After(0.1, function()
                        if addon.SpellsOptions then
                            addon.SpellsOptions:Open()
                        end
                    end)
                end },
                { text = "Got It" },
            },
        },
    },
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

    -- Per-profile migration tracking: ensures each character's profile gets
    -- migrated even if a different character logged in first and bumped the
    -- global dataVersion. Profile version defaults to global version on first
    -- encounter (no need to re-run migrations already completed globally).
    if db.profile._dataVersion == nil then
        db.profile._dataVersion = db.global.dataVersion
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

    -- Determine which migrations this profile still needs.
    -- Profile version may lag behind global version if a different character
    -- logged in first and bumped the global version.
    local profileVersion = db.profile._dataVersion or db.global.dataVersion
    local globalVersion = db.global.dataVersion
    local startVersion = math.min(profileVersion, globalVersion)

    if startVersion >= CURRENT_VERSION then return end

    -- Run all migrations above the lowest pending version
    for v = startVersion + 1, CURRENT_VERSION do
        local migration = migrations[v]
        if migration then
            -- Data migration: runs per-profile (idempotent checks inside)
            if migration.run and v > profileVersion then
                local ok, err = pcall(migration.run, db)
                if not ok then
                    addon.Utils:LogError("Migration v" .. v .. " failed:", err)
                end
            end

            -- Popup: only show once per account (use global version as gate)
            if migration.popup and v > globalVersion then
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

    -- Mark versions as done
    db.global.dataVersion = CURRENT_VERSION
    db.profile._dataVersion = CURRENT_VERSION

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
