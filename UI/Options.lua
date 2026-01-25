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

-------------------------------------------------------------------------------
-- Helper: Check if a setting path is overridden by user
-------------------------------------------------------------------------------

function addon:IsSettingOverridden(path)
    -- Check if the current value differs from the default value
    local currentValue = self:GetSettingValue(path)
    local defaultValue = self:GetDefaultValue(path)
    
    -- Compare values (handles booleans, numbers, strings)
    return currentValue ~= defaultValue
end

-- Get the default value for a path
function addon:GetDefaultValue(path)
    local defaults = self.Constants.DEFAULTS.profile
    local keys = {strsplit(".", path)}
    
    local current = defaults
    for i, key in ipairs(keys) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[key]
    end
    
    return current
end

-- Get the current value for a path
function addon:GetSettingValue(path)
    local profile = self.db and self.db.profile or {}
    local keys = {strsplit(".", path)}
    
    local current = profile
    for i, key in ipairs(keys) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[key]
    end
    
    return current
end

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
    
    -- === POSITION & SCALE SECTION ===
    yOffset = self:CreateSectionHeader(container, "Position & Scale", yOffset)
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "anchor.y",
        label = "Vertical Offset",
        tooltip = "Moves the entire HUD up or down on your screen. Use negative numbers to move it below the center of your screen, positive to move it above. Default is -84 (slightly below center).",
        min = -500, max = 500, step = 1,
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.scale",
        label = "Global Scale",
        tooltip = "Makes everything in the HUD bigger or smaller. 100% is the normal size. Increase if you have trouble seeing the icons, decrease if they take up too much screen space.",
        min = 0.25, max = 3.0, step = 0.05,
        isPercent = true,
    })
    
    -- === VISIBILITY SECTION ===
    yOffset = yOffset - 8
    yOffset = self:CreateSectionHeader(container, "Visibility", yOffset)
    
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
    yOffset = yOffset - 16
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.iconSpacing",
        label = "Horizontal Icon Spacing",
        tooltip = "The horizontal gap in pixels between each ability icon within a row. A small gap (2-4) helps visually separate icons. Set to 0 for icons to touch horizontally.",
        min = 0, max = 10, step = 1,
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.rowSpacing",
        label = "Vertical Row Spacing",
        tooltip = "The vertical gap in pixels between rows of icons (e.g., between Core Rotation and Situational rows). Set to 0 for rows to touch vertically.",
        min = 0, max = 20, step = 1,
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.readyAlpha",
        label = "Ready Alpha",
        tooltip = "How visible icons are when the ability is ready to use. 100% means fully visible, lower values make ready abilities slightly transparent. Most people want this at 100%.",
        min = 0, max = 1.0, step = 0.05,
        isPercent = true,
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.cooldownAlpha",
        label = "Cooldown Alpha",
        tooltip = "How visible icons are when the ability is on cooldown. A lower value (like 30%) makes cooldown abilities fade out so you can focus on what's ready. Higher values keep them visible.",
        min = 0, max = 1.0, step = 0.05,
        isPercent = true,
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "icons.showCooldownText",
        label = "Show Cooldown Text",
        tooltip = "Displays the remaining cooldown time as numbers on top of each icon (e.g., '5s', '1.2'). Very helpful for tracking when abilities will be ready. Works alongside addons like OmniCC.",
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.cooldownSpiralAlpha",
        label = "Cooldown Spiral Opacity",
        tooltip = "Controls how dark the cooldown spiral 'clock sweep' appears. Higher values make it more visible. Set to 0% to disable the spiral entirely and only use text.",
        min = 0, max = 1.0, step = 0.1,
        isPercent = true,
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "icons.desaturateNoResources",
        label = "Desaturate When Unusable",
        tooltip = "Turns ability icons grey when they can't be used - whether due to insufficient resources, wrong stance, target requirements, or other conditions. This mimics how the default action bars work and helps you instantly see what's usable.",
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "icons.castFeedback",
        label = "Cast Feedback Animation",
        tooltip = "Plays a brief 'pop' animation (the icon scales up slightly then back down) whenever you successfully cast an ability. Gives satisfying visual feedback that your spell went off.",
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "icons.castFeedbackScale",
        label = "Cast Feedback Scale",
        tooltip = "How much the icon grows during the cast feedback animation. 110% is a subtle pop, 150%+ is more dramatic. Only applies if Cast Feedback Animation is enabled.",
        min = 1.05, max = 2.0, step = 0.05,
        isPercent = true,
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "icons.showAuraTracking",
        label = "Show Buff/Debuff Active State",
        tooltip = "When enabled, abilities that apply buffs or debuffs (like Intimidating Shout, Rend, Renew) will show the active duration with a glow while the effect is on a target. After it expires, the cooldown is shown. Disable this if you only want to see cooldowns.",
    })
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.readyGlowMode",
        label = "Ready Glow",
        tooltip = "Shows a proc-style glowing border when an ability becomes ready. 'Once Per Cooldown' prevents re-triggering if your resources fluctuate. 'Every Time Ready' glows each time conditions are met. Note: Reactive abilities (Execute, Overpower, etc.) always glow every time they become usable, regardless of this setting.",
        options = {
            { value = "once", label = "Once Per Cooldown" },
            { value = "always", label = "Every Time Ready" },
            { value = "disabled", label = "Disabled" },
        },
    })
    
    yOffset = self:CreateDropdown(container, yOffset, {
        path = "icons.resourceDisplayMode",
        label = "Resource Cost Display",
        tooltip = "Shows your progress toward affording an ability. 'Vertical Fill' darkens the icon from top down until you have enough resources. 'Bottom Bar' shows a small horizontal bar at the bottom of the icon. 'None' disables this feature.",
        options = {
            { value = "none", label = "None" },
            { value = "fill", label = "Vertical Fill" },
            { value = "bar", label = "Bottom Bar" },
        },
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
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "healthBar.height",
        label = "Height",
        tooltip = "How tall/thick the health bar is in pixels. Changing this will automatically adjust the position of the resource bar below it.",
        min = 4, max = 20, step = 1,
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "healthBar.showText",
        label = "Show Text",
        tooltip = "Displays your health percentage as text on the bar (e.g., '85%'). Useful for knowing exactly when you're in execute range or need to use a defensive.",
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "healthBar.classColored",
        label = "Class Colored",
        tooltip = "Colors the health bar using your class color (e.g., brown for Warriors, purple for Warlocks) instead of the standard green. Helps you quickly identify your health bar.",
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
    })
    
    yOffset = self:CreateSlider(container, yOffset, {
        path = "resourceBar.height",
        label = "Height",
        tooltip = "How tall/thick the resource bar is in pixels. Changing this will automatically adjust the position of elements above it (health bar, proc tracker).",
        min = 6, max = 30, step = 1,
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "resourceBar.showText",
        label = "Show Text",
        tooltip = "Displays your current resource amount as text on the bar (e.g., '4523' for mana or '67' for rage). Helpful if you need exact numbers rather than just the bar visual.",
    })
    
    yOffset = self:CreateCheckbox(container, yOffset, {
        path = "resourceBar.showSpark",
        label = "Show Spark",
        tooltip = "Displays a glowing 'spark' effect at the current fill position of the bar. This small visual flourish makes the bar look more polished and helps you track changes.",
    })
    
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
    })
    
    -- === SUPPORT SECTION ===
    yOffset = yOffset - 8
    yOffset = self:CreateSectionHeader(container, "Support", yOffset)
    
    local supportLabel = container:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    supportLabel:SetPoint("TOPLEFT", 0, yOffset)
    supportLabel:SetText("|cff888888Report bugs or request features:|r")
    supportLabel:SetJustifyH("LEFT")
    
    local issuesLink = CreateFrame("Button", nil, container)
    issuesLink:SetPoint("LEFT", supportLabel, "RIGHT", 4, 0)
    issuesLink:SetSize(240, 14)
    
    local linkText = issuesLink:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    linkText:SetPoint("LEFT")
    linkText:SetText("|cff69b8ffhttps://github.com/veev-code/VeevHUD/issues|r")
    issuesLink:SetFontString(linkText)
    
    issuesLink:SetScript("OnEnter", function(self)
        linkText:SetText("|cff99d1ff[Click to copy URL]|r")
    end)
    issuesLink:SetScript("OnLeave", function(self)
        linkText:SetText("|cff69b8ffhttps://github.com/veev-code/VeevHUD/issues|r")
    end)
    issuesLink:SetScript("OnClick", function()
        Options:ShowURLDialog("https://github.com/veev-code/VeevHUD/issues")
    end)
    
    yOffset = yOffset - 20
    
    -- === RESET BUTTON ===
    yOffset = yOffset - 8
    local resetButton = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    resetButton:SetPoint("TOPLEFT", 0, yOffset)
    resetButton:SetSize(140, 22)
    resetButton:SetText("Reset All to Defaults")
    resetButton:SetScript("OnClick", function()
        StaticPopupDialogs["VEEVHUD_RESET_CONFIRM"] = {
            text = "Reset all VeevHUD settings to defaults?",
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
        StaticPopup_Show("VEEVHUD_RESET_CONFIRM")
    end)
    
    yOffset = yOffset - 30
    
    -- Set scroll child height
    container:SetHeight(math.abs(yOffset) + 20)
end

-------------------------------------------------------------------------------
-- Widget Creators
-------------------------------------------------------------------------------

function Options:CreateSectionHeader(parent, text, yOffset)
    local header = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", 0, yOffset)
    header:SetText(text)
    header:SetTextColor(1, 0.82, 0)  -- Gold
    
    return yOffset - 20
end

function Options:CreateCheckbox(parent, yOffset, config)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", 0, yOffset)
    frame:SetSize(400, 22)
    
    local checkbox = CreateFrame("CheckButton", nil, frame, "InterfaceOptionsCheckButtonTemplate")
    checkbox:SetPoint("LEFT", 0, 0)
    
    local isModified = addon:IsSettingOverridden(config.path)
    
    -- Label with modified indicator
    local labelText = config.label
    if isModified then
        labelText = "|cffffd200*|r " .. labelText
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
    end)
    
    -- Tooltip helper function
    local function ShowTooltip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
        GameTooltip:AddLine(config.label, 1, 1, 1)
        GameTooltip:AddLine(config.tooltip, 1, 0.82, 0, true)
        -- Add default value in grey
        local defaultValue = addon:GetDefaultValue(config.path)
        if defaultValue ~= nil then
            local defaultText = defaultValue and "Enabled" or "Disabled"
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Default: " .. defaultText, 0.5, 0.5, 0.5)
        end
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
        end
    end)
    
    return yOffset - 24
end

function Options:CreateSlider(parent, yOffset, config)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", 0, yOffset)
    frame:SetSize(450, 50)
    
    local isModified = addon:IsSettingOverridden(config.path)
    
    -- Label with modified indicator
    local labelText = config.label
    if isModified then
        labelText = "|cffffd200*|r " .. labelText
    end
    
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(labelText)
    
    -- Create slider using UISliderTemplate (more compatible than OptionsSliderTemplate)
    local sliderName = "VeevHUDSlider_" .. config.path:gsub("%.", "_")
    local slider = CreateFrame("Slider", sliderName, frame, "UISliderTemplate")
    slider:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 5, -12)
    slider:SetWidth(200)
    slider:SetHeight(16)
    slider:SetMinMaxValues(config.min, config.max)
    slider:SetValueStep(config.step)
    slider:SetObeyStepOnDrag(true)
    slider:SetStepsPerPage(1)
    
    -- UISliderTemplate is bugged, need to create these elements manually
    if not slider.High then
        slider.High = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        slider.High:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, 0)
    end
    if not slider.Low then
        slider.Low = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        slider.Low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, 0)
    end
    if not slider.Text then
        slider.Text = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        slider.Text:SetPoint("BOTTOM", slider, "TOP", 0, 0)
    end
    
    -- Set min/max labels
    slider.Low:SetText(tostring(config.min))
    slider.High:SetText(tostring(config.max))
    slider.Text:SetText("")  -- Don't use the top text
    
    -- Value text (to the right of slider)
    local valueText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    valueText:SetPoint("LEFT", slider, "RIGHT", 12, 0)
    
    local currentValue = addon:GetSettingValue(config.path) or config.min
    slider:SetValue(currentValue)
    
    local function FormatValue(v)
        if config.isPercent then
            return string.format("%.0f%%", v * 100)
        else
            return tostring(math.floor(v + 0.5))
        end
    end
    
    valueText:SetText(FormatValue(currentValue))
    
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
        GameTooltip:Show()
    end
    
    -- Tooltip on slider
    slider:SetScript("OnEnter", function(self) ShowTooltip(self) end)
    slider:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    
    -- Make the label also show tooltip
    local labelHitbox = CreateFrame("Frame", nil, frame)
    labelHitbox:SetPoint("LEFT", label, "LEFT", 0, 0)
    labelHitbox:SetPoint("RIGHT", label, "RIGHT", 0, 0)
    labelHitbox:SetHeight(16)
    labelHitbox:EnableMouse(true)
    labelHitbox:SetScript("OnEnter", function(self) ShowTooltip(slider) end)
    labelHitbox:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    
    -- Right-click to reset (use HookScript to not break slider dragging)
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
    
    frame.label = label
    frame.slider = slider
    frame.valueText = valueText
    
    return yOffset - 52
end

function Options:CreateDropdown(parent, yOffset, config)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", 0, yOffset)
    frame:SetSize(400, 45)
    
    local isModified = addon:IsSettingOverridden(config.path)
    
    -- Label with modified indicator
    local labelText = config.label
    if isModified then
        labelText = "|cffffd200*|r " .. labelText
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
        GameTooltip:Show()
    end
    
    -- Make the label show tooltip
    local labelHitbox = CreateFrame("Frame", nil, frame)
    labelHitbox:SetPoint("LEFT", label, "LEFT", 0, 0)
    labelHitbox:SetPoint("RIGHT", label, "RIGHT", 0, 0)
    labelHitbox:SetHeight(16)
    labelHitbox:EnableMouse(true)
    labelHitbox:SetScript("OnEnter", function(self) ShowTooltip(dropdown) end)
    labelHitbox:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    
    frame.label = label
    frame.dropdown = dropdown
    
    return yOffset - 50
end

-------------------------------------------------------------------------------
-- Refresh Helpers
-------------------------------------------------------------------------------

function Options:RefreshModuleIfNeeded(path)
    -- Determine which module needs refreshing based on path
    local moduleName = nil
    
    if path:match("^icons%.") or path:match("^rows") then
        moduleName = "CooldownIcons"
        -- Scale is under icons but affects the whole HUD
        if path == "icons.scale" then
            Options:UpdateHUDPosition()
        end
    elseif path:match("^resourceBar%.") then
        moduleName = "ResourceBar"
        -- Size/enabled changes affect relative positioning of other bars
        if path:match("height") or path:match("enabled") then
            Options:RefreshAllBarPositions()
        end
    elseif path:match("^healthBar%.") then
        moduleName = "HealthBar"
        -- Size/enabled changes affect relative positioning of other bars
        if path:match("height") or path:match("enabled") then
            Options:RefreshAllBarPositions()
        end
    elseif path:match("^procTracker%.") then
        moduleName = "ProcTracker"
        -- Size changes affect relative positioning
        if path:match("iconSize") then
            Options:RefreshAllBarPositions()
        end
    elseif path:match("^anchor%.") then
        -- Update HUD position
        Options:UpdateHUDPosition()
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
    local procTracker = addon:GetModule("ProcTracker")
    
    if resourceBar and resourceBar.Refresh then resourceBar:Refresh() end
    if healthBar and healthBar.Refresh then healthBar:Refresh() end
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
