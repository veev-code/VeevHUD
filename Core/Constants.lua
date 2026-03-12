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
-- Aura Source Filter Modes (WeakAuras-style own/not-own filtering)
-------------------------------------------------------------------------------

C.AURA_SOURCE_ANY = "any"          -- Show regardless of who cast it
C.AURA_SOURCE_OWN = "own"          -- Only show if cast by the player
C.AURA_SOURCE_NOT_OWN = "notOwn"   -- Only show if cast by someone else

-- Aura Tracker sort order
C.AURA_SORT_ORDER = {
    FIXED = "fixed",          -- Registration order (class procs → externals → custom)
    FIFO = "fifo",            -- First activated leftmost, newest rightmost
    REMAINING = "remaining",  -- Least remaining duration leftmost
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

-- Internal glow mode constants (used by UpdateReadyGlow logic)
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

-- Valid values for cooldownPulse.animationIn / animationOut
C.PULSE_EFFECT = {
    GROW = "grow",     -- Size increases during this phase
    SHRINK = "shrink", -- Size decreases during this phase
    NONE = "none",     -- No size change (pure alpha)
}

-- Druid form detection via spell ID (position-independent)
-- GetShapeshiftForm() returns the stance bar index, which shifts when forms
-- aren't trained (e.g., missing Aquatic Form moves Cat from slot 3 to slot 2).
-- We use GetShapeshiftFormInfo() to identify forms by spell ID instead.
-- Form-type mapping is sourced from LibSpellDB (formType field on SHAPESHIFT spells).
do
    local formLookup  -- spellID -> formType string, built lazily from LibSpellDB

    local function BuildFormLookup()
        formLookup = {}
        local LibSpellDB = LibStub and LibStub("LibSpellDB-1.0", true)
        if LibSpellDB then
            local shapeshifts = LibSpellDB:GetSpellsByClassAndTag("DRUID", "SHAPESHIFT")
            for spellID, data in pairs(shapeshifts) do
                if data.formType then
                    formLookup[spellID] = data.formType
                    if data.ranks then
                        for _, rankID in ipairs(data.ranks) do
                            formLookup[rankID] = data.formType
                        end
                    end
                end
            end
        end
    end

    --- Returns the current druid form as a string: "CASTER", "BEAR", "CAT",
    --- "AQUATIC", "TRAVEL", or "MOONKIN". Works regardless of which forms
    --- are trained or their position on the shapeshift bar.
    function C.GetDruidForm()
        if not formLookup then BuildFormLookup() end
        local formIndex = GetShapeshiftForm()
        if formIndex == 0 then return "CASTER" end

        local _, _, _, spellID = GetShapeshiftFormInfo(formIndex)
        return formLookup[spellID] or "CASTER"
    end
end

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
-- Set to 2.0 rather than 1.5 because wand auto-attacks report GetSpellCooldown duration
-- equal to the wand's attack speed (typically 1.5-1.9s), which must not be treated as a
-- real cooldown. No TBC ability has a real cooldown between 1.5s and 5s.
C.GCD_THRESHOLD = 2.0

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

-- Ready glow "almost ready" threshold fallback (see db.readyGlowThreshold for configurable value)
C.READY_GLOW_THRESHOLD = 0.5

-- Mana spike threshold - gains above this % of max mana are filtered (potions, life tap)
C.MANA_SPIKE_THRESHOLD = 0.10

-- Trinket slot sentinel IDs (used as spellID keys for trinket tracking)
-- These are far above any real WoW spell ID and serve as unique identifiers for equipment slots
C.TRINKET_SLOT_13 = 9999913  -- Trinket 1
C.TRINKET_SLOT_14 = 9999914  -- Trinket 2

-- Totem element slot sentinel IDs (used as spellID keys for totem element tracking)
-- Each represents one of the four totem elements (Shaman only)
C.TOTEM_SLOT_FIRE  = 9999901
C.TOTEM_SLOT_EARTH = 9999902
C.TOTEM_SLOT_WATER = 9999903
C.TOTEM_SLOT_AIR   = 9999904

-- Stance/form indicator sentinel ID (Warriors, Druids, Paladins)
C.STANCE_INDICATOR = 9999905

-------------------------------------------------------------------------------
-- Spell IDs
-------------------------------------------------------------------------------

-- Adrenaline Rush (Rogue) - doubles energy regeneration
C.SPELL_ID_ADRENALINE_RUSH = 13750

-------------------------------------------------------------------------------
-- Layout Element Keys
-------------------------------------------------------------------------------

-- All HUD elements that participate in vertical layout ordering.
-- Keys are used in layout.elementOrder and layout.gaps.
C.LAYOUT_ELEMENTS = {
    auraTracker  = "Aura Tracker",
    auxiliaryRow  = "Auxiliary Row",
    healthBar    = "Health Bar",
    petHealthBar = "Pet Health Bar",
    resourceBar  = "Resource Bar",
    comboPoints  = "Combo Points",
    swingBar     = "Swing Bar",
    primaryRow   = "Primary Row",
    secondaryRow = "Secondary Row",
    utilityRow   = "Utility Row",
}

-------------------------------------------------------------------------------
-- Default Settings
-------------------------------------------------------------------------------

C.DEFAULTS = {
    profile = {
        enabled = true,

        -- Global appearance settings
        appearance = {
            font = "Expressway, Bold",  -- Font name (registered with LibSharedMedia)
            statusbarTexture = "Clean",  -- Statusbar texture name (registered with LibSharedMedia)
            showGradient = true,  -- Gradient overlay on all status bars (health, resource, combo points, ticker)
            textColor = { r = 1.0, g = 0.906, b = 0.745 },  -- Warm cream/gold for cooldown/stack/duration text
        },

        -- Global positioning anchor (centered by default; configurable via settings)
        anchor = {
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = -100,  -- Default vertical offset
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

        -- Layout settings (unified element ordering and spacing)
        layout = {
            -- Element stacking order, top to bottom.
            -- All HUD elements are positioned in this order by Layout.lua.
            elementOrder = {
                "auraTracker",
                "auxiliaryRow",
                "healthBar",
                "petHealthBar",
                "resourceBar",
                "comboPoints",
                "swingBar",
                "primaryRow",
                "secondaryRow",
                "utilityRow",
            },
            -- Gap (in pixels) above each element (between it and the element above it).
            -- First visible element's gap is ignored. When an element is hidden,
            -- its gap passes through: the next visible element uses the max of its
            -- own gap and any hidden elements' gaps above it.
            gaps = {
                auraTracker  = 0,
                auxiliaryRow  = 6,
                healthBar    = 2,
                petHealthBar = 0,
                resourceBar  = 0,
                comboPoints  = 0,
                swingBar     = 0,
                primaryRow   = 2,   -- was layout.iconRowGap
                secondaryRow = 1,   -- was icons.rowSpacing + icons.primarySecondaryGap
                utilityRow   = 17,  -- was icons.rowSpacing + icons.sectionGap
            },
        },

        -- Resource bar settings (mana/rage/energy)
        resourceBar = {
            enabled = true,
            width = 230,  -- Width of 4 core icons (4×56 + 3×2 spacing)
            height = 14,
            offsetY = 0,
            textFormat = "current",  -- "current", "percent", "both", "none"
            textSize = 11,
            powerColor = true,    -- Use power-type color (blue/red/yellow) by default
            color = { r = 0.8, g = 0.8, b = 0.8 },  -- Custom color when powerColor is off (neutral light grey)
            innervateHighlight = {
                enabled = true,
                color = { r = 0.00, g = 0.80, b = 0.90 },
            },
            -- Predicted cost overlay (darkened section for queued/casting resource cost)
            showPredictedCost = true,
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
                color = { r = 1.0, g = 1.0, b = 0.0 },  -- Energy yellow
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
            -- Druid secondary mana bar (shows mana while in Cat/Bear Form)
            druidManaBar = {
                enabled = true,
                height = 4,
                textFormat = "none",
                textSize = 9,
                showSpark = false,
                color = { r = 0.00, g = 0.00, b = 1.00 },
                showFormCostMarker = false,
                showManaTicker = false,
            },
        },

        -- Health bar settings
        healthBar = {
            enabled = true,
            width = 230,  -- Width of 4 core icons (4×56 + 3×2 spacing)
            height = 10,
            textFormat = "percent",  -- "current", "percent", "both", "none"
            textSize = 10,
            classColored = true,
            color = { r = 0.0, g = 0.8, b = 0.0 },  -- Custom color when classColored is off (green default)
            showHealPrediction = true,   -- Show incoming heal overlay on bar
        },

        -- Pet health bar settings (auto-hides when no pet)
        petHealthBar = {
            enabled = true,
            width = 230,
            height = 4,
            textFormat = "none",  -- "current", "percent", "both", "none"
            textSize = 9,
            color = { r = 0.0, g = 0.8, b = 0.0 },
            showHealPrediction = true,
        },

        -- Combo points settings (for Rogues and Feral Druids)
        comboPoints = {
            enabled = true,  -- Auto-enabled only for classes that use combo points
            width = 230,     -- Total width (matches resource bar by default)
            barHeight = 6,
            barSpacing = 2,  -- Horizontal spacing between bars
            color = { r = 1.0, g = 0.82, b = 0.0 },  -- Yellow-gold (matches energy theme)
        },

        -- Aura Tracker (procs, external buffs, custom auras)
        auraTracker = {
            enabled = true,
            iconSize = 26,
            iconAspectRatio = 1.0,  -- Independent aspect ratio (1.0 = square)
            iconSpacing = 6,  -- spacing between icons
            showDuration = true,  -- show remaining time text on active auras
            showInactiveIcons = false,  -- Only show when active (not exposed in UI)
            inactiveAlpha = 0.4,
            activeGlow = true,  -- Show animated pixel glow around active auras
            backdropGlowIntensity = 0.25,  -- 0 = disabled, higher = more visible (max ~0.8)
            backdropGlowSize = 2.2,  -- Multiplier for glow size relative to icon
            backdropGlowColor = {1.0, 0.7, 0.35},  -- Warm orange-gold (alpha controlled by intensity)
            punchScale = 1.2,  -- Scale factor for activation pop animation (1.0 = disabled)
            slideAnimation = true,  -- Smooth sliding when auras appear/disappear
            sortOrder = "fifo",  -- Sort order: "fixed", "fifo", "remaining"
            customAuras = {},  -- User-added auras: array of { id = spellID } or { name = "Spell Name" }
        },

        -- Totem Bar settings (DEPRECATED - migrated to Auxiliary Row totem slots)
        -- Kept for migration compatibility only; new installs use rows[4]
        totemBar = {
            enabled = true,
            iconSize = 36,
            iconAspectRatio = 1.0,
            iconSpacing = 4,
        },

        -- Swing Bar settings (weapon swing timer)
        swingBar = {
            enabled = true,
            width = 230,
            height = 2,              -- Single weapon bar height (default for most classes)
            classHeight = { HUNTER = 6 },  -- Per-class height overrides
            specHeight = { RETRIBUTION = 6 },  -- Per-spec height overrides (takes priority over classHeight)
            wandHeight = 2,          -- Single bar height for wand users
            dualWieldHeight = 2,     -- Per-bar height for dual-wield
            dualWieldSpacing = 1,    -- Gap between MH and OH bars
            showText = false,        -- Timer countdown text (default OFF)
            textSize = 10,
            showSpark = true,
            sparkWidth = 8,
            color = { r = 1.0, g = 1.0, b = 1.0 },           -- Neutral fill
            safeColor = { r = 0.3, g = 0.9, b = 0.3 },        -- Green
            dangerColor = { r = 0.9, g = 0.2, b = 0.2 },      -- Red
            cautionColor = { r = 0.9, g = 0.8, b = 0.2 },     -- Yellow (Hunter 3-color)
            syncThreshold = 0.5,     -- Sync threshold (seconds). Enh Shaman: synced=green. Fury Warrior: synced=red (inverted).
            enableSyncColors = true, -- Enhancement/Fury: color bars by sync status
            enableClipZones = true,  -- Hunter: 3-zone bar (green=safe, yellow=Steady clips, red=don't move/Multi clips)
            enableTwistWindow = true, -- Ret Paladin: green zone at end for twist timing
            enableMeleeWeaving = false, -- Hunter: show both ranged + melee bars for weaving
            zoneAlpha = 0.4,         -- Alpha of zone background indicators
            hideDelay = 1.5,         -- Seconds after last swing before auto-hiding
        },

        -- Icon display settings (defaults, rows can override)
        icons = {
            iconSize = 52,          -- Default icon size (per-row overrides in rows config)
            iconAspectRatio = 1.0,  -- Width:Height ratio (1.0 = square, 1.33 = 4:3 wide)
            iconZoom = 0.20,        -- How much to zoom into icon textures (0 = none, 0.20 = 10% cropped from each edge)
            iconSpacing = 1,        -- Horizontal spacing between icons
            rowSpacing = 1,         -- Vertical spacing between sub-rows within a flow-wrapped row
            scale = 1.0,            -- Global scale multiplier
            
            -- Alpha settings
            readyAlpha = 1.0,
            cooldownAlpha = 0.3,
            desaturateNoResources = true,
            
            -- Cooldown display
            -- Row selection: "none" = disabled, "primary" = Primary only,
            -- "primary_secondary" = Primary + Secondary, "all" = all rows
            useOwnCooldownText = true,    -- Use VeevHUD's own cooldown text instead of Blizzard's
            detailedTimeThreshold = 2,    -- Minutes: durations below this show m:ss, above show compact "Xm"
            showCooldownTextOn = "all",   -- Which rows show cooldown text
            showCooldownSpiralOn = "all", -- Which rows show cooldown spiral
            cooldownSpiralAlpha = 1.0,    -- Darkness of cooldown spiral overlay (0 = invisible, 1 = max darkness)
            auraSpiralAlpha = 1.0,        -- Darkness of aura spiral overlay
            cooldownBlingRows = "all",     -- Which rows show sparkle effect when cooldown finishes
            
            -- GCD display: which rows show the global cooldown spinner
            -- "none" = disabled, "primary" = Primary Row only, 
            -- "primary_secondary" = Primary + Secondary, "all" = everywhere
            showGCDOn = "primary_secondary",
            
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
            -- Always rows: which rows keep glow active while ready (others use "once" mode)
            readyGlowRows = "all",            -- Which rows show ready glow (none = disabled)
            readyGlowAlwaysRows = "primary",  -- Which rows use persistent "always" glow (others flash once)
            readyGlowDuration = 1.0,          -- Duration to show glow in "once" mode
            readyGlowThreshold = 0.5,         -- Seconds before cooldown ends to trigger "almost ready" glow
            
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
            
            -- Queued highlight: shows a glow on icons for "next melee" abilities
            -- (Heroic Strike, Cleave, Maul, etc.) that are queued via IsCurrentSpell
            showQueuedHighlight = true,
            
            -- Keybind text: show the keyboard shortcut for each ability (like default action bars)
            -- "none" = disabled, "primary" = Primary only, "primary_secondary" = Primary + Secondary, "all" = all rows
            -- Scans action bars to find where each spell is placed and displays the keybind
            -- Text appears in bottom-right (stack text uses top-right)
            showKeybindText = "none",  -- Off by default
            keybindTextSize = 12,  -- Font size in pixels for keybind text
        },
        
        -- Buff Reminders (long-duration buff tracking, separate from HUD)
        buffReminders = {
            enabled = true,
            iconSize = 64,
            iconSpacing = 12,
            alpha = 0.30,     -- Semi-transparent reminder (not meant to obscure gameplay)
            pulseEnabled = true,
            showWhileResting = false,
            showWhileMounted = false,
            slideAnimation = true,  -- Smooth sliding when reminder icons appear/disappear
            respectResourceCost = true,
            weaponEnchantMH = true,   -- Check mainhand for missing weapon enchant (poison/imbue)
            weaponEnchantOH = true,   -- Check offhand for missing weapon enchant
            showOnlyKnown = true,     -- Filter spell list in options to known spells only
            anchor = {
                point = "BOTTOM",
                relativePoint = "TOP",
                x = 0,
                y = 24,  -- Positioned above main HUD
            },
            -- Per-spell overrides stored sparsely per spec:
            -- spellConfig[specKey][spellID] = { enabled, timeRemaining, minStacks, combatState, trackTarget, priority }
            -- specKey = "CLASS_SPEC" (e.g., "WARLOCK_DESTRUCTION"); absence = use computed defaults
            spellConfig = {},
        },

        -- Cooldown Pulse (flash icon on screen when ability comes off cooldown)
        cooldownPulse = {
            enabled = true,
            iconSize = 60,        -- Pulse icon size in pixels
            maxAlpha = 0.7,       -- Peak opacity during animation
            fadeInTime = 0.3,     -- Seconds to fade in
            holdTime = 0,         -- Seconds to hold at peak before fading out
            fadeOutTime = 0.7,    -- Seconds to fade out
            animationIn = C.PULSE_EFFECT.GROW,   -- Size effect during fade-in
            animationOut = C.PULSE_EFFECT.GROW,  -- Size effect during fade-out
            preTriggerTime = 0,      -- Seconds before cooldown ends to fire pulse (0 = exact ready)
            onlyInCombat = false,    -- Only show pulses while in combat
            minCooldown = 0,         -- Minimum cooldown duration (seconds) to trigger a pulse (0 = all)
            pulseRows = "all", -- Which rows trigger pulses
            anchor = {
                x = 0,
                y = 0,
            },
        },

        -- Per-spec spell configuration (sparse storage)
        -- Format: spellConfig[specKey][spellID] = { enabled, rowIndex, order }
        -- specKey = "CLASS_SPEC" (e.g., "WARRIOR_FURY")
        -- Only modified values are stored; nil = use default
        spellConfig = {},

        -- Per-aura visibility overrides (sparse storage, profile-wide)
        -- Format: auraConfig[spellID] = true/false
        -- Absence = use default (GetAuraDefaultEnabled logic)
        auraConfig = {},

        -- Per-aura source filter overrides (sparse storage, profile-wide)
        -- Format: auraSourceFilter[spellID] = "any"|"own"|"notOwn"
        -- Absence = use default (externals -> "notOwn", others -> "any")
        auraSourceFilter = {},

        -- Per-aura glow overrides (sparse storage, profile-wide)
        -- Format: auraGlowConfig[spellID] = true/false
        -- Absence = use default (true = glow enabled)
        auraGlowConfig = {},

        -- Row definitions (order matters - top to bottom)
        -- Each row shows spells matching these LibSpellDB tags
        -- Spells are assigned to the FIRST matching row (no duplicates)
        rows = {
            {
                name = "Primary Row",
                -- Primary: ROTATIONAL abilities for DPS/Healing/Tanking
                tags = {"ROTATIONAL", "CORE_ROTATION"},
                maxIcons = 24,       -- No practical limit, grows horizontally
                enabled = true,
                iconSize = 56,       -- Larger core icons (like retail)
                iconAspectRatio = nil, -- nil = inherit from icons.iconAspectRatio
                flowLayout = false,  -- Single line by default
                iconsPerRow = 6,     -- Icons per row when flow layout is on
            },
            {
                name = "Secondary Row",
                -- Secondary: Throughput abilities (DPS/healing CDs, maintenance debuffs, AoE-exclusive)
                -- Matches DPS or HEAL role tags, plus MAINTENANCE for tank upkeep
                -- EXTERNAL_DEFENSIVE included: healer external CDs are their "throughput" equivalent
                -- Self-only defensives (DEFENSIVE without EXTERNAL_DEFENSIVE) fall through to Utility
                tags = {"DPS", "HEAL", "MAINTENANCE", "AOE", "EXTERNAL_DEFENSIVE", "TRINKET",
                        -- Legacy tags for backward compatibility
                        "SITUATIONAL", "OFFENSIVE_CD", "OFFENSIVE_CD_MINOR", "HEALING_CD", "RESOURCE"},
                maxIcons = 24,       -- No practical limit, grows horizontally
                enabled = true,
                iconSize = 48,
                iconAspectRatio = nil, -- nil = inherit from icons.iconAspectRatio
                flowLayout = false,  -- Single line by default
                iconsPerRow = 6,     -- Icons per row when flow layout is on
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
                iconAspectRatio = nil, -- nil = inherit from icons.iconAspectRatio
                flowLayout = true,   -- Enable multi-row flow layout
            },
            {
                -- Auxiliary row - default home for totem element slots
                -- No tags: only sentinel slots (totems) and user-dragged spells appear here
                name = "Auxiliary",
                tags = {},
                maxIcons = 24,
                enabled = true,
                iconSize = 36,       -- Matches previous totem bar icon size
                iconAspectRatio = nil, -- nil = inherit from icons.iconAspectRatio
                flowLayout = false,
                iconsPerRow = 6,
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

-------------------------------------------------------------------------------
-- Bundled Statusbar Texture
-------------------------------------------------------------------------------

-- Bundled statusbar texture path (used as fallback when LibSharedMedia is unavailable)
-- Name matches SharedMedia convention to avoid duplicates
C.BUNDLED_STATUSBAR = "Interface\\AddOns\\VeevHUD\\Media\\Statusbar_Clean"
C.BUNDLED_STATUSBAR_NAME = "Clean"
