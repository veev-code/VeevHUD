# VeevHUD - Addon Context

VeevHUD is a lightweight, WeakAuras-inspired heads-up display addon for World of Warcraft (TBC Classic / Anniversary Edition). It tracks cooldowns, buffs, debuffs, DoTs, procs, and resources with zero configuration required.

## Key Features

- **Zero-config**: Works out-of-the-box for all classes and specs
- **Spec detection**: Automatically detects player spec via LibSpellDB and shows relevant spells
- **Tag-based filtering**: Spells categorized by tags (ROTATIONAL, DPS, HEAL, TANK, CC, INTERRUPT, etc.)
- **3-row layout**: Primary (core rotation), Secondary (throughput CDs), Utility (CC/movement/defensives)
- **Aura tracking**: Shows active buff/debuff durations on icons with visual glow
- **Resource display**: Resource cost progress on icons (vertical fill or bottom bar)
- **Health/resource bars**: With heal prediction, absorb shields, predicted cost overlays, tickers
- **Proc tracker**: Horizontal proc buff icons with stack tracking and glow
- **Masque support**: Compatible with Masque for icon skinning

## File Structure

### Root
- `VeevHUD.toc` — TOC file, MIT license
- `README.md`, `CHANGELOG.md`, `TODO.md`
- `.pkgmeta` — CurseForge packaging
- `.github/workflows/release.yml` — CI release workflow

### Core (`Core/`)
- `Core.lua` — Main entry point: addon init, module registration, HUD frame, visibility, scale
- `Constants.lua` — Static values, class/power colors, timing constants, `C.DEFAULTS.profile`
- `Database.lua` — AceDB wrapper: profiles, overrides, spell config, proc config, migrations
- `Events.lua` — Centralized event system: RegisterEvent, CLEU parsing, throttled update tickers
- `Utils.lua` — Utilities: formatting, scale compensation, frame creation, bar helpers, glow wrappers
- `Layout.lua` — Vertical stacking system for HUD elements (priority-based)
- `Logger.lua` — Persistent debug logging to `VeevHUDLog` SavedVariable
- `Animations.lua` — Animation utilities: fade, scale punch (custom OnUpdate driver), alpha transitions
- `AuraCache.lua` — Efficient buff/debuff lookup caching by GUID
- `FontManager.lua` — Font registration/retrieval via LibSharedMedia-3.0
- `TextureManager.lua` — Status bar texture registration/retrieval via LibSharedMedia-3.0
- `Keybinds.lua` — Keybind detection (supports Bartender4, ElvUI, default UI, button scanning)
- `SpellUtils.lua` — Spell cooldown info, effective spell ID resolution, power cost queries
- `IconStyling.lua` — Built-in Classic Enhanced icon styling (Masque fallback)
- `SlashCommands.lua` — All `/vh` and `/veevhud` slash command handlers

### Modules (`Modules/`)
- `SpellTracker.lua` — Determines which spells to track based on spec, tags, known status, user overrides
- `AuraTracker.lua` — Tracks buffs/debuffs applied by player spells via CLEU events
- `CooldownIcons.lua` — Main icon display: rows, cooldown spirals, resource cost, glows, sorting, queued highlight
- `ResourceBar.lua` — Resource bar (mana/rage/energy) with predicted cost overlay and tickers
- `HealthBar.lua` — Health bar with heal prediction, absorb shield, and over-absorb glow overlays
- `ComboPoints.lua` — Horizontal combo point bars with activation animation
- `ProcTracker.lua` — Proc buff icons with stacks, glow, and configurable enable/disable
- `BuffReminders.lua` — Buff reminder alerts for missing class/role buffs

### Services (`Services/`)
- `FiveSecondRule.lua` — 5-second rule tracking for mana regeneration
- `TickTracker.lua` — Energy/mana tick tracking and visual ticker
- `ResourcePrediction.lua` — Resource cost prediction for casting/queued abilities
- `RangeChecker.lua` — Spell range checking for icon desaturation

### UI (`UI/`)
- `Options.lua` — AceConfig options panel (General, Icons, Bars, Rows, Spells, Profiles)
- `SpellsOptions.lua` — Standalone spell config window with drag-and-drop row assignment
- `MigrationManager.lua` — One-time migration notice system
- `ScaleMigration.lua` — UI scale auto-compensation migration notice
- `WelcomePopup.lua` — First-time welcome dialog with Discord link
- `BuffRemindersMigration.lua` — Migration notice for buff reminders feature
- `Templates.xml` — UI frame templates

### Other
- `Locales/enUS.lua` — English localization strings
- `Media/Statusbar_Clean.blp` — Bundled status bar texture
- `Fonts/Expressway-Bold.ttf` — Bundled font
- `Libs/` — Embedded libraries (Ace3 suite, LibSharedMedia, LibDualSpec, LibCustomGlow, etc.)

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

Single `eventFrame` for all events. CLEU events are parsed and dispatched by sub-event name.

### Layout System (`Core/Layout.lua`)

Vertical stacking from icon rows upward, priority-ordered:

| Priority | Element      |
|----------|-------------|
| 10       | ComboPoints  |
| 20       | EnergyTicker |
| 30       | ResourceBar  |
| 40       | HealthBar    |
| 50       | ProcTracker  |

```lua
addon.Layout:RegisterElement(name, module, priority, gap)
-- Module must implement:
function Module:GetLayoutHeight()
function Module:SetLayoutPosition(y)
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
  - Instead write: `db.textSize`, `not db.showSpark`, `db.enabled`, `addon.db.profile.appearance`
- **ALL new config keys MUST have a default** in `Constants.DEFAULTS.profile`. If a key is used in code but missing from defaults, add it — don't paper over it with a fallback at the call site.
- The only exception is **sparse per-spell config** (`spellConfig`/`procConfig`), which intentionally uses `nil` to mean "use default behavior" and `false` to mean "explicitly disabled". The `cfg.enabled ~= false` pattern is correct there.

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

-- Proc config
addon.Database:IsProcEnabled(spellID)
addon.Database:SetProcEnabled(spellID, enabled)
addon.Database:GetProcConfig()
addon.Database:ResetProcConfig()

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
- `C.CLASS_COLORS`, `C.POWER_COLORS`, `C.POWER_TYPE` IDs
- `C.COMBO_POINT_COLOR`, `C.MAX_COMBO_POINTS`

### Timing Constants
- `C.GCD_THRESHOLD` (1.5s), `C.TICK_RATE` (2.0s)
- `C.ENERGY_PER_TICK`, `C.ENERGY_PER_TICK_ADRENALINE`
- `C.FIVE_SECOND_RULE_DURATION` (5.0s)
- `C.READY_GLOW_THRESHOLD` (0.5s), `C.MANA_SPIKE_THRESHOLD` (0.10)
- `C.REFERENCE_UI_SCALE` (0.65)

### Default Profile (`C.DEFAULTS.profile`)

Top-level keys:
- `enabled`, `appearance`, `anchor`, `visibility`, `animations`, `layout`
- `resourceBar`, `healthBar`, `comboPoints`, `procTracker`
- `icons`, `spellConfig`, `procConfig`, `rows`

Notable defaults:
- `resourceBar.showPredictedCost = true`
- `healthBar.showHealPrediction = true`, `healthBar.showAbsorbs = true`, `healthBar.showOverAbsorbGlow = true`
- `icons.useOwnCooldownText = true`
- `visibility.outOfCombatAlpha = 1.0`, `visibility.hideOnFlightPath = true`
- `animations.smoothBars = true`, `animations.dimTransition = true`

## Row Configuration

Rows defined in `Constants.DEFAULTS.profile.rows`:

1. **Primary** (iconSize: 56) — Tags: `ROTATIONAL`, `CORE_ROTATION`
2. **Secondary** (iconSize: 48) — Tags: `DPS`, `HEAL`, `MAINTENANCE`, `AOE`, `EXTERNAL_DEFENSIVE`
3. **Utility** (iconSize: 42, flowLayout) — Tags: `CC_BREAK`, `INTERRUPT`, `CC_HARD`, `CC_SOFT`, `MOVEMENT`, `DEFENSIVE`, etc.

Spells assigned to the **first matching row** (no duplicates).

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

### Embedded (`Libs/`)
LibStub, CallbackHandler-1.0, AceAddon-3.0, AceEvent-3.0, AceHook-3.0, AceConsole-3.0, AceLocale-3.0, AceDB-3.0, AceDBOptions-3.0, AceGUI-3.0, AceConfig-3.0, AceGUI-3.0-SharedMediaWidgets, LibDualSpec-1.0, LibSharedMedia-3.0, LibCustomGlow-1.0

### External (OptionalDeps)
- `LibSpellDB` — Spell database (not embedded, installed separately)
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

## Code Conventions

- Modules: `local M = {}; M.addon = addon; addon:RegisterModule("Name", M)`
- Events: `addon.Events:RegisterEvent(self, "EVENT", callback)`
- Logging: `addon.Utils:LogInfo/LogDebug/LogError(source, msg)`
- User messages: `addon.Utils:Print(msg)`
- Config reads: Direct access via `addon.db.profile.X.Y` — no inline fallbacks
- Icon frames: Created as Buttons for Masque compatibility
- Bar creation: `addon.Utils:CreateStatusBar(parent, width, height)` — creates bar + background
- Layout: `addon.Layout:RegisterElement(name, module, priority, gap)`
- Animations: `addon.Animations:PlayScalePunch(frame)` (custom OnUpdate, avoids WoW Scale animation bugs)
