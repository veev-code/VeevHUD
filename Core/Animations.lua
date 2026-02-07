-------------------------------------------------------------------------------
-- VeevHUD Animation Utilities
-- Reusable animation factories with consistent patterns and gotcha handling
-------------------------------------------------------------------------------
-- Key patterns implemented:
--   1. Stop before play: Prevents overlapping animations
--   2. SetToFinalAlpha(true): Clean final state even if stopped early
--   3. OnPlay cleanup: Stop opposite animation to prevent conflicts
--   4. OnFinished cleanup: Explicitly set final state
--   5. Lazy creation: Create on first use, cache on frame
--   6. Parameter caching: Recreate animation if parameters change
--   7. Lerp with minimum step: Prevent stuck animations in OnUpdate
-------------------------------------------------------------------------------

local addonName, addon = ...

local Animations = {}
addon.Animations = Animations

-- Default durations for consistency
Animations.DURATIONS = {
    FAST = 0.1,      -- Quick transitions
    NORMAL = 0.15,   -- Standard transitions (fade in/out)
    SLOW = 0.2,      -- Slower, more noticeable transitions
}

-------------------------------------------------------------------------------
-- Alpha Fade Animations (Show/Hide with fade)
-------------------------------------------------------------------------------

-- Creates bidirectional fade animations on a frame
-- Returns: { fadeIn, fadeOut } animation groups attached to frame
-- Usage: Animations:CreateFadePair(frame, duration, onShowFinished, onHideFinished)
function Animations:CreateFadePair(frame, duration, onShowFinished, onHideFinished)
    if not frame then return nil end
    
    duration = duration or self.DURATIONS.NORMAL
    
    -- Fade In
    local fadeIn = frame:CreateAnimationGroup()
    fadeIn:SetToFinalAlpha(true)
    
    local fadeInAlpha = fadeIn:CreateAnimation("Alpha")
    fadeInAlpha:SetFromAlpha(0)
    fadeInAlpha:SetToAlpha(1)
    fadeInAlpha:SetDuration(duration)
    fadeInAlpha:SetSmoothing("OUT")
    
    fadeIn:SetScript("OnPlay", function()
        -- Stop opposite animation to prevent conflicts
        if frame.fadeOut and frame.fadeOut:IsPlaying() then
            frame.fadeOut:Stop()
        end
        frame:SetAlpha(0)
        frame:Show()
    end)
    
    fadeIn:SetScript("OnFinished", function()
        frame:SetAlpha(1)
        if onShowFinished then onShowFinished(frame) end
    end)
    
    frame.fadeIn = fadeIn
    
    -- Fade Out
    local fadeOut = frame:CreateAnimationGroup()
    fadeOut:SetToFinalAlpha(true)
    
    local fadeOutAlpha = fadeOut:CreateAnimation("Alpha")
    fadeOutAlpha:SetFromAlpha(1)
    fadeOutAlpha:SetToAlpha(0)
    fadeOutAlpha:SetDuration(duration)
    fadeOutAlpha:SetSmoothing("IN")
    
    fadeOut:SetScript("OnPlay", function()
        -- Stop opposite animation to prevent conflicts
        if frame.fadeIn and frame.fadeIn:IsPlaying() then
            frame.fadeIn:Stop()
        end
        frame:SetAlpha(1)
    end)
    
    fadeOut:SetScript("OnFinished", function()
        frame:SetAlpha(0)
        frame:Hide()
        if onHideFinished then onHideFinished(frame) end
    end)
    
    frame.fadeOut = fadeOut
    
    return fadeIn, fadeOut
end

-- Play fade in (safely handles missing animations)
function Animations:FadeIn(frame)
    if not frame then return end
    if not frame.fadeIn then return end
    
    frame.fadeIn:Stop()
    frame.fadeIn:Play()
end

-- Play fade out (safely handles missing animations)
function Animations:FadeOut(frame)
    if not frame then return end
    if not frame.fadeOut then return end
    
    frame.fadeOut:Stop()
    frame.fadeOut:Play()
end

-- Instantly show without animation (cleanup any running animations)
function Animations:ShowInstant(frame)
    if not frame then return end
    
    if frame.fadeIn and frame.fadeIn:IsPlaying() then
        frame.fadeIn:Stop()
    end
    if frame.fadeOut and frame.fadeOut:IsPlaying() then
        frame.fadeOut:Stop()
    end
    
    frame:SetAlpha(1)
    frame:Show()
end

-- Instantly hide without animation (cleanup any running animations)
function Animations:HideInstant(frame)
    if not frame then return end
    
    if frame.fadeIn and frame.fadeIn:IsPlaying() then
        frame.fadeIn:Stop()
    end
    if frame.fadeOut and frame.fadeOut:IsPlaying() then
        frame.fadeOut:Stop()
    end
    
    frame:SetAlpha(0)
    frame:Hide()
end

-------------------------------------------------------------------------------
-- Scale Punch Animation (pop effect)
-------------------------------------------------------------------------------
-- Uses frame:SetScale() driven by a shared OnUpdate handler instead of WoW's
-- CreateAnimation("Scale") API. The Scale animation type causes rendering
-- artifacts (large black box flash) on frames containing CooldownFrameTemplate
-- children, because the Cooldown model's internal clipping doesn't follow the
-- animation's rendering transform. SetScale() modifies the frame's actual
-- effective scale, which the renderer handles correctly.
-------------------------------------------------------------------------------

-- SetScale() multiplies anchor offsets by the scale factor, which causes frames
-- to drift away from (or toward) their anchor origin during scaling. These
-- helpers adjust offsets each frame to keep the effective visual position fixed.
--
-- Stateless: computes compensation from current scale/offset so external
-- repositioning (e.g., ProcTracker re-centering icons) is handled correctly.

-- Apply scale while keeping the frame's effective visual position fixed.
-- Math: effectiveOffset = storedOffset * scale  (must stay constant)
--       newOffset = currentOffset * (currentScale / newScale)
local function ApplyPunchScale(frame, newScale)
    local oldScale = frame:GetScale()
    local point, relativeTo, relativePoint, xOfs, yOfs = frame:GetPoint(1)
    frame:SetScale(newScale)
    if point then
        local ratio = oldScale / newScale
        frame:SetPoint(point, relativeTo, relativePoint,
            (xOfs or 0) * ratio, (yOfs or 0) * ratio)
    end
end

-- Reset frame to scale 1 and restore the correct offset.
local function ResetPunchScale(frame)
    local oldScale = frame:GetScale()
    local point, relativeTo, relativePoint, xOfs, yOfs = frame:GetPoint(1)
    frame:SetScale(1)
    if point then
        -- At scale 1, stored offset = effective offset = currentOffset * oldScale
        frame:SetPoint(point, relativeTo, relativePoint,
            (xOfs or 0) * oldScale, (yOfs or 0) * oldScale)
    end
end

-- Shared driver frame for all active scale punch animations.
-- A single OnUpdate handler manages all in-flight punches efficiently.
local punchDriver = CreateFrame("Frame")
punchDriver.active = {}  -- [frame] = { phase, elapsed, targetScale, upDur, downDur }
punchDriver:Hide()

punchDriver:SetScript("OnUpdate", function(self, elapsed)
    local hasActive = false

    for frame, state in pairs(self.active) do
        state.elapsed = state.elapsed + elapsed

        if state.phase == "up" then
            -- Hold at target scale for upDuration
            if state.elapsed >= state.upDur then
                state.phase = "down"
                state.elapsed = 0
            end
            hasActive = true
        elseif state.phase == "down" then
            -- Smoothly scale back to 1.0
            local progress = state.elapsed / state.downDur
            if progress >= 1 then
                ResetPunchScale(frame)
                self.active[frame] = nil
            else
                -- Quadratic ease-out: fast start, smooth deceleration
                local eased = progress * (2 - progress)
                local s = state.targetScale
                ApplyPunchScale(frame, s + (1 - s) * eased)
                hasActive = true
            end
        end
    end

    if not hasActive then
        self:Hide()
    end
end)

-- Play scale punch animation on a frame
-- Parameters:
--   frame: The frame to animate
--   scale: Target scale (e.g., 1.15 for 15% larger)
--   cacheKey: Unused, kept for API compatibility
function Animations:PlayScalePunch(frame, scale, cacheKey)
    if not frame then return end

    scale = scale or 1.15

    -- Cancel any in-progress punch on this frame
    if punchDriver.active[frame] then
        ResetPunchScale(frame)
        punchDriver.active[frame] = nil
    end

    -- Also stop any legacy AnimationGroup-based animations (cleanup after code update)
    cacheKey = cacheKey or "scalePunch"
    if frame[cacheKey] and type(frame[cacheKey]) == "table" and frame[cacheKey].Stop then
        frame[cacheKey]:Stop()
        frame[cacheKey] = nil
    end

    -- Phase 1: Immediately scale up (the visual "punch")
    ApplyPunchScale(frame, scale)

    -- Register for animated scale-down
    punchDriver.active[frame] = {
        phase = "up",
        elapsed = 0,
        targetScale = scale,
        upDur = 0.08,   -- Hold at peak scale
        downDur = 0.12,  -- Smooth return to normal
    }

    punchDriver:Show()
end

-- Stop any active scale punch on a frame (immediately restore scale)
function Animations:StopScalePunch(frame)
    if not frame then return end

    if punchDriver.active[frame] then
        ResetPunchScale(frame)
        punchDriver.active[frame] = nil
    end
end

-------------------------------------------------------------------------------
-- Alpha Transition (smooth alpha change without show/hide)
-------------------------------------------------------------------------------

-- Smoothly transition a frame's alpha to a target value
-- Uses OnUpdate for smooth interpolation (lerp with minimum step)
-- Parameters:
--   frame: Frame to animate
--   targetAlpha: Target alpha value (0-1)
--   speed: Animation speed multiplier (default 8, higher = faster)
--   callback: Optional function to call when animation completes
function Animations:TransitionAlpha(frame, targetAlpha, speed, callback)
    if not frame then return end
    
    speed = speed or 8
    local minStep = 0.02  -- Minimum alpha change per frame to prevent getting stuck
    
    -- Store target
    frame._targetAlpha = targetAlpha
    frame._alphaCallback = callback
    
    -- If already at target, call callback and return
    local currentAlpha = frame:GetAlpha()
    if math.abs(targetAlpha - currentAlpha) < 0.01 then
        frame:SetAlpha(targetAlpha)
        if callback then callback(frame) end
        return
    end
    
    -- Start OnUpdate if not already running
    if frame._alphaAnimating then return end
    
    frame._alphaAnimating = true
    frame:SetScript("OnUpdate", function(self, elapsed)
        if not self._targetAlpha then
            self._alphaAnimating = false
            self:SetScript("OnUpdate", nil)
            return
        end
        
        local current = self:GetAlpha()
        local diff = self._targetAlpha - current
        
        -- If close enough, snap to target and stop
        if math.abs(diff) < 0.01 then
            self:SetAlpha(self._targetAlpha)
            self._alphaAnimating = false
            self:SetScript("OnUpdate", nil)
            if self._alphaCallback then
                self._alphaCallback(self)
                self._alphaCallback = nil
            end
            return
        end
        
        -- Lerp toward target with minimum step
        local step = diff * math.min(1, elapsed * speed)
        if math.abs(step) < minStep then
            step = diff > 0 and minStep or -minStep
        end
        local newAlpha = math.max(0, math.min(1, current + step))
        self:SetAlpha(newAlpha)
    end)
end

-- Stop any running alpha transition
function Animations:StopAlphaTransition(frame)
    if not frame then return end
    
    frame._targetAlpha = nil
    frame._alphaCallback = nil
    frame._alphaAnimating = false
    frame:SetScript("OnUpdate", nil)
end

return Animations
