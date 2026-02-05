--[[
    VeevHUD - Constants
    Static values and default settings
]]

local ADDON_NAME, addon = ...

addon.Constants = {}
local C = addon.Constants

-------------------------------------------------------------------------------
-- Addon Info
-------------------------------------------------------------------------------

C.ADDON_NAME = ADDON_NAME
-- Version is set later in Core.lua after API is available
C.VERSION = nil

-- URLs (matches TOC metadata)
C.DISCORD_URL = "https://discord.gg/HuSXTa5XNq"

-------------------------------------------------------------------------------
-- Class Names
-------------------------------------------------------------------------------

C.CLASS = {
    WARRIOR = "WARRIOR",
    PALADIN = "PALADIN",
    HUNTER = "HUNTER",
    ROGUE = "ROGUE",
    PRIEST = "PRIEST",
    SHAMAN = "SHAMAN",
    MAGE = "MAGE",
    WARLOCK = "WARLOCK",
    DRUID = "DRUID",
}

-------------------------------------------------------------------------------
-- Row Setting Values (for per-row feature toggles)
-------------------------------------------------------------------------------

-- Valid values for settings like showCooldownTextOn, dimOnCooldown, etc.
-- Used with Database:IsRowSettingEnabled(settingValue, rowIndex)
C.ROW_SETTING = {
    NONE = "none",                          -- Disabled on all rows
    PRIMARY = "primary",                    -- Primary row only (row 1)
    PRIMARY_SECONDARY = "primary_secondary", -- Primary + Secondary (rows 1-2)
    SECONDARY_UTILITY = "secondary_utility", -- Secondary + Utility (rows 2+)
    UTILITY = "utility",                    -- Utility only (rows 3+)
    ALL = "all",                            -- All rows
}

-------------------------------------------------------------------------------
-- Resource Display Mode Values
-------------------------------------------------------------------------------

-- Valid values for icons.resourceDisplayMode setting
C.RESOURCE_DISPLAY_MODE = {
    FILL = "fill",           -- Vertical fill from top
    BAR = "bar",             -- Horizontal bar at bottom
    PREDICTION = "prediction", -- Extends cooldown spiral to show time until affordable
}

-- Valid values for resourceBar.energyTicker.style setting
C.TICKER_STYLE = {
    BAR = "bar",     -- Separate bar below resource bar
    SPARK = "spark", -- Large spark overlay on resource bar
}

-- Valid values for icons.readyGlowMode setting
C.GLOW_MODE = {
    ONCE = "once",     -- Only glow once per cooldown cycle
    ALWAYS = "always", -- Glow every time ability becomes ready
}

-- Valid values for healthBar.textFormat and resourceBar.textFormat
C.TEXT_FORMAT = {
    CURRENT = "current", -- Show current value (e.g., "3256")
    PERCENT = "percent", -- Show percentage (e.g., "71%")
    BOTH = "both",       -- Show both (e.g., "3256 (71%)")
    NONE = "none",       -- Hide text
}

-- Druid shapeshift form indices (returned by GetShapeshiftForm())
C.DRUID_FORM = {
    CASTER = 0,
    BEAR = 1,
    AQUATIC = 2,
    CAT = 3,
    TRAVEL = 4,
    MOONKIN = 5,
}

-------------------------------------------------------------------------------
-- Class Colors (Classic values)
-------------------------------------------------------------------------------

C.CLASS_COLORS = {
    WARRIOR     = { r = 0.78, g = 0.61, b = 0.43 },
    PALADIN     = { r = 0.96, g = 0.55, b = 0.73 },
    HUNTER      = { r = 0.67, g = 0.83, b = 0.45 },
    ROGUE       = { r = 1.00, g = 0.96, b = 0.41 },
    PRIEST      = { r = 1.00, g = 1.00, b = 1.00 },
    SHAMAN      = { r = 0.00, g = 0.44, b = 0.87 },
    MAGE        = { r = 0.41, g = 0.80, b = 0.94 },
    WARLOCK     = { r = 0.58, g = 0.51, b = 0.79 },
    DRUID       = { r = 1.00, g = 0.49, b = 0.04 },
}

-------------------------------------------------------------------------------
-- Power/Resource Colors
-------------------------------------------------------------------------------

C.POWER_COLORS = {
    MANA        = { r = 0.00, g = 0.00, b = 1.00 },
    RAGE        = { r = 1.00, g = 0.00, b = 0.00 },
    ENERGY      = { r = 1.00, g = 1.00, b = 0.00 },
    FOCUS       = { r = 1.00, g = 0.50, b = 0.25 },
    RUNIC_POWER = { r = 0.00, g = 0.82, b = 1.00 },
}

-- Power type IDs (Classic)
C.POWER_TYPE = {
    MANA    = 0,
    RAGE    = 1,
    FOCUS   = 2,
    ENERGY  = 3,
}

-- Combo point color (yellow-gold to match energy theme)
C.COMBO_POINT_COLOR = { r = 1.0, g = 0.82, b = 0.0 }

-- Max combo points (TBC Classic = 5)
C.MAX_COMBO_POINTS = 5

-------------------------------------------------------------------------------
-- UI Colors
-------------------------------------------------------------------------------

C.COLORS = {
    TEXT = { r = 1.0, g = 0.906, b = 0.745 },  -- #ffe7be warm cream/gold for cooldown/stack text
}

-------------------------------------------------------------------------------
-- Timing Constants
-------------------------------------------------------------------------------

-- Global Cooldown threshold - cooldowns at or below this duration are considered GCD
-- Used to distinguish between "on GCD" (brief lockout) vs "on real cooldown" (ability CD)
C.GCD_THRESHOLD = 1.5

-- Reference UI scale - the UI scale VeevHUD was designed at
-- Used to auto-compensate so the HUD appears the same size regardless of player's UI scale
-- At 65% UI scale, icons look as intended. At 100%, we scale down to match.
C.REFERENCE_UI_SCALE = 0.65

-- Resource regeneration tick rate (both energy and mana tick every 2 seconds)
C.TICK_RATE = 2.0

-- Energy regeneration per tick (20 base, 40 with Adrenaline Rush)
C.ENERGY_PER_TICK = 20
C.ENERGY_PER_TICK_ADRENALINE = 40

-- Five Second Rule duration (spirit-based mana regen suppressed after spending mana)
C.FIVE_SECOND_RULE_DURATION = 5.0

-- Ready glow "almost ready" threshold (triggers glow when this much time remains)
C.READY_GLOW_THRESHOLD = 0.5

-- Mana spike threshold - gains above this % of max mana are filtered (potions, life tap)
C.MANA_SPIKE_THRESHOLD = 0.10

-------------------------------------------------------------------------------
-- Spell IDs
-------------------------------------------------------------------------------

-- Adrenaline Rush (Rogue) - doubles energy regeneration
C.SPELL_ID_ADRENALINE_RUSH = 13750

-------------------------------------------------------------------------------
-- Default Settings
-------------------------------------------------------------------------------

C.DEFAULTS = {
    profile = {
        enabled = true,

        -- Global appearance settings
        appearance = {
            font = "Expressway, Bold",  -- Font name (registered with LibSharedMedia)
        },

        -- Global positioning anchor (centered, below character)
        -- Note: x is always 0 (centered), y is configurable via settings
        anchor = {
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = -84,  -- Default vertical offset
        },

        -- Visibility conditions
        visibility = {
            hideOnFlightPath = true, -- Hide completely when on taxi/flight
            outOfCombatAlpha = 1.0,  -- Alpha multiplier when not in combat (1.0 = full, 0.5 = half)
        },
        
        -- Global animation settings
        animations = {
            smoothBars = true,           -- Smooth animation for health bar, resource bar, and resource cost display
            dimTransition = true,        -- Smooth alpha transition for dim on cooldown (vs instant)
        },

        -- Layout settings (spacing between stacked bars)
        layout = {
            iconRowGap = 2,  -- Gap between icon row top and first bar's bottom
        },

        -- Resource bar settings (mana/rage/energy)
        resourceBar = {
            enabled = true,
            width = 230,  -- Width of 4 core icons (4×56 + 3×2 spacing)
            height = 14,
            offsetY = 0,
            textFormat = "current",  -- "current", "percent", "both", "none"
            textSize = 11,
            smoothing = true,
            classColored = false,  -- Use power color by default
            showGradient = true,  -- Gradient overlay (darker at bottom)
            -- Spark settings
            showSpark = true,
            sparkWidth = 12,
            sparkOverflow = 8,  -- How much taller than bar (for glow effect)
            sparkHideFullEmpty = true,
            -- Energy ticker settings (shows progress to next energy tick)
            -- enabled: master toggle for the feature
            -- style: "bar" = separate bar below resource bar, "spark" = large spark overlay on resource bar
            energyTicker = {
                enabled = true,
                style = "spark",      -- "bar" or "spark"
                showAtFullEnergy = true, -- Keep showing ticker at full energy (useful for timing openers)
                -- Bar style settings
                height = 3,           -- Height of the ticker bar
                offsetY = -1,         -- Gap between resource bar bottom and ticker top (negative = below)
                showGradient = true,  -- Match resource bar gradient style
                -- Spark style settings
                sparkWidth = 6,       -- Width of the spark overlay (thinner = more elegant)
                sparkHeight = 1.8,    -- Height multiplier relative to bar height
            },
            -- Mana tick indicator (shows progress to next mana tick)
            -- enabled: master toggle for the feature
            -- style: "outside5sr" = only outside 5-second rule, "nextfulltick" = intelligent countdown
            manaTicker = {
                enabled = true,
                style = "nextfulltick", -- "outside5sr" or "nextfulltick"
                sparkWidth = 12,      -- Width of the spark overlay (larger for visibility)
                sparkHeight = 2.0,    -- Height multiplier relative to bar height
            },
        },

        -- Health bar settings
        healthBar = {
            enabled = true,
            width = 230,  -- Width of 4 core icons (4×56 + 3×2 spacing)
            height = 10,
            offsetY = 12,  -- Position so bars touch (resourceBar.height/2 + healthBar.height/2)
            textFormat = "percent",  -- "current", "percent", "both", "none"
            textSize = 10,
            smoothing = true,
            classColored = true,
            showGradient = true,
        },

        -- Combo points settings (for Rogues and Feral Druids)
        comboPoints = {
            enabled = true,  -- Auto-enabled only for classes that use combo points
            width = 230,     -- Total width (matches resource bar by default)
            barHeight = 6,
            barSpacing = 2,  -- Horizontal spacing between bars
            offsetY = 2,     -- Gap between resource bar bottom and combo points top
            showGradient = true,
        },

        -- Proc/Buff tracker (important buffs like Enrage, Flurry)
        procTracker = {
            enabled = true,
            iconSize = 26,
            iconSpacing = 6,  -- spacing between icons
            offsetY = 31,     -- calculated dynamically in CreateFrames
            gapAboveHealthBar = 6,  -- gap between health bar and proc icons
            showDuration = true,  -- show remaining time text on procs
            showInactiveIcons = false,  -- Only show when active (not exposed in UI)
            inactiveAlpha = 0.4,
            activeGlow = true,  -- Show animated pixel glow around active procs
            backdropGlowIntensity = 0.25,  -- 0 = disabled, higher = more visible (max ~0.8)
            backdropGlowSize = 2.2,  -- Multiplier for glow size relative to icon
            backdropGlowColor = {1.0, 0.7, 0.35},  -- Warm orange-gold (alpha controlled by intensity)
            slideAnimation = true,  -- Smooth sliding when procs appear/disappear
        },

        -- Icon display settings (defaults, rows can override)
        icons = {
            enabled = true,
            iconSize = 52,          -- Default icon size (per-row overrides in rows config)
            iconAspectRatio = 1.0,  -- Width:Height ratio (1.0 = square, 1.33 = 4:3 wide)
            iconZoom = 0.20,        -- How much to zoom into icon textures (0 = none, 0.20 = 10% cropped from each edge)
            iconSpacing = 1,        -- Horizontal spacing between icons
            rowSpacing = 1,         -- Vertical spacing between rows
            primarySecondaryGap = 0, -- Extra gap between primary and secondary rows
            sectionGap = 16,        -- Extra gap before utility/misc section
            scale = 1.0,            -- Global scale multiplier
            
            -- Alpha settings
            readyAlpha = 1.0,
            cooldownAlpha = 0.3,
            desaturateNoResources = true,
            
            -- Cooldown display
            -- Row selection: "none" = disabled, "primary" = Primary only,
            -- "primary_secondary" = Primary + Secondary, "all" = all rows
            showCooldownTextOn = "all",   -- Which rows show cooldown text
            showCooldownSpiralOn = "all", -- Which rows show cooldown spiral
            cooldownBlingRows = "all",     -- Which rows show sparkle effect when cooldown finishes
            
            -- GCD display: which rows show the global cooldown spinner
            -- "none" = disabled, "primary" = Primary Row only, 
            -- "primary_secondary" = Primary + Secondary, "all" = everywhere
            showGCDOn = "primary",
            
            -- Dim on cooldown: which rows fade to cooldownAlpha when on cooldown
            -- "none" = all rows stay full alpha, "utility" = Utility only,
            -- "secondary_utility" = Secondary + Utility, "all" = all rows dim
            dimOnCooldown = "secondary_utility",
            
            -- Resource cost display (for rage/energy classes)
            -- Mode: "fill" = vertical fill from top, "bar" = horizontal bar at bottom,
            --       "prediction" = extends cooldown spiral to show max(cd, time_until_affordable),
            --                      falls back to vertical fill if prediction was wrong
            -- Rows: "none" = disabled, "primary"/"primary_secondary"/"all" = which rows show it
            resourceDisplayMode = "prediction",
            resourceDisplayRows = "all", -- Which rows show resource cost display
            resourceBarHeight = 4,       -- Height of horizontal bar (Option A)
            resourceFillAlpha = 0.6,     -- Alpha of fill overlay (Option B)
            
            -- Cast feedback: scale punch when ability is used
            -- Rows: "none" = disabled, "primary"/"primary_secondary"/"all" = which rows show it
            castFeedbackRows = "all",     -- Which rows show cast feedback animation
            castFeedbackScale = 1.1,      -- How much to scale up (1.1 = 110%)
            
            -- Aura tracking: show buff/debuff active state on icons
            -- When enabled, icons show the active aura (with duration) before showing cooldown
            showAuraTracking = true,
            
            -- Targettarget support: when targeting enemy, check their target for helpful effects
            -- Useful for healers with targettarget macros (e.g., targeting boss, healing tank)
            -- Default OFF since most players don't use targettarget workflows
            auraTargettargetSupport = false,
            
            -- Ready glow: shows a proc-style glow when ability becomes ready
            -- Triggers: 1) <1s remaining on CD with enough resources
            --           2) Just got enough resources after CD finished
            -- Rows: "none" = disabled, "primary"/"primary_secondary"/"all" = which rows show it
            -- Mode: "once" = once per cooldown, "always" = every time ready
            readyGlowRows = "all",        -- Which rows show ready glow (none = disabled)
            readyGlowMode = "once",
            readyGlowDuration = 1.0,      -- Duration to show glow when triggered
            
            -- Dynamic sorting by time remaining: which rows dynamically reorder by actionable time
            -- "none" = static order (priority-based, icons don't move)
            -- "primary" = Primary Row only, "primary_secondary" = Primary + Secondary
            -- Note: Utility rows are not supported (they can span multiple sub-rows)
            -- The "actionable time" is max(cooldown_remaining, aura_remaining)
            -- Ready abilities (actionable time = 0) are sorted to the left
            dynamicSortRows = "none",
            dynamicSortAnimation = true,  -- Smooth sliding animation when icons reorder
            
            -- Range indicator: red overlay when target is out of spell range
            -- "none" = disabled, "primary" = Primary only, "primary_secondary" = Primary + Secondary, "all" = all rows
            -- Uses throttled updates (0.1s) to minimize performance impact
            showRangeIndicator = "all",
            
            -- Keybind text: show the keyboard shortcut for each ability (like default action bars)
            -- "none" = disabled, "primary" = Primary only, "primary_secondary" = Primary + Secondary, "all" = all rows
            -- Scans action bars to find where each spell is placed and displays the keybind
            -- Text appears in bottom-right (stack text uses top-right)
            showKeybindText = "none",  -- Off by default
            keybindTextSize = 12,  -- Font size in pixels for keybind text
        },
        
        -- Per-spec spell configuration (sparse storage)
        -- Format: spellConfig[specKey][spellID] = { enabled, rowIndex, order }
        -- specKey = "CLASS_SPEC" (e.g., "WARRIOR_FURY")
        -- Only modified values are stored; nil = use default
        spellConfig = {},

        -- Row definitions (order matters - top to bottom)
        -- Each row shows spells matching these LibSpellDB tags
        -- Spells are assigned to the FIRST matching row (no duplicates)
        rows = {
            {
                name = "Primary Row",
                -- Primary: ROTATIONAL abilities for DPS/Healing/Tanking
                tags = {"ROTATIONAL", "CORE_ROTATION"},
                maxIcons = 20,       -- No practical limit, grows horizontally
                enabled = true,
                iconSize = 56,       -- Larger core icons (like retail)
            },
            {
                name = "Secondary Row",
                -- Secondary: Throughput abilities (DPS/healing CDs, maintenance debuffs, AoE-exclusive)
                -- Matches DPS or HEAL role tags, plus MAINTENANCE for tank upkeep
                -- EXTERNAL_DEFENSIVE included: healer external CDs are their "throughput" equivalent
                -- Self-only defensives (DEFENSIVE without EXTERNAL_DEFENSIVE) fall through to Utility
                tags = {"DPS", "HEAL", "MAINTENANCE", "AOE", "EXTERNAL_DEFENSIVE",
                        -- Legacy tags for backward compatibility
                        "SITUATIONAL", "OFFENSIVE_CD", "OFFENSIVE_CD_MINOR", "HEALING_CD", "RESOURCE"},
                maxIcons = 20,       -- No practical limit, grows horizontally
                enabled = true,
                iconSize = 48,
            },
            {
                -- Combined utility group - flows into multiple rows automatically
                name = "Utility",
                tags = {"CC_BREAK", "CC_IMMUNITY", "INTERRUPT", "CC_HARD", "CC_SOFT", "SILENCE", 
                        "MOVEMENT", "MOVEMENT_GAP_CLOSE", "MOVEMENT_ESCAPE",
                        "TAUNT", "DEFENSIVE", "PERSONAL_DEFENSIVE", "EXTERNAL_DEFENSIVE", "IMMUNITY", "DAMAGE_REDUCTION",
                        "UTILITY", "DISPEL_MAGIC", "DISPEL_POISON", "DISPEL_DISEASE"},
                maxIcons = 24,       -- Allow many icons, will wrap
                iconsPerRow = 6,     -- Target icons per row
                enabled = true,
                iconSize = 42,
                flowLayout = true,   -- Enable multi-row flow layout
            },
        },
    },
}

-------------------------------------------------------------------------------
-- Texture Paths
-------------------------------------------------------------------------------

C.TEXTURES = {
    STATUSBAR = "Interface\\AddOns\\VeevHUD\\Media\\Statusbar_Clean",
}

-------------------------------------------------------------------------------
-- Fonts
-------------------------------------------------------------------------------

-- Bundled font path (used as fallback when LibSharedMedia is unavailable)
-- Name matches SharedMediaAdditionalFonts convention to avoid duplicates
C.BUNDLED_FONT = "Interface\\AddOns\\VeevHUD\\Fonts\\Expressway-Bold.ttf"
C.BUNDLED_FONT_NAME = "Expressway, Bold"
