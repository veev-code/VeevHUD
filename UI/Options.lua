--[[
    VeevHUD - Options Panel
    Uses Blizzard's native Settings API with ScrollFrame
    
    Key features:
    - Only user-modified settings are saved (inherit new defaults automatically)
    - Visual highlighting for modified settings (gold asterisk)
    - Per-setting reset to default (right-click)
    - Scrollable content area
]]

local ADDON_NAME, addon = ...

local Options = {}
addon.Options = Options

-- Widget registry for dependency management
Options.widgets = {}  -- widgets[path] = { widget = frame, control = checkbox/slider, config = config }
Options.dependencies = {}  -- dependencies[parentPath] = { childPath1, childPath2, ... }

-- Static popup for reload UI prompt (needed for Masque compatibility with aspect ratio changes)
StaticPopupDialogs["VEEVHUD_RELOAD_UI"] = {
    text = "Changing icon aspect ratio with Masque installed requires a UI reload.\n\nReload now?",
    button1 = "Reload",
    button2 = "Cancel",
    OnAccept = function()
        ReloadUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-------------------------------------------------------------------------------
-- Options Initialization
-------------------------------------------------------------------------------

function Options:Initialize()
    -- Wait for Settings API to be available
    if not Settings or not Settings.RegisterCanvasLayoutCategory then
        addon.Utils:LogInfo("Settings API not available, skipping options registration")
        return
    end
    
    -- Create the main options panel with error handling
    local success, err = pcall(function()
        self:CreateOptionsPanel()
    end)
    
    if success then
        addon.Utils:LogInfo("Options panel registered")
    else
        addon.Utils:LogError("Options panel failed to register:", err)
        addon.Utils:Print("|cffff0000Options panel failed:|r " .. tostring(err))
    end
end

function Options:CreateOptionsPanel()
    -- Create main panel frame
    local panel = CreateFrame("Frame")
    panel.name = "VeevHUD"
    
    -- Title
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("VeevHUD")
    
    -- Version
    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    version:SetText("Version " .. (addon.version or "1.0.0"))
    version:SetTextColor(0.6, 0.6, 0.6)
    
    -- Legend
    local legend = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    legend:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -16)
    legend:SetText("|cffffd200*|r = Modified (Right-click to reset)")
    legend:SetTextColor(0.7, 0.7, 0.7)
    
    -- Reset Display Settings Button (pinned top-right)
    local resetButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetButton:SetPoint("TOPRIGHT", legend, "BOTTOMRIGHT", 0, -4)
    resetButton:SetSize(180, 22)
    resetButton:SetText("Reset Display Settings")
    resetButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Reset Display Settings", 1, 1, 1)
        GameTooltip:AddLine("Resets all settings on this page to defaults.", 1, 0.82, 0, true)
        GameTooltip:AddLine("Does NOT affect spell configuration.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    resetButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    resetButton:SetScript("OnClick", function()
        StaticPopupDialogs["VEEVHUD_RESET_DISPLAY_CONFIRM"] = {
            text = "Reset all VeevHUD display settings to defaults?\n\n(Spell configuration will NOT be affected)",
            button1 = "Yes",
            button2 = "No",
            OnAccept = function()
                addon:ResetProfile()
                ReloadUI()
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
        }
        StaticPopup_Show("VEEVHUD_RESET_DISPLAY_CONFIRM")
    end)
    
    -- Create scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", version, "BOTTOMLEFT", 0, -12)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 10)
    
    -- Scroll child (content container)
    local scrollChild = CreateFrame("Frame")
    scrollFrame:SetScrollChild(scrollChild)
    scrollChild:SetWidth(scrollFrame:GetWidth() or 540)
    scrollChild:SetHeight(1)  -- Will be set after content is added
    
    -- Store references
    self.scrollFrame = scrollFrame
    self.scrollChild = scrollChild
    
    -- Create content
    self:CreatePanelContent(scrollChild)
    
    -- Register with Blizzard Settings
    local category = Settings.RegisterCanvasLayoutCategory(panel, "VeevHUD")
    self.category = category
    Settings.RegisterAddOnCategory(category)
    
    -- Store category ID for opening via slash command
    self.categoryID = category:GetID()
    
    -- Update scroll child size on show
    panel:SetScript("OnShow", function()
        scrollChild:SetWidth(scrollFrame:GetWidth() - 10)
    end)
end

function Options:CreatePanelContent(container)
    -- Track Y offset for positioning
    local yOffset = 0
    
    -- === APPEARANCE SECTION ===
    yOffset = self:CreateSectionHeader(container, "Appearance", yOffset)
    
    -- Global Scale first - most commonly adjusted setting
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.scale",
        label = "Global Scale",
        tooltip = "Makes everything in the HUD bigger or smaller. 100% is the normal size. Increase if you have trouble seeing the icons, decrease if they take up too much screen space.",
        min = 0.25, max = 3.0, step = 0.05,
        isPercent = true,
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "anchor.y",
        label = "Vertical Offset",
        tooltip = "Moves the entire HUD up or down on your screen. Use negative numbers to move it below the center of your screen, positive to move it above. Default is -84 (slightly below center).",
        min = -500, max = 500, step = 1,
    })
    
    yOffset = self:CreateFontDropdown(container, yOffset, {
        path = "appearance.font",
        label = "Font",
        tooltip = "The font used for all text in the HUD: cooldown timers, stack counts, health/resource values, and proc durations.\n\nWith LibSharedMedia-3.0 installed, you'll see all built-in WoW fonts plus any custom fonts from other addons.",
    })
    
    -- === VISIBILITY SECTION ===
    yOffset = yOffset - 8
    yOffset = self:CreateSectionHeader(container, "Visibility", yOffset)
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "visibility.outOfCombatAlpha",
        label = "Out of Combat Opacity",
        tooltip = "Controls the HUD's visibility when not in combat. Use this to fade the HUD when out of combat so it's less distracting. 100% = fully visible, 50% = half transparent, 0% = invisible.",
        min = 0, max = 1.0, step = 0.05,
        isPercent = true,
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "visibility.hideOnFlightPath",
        label = "Hide on Flight Path",
        tooltip = "Automatically hides the HUD when you're on a flight path (taxi). The HUD will reappear when you land. Useful to keep your screen clean while traveling.",
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "animations.smoothBars",
        label = "Smooth Bar Animation",
        tooltip = "Makes bars animate smoothly when values change, rather than jumping instantly. Applies to health bar, resource bar, and resource cost fill on icons. Disable if you prefer instant feedback.",
    })
    
    -- === ICONS SECTION ===
    yOffset = yOffset - 8
    yOffset = self:CreateSectionHeader(container, "Icons", yOffset)
    
    -- Masque note
    local masqueNote = container:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    masqueNote:SetPoint("TOPLEFT", 0, yOffset)
    masqueNote:SetText("|cff888888Tip: Install the Masque addon to reskin ability icons with custom button styles.|r")
    masqueNote:SetJustifyH("LEFT")
    yOffset = yOffset - 20
    
    -- ─── Icons: Appearance ───
    yOffset = self:CreateSubsectionHeader(container, "Appearance", yOffset)
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.iconAspectRatio",
        label = "Icon Aspect Ratio",
        tooltip = "Makes icons shorter to create a more vertically compact HUD. Width stays the same while height shrinks, cropping the top/bottom of icon textures. The health and resource bars stay in place; ability rows shift up to fill the space. Affects both HUD icons and proc icons.",
        options = {
            { value = 1.0, label = "1:1 (Square)" },
            { value = 1.33, label = "4:3 (Compact)" },
            { value = 2.0, label = "2:1 (Ultra Compact)" },
        },
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.iconZoom",
        label = "Icon Zoom",
        tooltip = "How much to zoom into the icon textures, cropping the edges. The percentage represents total texture cropped (split evenly between all edges). 0% shows the full texture, 16% is a subtle zoom, 30% is more noticeable. Similar to WeakAuras' zoom setting.",
        min = 0, max = 0.5, step = 0.02,
        isPercent = true,
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.readyAlpha",
        label = "Ready Opacity",
        tooltip = "How visible icons are when the ability is ready to use. 100% means fully visible, lower values make ready abilities slightly transparent. Most people want this at 100%.",
        min = 0, max = 1.0, step = 0.05,
        isPercent = true,
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.cooldownAlpha",
        label = "Cooldown Opacity",
        tooltip = "How visible icons are when the ability is on cooldown (for rows with fading enabled). A lower value (like 30%) makes cooldown abilities fade out so you can focus on what's ready. Higher values keep them visible.",
        min = 0, max = 1.0, step = 0.05,
        isPercent = true,
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "icons.desaturateNoResources",
        label = "Grey Out Unusable",
        tooltip = "Turns ability icons grey when they can't be used - whether due to insufficient resources, wrong stance, target requirements, or other conditions. This mimics how the default action bars work and helps you instantly see what's usable.\n\nNote: This effect is suppressed while resting in cities/inns to keep the UI clean when you're not actively playing.",
    })
    
    -- ─── Icons: Spacing ───
    yOffset = yOffset - 10
    yOffset = self:CreateSubsectionHeader(container, "Spacing", yOffset)
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.iconSpacing",
        label = "Horizontal Icon Spacing",
        tooltip = "The horizontal gap in pixels between each ability icon within a row. A small gap (2-4) helps visually separate icons. Set to 0 for icons to touch. Negative values allow overlap, which may look better with certain skins.",
        min = -10, max = 10, step = 1,
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.rowSpacing",
        label = "Vertical Row Spacing",
        tooltip = "The vertical gap in pixels between rows of icons (e.g., between Primary and Secondary rows). Set to 0 for rows to touch. Negative values allow overlap, which may look better with certain skins.",
        min = -10, max = 20, step = 1,
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "layout.iconRowGap",
        label = "Icon Row to Bars Gap",
        tooltip = "The vertical gap in pixels between the top of the icon row and the bottom of the first bar (combo points, resource bar, or health bar). This controls how close the bars sit to your ability icons.",
        min = -10, max = 30, step = 1,
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.primarySecondaryGap",
        label = "Primary/Secondary Gap",
        tooltip = "Extra vertical gap in pixels between the Primary and Secondary rows. This creates visual separation between your core rotation abilities and secondary throughput cooldowns. Set to 0 to use only the base row spacing.",
        min = -10, max = 30, step = 1,
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.sectionGap",
        label = "Utility Section Gap",
        tooltip = "Extra vertical gap in pixels before the utility/misc row section. This creates visual separation between your main rotation abilities and utility spells. Set to 0 to remove the gap. Negative values allow overlap.",
        min = -10, max = 30, step = 1,
    })
    
    -- ─── Icons: Cooldown Display ───
    yOffset = yOffset - 10
    yOffset = self:CreateSubsectionHeader(container, "Cooldown Display", yOffset)
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.showCooldownTextOn",
        label = "Cooldown Text",
        tooltip = "Displays the remaining cooldown time as numbers on top of each icon (e.g., '5s', '1.2'). When enabled, VeevHUD shows its own text and hides text from addons like OmniCC. Select which rows display cooldown text.",
        options = {
            { value = "none", label = "None" },
            { value = "primary", label = "Primary Row Only" },
            { value = "primary_secondary", label = "Primary + Secondary" },
            { value = "all", label = "All Rows" },
        },
    })
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.showCooldownSpiralOn",
        label = "Cooldown Spiral",
        tooltip = "Shows the dark 'clock sweep' overlay on abilities that are on cooldown. This visual helps you see at a glance how much time remains. Select which rows display the cooldown spiral.",
        options = {
            { value = "none", label = "None" },
            { value = "primary", label = "Primary Row Only" },
            { value = "primary_secondary", label = "Primary + Secondary" },
            { value = "all", label = "All Rows" },
        },
    })
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.showGCDOn",
        label = "GCD Indicator",
        tooltip = "Controls which rows display the Global Cooldown (GCD) spinner. The GCD is the brief ~1.5 second lockout after using most abilities. Showing GCD helps you see when you can press your next ability.",
        options = {
            { value = "none", label = "None" },
            { value = "primary", label = "Primary Row Only" },
            { value = "primary_secondary", label = "Primary + Secondary" },
            { value = "all", label = "All Rows" },
        },
    })
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.dimOnCooldown",
        label = "Fade on Cooldown",
        tooltip = "Controls which rows fade to Cooldown Opacity when abilities are on cooldown. Rows that don't fade stay at full brightness and use desaturation to show unavailability instead. Primary row typically stays bright to keep your core rotation visually prominent.",
        options = {
            { value = "none", label = "None (All Rows Full Opacity)" },
            { value = "utility", label = "Utility Only" },
            { value = "secondary_utility", label = "Secondary + Utility" },
            { value = "all", label = "All Rows" },
        },
    })
    
    -- ─── Icons: Resource Cost ───
    yOffset = yOffset - 10
    yOffset = self:CreateSubsectionHeader(container, "Resource Cost", yOffset)
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.resourceDisplayRows",
        label = "Show Resource Cost",
        tooltip = "Shows your progress toward affording an ability on selected rows. The display style fills or overlays the icon until you have enough resources.",
        options = {
            { value = "none", label = "None" },
            { value = "primary", label = "Primary Row Only" },
            { value = "primary_secondary", label = "Primary + Secondary" },
            { value = "all", label = "All Rows" },
        },
    })
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.resourceDisplayMode",
        label = "Resource Cost Style",
        tooltip = "'Vertical Fill' darkens the icon from top down until you have enough resources.\n\n'Bottom Bar' shows a small horizontal bar at the bottom of the icon.\n\n'Resource Timer' extends the cooldown spiral to show when you'll actually be able to cast — factoring in both cooldown AND resource regeneration. The icon shows max(cooldown, time_until_affordable).\n\nResource-specific behavior:\n- Energy: Highly accurate. Tick-aware (2-second ticks), accounts for Adrenaline Rush.\n- Mana: Tick-aware with 5-second rule tracking. Measures in-combat vs passive regen rates separately.\n- Rage: Falls back to Vertical Fill (rage generation is unpredictable).\n\nIf any prediction is wrong, it falls back to vertical fill.",
        options = {
            { value = "fill", label = "Vertical Fill" },
            { value = "bar", label = "Bottom Bar" },
            { value = "prediction", label = "Resource Timer" },
        },
        dependsOn = "icons.resourceDisplayRows",
        dependsOnNotValue = "none",
    })
    
    -- ─── Icons: Feedback & Glow ───
    yOffset = yOffset - 10
    yOffset = self:CreateSubsectionHeader(container, "Feedback & Glow", yOffset)
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.castFeedbackRows",
        label = "Cast Feedback Animation",
        tooltip = "Plays a brief 'pop' animation (the icon scales up slightly then back down) whenever you successfully cast an ability. Gives satisfying visual feedback that your spell went off. Select which rows show this animation.",
        options = {
            { value = "none", label = "None" },
            { value = "primary", label = "Primary Row Only" },
            { value = "primary_secondary", label = "Primary + Secondary" },
            { value = "all", label = "All Rows" },
        },
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.castFeedbackScale",
        label = "Feedback Scale",
        tooltip = "How much the icon grows during the cast feedback animation. 110% is a subtle pop, 150%+ is more dramatic. Only applies if Cast Feedback Animation is enabled.",
        min = 1.05, max = 2.0, step = 0.05,
        isPercent = true,
        dependsOn = "icons.castFeedbackRows",
        dependsOnNotValue = "none",
    })
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.readyGlowRows",
        label = "Usable Glow",
        tooltip = "Shows a proc-style glowing border when an ability becomes ready. Controls which rows show the effect.\n\nNote: Reactive abilities (Execute, Overpower, etc.) always glow every time they become usable, regardless of this setting.",
        options = {
            { value = "none", label = "None" },
            { value = "primary", label = "Primary Row Only" },
            { value = "primary_secondary", label = "Primary + Secondary" },
            { value = "all", label = "All Rows" },
        },
    })
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.readyGlowMode",
        label = "Glow Behavior",
        tooltip = "'Once Per Cooldown' glows when an ability first becomes ready and won't re-trigger if your resources fluctuate. 'Every Time Usable' glows each time all conditions are met (off cooldown + enough resources).",
        options = {
            { value = "once", label = "Once Per Cooldown" },
            { value = "always", label = "Every Time Usable" },
        },
        dependsOn = "icons.readyGlowRows",
        dependsOnNotValue = "none",
    })
    
    -- ─── Icons: Aura Tracking ───
    yOffset = yOffset - 10
    yOffset = self:CreateSubsectionHeader(container, "Aura Tracking", yOffset)
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "icons.showAuraTracking",
        label = "Show Buff/Debuff Duration",
        tooltip = "When enabled, abilities that apply buffs or debuffs (like Intimidating Shout, Rend, Renew) will show the active duration with a glow while the effect is on a target. After it expires, the cooldown is shown. Disable this if you only want to see cooldowns.",
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "icons.auraTargettargetSupport",
        label = "Include Target-of-Target",
        tooltip = "Enables targettarget-aware aura tracking. Helpful if you use @targettarget macros:\n\n- Target the boss, see your HOTs on the tank\n- Target the tank, see your DoTs on the boss\n\nExample macros:\n/cast [@target,help] [@targettarget,help] [@player] Renew\n/cast [@target,harm] [@targettarget,harm] [] Shadow Word: Pain",
        dependsOn = "icons.showAuraTracking",
    })
    
    -- ─── Icons: Dynamic Sorting ───
    yOffset = yOffset - 10
    yOffset = self:CreateSubsectionHeader(container, "Dynamic Sorting", yOffset)
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.dynamicSortRows",
        label = "Sort by Time Remaining",
        tooltip = "Controls which rows dynamically reorder icons by 'actionable time' (least time remaining first).\n\n'None' uses a static order. Icons never move positions.\n\nWhen enabled, the ability needing attention soonest is always on the left. Useful for:\n- DOT classes: see which debuff is closest to expiring\n- Cooldown-heavy classes: see which ability is ready next\n\nTie-breaker: When multiple abilities are ready (or have equal time), they sort by their original row position. This means you can arrange your row as a priority order and the leftmost icon is always the next best spell to cast.\n\nThe 'actionable time' is max(cooldown remaining, buff/debuff remaining).",
        options = {
            { value = "none", label = "None (Static Order)" },
            { value = "primary", label = "Primary Row Only" },
            { value = "primary_secondary", label = "Primary + Secondary" },
        },
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "icons.dynamicSortAnimation",
        label = "Animate Sorting",
        tooltip = "When dynamic sorting is enabled, icons slide smoothly to their new positions instead of snapping instantly. The animation is quick and snappy to avoid being distracting during combat. Disable for instant repositioning.",
        dependsOn = "icons.dynamicSortRows",
        dependsOnNotValue = "none",
    })
    
    -- === HEALTH BAR SECTION ===
    yOffset = yOffset - 8
    yOffset = self:CreateSectionHeader(container, "Health Bar", yOffset)
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "healthBar.enabled",
        label = "Enable Health Bar",
        tooltip = "Shows a bar displaying your current health. This appears above the resource bar and gives you a quick glance at your survivability without looking at your unit frame.",
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "healthBar.width",
        label = "Width",
        tooltip = "How wide the health bar is in pixels. By default it matches the resource bar width for a clean, aligned look.",
        min = 100, max = 400, step = 10,
        dependsOn = "healthBar.enabled",
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "healthBar.height",
        label = "Height",
        tooltip = "How tall/thick the health bar is in pixels. Changing this will automatically adjust the position of the resource bar below it.",
        min = 4, max = 20, step = 1,
        dependsOn = "healthBar.enabled",
    })
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "healthBar.textFormat",
        label = "Text Display",
        tooltip = "Controls what text is shown on the health bar.\n\n'Current Value' shows your actual health (e.g., '3256').\n'Percent' shows your health percentage (e.g., '71%').\n'Both' shows both (e.g., '3256 (71%)').\n'None' hides the text entirely.",
        options = {
            { value = "current", label = "Current Value" },
            { value = "percent", label = "Percent" },
            { value = "both", label = "Both" },
            { value = "none", label = "None" },
        },
        dependsOn = "healthBar.enabled",
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "healthBar.textSize",
        label = "Text Size",
        tooltip = "The font size in pixels for the health text. Larger sizes are easier to read but may overflow small bars.",
        min = 6, max = 18, step = 1,
        dependsOn = "healthBar.textFormat",
        dependsOnNotValue = "none",
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "healthBar.classColored",
        label = "Class Colored",
        tooltip = "Colors the health bar using your class color (e.g., brown for Warriors, purple for Warlocks) instead of the standard green. Helps you quickly identify your health bar.",
        dependsOn = "healthBar.enabled",
    })
    
    -- === RESOURCE BAR SECTION ===
    yOffset = yOffset - 8
    yOffset = self:CreateSectionHeader(container, "Resource Bar", yOffset)
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "resourceBar.enabled",
        label = "Enable Resource Bar",
        tooltip = "Shows a bar displaying your current mana, rage, or energy (depending on your class). This bar appears below the health bar and gives you a quick view of your resources.",
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "resourceBar.width",
        label = "Width",
        tooltip = "How wide the resource bar is in pixels. By default it matches the width of 4 core ability icons. Make it wider or narrower to fit your preference.",
        min = 100, max = 400, step = 10,
        dependsOn = "resourceBar.enabled",
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "resourceBar.height",
        label = "Height",
        tooltip = "How tall/thick the resource bar is in pixels. Changing this will automatically adjust the position of elements above it (health bar, proc tracker).",
        min = 6, max = 30, step = 1,
        dependsOn = "resourceBar.enabled",
    })
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "resourceBar.textFormat",
        label = "Text Display",
        tooltip = "Controls what text is shown on the resource bar.\n\n'Current Value' shows your actual resource (e.g., '4523' for mana, '67' for energy).\n'Percent' shows your resource percentage (e.g., '85%').\n'Both' shows both (e.g., '4523 (85%)').\n'None' hides the text entirely.",
        options = {
            { value = "current", label = "Current Value" },
            { value = "percent", label = "Percent" },
            { value = "both", label = "Both" },
            { value = "none", label = "None" },
        },
        dependsOn = "resourceBar.enabled",
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "resourceBar.textSize",
        label = "Text Size",
        tooltip = "The font size in pixels for the resource text. Larger sizes are easier to read but may overflow small bars.",
        min = 6, max = 18, step = 1,
        dependsOn = "resourceBar.textFormat",
        dependsOnNotValue = "none",
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "resourceBar.showSpark",
        label = "Show Spark",
        tooltip = "Displays a glowing 'spark' effect at the current fill position of the bar. This small visual flourish makes the bar look more polished and helps you track changes.",
        dependsOn = "resourceBar.enabled",
    })
    
    -- Energy ticker (only for Rogues and Druids - energy users)
    if addon.playerClass == "ROGUE" or addon.playerClass == "DRUID" then
        yOffset = self:CreateCheckbox(container, yOffset, {
            path = "resourceBar.energyTicker.enabled",
            label = "Energy Tick Indicator",
            tooltip = "Shows progress toward the next energy tick (energy regenerates every 2 seconds). Helps you time abilities to maximize energy efficiency.",
            dependsOn = "resourceBar.enabled",
        })
        
        yOffset = self:CreateDropdown(container, yOffset, {
            path = "resourceBar.energyTicker.style",
            label = "Tick Indicator Style",
            tooltip = "'Ticker Bar' shows a separate thin bar below the resource bar that fills as the next tick approaches.\n\n'Spark' shows a moving spark overlay on the resource bar itself, which is more subtle.",
            options = {
                { value = "bar", label = "Ticker Bar" },
                { value = "spark", label = "Spark" },
            },
            dependsOn = "resourceBar.energyTicker.enabled",
        })
    end
    
    -- Mana ticker (only for mana-using classes)
    local manaClasses = { MAGE = true, PRIEST = true, WARLOCK = true, PALADIN = true, DRUID = true, SHAMAN = true, HUNTER = true }
    if manaClasses[addon.playerClass] then
        yOffset = self:CreateCheckbox(container, yOffset, {
            path = "resourceBar.manaTicker.enabled",
            label = "Mana Tick Indicator",
            tooltip = "Shows a spark overlay indicating progress toward the next mana tick. Helps you time casts to avoid clipping mana regeneration.",
            dependsOn = "resourceBar.enabled",
        })
        
        yOffset = self:CreateDropdown(container, yOffset, {
            path = "resourceBar.manaTicker.style",
            label = "Tick Indicator Mode",
            tooltip = "'Outside 5 Second Rule' shows the 2-second tick cycle, but only when already regenerating at full spirit rate.\n\n'Next Full Tick' (recommended) intelligently combines the 5-second rule AND tick timing. After you cast, it calculates exactly when your first full-rate tick will arrive and shows a seamless countdown. Cast right after it completes to maximize mana efficiency — you'll never accidentally clip a big tick again.",
            options = {
                { value = "outside5sr", label = "Outside 5 Second Rule" },
                { value = "nextfulltick", label = "Next Full Tick" },
            },
            dependsOn = "resourceBar.manaTicker.enabled",
        })
    end
    
    -- === COMBO POINTS SECTION (only for Rogues and Druids) ===
    if addon.playerClass == "ROGUE" or addon.playerClass == "DRUID" then
        yOffset = yOffset - 8
        yOffset = self:CreateSectionHeader(container, "Combo Points", yOffset)
        
        yOffset = self:CreateCheckbox(container, yOffset, {
            path = "comboPoints.enabled",
            label = "Enable Combo Points",
            tooltip = "Shows combo point bars below the resource bar. For Druids, this only appears while in Cat Form.",
        })
        
        yOffset = self:CreateSlider(container, yOffset, {
            path = "comboPoints.width",
            label = "Width",
            tooltip = "The total width of the combo points bar in pixels. By default this matches the resource bar width.",
            min = 100, max = 400, step = 10,
            dependsOn = "comboPoints.enabled",
        })
        
        yOffset = self:CreateSlider(container, yOffset, {
            path = "comboPoints.barHeight",
            label = "Bar Height",
            tooltip = "The height of each combo point bar in pixels. Smaller values create a more subtle display.",
            min = 4, max = 16, step = 1,
            dependsOn = "comboPoints.enabled",
        })
    end
    
    -- === PROC TRACKER SECTION ===
    yOffset = yOffset - 8
    yOffset = self:CreateSectionHeader(container, "Proc Tracker", yOffset)
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "procTracker.enabled",
        label = "Enable Proc Tracker",
        tooltip = "Shows small icons for important temporary buffs (procs) like Warrior's Enrage or Flurry. These appear above the health bar and only show when the buff is active, helping you react to procs.",
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "procTracker.iconSize",
        label = "Icon Size",
        tooltip = "How big the proc icons are in pixels. These are typically smaller than ability icons since they're just indicators. 20-28 pixels works well for most people.",
        min = 16, max = 40, step = 2,
        dependsOn = "procTracker.enabled",
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "procTracker.iconSpacing",
        label = "Icon Spacing",
        tooltip = "The gap in pixels between proc icons. Increase for more visual separation between procs.",
        min = 2, max = 12, step = 1,
        dependsOn = "procTracker.enabled",
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "procTracker.gapAboveHealthBar",
        label = "Gap Above Health Bar",
        tooltip = "The gap in pixels between the health bar and the proc icons. Increase if procs feel too close to the health bar.",
        min = 2, max = 16, step = 1,
        dependsOn = "procTracker.enabled",
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "procTracker.showDuration",
        label = "Show Duration Text",
        tooltip = "Displays the remaining time on proc buffs as text on the icon. Disable if you prefer a cleaner look or if it overlaps with stack counts.",
        dependsOn = "procTracker.enabled",
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "procTracker.activeGlow",
        label = "Show Edge Glow",
        tooltip = "Shows an animated pixel glow effect around the edge of active proc icons. Helps draw attention to active procs.",
        dependsOn = "procTracker.enabled",
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "procTracker.backdropGlowIntensity",
        label = "Backdrop Glow Intensity",
        tooltip = "Controls the brightness of the soft glow halo behind proc icons. Set to 0 to disable the backdrop glow entirely. Higher values make it more visible.",
        min = 0, max = 0.8, step = 0.05,
        isPercent = true,
        dependsOn = "procTracker.enabled",
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "procTracker.slideAnimation",
        label = "Slide Animation",
        tooltip = "When procs appear or disappear, the remaining icons smoothly slide to re-center instead of snapping instantly. Disable for instant repositioning.",
        dependsOn = "procTracker.enabled",
    })
    
    -- === SUPPORT SECTION ===
    yOffset = yOffset - 8
    yOffset = self:CreateSectionHeader(container, "Support", yOffset)
    
    local supportLabel = container:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    supportLabel:SetPoint("TOPLEFT", 0, yOffset)
    supportLabel:SetText("|cff888888Join the |cffffffffVeev Addons Discord|r|cff888888 for feedback, suggestions, and bug reports:|r")
    supportLabel:SetJustifyH("LEFT")
    
    local discordLink = CreateFrame("Button", nil, container)
    discordLink:SetPoint("LEFT", supportLabel, "RIGHT", 4, 0)
    discordLink:SetSize(180, 14)
    
    local linkText = discordLink:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    linkText:SetPoint("LEFT")
    linkText:SetText("|cff69b8ffhttps://discord.gg/HuSXTa5XNq|r")
    discordLink:SetFontString(linkText)
    
    discordLink:SetScript("OnEnter", function(self)
        linkText:SetText("|cff99d1ff[Click to copy URL]|r")
    end)
    discordLink:SetScript("OnLeave", function(self)
        linkText:SetText("|cff69b8ffhttps://discord.gg/HuSXTa5XNq|r")
    end)
    discordLink:SetScript("OnClick", function()
        Options:ShowURLDialog("https://discord.gg/HuSXTa5XNq")
    end)
    
    yOffset = yOffset - 20
    
    -- Set scroll child height
    container:SetHeight(math.abs(yOffset) + 20)
    
    -- Initialize widget dependencies (grey out dependent widgets based on parent state)
    self:InitializeDependencies()
end

-------------------------------------------------------------------------------
-- Widget Dependency Management
-------------------------------------------------------------------------------

function Options:RegisterWidget(path, frame, control, config)
    self.widgets[path] = { frame = frame, control = control, config = config }
    
    -- Register dependency if specified
    if config.dependsOn then
        if not self.dependencies[config.dependsOn] then
            self.dependencies[config.dependsOn] = {}
        end
        table.insert(self.dependencies[config.dependsOn], path)
    end
end

function Options:UpdateDependentWidgets(parentPath)
    local dependents = self.dependencies[parentPath]
    if not dependents then return end
    
    for _, childPath in ipairs(dependents) do
        local widget = self.widgets[childPath]
        if widget then
            -- Check if this widget should be enabled based on its dependency config
            local shouldEnable = self:IsWidgetDependencySatisfied(widget.config)
            self:SetWidgetEnabled(widget, shouldEnable, childPath)
        end
    end
end

-- Check if a widget's dependency is satisfied
-- Supports:
--   - Boolean dependencies (dependsOn only): parent must be true
--   - Value-based (dependsOn + dependsOnValue): parent must equal specific value
--   - Negated value (dependsOn + dependsOnNotValue): parent must NOT equal specific value
function Options:IsWidgetDependencySatisfied(config)
    if not config.dependsOn then return true end
    
    local parentValue = addon:GetSettingValue(config.dependsOn)
    
    if config.dependsOnNotValue ~= nil then
        -- Negated value dependency: parent must NOT equal specific value
        if parentValue == config.dependsOnNotValue then
            return false
        end
    elseif config.dependsOnValue ~= nil then
        -- Value-based dependency: parent must equal specific value
        if parentValue ~= config.dependsOnValue then
            return false
        end
    else
        -- Boolean dependency: parent must be true
        if parentValue ~= true then
            return false
        end
    end
    
    -- Also check parent's parent chain
    return self:IsParentChainEnabled(config.dependsOn)
end

function Options:IsParentChainEnabled(parentPath)
    if not parentPath then return true end
    
    local parentWidget = self.widgets[parentPath]
    if not parentWidget then
        -- Parent widget not registered, check value directly (assume boolean)
        return addon:GetSettingValue(parentPath) == true
    end
    
    -- Check if parent's own dependency is satisfied
    if not self:IsWidgetDependencySatisfied(parentWidget.config) then
        return false
    end
    
    -- Recursively check parent's parent
    if parentWidget.config.dependsOn then
        return self:IsParentChainEnabled(parentWidget.config.dependsOn)
    end
    
    return true
end

function Options:SetWidgetEnabled(widget, enabled, widgetPath)
    local frame = widget.frame
    local control = widget.control
    
    if enabled then
        -- Enable
        if control.Enable then control:Enable() end
        if control.Text then control.Text:SetTextColor(1, 1, 1) end
        frame:SetAlpha(1.0)
        -- Re-enable mouse on all children
        for _, child in ipairs({frame:GetChildren()}) do
            if child.EnableMouse then child:EnableMouse(true) end
            if child.Enable then child:Enable() end
        end
    else
        -- Disable (grey out)
        if control.Disable then control:Disable() end
        if control.Text then control.Text:SetTextColor(0.5, 0.5, 0.5) end
        frame:SetAlpha(0.5)
        -- Disable mouse on all children to prevent interaction
        for _, child in ipairs({frame:GetChildren()}) do
            if child.EnableMouse then child:EnableMouse(false) end
            if child.Disable then child:Disable() end
        end
    end
    
    -- Cascade to dependents of this widget
    if widgetPath then
        self:UpdateDependentWidgets(widgetPath)
    end
end

function Options:InitializeDependencies()
    -- Update all dependent widgets based on current parent values
    for parentPath, _ in pairs(self.dependencies) do
        self:UpdateDependentWidgets(parentPath)
    end
end

-------------------------------------------------------------------------------
-- Widget Creators
-------------------------------------------------------------------------------

function Options:CreateSectionHeader(parent, text, yOffset)
    -- Create container frame for the header
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", 0, yOffset)
    frame:SetSize(400, 20)
    
    -- Left separator line
    local leftLine = frame:CreateTexture(nil, "ARTWORK")
    leftLine:SetHeight(1)
    leftLine:SetPoint("LEFT", 0, 0)
    leftLine:SetPoint("RIGHT", frame, "LEFT", 80, 0)
    leftLine:SetColorTexture(0.6, 0.5, 0.2, 0.8)  -- Gold-ish
    
    -- Header text (centered in section)
    local header = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("LEFT", leftLine, "RIGHT", 8, 0)
    header:SetText(text)
    header:SetTextColor(1, 0.82, 0)  -- Gold
    
    -- Right separator line
    local rightLine = frame:CreateTexture(nil, "ARTWORK")
    rightLine:SetHeight(1)
    rightLine:SetPoint("LEFT", header, "RIGHT", 8, 0)
    rightLine:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    rightLine:SetColorTexture(0.6, 0.5, 0.2, 0.8)  -- Gold-ish
    
    return yOffset - 24
end

function Options:CreateSubsectionHeader(parent, text, yOffset)
    -- Lighter-weight header for sub-sections within a main section
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", 0, yOffset)
    frame:SetSize(400, 16)
    
    -- Header text (left-aligned, smaller, dimmer)
    local header = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    header:SetPoint("LEFT", 4, 0)
    header:SetText(text)
    header:SetTextColor(0.8, 0.7, 0.5)  -- Muted gold
    
    -- Subtle line after text
    local line = frame:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("LEFT", header, "RIGHT", 8, 0)
    line:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    line:SetColorTexture(0.4, 0.35, 0.2, 0.5)  -- Very subtle
    
    return yOffset - 18
end

function Options:CreateCheckbox(parent, yOffset, config)
    -- Indent dependent settings for visual hierarchy
    local indent = config.dependsOn and 28 or 0
    
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", indent, yOffset)
    frame:SetSize(400 - indent, 22)
    
    local checkbox = CreateFrame("CheckButton", nil, frame, "InterfaceOptionsCheckButtonTemplate")
    checkbox:SetPoint("LEFT", 0, 0)
    
    local isModified = addon:IsSettingOverridden(config.path)
    
    -- Label with modified indicator
    local labelText = config.label
    if isModified then
        labelText = "|cffffd200*|r " .. config.label
    end
    checkbox.Text:SetText(labelText)
    checkbox.Text:SetFontObject("GameFontHighlight")
    
    -- Get/Set
    checkbox:SetChecked(addon:GetSettingValue(config.path) == true)
    
    checkbox:SetScript("OnClick", function(self)
        local value = self:GetChecked()
        addon:SetOverride(config.path, value)
        -- Only show * if value differs from default
        local defaultValue = addon:GetDefaultValue(config.path)
        if value ~= defaultValue then
            self.Text:SetText("|cffffd200*|r " .. config.label)
        else
            self.Text:SetText(config.label)
        end
        Options:RefreshModuleIfNeeded(config.path)
        Options:UpdateDependentWidgets(config.path)
    end)
    
    -- Tooltip helper function
    local function ShowTooltip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
        GameTooltip:SetMinimumWidth(280)  -- Ensure tooltips have enough width for longer content
        GameTooltip:AddLine(config.label, 1, 1, 1)
        GameTooltip:AddLine(config.tooltip, 1, 0.82, 0, true)
        -- Add default value in grey
        local defaultValue = addon:GetDefaultValue(config.path)
        if defaultValue ~= nil then
            local defaultText = defaultValue and "Enabled" or "Disabled"
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Default: " .. defaultText, 0.5, 0.5, 0.5)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Right-click to reset to default", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end
    
    -- Tooltip on checkbox
    checkbox:SetScript("OnEnter", function(self) ShowTooltip(self) end)
    checkbox:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    
    -- Make the text also show tooltip (create invisible hitbox over text)
    local textHitbox = CreateFrame("Frame", nil, frame)
    textHitbox:SetPoint("LEFT", checkbox.Text, "LEFT", 0, 0)
    textHitbox:SetPoint("RIGHT", checkbox.Text, "RIGHT", 0, 0)
    textHitbox:SetHeight(20)
    textHitbox:EnableMouse(true)
    textHitbox:SetScript("OnEnter", function(self) ShowTooltip(checkbox) end)
    textHitbox:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    textHitbox:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            checkbox:Click()
        elseif button == "RightButton" then
            addon:ClearOverride(config.path)
            checkbox:SetChecked(addon:GetSettingValue(config.path) == true)
            checkbox.Text:SetText(config.label)
            Options:RefreshModuleIfNeeded(config.path)
            Options:UpdateDependentWidgets(config.path)
        end
    end)
    
    -- Right-click to reset
    checkbox:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    checkbox:HookScript("OnClick", function(self, button)
        if button == "RightButton" then
            addon:ClearOverride(config.path)
            self:SetChecked(addon:GetSettingValue(config.path) == true)
            self.Text:SetText(config.label)
            Options:RefreshModuleIfNeeded(config.path)
            Options:UpdateDependentWidgets(config.path)
        end
    end)
    
    -- Register widget for dependency management
    Options:RegisterWidget(config.path, frame, checkbox, config)
    
    return yOffset - 24
end

function Options:CreateSlider(parent, yOffset, config)
    -- Indent dependent settings for visual hierarchy
    local indent = config.dependsOn and 28 or 0
    
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", indent, yOffset)
    frame:SetSize(450 - indent, 50)
    
    local isModified = addon:IsSettingOverridden(config.path)
    
    -- Label with modified indicator
    local labelText = config.label
    if isModified then
        labelText = "|cffffd200*|r " .. config.label
    end
    
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(labelText)
    
    -- Create slider using OptionsSliderTemplate for better visibility
    local sliderName = "VeevHUDSlider_" .. config.path:gsub("%.", "_")
    local slider = CreateFrame("Slider", sliderName, frame, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 5, -8)
    slider:SetWidth(180)
    slider:SetMinMaxValues(config.min, config.max)
    slider:SetValueStep(config.step)
    slider:SetObeyStepOnDrag(true)
    
    -- Add a visible background track
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("TOPLEFT", slider, "TOPLEFT", 8, -6)
    track:SetPoint("BOTTOMRIGHT", slider, "BOTTOMRIGHT", -8, 6)
    track:SetColorTexture(0.2, 0.2, 0.2, 0.8)
    
    -- Set min/max labels
    _G[sliderName .. "Low"]:SetText(tostring(config.min))
    _G[sliderName .. "High"]:SetText(tostring(config.max))
    _G[sliderName .. "Text"]:SetText("")  -- Don't use the top text
    
    -- Value text (to the right of slider)
    local valueText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    valueText:SetPoint("LEFT", slider, "RIGHT", 12, 0)
    
    local function FormatValue(v)
        if config.isPercent then
            return string.format("%.0f%%", v * 100)
        else
            return tostring(math.floor(v + 0.5))
        end
    end
    
    local currentValue = addon:GetSettingValue(config.path) or config.min
    
    -- Set initial slider value and display text
    slider:SetValue(currentValue)
    valueText:SetText(FormatValue(currentValue))
    
    -- Sync slider -> value text
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value / config.step + 0.5) * config.step
        valueText:SetText(FormatValue(value))
        addon:SetOverride(config.path, value)
        -- Only show * if value differs from default
        local defaultValue = addon:GetDefaultValue(config.path)
        if value ~= defaultValue then
            label:SetText("|cffffd200*|r " .. config.label)
        else
            label:SetText(config.label)
        end
        Options:RefreshModuleIfNeeded(config.path)
    end)
    
    -- Right-click on slider to reset
    slider:EnableMouse(true)
    slider:HookScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            addon:ClearOverride(config.path)
            local defaultValue = addon:GetSettingValue(config.path)
            self:SetValue(defaultValue)
            valueText:SetText(FormatValue(defaultValue))
            label:SetText(config.label)
            Options:RefreshModuleIfNeeded(config.path)
        end
    end)
    
    -- Tooltip helper function
    local function ShowTooltip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
        GameTooltip:AddLine(config.label, 1, 1, 1)
        GameTooltip:AddLine(config.tooltip, 1, 0.82, 0, true)
        -- Add default value in grey
        local defaultValue = addon:GetDefaultValue(config.path)
        if defaultValue ~= nil then
            local defaultText
            if config.isPercent then
                defaultText = string.format("%.0f%%", defaultValue * 100)
            else
                defaultText = tostring(defaultValue)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Default: " .. defaultText, 0.5, 0.5, 0.5)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Right-click to reset to default", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end
    
    -- Tooltip on slider
    slider:SetScript("OnEnter", function(self) ShowTooltip(self) end)
    slider:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    
    -- Make the label also show tooltip and support right-click reset
    local labelHitbox = CreateFrame("Button", nil, frame)
    labelHitbox:SetPoint("LEFT", label, "LEFT", 0, 0)
    labelHitbox:SetPoint("RIGHT", label, "RIGHT", 0, 0)
    labelHitbox:SetHeight(16)
    labelHitbox:EnableMouse(true)
    labelHitbox:RegisterForClicks("RightButtonUp")
    labelHitbox:SetScript("OnEnter", function(self) ShowTooltip(slider) end)
    labelHitbox:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    labelHitbox:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            addon:ClearOverride(config.path)
            local defaultValue = addon:GetSettingValue(config.path)
            slider:SetValue(defaultValue)
            valueText:SetText(FormatValue(defaultValue))
            label:SetText(config.label)
            Options:RefreshModuleIfNeeded(config.path)
        end
    end)
    
    frame.label = label
    frame.slider = slider
    frame.valueText = valueText
    
    -- Register widget for dependency management
    Options:RegisterWidget(config.path, frame, slider, config)
    
    return yOffset - 52
end

function Options:CreateDropdown(parent, yOffset, config)
    -- Indent dependent settings for visual hierarchy
    local indent = config.dependsOn and 28 or 0
    
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", indent, yOffset)
    frame:SetSize(400 - indent, 45)
    
    local isModified = addon:IsSettingOverridden(config.path)
    
    -- Label with modified indicator
    local labelText = config.label
    if isModified then
        labelText = "|cffffd200*|r " .. config.label
    end
    
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(labelText)
    
    -- Create dropdown
    local dropdownName = "VeevHUDDropdown_" .. config.path:gsub("%.", "_")
    local dropdown = CreateFrame("Frame", dropdownName, frame, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", label, "BOTTOMLEFT", -16, -2)
    
    local currentValue = addon:GetSettingValue(config.path)
    
    local function GetLabelForValue(value)
        for _, opt in ipairs(config.options) do
            if opt.value == value then
                return opt.label
            end
        end
        return tostring(value)
    end
    
    UIDropDownMenu_SetWidth(dropdown, 150)
    UIDropDownMenu_SetText(dropdown, GetLabelForValue(currentValue))
    
    UIDropDownMenu_Initialize(dropdown, function(self, level)
        for _, opt in ipairs(config.options) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.label
            info.value = opt.value
            info.checked = (addon:GetSettingValue(config.path) == opt.value)
            info.func = function()
                addon:SetOverride(config.path, opt.value)
                UIDropDownMenu_SetText(dropdown, opt.label)
                -- Only show * if value differs from default
                local defaultValue = addon:GetDefaultValue(config.path)
                if opt.value ~= defaultValue then
                    label:SetText("|cffffd200*|r " .. config.label)
                else
                    label:SetText(config.label)
                end
                Options:RefreshModuleIfNeeded(config.path)
                Options:UpdateDependentWidgets(config.path)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    
    -- Tooltip helper function
    local function ShowTooltip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
        GameTooltip:AddLine(config.label, 1, 1, 1)
        GameTooltip:AddLine(config.tooltip, 1, 0.82, 0, true)
        -- Add default value in grey
        local defaultValue = addon:GetDefaultValue(config.path)
        if defaultValue ~= nil then
            local defaultText = defaultValue
            for _, opt in ipairs(config.options) do
                if opt.value == defaultValue then
                    defaultText = opt.label
                    break
                end
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Default: " .. tostring(defaultText), 0.5, 0.5, 0.5)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Right-click to reset to default", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end
    
    -- Make the label show tooltip and handle right-click reset
    local labelHitbox = CreateFrame("Button", nil, frame)
    labelHitbox:SetPoint("LEFT", label, "LEFT", 0, 0)
    labelHitbox:SetPoint("RIGHT", label, "RIGHT", 0, 0)
    labelHitbox:SetHeight(16)
    labelHitbox:EnableMouse(true)
    labelHitbox:RegisterForClicks("RightButtonUp")
    labelHitbox:SetScript("OnEnter", function(self) ShowTooltip(dropdown) end)
    labelHitbox:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    labelHitbox:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            addon:ClearOverride(config.path)
            local defaultValue = addon:GetDefaultValue(config.path)
            UIDropDownMenu_SetText(dropdown, GetLabelForValue(defaultValue))
            label:SetText(config.label)  -- Remove * indicator
            Options:RefreshModuleIfNeeded(config.path)
            Options:UpdateDependentWidgets(config.path)
        end
    end)
    
    -- Also add right-click to dropdown button area
    local dropdownButton = _G[dropdownName .. "Button"]
    if dropdownButton then
        dropdownButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        dropdownButton:HookScript("OnClick", function(self, button)
            if button == "RightButton" then
                addon:ClearOverride(config.path)
                local defaultValue = addon:GetDefaultValue(config.path)
                UIDropDownMenu_SetText(dropdown, GetLabelForValue(defaultValue))
                label:SetText(config.label)  -- Remove * indicator
                Options:RefreshModuleIfNeeded(config.path)
                Options:UpdateDependentWidgets(config.path)
                CloseDropDownMenus()  -- Close any open menus
            end
        end)
    end
    
    frame.label = label
    frame.dropdown = dropdown
    
    -- Register widget for dependency management
    Options:RegisterWidget(config.path, frame, dropdown, config)
    
    return yOffset - 50
end

function Options:CreateFontDropdown(parent, yOffset, config)
    -- Font dropdown with preview and scrolling support
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", 0, yOffset)
    frame:SetSize(400, 45)
    
    local isModified = addon:IsSettingOverridden(config.path)
    
    -- Label with modified indicator
    local labelText = config.label
    if isModified then
        labelText = "|cffffd200*|r " .. config.label
    end
    
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(labelText)
    
    -- Use FontManager for font list and path lookups
    local FM = addon.FontManager
    local function GetFontList()
        return FM:GetFontList()
    end
    
    local function GetFontPath(fontName)
        return FM:GetFontPath(fontName)
    end
    
    local currentValue = addon:GetSettingValue(config.path) or addon.Constants.BUNDLED_FONT_NAME
    
    -- Create custom dropdown button (styled like UIDropDownMenu)
    local dropdownFrame = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
    dropdownFrame:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
    dropdownFrame:SetSize(200, 24)
    
    -- Dropdown background
    local DLeft = dropdownFrame:CreateTexture(nil, "ARTWORK")
    DLeft:SetSize(25, 64)
    DLeft:SetPoint("TOPLEFT", -17, 20)
    DLeft:SetTexture([[Interface\Glues\CharacterCreate\CharacterCreate-LabelFrame]])
    DLeft:SetTexCoord(0, 0.1953125, 0, 1)
    
    local DRight = dropdownFrame:CreateTexture(nil, "ARTWORK")
    DRight:SetSize(25, 64)
    DRight:SetPoint("TOPRIGHT", 17, 20)
    DRight:SetTexture([[Interface\Glues\CharacterCreate\CharacterCreate-LabelFrame]])
    DRight:SetTexCoord(0.8046875, 1, 0, 1)
    
    local DMiddle = dropdownFrame:CreateTexture(nil, "ARTWORK")
    DMiddle:SetHeight(64)
    DMiddle:SetPoint("LEFT", DLeft, "RIGHT")
    DMiddle:SetPoint("RIGHT", DRight, "LEFT")
    DMiddle:SetTexture([[Interface\Glues\CharacterCreate\CharacterCreate-LabelFrame]])
    DMiddle:SetTexCoord(0.1953125, 0.8046875, 0, 1)
    
    -- Selected font text (shows current font in its own typeface)
    local selectedText = dropdownFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    selectedText:SetPoint("LEFT", 8, 2)
    selectedText:SetPoint("RIGHT", -28, 2)
    selectedText:SetJustifyH("LEFT")
    selectedText:SetText(currentValue)
    pcall(function()
        selectedText:SetFont(GetFontPath(currentValue), 12, "")
    end)
    
    -- Dropdown arrow button
    local dropButton = CreateFrame("Button", nil, dropdownFrame)
    dropButton:SetSize(24, 24)
    dropButton:SetPoint("RIGHT", 4, 2)
    dropButton:SetNormalTexture([[Interface\ChatFrame\UI-ChatIcon-ScrollDown-Up]])
    dropButton:SetPushedTexture([[Interface\ChatFrame\UI-ChatIcon-ScrollDown-Down]])
    dropButton:SetHighlightTexture([[Interface\Buttons\UI-Common-MouseHilight]], "ADD")
    
    -- Scrollable dropdown list frame
    local listFrame = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    listFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    listFrame:SetSize(220, 200)
    listFrame:SetBackdrop({
        bgFile = [[Interface\DialogFrame\UI-DialogBox-Background-Dark]],
        edgeFile = [[Interface\DialogFrame\UI-DialogBox-Border]],
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    listFrame:SetBackdropColor(0, 0, 0, 0.9)
    listFrame:Hide()
    listFrame:EnableMouseWheel(true)
    
    -- Scroll frame inside list
    local scrollFrame = CreateFrame("ScrollFrame", nil, listFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 8, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)
    
    -- Content frame for scroll child
    local contentFrame = CreateFrame("Frame", nil, scrollFrame)
    contentFrame:SetSize(180, 1)  -- Height will be set dynamically
    scrollFrame:SetScrollChild(contentFrame)
    
    -- Font item buttons (created on demand)
    local fontButtons = {}
    local BUTTON_HEIGHT = 20
    
    local function UpdateList()
        local fonts = GetFontList()
        local currentSelection = addon:GetSettingValue(config.path) or addon.Constants.BUNDLED_FONT_NAME
        
        -- Create/update buttons
        for i, fontName in ipairs(fonts) do
            local btn = fontButtons[i]
            if not btn then
                btn = CreateFrame("Button", nil, contentFrame)
                btn:SetHeight(BUTTON_HEIGHT)
                btn:SetPoint("TOPLEFT", 0, -(i-1) * BUTTON_HEIGHT)
                btn:SetPoint("TOPRIGHT", 0, -(i-1) * BUTTON_HEIGHT)
                
                btn:SetHighlightTexture([[Interface\QuestFrame\UI-QuestTitleHighlight]], "ADD")
                
                local check = btn:CreateTexture(nil, "OVERLAY")
                check:SetSize(14, 14)
                check:SetPoint("LEFT", 2, 0)
                check:SetTexture([[Interface\Buttons\UI-CheckBox-Check]])
                btn.check = check
                
                local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                text:SetPoint("LEFT", check, "RIGHT", 4, 0)
                text:SetPoint("RIGHT", -4, 0)
                text:SetJustifyH("LEFT")
                btn.text = text
                
                fontButtons[i] = btn
            end
            
            btn.fontName = fontName
            btn.text:SetText(fontName)
            
            -- Set font for preview
            local fontPath = GetFontPath(fontName)
            pcall(function()
                btn.text:SetFont(fontPath, 12, "")
            end)
            
            -- Show/hide check
            if fontName == currentSelection then
                btn.check:Show()
            else
                btn.check:Hide()
            end
            
            btn:SetScript("OnClick", function()
                addon:SetOverride(config.path, fontName)
                selectedText:SetText(fontName)
                pcall(function()
                    selectedText:SetFont(GetFontPath(fontName), 12, "")
                end)
                -- Update modified indicator
                local defaultValue = addon:GetDefaultValue(config.path)
                if fontName ~= defaultValue then
                    label:SetText("|cffffd200*|r " .. config.label)
                else
                    label:SetText(config.label)
                end
                listFrame:Hide()
                Options:RefreshModuleIfNeeded(config.path)
            end)
            
            btn:Show()
        end
        
        -- Hide extra buttons
        for i = #fonts + 1, #fontButtons do
            fontButtons[i]:Hide()
        end
        
        -- Set content height
        contentFrame:SetHeight(#fonts * BUTTON_HEIGHT)
        
        -- Adjust list frame height (max 300px)
        local listHeight = math.min(#fonts * BUTTON_HEIGHT + 16, 300)
        listFrame:SetHeight(listHeight)
    end
    
    -- Toggle dropdown list
    local function ToggleList()
        if listFrame:IsShown() then
            listFrame:Hide()
        else
            UpdateList()
            listFrame:ClearAllPoints()
            listFrame:SetPoint("TOPLEFT", dropdownFrame, "BOTTOMLEFT", -4, 2)
            listFrame:Show()
        end
    end
    
    dropButton:SetScript("OnClick", ToggleList)
    dropdownFrame:EnableMouse(true)
    dropdownFrame:SetScript("OnMouseDown", ToggleList)
    
    -- Mouse wheel scrolling
    listFrame:SetScript("OnMouseWheel", function(self, delta)
        local scrollBar = _G[scrollFrame:GetName() .. "ScrollBar"]
        if scrollBar then
            local current = scrollBar:GetValue()
            local min, max = scrollBar:GetMinMaxValues()
            local step = BUTTON_HEIGHT * 3
            scrollBar:SetValue(math.max(min, math.min(max, current - delta * step)))
        end
    end)
    
    -- Close when settings panel hides
    frame:SetScript("OnHide", function()
        listFrame:Hide()
    end)
    
    -- Tooltip helper function
    local function ShowTooltip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
        GameTooltip:AddLine(config.label, 1, 1, 1)
        GameTooltip:AddLine(config.tooltip, 1, 0.82, 0, true)
        local defaultValue = addon:GetDefaultValue(config.path)
        if defaultValue then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Default: " .. defaultValue, 0.5, 0.5, 0.5)
        end
        if FM:HasLSM() then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Fonts from LibSharedMedia are available.", 0.5, 0.7, 0.5)
        else
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Install LibSharedMedia-3.0 for more fonts.", 0.7, 0.7, 0.5)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Right-click to reset to default", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end
    
    -- Tooltip and right-click reset for label
    local labelHitbox = CreateFrame("Button", nil, frame)
    labelHitbox:SetPoint("LEFT", label, "LEFT", 0, 0)
    labelHitbox:SetPoint("RIGHT", label, "RIGHT", 0, 0)
    labelHitbox:SetHeight(16)
    labelHitbox:EnableMouse(true)
    labelHitbox:RegisterForClicks("RightButtonUp")
    labelHitbox:SetScript("OnEnter", function(self) ShowTooltip(dropdownFrame) end)
    labelHitbox:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    labelHitbox:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            addon:ClearOverride(config.path)
            local defaultValue = addon:GetSettingValue(config.path)
            selectedText:SetText(defaultValue)
            pcall(function()
                selectedText:SetFont(GetFontPath(defaultValue), 12, "")
            end)
            label:SetText(config.label)
            listFrame:Hide()
            Options:RefreshModuleIfNeeded(config.path)
        end
    end)
    
    -- Right-click on dropdown to reset
    dropButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    dropButton:HookScript("OnClick", function(self, button)
        if button == "RightButton" then
            addon:ClearOverride(config.path)
            local defaultValue = addon:GetSettingValue(config.path)
            selectedText:SetText(defaultValue)
            pcall(function()
                selectedText:SetFont(GetFontPath(defaultValue), 12, "")
            end)
            label:SetText(config.label)
            listFrame:Hide()
            Options:RefreshModuleIfNeeded(config.path)
        end
    end)
    
    frame.label = label
    frame.dropdown = dropdownFrame
    frame.listFrame = listFrame
    
    -- Register widget for dependency management
    Options:RegisterWidget(config.path, frame, dropdownFrame, config)
    
    return yOffset - 50
end

-------------------------------------------------------------------------------
-- Refresh Helpers
-------------------------------------------------------------------------------

function Options:RefreshModuleIfNeeded(path)
    -- Determine which module needs refreshing based on path
    local moduleName = nil
    
    -- Font changes: refresh all fonts dynamically
    if path == "appearance.font" then
        addon.FontManager:RefreshAllFonts()
        return
    end
    
    if path:match("^icons%.") or path:match("^rows") then
        moduleName = "CooldownIcons"
        -- Scale is under icons but affects the whole HUD
        if path == "icons.scale" then
            Options:UpdateHUDPosition()
        end
        -- Aspect ratio affects both HUD icons and proc tracker
        if path == "icons.iconAspectRatio" then
            local cooldownIcons = addon:GetModule("CooldownIcons")
            local procTracker = addon:GetModule("ProcTracker")
            
            -- If Masque is active, prompt for reload since Masque doesn't handle dynamic resizing
            if cooldownIcons and cooldownIcons.MasqueGroup then
                StaticPopup_Show("VEEVHUD_RELOAD_UI")
                return  -- Skip refresh, reload will handle it
            end
            
            if procTracker and procTracker.Refresh then
                procTracker:Refresh()
            end
            -- CooldownIcons will be refreshed via normal moduleName path below
        end
    elseif path:match("^resourceBar%.") then
        moduleName = "ResourceBar"
        -- Size/enabled changes affect relative positioning of other bars
        -- Energy ticker style changes also affect layout (bar style takes space, spark doesn't)
        if path:match("height") or path:match("enabled") or path:match("energyTicker") then
            Options:RefreshAllBarPositions()
        end
    elseif path:match("^healthBar%.") then
        moduleName = "HealthBar"
        -- Size/enabled changes affect relative positioning of other bars
        if path:match("height") or path:match("enabled") then
            Options:RefreshAllBarPositions()
        end
    elseif path:match("^comboPoints%.") then
        moduleName = "ComboPoints"
        -- Height/enabled/width changes affect relative positioning of other bars
        if path:match("barHeight") or path:match("enabled") or path:match("width") then
            Options:RefreshAllBarPositions()
        end
    elseif path:match("^procTracker%.") then
        moduleName = "ProcTracker"
        -- Size changes affect relative positioning
        if path:match("iconSize") then
            Options:RefreshAllBarPositions()
        end
    elseif path:match("^layout%.") then
        -- Layout changes affect all bar positions
        addon.Layout:Refresh()
    elseif path:match("^anchor%.") then
        -- Update HUD position
        Options:UpdateHUDPosition()
    elseif path:match("^visibility%.") then
        -- Update HUD visibility/alpha
        addon:UpdateVisibility()
    end
    
    if moduleName then
        local module = addon:GetModule(moduleName)
        if module and module.Refresh then
            module:Refresh()
        end
    end
end

-- Recalculate and refresh all bar positions based on current sizes
function Options:RefreshAllBarPositions()
    local resourceBar = addon:GetModule("ResourceBar")
    local healthBar = addon:GetModule("HealthBar")
    local comboPoints = addon:GetModule("ComboPoints")
    local procTracker = addon:GetModule("ProcTracker")
    
    if resourceBar and resourceBar.Refresh then resourceBar:Refresh() end
    if healthBar and healthBar.Refresh then healthBar:Refresh() end
    if comboPoints and comboPoints.Refresh then comboPoints:Refresh() end
    if procTracker and procTracker.Refresh then procTracker:Refresh() end
end

function Options:UpdateHUDPosition()
    if addon.hudFrame then
        local db = addon.db.profile.anchor
        addon.hudFrame:ClearAllPoints()
        addon.hudFrame:SetPoint(
            db.point or "CENTER",
            UIParent,
            db.relativePoint or "CENTER",
            db.x or 0,
            db.y or -84
        )
        
        -- Apply scale (under icons config)
        local scale = addon.db.profile.icons.scale or 1.0
        addon.hudFrame:SetScale(scale)
    end
end

function Options:ShowURLDialog(url)
    -- Create the dialog frame if it doesn't exist
    if not self.urlDialog then
        local dialog = CreateFrame("Frame", "VeevHUDURLDialog", UIParent, "BasicFrameTemplateWithInset")
        dialog:SetSize(400, 100)
        dialog:SetPoint("CENTER")
        dialog:SetFrameStrata("DIALOG")
        dialog:SetMovable(true)
        dialog:EnableMouse(true)
        dialog:RegisterForDrag("LeftButton")
        dialog:SetScript("OnDragStart", dialog.StartMoving)
        dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
        dialog:Hide()
        
        dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        dialog.title:SetPoint("TOP", 0, -8)
        dialog.title:SetText("Copy URL")
        
        local instructions = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        instructions:SetPoint("TOP", 0, -30)
        instructions:SetText("|cff888888Press Ctrl+C to copy, then Escape to close|r")
        
        local editBox = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
        editBox:SetSize(360, 20)
        editBox:SetPoint("CENTER", 0, -10)
        editBox:SetAutoFocus(true)
        editBox:SetScript("OnEscapePressed", function() dialog:Hide() end)
        editBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        editBox:SetScript("OnChar", function(self) self:SetText(dialog.url); self:HighlightText() end)
        
        dialog.editBox = editBox
        self.urlDialog = dialog
    end
    
    self.urlDialog.url = url
    self.urlDialog.editBox:SetText(url)
    self.urlDialog:Show()
    self.urlDialog.editBox:SetFocus()
    self.urlDialog.editBox:HighlightText()
end

function Options:Open()
    if self.categoryID then
        Settings.OpenToCategory(self.categoryID)
    else
        addon.Utils:Print("Options panel not available. Use /vh help for commands.")
    end
end

-------------------------------------------------------------------------------
-- Register as module
-------------------------------------------------------------------------------

addon:RegisterModule("Options", Options)
