--[[
    VeevHUD - AceConfig Options

    Replaces the Blizzard Settings UI config with an AceConfigDialog window:
    - Draggable by default (AceGUI Frame)
    - Profiles via AceDBOptions-3.0
    - Per-specialization profile switching via LibDualSpec-1.0
]]

local ADDON_NAME, addon = ...
local C = addon.Constants

local Options = {}
addon.Options = Options

Options.isConfigOpen = false
Options._registered = false

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------

-- Static popup for reload UI prompt (Masque compatibility with aspect ratio changes)
StaticPopupDialogs["VEEVHUD_RELOAD_UI"] = StaticPopupDialogs["VEEVHUD_RELOAD_UI"] or {
	text = "Changing icon size or aspect ratio with Masque installed requires a UI reload.\n\nReload now?",
	button1 = "Reload",
	button2 = "Later",
	OnAccept = function()
		ReloadUI()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local function SafeCall(method, ...)
	if not method then return end
	local ok, err = pcall(method, ...)
	if not ok and addon.Utils and addon.Utils.LogError then
		addon.Utils:LogError(err)
	end
end

local function GetLSMFontValues()
	if type(AceGUIWidgetLSMlists) == "table" and type(AceGUIWidgetLSMlists.font) == "table" then
		return AceGUIWidgetLSMlists.font
	end

	local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
	return LSM and LSM:HashTable("font") or {}
end

local function PickValues(source, ...)
	local values = {}
	for i = 1, select("#", ...) do
		local key = select(i, ...)
		values[key] = source[key]
	end
	return values
end

-------------------------------------------------------------------------------
-- Change Application
-------------------------------------------------------------------------------

function Options:ApplySettingChange(path)
	if not addon or addon.fatalError then return end

	-- Positioning & scaling
	if path == "icons.scale" then
		addon:UpdateHUDScale()
		return
	end
	if path:match("^anchor%.") then
		addon:UpdateHUDPosition()
		return
	end

	-- Fonts
	if path == "appearance.font" then
		SafeCall(addon.FontManager and addon.FontManager.RefreshAllFonts, addon.FontManager)
		return
	end

	-- Visibility
	if path:match("^visibility%.") or path == "enabled" then
		addon:UpdateVisibility()
		return
	end

	-- Layout spacing
	if path:match("^layout%.") then
		SafeCall(addon.Layout and addon.Layout.Refresh, addon.Layout)
		return
	end

	-- Module-specific refreshes
	if path:match("^resourceBar%.") then
		local m = addon:GetModule("ResourceBar")
		SafeCall(m and m.Refresh, m)
		-- Size/enabled/ticker changes affect bar stacking positions
		if path:match("height") or path:match("enabled") or path:match("energyTicker") then
			self:RefreshAllBarPositions()
		end
		return
	end
	if path:match("^healthBar%.") then
		local m = addon:GetModule("HealthBar")
		SafeCall(m and m.Refresh, m)
		if path:match("height") or path:match("enabled") then
			self:RefreshAllBarPositions()
		end
		return
	end
	if path:match("^comboPoints%.") then
		local m = addon:GetModule("ComboPoints")
		SafeCall(m and m.Refresh, m)
		if path:match("barHeight") or path:match("enabled") or path:match("width") then
			self:RefreshAllBarPositions()
		end
		return
	end
	if path:match("^procTracker%.") then
		local m = addon:GetModule("ProcTracker")
		SafeCall(m and m.Refresh, m)
		if path:match("iconSize") then
			self:RefreshAllBarPositions()
		end
		return
	end

	-- Keybind text: lightweight updates (no full icon refresh needed)
	if path == "icons.showKeybindText" then
		local cooldownIcons = addon:GetModule("CooldownIcons")
		if cooldownIcons and cooldownIcons.UpdateAllKeybindText then
			cooldownIcons:UpdateAllKeybindText()
		end
		return
	end
	if path == "icons.keybindTextSize" then
		local cooldownIcons = addon:GetModule("CooldownIcons")
		if cooldownIcons and cooldownIcons.RefreshFonts then
			cooldownIcons:RefreshFonts(addon:GetFont())
		end
		return
	end

	-- Aspect ratio affects both HUD icons and proc tracker; may trigger Masque reload
	if path == "icons.iconAspectRatio" then
		local cooldownIcons = addon:GetModule("CooldownIcons")
		local procTracker = addon:GetModule("ProcTracker")
		if procTracker and procTracker.Refresh then
			procTracker:Refresh()
		end
		if cooldownIcons and cooldownIcons.Refresh then
			cooldownIcons:Refresh()
		end
		return
	end

	-- Row config changes need layout recalc
	if path:match("^rows%.") then
		SafeCall(addon.Layout and addon.Layout.Refresh, addon.Layout)
		local icons = addon:GetModule("CooldownIcons")
		SafeCall(icons and icons.Refresh, icons)
		-- Icon size changes require reload with Masque (same as aspect ratio)
		-- Debounce so the popup only appears after the slider is released
		if path:match("%.iconSize$") and icons and icons.MasqueGroup then
			if Options._masqueReloadTimer then
				Options._masqueReloadTimer:Cancel()
			end
			Options._masqueReloadTimer = C_Timer.NewTimer(0.5, function()
				Options._masqueReloadTimer = nil
				StaticPopup_Show("VEEVHUD_RELOAD_UI")
			end)
		end
		return
	end

	-- Other icon-related settings
	if path:match("^icons%.") then
		local icons = addon:GetModule("CooldownIcons")
		SafeCall(icons and icons.Refresh, icons)
		return
	end

	-- Fallback: profile-wide refresh.
	SafeCall(addon.OnProfileChanged, addon)
end

-- Recalculate positions for all vertically-stacked bar elements
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

-------------------------------------------------------------------------------
-- Options Table
-------------------------------------------------------------------------------

function Options:BuildOptionsTable()
	local rowSettingAll = {
		[C.ROW_SETTING.NONE] = "None",
		[C.ROW_SETTING.PRIMARY] = "Primary",
		[C.ROW_SETTING.PRIMARY_SECONDARY] = "Primary + Secondary",
		[C.ROW_SETTING.SECONDARY_UTILITY] = "Secondary + Utility",
		[C.ROW_SETTING.UTILITY] = "Utility",
		[C.ROW_SETTING.ALL] = "All",
	}

	local rowSettingDynamicSort = PickValues(rowSettingAll,
		C.ROW_SETTING.NONE,
		C.ROW_SETTING.PRIMARY,
		C.ROW_SETTING.PRIMARY_SECONDARY
	)

	local resourceDisplayModeValues = {
		[C.RESOURCE_DISPLAY_MODE.PREDICTION] = "Prediction (Recommended)",
		[C.RESOURCE_DISPLAY_MODE.FILL] = "Fill",
		[C.RESOURCE_DISPLAY_MODE.BAR] = "Bar",
	}

	local tickerStyleValues = {
		[C.TICKER_STYLE.SPARK] = "Spark",
		[C.TICKER_STYLE.BAR] = "Bar",
	}

	local textFormatValues = {
		[C.TEXT_FORMAT.CURRENT] = "Current",
		[C.TEXT_FORMAT.PERCENT] = "Percent",
		[C.TEXT_FORMAT.BOTH] = "Both",
		[C.TEXT_FORMAT.NONE] = "None",
	}

	local function get(info)
		return addon.Database:GetSettingValue(info.arg)
	end

	local function set(info, value)
		addon.Database:SetOverride(info.arg, value)
		Options:ApplySettingChange(info.arg)
	end

	local function colorGet(info)
		local c = addon.Database:GetSettingValue(info.arg)
		if type(c) == "table" then
			return c.r or 1, c.g or 1, c.b or 1
		end
		return 1, 1, 1
	end

	local function colorSet(info, r, g, b)
		addon.Database:SetOverride(info.arg, { r = r, g = g, b = b })
		Options:ApplySettingChange(info.arg)
	end

	-- Post-process: append "Default: X" to every setting's desc tooltip
	local function enrichDescsWithDefaults(args)
		for _, opt in pairs(args) do
			if type(opt) == "table" then
				if opt.args then
					enrichDescsWithDefaults(opt.args)
				end
				if opt.arg and opt.desc then
					local path = opt.arg
					local originalDesc = opt.desc
					local isPercent = opt.isPercent
					local valuesRef = opt.values
					-- LSM widgets (font, statusbar, etc.) use keys as display names
					local isLSMWidget = opt.dialogControl and opt.dialogControl:match("^LSM")
					opt.desc = function(info)
						local text = type(originalDesc) == "function" and originalDesc(info) or originalDesc
						local default = addon.Database:GetDefaultValue(path)
						if default == nil or type(default) == "table" then return text end
						local formatted
						if type(default) == "boolean" then
							formatted = default and "Enabled" or "Disabled"
						elseif type(default) == "number" and isPercent then
							formatted = math.floor(default * 100 + 0.5) .. "%"
						elseif type(default) == "number" then
							-- Clean up trailing zeros for decimals
							if default == math.floor(default) then
								formatted = tostring(math.floor(default))
							else
								formatted = string.format("%.2g", default)
							end
						elseif type(default) == "string" then
							if isLSMWidget then
								-- LSM keys are already human-readable names (e.g., "Expressway, Bold")
								formatted = default
							else
								-- For regular selects, look up the display label
								local vals = type(valuesRef) == "function" and valuesRef() or valuesRef
								if type(vals) == "table" and vals[default] then
									formatted = vals[default]
								else
									formatted = default
								end
							end
						else
							formatted = tostring(default)
						end
						return text .. "\n\n|cff888888Default: " .. formatted .. "|r"
					end
				end
			end
		end
	end

	-- Profiles (AceDBOptions + LibDualSpec)
	local profilesOptions
	do
		local AceDBOptions = LibStub and LibStub("AceDBOptions-3.0", true)
		if AceDBOptions and addon.db then
			profilesOptions = AceDBOptions:GetOptionsTable(addon.db)
			profilesOptions.order = 99

			local LibDualSpec = LibStub and LibStub("LibDualSpec-1.0", true)
			if LibDualSpec then
				SafeCall(LibDualSpec.EnhanceOptions, LibDualSpec, profilesOptions, addon.db)
			end
		end
	end

	-- Per-row options (Primary / Secondary / Utility)
	local rowArgs = {}
	if addon.db and addon.db.profile and type(addon.db.profile.rows) == "table" then
		for i, row in ipairs(addon.db.profile.rows) do
			local rowKey = "row" .. i
			rowArgs[rowKey] = {
				type = "group",
				name = row.name or ("Row " .. i),
				order = i,
				args = {
					enabled = {
						type = "toggle",
						name = "Enabled",
						desc = "Enables or disables this row entirely. When disabled, no abilities will be shown in this row and it won't take up any space on the HUD.",
						arg = ("rows.%d.enabled"):format(i),
						order = 1,
					},
					sizeSettings = {
						type = "group",
						name = "Size",
						inline = true,
						order = 2,
						disabled = function()
							return addon.db and addon.db.profile and addon.db.profile.rows and addon.db.profile.rows[i] and not addon.db.profile.rows[i].enabled
						end,
						args = {
							iconSize = {
								type = "range",
								name = "Icon Size",
								desc = "The size of each ability icon in this row, in pixels. Each row can have different-sized icons — for example, larger icons for your main rotation and smaller ones for utility.",
								min = 16, max = 96, step = 1,
								arg = ("rows.%d.iconSize"):format(i),
								order = 1,
							},
							maxIcons = {
								type = "range",
								name = "Max Icons",
								desc = "The maximum number of ability icons that can appear in this row. If you assign more spells than this limit, the extra ones won't be shown.",
								min = 1, max = 48, step = 1,
								arg = ("rows.%d.maxIcons"):format(i),
								order = 2,
							},
						},
					},
					flowSettings = {
						type = "group",
						name = "Flow Layout",
						inline = true,
						order = 3,
						disabled = function()
							return addon.db and addon.db.profile and addon.db.profile.rows and addon.db.profile.rows[i] and not addon.db.profile.rows[i].enabled
						end,
						args = {
							flowLayout = {
								type = "toggle",
								name = "Enabled",
								desc = "When enabled, this row wraps its icons into multiple lines instead of displaying them all in a single long line. The 'Icons Per Row' setting controls the maximum icons per line.\n\nTo avoid a sparse last row, icons are moved down from the previous row — for example, 8 icons at 6 per row becomes 5 and 3 instead of 6 and 2.",
								arg = ("rows.%d.flowLayout"):format(i),
								order = 1,
							},
							iconsPerRow = {
								type = "range",
								name = "Icons Per Row",
								desc = "The maximum number of icons on each line before wrapping to the next. Rows fill from the top, so earlier rows are always full.\n\nTo avoid a sparse last row, icons are moved down from the previous row — for example, 14 icons at 6 per row becomes 6, 5, 3 instead of 6, 6, 2.",
								min = 2, max = 20, step = 1,
								arg = ("rows.%d.iconsPerRow"):format(i),
								disabled = function()
									return not (addon.db and addon.db.profile and addon.db.profile.rows and addon.db.profile.rows[i] and addon.db.profile.rows[i].flowLayout)
								end,
								order = 2,
							},
						},
					},
				},
			}
		end
	end

	local optionsTable = {
		type = "group",
		name = "VeevHUD",
		get = get,
		set = set,
		args = {
			header = {
				type = "description",
				name = "|cff888888Version " .. (addon.version or "1.0.0") .. "|r",
				order = 0,
				fontSize = "medium",
			},
			general = {
				type = "group",
				name = "General",
				order = 1,
				args = {
					positionAndScale = {
						type = "group",
						name = "Position and Scale",
						inline = true,
						order = 1,
						args = {
							scale = {
								type = "range",
								name = "Global Scale",
								desc = "Makes everything in the HUD bigger or smaller. 100% is the normal size. Increase if you have trouble seeing the icons, decrease if they take up too much screen space.",
								min = 0.25, max = 3.0, step = 0.05,
								isPercent = true,
								arg = "icons.scale",
								order = 2,
							},
							hOffset = {
								type = "range",
								name = "Horizontal Offset",
								desc = "Moves the entire HUD left or right from the center of the screen. Negative values shift it left, positive values shift it right.",
								min = -500, max = 500, step = 1,
								arg = "anchor.x",
								order = 3,
							},
							vOffset = {
								type = "range",
								name = "Vertical Offset",
								desc = "Moves the entire HUD up or down on your screen. Negative values move it below center, positive values move it above.",
								min = -500, max = 500, step = 1,
								arg = "anchor.y",
								order = 4,
							},
							font = {
								type = "select",
								name = "Font",
								desc = "The font used for all text in the HUD, including cooldown timers, stack counts, health/resource values, and proc durations.\n\nIf you have font-sharing addons installed (SharedMedia, etc.), their fonts will appear here automatically.",
								dialogControl = "LSM30_Font",
								values = GetLSMFontValues,
								arg = "appearance.font",
								order = 5,
							},
						},
					},
					visibility = {
						type = "group",
						name = "Visibility",
						inline = true,
						order = 2,
						args = {
							outOfCombatAlpha = {
								type = "range",
								name = "Out of Combat Opacity",
								desc = "Controls the HUD's visibility when not in combat. Use this to fade the HUD when out of combat so it's less distracting. 100% = fully visible, 50% = half transparent, 0% = invisible.\n\nNote: This setting is ignored while the config panel is open so you can see the HUD while configuring.",
								min = 0, max = 1.0, step = 0.05,
								isPercent = true,
								arg = "visibility.outOfCombatAlpha",
								order = 1,
							},
							hideOnFlightPath = {
								type = "toggle",
								name = "Hide on Flight Path",
								desc = "Automatically hides the HUD when you're on a flight path (taxi). The HUD will reappear when you land. Useful to keep your screen clean while traveling.\n\nNote: This setting is ignored while the config panel is open so you can see the HUD while configuring.",
								arg = "visibility.hideOnFlightPath",
								order = 2,
							},
						},
					},
					animations = {
						type = "group",
						name = "Animations",
						inline = true,
						order = 3,
						args = {
							smoothBars = {
								type = "toggle",
								name = "Smooth Bar Animation",
								desc = "When enabled, health bars, resource bars, and the resource-cost overlay on ability icons animate smoothly instead of jumping when values change.",
								arg = "animations.smoothBars",
								order = 1,
							},
							dimTransition = {
								type = "toggle",
								name = "Smooth Dim Transition",
								desc = "When icons fade in or out (e.g., dimming on cooldown), the transition is gradual instead of instant. Disable for snappier visual feedback.",
								arg = "animations.dimTransition",
								order = 2,
							},
						},
					},
					layout = {
						type = "group",
						name = "Layout",
						inline = true,
						order = 4,
						args = {
							iconRowGap = {
								type = "range",
								name = "Icon Row Gap",
								desc = "The vertical space (in pixels) between your ability icon rows and the bars above them (health bar, resource bar, or combo points). Increase for more breathing room, decrease to keep things compact.",
								min = -10, max = 100, step = 1,
								arg = "layout.iconRowGap",
								order = 1,
							},
						},
					},
				},
			},

			icons = {
				type = "group",
				name = "Icons",
				childGroups = "tab",
				order = 2,
				args = {
					appearance = {
						type = "group",
						name = "Appearance",
						order = 1,
						args = {
							masqueTip = {
								type = "description",
								name = "|cff888888Tip: Install the Masque addon to reskin ability icons with custom button styles.|r",
								order = 0,
								hidden = function()
									return IsAddOnLoaded and IsAddOnLoaded("Masque")
								end,
							},
							shapeAndZoom = {
								type = "group",
								name = "Shape & Zoom",
								inline = true,
								order = 1,
								args = {
									iconAspectRatio = {
										type = "select",
										name = "Aspect Ratio",
										desc = "Makes icons shorter to create a more vertically compact HUD. Width stays the same while height shrinks, cropping the top/bottom of icon textures. The health and resource bars stay in place; ability rows shift up to fill the space. Affects both HUD icons and proc icons.",
										values = {
											[1.0] = "1:1 (Square)",
											[1.33] = "4:3 (Compact)",
											[2.0] = "2:1 (Ultra Compact)",
										},
										arg = "icons.iconAspectRatio",
										set = function(info, value)
											addon.Database:SetOverride(info.arg, value)
											Options:ApplySettingChange(info.arg)
											local cooldownIcons = addon:GetModule("CooldownIcons")
											if cooldownIcons and cooldownIcons.MasqueGroup then
												StaticPopup_Show("VEEVHUD_RELOAD_UI")
											end
										end,
										order = 1,
									},
									iconZoom = {
										type = "range",
										name = "Icon Zoom",
										desc = "Zooms into each icon's artwork, cropping the edges. Useful for removing the default border that some spell textures have. 0% shows the full icon, 16% is a subtle crop, 30% is more aggressive.",
										min = 0, max = 0.6, step = 0.01,
										isPercent = true,
										arg = "icons.iconZoom",
										order = 2,
									},
								},
							},
							spacing = {
								type = "group",
								name = "Spacing",
								inline = true,
								order = 2,
								args = {
									iconSpacing = {
										type = "range",
										name = "Icon Spacing",
										desc = "The horizontal gap in pixels between each ability icon within a row. A small gap (2-4) helps visually separate icons. Set to 0 for icons to touch. Negative values allow overlap, which may look better with certain skins.",
										min = -10, max = 20, step = 1,
										arg = "icons.iconSpacing",
										order = 1,
									},
									rowSpacing = {
										type = "range",
										name = "Row Spacing",
										desc = "The vertical gap in pixels between rows of icons (e.g., between Primary and Secondary rows). Set to 0 for rows to touch. Negative values allow overlap, which may look better with certain skins.",
										min = -10, max = 40, step = 1,
										arg = "icons.rowSpacing",
										order = 2,
									},
									primarySecondaryGap = {
										type = "range",
										name = "Primary/Secondary Gap",
										desc = "Extra vertical gap between the Primary and Secondary rows, added on top of the base Row Spacing. Helps visually separate your main rotation abilities from your secondary cooldowns. Set to 0 to use only the base row spacing.",
										min = -10, max = 200, step = 1,
										arg = "icons.primarySecondaryGap",
										order = 3,
									},
									sectionGap = {
										type = "range",
										name = "Utility Section Gap",
										desc = "Extra vertical space before the Utility row. Creates a visible gap between your damage/healing abilities and your utility spells (interrupts, dispels, cooldowns, etc.).",
										min = -10, max = 200, step = 1,
										arg = "icons.sectionGap",
										order = 4,
									},
								},
							},
						},
					},
					alpha = {
						type = "group",
						name = "Alpha",
						order = 2,
						args = {
							opacity = {
								type = "group",
								name = "Icon Opacity",
								inline = true,
								order = 1,
								args = {
									readyAlpha = {
										type = "range",
										name = "Ready Alpha",
										desc = "How visible icons are when the ability is ready to use. 100% means fully visible, lower values make ready abilities slightly transparent. Most people want this at 100%.",
										min = 0, max = 1.0, step = 0.05,
										isPercent = true,
										arg = "icons.readyAlpha",
										order = 1,
									},
									cooldownAlpha = {
										type = "range",
										name = "Cooldown Alpha",
										desc = "How visible icons are when on cooldown (for rows with Dim On Cooldown enabled). A lower value (like 30%) makes cooldown abilities fade out so you can focus on what's ready. Higher values keep them visible.",
										min = 0, max = 1.0, step = 0.05,
										isPercent = true,
										arg = "icons.cooldownAlpha",
										order = 2,
									},
								},
							},
							visualFeedback = {
								type = "group",
								name = "Visual Feedback",
								inline = true,
								order = 2,
								args = {
									desaturateNoResources = {
										type = "toggle",
										name = "Desaturate Without Resources",
										desc = "Turns icons grey when you can't use the ability — for example, not enough mana/rage/energy, wrong stance, or missing a required buff. Works the same way as WoW's default action bars.\n\nAutomatically disabled while resting in an inn or city to avoid constant grey-outs on combat abilities.",
										arg = "icons.desaturateNoResources",
										order = 1,
									},
								},
							},
						},
					},
					cooldowns = {
						type = "group",
						name = "Cooldowns",
						order = 3,
						args = {
							display = {
								type = "group",
								name = "Display",
								inline = true,
								order = 1,
								args = {
									showCooldownTextOn = {
										type = "select",
										name = "Cooldown Text",
										desc = "Displays the remaining cooldown time as numbers on top of each icon. When enabled, VeevHUD shows its own text and hides text from addons like OmniCC. Select which rows display cooldown text.",
										values = rowSettingAll,
										arg = "icons.showCooldownTextOn",
										order = 1,
									},
									showCooldownSpiralOn = {
										type = "select",
										name = "Cooldown Spiral",
										desc = "Shows the dark 'clock sweep' overlay on abilities that are on cooldown. This visual helps you see at a glance how much time remains. Select which rows display the cooldown spiral.",
										values = rowSettingAll,
										arg = "icons.showCooldownSpiralOn",
										order = 2,
									},
									showGCDOn = {
										type = "select",
										name = "Show GCD",
										desc = "Controls which rows display the Global Cooldown (GCD) spinner. The GCD is the brief ~1.5 second lockout after using most abilities. Showing GCD helps you see when you can press your next ability.",
										values = rowSettingAll,
										arg = "icons.showGCDOn",
										order = 3,
									},
								},
							},
							effects = {
								type = "group",
								name = "Effects",
								inline = true,
								order = 2,
								args = {
									dimOnCooldown = {
										type = "select",
										name = "Dim On Cooldown",
										desc = "Controls which rows fade out (become transparent) when abilities are on cooldown. The amount they fade is controlled by the 'Cooldown Alpha' setting.\n\nRows without dimming stay at full brightness and use greying-out to indicate unavailability instead. Many players keep the Primary row undimmed so their core rotation stays visually prominent.",
										values = rowSettingAll,
										arg = "icons.dimOnCooldown",
										order = 1,
									},
									cooldownBlingRows = {
										type = "select",
										name = "Cooldown Bling",
										desc = "Shows WoW's native sparkle effect when a cooldown finishes. This is purely cooldown-based and does not indicate usability — the spell may still be unusable due to resources or other conditions.\n\nNote: This also triggers when the GCD finishes, matching WoW's default action bar behavior.",
										values = rowSettingAll,
										arg = "icons.cooldownBlingRows",
										order = 2,
									},
								},
							},
						},
					},
					resources = {
						type = "group",
						name = "Resources",
						order = 4,
						args = {
							mode = {
								type = "group",
								name = "Mode",
								inline = true,
								order = 1,
								args = {
									resourceDisplayRows = {
										type = "select",
										name = "Rows",
										desc = "Choose which rows show resource cost information on their icons. When enabled, you can see at a glance whether you have enough mana, rage, or energy to cast each ability. The visual style is controlled by Resource Display Mode below.",
										values = rowSettingAll,
										arg = "icons.resourceDisplayRows",
										order = 1,
									},
									resourceDisplayMode = {
										type = "select",
										name = "Display Mode",
										desc = "How ability icons show whether you can afford to cast them:\n\n'Fill' — Darkens the icon from top to bottom proportional to missing resources. Simple and easy to read.\n\n'Bar' — Shows a small colored bar at the bottom of each icon that fills up as you gain resources.\n\n'Prediction' (Recommended) — Extends the cooldown sweep to include resource regeneration time. Instead of just showing cooldown, the icon shows how long until you can actually cast — accounting for both cooldown AND resource cost. If an ability is off cooldown but you can't afford it, you'll see the sweep counting down to when you'll have enough.\n\nPrediction accuracy varies by resource: Energy and Mana predictions are very accurate (tick-aware). Rage falls back to Fill since rage income is unpredictable.",
										values = resourceDisplayModeValues,
										arg = "icons.resourceDisplayMode",
										order = 2,
										disabled = function() return addon.db and addon.db.profile and addon.db.profile.icons.resourceDisplayRows == C.ROW_SETTING.NONE end,
									},
								},
							},
							appearance = {
								type = "group",
								name = "Appearance",
								inline = true,
								order = 2,
								disabled = function() return addon.db and addon.db.profile and addon.db.profile.icons.resourceDisplayRows == C.ROW_SETTING.NONE end,
								args = {
									resourceBarHeight = {
										type = "range",
										name = "Bar Height",
										desc = "Height of the small resource bar shown at the bottom of each icon. Only visible when Resource Display Mode is set to 'Bar'.",
										min = 1, max = 16, step = 1,
										arg = "icons.resourceBarHeight",
										order = 1,
										disabled = function()
											return addon.db and addon.db.profile and addon.db.profile.icons and addon.db.profile.icons.resourceDisplayMode ~= C.RESOURCE_DISPLAY_MODE.BAR
										end,
									},
									resourceFillAlpha = {
										type = "range",
										name = "Fill Alpha",
										desc = "How dark the resource cost overlay appears on icons. Higher values make it more obvious when you can't afford an ability. Applies to Fill mode and Prediction mode's fill fallback (used for rage and when predictions are unavailable).",
										min = 0.05, max = 1.0, step = 0.05,
										isPercent = true,
										arg = "icons.resourceFillAlpha",
										order = 2,
										disabled = function()
											local icons = addon.db and addon.db.profile and addon.db.profile.icons
											if not icons then return true end
											local mode = icons.resourceDisplayMode
											return mode ~= C.RESOURCE_DISPLAY_MODE.FILL and mode ~= C.RESOURCE_DISPLAY_MODE.PREDICTION
										end,
									},
								},
							},
						},
					},
					behavior = {
						type = "group",
						name = "Behavior",
						order = 5,
						args = {
							auraTracking = {
								type = "group",
								name = "Aura Tracking",
								inline = true,
								order = 1,
								args = {
									showAuraTracking = {
										type = "toggle",
										name = "Enabled",
										desc = "When enabled, abilities that apply buffs or debuffs (like Intimidating Shout, Rend, Renew) will show the active duration with a glow while the effect is on a target. After it expires, the cooldown is shown. Disable this if you only want to see cooldowns.",
										arg = "icons.showAuraTracking",
										order = 1,
									},
									auraTargettargetSupport = {
										type = "toggle",
										name = "Target-of-Target Support",
										desc = "Also tracks buffs and debuffs on your target's target. This is useful if you use target-of-target macros:\n\n- Target the boss, see your heals on the tank (the boss's target)\n- Target the tank, see your DoTs on the boss (the tank's target)\n\nExample macros:\n/cast [@target,help] [@targettarget,help] [@player] Renew\n/cast [@target,harm] [@targettarget,harm] [] Shadow Word: Pain",
										arg = "icons.auraTargettargetSupport",
										order = 2,
										disabled = function()
											return addon.db and addon.db.profile and not addon.db.profile.icons.showAuraTracking
										end,
									},
								},
							},
							castFeedback = {
								type = "group",
								name = "Cast Feedback",
								inline = true,
								order = 2,
								args = {
									castFeedbackRows = {
										type = "select",
										name = "Rows",
										desc = "Plays a brief 'pop' animation (the icon scales up slightly then back down) whenever you successfully cast an ability. Gives satisfying visual feedback that your spell went off. Select which rows show this animation.",
										values = rowSettingAll,
										arg = "icons.castFeedbackRows",
										order = 1,
									},
									castFeedbackScale = {
										type = "range",
										name = "Scale",
										desc = "How much the icon grows during the cast feedback animation. 110% is a subtle pop, 150%+ is more dramatic. Only applies if Cast Feedback is enabled.",
										min = 1.05, max = 2.0, step = 0.05,
										isPercent = true,
										arg = "icons.castFeedbackScale",
										order = 2,
										disabled = function()
											return addon.db and addon.db.profile and addon.db.profile.icons and addon.db.profile.icons.castFeedbackRows == C.ROW_SETTING.NONE
										end,
									},
								},
							},
							readyGlow = {
								type = "group",
								name = "Ready Glow",
								inline = true,
								order = 3,
								args = {
									readyGlowRows = {
										type = "select",
										name = "Rows",
										desc = "Shows a glowing border around ability icons when they come off cooldown and are ready to use. Only triggers while in combat. Select which rows display this effect.",
										values = rowSettingAll,
										arg = "icons.readyGlowRows",
										order = 1,
									},
									readyGlowAlwaysRows = {
										type = "select",
										name = "Persistent Glow",
										desc = "Controls which rows re-trigger the ready glow each time an ability becomes usable. On these rows, the glow plays for the configured duration every time usability changes (e.g., gaining enough resources, target entering Execute range). Rows not selected here play the glow only once per cooldown cycle.\n\nNote: Reactive abilities (like Execute or Overpower) always re-glow every time they become usable, regardless of this setting.",
										values = rowSettingAll,
										arg = "icons.readyGlowAlwaysRows",
										order = 2,
										disabled = function()
											return addon.db and addon.db.profile and addon.db.profile.icons and addon.db.profile.icons.readyGlowRows == C.ROW_SETTING.NONE
										end,
									},
									readyGlowDuration = {
										type = "range",
										name = "Duration",
										desc = "How long each ready glow animation lasts (in seconds). After this time, the glow fades out. On rows with Persistent Glow enabled, the glow will re-trigger at this duration each time usability changes.",
										min = 0.1, max = 5.0, step = 0.05,
										arg = "icons.readyGlowDuration",
										order = 3,
										disabled = function()
											return addon.db and addon.db.profile and addon.db.profile.icons and addon.db.profile.icons.readyGlowRows == C.ROW_SETTING.NONE
										end,
									},
								},
							},
							rangeSorting = {
								type = "group",
								name = "Range & Sorting",
								inline = true,
								order = 4,
								args = {
									showRangeIndicator = {
										type = "select",
										name = "Range Indicator",
										desc = "Shows a red overlay on spell icons when your current target is out of range. Shows when an ability is usable but out of range — even during cooldown, giving you a heads-up on positioning. When resources are insufficient, the grey/resource indicators take priority instead.\n\nNote: Only shows when you have a target. Spells without a range component (self-buffs, etc.) are not affected.",
										values = rowSettingAll,
										arg = "icons.showRangeIndicator",
										order = 1,
									},
									dynamicSortRows = {
										type = "select",
										name = "Dynamic Sorting",
										desc = "Controls which rows dynamically reorder icons by 'actionable time' (least time remaining first).\n\nWhen enabled, the ability needing attention soonest is always on the left. Useful for DOT classes (see which debuff is closest to expiring) and cooldown-heavy classes (see which ability is ready next).\n\nTie-breaker: When multiple abilities are ready, they sort by their original row position — so your row order acts as a priority list and the leftmost icon is always the next best spell to cast.\n\nThe 'actionable time' is max(cooldown remaining, buff/debuff remaining).",
										values = rowSettingDynamicSort,
										arg = "icons.dynamicSortRows",
										order = 2,
									},
									dynamicSortAnimation = {
										type = "toggle",
										name = "Sort Animation",
										desc = "When dynamic sorting is enabled, icons slide smoothly to their new positions instead of snapping instantly. The animation is quick and snappy to avoid being distracting during combat. Disable for instant repositioning.",
										arg = "icons.dynamicSortAnimation",
										order = 3,
										disabled = function()
											return addon.db and addon.db.profile and addon.db.profile.icons and addon.db.profile.icons.dynamicSortRows == C.ROW_SETTING.NONE
										end,
									},
								},
							},
							keybinds = {
								type = "group",
								name = "Keybinds",
								inline = true,
								order = 5,
								args = {
									showKeybindText = {
										type = "select",
										name = "Rows",
										desc = "Displays the keyboard shortcut for each ability in the bottom-right corner. VeevHUD scans your action bars to find where each spell is placed. Modifiers are abbreviated: Shift=S, Ctrl=C, Alt=A (e.g., Shift+X becomes 'SX').\n\nSupports Bartender4, ElvUI, Dominos. If you move spells or change keybinds, the display updates automatically.",
										values = rowSettingAll,
										arg = "icons.showKeybindText",
										order = 1,
									},
									keybindTextSize = {
										type = "range",
										name = "Text Size",
										desc = "The font size for keybind text in pixels. Larger values make the text more readable but take up more space on the icon.",
										min = 6, max = 24, step = 1,
										arg = "icons.keybindTextSize",
										order = 2,
										disabled = function()
											return addon.db and addon.db.profile and addon.db.profile.icons and addon.db.profile.icons.showKeybindText == C.ROW_SETTING.NONE
										end,
									},
								},
							},
						},
					},
				},
			},

			bars = {
				type = "group",
				name = "Bars",
				childGroups = "tab",
				order = 3,
				args = {
					resource = {
						type = "group",
						name = "Resource Bar",
						order = 3,
						args = {
							enabled = { type = "toggle", name = "Enabled", desc = "Shows a bar displaying your current mana, rage, or energy (depending on your class). Appears between the health bar and the ability icon rows.", arg = "resourceBar.enabled", order = 1 },
							sizeSettings = {
								type = "group",
								name = "Size",
								inline = true,
								order = 2,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.enabled end,
								args = {
									width = { type = "range", name = "Width", desc = "How wide the resource bar is in pixels.", min = 100, max = 600, step = 1, arg = "resourceBar.width", order = 1 },
									height = { type = "range", name = "Height", desc = "How tall/thick the resource bar is in pixels. Changing this will automatically adjust the position of elements above it.", min = 4, max = 60, step = 1, arg = "resourceBar.height", order = 2 },
								},
							},
							textSettings = {
								type = "group",
								name = "Text",
								inline = true,
								order = 3,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.enabled end,
								args = {
									textFormat = { type = "select", name = "Text Format", desc = "Controls what text is shown on the resource bar.\n\n'Current Value' shows your actual resource (e.g., '4523' for mana, '67' for energy).\n'Percent' shows your resource percentage (e.g., '85%').\n'Both' shows both (e.g., '4523 (85%)').\n'None' hides the text entirely.", values = textFormatValues, arg = "resourceBar.textFormat", order = 1 },
									textSize = { type = "range", name = "Text Size", desc = "Font size for the resource text. Larger sizes are easier to read but may overflow small bars.", min = 6, max = 24, step = 1, arg = "resourceBar.textSize", order = 2, disabled = function() return addon.db and addon.db.profile and addon.db.profile.resourceBar.textFormat == C.TEXT_FORMAT.NONE end },
								},
							},
							colorSettings = {
								type = "group",
								name = "Color",
								inline = true,
								order = 4,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.enabled end,
								args = {
									powerColor = { type = "toggle", name = "Power Color", desc = "Colors the bar based on your resource type — blue for mana, red for rage, yellow for energy. Uncheck to use a custom color instead.", arg = "resourceBar.powerColor", order = 1 },
									color = { type = "color", name = "Bar Color", desc = "The custom color for the resource bar. Only used when Power Color is unchecked.", hasAlpha = false, get = colorGet, set = colorSet, arg = "resourceBar.color", order = 2, disabled = function() local db = addon.db and addon.db.profile and addon.db.profile.resourceBar; return db and db.powerColor end },
									showGradient = { type = "toggle", name = "Gradient", desc = "Adds a subtle light-to-dark gradient across the bar, giving it more visual depth instead of a flat solid color.", arg = "resourceBar.showGradient", order = 3 },
								},
							},
							sparkSettings = {
								type = "group",
								name = "Spark",
								inline = true,
								order = 5,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.enabled end,
								args = {
									showSpark = { type = "toggle", name = "Enabled", desc = "Shows a bright highlight at the bar's current fill point — the glowing line where the filled and empty portions meet. Adds visual polish.", arg = "resourceBar.showSpark", order = 1 },
									sparkWidth = { type = "range", name = "Width", desc = "How wide the spark highlight is in pixels. Larger values create a broader, more prominent glow.", min = 1, max = 32, step = 1, arg = "resourceBar.sparkWidth", order = 2 },
									sparkOverflow = { type = "range", name = "Overflow", desc = "How far the spark glow extends beyond the top and bottom edges of the bar (in pixels). Higher values create a taller spark that 'overflows' past the bar.", min = 0, max = 32, step = 1, arg = "resourceBar.sparkOverflow", order = 3 },
									sparkHideFullEmpty = { type = "toggle", name = "Hide at Full/Empty", desc = "Hides the spark when the bar is completely full or completely empty, since there's no meaningful fill point to highlight in those states.", arg = "resourceBar.sparkHideFullEmpty", order = 4 },
								},
							},
						},
					},
				energyTicker = {
					type = "group",
					name = "Energy Ticker",
					order = 4,
					hidden = function() return addon.playerClass ~= C.CLASS.ROGUE and addon.playerClass ~= C.CLASS.DRUID end,
						args = {
							enabled = { type = "toggle", name = "Enabled", desc = "Shows progress toward the next energy tick (energy regenerates every 2 seconds). Helps you time abilities to maximize energy efficiency.", arg = "resourceBar.energyTicker.enabled", order = 1, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.enabled end },
							style = { type = "select", name = "Style", desc = "'Ticker Bar' shows a separate thin bar below the resource bar that fills as the next tick approaches.\n\n'Spark' shows a moving spark overlay on the resource bar itself, which is more subtle.", values = tickerStyleValues, arg = "resourceBar.energyTicker.style", order = 2, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.energyTicker.enabled end },
							showAtFullEnergy = { type = "toggle", name = "Show at Full Energy", desc = "Keep the tick indicator running even when at full energy. Useful for timing openers — you can see exactly when the next tick will occur and use energy right before it arrives.", arg = "resourceBar.energyTicker.showAtFullEnergy", order = 3, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.energyTicker.enabled end },
							barSettings = {
								type = "group",
								name = "Bar Settings",
								inline = true,
								order = 4,
								disabled = function()
									local t = addon.db and addon.db.profile and addon.db.profile.resourceBar and addon.db.profile.resourceBar.energyTicker
									return not t or not t.enabled or t.style ~= C.TICKER_STYLE.BAR
								end,
								args = {
									height = { type = "range", name = "Bar Height", desc = "How tall the energy ticker bar is in pixels.", min = 1, max = 12, step = 1, arg = "resourceBar.energyTicker.height", order = 1 },
									offsetY = { type = "range", name = "Bar Offset", desc = "Moves the energy ticker bar up or down relative to the resource bar. Positive values move it down, negative values move it up.", min = -24, max = 24, step = 1, arg = "resourceBar.energyTicker.offsetY", order = 2 },
									color = { type = "color", name = "Color", desc = "The color used for the energy ticker bar.", hasAlpha = false, get = colorGet, set = colorSet, arg = "resourceBar.energyTicker.color", order = 3 },
									showGradient = { type = "toggle", name = "Gradient", desc = "Adds a subtle light-to-dark gradient across the energy ticker bar for more visual depth.", arg = "resourceBar.energyTicker.showGradient", order = 4 },
								},
							},
							sparkSettings = {
								type = "group",
								name = "Spark Settings",
								inline = true,
								order = 5,
								disabled = function()
									local t = addon.db and addon.db.profile and addon.db.profile.resourceBar and addon.db.profile.resourceBar.energyTicker
									return not t or not t.enabled or t.style ~= C.TICKER_STYLE.SPARK
								end,
								args = {
									sparkWidth = { type = "range", name = "Spark Width", desc = "How wide the tick spark is in pixels.", min = 1, max = 32, step = 1, arg = "resourceBar.energyTicker.sparkWidth", order = 1 },
									sparkHeight = { type = "range", name = "Spark Height", desc = "How tall the tick spark is relative to the resource bar. Values above 1.0 make the spark extend beyond the bar edges.", min = 0.5, max = 4.0, step = 0.1, arg = "resourceBar.energyTicker.sparkHeight", order = 2 },
								},
							},
						},
					},
				manaTicker = {
					type = "group",
					name = "Mana Ticker",
					order = 5,
					hidden = function()
						local mc = { MAGE = true, PRIEST = true, WARLOCK = true, PALADIN = true, DRUID = true, SHAMAN = true, HUNTER = true }
						return not mc[addon.playerClass]
					end,
						args = {
							enabled = { type = "toggle", name = "Enabled", desc = "Shows a moving spark on the resource bar indicating when your next mana tick will arrive. Mana regenerates in periodic ticks, and casting at the wrong time can delay your next tick — this indicator helps you cast at the optimal moment.", arg = "resourceBar.manaTicker.enabled", order = 1, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.enabled end },
							style = {
								type = "select",
								name = "Style",
								desc = "'Outside 5 Second Rule' — Only shows the tick timer when you haven't cast a spell in the last 5 seconds (when you're getting full spirit-based mana regeneration).\n\n'Next Full Tick' (Recommended) — Always active. After you cast a spell, it predicts exactly when your first full-rate mana tick will arrive and counts down to it. Cast right after the tick completes to get the most mana before your next spell.",
								values = {
									outside5sr = "Outside 5-second rule",
									nextfulltick = "Next full tick",
								},
								arg = "resourceBar.manaTicker.style",
								order = 2,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.manaTicker.enabled end,
							},
							sparkWidth = { type = "range", name = "Spark Width", desc = "How wide the mana tick spark is in pixels.", min = 1, max = 32, step = 1, arg = "resourceBar.manaTicker.sparkWidth", order = 3, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.manaTicker.enabled end },
							sparkHeight = { type = "range", name = "Spark Height", desc = "How tall the mana tick spark is relative to the resource bar. Values above 1.0 make it extend beyond the bar edges.", min = 0.5, max = 4.0, step = 0.1, arg = "resourceBar.manaTicker.sparkHeight", order = 4, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.manaTicker.enabled end },
						},
					},
					health = {
						type = "group",
						name = "Health Bar",
						order = 2,
						args = {
							enabled = { type = "toggle", name = "Enabled", desc = "Shows a bar displaying your current health above the resource bar. Gives you a quick glance at your survivability without looking at your unit frame.", arg = "healthBar.enabled", order = 1 },
							sizeSettings = {
								type = "group",
								name = "Size",
								inline = true,
								order = 2,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.healthBar.enabled end,
								args = {
									width = { type = "range", name = "Width", desc = "How wide the health bar is in pixels.", min = 100, max = 600, step = 1, arg = "healthBar.width", order = 1 },
									height = { type = "range", name = "Height", desc = "How tall/thick the health bar is in pixels. Changing this will automatically adjust the position of elements above it.", min = 4, max = 60, step = 1, arg = "healthBar.height", order = 2 },
								},
							},
							textSettings = {
								type = "group",
								name = "Text",
								inline = true,
								order = 3,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.healthBar.enabled end,
								args = {
									textFormat = { type = "select", name = "Text Format", desc = "Controls what text is shown on the health bar.\n\n'Current Value' shows your actual health (e.g., '3256').\n'Percent' shows your health percentage (e.g., '71%').\n'Both' shows both (e.g., '3256 (71%)').\n'None' hides the text entirely.", values = textFormatValues, arg = "healthBar.textFormat", order = 1 },
									textSize = { type = "range", name = "Text Size", desc = "Font size for the health text. Larger sizes are easier to read but may overflow small bars.", min = 6, max = 24, step = 1, arg = "healthBar.textSize", order = 2, disabled = function() return addon.db and addon.db.profile and addon.db.profile.healthBar.textFormat == C.TEXT_FORMAT.NONE end },
								},
							},
							colorSettings = {
								type = "group",
								name = "Color",
								inline = true,
								order = 4,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.healthBar.enabled end,
								args = {
									classColored = { type = "toggle", name = "Class Colored", desc = "Colors the health bar using your class color (e.g., brown for Warriors, purple for Warlocks) instead of the standard green.", arg = "healthBar.classColored", order = 1 },
									color = { type = "color", name = "Bar Color", desc = "The custom color for the health bar. Only used when Class Colored is unchecked.", hasAlpha = false, get = colorGet, set = colorSet, arg = "healthBar.color", order = 2, disabled = function() local db = addon.db and addon.db.profile and addon.db.profile.healthBar; return db and db.classColored end },
									showGradient = { type = "toggle", name = "Gradient", desc = "Adds a subtle light-to-dark gradient across the bar for more visual depth.", arg = "healthBar.showGradient", order = 3 },
								},
							},
						},
					},
				combopoints = {
					type = "group",
					name = "Combo Points",
					order = 6,
					hidden = function() return addon.playerClass ~= C.CLASS.ROGUE and addon.playerClass ~= C.CLASS.DRUID end,
						args = {
							enabled = { type = "toggle", name = "Enabled", desc = "Shows combo point bars below the resource bar. For Druids, this only appears while in Cat Form.", arg = "comboPoints.enabled", order = 1 },
							sizeLayout = {
								type = "group",
								name = "Size & Layout",
								inline = true,
								order = 2,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.comboPoints.enabled end,
								args = {
									width = { type = "range", name = "Width", desc = "The total width of the combo points display in pixels.", min = 100, max = 600, step = 1, arg = "comboPoints.width", order = 1 },
									barHeight = { type = "range", name = "Bar Height", desc = "The height of each combo point bar in pixels. Smaller values create a more subtle display.", min = 2, max = 30, step = 1, arg = "comboPoints.barHeight", order = 2 },
									barSpacing = { type = "range", name = "Bar Spacing", desc = "The gap in pixels between each individual combo point segment.", min = 0, max = 20, step = 1, arg = "comboPoints.barSpacing", order = 3 },
									offsetY = { type = "range", name = "Gap Above Icons", desc = "Extra vertical space in pixels between the combo points display and the ability icon rows below it.", min = 0, max = 120, step = 1, arg = "comboPoints.offsetY", order = 4 },
								},
							},
							appearance = {
								type = "group",
								name = "Appearance",
								inline = true,
								order = 3,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.comboPoints.enabled end,
								args = {
									color = { type = "color", name = "Color", desc = "The color used for active combo point segments.", hasAlpha = false, get = colorGet, set = colorSet, arg = "comboPoints.color", order = 1 },
									showGradient = { type = "toggle", name = "Gradient", desc = "Adds a subtle light-to-dark gradient to each combo point segment for more visual depth.", arg = "comboPoints.showGradient", order = 2 },
								},
							},
						},
					},
					procs = {
						type = "group",
						name = "Proc Tracker",
						order = 1,
						args = {
							enabled = { type = "toggle", name = "Enabled", desc = "Shows small icons for important temporary buffs (procs) — like a Warrior's Enrage or Flurry, a Mage's Clearcasting, etc. These icons appear above the health bar and are only visible while the buff is active.", arg = "procTracker.enabled", order = 1 },
							layout = {
								type = "group",
								name = "Layout",
								inline = true,
								order = 2,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.procTracker.enabled end,
								args = {
									iconSize = { type = "range", name = "Icon Size", desc = "How big the proc icons are in pixels. These are typically smaller than ability icons since they're just indicators. 20-28 pixels works well for most people.", min = 12, max = 140, step = 1, arg = "procTracker.iconSize", order = 1 },
									iconSpacing = { type = "range", name = "Icon Spacing", desc = "The gap in pixels between each proc icon when multiple procs are active at once.", min = 0, max = 40, step = 1, arg = "procTracker.iconSpacing", order = 2 },
									gapAboveHealthBar = { type = "range", name = "Gap Above Health Bar", desc = "The gap in pixels between the health bar and the proc icons. Increase if procs feel too close to the health bar.", min = 0, max = 200, step = 1, arg = "procTracker.gapAboveHealthBar", order = 3 },
								},
							},
							effects = {
								type = "group",
								name = "Effects",
								inline = true,
								order = 3,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.procTracker.enabled end,
								args = {
									showDuration = { type = "toggle", name = "Show Duration", desc = "Displays the remaining time on proc buffs as text on the icon. Disable if you prefer a cleaner look or if it overlaps with stack counts.", arg = "procTracker.showDuration", order = 1 },
									activeGlow = { type = "toggle", name = "Active Glow", desc = "Shows a glowing animated border around active proc icons, making them stand out and drawing your eye to important buffs.", arg = "procTracker.activeGlow", order = 2 },
									backdropGlowIntensity = { type = "range", name = "Backdrop Glow Intensity", desc = "Controls the brightness of the soft colored halo that appears behind each proc icon. Higher values make the glow more prominent. Set to 0 to turn it off completely.", min = 0, max = 0.8, step = 0.05, arg = "procTracker.backdropGlowIntensity", order = 3 },
									backdropGlowSize = { type = "range", name = "Backdrop Glow Size", desc = "How far the backdrop glow extends outward from each proc icon. Larger values create a wider, softer halo.", min = 0.5, max = 6.0, step = 0.1, arg = "procTracker.backdropGlowSize", order = 4 },
									slideAnimation = { type = "toggle", name = "Slide Animation", desc = "When procs appear or disappear, the remaining icons smoothly slide to re-center instead of snapping instantly. Disable for instant repositioning.", arg = "procTracker.slideAnimation", order = 5 },
								},
							},
						},
					},
				},
			},

			rows = {
				type = "group",
				name = "Rows",
				childGroups = "tab",
				order = 4,
				args = rowArgs,
			},

			spells = {
				type = "group",
				name = "Spells",
				order = 5,
				args = {
					_desc = {
						type = "description",
						name = "Spell configuration uses a standalone window with drag-and-drop reordering.\nCustomize which spells appear on your HUD, their order, and which row they belong to.",
						order = 1,
						fontSize = "medium",
					},
					openButton = {
						type = "execute",
						name = "Open Spell Configuration",
						desc = "Opens the spell configuration window where you can enable/disable spells, reorder them, and move them between rows using drag-and-drop.",
						func = function()
							local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
							if not AceConfigDialog then return end
							local widget = AceConfigDialog.OpenFrames[ADDON_NAME]
							local frame = widget and widget.frame
							local cx, cy
							if frame and frame:IsShown() then
								cx, cy = frame:GetCenter()
							end
							AceConfigDialog:Close(ADDON_NAME)
							local spellsOptions = addon:GetModule("SpellsOptions")
							if spellsOptions and spellsOptions.Open then
								spellsOptions:Open(cx, cy)
							end
						end,
						order = 2,
						width = "double",
					},
				},
			},

			support = {
				type = "group",
				name = "Support",
				order = 7,
				args = {
					discordInfo = {
						type = "description",
						name = "|cff888888Join the |cffffffffVeev Addons Discord|r|cff888888 for feedback, suggestions, and bug reports:|r",
						fontSize = "medium",
						order = 1,
					},
					discordLink = {
						type = "input",
						name = "Discord URL",
						desc = "Press Ctrl+C to copy the URL.",
						get = function() return C.DISCORD_URL end,
						set = function() end,
						order = 2,
						width = "double",
					},
				},
			},

			profiles = profilesOptions,
		},
	}

	-- Enrich all setting tooltips with their default values
	enrichDescsWithDefaults(optionsTable.args)

	return optionsTable
end

function Options:Register()
	if self._registered then return end

	local AceConfig = LibStub and LibStub("AceConfig-3.0", true)
	local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
	if not AceConfig or not AceConfigDialog then
		if addon.Utils then
			addon.Utils:LogError("AceConfig libraries missing; options disabled.")
		end
		return
	end

	local optionsTable = self:BuildOptionsTable()
	AceConfig:RegisterOptionsTable(ADDON_NAME, optionsTable)

	-- Default size for the draggable AceConfigDialog window.
	AceConfigDialog:SetDefaultSize(ADDON_NAME, 760, 660)

	self._registered = true
end

function Options:HookDialogState()
	local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
	if not AceConfigDialog then return end

	local widget = AceConfigDialog.OpenFrames[ADDON_NAME]
	local frame = widget and widget.frame
	if not frame then return end

	if not frame._veevhudStateHooked then
		frame._veevhudStateHooked = true
		frame:HookScript("OnShow", function()
			Options.isConfigOpen = true
			if addon and addon.UpdateVisibility then
				addon:UpdateVisibility()
			end
		end)
		frame:HookScript("OnHide", function()
			Options.isConfigOpen = false
			if addon and addon.UpdateVisibility then
				addon:UpdateVisibility()
			end
		end)
	end

	Options.isConfigOpen = frame:IsShown() or false
end

-------------------------------------------------------------------------------
-- Module Lifecycle
-------------------------------------------------------------------------------

function Options:Initialize()
	self:Register()
end

function Options:Open(centerX, centerY)
	self:Register()

	local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
	if not AceConfigDialog then
		if addon.Utils then
			addon.Utils:Print("Options unavailable (AceConfigDialog missing).")
		end
		return
	end

	AceConfigDialog:Open(ADDON_NAME)
	self:HookDialogState()

	-- Reposition to a specific location (e.g. where SpellsOptions was).
	-- Deferred: AceConfigDialog and SelectGroup may reset position during the
	-- current frame, so we apply our override on the next frame.
	if centerX and centerY then
		C_Timer.After(0, function()
			local widget = AceConfigDialog.OpenFrames[ADDON_NAME]
			local frame = widget and widget.frame
			if frame then
				frame:ClearAllPoints()
				frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", centerX, centerY)
			end
		end)
	end
end

-------------------------------------------------------------------------------
-- Register as module
-------------------------------------------------------------------------------

addon:RegisterModule("Options", Options)
