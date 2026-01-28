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

-------------------------------------------------------------------------------
-- UI Colors
-------------------------------------------------------------------------------

C.COLORS = {
    TEXT = { r = 1.0, g = 0.906, b = 0.745 },  -- #ffe7be warm cream/gold for cooldown/stack text
}

-------------------------------------------------------------------------------
-- Default Icon Sizes
-------------------------------------------------------------------------------

C.ICON_SIZE = {
    LARGE   = 40,
    MEDIUM  = 32,
    SMALL   = 24,
    TINY    = 20,
}

-------------------------------------------------------------------------------
-- Default Settings
-------------------------------------------------------------------------------

C.DEFAULTS = {
    profile = {
        enabled = true,

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
            smoothBars = true,  -- Smooth animation for health bar, resource bar, and resource cost display
        },

        -- Resource bar settings (mana/rage/energy)
        resourceBar = {
            enabled = true,
            width = 230,  -- Width of 4 core icons (4×56 + 3×2 spacing)
            height = 14,
            offsetY = 0,
            showText = true,
            textSize = 11,
            textFormat = "current",  -- "current", "percent", "both", "none"
            smoothing = true,
            classColored = false,  -- Use power color by default
            showGradient = true,  -- Gradient overlay (darker at bottom)
            -- Spark settings
            showSpark = true,
            sparkWidth = 12,
            sparkOverflow = 8,  -- How much taller than bar (for glow effect)
            sparkHideFullEmpty = true,
        },

        -- Health bar settings
        healthBar = {
            enabled = true,
            width = 230,  -- Width of 4 core icons (4×56 + 3×2 spacing)
            height = 10,
            offsetY = 12,  -- Position so bars touch (resourceBar.height/2 + healthBar.height/2)
            showText = true,
            textSize = 10,
            textFormat = "percent",
            smoothing = true,
            classColored = true,
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
            showCooldownText = true,
            showCooldownSpiral = true,  -- Show the cooldown spiral overlay
            
            -- GCD display: which rows show the global cooldown spinner
            -- "primary" = Primary Row only, "primary_secondary" = Primary + Secondary, "all" = everywhere
            showGCDOn = "primary",
            
            -- Dim on cooldown: which rows fade to cooldownAlpha when on cooldown
            -- "none" = all rows stay full alpha, "utility" = Utility only,
            -- "secondary_utility" = Secondary + Utility, "all" = all rows dim
            dimOnCooldown = "secondary_utility",
            
            -- Resource cost display (for rage/energy classes)
            -- "none" = disabled, "bar" = horizontal bar at bottom, "fill" = vertical fill from bottom
            resourceDisplayMode = "fill",
            resourceBarHeight = 4,       -- Height of horizontal bar (Option A)
            resourceFillAlpha = 0.6,     -- Alpha of fill overlay (Option B)
            
            -- Cast feedback: scale punch when ability is used
            castFeedback = true,
            castFeedbackScale = 1.1,  -- How much to scale up (1.1 = 110%)
            
            -- Aura tracking: show buff/debuff active state on icons
            -- When enabled, icons show the active aura (with duration) before showing cooldown
            showAuraTracking = true,
            
            -- Ready glow: shows a proc-style glow when ability becomes ready
            -- Triggers: 1) <1s remaining on CD with enough resources
            --           2) Just got enough resources after CD finished
            -- Mode: "once" = once per cooldown, "always" = every time ready, "disabled" = off
            readyGlowMode = "once",
            readyGlowDuration = 1.0,     -- Duration to show glow when triggered
            
            -- Per-spell overrides for icons (legacy, use top-level spellOverrides)
            spellOverrides = {},
        },

        -- Global spell overrides: spellID -> true (force show) / false (force hide)
        -- Legacy - prefer spellConfig for new overrides
        spellOverrides = {},
        
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
                -- Uses composite tag matching: must have ROTATIONAL + (DPS or HEAL or TANK)
                tags = {"ROTATIONAL", "CORE_ROTATION"},  -- CORE_ROTATION for legacy compat
                compositeTags = {  -- New: requires ROTATIONAL + at least one role tag
                    required = {"ROTATIONAL"},
                    anyOf = {"DPS", "HEAL", "TANK"},
                },
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

        -- Proc/buff tracking row (glowing when active)
        procIcons = {
            enabled = true,
            iconSize = 32,
            iconSpacing = 3,
            maxIcons = 6,
            offsetY = 40,  -- Above the resource bar
            glowEnabled = true,
        },
    },
}

-------------------------------------------------------------------------------
-- Texture Paths
-------------------------------------------------------------------------------

C.TEXTURES = {
    STATUSBAR       = "Interface\\AddOns\\VeevHUD\\Media\\Statusbar_Clean",
    STATUSBAR_FLAT  = "Interface\\Buttons\\WHITE8X8",
    STATUSBAR_DEFAULT = "Interface\\TargetingFrame\\UI-StatusBar",
    BORDER          = "Interface\\Tooltips\\UI-Tooltip-Border",
    BACKDROP        = "Interface\\Tooltips\\UI-Tooltip-Background",
    GLOW            = "Interface\\SpellActivationOverlay\\IconAlert",
}

-------------------------------------------------------------------------------
-- Fonts
-------------------------------------------------------------------------------

C.FONTS = {
    DEFAULT     = "Fonts\\FRIZQT__.TTF",
    NUMBER      = "Interface\\AddOns\\VeevHUD\\Fonts\\Expressway-Bold.ttf",
    BOLD        = "Interface\\AddOns\\VeevHUD\\Fonts\\Expressway-Bold.ttf",
}
