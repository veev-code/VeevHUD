# Shadowhawk Feedback — Implementation Plan

Source: Discord feedback from Shadowhawk (2026-03-18)

Work through these items one at a time, clearing context between each. Reference this file at the start of each session.

---

## Item 4: Comma Number Format Not Working (Bug)
**Files:** `VeevHUD/Core/Utils.lua` (~line 34), bar modules (HealthBar, ResourceBar)
**Problem:** User reports comma mode behaves identically to full text.
**Code review:** `FormatNumber` calls `BreakUpLargeNumbers(math.floor(num))` for comma mode. This is a WoW API function. For values under 10,000, `BreakUpLargeNumbers` returns the same as `tostring()` (no comma needed). So comma and full only differ at 10k+ values. If the user's health/mana is under 10k, they'd look identical.
**Investigate:** Test in-game with a character that has 10k+ health/mana. If it works there, this is "working as intended" and just needs a tooltip clarification. If it doesn't work even at 10k+, then `BreakUpLargeNumbers` may behave differently in Anniversary Edition.
**Possible fix:** If WAI, update the option description to clarify behavior. If broken, implement manual comma formatting as fallback.

## Item 5: Bar Outline Rendering at Non-Integer Scale (Bug/Limitation)
**Status:** WoW engine limitation — partially mitigated, not fully fixable.
**What was done:** Added `DisablePixelSnap` (`SetSnapToPixelGrid(false)` + `SetTexelSnappingBias(0)`) to all textures via `Utils:CreateTexture` and `Utils:DisablePixelSnap` utilities. This improves rendering for icons, gradients, sparks, overlays, and all non-StatusBar visuals.
**What remains:** Bar borders (1px edge textures around StatusBar frames) still render at slightly inconsistent thickness at non-integer scales. The root cause is WoW's `StatusBar` widget — its internal fill texture is positioned by the engine, and at fractional scales the fill edge overlaps border edges asymmetrically.
**Approaches tried:** PixelUtil pixel-aligned edges (uniform but creates layout gaps between stacked bars due to semi-transparent backgrounds), inside borders (gaps), frame level changes (border bleeds onto adjacent bars), SetBackdrop (renders incorrectly at HUD's effective scale), solid background fill (breaks bar transparency).
**Future fix:** Replace `StatusBar` with custom masked texture fills (how WeakAuras does it) for full rendering control. Large scope — revisit if border quality becomes a higher priority.

## Item 6: Text Outline Quality at Small Sizes (Feature Request)
**Files:** All modules using `SetFont()` with "OUTLINE" flag, `VeevHUD/Core/Constants.lua` (defaults), `VeevHUD/UI/Options.lua`
**Problem:** At small text sizes, WoW's "OUTLINE" flag produces rough/pixelated outlines. At non-100% scale, outline thickness varies per-edge.
**Feature request:** Add text outline style option: Outline / Shadow / None.
**Approach:**
  - Add `icons.textOutline` setting to Constants defaults ("OUTLINE", "SHADOW", "NONE")
  - Add similar settings for bars (`healthBar.textOutline`, `resourceBar.textOutline`)
  - "OUTLINE" = current behavior (SetFont flag)
  - "SHADOW" = no outline flag, use `SetShadowOffset(1, -1)` + `SetShadowColor(0,0,0,1)` instead
  - "NONE" = no outline, no shadow
  - Update all `SetFont()` calls to use the configured outline style
  - For stacks/reagent text specifically, consider a separate outline toggle
**Note:** Text outline quality is fundamentally a WoW renderer issue. Shadow mode is the best workaround for small text.

---

## Completion Tracking

| # | Item | Status |
|---|------|--------|
| 4 | Comma number format | Done |
| 5 | Bar outline at scale | Partial (WoW limitation) |
| 6 | Text outline options | Done |
