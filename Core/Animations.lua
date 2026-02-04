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

-- Creates a scale punch animation (scale up then back down)
-- Parameters:
--   frame: The frame to animate
--   scale: Target scale (e.g., 1.15 for 15% larger)
--   upDuration: Duration of scale up (default 0.08)
--   downDuration: Duration of scale down (default 0.12)
--   cacheKey: Optional key to cache animation (for dynamic scale values)
function Animations:CreateScalePunch(frame, scale, upDuration, downDuration, cacheKey)
    if not frame then return nil end
    
    scale = scale or 1.15
    upDuration = upDuration or 0.08
    downDuration = downDuration or 0.12
    cacheKey = cacheKey or "scalePunch"
    local scaleKey = cacheKey .. "Scale"
    
    -- Check if we need to recreate (scale changed)
    if frame[cacheKey] and frame[scaleKey] == scale then
        return frame[cacheKey]
    end
    
    -- Stop existing animation if recreating
    if frame[cacheKey] then
        frame[cacheKey]:Stop()
    end
    
    local ag = frame:CreateAnimationGroup()
    
    -- Scale up from center
    local scaleUp = ag:CreateAnimation("Scale")
    scaleUp:SetOrigin("CENTER", 0, 0)
    scaleUp:SetScale(scale, scale)
    scaleUp:SetDuration(upDuration)
    scaleUp:SetSmoothing("OUT")
    scaleUp:SetOrder(1)
    
    -- Scale back down to normal
    local scaleDown = ag:CreateAnimation("Scale")
    scaleDown:SetOrigin("CENTER", 0, 0)
    scaleDown:SetScale(1/scale, 1/scale)
    scaleDown:SetDuration(downDuration)
    scaleDown:SetSmoothing("IN")
    scaleDown:SetOrder(2)
    
    frame[cacheKey] = ag
    frame[scaleKey] = scale
    
    return ag
end

-- Play scale punch animation (creates if needed)
function Animations:PlayScalePunch(frame, scale, cacheKey)
    if not frame then return end
    
    cacheKey = cacheKey or "scalePunch"
    
    -- Create or get cached animation
    local ag = self:CreateScalePunch(frame, scale, nil, nil, cacheKey)
    if not ag then return end
    
    ag:Stop()
    ag:Play()
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
