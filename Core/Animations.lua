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
-- helpers adjust offsets to keep the effective visual position fixed.
--
-- Uses saved base offsets (captured at punch start) so that external
-- repositioning during a punch (e.g., layout refresh, icon reordering)
-- cannot corrupt the final position.

-- Apply scale while keeping the frame's effective visual position fixed.
-- Math: to achieve effective position P at scale S, set offset = P / S.
local function ApplyPunchScale(frame, newScale, state)
    if not state or not state.basePoint then
        frame:SetScale(newScale)
        return
    end
    frame:SetScale(newScale)
    frame:ClearAllPoints()
    frame:SetPoint(state.basePoint, state.baseRelativeTo, state.baseRelativePoint,
        state.baseXOfs / newScale, state.baseYOfs / newScale)
end

-- Reset frame to scale 1 and restore the saved base offset.
local function ResetPunchScale(frame, state)
    frame:SetScale(1)
    if state and state.basePoint then
        frame:ClearAllPoints()
        frame:SetPoint(state.basePoint, state.baseRelativeTo, state.baseRelativePoint,
            state.baseXOfs, state.baseYOfs)
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
                ResetPunchScale(frame, state)
                self.active[frame] = nil
            else
                -- Quadratic ease-out: fast start, smooth deceleration
                local eased = progress * (2 - progress)
                local s = state.targetScale
                ApplyPunchScale(frame, s + (1 - s) * eased, state)
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
    local oldState = punchDriver.active[frame]
    if oldState then
        ResetPunchScale(frame, oldState)
        punchDriver.active[frame] = nil
    end

    -- Also stop any legacy AnimationGroup-based animations (cleanup after code update)
    cacheKey = cacheKey or "scalePunch"
    if frame[cacheKey] and type(frame[cacheKey]) == "table" and frame[cacheKey].Stop then
        frame[cacheKey]:Stop()
        frame[cacheKey] = nil
    end

    -- Save the base anchor before scaling so we can always restore correctly,
    -- even if layout repositions the frame during the animation.
    local point, relativeTo, relativePoint, xOfs, yOfs = frame:GetPoint(1)

    -- Register for animated scale-down (must exist before ApplyPunchScale)
    local state = {
        phase = "up",
        elapsed = 0,
        targetScale = scale,
        upDur = 0.12,   -- Hold at peak scale
        downDur = 0.20,  -- Smooth return to normal
        basePoint = point,
        baseRelativeTo = relativeTo,
        baseRelativePoint = relativePoint,
        baseXOfs = xOfs or 0,
        baseYOfs = yOfs or 0,
    }
    punchDriver.active[frame] = state

    -- Phase 1: Immediately scale up (the visual "punch")
    ApplyPunchScale(frame, scale, state)

    punchDriver:Show()
end

-- Stop any active scale punch on a frame (immediately restore scale)
function Animations:StopScalePunch(frame)
    if not frame then return end

    local state = punchDriver.active[frame]
    if state then
        ResetPunchScale(frame, state)
        punchDriver.active[frame] = nil
    end
end

-- Check if frame has an active punch animation (for grace period logic)
function Animations:IsPunchActive(frame)
    return frame and punchDriver.active[frame] ~= nil
end

-- Update the saved base offset for an active punch.
-- Call this after layout repositions a frame so the punch animates
-- at the new position instead of snapping back to the old one.
function Animations:UpdatePunchBase(frame)
    local state = punchDriver.active[frame]
    if not state then return end

    local point, relativeTo, relativePoint, xOfs, yOfs = frame:GetPoint(1)
    if not point then return end

    -- Layout just set the raw intended position; adopt it as the new base
    state.basePoint = point
    state.baseRelativeTo = relativeTo
    state.baseRelativePoint = relativePoint
    state.baseXOfs = xOfs or 0
    state.baseYOfs = yOfs or 0

    -- Re-apply scale compensation at the updated position
    local currentScale = frame:GetScale()
    if currentScale ~= 1 then
        frame:SetPoint(point, relativeTo, relativePoint,
            (xOfs or 0) / currentScale, (yOfs or 0) / currentScale)
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

-------------------------------------------------------------------------------
-- Slide Animator (smooth horizontal repositioning)
-------------------------------------------------------------------------------
-- Creates reusable slide animators for centered horizontal icon layouts.
-- Child frames smoothly lerp from their current X offset to a target X offset
-- using an ease-out feel (same approach as the original AuraTracker slide).
--
-- Uses a shared driver frame (like punchDriver) so the animator never touches
-- the container's OnUpdate script.
-------------------------------------------------------------------------------

local slideDriver = CreateFrame("Frame")
slideDriver.active = {}  -- [animator] = true
slideDriver:Hide()

slideDriver:SetScript("OnUpdate", function(self, elapsed)
    local hasActive = false

    for animator in pairs(self.active) do
        local settled = animator:_OnUpdate(elapsed)
        if settled then
            self.active[animator] = nil
        else
            hasActive = true
        end
    end

    if not hasActive then
        self:Hide()
    end
end)

-- Create a slide animator bound to a container frame.
-- Parameters:
--   container: The parent frame that child icons are anchored to (CENTER)
--   speed: Lerp speed multiplier (default 12, higher = faster)
function Animations:CreateSlideAnimator(container, speed)
    local animator = {
        container = container,
        speed = speed or 12,
        snapThreshold = 0.5,
        running = false,
        frames = {},  -- [frame] = true; frames with active slide state
    }

    -- Compute centered positions and set slide targets for all frames.
    -- Parameters:
    --   frames: array of visible child frames (ipairs order = left to right)
    --   itemWidth: pixel width of each item
    --   spacing: pixel gap between items
    --   animate: if true, lerp to position; if false, snap instantly
    function animator:LayoutFrames(frames, itemWidth, spacing, animate)
        local count = #frames
        if count == 0 then return end

        local totalWidth = (count * itemWidth) + ((count - 1) * spacing)

        for i, frame in ipairs(frames) do
            local targetX = (i - 1) * (itemWidth + spacing) - (totalWidth / 2) + (itemWidth / 2)

            if animate then
                if not frame._slideCurrentX then
                    -- First time: snap to target (no stale position to slide from)
                    frame._slideCurrentX = targetX
                    if not punchDriver.active[frame] then
                        frame:ClearAllPoints()
                        frame:SetPoint("CENTER", self.container, "CENTER", targetX, 0)
                    end
                end
                frame._slideTargetX = targetX
                self.frames[frame] = true
            else
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", self.container, "CENTER", targetX, 0)
                frame._slideCurrentX = targetX
                frame._slideTargetX = targetX
                self.frames[frame] = nil
            end
        end

        if animate and not self.running then
            self.running = true
            slideDriver.active[self] = true
            slideDriver:Show()
        end
    end

    -- Clear slide state on a frame (call when the frame is hidden or recycled).
    function animator:ResetFrame(frame)
        frame._slideCurrentX = nil
        frame._slideTargetX = nil
        self.frames[frame] = nil
    end

    -- Snap all tracked frames to their targets and stop animating.
    function animator:Stop()
        for frame in pairs(self.frames) do
            if frame._slideCurrentX and frame._slideTargetX
               and frame._slideCurrentX ~= frame._slideTargetX then
                frame._slideCurrentX = frame._slideTargetX
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", self.container, "CENTER", frame._slideTargetX, 0)
            end
        end
        self.running = false
        slideDriver.active[self] = nil
    end

    -- Internal: called by slideDriver each frame. Returns true when all settled.
    function animator:_OnUpdate(elapsed)
        local allSettled = true

        for frame in pairs(self.frames) do
            if frame:IsShown() and frame._slideCurrentX and frame._slideTargetX then
                -- If a punch animation is active on this frame, the punch owns
                -- SetPoint (it applies scale compensation). We still update
                -- _slideCurrentX so the position is correct when the punch ends.
                local hasPunch = punchDriver.active[frame]

                local diff = frame._slideTargetX - frame._slideCurrentX

                if math.abs(diff) < self.snapThreshold then
                    if frame._slideCurrentX ~= frame._slideTargetX then
                        frame._slideCurrentX = frame._slideTargetX
                        if not hasPunch then
                            frame:ClearAllPoints()
                            frame:SetPoint("CENTER", self.container, "CENTER", frame._slideTargetX, 0)
                        end
                    end
                    -- Keep running while punch is active so we can position
                    -- the frame correctly once the punch finishes
                    if hasPunch then
                        allSettled = false
                    end
                else
                    allSettled = false
                    local move = diff * math.min(1, elapsed * self.speed)
                    frame._slideCurrentX = frame._slideCurrentX + move
                    if not hasPunch then
                        frame:ClearAllPoints()
                        frame:SetPoint("CENTER", self.container, "CENTER", frame._slideCurrentX, 0)
                    end
                end
            end
        end

        if allSettled then
            self.running = false
        end

        return allSettled
    end

    return animator
end

return Animations
