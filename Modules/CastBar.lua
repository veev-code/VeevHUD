--[[
    VeevHUD - Cast Bar Module
    Displays target cast bar with interrupt indicators
]]

local ADDON_NAME, addon = ...

local CastBar = {}
addon:RegisterModule("CastBar", CastBar)

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function CastBar:Initialize()
    self.Events = addon.Events
    self.Utils = addon.Utils
    self.C = addon.Constants

    -- Register events
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_START", self.OnCastStart)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_STOP", self.OnCastStop)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_FAILED", self.OnCastStop)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_INTERRUPTED", self.OnCastInterrupted)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_DELAYED", self.OnCastDelayed)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_CHANNEL_START", self.OnChannelStart)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_CHANNEL_STOP", self.OnCastStop)
    self.Events:RegisterEvent(self, "UNIT_SPELLCAST_CHANNEL_UPDATE", self.OnChannelUpdate)
    self.Events:RegisterEvent(self, "PLAYER_TARGET_CHANGED", self.OnTargetChanged)

    self.Utils:Debug("CastBar initialized")
end

-------------------------------------------------------------------------------
-- Frame Creation
-------------------------------------------------------------------------------

function CastBar:CreateFrames(parent)
    local db = addon.db.profile.castBar

    if not db.enabled then return end

    -- Main container
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(db.width, db.height)
    frame:SetPoint("CENTER", parent, "CENTER", 0, db.offsetY)
    frame:Hide()
    self.frame = frame

    -- Status bar
    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetAllPoints()
    bar:SetStatusBarTexture(self.C.TEXTURES.STATUSBAR)
    bar:SetStatusBarColor(0.8, 0.7, 0.0)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    self.bar = bar

    -- Background
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(self.C.TEXTURES.STATUSBAR)
    bg:SetVertexColor(0.2, 0.2, 0.2, 0.8)
    self.bg = bg

    -- Border
    local border = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", 2, -2)
    border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    border:SetBackdropBorderColor(0, 0, 0, 1)
    border:SetFrameLevel(frame:GetFrameLevel() - 1)

    -- Icon (left side)
    if db.showIcon then
        local iconFrame = CreateFrame("Frame", nil, frame)
        iconFrame:SetSize(db.height + 4, db.height + 4)
        iconFrame:SetPoint("RIGHT", frame, "LEFT", -4, 0)

        local icon = iconFrame:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        self.icon = icon

        local iconBorder = iconFrame:CreateTexture(nil, "OVERLAY")
        iconBorder:SetPoint("TOPLEFT", -1, 1)
        iconBorder:SetPoint("BOTTOMRIGHT", 1, -1)
        iconBorder:SetColorTexture(0, 0, 0, 1)
        iconBorder:SetDrawLayer("OVERLAY", -1)
    end

    -- Spell name text
    local spellText = bar:CreateFontString(nil, "OVERLAY")
    spellText:SetFont(self.C.FONTS.DEFAULT, 10, "OUTLINE")
    spellText:SetPoint("LEFT", 4, 0)
    spellText:SetJustifyH("LEFT")
    self.spellText = spellText

    -- Timer text
    if db.showTimer then
        local timerText = bar:CreateFontString(nil, "OVERLAY")
        timerText:SetFont(self.C.FONTS.NUMBER, 10, "OUTLINE")
        timerText:SetPoint("RIGHT", -4, 0)
        timerText:SetJustifyH("RIGHT")
        self.timerText = timerText
    end

    -- Interrupt highlight border
    if db.interruptHighlight then
        self.interruptBorder = border
    end

    -- Update ticker
    self.Events:RegisterUpdate(self, 0.02, self.UpdateCast)
end

-------------------------------------------------------------------------------
-- Cast Event Handlers
-------------------------------------------------------------------------------

function CastBar:OnCastStart(event, unit, castGUID, spellID)
    if unit ~= "target" then return end

    self:StartCast(unit, false)
end

function CastBar:OnChannelStart(event, unit, castGUID, spellID)
    if unit ~= "target" then return end

    self:StartCast(unit, true)
end

function CastBar:OnCastStop(event, unit)
    if unit ~= "target" then return end

    self:StopCast()
end

function CastBar:OnCastInterrupted(event, unit)
    if unit ~= "target" then return end

    self:ShowInterrupted()
end

function CastBar:OnCastDelayed(event, unit)
    if unit ~= "target" then return end

    self:UpdateCastInfo(false)
end

function CastBar:OnChannelUpdate(event, unit)
    if unit ~= "target" then return end

    self:UpdateCastInfo(true)
end

function CastBar:OnTargetChanged()
    -- Check if new target is casting
    if UnitExists("target") then
        local name, _, _, startTime, endTime = UnitCastingInfo("target")
        if name then
            self:StartCast("target", false)
            return
        end

        name, _, _, startTime, endTime = UnitChannelInfo("target")
        if name then
            self:StartCast("target", true)
            return
        end
    end

    self:StopCast()
end

-------------------------------------------------------------------------------
-- Cast Bar Logic
-------------------------------------------------------------------------------

function CastBar:StartCast(unit, isChannel)
    if not self.frame then return end

    self.casting = true
    self.channeling = isChannel

    self:UpdateCastInfo(isChannel)

    self.frame:Show()
end

function CastBar:UpdateCastInfo(isChannel)
    local unit = "target"
    local name, text, texture, startTime, endTime, isTradeSkill, castID, notInterruptible, spellID

    if isChannel then
        name, text, texture, startTime, endTime, isTradeSkill, notInterruptible, spellID = UnitChannelInfo(unit)
    else
        name, text, texture, startTime, endTime, isTradeSkill, castID, notInterruptible, spellID = UnitCastingInfo(unit)
    end

    if not name then
        self:StopCast()
        return
    end

    self.startTime = startTime / 1000
    self.endTime = endTime / 1000
    self.isChannel = isChannel
    self.notInterruptible = notInterruptible

    -- Update display
    if self.icon then
        self.icon:SetTexture(texture)
    end

    if self.spellText then
        self.spellText:SetText(name)
    end

    -- Update interruptible color
    self:UpdateInterruptHighlight(notInterruptible)
end

function CastBar:UpdateCast()
    if not self.casting and not self.channeling then return end
    if not self.frame or not self.frame:IsShown() then return end

    local now = GetTime()

    if now >= self.endTime then
        self:StopCast()
        return
    end

    local progress
    if self.isChannel then
        progress = (self.endTime - now) / (self.endTime - self.startTime)
    else
        progress = (now - self.startTime) / (self.endTime - self.startTime)
    end

    self.bar:SetValue(progress)

    -- Update timer
    if self.timerText then
        local remaining = self.endTime - now
        self.timerText:SetText(string.format("%.1f", remaining))
    end
end

function CastBar:UpdateInterruptHighlight(notInterruptible)
    if not self.interruptBorder then return end

    local db = addon.db.profile.castBar

    if notInterruptible then
        -- Cannot be interrupted - red/gray
        self.bar:SetStatusBarColor(0.5, 0.5, 0.5)
        self.interruptBorder:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    else
        -- Can be interrupted - yellow with highlight
        self.bar:SetStatusBarColor(0.8, 0.7, 0.0)
        if db.interruptHighlight then
            self.interruptBorder:SetBackdropBorderColor(1, 0.5, 0, 1)
        else
            self.interruptBorder:SetBackdropBorderColor(0, 0, 0, 1)
        end
    end
end

function CastBar:StopCast()
    self.casting = false
    self.channeling = false

    if self.frame then
        self.frame:Hide()
    end
end

function CastBar:ShowInterrupted()
    -- Flash red briefly
    if self.bar then
        self.bar:SetStatusBarColor(1, 0, 0)
    end

    -- Hide after short delay
    C_Timer.After(0.3, function()
        self:StopCast()
    end)
end

-------------------------------------------------------------------------------
-- Enable/Disable
-------------------------------------------------------------------------------

function CastBar:Enable()
    -- Will show when target is casting
end

function CastBar:Disable()
    if self.frame then
        self.frame:Hide()
    end
end

function CastBar:Refresh()
    self:OnTargetChanged()
end
