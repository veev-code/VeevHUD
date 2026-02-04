# VeevHUD Changelog

## [1.0.35] - 2026-02-04

### Fixed
- **Spell reordering** — Fixed drag-and-drop to allow dropping spells at the end of a category
- **Ready glow for lockout spells** — Ready glow now correctly triggers when a target lockout debuff (like Forbearance) is about to expire, even though the spell appears unusable during the lockout

## [1.0.34] - 2026-02-04

### Added
- **Cooldown Finish Sparkle** — WoW's native sparkle/bling effect now plays when cooldowns finish (per-row configurable, defaults to all rows). Note: Also triggers on GCD finish, matching default action bar behavior.
- **Smooth Dim Transition** — Icons now smoothly fade to 30% alpha when going on cooldown, synced with cast feedback animation timing. Can be disabled in Animations settings.

### Changed
- **More row options** — All row-based dropdowns now offer 6 choices: None, Primary Only, Primary + Secondary, All Rows, Secondary + Utility, Utility Only. This allows more flexible configurations like usable glow on primary row but sparkle on secondary/utility rows.

### Fixed
- **Prediction spiral cleanup** — Resource prediction spirals now clear immediately when you gain enough resources (e.g., zoning and gaining full mana)
- **Aura spiral cleanup** — Buff/debuff spirals now clear immediately when switching targets (instead of lingering from the previous target)
- **Dim alpha on reload** — Icons on cooldown now correctly show 30% alpha immediately after /reload (previously showed full alpha until state changed)

## [1.0.33] - 2026-02-04

### Changed
- **Migration popup improvements** — Now shows for all users affected by UI scale auto-compensation (not just those who manually scaled down). Message explains whether your HUD is now smaller or if manual settings are stacking.
- Migration popups are now skipped for brand new users (they get the correct behavior from the start)

## [1.0.32] - 2026-02-04

### Added
- **UI Scale Auto-Compensation** — VeevHUD now automatically adjusts for your in-game UI Scale setting, so the HUD looks the same size whether you use 65% or 100% UI scale. No more oversized icons at default settings!
- **Migration popup** — If you previously adjusted Global Scale to compensate for a high UI scale, a one-time popup will offer to reset it to 100%
- **Reusable MigrationManager** — Framework for future migration notices when addon behavior changes

### Changed
- Popups now appear 30% from the top of the screen (instead of center) to avoid covering the HUD
- Improved popup title centering

### LibSpellDB Updates
- New `auraTarget` system for explicit buff tracking targets (self, ally, pet, none)
- Added `GetAuraTarget()` API function

## [1.0.31] - 2026-02-03

### Fixed
- **Aura cache invalidation** — Fixed an issue where auras could fail to update when the same player was referenced by multiple unit tokens (e.g., "party1" and "targettarget"). Cache is now keyed by GUID for correct invalidation.

### LibSpellDB Updates
- `IsSelfOnly()` now correctly identifies `HAS_BUFF` and `CC_IMMUNITY` tagged spells as abilities that can target others

## [1.0.30] - 2026-02-01

### Changed
- **Range indicator during cooldown** — The out-of-range indicator now shows while abilities are on cooldown, as long as you have the resources to use them. This gives you a heads-up on positioning while waiting for the cooldown to finish.
- **Cleaner visual priority** — When you lack resources for an ability, the grey/resource indicators take priority and the range indicator is hidden. This prevents overlapping visual states and keeps feedback clear.

### Fixed
- **Range indicator after cooldown ends** — Fixed an issue where the range indicator wouldn't appear immediately when a spell like Bloodthirst came off cooldown (was incorrectly suppressed by the spell's healing buff)

## [1.0.29] - 2026-02-01

### Fixed
- **Config visibility** — HUD now stays visible at full opacity when the options panel is open, so visibility settings (Out of Combat Opacity, Hide on Flight Path) don't make it hard to configure

## [1.0.28] - 2026-01-31

### Added
- **Range Indicator** — Out-of-range spells now display a desaturated icon with a red range indicator at the bottom
- Smooth fade animations for range indicator transitions

### Changed
- **Improved buff tracking** — Rotational spells now track auras on your current target, while cooldown-only spells always show in the HUD
- Code cleanup: removed unused RangeChecker API methods

### LibSpellDB Updates
- New `IsSelfOnly()` and `IsRotational()` API functions for smarter buff tracking behavior

## [1.0.27] - 2026-01-31

### Fixed
- **AoE CC tracking** — When a CC effect breaks on one target (e.g., Psychic Scream), icons now correctly continue tracking remaining affected targets
- **Spell Configuration panel** — Utility row positioning now updates correctly when spells are reordered
- Various bug fixes and code cleanup

### Changed
- **Major refactor** — Extracted modules and removed ~1700 lines of unused/dead code
- All spell IDs now normalize to canonical (base) ID for consistent tracking across ranks

### LibSpellDB Updates
- Added Priest Chastise as soft CC for all specs
- Fixed duplicate spell ID warnings and nil access bugs

## [1.0.26] - 2026-01-31

### Changed
- **New Layout System** — Completely refactored how HUD elements (combo points, resource bar, health bar, proc tracker) are positioned
  - Elements now register with a central layout manager instead of calculating positions based on other modules
  - Automatic repositioning when any element's visibility changes (e.g., Druid entering/leaving Cat Form)
  - Cleaner architecture: modules no longer need to know about each other's positions
  - New `/vh layout` debug command to inspect element positions
- **Icon Row Gap setting** — New slider in Appearance section to control the gap between the icon row and the first bar above it

### Fixed
- Discord release notifications now use the description field (supports up to 3500 characters) instead of embed fields (which had a 1024 character limit)

## [1.0.25] - 2026-01-31

### Added
- **Font customization** — New global font setting lets you change the font used for all HUD text (cooldowns, stack counts, health/resource values, proc durations)
  - Integrates with LibSharedMedia-3.0 to discover fonts from other addons
  - Scrollable dropdown with font preview (each font rendered in its own typeface)
  - Fonts update instantly without requiring a UI reload
  - Default: Expressway, Bold (bundled with VeevHUD)
- **New FontManager module** (`Core/FontManager.lua`) — Centralizes font registration and utilities

### Changed
- **Text display options** — Replaced "Show Text" checkbox with a "Text Display" dropdown for Health Bar and Resource Bar
  - Options: Current Value, Percent, Both, None
  - More intuitive than separate toggle + format settings
- Font setting placed in Appearance section (after Vertical Offset)

### Removed
- Cleaned up unused font constants (`FONTS.DEFAULT`, `FONTS.BOLD`)

## [1.0.24] - 2026-01-30

### Fixed
- **Blood Fury GCD tracking bug** — Orc racial spell power variants (33697, 33702) no longer briefly show as "ready" when triggering a GCD while on cooldown
- **Spell ID discovery** — Now correctly tracks the actual spell ID from your spellbook instead of the library spell ID (fixes issues where class-specific spell variants weren't tracked properly)

### Changed
- Options UI consistency improvements and better user-friendliness

### LibSpellDB Updates
- Added all Orc Blood Fury variants (20572, 33697, 33702) for proper class-specific tracking
- Added Fire Nova Totem (all ranks)

## [1.0.23] - 2026-01-30

### LibSpellDB Updates
- Hemorrhage now shows cooldown display instead of debuff tracking (more useful for rotation)

## [1.0.22] - 2026-01-30

### Added
- **Resource Timer** — A new resource cost display mode that extends the cooldown spiral to show when you'll actually be able to cast, factoring in both cooldown AND resource regeneration
  - Icons show `max(cooldown_remaining, time_until_affordable)` as a unified countdown
  - **Energy**: Highly accurate tick-aware predictions (2-second ticks), accounts for Adrenaline Rush
  - **Mana**: Tick-aware with 5-second rule tracking, measures in-combat vs passive regen rates separately
  - **Rage**: Falls back to vertical fill (rage generation is unpredictable)
  - If prediction is wrong (resources spent mid-countdown), automatically falls back to deterministic vertical fill
  - Configure via "Resource Cost Style" → "Resource Timer" in settings
- **Mana Tick Indicator** for mana classes (Mage, Priest, Warlock, Paladin, Druid, Shaman, Hunter)
  - Shows a spark overlay on the resource bar indicating progress toward the next mana tick
  - **"Outside 5SR"** mode: Shows the 2-second tick cycle only when regenerating at full spirit rate
  - **"Next Full Tick"** mode (recommended): Intelligently combines 5-second rule AND tick timing — calculates exactly when your first full-rate tick will arrive and shows a seamless countdown. Cast right after it completes to maximize mana efficiency.
- New core modules: `TickTracker.lua`, `FiveSecondRule.lua`, `ResourcePrediction.lua`

### Changed
- Default energy ticker style changed to "Spark" (overlay on resource bar)
- Default resource cost display changed to "Resource Timer" (prediction mode)
- Increased debug log buffer from 200 to 500 entries

## [1.0.21] - 2026-01-29

### Added
- **Energy Tick Indicator** for Rogues and Druids
  - Shows progress toward the next energy tick (energy regenerates every 2 seconds)
  - Three styles: "Ticker Bar" (thin bar below resource bar), "Spark" (overlay on resource bar), or "Disabled"
  - Configurable in Options under Resource Bar section

### Fixed
- Spells Configuration panel now refreshes correctly when opened before initialization completes
- GitHub release workflow now correctly extracts changelog for v-prefixed tags

## [1.0.20] - 2026-01-30

### Added
- Discord release notifications now include changelog summary

### Changed
- **Refactored aura tracking** for LibSpellDB's new `triggersAuras` array structure
- Aura priority system: CC_HARD > CC_SOFT/ROOT > array order for abilities with multiple effects
- All spell lookups now normalize to canonical ID for consistent tracking across ranks

### Fixed
- Rampage stack count now displays correctly (was broken due to rank ID mismatch)
- Hamstring debuff tracking (same-ID auras now handled properly)
- Removed dead code (`GetLongestAuraRemaining`)

### LibSpellDB Updates
- **New `triggersAuras` array** for multi-aura spells (Pounce stun + bleed, Wyvern Sting sleep + DoT, etc.)
- **Comprehensive TBC spell ranks** added for all 9 classes from wago.tools data
- New trigger mappings: Scatter Shot, Wyvern Sting DoTs, Pounce Bleeds, Nature's Grasp roots, Misdirection
- New spells: Mage Cone of Cold, Dragon's Breath, Flamestrike, Blizzard, Slow; Rogue Backstab
- New APIs: `GetAuraInfo()`, `GetAuraSourceSpellID()`, `GetAuraTags()`, `AuraHasTag()`

## [1.0.19] - 2026-01-29

### Added
- **Combo Points Display** for Rogues and Feral Druids
  - 5 horizontal bars displayed below the resource bar
  - Rogues: Always visible when you have a target
  - Druids: Only visible while in Cat Form
  - Subtle scale animation when gaining combo points
  - Configurable width, bar height, and spacing in Options panel
- Shared bar utilities (CreateBarBorder, CreateBarGradient, FormatBarText, SmoothBarValue) extracted to Utils
- Shared glow utilities (GetLibCustomGlow, ShowButtonGlow, HideButtonGlow, ShowPixelGlow, HidePixelGlow) for cleaner module code
- Shared ConfigureCooldownText helper for OmniCC/ElvUI compatibility

### Changed
- Health bar, resource bar, and proc tracker now shift upward when combo points are visible
- Code consolidation reduces duplicate code across modules

## [1.0.18] - 2026-01-29

### Fixed
- **Targettarget Aura Support setting was never being read** - The setting path was incorrect, so enabling it had no effect. Now works correctly for healers using targettarget macros.
- Fixed Spell Configuration panel causing CPU spikes every second while open (replaced aggressive polling with OnShow refresh)
- Added `targettarget` to unit GUID lookup for accurate aura duration detection

## [1.0.17] - 2026-01-29

### Added
- **Smart Aura Target Resolution**: Aura tracking now intelligently selects the most relevant target
  - Hard CC (Polymorph, Fear, stuns) tracks across all targets
  - Hostile debuffs (DoTs) track only your current target
  - Helpful effects (buffs, heals) track appropriate friendly target
  - Soft CC (snares like Hamstring) follows normal debuff rules, not CC rules
- **Targettarget Aura Support** option: When targeting an enemy, shows your helpful effects on their target instead of yourself (useful for healers with targettarget macros)
- Completely rewrote README with improved structure and comprehensive documentation

### Fixed
- Lockout debuffs (Weakened Soul, Forbearance) now check the same target as the spell they restrict
- Fixed "permanent buff" glow appearing on debuffs (like Vampiric Embrace) when target was removed
- Fixed ready glow persisting after removing target while aura was active

### LibSpellDB Updates
- Vampiric Embrace now correctly tagged as debuff (was incorrectly tagged as buff)

## [1.0.16] - 2026-01-28

### Changed
- Dynamic Sort now deprioritizes conditional spells (Execute, Victory Rush, etc.) when they're not usable
- Unusable conditional spells sort after spells with cooldowns up to 60s, rather than always appearing first
- Welcome popup now shows `/vh` command earlier for faster onboarding

### Fixed
- Spell Configuration panel now correctly detects current spec when opened after a dual spec switch

## [1.0.15] - 2026-01-28

### Changed
- Target lockout debuffs (Forbearance, Weakened Soul) now show the **most restrictive** time remaining
- Example: Divine Shield (5min CD) with Forbearance (1min) shows the 5min CD since that's more restrictive
- Example: Avenging Wrath (ready) with Forbearance (1min) shows the 1min lockout

### LibSpellDB Updates
- Added Forbearance lockout tracking for Paladin immunity spells (Divine Shield, Divine Protection, Blessing of Protection, Avenging Wrath)

## [1.0.14] - 2026-01-28

### Added
- Dynamic Sort (Time Remaining) option for Primary and Secondary rows
- Icons reorder by "actionable time" (least time remaining first) so the ability needing attention soonest is always on the left
- Useful for DOT classes (see which debuff is expiring) and cooldown-heavy rotations

### LibSpellDB Updates
- **Critical Fix**: Bundled LibSpellDB now properly loads spell data. Previously, users who only downloaded VeevHUD from CurseForge had zero spells displayed because the embedded library wasn't loading its data files.

## [1.0.13] - 2026-01-28

### Fixed
- Out-of-combat alpha animation no longer gets stuck at very low values when fading to 0%

## [1.0.12] - 2026-01-28

### Added
- Icon Zoom setting (0-50%) to crop icon edges, similar to WeakAuras' zoom feature
- First-time welcome popup with Discord invite for new users
- Stack count text now renders above cooldown spiral for better visibility

### Changed
- Stack count text moved to top-right corner (consistent with proc tracker icons)
- Support link updated to Discord server (https://discord.gg/HuSXTa5XNq)

## [1.0.11] - 2026-01-28

### Added
- Icon Aspect Ratio setting for more compact HUD (Square, Compact 4:3, Ultra Compact 2:1)
- Icons shrink vertically while width stays the same, cropping textures proportionally
- Proc Tracker now supports tracking target debuffs (e.g., Deep Wounds)

### Fixed
- Spec detection now properly updates after respeccing at NPC
- Mortal Strike now prioritizes cooldown display over debuff tracking

### Changed
- Prompt for UI reload when changing aspect ratio with Masque installed (Masque requires reload for dynamic resizing)

### LibSpellDB Updates
- Added Deep Wounds proc tracking for Warriors (target debuff)
- Added `ignoreAura` flag for spells where cooldown tracking is preferred over debuff tracking

## [1.0.10] - 2026-01-28

### Added
- Out of Combat Alpha setting to fade the entire HUD when not in combat
- Smooth fade animation when entering/leaving combat

## [1.0.9] - 2026-01-28

### Added
- Backdrop glow effect for active procs (soft halo behind icons)
- Animated pixel glow for active proc borders
- Smooth sliding animation when procs appear/disappear
- New Proc Tracker options: Icon Spacing, Gap Above Health Bar, Show Duration Text, Show Edge Glow, Backdrop Glow Intensity, Slide Animation

### Changed
- Proc icons now 26px by default (increased from 20px) for better visibility
- Duration text now displayed in center, stack count in top-right corner
- Duration text enabled by default
- Text renders above cooldown spiral for better readability
- Extracted shared text color (#ffe7be) to centralized constant

## [1.0.8] - 2026-01-27

### Changed
- Add buff/debuff caching to reduce aura scanning overhead (event-driven invalidation)

### LibSpellDB Updates
- Added `lib.Specs` constants for type-safe spec tagging
- All spells now have explicit `specs` field for better spec filtering

## [1.0.7] - 2026-01-27

### Added
- Built-in "Classic Enhanced" icon styling when Masque is not installed (uses same WoW game textures as Masque skin)

### Fixed
- Resource cost display now correctly uses action bar spell rank instead of base rank
- Mana abilities now properly desaturate when player lacks sufficient mana
- Improved caching for spell rank lookups with event-driven invalidation

### LibSpellDB Updates
- Added `GetAllRankIDs()` and `GetHighestKnownRank()` utility functions for accurate spell rank detection

## [1.0.6] - 2026-01-27

### Fixed
- Version display now dynamically reads from TOC file
- Updated changelog for CurseForge

## [1.0.5] - 2026-01-27

### Added
- Configurable "Dim on Cooldown" dropdown setting (None / Utility / Secondary+Utility / All)
- Right-click to reset any setting to default (with tooltip hint)

### Fixed
- Icon alpha now properly inherits to all child elements (resource fills, cooldown spirals, charges text)
- Aura glow respects icon alpha when Ready Alpha is reduced
- Version display now reads from TOC file

## [1.0.4] - 2026-01-26

### Fixed
- Debug logs only saved to SavedVariables when debug mode is enabled

## [1.0.3] - 2026-01-25

### Changed
- HUD is now fully click-through (no longer intercepts mouse clicks)
- Removed HUD dragging functionality (position controlled via Y-offset setting)

## [1.0.2] - 2026-01-25

### Added
- Secondary Row Gap setting (gap between Primary and Secondary rows)
- Ready glow now only initiates when player is in combat

### Fixed
- Charge Stun and Intercept Stun debuff tracking for Warriors

## [1.0.1] - 2026-01-24

### Fixed
- CurseForge publishing configuration for TBC Classic

## [1.0.0] - 2025-01-24

### Added
- Initial release
- Cooldown tracking with visual indicators
- Buff/debuff tracking with duration display
- Resource bar with cost preview
- Health bar with class coloring
- Proc tracking area for important buffs
- Ready glow for abilities coming off cooldown
- Cast feedback animations
- Full options panel with live-updating settings
- Support for all TBC Classic classes
- Masque skin compatibility
