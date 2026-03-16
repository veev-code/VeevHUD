--[[
    VeevHUD - Icon Renderer Module
    Stateless rendering service for icon frames.
    All functions take a frame + parameters — no domain logic, no spell/aura lookups.

    Used by CooldownIcons and TrinketTracker to apply visual state (spirals, text,
    alpha transitions, desaturation, stacks, charges, resource displays) through
    a common rendering pipeline.
]]

local _, addon = ...
local C = addon.Constants

-- Localized WoW API functions (hot path)
local GetTime = GetTime
local UnitAffectingCombat = UnitAffectingCombat
local IsResting = IsResting

local IconRenderer = {}
addon:RegisterModule("IconRenderer", IconRenderer)

-------------------------------------------------------------------------------
-- 60fps Resource Animation Driver
-- A single invisible Frame whose OnUpdate smoothly interpolates resource fill
-- heights across all registered icon frames. Starts hidden; shown when frames
-- are registered, hidden when all converge or are removed. Same pattern as
-- Animations.lua punchDriver/slideDriver.
-------------------------------------------------------------------------------
local animatedFrames = {}
local animDriverFrame = CreateFrame("Frame")
animDriverFrame:Hide()  -- Start hidden; shown when frames are registered
animDriverFrame:SetScript("OnUpdate", function()
    local smooth = addon.db.profile.animations.smoothBars
    local hasActive = false
    for frame in pairs(animatedFrames) do
        local target = frame.resourceTarget
        if not target then
            animatedFrames[frame] = nil
        else
            local converged
            if smooth then
                -- 0.02/frame at 60fps gives a slow, visible fill (~2s to converge)
                frame.resourceCurrent, converged = addon.Utils:SmoothBarValue(frame.resourceCurrent, target, 0.02)
            else
                frame.resourceCurrent = target
                converged = true
            end

            local current = frame.resourceCurrent
            local mode = frame.resourceDisplayMode
            if mode == C.RESOURCE_DISPLAY_MODE.BAR and frame.resourceBar and frame.resourceBar:IsShown() then
                frame.resourceBar.fill:SetWidth(math.max(1, frame.resourceIconWidth * current))
            elseif mode == C.RESOURCE_DISPLAY_MODE.FILL and frame.resourceFill and frame.resourceFill:IsShown() then
                local h = frame.resourceIconHeight
                if frame.resourceFillInvert then
                    frame.resourceFill:SetHeight(math.max(0, h * current))
                else
                    frame.resourceFill:SetHeight(math.max(0, h * (1 - current)))
                end
            end

            if not converged then
                hasActive = true
            end
        end
    end
    if not hasActive then
        animDriverFrame:Hide()
    end
end)

function IconRenderer:RegisterAnimatedFrame(frame)
    if not animatedFrames[frame] then
        animatedFrames[frame] = true
    end
    animDriverFrame:Show()
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function IconRenderer:Initialize()
    self.Utils = addon.Utils
    self.Animations = addon.Animations
    self.C = addon.Constants
end

-------------------------------------------------------------------------------
-- Cooldown Text Configuration
-------------------------------------------------------------------------------

-- Configure external cooldown text addons (OmniCC, ElvUI, etc.)
-- If showCooldownText is enabled for this row, we use our own text and hide external addons
-- If showCooldownText is disabled for this row, we let external addons show their text
-- rowIndex: 1 = Primary, 2 = Secondary, 3+ = Utility (nil = use global setting)
function IconRenderer:ConfigureCooldownText(cooldown, rowIndex)
    local db = addon.db.profile.icons

    -- Check if VeevHUD will show its own text for this specific row
    local showOwnText
    if rowIndex then
        showOwnText = addon.Database:IsRowSettingEnabled(db.showCooldownTextOn, rowIndex)
    else
        -- No row specified (initial creation) - default to allowing external addons
        -- Will be reconfigured when assigned to a row
        showOwnText = false
    end

    -- Use shared utility for the actual OmniCC/ElvUI configuration
    self.Utils:ConfigureCooldownText(cooldown, showOwnText)
end

-------------------------------------------------------------------------------
-- Cast Feedback
-------------------------------------------------------------------------------

-- Play cast feedback animation (scale punch using Animations utility)
function IconRenderer:PlayCastFeedback(frame)
    if not frame then return end

    local db = addon.db.profile.icons

    -- Check row-based setting
    local rowIndex = frame.rowIndex or 1
    if not addon.Database:IsRowSettingEnabled(db.castFeedbackRows, rowIndex) then return end

    local scale = db.castFeedbackScale

    -- Track when cast feedback plays so dim transition can sync with it
    frame._lastCastFeedbackTime = GetTime()

    -- Use Animations utility for consistent scale punch behavior
    if self.Animations then
        self.Animations:PlayScalePunch(frame, scale)
    end
end

-------------------------------------------------------------------------------
-- Icon Visuals (shared rendering pipeline)
-------------------------------------------------------------------------------

-- Apply visual state to an icon frame.
-- Both CooldownIcons and TrinketTracker compute their own
-- domain-specific state, then call this method to apply spirals, text, alpha,
-- desaturation, stacks, and charges identically.
--
-- @param frame    The icon frame
-- @param state    Table with visual state fields (see below)
-- @param db       icons config (addon.db.profile.icons)
function IconRenderer:ApplyIconVisuals(frame, state, db)
    local rowIndex = frame.rowIndex or 1
    local now = GetTime()

    -- Unpack state
    local showAuraActive = state.showAuraActive
    local auraRemaining = state.auraRemaining or 0
    local auraDuration = state.auraDuration or 0
    local auraStacks = state.auraStacks or 0
    local cdRemaining = state.cdRemaining or 0
    local cdDuration = state.cdDuration or 0
    local cdStartTime = state.cdStartTime or 0
    local alpha = state.alpha
    local desaturate = state.desaturate
    local showSpinner = state.showSpinner
    local showText = state.showText
    local showPrediction = state.showPrediction
    local predictionRemaining = state.predictionRemaining or 0
    local predictionDuration = state.predictionDuration or 0
    local predictionStartTime = state.predictionStartTime or 0
    local gcdContinueText = state.gcdContinueText
    local charges = state.charges
    local hasCharges = state.hasCharges

    -------------------------------------------------------------------
    -- Spiral display
    -------------------------------------------------------------------
    local showSpiralForRow = addon.Database:IsRowSettingEnabled(db.showCooldownSpiralOn, rowIndex)
    local shouldShowSpiral = showSpinner or showPrediction

    if shouldShowSpiral and showSpiralForRow then
        if showPrediction and predictionDuration > 0 then
            -- Prediction spiral (waiting for resources)
            frame.cooldown:SetAlpha(db.cooldownSpiralAlpha)
            frame.cooldown:SetReverse(false)
            if frame.lastCdStart ~= predictionStartTime or frame.lastCdDuration ~= predictionDuration then
                frame.cooldown:SetCooldown(predictionStartTime, predictionDuration)
                frame.lastCdStart = predictionStartTime
                frame.lastCdDuration = predictionDuration
            end
            frame.cooldown:Show()
            frame._wasRealCooldown = false
        elseif showAuraActive and auraDuration > 0 then
            -- Aura spiral (reverse: bright drains as time passes)
            frame.cooldown:SetAlpha(db.auraSpiralAlpha)
            frame.cooldown:SetReverse(true)
            local start = now - (auraDuration - auraRemaining)
            if frame.lastCdStart ~= start or frame.lastCdDuration ~= auraDuration then
                frame.cooldown:SetCooldown(start, auraDuration)
                frame.lastCdStart = start
                frame.lastCdDuration = auraDuration
            end
            frame.cooldown:Show()
            frame._wasRealCooldown = false
        elseif cdDuration > 0 and cdStartTime > 0 then
            -- Cooldown spiral (normal: dark drains as time passes)
            frame.cooldown:SetAlpha(db.cooldownSpiralAlpha)
            frame.cooldown:SetReverse(false)
            if frame.lastCdStart ~= cdStartTime or frame.lastCdDuration ~= cdDuration then
                frame.cooldown:SetCooldown(cdStartTime, cdDuration)
                frame.lastCdStart = cdStartTime
                frame.lastCdDuration = cdDuration
            end
            frame._wasRealCooldown = true
            frame.cooldown:Show()
        else
            frame.cooldown:SetAlpha(1)
            if not frame._wasRealCooldown then
                frame.cooldown:SetCooldown(0, 0)
            end
            frame.lastCdStart = nil
            frame.lastCdDuration = nil
            frame._wasRealCooldown = nil
        end
    else
        frame.cooldown:SetAlpha(1)
        if not frame._wasRealCooldown then
            frame.cooldown:SetCooldown(0, 0)
        end
        frame.lastCdStart = nil
        frame.lastCdDuration = nil
        frame._wasRealCooldown = nil
    end

    -------------------------------------------------------------------
    -- Text display
    -------------------------------------------------------------------
    local showTextForRow = addon.Database:IsRowSettingEnabled(db.showCooldownTextOn, rowIndex)
    local textColor = addon.db.profile.appearance.textColor

    if showPrediction and predictionRemaining > 0 and showTextForRow then
        frame.text:SetText(self.Utils:FormatCooldown(predictionRemaining))
        frame.text:SetTextColor(textColor.r, textColor.g, textColor.b)
    elseif gcdContinueText and cdRemaining > 0 and showTextForRow then
        frame.text:SetText(self.Utils:FormatCooldown(cdRemaining))
        frame.text:SetTextColor(textColor.r, textColor.g, textColor.b)
    elseif showAuraActive and auraRemaining > 0 and showTextForRow then
        frame.text:SetText(self.Utils:FormatCooldown(auraRemaining))
        frame.text:SetTextColor(textColor.r, textColor.g, textColor.b)
    elseif showText and showTextForRow and cdRemaining > 0 then
        if db.useOwnCooldownText then
            frame.text:SetText(self.Utils:FormatCooldown(cdRemaining))
            frame.text:SetTextColor(textColor.r, textColor.g, textColor.b)
        else
            frame.text:SetText("")
        end
    else
        frame.text:SetText("")
    end

    -------------------------------------------------------------------
    -- Alpha transition (with cast-feedback delay)
    -------------------------------------------------------------------
    frame.iconAlpha = alpha

    local animDb = addon.db.profile.animations
    if animDb.dimTransition and self.Animations then
        local targetAlpha = frame._targetAlpha
        if targetAlpha ~= alpha then
            local currentAlpha = frame:GetAlpha()
            if alpha < currentAlpha then
                -- Dimming - delay if cast feedback is playing
                if frame._dimTimer then
                    frame._dimTimer:Cancel()
                    frame._dimTimer = nil
                end

                local castFeedbackPlaying = frame._lastCastFeedbackTime and
                    (now - frame._lastCastFeedbackTime) < 0.2
                local dimDelay = castFeedbackPlaying and 0.08 or 0

                if dimDelay > 0 then
                    frame._dimTimer = C_Timer.After(dimDelay, function()
                        if frame and frame:IsShown() then
                            self.Animations:TransitionAlpha(frame, alpha, 6)
                        end
                        frame._dimTimer = nil
                    end)
                else
                    self.Animations:TransitionAlpha(frame, alpha, 6)
                end
            else
                -- Brightening - cancel pending dim and snap immediately
                if frame._dimTimer then
                    frame._dimTimer:Cancel()
                    frame._dimTimer = nil
                end
                self.Animations:StopAlphaTransition(frame)
                frame:SetAlpha(alpha)
            end
            frame._targetAlpha = alpha
        end
    else
        if frame._dimTimer then
            frame._dimTimer:Cancel()
            frame._dimTimer = nil
        end
        if self.Animations then
            self.Animations:StopAlphaTransition(frame)
        end
        frame:SetAlpha(alpha)
        frame._targetAlpha = alpha
    end

    -------------------------------------------------------------------
    -- Desaturation
    -------------------------------------------------------------------
    frame.icon:SetDesaturated(desaturate)

    -------------------------------------------------------------------
    -- Charges
    -------------------------------------------------------------------
    if frame.charges then
        if hasCharges then
            frame.charges:SetText(charges)
        else
            frame.charges:SetText("")
        end
    end

    -------------------------------------------------------------------
    -- Stacks
    -------------------------------------------------------------------
    if frame.stacks then
        if auraStacks >= 1 then
            frame.stacks:SetText(auraStacks)
        else
            frame.stacks:SetText("")
        end
    end
end

-------------------------------------------------------------------------------
-- Resource Display
-------------------------------------------------------------------------------

-- Update resource cost display (horizontal bar or vertical fill)
-- In prediction mode:
--   - While prediction spiral is active: hide resource display (spiral is the indicator)
--   - When prediction failed (fallback): show vertical fill as deterministic feedback
function IconRenderer:UpdateResourceDisplay(frame, _, _, hasResourceCost, resourcePercent, powerColor, db, showPredictionSpiral, inPredictionFallback, isOnActualCooldown)
    local displayMode = db.resourceDisplayMode
    local displayRows = db.resourceDisplayRows
    local rowIndex = frame.rowIndex or 1
    local isPredictionMode = displayMode == C.RESOURCE_DISPLAY_MODE.PREDICTION

    -- Check if resource display is enabled for this row
    local enabledForRow = addon.Database:IsRowSettingEnabled(displayRows, rowIndex)

    -- Prediction mode: hide display while spiral is active
    if isPredictionMode and showPredictionSpiral then
        if frame.resourceBar then frame.resourceBar:Hide() end
        if frame.resourceFill then frame.resourceFill:Hide() end
        frame.resourceTarget = nil
        return
    end

    -- Only show resource indicator if:
    -- 1. Not resting and out of combat (show in PvP/world even if combat drops)
    -- 2. The spell has a resource cost
    -- 3. We don't have enough resources (resourcePercent < 1)
    -- 4. Resource display is enabled for this row
    -- 5. If on cooldown, only show if resourceShowDuringCooldown is enabled
    local inCombat = UnitAffectingCombat("player")
    local isResting = IsResting()
    local showUsability = inCombat or not isResting

    local showResource = showUsability and hasResourceCost and resourcePercent < 1 and enabledForRow
    if showResource and isOnActualCooldown and not db.resourceShowDuringCooldown then
        showResource = false
    end

    if not showResource then
        -- Hide and reset
        if frame.resourceBar then frame.resourceBar:Hide() end
        if frame.resourceFill then frame.resourceFill:Hide() end
        frame.resourceTarget = nil
        return
    end

    local iconSize = frame.iconSize or db.iconSize
    local iconWidth = frame.iconWidth or iconSize
    local iconHeight = frame.iconHeight or iconSize

    -- Set animation target (60fps driver frame handles smooth interpolation)
    if not frame.resourceCurrent then
        frame.resourceCurrent = resourcePercent
    end
    frame.resourceTarget = resourcePercent
    frame.resourceIconWidth = iconWidth
    frame.resourceIconHeight = iconHeight
    frame.resourceFillInvert = db.resourceFillInvert

    -- In prediction fallback, always use vertical fill regardless of configured mode
    local effectiveMode = inPredictionFallback and C.RESOURCE_DISPLAY_MODE.FILL or displayMode
    frame.resourceDisplayMode = effectiveMode

    -- Resolve fill color (normalize to r,g,b regardless of source format)
    local fcR, fcG, fcB
    if db.resourceFillUsePowerColor and powerColor then
        fcR, fcG, fcB = powerColor[1], powerColor[2], powerColor[3]
    else
        local fc = db.resourceFillColor
        fcR, fcG, fcB = fc.r, fc.g, fc.b
    end

    if effectiveMode == C.RESOURCE_DISPLAY_MODE.BAR and frame.resourceBar then
        local brR, brG, brB
        if db.resourceBarUsePowerColor and powerColor then
            brR, brG, brB = powerColor[1], powerColor[2], powerColor[3]
        else
            local bc = db.resourceBarColor
            brR, brG, brB = bc.r, bc.g, bc.b
        end
        frame.resourceBar.fill:SetVertexColor(brR, brG, brB, 1)
        frame.resourceBar:SetHeight(db.resourceBarHeight)
        frame.resourceBar:Show()
        if frame.resourceFill then frame.resourceFill:Hide() end
    elseif effectiveMode == C.RESOURCE_DISPLAY_MODE.FILL and frame.resourceFill then
        frame.resourceFill:SetVertexColor(fcR, fcG, fcB, db.resourceFillAlpha)
        -- Update anchor if invert setting changed
        if frame._fillInverted ~= db.resourceFillInvert then
            frame._fillInverted = db.resourceFillInvert
            frame.resourceFill:ClearAllPoints()
            if db.resourceFillInvert then
                frame.resourceFill:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
                frame.resourceFill:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
            else
                frame.resourceFill:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
                frame.resourceFill:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
            end
        end
        frame.resourceFill:Show()
        if frame.resourceBar then frame.resourceBar:Hide() end
    end

    -- Register this frame for 60fps animation
    self:RegisterAnimatedFrame(frame)

end


