# VeevHUD Changelog

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
