# VeevHUD - Addon Context

VeevHUD is a lightweight, WeakAuras-inspired heads-up display addon for World of Warcraft (TBC Classic / Anniversary Edition). It tracks cooldowns, buffs, debuffs, DoTs, procs, and resources with zero configuration required.

## Key Features

- **Zero-config**: Works out-of-the-box for all classes and specs
- **Spec detection**: Automatically detects player spec via LibSpellDB and shows relevant spells
- **Tag-based filtering**: Spells categorized by tags (ROTATIONAL, DPS, HEAL, TANK, CC, INTERRUPT, etc.)
- **3-row layout**: Primary (core rotation), Secondary (throughput CDs), Utility (CC/movement/defensives)
- **Aura tracking**: Shows active buff/debuff durations on icons with visual glow
- **Resource display**: Resource cost progress on icons (vertical fill or bottom bar)
- **Health/resource bars**: With heal prediction, predicted cost overlays, tickers
- **Trinket tracking**: Equipped trinkets shown as icons in ability rows with on-use cooldowns, proc buff tracking, ICD display, and stack counts
- **Consumable tracking**: User-configured combat potions, runes, and other mid-fight consumables with cooldown display, buff duration, and bag count overlay (per-spec)
- **Aura tracker**: Horizontal aura icons (procs, externals, custom) with stack tracking and glow
- **Masque support**: Compatible with Masque for icon skinning

## File Structure

### README.md Purpose
`README.md` doubles as the CurseForge addon description (https://www.curseforge.com/wow/addons/veevhud). It's a quick pitch to get users to try the addon — not exhaustive documentation. Keep entries short and benefit-focused. Implementation details (Kit IDs, loading screen squelch, channel selection, etc.) belong in CLAUDE.md or CHANGELOG.md, not the README.

### Root
- `VeevHUD.toc` — TOC file, MIT license
- `README.md`, `CHANGELOG.md`, `TODO.md`
- `.pkgmeta` — CurseForge packaging
- `.github/workflows/release.yml` — CI release workflow

### Core (`Core/`)
- `Core.lua` — Main entry point: addon init, module registration, HUD frame, visibility, scale
- `Constants.lua` — Static values, class/power colors, timing constants, `C.DEFAULTS.profile`
- `Database.lua` — AceDB wrapper: profiles, overrides, spell config, aura config, legacy key migrations
- `Migrations.lua` — Versioned migration system: `dataVersion` integer, popup UI, data migrations. Add new migrations by bumping `CURRENT_VERSION` and adding a numbered entry.
- `Events.lua` — Centralized event system: RegisterEvent, CLEU parsing, throttled update tickers
- `Utils.lua` — Utilities: formatting, scale compensation, frame creation, bar helpers, glow wrappers
- `Layout.lua` — Vertical stacking system for HUD elements (priority-based)
- `Logger.lua` — Persistent debug logging to `VeevHUDLog` SavedVariable
- `Animations.lua` — Animation utilities: fade, scale punch (custom OnUpdate driver), alpha transitions
- `AuraCache.lua` — Efficient buff/debuff lookup caching by GUID; tracks `recentPlayerBuffs` (50-cap) for Custom Auras UI
- `FontManager.lua` — Font registration/retrieval via LibSharedMedia-3.0
- `TextureManager.lua` — Status bar texture registration/retrieval via LibSharedMedia-3.0
- `Keybinds.lua` — Keybind detection (supports Bartender4, ElvUI, default UI, button scanning)
- `SpellUtils.lua` — Spell cooldown info, effective spell ID resolution, power cost queries
- `IconStyling.lua` — Built-in Classic Enhanced icon styling (Masque fallback)
- `SlashCommands.lua` — All `/vh` and `/veevhud` slash command handlers

### Modules (`Modules/`)
- `SpellTracker.lua` — Determines which spells to track based on spec, tags, known status, user overrides
- `AuraState.lua` — Tracks buffs/debuffs applied by player spells via CLEU events. CC_HARD and `singleTarget` spells track across all targets regardless of current target.
- `ResourceBar.lua` — Resource bar (mana/rage/energy) with predicted cost overlay and tickers
- `HealthBar.lua` — Health bar with heal prediction overlay
- `PetHealthBar.lua` — Pet health bar with heal prediction, auto-hides when no pet active
- `ComboPoints.lua` — Horizontal combo point bars with activation animation
- `TotemTracker.lua` — Shaman totem state tracker with 4 element sentinel slots, duration tracking, and one-per-element enforcement. Icons rendered within CooldownIcons rows (no standalone UI).
- `SwingBar.lua` — Auto-attack swing timer with class-specific mechanics (Hunter clip zones, dual-wield sync, Ret twist window)
- `IconRenderer.lua` — Stateless rendering service for icon frames: spirals, text, alpha transitions (with cast-feedback delay), desaturation, stacks, charges, resource cost display (bar/fill/prediction). Common rendering pipeline used by CooldownIcons and TrinketTracker via `ApplyIconVisuals` state table pattern.
- `GlowManager.lua` — Composable glow service for icon frames: proc overlay glow, aura pixel glow, permanent buff glow, ready glow state machine. Owns `activeOverlays` table and fires `OVERLAY_STATE_CHANGED` addon event when overlays change.
- `SpellAssignment.lua` — Pure spell-to-row assignment logic: exclusive BuffGroup collapse, druid form filtering, totem bar filtering, tag-based row matching, within-row sorting. Called by CooldownIcons:RebuildAllRows with tracked spells and config context, returns iconsByRow and spellAssignments.
- `IconStateEngine.lua` — Pure state computation engine (WeakAuras trigger pattern). Queries WoW APIs to produce state tables consumed by CooldownIcons. Contains: aura detection, cooldown/item CD/GCD tracking, resource prediction, visual flags, usability checks, dodge windows, timed effect timers. CooldownIcons:UpdateIconState NEVER queries WoW APIs — it reads state engine output only.
- `IconFrameFactory.lua` — Icon frame construction service: creates Button frames with all child elements (texture, cooldown spiral, text, charges, stacks, keybind, resource display, range overlay, queued highlight). Handles Masque-compatible references (.Icon, .Cooldown, .NormalTexture, .Count). Called by CooldownIcons during row creation.
- `CooldownIcons.lua` — Main icon orchestrator: event dispatch, row/icon management, dynamic layout, dynamic sorting, range indicator, queued highlight. Delegates assignment to SpellAssignment, frame construction to IconFrameFactory, state computation to IconStateEngine, rendering to IconRenderer, and glow to GlowManager.
- `CooldownPulse.lua` — Flashes a large icon in center-screen when a tracked ability comes off cooldown. Listens for `COOLDOWN_READY` addon event from GlowManager. Per-row filtering, concurrent pulses overlay simultaneously, eased fade+scale animation, frame pool. Inspired by Doom_CooldownPulse.
- `TrinketTracker.lua` — Trinket tracking: equipment detection, on-use/proc classification, ICD tracking via CLEU, icon state computation. Delegates rendering to IconRenderer and glow to GlowManager.
- `ConsumableTracker.lua` — User-configured consumable tracking (potions, runes, sappers, etc.): dynamic N slots, bag scanning for potion discovery, LibSpellDB fallback lists for potions and other consumables, cooldown display, bag count overlay. Sentinel IDs: `CONSUMABLE_SENTINEL_BASE (10000000) + itemID`. Delegates to CooldownIcons via same 3-point pattern as TrinketTracker.
- `AuraTracker.lua` — Aura icons (class procs, external buffs, custom auras) with stacks, glow, and configurable enable/disable
- `BuffReminders.lua` — Buff reminder alerts for missing class/role buffs with per-spec configuration

### Services (`Services/`)
- `FiveSecondRule.lua` — 5-second rule tracking for mana regeneration
- `TickTracker.lua` — Energy/mana tick tracking and visual ticker
- `ResourcePrediction.lua` — Resource cost prediction for casting/queued abilities
- `RangeChecker.lua` — Spell range checking for icon desaturation

### UI (`UI/`)
- `Options.lua` — AceConfig options panel (General, Ability Rows, Bars, Aura Tracker, Totem Bar, Buff Reminders, Spells, Layout, Profiles)
- `SpellsOptions.lua` — Standalone spell config window with drag-and-drop row assignment
- `WelcomePopup.lua` — First-time welcome dialog with Discord link
- `Templates.xml` — UI frame templates

### Other
- `Locales/enUS.lua` — English localization strings
- `Media/Statusbar_Clean.blp` — Bundled status bar texture
- `Fonts/Expressway-Bold.ttf` — Bundled font
- `Libs/embeds.xml` — Library loader (only tracked file in `Libs/`; library source fetched by `.pkgmeta` externals)
- `Tools/fetch-libs.sh` — Fetches all library externals into `Libs/` for local development

## Architecture

### Module Registration

```lua
local Module = {}
Module.addon = addon
addon:RegisterModule("ModuleName", Module)

-- Modules implement these lifecycle methods:
function Module:Initialize()    -- Setup, register events
function Module:CreateFrames()  -- Create UI elements
function Module:Enable()        -- Start tracking
function Module:Disable()       -- Stop tracking
function Module:Refresh()       -- Rebuild after config change
```

Retrieve modules with `addon:GetModule("ModuleName")`.

### Event System (`Core/Events.lua`)

```lua
addon.Events:RegisterEvent(owner, "EVENT_NAME", callback)
addon.Events:UnregisterEvent(owner, "EVENT_NAME")
addon.Events:RegisterCLEU(owner, "SPELL_AURA_APPLIED", callback)
addon.Events:RegisterUpdate(owner, interval, callback)  -- Throttled ticker
```

Single `eventFrame` for all events. CLEU events are parsed and dispatched by sub-event name. Update tickers use `C_Timer.NewTicker`.

CLEU callbacks receive `(owner, subEvent, cleuEventData)` where `cleuEventData` is a reusable table:
```lua
{ timestamp, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, spellID, spellName, spellSchool }
```

### Layout System (`Core/Layout.lua`)

Unified vertical stacking for all 9 HUD elements. Order is user-configurable via `layout.elementOrder`. Elements stack downward, anchored so Primary Row's top edge stays at a fixed Y offset (`PRIMARY_TOP_OFFSET = -9`).

Default element order (top to bottom):
1. Aura Tracker
2. Totem Bar
3. Health Bar
4. Pet Health Bar
5. Resource Bar
6. Combo Points
7. Swing Bar
8. Primary Row
9. Secondary Row
10. Utility Row

Per-element gaps configured via `layout.gaps` (pixels above each element, skipped for first visible).

```lua
-- Bar modules:
addon.Layout:RegisterElement(key, module)
-- Module must implement:
function Module:GetLayoutHeight()     -- returns pixel height (0 if hidden)
function Module:SetLayoutPosition(y)  -- positions at given center Y

-- Icon row modules (via closures):
addon.Layout:RegisterRowElement(key, getHeightFn, setPositionFn)
```

### Database Pattern (`Core/Database.lua`)

VeevHUD uses **AceDB-3.0** with metatable-based defaults merging:
- All defaults defined in `Constants.DEFAULTS.profile` and passed to `AceDB:New("VeevHUDDB", defaults, true)`
- AceDB guarantees `addon.db.profile.X.Y` always returns the default value for any key not user-overridden
- Only user-modified values are persisted to `VeevHUDDB` (AceDB strips matching defaults on save)
- LibDualSpec-1.0 integration for automatic per-spec profile switching

**IMPORTANT -- Config access rules:**

The DB layer is the single source of truth for all resolved config values. Application code (modules, services, UI) must never know or care what the default is — it just reads from `addon.db.profile` and gets the correct value. All default resolution happens in the DB layer via AceDB metatables. This means:

- **NEVER** use inline default fallbacks when reading config values. AceDB provides them via metatables.
  - Do NOT write: `db.textSize or 10`, `db.showSpark == false`, `db.enabled ~= false`, `addon.db.profile.appearance or {}`
  - Do NOT write: `addon.db and addon.db.profile.X.Y or 120` — this is the same anti-pattern with extra nil-guarding. By the time any module or utility code runs, `addon.db` is always initialized; `or <default>` is never needed.
  - Instead write: `db.textSize`, `not db.showSpark`, `db.enabled`, `addon.db.profile.appearance`
- **ALL new config keys MUST have a default** in `Constants.DEFAULTS.profile`. If a key is used in code but missing from defaults, add it — don't paper over it with a fallback at the call site.
- The only exception is **sparse per-spell config** (`spellConfig`/`auraConfig`), which intentionally uses `nil` to mean "use default behavior" and `false` to mean "explicitly disabled". The `cfg.enabled ~= false` pattern is correct there.

#### Database API

```lua
addon.Database:GetSettingValue(path)         -- Get current value (override or default)
addon.Database:GetDefaultValue(path)         -- Get default value
addon.Database:IsSettingOverridden(path)     -- Check if user-overridden
addon.Database:SetOverride(path, value)      -- Set override in profile
addon.Database:ClearOverride(path)           -- Reset to default

-- Spell config (sparse per-spec storage)
addon.Database:GetSpecKey()                  -- Current spec key
addon.Database:GetSpellConfig(specKey)       -- All spell config for spec
addon.Database:GetSpellConfigForSpell(spellID, specKey)
addon.Database:SetSpellConfigOverride(spellID, field, value, specKey)
addon.Database:ClearSpellConfigOverride(spellID, field, specKey)
addon.Database:IsSpellConfigModified(spellID, specKey)

-- Aura config
addon.Database:IsAuraEnabled(spellID)
addon.Database:SetAuraEnabled(spellID, enabled)
addon.Database:GetAuraConfig()
addon.Database:ResetAuraConfig()
addon.Database:GetAuraSourceFilter(spellID, auraSource)   -- Sparse: MINOR_EXTERNAL defaults "any", other externals "notOwn"
addon.Database:SetAuraSourceFilter(spellID, filter, auraSource)

-- Row settings
addon.Database:IsRowSettingEnabled(settingValue, rowIndex)  -- C.ROW_SETTING logic
```

### Spell Configuration

Per-spec spell config stored at `VeevHUDDB.overrides.spellConfig[specKey][spellID]`:
```lua
{
    enabled = true/false,  -- Force show/hide
    rowIndex = 1/2/3,      -- Override which row
    order = number,        -- Custom sort order
}
```

### SpellUtils (`Core/SpellUtils.lua`)

Note: SpellUtils populates `addon.Utils`, not a separate namespace.

```lua
addon.Utils:GetSpellCooldown(spellID)   -- Returns remaining, duration, enabled, startTime
addon.Utils:IsOnRealCooldown(remaining, duration)
addon.Utils:IsOnGCD(remaining, duration)
addon.Utils:IsOffCooldown(remaining, duration)
addon.Utils:IsSpellOnRealCooldown(spellID) -- Convenience: fetches cooldown + checks
addon.Utils:IsSpellOnGCD(spellID)
addon.Utils:IsSpellOffCooldown(spellID)
addon.Utils:GetEffectiveSpellID(spellID) -- Action bar rank or highest known rank
addon.Utils:GetSpellPowerInfo(spellID)   -- Returns {cost, currentPower, maxPower, powerType, powerColor}
addon.Utils:GetSpellTexture(spellID)
addon.Utils:FindSpellOnActionBar(spellID) -- Finds actual rank on action bar
```

## Constants (`Core/Constants.lua`)

### Key Constants
- `C.ROW_SETTING` — `NONE`, `PRIMARY`, `PRIMARY_SECONDARY`, `SECONDARY_UTILITY`, `UTILITY`, `ALL`
- `C.RESOURCE_DISPLAY_MODE` — `FILL`, `BAR`, `PREDICTION`
- `C.TICKER_STYLE` — `BAR`, `SPARK`
- `C.GLOW_MODE` — `ONCE`, `ALWAYS`
- `C.TEXT_FORMAT` — `CURRENT`, `PERCENT`, `BOTH`, `NONE`
- `C.AURA_SOURCE_ANY` (`"any"`), `C.AURA_SOURCE_OWN` (`"own"`), `C.AURA_SOURCE_NOT_OWN` (`"notOwn"`) — Aura source filters for AuraTracker
- `C.AURA_SORT_ORDER` — `FIXED` (registration order), `FIFO` (activation order), `REMAINING` (least duration first)
- `C.CLASS_COLORS`, `C.POWER_COLORS`, `C.POWER_TYPE` IDs
- `C.COMBO_POINT_COLOR`, `C.MAX_COMBO_POINTS`
- `C.GetDruidForm()` — Position-independent druid form detection via spell ID (returns `"CASTER"`, `"BEAR"`, `"CAT"`, `"AQUATIC"`, `"TRAVEL"`, `"MOONKIN"`)
- `C.TRINKET_SLOT_13` (9999913), `C.TRINKET_SLOT_14` (9999914) — Sentinel spell IDs for trinket slots. Used as numeric keys in `spellConfig` without colliding with real spell IDs.

### Timing Constants
- `C.GCD_THRESHOLD` (1.5s), `C.TICK_RATE` (2.0s)
- `C.ENERGY_PER_TICK`, `C.ENERGY_PER_TICK_ADRENALINE`
- `C.FIVE_SECOND_RULE_DURATION` (5.0s)
- `C.READY_GLOW_THRESHOLD` (0.5s), `C.MANA_SPIKE_THRESHOLD` (0.10)
- `C.REFERENCE_UI_SCALE` (0.65)

### Default Profile (`C.DEFAULTS.profile`)

Top-level keys:
- `enabled`, `appearance`, `anchor`, `visibility`, `animations`, `layout`
- `resourceBar`, `healthBar`, `comboPoints`, `auraTracker`, `totemBar`, `swingBar`
- `icons`, `buffReminders`, `spellConfig`, `auraConfig`, `rows`

Notable defaults:
- `resourceBar.showPredictedCost = true`
- `healthBar.showHealPrediction = true`
- `icons.useOwnCooldownText = true`
- `visibility.outOfCombatAlpha = 1.0`, `visibility.hideOnFlightPath = true`
- `animations.smoothBars = true`, `animations.dimTransition = true`

## Row Configuration

Rows defined in `Constants.DEFAULTS.profile.rows`. Spells assigned to the **first matching row** (no duplicates).

1. **Primary** (iconSize: 56) — Tags: `ROTATIONAL`, `CORE_ROTATION`
2. **Secondary** (iconSize: 48) — Tags: `DPS`, `HEAL`, `MAINTENANCE`, `AOE`, `EXTERNAL_DEFENSIVE`, `RESOURCE`
3. **Utility** (iconSize: 42, flowLayout) — Tags: `CC_BREAK`, `INTERRUPT`, `CC_HARD`, `CC_SOFT`, `MOVEMENT`, `DEFENSIVE`, `PERSONAL_DEFENSIVE`, etc.

### Default Config Design Philosophy

The default spell config should produce sensible out-of-box defaults for every class/spec with zero user configuration. The guiding principles:

**Primary Row** — Core rotation abilities used on cooldown every fight. Must have a meaningful cooldown (not spammable fillers). The "heartbeat" of your spec's gameplay loop.

**Secondary Row** — Throughput cooldowns that boost output when used at the right time: offensive CDs, healing CDs, resource generation CDs, maintenance buffs/debuffs. For **healer specs**, this row should contain abilities castable on allies (your raid-healing toolkit). Self-only heals/defensives do not belong here.

**Utility Row** — Combat utility that doesn't directly increase throughput: personal defensives (self-only survival CDs), crowd control, interrupts, dispels, movement abilities.

**Excluded from tracking** — Spammable fillers (no cooldown, mana-gated only), out-of-combat abilities, long-duration buffs (30+ min). These are tagged `FILLER`, `OUT_OF_COMBAT`, or `LONG_BUFF` in LibSpellDB. **Exception**: rage/energy-gated abilities without cooldowns are NOT fillers — they are `ROTATIONAL` because resource prediction on the icon is valuable (e.g., Slam, Sinister Strike, Shred).

**Spec relevance** — Spells should only appear for specs that realistically use them in their default role. Damage abilities should not default-show for healer specs. Niche/situational cross-role spells belong in the Available pool for manual enabling.

For tagging guidelines (FILLER vs ROTATIONAL, PERSONAL_DEFENSIVE vs HEAL, specs/talent rules), see **LibSpellDB CLAUDE.md → Tagging Guidelines**.

## Key Global Variables

- `_G.VeevHUD` / `addon` — Main addon table
- `VeevHUDDB` — SavedVariables (AceDB database)
- `VeevHUDLog` — SavedVariables (debug log, only when debug enabled)
- `addon.db` — AceDB instance (`addon.db.profile`, `addon.db.global`)
- `addon.modules` — Module registry
- `addon.hudFrame` — Main HUD container frame
- `addon.playerClass` — Detected player class token
- `addon.playerSpec` — Detected player spec string
- `addon.LibSpellDB` — Reference to LibSpellDB library

## Dependencies

All libraries are fetched via `.pkgmeta` externals at release time (by `BigWigsMods/packager@v2`). They are NOT committed to git — `Libs/*/` is gitignored.

**Local dev workflow:** Run `bash Tools/fetch-libs.sh` to populate `Libs/`, test in-game, then release in the same session to ensure version consistency.

### Libraries (`Libs/`)
LibStub, CallbackHandler-1.0, AceAddon-3.0, AceEvent-3.0, AceHook-3.0, AceConsole-3.0, AceLocale-3.0, AceDB-3.0, AceDBOptions-3.0, AceGUI-3.0, AceConfig-3.0, AceGUI-3.0-SharedMediaWidgets, LibDualSpec-1.0, LibSharedMedia-3.0, LibCustomGlow-1.0, LibSpellDB

### Optional
- `Masque` — Icon skinning (optional)

## Slash Commands

`/vh` or `/veevhud`:
- `help` — Command list
- `reset` — Reset current profile
- `toggle` — Toggle enabled state
- `config` / `options` — Open AceConfig panel
- `log [n]` — Print recent log entries (default: 20)
- `clearlog` — Clear VeevHUDLog
- `debug` — Toggle debug mode
- `scan` / `rescan` — Force SpellTracker rescan
- `spec` — Show detected spec
- `spells` — List tracked spells
- `cd <id/name>` — Debug spell cooldown
- `icon <id>` — Debug icon state
- `usable <id/name>` — Debug IsUsableSpell
- `overlay <id>` — Debug spell activation overlay
- `check <id>` — Diagnose why a spell isn't showing
- `layout` — Print layout debug info

## Debug Logging

VeevHUD has built-in persistent debug logging that makes it easy to diagnose timing-sensitive issues (tick tracking, predictions, form changes, etc.) without needing to reproduce them live.

### Workflow
1. **Enable debug mode**: `/vh debug` in-game
2. **Play and reproduce the issue** (e.g., shift into cat form, wait for energy prediction)
3. **Reload UI**: `/reload` — this flushes logs to SavedVariables
4. **Read the log file**: `WTF/Account/<account>/SavedVariables/VeevHUD.lua` — the `VeevHUDLog` table contains timestamped entries

### How to add debug logging
- **In services** (TickTracker, ResourcePrediction): Use the local `TickLog()`/`DebugLog()` helpers already defined at the top of each file. These only fire when debug mode is on.
- **In modules**: Call `addon.Utils:LogDebug(source, message)` directly.
- **Deduplication**: For logs inside hot paths (per-frame updates), use a `lastLogKey` pattern to avoid flooding — only log when inputs change. See `ResourcePrediction.lastEnergyPredLogKey` for an example.
- All logs go through `Core/Logger.lua` which gates on `debugMode` and writes to `VeevHUDLog` SavedVariable.

### Key log prefixes
- `[TickTracker] TICK` — Energy/mana tick observed (with interval)
- `[TickTracker] PHANTOM` — Inferred tick when at full energy
- `[TickTracker] FORM` — Druid shapeshift transitions
- `[EPRED]` — Energy prediction calculations (spell, energy, needed, ticks, timing)
- `[ESYNC]` — Energy tick detected by ResourcePrediction before TickTracker
- `[PRED]` — Mana prediction calculations
- `[COST]` — Spell cost info when prediction is needed
- `[SYNC]` — Mana tick detected by ResourcePrediction before TickTracker

## Code Conventions

- Modules: `local M = {}; M.addon = addon; addon:RegisterModule("Name", M)`
- Events: `addon.Events:RegisterEvent(self, "EVENT", callback)`
- Logging: `addon.Utils:LogInfo/LogDebug/LogError(source, msg)`
- User messages: `addon.Utils:Print(msg)`
- Config reads: Direct access via `addon.db.profile.X.Y` — no inline fallbacks
- Icon frames: Created as Buttons for Masque compatibility
- Bar creation: `addon.Utils:CreateStatusBar(parent, width, height)` — creates bar + background
- Bar helpers: `CreateBarBorder(bar, skipTop)`, `FormatBarText(value, maxValue, percent, format, numberFormat)`, `SmoothBarValue(current, target, speed)` → newValue, reachedTarget
- Glow helpers: `ShowButtonGlow(frame, color)` / `HideButtonGlow(frame)`, `ShowPixelGlow(frame, color, key, ...)` / `HidePixelGlow(frame, key)` — via LibCustomGlow
- Icon wrapper: `CreateWrapperIcon(parent, buttonName, width, height)` — decouples positioning from visual effects
- Cooldown text: `ConfigureCooldownText(cooldown, hideExternal)` — OmniCC/ElvUI integration
- Layout: `addon.Layout:RegisterElement(key, module)` or `addon.Layout:RegisterRowElement(key, getHeightFn, setPositionFn)`
- Animations: `addon.Animations:PlayScalePunch(frame)` (custom OnUpdate driver, avoids WoW Scale animation CooldownFrame bug)
- Animations: `addon.Animations:CreateSlideAnimator(container, speed)` — centered horizontal icon reordering with ease-out lerp
- Animations: `addon.Animations:TransitionAlpha(frame, targetAlpha, speed, callback)` — smooth alpha fade via OnUpdate
- **No hardcoded spell IDs** — VeevHUD must never contain hardcoded spell IDs. All spell knowledge (IDs, durations, tags, cooldowns, proc info, etc.) lives in LibSpellDB. VeevHUD queries LibSpellDB at runtime via its API. If a spell needs special handling, add the appropriate tag or field in LibSpellDB and query it from VeevHUD — don't embed spell IDs in VeevHUD code. **Exception**: When LibSpellDB has no applicable generic query, a hardcoded spell ID is acceptable as a last resort (e.g., `IsPlayerSpell(34120)` for Steady Shot detection in SwingBar). **Never use English spell names** as identifiers — they break localization. Preference order: (1) generic LibSpellDB query by tag/field, (2) hardcoded spell ID with a comment, (3) never spell name strings.
