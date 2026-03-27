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

-- Patch LSM30_Sound to collapse label space when name is empty.
-- Stock widget always reserves 18px for its label; this hides it and shrinks to 26px.
do
	local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
	if AceGUI then
		local origCreate = AceGUI.Create
		AceGUI.Create = function(self, widgetType, ...)
			local widget = origCreate(self, widgetType, ...)
			if widget and widgetType == "LSM30_Sound" and not widget._veevhudPatched then
				widget._veevhudPatched = true
				local origSetLabel = widget.SetLabel
				widget.SetLabel = function(w, text)
					origSetLabel(w, text or "")
					if text and text ~= "" and text ~= " " then
						w.frame.label:Show()
						w:SetHeight(44)
						w.alignoffset = 31
					else
						w.frame.label:Hide()
						w:SetHeight(26)
						w.alignoffset = 12
					end
				end
			end
			return widget
		end
	end
end

-- Shared value tables for text outline dropdowns (used by both BuildOptions and BuildBuffRemindersOptions)
local textOutlineValues = {
	[C.TEXT_OUTLINE.OUTLINE] = "Outline",
	[C.TEXT_OUTLINE.SHADOW] = "Shadow",
	[C.TEXT_OUTLINE.BOTH] = "Both",
	[C.TEXT_OUTLINE.NONE] = "None",
}
local textOutlineSorting = {
	C.TEXT_OUTLINE.OUTLINE,
	C.TEXT_OUTLINE.SHADOW,
	C.TEXT_OUTLINE.BOTH,
	C.TEXT_OUTLINE.NONE,
}
local textOutlineValuesInherit = {
	[C.TEXT_OUTLINE.INHERIT] = "Inherit (Global)",
	[C.TEXT_OUTLINE.OUTLINE] = "Outline",
	[C.TEXT_OUTLINE.SHADOW] = "Shadow",
	[C.TEXT_OUTLINE.BOTH] = "Both",
	[C.TEXT_OUTLINE.NONE] = "None",
}
local textOutlineSortingInherit = {
	C.TEXT_OUTLINE.INHERIT,
	C.TEXT_OUTLINE.OUTLINE,
	C.TEXT_OUTLINE.SHADOW,
	C.TEXT_OUTLINE.BOTH,
	C.TEXT_OUTLINE.NONE,
}

Options.isConfigOpen = false
Options._registered = false

-- Screen-aware offset limits (full screen dimension in each direction, rounded up to nearest 100)
local screenW = math.ceil((GetScreenWidth and GetScreenWidth() or 1920) / 100) * 100
local screenH = math.ceil((GetScreenHeight and GetScreenHeight() or 1080) / 100) * 100

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------


local DESC_COLOR = "cff888888"
local function Dim(text)
	return "|" .. DESC_COLOR .. text .. "|r"
end

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

local function GetLSMStatusbarValues()
	if type(AceGUIWidgetLSMlists) == "table" and type(AceGUIWidgetLSMlists.statusbar) == "table" then
		return AceGUIWidgetLSMlists.statusbar
	end

	local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
	return LSM and LSM:HashTable("statusbar") or {}
end

local function GetLSMSoundValues()
	if type(AceGUIWidgetLSMlists) == "table" and type(AceGUIWidgetLSMlists.sound) == "table" then
		return AceGUIWidgetLSMlists.sound
	end

	local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
	return LSM and LSM:HashTable("sound") or {}
end

-- Factory for consistent LSM30_Sound dropdown options.
-- Pass a table of overrides (name, desc, arg, get, set, order, disabled, etc.)
local SOUND_DROPDOWN_WIDTH = 0.7
local function SoundDropdown(overrides)
	local opt = {
		type = "select",
		name = "",
		dialogControl = "LSM30_Sound",
		width = SOUND_DROPDOWN_WIDTH,
		values = GetLSMSoundValues,
	}
	for k, v in pairs(overrides) do
		opt[k] = v
	end
	return opt
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

	-- Bar textures
	if path == "appearance.statusbarTexture" then
		SafeCall(addon.TextureManager and addon.TextureManager.RefreshAllTextures, addon.TextureManager)
		return
	end

	-- Text color or outline style
	if path == "appearance.textColor" or path == "appearance.textOutline" then
		SafeCall(addon.FontManager and addon.FontManager.RefreshAllFonts, addon.FontManager)
		local buffReminders = addon:GetModule("BuffReminders")
		SafeCall(buffReminders and buffReminders.Refresh, buffReminders)
		return
	end

	-- Bar gradient
	if path == "appearance.showGradient" then
		SafeCall(addon.TextureManager and addon.TextureManager.RefreshAllTextures, addon.TextureManager)
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
	if path:match("^auraTracker%.") then
		local m = addon:GetModule("AuraTracker")
		SafeCall(m and m.Refresh, m)
		if path:match("iconSize") or path:match("iconAspectRatio") then
			self:RefreshAllBarPositions()
		end
		return
	end
	if path:match("^totemBar%.") then
		-- Legacy totemBar settings are deprecated; refresh CooldownIcons which now owns totem display
		local cooldownIcons = addon:GetModule("CooldownIcons")
		if cooldownIcons and cooldownIcons.Refresh then
			cooldownIcons:Refresh()
		end
		return
	end
	if path:match("^swingBar%.") then
		local m = addon:GetModule("SwingBar")
		SafeCall(m and m.Refresh, m)
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

	-- Aspect ratio affects HUD spell icon rows and layout heights
	if path == "icons.iconAspectRatio" then
		local cooldownIcons = addon:GetModule("CooldownIcons")
		if cooldownIcons and cooldownIcons.Refresh then
			cooldownIcons:Refresh()
		end
		SafeCall(addon.Layout and addon.Layout.Refresh, addon.Layout)
		return
	end

	-- Cooldown Pulse settings
	if path:match("^cooldownPulse%.") then
		local m = addon:GetModule("CooldownPulse")
		SafeCall(m and m.Refresh, m)
		return
	end

	-- Buff Reminders settings
	if path:match("^buffReminders%.") then
		local m = addon:GetModule("BuffReminders")
		SafeCall(m and m.Refresh, m)
		return
	end

	-- Row config changes need layout recalc
	if path:match("^rows%.") then
		SafeCall(addon.Layout and addon.Layout.Refresh, addon.Layout)
		local icons = addon:GetModule("CooldownIcons")
		SafeCall(icons and icons.Refresh, icons)
		return
	end

	-- Other icon-related settings
	if path:match("^icons%.") then
		local icons = addon:GetModule("CooldownIcons")
		SafeCall(icons and icons.Refresh, icons)
		-- iconZoom also affects AuraTracker
		if path == "icons.iconZoom" then
			local auraTracker = addon:GetModule("AuraTracker")
			SafeCall(auraTracker and auraTracker.Refresh, auraTracker)
		end
		return
	end

	-- Fallback: profile-wide refresh.
	SafeCall(addon.OnProfileChanged, addon)
end

-- Recalculate positions for all vertically-stacked HUD elements
function Options:RefreshAllBarPositions()
	addon.Layout:Refresh()
end

-------------------------------------------------------------------------------
-- Options Table
-------------------------------------------------------------------------------

function Options:BuildOptionsTable()
	local rowSettingAll = {
		[C.ROW_SETTING.NONE] = "Off",
		[C.ROW_SETTING.PRIMARY] = "Primary Row",
		[C.ROW_SETTING.PRIMARY_SECONDARY] = "Primary + Secondary Rows",
		[C.ROW_SETTING.SECONDARY_UTILITY] = "Secondary + Utility Rows",
		[C.ROW_SETTING.UTILITY] = "Utility Row",
		[C.ROW_SETTING.ALL] = "All Rows",
	}

	local rowSettingDynamicSort = PickValues(rowSettingAll,
		C.ROW_SETTING.NONE,
		C.ROW_SETTING.PRIMARY,
		C.ROW_SETTING.PRIMARY_SECONDARY
	)

	local resourceDisplayModeValues = {
		[C.RESOURCE_DISPLAY_MODE.PREDICTION] = "Prediction",
		[C.RESOURCE_DISPLAY_MODE.FILL] = "Fill",
		[C.RESOURCE_DISPLAY_MODE.BAR] = "Bar",
	}

	local tickerStyleValues = {
		[C.TICKER_STYLE.SPARK] = "Spark",
		[C.TICKER_STYLE.BAR] = "Bar",
	}

	local textFormatValues = {
		[C.TEXT_FORMAT.CURRENT] = "Current",
		[C.TEXT_FORMAT.PERCENT] = "%",
		[C.TEXT_FORMAT.BOTH] = "Current (%)",
		[C.TEXT_FORMAT.CURRENT_MAX] = "Current / Max",
		[C.TEXT_FORMAT.CURRENT_MAX_PERCENT] = "Current / Max (%)",
		[C.TEXT_FORMAT.DEFICIT] = "Deficit",
		[C.TEXT_FORMAT.NONE] = "None",
	}
	local textFormatSorting = {
		C.TEXT_FORMAT.CURRENT,
		C.TEXT_FORMAT.PERCENT,
		C.TEXT_FORMAT.BOTH,
		C.TEXT_FORMAT.CURRENT_MAX,
		C.TEXT_FORMAT.CURRENT_MAX_PERCENT,
		C.TEXT_FORMAT.DEFICIT,
		C.TEXT_FORMAT.NONE,
	}

	local numberFormatValues = {
		[C.NUMBER_FORMAT.ABBREVIATED] = "Abbreviated (4.5k)",
		[C.NUMBER_FORMAT.FULL] = "Full (4523)",
		[C.NUMBER_FORMAT.COMMA] = "Comma (4,523)",
	}
	local numberFormatSorting = {
		C.NUMBER_FORMAT.ABBREVIATED,
		C.NUMBER_FORMAT.FULL,
		C.NUMBER_FORMAT.COMMA,
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
			return c.r, c.g, c.b
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
						if default == nil then return text end
						-- Color tables: show as hex code
						if type(default) == "table" and default.r then
							local hex = string.format("#%02X%02X%02X",
								math.floor(default.r * 255 + 0.5),
								math.floor(default.g * 255 + 0.5),
								math.floor(default.b * 255 + 0.5))
							return text .. "\n\n" .. Dim("Default: " .. hex)
						end
						if type(default) == "table" then return text end
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
						return text .. "\n\n" .. Dim("Default: " .. formatted)
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
	local rowDescriptions = {
		Dim("Core rotation abilities used every fight — your most important cooldowns."),
		Dim("Throughput cooldowns, maintenance buffs, and situational damage or healing abilities."),
		Dim("Crowd control, interrupts, defensives, and movement abilities."),
		Dim("Totems, trinkets, and other supplementary icons."),
	}

	local rowArgs = {}
	if addon.db and addon.db.profile and type(addon.db.profile.rows) == "table" then
		for i, row in ipairs(addon.db.profile.rows) do
			local rowKey = "row" .. i
			rowArgs[rowKey] = {
				type = "group",
				name = row.name or ("Row " .. i),
				order = i,
				args = {
					rowDesc = {
						type = "description",
						name = (rowDescriptions[i] or "") .. "\n",
						fontSize = "medium",
						order = 0,
					},
					enabled = {
						type = "toggle",
						name = "Enabled",
						desc = "Enables or disables this row. When disabled, abilities assigned to this row are hidden and the row takes no space on the HUD.",
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
							iconAspectRatio = {
								type = "select",
								name = "Aspect Ratio",
								desc = "Override the icon shape for this row. |cffffffffInherit|r uses the global setting from Appearance.",
								values = {
									[0] = "Inherit",
									[1.0] = "Square (1:1)",
									[1.165] = "Slightly Compact",
									[1.33] = "Compact (4:3)",
									[1.665] = "Very Compact",
									[2.0] = "Ultra Compact (2:1)",
								},
								sorting = {0, 1.0, 1.165, 1.33, 1.665, 2.0},
								get = function()
									local val = addon.db.profile.rows[i] and addon.db.profile.rows[i].iconAspectRatio
									if val == nil then return 0 end
									return val
								end,
								set = function(info, value)
									if value == 0 then
										addon.Database:ClearOverride(("rows.%d.iconAspectRatio"):format(i))
									else
										addon.Database:SetOverride(("rows.%d.iconAspectRatio"):format(i), value)
									end
									Options:ApplySettingChange(("rows.%d.iconAspectRatio"):format(i))
								end,
								order = 3,
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
								desc = "Wraps icons into multiple lines instead of displaying them all in a single long line. The Icons Per Row setting controls the maximum icons per line.\n\nTo avoid a sparse last row, icons are moved down from the previous row — for example, 8 icons at 6 per row becomes 5 and 3 instead of 6 and 2.",
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

	---------------------------------------------------------------------------
	-- Dynamic Layout Element Order UI
	---------------------------------------------------------------------------

	local layoutArgs = {}

	-- Helper: check if an element key is hidden for the current class
	local function isElementHidden(key)
		if key == "comboPoints" then
			return addon.playerClass ~= C.CLASS.ROGUE and addon.playerClass ~= C.CLASS.DRUID
		end
		return false
	end

	local function rebuildLayoutArgs()
		-- Clear existing args
		for k in pairs(layoutArgs) do
			layoutArgs[k] = nil
		end

		-- Intro description
		layoutArgs["introDesc"] = {
			type = "description",
			name = Dim("Reorder the vertical layout of the HUD and adjust spacing between elements.") .. "\n",
			fontSize = "medium",
			order = 0,
		}

		local db = addon.db.profile.layout
		local order = db.elementOrder
		local orderLen = #order

		-- Find first and last visible positions (for disabling Move buttons)
		local firstVisiblePos, lastVisiblePos
		for i, key in ipairs(order) do
			if not isElementHidden(key) then
				if not firstVisiblePos then firstVisiblePos = i end
				lastVisiblePos = i
			end
		end

		for i, key in ipairs(order) do
			local displayName = C.LAYOUT_ELEMENTS[key]
			if not displayName then break end

			local idx = i
			local base = i * 10

			-- Hidden function for comboPoints (class-conditional)
			local elemHiddenFn
			if key == "comboPoints" then
				elemHiddenFn = function()
					return addon.playerClass ~= C.CLASS.ROGUE and addon.playerClass ~= C.CLASS.DRUID
				end
			end

			-- Move Up button
			layoutArgs["up" .. i] = {
				type = "execute",
				name = "Up",
				order = base,
				width = 0.5,
				hidden = elemHiddenFn,
				disabled = idx == (firstVisiblePos or 1),
				func = function()
					local o = addon.db.profile.layout.elementOrder
					local g = addon.db.profile.layout.gaps
					local target = idx - 1
					while target >= 1 do
						if not isElementHidden(o[target]) then break end
						target = target - 1
					end
					if target < 1 then return end
					for p = idx, target + 1, -1 do
						local kA, kB = o[p - 1], o[p]
						g[kA], g[kB] = g[kB], g[kA]
						o[p - 1], o[p] = o[p], o[p - 1]
					end
					addon.Layout:Refresh()
					rebuildLayoutArgs()
					LibStub("AceConfigRegistry-3.0"):NotifyChange(ADDON_NAME)
				end,
			}

			-- Element name label
			layoutArgs["name" .. i] = {
				type = "description",
				name = "|cffffd100" .. displayName .. "|r",
				order = base + 1,
				width = 0.7,
				fontSize = "medium",
				hidden = elemHiddenFn,
			}

			-- Move Down button
			layoutArgs["dn" .. i] = {
				type = "execute",
				name = "Down",
				order = base + 2,
				width = 0.5,
				hidden = elemHiddenFn,
				disabled = idx == (lastVisiblePos or orderLen),
				func = function()
					local o = addon.db.profile.layout.elementOrder
					local g = addon.db.profile.layout.gaps
					local target = idx + 1
					while target <= #o do
						if not isElementHidden(o[target]) then break end
						target = target + 1
					end
					if target > #o then return end
					for p = idx, target - 1 do
						local kA, kB = o[p], o[p + 1]
						g[kA], g[kB] = g[kB], g[kA]
						o[p], o[p + 1] = o[p + 1], o[p]
					end
					addon.Layout:Refresh()
					rebuildLayoutArgs()
					LibStub("AceConfigRegistry-3.0"):NotifyChange(ADDON_NAME)
				end,
			}

			-- Gap slider between this element and the next
			if i < orderLen then
				local nextKey = order[i + 1]
				local gapKey = nextKey

				-- Hide gap if the element below it is hidden
				local gapHiddenFn
				if nextKey == "comboPoints" then
					gapHiddenFn = function()
						return addon.playerClass ~= C.CLASS.ROGUE and addon.playerClass ~= C.CLASS.DRUID
					end
				end

				local nextDisplayName = C.LAYOUT_ELEMENTS[nextKey] or nextKey
				layoutArgs["gap" .. i] = {
					type = "range",
					name = "Gap above " .. nextDisplayName,
					desc = "Pixels of space between " .. displayName .. " and " .. nextDisplayName .. ".",
					min = -20, max = 200, step = 1,
					order = base + 5,
					width = "full",
					hidden = gapHiddenFn,
					get = function() return addon.db.profile.layout.gaps[gapKey] or 0 end,
					set = function(_, val)
						addon.db.profile.layout.gaps[gapKey] = val
						addon.Layout:Refresh()
					end,
				}
			end
		end
	end

	rebuildLayoutArgs()

	---------------------------------------------------------------------------

	local optionsTable = {
		type = "group",
		name = "VeevHUD",
		get = get,
		set = set,
		args = {
			header = {
				type = "description",
				name = Dim("Version " .. (addon.version or "1.0.0")),
				order = 0,
				fontSize = "medium",
			},
			general = {
				type = "group",
				name = "General",
				order = 1,
				args = {
					introDesc = {
						type = "description",
						name = Dim("Global settings that affect the entire HUD. Individual modules have their own tabs.") .. "\n",
						fontSize = "medium",
						order = 0,
					},
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
								desc = "Moves the entire HUD left or right from the center of the screen. Negative values shift it left, positive values shift it right. The range adjusts to your screen resolution.",
								min = -screenW, max = screenW, step = 1,
								arg = "anchor.x",
								order = 3,
							},
							vOffset = {
								type = "range",
								name = "Vertical Offset",
								desc = "Moves the entire HUD up or down on your screen. Negative values move it below center, positive values move it above. The range adjusts to your screen resolution.",
								min = -screenH, max = screenH, step = 1,
								arg = "anchor.y",
								order = 4,
							},
						},
					},
					appearance = {
						type = "group",
						name = "Appearance",
						inline = true,
						order = 1.5,
						args = {
							font = {
								type = "select",
								name = "Font",
								desc = "The font used for all text in the HUD, including cooldown timers, stack counts, health/resource values, and proc durations.\n\nIf you have font-sharing addons installed (SharedMedia, etc.), their fonts will appear here automatically.",
								dialogControl = "LSM30_Font",
								values = GetLSMFontValues,
								arg = "appearance.font",
								order = 1,
							},
							statusbarTexture = {
								type = "select",
								name = "Bar Texture",
								desc = "The texture used for all status bars in the HUD, including health, resource, combo point, and energy ticker bars.\n\nIf you have texture-sharing addons installed (SharedMedia, etc.), their textures will appear here automatically.",
								dialogControl = "LSM30_Statusbar",
								values = GetLSMStatusbarValues,
								arg = "appearance.statusbarTexture",
								order = 2,
							},
							showGradient = {
								type = "toggle",
								name = "Bar Gradient",
								desc = "Adds a subtle dark-to-light gradient across all status bars (health, resource, combo points, and energy ticker), giving them more visual depth instead of a flat solid color.",
								arg = "appearance.showGradient",
								order = 3,
							},
							iconZoom = {
								type = "range",
								name = "Icon Zoom",
								desc = "Zooms into each icon's artwork, cropping the edges. Affects ability rows and Aura Tracker. Useful for removing the default border that some spell textures have. 0% shows the full icon, 16% is a subtle crop.",
								min = 0, max = 0.6, step = 0.01,
								isPercent = true,
								arg = "icons.iconZoom",
								order = 4,
							},
							textColor = {
								type = "color",
								name = "Text Color",
								desc = "The color used for cooldown countdowns, duration timers, and stack counts across all HUD elements.",
								hasAlpha = false,
								get = colorGet,
								set = colorSet,
								arg = "appearance.textColor",
								order = 5,
							},
							textOutline = {
								type = "select",
								name = "Text Outline",
								desc = "Controls how text is rendered across all HUD elements.\n\n|cffffffffOutline|r — Font outline only.\n|cffffffffShadow|r — Drop shadow only (cleaner at small sizes).\n|cffffffffBoth|r — Font outline + drop shadow (maximum readability).\n|cffffffffNone|r — No outline or shadow.\n\nIndividual elements can override this in their own settings.",
								values = textOutlineValues,
								sorting = textOutlineSorting,
								arg = "appearance.textOutline",
								order = 6,
							},
						},
					},
					sound = {
						type = "group",
						name = "Sound",
						inline = true,
						order = 4,
						args = {
							channel = {
								type = "select",
								name = "Sound Channel",
								desc = "Audio channel for all VeevHUD sound alerts.\n\n|cffffffffMaster|r — Always plays regardless of volume sliders.\n|cffffffffSound Effects|r — Respects the Sound Effects volume slider.\n|cffffffffMusic|r — Respects the Music volume slider.\n|cffffffffAmbience|r — Respects the Ambience volume slider.",
								values = { Master = "Master", SFX = "Sound Effects", Music = "Music", Ambience = "Ambience" },
								arg = "sound.channel",
								order = 1,
							},
							registerKitID = {
								type = "input",
								name = "Register Sound Kit ID",
								desc = "Enter a WoW Sound Kit ID (a number) to register it as an available sound. Once registered, it appears in all sound dropdowns.\n\nBrowse IDs at: wowhead.com/sounds\n\nExamples: 8959 (raid warning), 11466 (Illidan), 8174 (PvP flag).\n\nNote: the speaker preview button in dropdowns does not work for Kit IDs, but the sound plays correctly in-game.",
								get = function() return "" end,
								set = function(_, value)
									local kitID = tonumber(value)
									if not kitID then
										addon.Utils:Print("Invalid Sound Kit ID: " .. value)
										return
									end
									local name = addon.SoundManager:RegisterSoundKitID(kitID)
									if name then
										pcall(PlaySound, kitID, "Master")
										addon.Utils:Print("Playing Kit ID " .. kitID .. " — registered as |cff00ff00" .. name .. "|r (top of sound dropdowns).")
									else
										addon.Utils:Print("Sound Kit ID registration failed — LibSharedMedia not available.")
									end
								end,
								order = 2,
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
								desc = "Health bars, resource bars, and the resource-cost overlay on ability icons animate smoothly instead of jumping when values change.",
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
					},
			},

			icons = {
				type = "group",
				name = "Ability Rows",
				childGroups = "tab",
				order = 2,
				args = {
					appearance = {
						type = "group",
						name = "Appearance",
						order = 1,
						args = {
							introDesc = {
								type = "description",
								name = Dim("Default visual settings for all ability rows. Individual rows can override icon shape in their own tabs.") .. "\n",
								fontSize = "medium",
								order = 0.1,
							},
							masqueTip = {
								type = "description",
								name = Dim("Tip: Install the Masque addon to reskin ability icons with custom button styles."),
								order = 0.2,
								hidden = function()
									return IsAddOnLoaded and IsAddOnLoaded("Masque")
								end,
							},
							shape = {
								type = "group",
								name = "Shape",
								inline = true,
								order = 1,
								args = {
									iconAspectRatio = {
										type = "select",
										name = "Aspect Ratio",
										desc = "Default icon shape for all ability rows. Individual rows can override this in their own settings. Aura Tracker has its own setting under Bars.",
										values = {
											[1.0] = "Square (1:1)",
											[1.165] = "Slightly Compact",
											[1.33] = "Compact (4:3)",
											[1.665] = "Very Compact",
											[2.0] = "Ultra Compact (2:1)",
										},
										sorting = {1.0, 1.165, 1.33, 1.665, 2.0},
										arg = "icons.iconAspectRatio",
										set = function(info, value)
											addon.Database:SetOverride(info.arg, value)
											Options:ApplySettingChange(info.arg)
										end,
										order = 1,
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
										name = "Flow Row Spacing",
										desc = "When a row uses flow layout and icons overflow to a second line, this is the vertical gap between lines.",
										min = -10, max = 40, step = 1,
										arg = "icons.rowSpacing",
										order = 2,
									},
								},
							},
							opacity = {
								type = "group",
								name = "Opacity",
								inline = true,
								order = 3,
								args = {
									readyAlpha = {
										type = "range",
										name = "Ready Opacity",
										desc = "How visible icons are when the ability is ready to use. 100% means fully visible, lower values make ready abilities slightly transparent. Most people want this at 100%.",
										min = 0, max = 1.0, step = 0.05,
										isPercent = true,
										arg = "icons.readyAlpha",
										order = 1,
									},
									cooldownAlpha = {
										type = "range",
										name = "Cooldown Opacity",
										desc = "How visible icons are when on cooldown (for rows with Dim On Cooldown enabled). A lower value (like 30%) makes cooldown abilities fade out so you can focus on what's ready. Higher values keep them visible.",
										min = 0, max = 1.0, step = 0.05,
										isPercent = true,
										arg = "icons.cooldownAlpha",
										order = 2,
									},
									desaturateNoResources = {
										type = "toggle",
										name = "Grey Out When Not Usable",
										desc = "Makes icons grey when you don't have enough mana, rage, or energy to use the ability, or when you're in the wrong stance. Works the same way as WoW's default action bars.\n\nAutomatically disabled while resting in an inn or city to avoid constant grey-outs on combat abilities.",
										arg = "icons.desaturateNoResources",
										order = 3,
									},
								},
							},
						},
					},
					cooldowns = {
						type = "group",
						name = "Cooldowns",
						order = 2,
						args = {
							introDesc = {
								type = "description",
								name = Dim("How cooldown information is displayed on ability icons.") .. "\n",
								fontSize = "medium",
								order = 0,
							},
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
									textOutline = {
										type = "select",
										name = "Text Outline",
										desc = "Text outline style for ability icon text (cooldowns, stacks, charges, keybinds).",
										values = textOutlineValuesInherit,
										sorting = textOutlineSortingInherit,
										arg = "icons.textOutline",
										order = 1.2,
									},
									detailedTimeThreshold = {
										type = "range",
										name = "Detailed Time Threshold",
										desc = "Threshold in minutes. Cooldowns below this show precise m:ss format (e.g., 3:27). Above this, compact format is used (e.g., 3m), rounded down to the nearest minute.",
										min = 1, max = 10, step = 1,
										arg = "icons.detailedTimeThreshold",
										order = 1.5,
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
							behavior = {
								type = "group",
								name = "Behavior",
								inline = true,
								order = 2,
								args = {
									dimOnCooldown = {
										type = "select",
										name = "Dim On Cooldown",
										desc = "Controls which rows fade out (become transparent) when abilities are on cooldown. The amount they fade is controlled by the |cffffffffCooldown Opacity|r setting.\n\nRows without dimming stay at full brightness and use greying-out to indicate unavailability instead. Many players keep the Primary row undimmed so their core rotation stays visually prominent.",
										values = rowSettingAll,
										arg = "icons.dimOnCooldown",
										order = 1,
									},
									cooldownBlingRows = {
										type = "select",
										name = "Cooldown Sparkle",
										desc = "Plays WoW's native sparkle animation when a cooldown finishes. Also triggers after the GCD, matching default action bar behavior. This is purely cooldown-based — it does not check resources or other usability conditions.",
										values = rowSettingAll,
										arg = "icons.cooldownBlingRows",
										order = 2,
									},
									cooldownSpiralAlpha = {
										type = "range",
										name = "Cooldown Spiral Opacity",
										desc = "How dark the spiral overlay appears during ability cooldowns. Lower values make it more subtle and transparent.\n\nNote: Even at 100%, the spiral won't completely obscure the icon — WoW's cooldown texture has built-in transparency.",
										min = 0, max = 1.0, step = 0.05,
										isPercent = true,
										arg = "icons.cooldownSpiralAlpha",
										order = 4,
									},
								},
							},
						},
					},
					resources = {
						type = "group",
						name = "Resources",
						order = 3,
						args = {
							introDesc = {
								type = "description",
								name = Dim("How resource costs (mana, rage, energy) are shown on ability icons.") .. "\n",
								fontSize = "medium",
								order = 0,
							},
							display = {
								type = "group",
								name = "Display",
								inline = true,
								order = 1,
								args = {
									resourceDisplayMode = {
										type = "select",
										name = "Display Mode",
										desc = "How ability icons show whether you can afford to cast them:\n\n|cffffffffPrediction|r — Extends the cooldown sweep to include resource regeneration time. The icon shows how long until you can actually cast, accounting for both cooldown and resource cost. Energy and Mana predictions are tick-aware and very accurate. Rage falls back to Fill since rage income is unpredictable.\n\n|cffffffffFill|r — Darkens the icon from top to bottom proportional to missing resources. Simple and easy to read.\n\n|cffffffffBar|r — Shows a small colored bar at the bottom of each icon that fills up as you gain resources.",
										values = resourceDisplayModeValues,
										sorting = {"prediction", "fill", "bar"},
										arg = "icons.resourceDisplayMode",
										order = 1,
									},
									resourceDisplayRows = {
										type = "select",
										name = "Show On Rows",
										desc = "Choose which rows show resource cost information on their icons. When enabled, you can see at a glance whether you have enough mana, rage, or energy to cast each ability.",
										values = rowSettingAll,
										arg = "icons.resourceDisplayRows",
										order = 2,
									},
									resourceShowDuringCooldown = {
										type = "toggle",
										name = "Show During Cooldowns",
										desc = "Shows the resource cost overlay on icons while they are on cooldown, so you can see your resource state through the cooldown spiral. When disabled, the resource overlay only appears when the ability is off cooldown.",
										arg = "icons.resourceShowDuringCooldown",
										order = 3,
									},
								},
							},
							fillStyle = {
								type = "group",
								name = "Fill Style",
								inline = true,
								order = 2,
								disabled = function()
									local icons = addon.db and addon.db.profile and addon.db.profile.icons
									if not icons then return true end
									local mode = icons.resourceDisplayMode
									return mode ~= C.RESOURCE_DISPLAY_MODE.FILL and mode ~= C.RESOURCE_DISPLAY_MODE.PREDICTION
								end,
								args = {
									resourceFillUsePowerColor = {
										type = "toggle",
										name = "Use Resource Color",
										desc = "Uses your resource type color for the fill overlay — red for rage, blue for mana, yellow for energy — instead of the custom Fill Color.",
										arg = "icons.resourceFillUsePowerColor",
										order = 1,
									},
									resourceFillColor = {
										type = "color",
										name = "Fill Color",
										desc = "The color of the resource cost fill overlay on icons. Default is black (a dark overlay showing missing resources). Only used when Use Resource Color is unchecked.",
										hasAlpha = false,
										get = colorGet,
										set = colorSet,
										arg = "icons.resourceFillColor",
										order = 2,
										disabled = function()
											local icons = addon.db and addon.db.profile and addon.db.profile.icons
											if not icons then return true end
											local mode = icons.resourceDisplayMode
											local isFillMode = mode == C.RESOURCE_DISPLAY_MODE.FILL or mode == C.RESOURCE_DISPLAY_MODE.PREDICTION
											return not isFillMode or icons.resourceFillUsePowerColor
										end,
									},
									resourceFillAlpha = {
										type = "range",
										name = "Fill Opacity",
										desc = "How opaque the resource cost overlay appears on icons. Higher values make it more obvious when you can't afford an ability. Applies to Fill mode and Prediction mode's fill fallback (used for rage and when predictions are unavailable).",
										min = 0.05, max = 1.0, step = 0.05,
										isPercent = true,
										arg = "icons.resourceFillAlpha",
										order = 3,
									},
									resourceFillInvert = {
										type = "toggle",
										name = "Invert Fill",
										desc = "Inverts the fill direction. Normal: overlay covers from top down showing missing resources. Inverted: overlay fills from bottom up showing current resources.",
										arg = "icons.resourceFillInvert",
										order = 4,
									},
								},
							},
							barStyle = {
								type = "group",
								name = "Bar Style",
								inline = true,
								order = 3,
								disabled = function()
									return addon.db and addon.db.profile and addon.db.profile.icons and addon.db.profile.icons.resourceDisplayMode ~= C.RESOURCE_DISPLAY_MODE.BAR
								end,
								args = {
									resourceBarUsePowerColor = {
										type = "toggle",
										name = "Use Resource Color",
										desc = "Uses your resource type color for the bar — red for rage, blue for mana, yellow for energy — instead of the custom Bar Color.",
										arg = "icons.resourceBarUsePowerColor",
										order = 1,
									},
									resourceBarColor = {
										type = "color",
										name = "Bar Color",
										desc = "The color of the resource bar at the bottom of icons. Only used when Use Resource Color is unchecked.",
										hasAlpha = false,
										get = colorGet,
										set = colorSet,
										arg = "icons.resourceBarColor",
										order = 2,
										disabled = function()
											local icons = addon.db and addon.db.profile and addon.db.profile.icons
											if not icons then return true end
											return icons.resourceDisplayMode ~= C.RESOURCE_DISPLAY_MODE.BAR or icons.resourceBarUsePowerColor
										end,
									},
									resourceBarHeight = {
										type = "range",
										name = "Bar Height",
										desc = "Height of the small resource bar shown at the bottom of each icon. Only visible when Display Mode is set to |cffffffffBar|r.",
										min = 1, max = 16, step = 1,
										arg = "icons.resourceBarHeight",
										order = 3,
									},
								},
							},
						},
					},
					effects = {
						type = "group",
						name = "Effects",
						order = 4,
						args = {
							introDesc = {
								type = "description",
								name = Dim("Visual effects on ability icons for active buffs, debuffs, and procs.") .. "\n",
								fontSize = "medium",
								order = 0,
							},
							auraTracking = {
								type = "group",
								name = "Aura Tracking",
								inline = true,
								order = 1,
								args = {
									showAuraTracking = {
										type = "toggle",
										name = "Enabled",
										desc = "Abilities that apply buffs or debuffs (like Intimidating Shout, Rend, Renew) show the active duration with a glow while the effect is on a target. After it expires, the cooldown is shown. Disable if you only want to see cooldowns.",
										arg = "icons.showAuraTracking",
										order = 1,
									},
									auraTargettargetSupport = {
										type = "toggle",
										name = "Target-of-Target Support",
										desc = "Also check for your buffs and debuffs on your target's target. Useful for healers tracking HoTs on the tank's target.\n\nExamples:\n- Target the boss, see your heals on the tank (the boss's target)\n- Target the tank, see your DoTs on the boss (the tank's target)",
										arg = "icons.auraTargettargetSupport",
										order = 2,
										disabled = function()
											return addon.db and addon.db.profile and not addon.db.profile.icons.showAuraTracking
										end,
									},
									auraSpiralAlpha = {
										type = "range",
										name = "Aura Spiral Opacity",
										desc = "How dark the spiral overlay appears when tracking active buff or aura durations on icons. Lower values make it more subtle and transparent.\n\nNote: Even at 100%, the spiral won't completely obscure the icon — WoW's cooldown texture has built-in transparency.",
										min = 0, max = 1.0, step = 0.05,
										isPercent = true,
										arg = "icons.auraSpiralAlpha",
										order = 3,
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
										name = "Show On Rows",
										desc = "Plays a brief 'pop' animation (the icon scales up slightly then back down) whenever you successfully cast an ability. Gives satisfying visual feedback that your spell went off. Select which rows show this animation.",
										values = rowSettingAll,
										arg = "icons.castFeedbackRows",
										order = 1,
									},
									castFeedbackScale = {
										type = "range",
										name = "Pop Scale",
										desc = "How much the icon briefly grows when you cast a spell. Higher values = bigger pop.",
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
										name = "Show On Rows",
										desc = "Shows a glowing border around ability icons when they come off cooldown and are ready to use. Only triggers while in combat. Select which rows display this effect.",
										values = rowSettingAll,
										arg = "icons.readyGlowRows",
										order = 1,
									},
									readyGlowAlwaysRows = {
										type = "select",
										name = "Re-trigger Glow",
										desc = "Which rows re-trigger the glow whenever an ability becomes usable again (not just the first time).\n\nOn these rows, the glow plays again every time usability changes (e.g., gaining enough resources, target entering Execute range). Rows not selected here play the glow only once per cooldown cycle.\n\nNote: Reactive abilities (like Execute or Overpower) always re-trigger regardless of this setting.",
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
										desc = "How long each ready glow animation lasts (in seconds). After this time, the glow fades out. On rows with Re-trigger Glow, the glow will re-trigger at this interval each time usability changes.",
										min = 0.1, max = 5.0, step = 0.05,
										arg = "icons.readyGlowDuration",
										order = 3,
										disabled = function()
											return addon.db and addon.db.profile and addon.db.profile.icons and addon.db.profile.icons.readyGlowRows == C.ROW_SETTING.NONE
										end,
									},
									readyGlowThreshold = {
										type = "range",
										name = "Pre-trigger Time",
										desc = "Begin the glow this many seconds before the cooldown completes, so you can prepare your next action. At 0, the glow only appears once the cooldown is fully complete.",
										min = 0, max = 2.0, step = 0.05,
										arg = "icons.readyGlowThreshold",
										order = 4,
										disabled = function()
											return addon.db and addon.db.profile and addon.db.profile.icons and addon.db.profile.icons.readyGlowRows == C.ROW_SETTING.NONE
										end,
									},
								},
							},
							queuedHighlight = {
								type = "group",
								name = "Queued Highlight",
								inline = true,
								order = 4,
								args = {
									showQueuedHighlight = {
										type = "toggle",
										name = "Enabled",
										desc = "Brightens the icon of your next queued ability. Most noticeable on \"next melee\" attacks like Heroic Strike or Maul that stay queued until your next swing, but you may also see a brief flash on any ability queued during a cast or GCD.",
										arg = "icons.showQueuedHighlight",
										order = 1,
									},
								},
							},
						},
					},
					other = {
						type = "group",
						name = "Indicators",
						order = 5,
						args = {
							introDesc = {
								type = "description",
								name = Dim("Range checking, sorting, and keybind display on ability icons.") .. "\n",
								fontSize = "medium",
								order = 0,
							},
							rangeIndicator = {
								type = "group",
								name = "Range Indicator",
								inline = true,
								order = 1,
								args = {
									showRangeIndicator = {
										type = "select",
										name = "Range Indicator",
										desc = "Shows a red overlay on spell icons when your current target is out of range. Shows when an ability is usable but out of range — even during cooldown, giving you a heads-up on positioning. When resources are insufficient, the grey/resource indicators take priority instead.\n\nNote: Only shows when you have a target. Spells without a range component (self-buffs, etc.) are not affected.",
										values = rowSettingAll,
										arg = "icons.showRangeIndicator",
										order = 1,
									},
								},
							},
							dynamicSorting = {
								type = "group",
								name = "Dynamic Sorting",
								inline = true,
								order = 2,
								args = {
									dynamicSortRows = {
										type = "select",
										name = "Dynamic Sorting",
										desc = "Automatically reorders icons left-to-right by remaining cooldown, so abilities that are almost ready appear first.\n\nUseful for DOT classes (see which debuff is closest to expiring) and cooldown-heavy classes (see which ability is ready next).\n\nTie-breaker: When multiple abilities are ready, they sort by their original row position — so your row order acts as a priority list and the leftmost icon is always the next best spell to cast.",
										values = rowSettingDynamicSort,
										arg = "icons.dynamicSortRows",
										order = 1,
									},
									dynamicSortAnimation = {
										type = "toggle",
										name = "Smooth Sorting",
										desc = "Icons slide smoothly into their new position when the sort order changes. Disable for instant repositioning.",
										arg = "icons.dynamicSortAnimation",
										order = 2,
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
								order = 3,
								args = {
									showKeybindText = {
										type = "select",
										name = "Show On Rows",
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
							reagentCount = {
								type = "group",
								name = "Reagent Count",
								inline = true,
								order = 3,
								args = {
									showReagentCount = {
										type = "toggle",
										name = "Enabled",
										desc = "Shows the number of reagents you have in the top-right corner of spell icons that consume reagents on cast. Examples: Soul Shards on warlock abilities, seeds on Rebirth, Flash Powder on Vanish, Ankhs on Reincarnation.",
										arg = "icons.showReagentCount",
										order = 1,
									},
									reagentCountAllRanks = {
										type = "toggle",
										name = "Count All Ranks",
										desc = "When enabled, counts reagents for all spell ranks combined (e.g., all seed types for Rebirth). When disabled, only counts the reagent for your highest learned rank.",
										arg = "icons.reagentCountAllRanks",
										order = 2,
										disabled = function() return not addon.db.profile.icons.showReagentCount end,
									},
								},
							},
						},
					},
				},
			},

			bars = {
				type = "group",
				name = "Status Bars",
				childGroups = "tab",
				order = 4,
				args = {
					resource = {
						type = "group",
						name = "Resource Bar",
						order = 3,
						args = {
							introDesc = {
								type = "description",
								name = Dim("Your character's resource bar (mana, rage, or energy).") .. "\n",
								fontSize = "medium",
								order = 0,
							},
							enabled = { type = "toggle", name = "Enabled", desc = "Shows a bar displaying your current mana, rage, or energy (depending on your class). Appears between the health bar and the ability icon rows.", arg = "resourceBar.enabled", order = 1 },
							sizeSettings = {
								type = "group",
								name = "Size",
								inline = true,
								order = 2,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.enabled end,
								args = {
									width = { type = "range", name = "Width", desc = "How wide the resource bar is in pixels.", min = 50, max = 600, step = 1, arg = "resourceBar.width", order = 1 },
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
									textFormat = { type = "select", name = "Text Format", desc = "Controls what text is shown on the resource bar.\n\n|cffffffffCurrent|r — Shows your actual resource (e.g., 4523).\n|cffffffffPercent|r — Shows your resource percentage (e.g., 85%).\n|cffffffffBoth|r — Shows both (e.g., 4523 (85%)).\n|cffffffffCurrent / Max|r — Shows current and maximum (e.g., 4523 / 5320).\n|cffffffffCurrent / Max (%)|r — Shows current, maximum, and percentage (e.g., 4523 / 5320 (85%)).\n|cffffffffDeficit|r — Shows how much is missing (e.g., -797). Hidden at full.\n|cffffffffNone|r — Hides the text entirely.", values = textFormatValues, sorting = textFormatSorting, arg = "resourceBar.textFormat", order = 1 },
									numberFormat = { type = "select", name = "Number Format", desc = "Controls how numbers are displayed.\n\n|cffffffffAbbreviated|r — Large numbers shortened (e.g., 4.5k, 1.2m).\n|cffffffffFull|r — Whole numbers (e.g., 4523).\n|cffffffffComma|r — Comma-separated (e.g., 4,523).", values = numberFormatValues, sorting = numberFormatSorting, arg = "resourceBar.numberFormat", order = 2, disabled = function() local fmt = addon.db.profile.resourceBar.textFormat; return fmt == C.TEXT_FORMAT.NONE or fmt == C.TEXT_FORMAT.PERCENT end },
									textSize = { type = "range", name = "Text Size", desc = "Font size for the resource text. Larger sizes are easier to read but may overflow small bars.", min = 6, max = 24, step = 1, arg = "resourceBar.textSize", order = 3, disabled = function() return addon.db.profile.resourceBar.textFormat == C.TEXT_FORMAT.NONE end },
									textOutline = { type = "select", name = "Text Outline", desc = "Text outline style for the resource bar.", values = textOutlineValuesInherit, sorting = textOutlineSortingInherit, arg = "resourceBar.textOutline", order = 4, disabled = function() return addon.db.profile.resourceBar.textFormat == C.TEXT_FORMAT.NONE end },
								},
							},
							colorSettings = {
								type = "group",
								name = "Color",
								inline = true,
								order = 4,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.enabled end,
								args = {
									powerColor = { type = "toggle", name = "Use Resource Color", desc = "Colors the bar based on your resource type — blue for mana, red for rage, yellow for energy. Uncheck to use a custom color instead.", arg = "resourceBar.powerColor", order = 1 },
									color = { type = "color", name = "Bar Color", desc = "The custom color for the resource bar. Only used when Use Resource Color is unchecked.", hasAlpha = false, get = colorGet, set = colorSet, arg = "resourceBar.color", order = 2, disabled = function() local db = addon.db and addon.db.profile and addon.db.profile.resourceBar; return db and db.powerColor end },
								},
							},
							innervateHighlight = {
								type = "group",
								name = "Innervate Highlight",
								inline = true,
								order = 5,
								hidden = function() return addon.playerClass == C.CLASS.ROGUE or addon.playerClass == C.CLASS.WARRIOR end,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.enabled end,
								args = {
									enabled = { type = "toggle", name = "Enabled", desc = "Changes the mana bar color when the Innervate buff is active, giving you immediate visual feedback that your mana regeneration is boosted.", arg = "resourceBar.innervateHighlight.enabled", order = 1 },
									color = { type = "color", name = "Color", desc = "The color the resource bar changes to during Innervate.", hasAlpha = false, get = colorGet, set = colorSet, arg = "resourceBar.innervateHighlight.color", order = 2, disabled = function() return not addon.db.profile.resourceBar.innervateHighlight.enabled end },
								},
							},
							sparkSettings = {
								type = "group",
								name = "Spark",
								inline = true,
								order = 6,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.enabled end,
								args = {
									showSpark = { type = "toggle", name = "Enabled", desc = "Shows a bright highlight at the bar's current fill point — the glowing line where the filled and empty portions meet. Adds visual polish.", arg = "resourceBar.showSpark", order = 1 },
									sparkWidth = { type = "range", name = "Width", desc = "How wide the spark highlight is in pixels. Larger values create a broader, more prominent glow.", min = 1, max = 32, step = 1, arg = "resourceBar.sparkWidth", order = 2 },
									sparkOverflow = { type = "range", name = "Overflow", desc = "How far the spark glow extends beyond the top and bottom edges of the bar (in pixels). Higher values create a taller spark that 'overflows' past the bar.", min = 0, max = 32, step = 1, arg = "resourceBar.sparkOverflow", order = 3 },
									sparkHideFullEmpty = { type = "toggle", name = "Hide at Full/Empty", desc = "Hides the spark when the bar is completely full or completely empty, since there's no meaningful fill point to highlight in those states.", arg = "resourceBar.sparkHideFullEmpty", order = 4 },
								},
							},
							overlaySettings = {
								type = "group",
								name = "Overlays",
								inline = true,
								order = 7,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.enabled end,
								args = {
									showPredictedCost = { type = "toggle", name = "Predicted Cost", desc = "Shows a darkened section on the resource bar representing the cost of abilities you are currently casting or have queued (e.g., Heroic Strike, Cleave). Gives you a preview of where your resource will be after the ability completes.", arg = "resourceBar.showPredictedCost", order = 1 },
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
							style = { type = "select", name = "Style", desc = "|cffffffffTicker Bar|r — Shows a separate thin bar below the resource bar that fills as the next tick approaches.\n\n|cffffffffSpark|r — Shows a moving spark overlay on the resource bar itself, which is more subtle.", values = tickerStyleValues, arg = "resourceBar.energyTicker.style", order = 2, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.energyTicker.enabled end },
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
								desc = "|cffffffffOutside 5 Second Rule|r — Only shows the tick timer when you haven't cast a spell in the last 5 seconds (when you're getting full spirit-based mana regeneration).\n\n|cffffffffNext Full Tick|r (Recommended) — Always active. After you cast a spell, it predicts exactly when your first full-rate mana tick will arrive and counts down to it. Cast right after the tick completes to get the most mana before your next spell.",
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
				druidManaBar = {
					type = "group",
					name = "Mana Bar (Druid)",
					order = 6,
					hidden = function() return addon.playerClass ~= C.CLASS.DRUID end,
					args = {
						desc = {
							type = "description",
							name = Dim("Shows a secondary mana bar below the resource bar while in Cat Form or Bear Form, so you can monitor mana for shifting and casting."),
							order = 0,
						},
						enabled = { type = "toggle", name = "Enabled", desc = "Show a secondary mana bar below the resource bar while shapeshifted.", arg = "resourceBar.druidManaBar.enabled", order = 1, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.enabled end },
						height = { type = "range", name = "Height", desc = "How tall the secondary mana bar is in pixels.", min = 2, max = 30, step = 1, arg = "resourceBar.druidManaBar.height", order = 2, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.druidManaBar.enabled end },
						showSpark = { type = "toggle", name = "Show Spark", desc = "Shows a glowing spark at the current fill position on the mana bar.", arg = "resourceBar.druidManaBar.showSpark", order = 3, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.druidManaBar.enabled end },
						color = { type = "color", name = "Color", desc = "The color used for the secondary mana bar.", hasAlpha = false, get = colorGet, set = colorSet, arg = "resourceBar.druidManaBar.color", order = 4, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.druidManaBar.enabled end },
						showManaTicker = { type = "toggle", name = "Show Mana Ticker", desc = "Shows the mana tick spark on this bar while in form. When disabled, the mana ticker only appears on the main resource bar in caster form.", arg = "resourceBar.druidManaBar.showManaTicker", order = 5, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.druidManaBar.enabled end },
						showFormCostMarker = { type = "toggle", name = "Form Cost Marker", desc = "Shows a vertical line on the mana bar when your mana is too low to re-enter your current shapeshift form. The line indicates the mana threshold needed, so you can see how close you are to being able to shift back.", arg = "resourceBar.druidManaBar.showFormCostMarker", order = 6, disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.druidManaBar.enabled end },
						textSettings = {
							type = "group",
							name = "Text",
							inline = true,
							order = 7,
							disabled = function() return addon.db and addon.db.profile and not addon.db.profile.resourceBar.druidManaBar.enabled end,
							args = {
								textFormat = { type = "select", name = "Text Format", desc = "Controls what text is shown on the Druid mana bar.\n\n|cffffffffCurrent|r — Shows your actual mana.\n|cffffffffPercent|r — Shows your mana percentage.\n|cffffffffBoth|r — Shows both.\n|cffffffffCurrent / Max|r — Shows current and maximum.\n|cffffffffCurrent / Max (%)|r — Shows current, maximum, and percentage.\n|cffffffffDeficit|r — Shows how much is missing. Hidden at full.\n|cffffffffNone|r — Hides the text.", values = textFormatValues, sorting = textFormatSorting, arg = "resourceBar.druidManaBar.textFormat", order = 1 },
								numberFormat = { type = "select", name = "Number Format", desc = "Controls how numbers are displayed.", values = numberFormatValues, sorting = numberFormatSorting, arg = "resourceBar.druidManaBar.numberFormat", order = 2, disabled = function() local fmt = addon.db.profile.resourceBar.druidManaBar.textFormat; return fmt == C.TEXT_FORMAT.NONE or fmt == C.TEXT_FORMAT.PERCENT end },
								textSize = { type = "range", name = "Text Size", desc = "Font size for the mana bar text.", min = 6, max = 18, step = 1, arg = "resourceBar.druidManaBar.textSize", order = 3 },
								textOutline = { type = "select", name = "Text Outline", desc = "Text outline style for the druid mana bar.", values = textOutlineValuesInherit, sorting = textOutlineSortingInherit, arg = "resourceBar.druidManaBar.textOutline", order = 4 },
							},
						},
					},
				},
					health = {
						type = "group",
						name = "Health Bar",
						order = 2,
						args = {
							introDesc = {
								type = "description",
								name = Dim("Your character's health bar with heal prediction.") .. "\n",
								fontSize = "medium",
								order = 0,
							},
							enabled = { type = "toggle", name = "Enabled", desc = "Shows a bar displaying your current health above the resource bar. Gives you a quick glance at your survivability without looking at your unit frame.", arg = "healthBar.enabled", order = 1 },
							sizeSettings = {
								type = "group",
								name = "Size",
								inline = true,
								order = 2,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.healthBar.enabled end,
								args = {
									width = { type = "range", name = "Width", desc = "How wide the health bar is in pixels.", min = 50, max = 600, step = 1, arg = "healthBar.width", order = 1 },
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
									textFormat = { type = "select", name = "Text Format", desc = "Controls what text is shown on the health bar.\n\n|cffffffffCurrent|r — Shows your actual health (e.g., 3256).\n|cffffffffPercent|r — Shows your health percentage (e.g., 71%).\n|cffffffffBoth|r — Shows both (e.g., 3256 (71%)).\n|cffffffffCurrent / Max|r — Shows current and maximum (e.g., 3256 / 4580).\n|cffffffffCurrent / Max (%)|r — Shows current, maximum, and percentage (e.g., 3256 / 4580 (71%)).\n|cffffffffDeficit|r — Shows how much health is missing (e.g., -1324). Hidden at full.\n|cffffffffNone|r — Hides the text entirely.", values = textFormatValues, sorting = textFormatSorting, arg = "healthBar.textFormat", order = 1 },
									numberFormat = { type = "select", name = "Number Format", desc = "Controls how numbers are displayed.\n\n|cffffffffAbbreviated|r — Large numbers shortened (e.g., 4.5k, 1.2m).\n|cffffffffFull|r — Whole numbers (e.g., 4523).\n|cffffffffComma|r — Comma-separated (e.g., 4,523).", values = numberFormatValues, sorting = numberFormatSorting, arg = "healthBar.numberFormat", order = 2, disabled = function() local fmt = addon.db.profile.healthBar.textFormat; return fmt == C.TEXT_FORMAT.NONE or fmt == C.TEXT_FORMAT.PERCENT end },
									textSize = { type = "range", name = "Text Size", desc = "Font size for the health text. Larger sizes are easier to read but may overflow small bars.", min = 6, max = 24, step = 1, arg = "healthBar.textSize", order = 3, disabled = function() return addon.db.profile.healthBar.textFormat == C.TEXT_FORMAT.NONE end },
									textOutline = { type = "select", name = "Text Outline", desc = "Text outline style for the health bar.", values = textOutlineValuesInherit, sorting = textOutlineSortingInherit, arg = "healthBar.textOutline", order = 4, disabled = function() return addon.db.profile.healthBar.textFormat == C.TEXT_FORMAT.NONE end },
								},
							},
							colorSettings = {
								type = "group",
								name = "Color",
								inline = true,
								order = 4,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.healthBar.enabled end,
								args = {
									classColored = { type = "toggle", name = "Use Class Color", desc = "Colors the health bar using your class color (e.g., brown for Warriors, purple for Warlocks) instead of the standard green.", arg = "healthBar.classColored", order = 1 },
									color = { type = "color", name = "Bar Color", desc = "The custom color for the health bar. Only used when Use Class Color is unchecked.", hasAlpha = false, get = colorGet, set = colorSet, arg = "healthBar.color", order = 2, disabled = function() local db = addon.db and addon.db.profile and addon.db.profile.healthBar; return db and db.classColored end },
								},
							},
							overlaySettings = {
								type = "group",
								name = "Overlays",
								inline = true,
								order = 5,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.healthBar.enabled end,
								args = {
									showHealPrediction = { type = "toggle", name = "Heal Prediction", desc = "Shows a lighter overlay on the health bar representing incoming heals. The overlay extends from your current health into the missing health area, giving you a preview of where your health will be after heals land.", arg = "healthBar.showHealPrediction", order = 1 },
								},
							},
						},
					},
					petHealth = {
						type = "group",
						name = "Pet Health Bar",
						order = 2.5,
						args = {
							introDesc = {
								type = "description",
								name = Dim("Your pet's health bar. Automatically hides when no pet is active.") .. "\n",
								fontSize = "medium",
								order = 0,
							},
							enabled = { type = "toggle", name = "Enabled", desc = "Shows a bar displaying your pet's current health. Automatically hides when you have no active pet.", arg = "petHealthBar.enabled", order = 1 },
							sizeSettings = {
								type = "group",
								name = "Size",
								inline = true,
								order = 2,
								disabled = function() return not addon.db.profile.petHealthBar.enabled end,
								args = {
									width = { type = "range", name = "Width", desc = "How wide the pet health bar is in pixels.", min = 50, max = 600, step = 1, arg = "petHealthBar.width", order = 1 },
									height = { type = "range", name = "Height", desc = "How tall/thick the pet health bar is in pixels.", min = 2, max = 60, step = 1, arg = "petHealthBar.height", order = 2 },
								},
							},
							textSettings = {
								type = "group",
								name = "Text",
								inline = true,
								order = 3,
								disabled = function() return not addon.db.profile.petHealthBar.enabled end,
								args = {
									textFormat = { type = "select", name = "Text Format", desc = "Controls what text is shown on the pet health bar.\n\n|cffffffffCurrent|r — Shows actual health.\n|cffffffffPercent|r — Shows health percentage.\n|cffffffffBoth|r — Shows both.\n|cffffffffCurrent / Max|r — Shows current and maximum.\n|cffffffffCurrent / Max (%)|r — Shows current, maximum, and percentage.\n|cffffffffDeficit|r — Shows how much health is missing. Hidden at full.\n|cffffffffNone|r — Hides the text.", values = textFormatValues, sorting = textFormatSorting, arg = "petHealthBar.textFormat", order = 1 },
									numberFormat = { type = "select", name = "Number Format", desc = "Controls how numbers are displayed.", values = numberFormatValues, sorting = numberFormatSorting, arg = "petHealthBar.numberFormat", order = 2, disabled = function() local fmt = addon.db.profile.petHealthBar.textFormat; return fmt == C.TEXT_FORMAT.NONE or fmt == C.TEXT_FORMAT.PERCENT end },
									textSize = { type = "range", name = "Text Size", desc = "Font size for the pet health text.", min = 6, max = 24, step = 1, arg = "petHealthBar.textSize", order = 3, disabled = function() return addon.db.profile.petHealthBar.textFormat == C.TEXT_FORMAT.NONE end },
									textOutline = { type = "select", name = "Text Outline", desc = "Text outline style for the pet health bar.", values = textOutlineValuesInherit, sorting = textOutlineSortingInherit, arg = "petHealthBar.textOutline", order = 4, disabled = function() return addon.db.profile.petHealthBar.textFormat == C.TEXT_FORMAT.NONE end },
								},
							},
							colorSettings = {
								type = "group",
								name = "Color",
								inline = true,
								order = 4,
								disabled = function() return not addon.db.profile.petHealthBar.enabled end,
								args = {
									color = { type = "color", name = "Bar Color", desc = "The color for the pet health bar.", hasAlpha = false, get = colorGet, set = colorSet, arg = "petHealthBar.color", order = 1 },
								},
							},
							overlaySettings = {
								type = "group",
								name = "Overlays",
								inline = true,
								order = 5,
								disabled = function() return not addon.db.profile.petHealthBar.enabled end,
								args = {
									showHealPrediction = { type = "toggle", name = "Heal Prediction", desc = "Shows a lighter overlay on the pet health bar representing incoming heals.", arg = "petHealthBar.showHealPrediction", order = 1 },
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
							introDesc = {
								type = "description",
								name = Dim("Horizontal combo point display below the resource bar.") .. "\n",
								fontSize = "medium",
								order = 0,
							},
							enabled = { type = "toggle", name = "Enabled", desc = "Shows combo point bars below the resource bar. For Druids, this only appears while in Cat Form.", arg = "comboPoints.enabled", order = 1 },
							sizeLayout = {
								type = "group",
								name = "Size & Layout",
								inline = true,
								order = 2,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.comboPoints.enabled end,
								args = {
									width = { type = "range", name = "Width", desc = "The total width of the combo points display in pixels.", min = 50, max = 600, step = 1, arg = "comboPoints.width", order = 1 },
									barHeight = { type = "range", name = "Bar Height", desc = "The height of each combo point bar in pixels. Smaller values create a more subtle display.", min = 2, max = 30, step = 1, arg = "comboPoints.barHeight", order = 2 },
									barSpacing = { type = "range", name = "Bar Spacing", desc = "The gap in pixels between each individual combo point segment.", min = 0, max = 20, step = 1, arg = "comboPoints.barSpacing", order = 3 },
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
								},
							},
						},
					},
					procs = {
						type = "group",
						name = "Aura Tracker",
						order = 1,
						args = {
							description = {
								type = "description",
								name = Dim("The Aura Tracker shows small icons for important temporary buffs — class procs (Enrage, Flurry, Clearcasting), external buffs (Bloodlust, Power Infusion, Innervate), and any custom auras you add.\n\nUse the tabs above to configure which auras to show.") .. "\n",
								fontSize = "medium",
								order = 0,
							},
							enabled = { type = "toggle", name = "Enable Aura Tracker", desc = "Master toggle for the Aura Tracker feature. When disabled, no aura icons will be shown.", arg = "auraTracker.enabled", order = 1, width = "full" },
							layout = {
								type = "group",
								name = "Layout",
								inline = true,
								order = 2,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.auraTracker.enabled end,
								args = {
									iconSize = { type = "range", name = "Icon Size", desc = "How big the aura icons are in pixels. These are typically smaller than ability icons since they're just indicators. 20-28 pixels works well for most people.", min = 12, max = 140, step = 1, arg = "auraTracker.iconSize", order = 1 },
									iconSpacing = { type = "range", name = "Icon Spacing", desc = "The gap in pixels between each aura icon when multiple auras are active at once.", min = 0, max = 40, step = 1, arg = "auraTracker.iconSpacing", order = 2 },
									iconAspectRatio = {
										type = "select",
										name = "Aspect Ratio",
										desc = "Makes aura icons shorter by shrinking height while keeping width the same. Useful if you want compact spell rows but prefer aura icons to stay more square and readable.",
										values = {
											[1.0] = "Square (1:1)",
											[1.165] = "Slightly Compact",
											[1.33] = "Compact (4:3)",
											[1.665] = "Very Compact",
											[2.0] = "Ultra Compact (2:1)",
										},
										sorting = {1.0, 1.165, 1.33, 1.665, 2.0},
										arg = "auraTracker.iconAspectRatio",
										set = function(info, value)
											addon.Database:SetOverride(info.arg, value)
											Options:ApplySettingChange(info.arg)
										end,
										order = 3,
									},
								},
							},
							glow = {
								type = "group",
								name = "Glow",
								inline = true,
								order = 3,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.auraTracker.enabled end,
								args = {
									activeGlow = { type = "toggle", name = "Edge Glow", desc = "Shows a glowing animated border around active aura icons, making them stand out and drawing your eye to important buffs.", width = "full", arg = "auraTracker.activeGlow", order = 1 },
									backdropGlowIntensity = { type = "range", name = "Backdrop Intensity", desc = "Controls the brightness of the soft colored halo that appears behind each aura icon. Higher values make the glow more prominent. Set to 0 to turn it off completely.", min = 0, max = 0.8, step = 0.05, width = "normal", arg = "auraTracker.backdropGlowIntensity", order = 2 },
									backdropGlowSize = { type = "range", name = "Backdrop Size", desc = "How far the backdrop glow extends outward from each aura icon. Larger values create a wider, softer halo.", min = 0.5, max = 6.0, step = 0.1, width = "normal", arg = "auraTracker.backdropGlowSize", order = 3 },
								},
							},
							animation = {
								type = "group",
								name = "Animation",
								inline = true,
								order = 4,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.auraTracker.enabled end,
								args = {
									showDuration = { type = "toggle", name = "Show Duration", desc = "Displays the remaining time on aura buffs as text on the icon. Disable if you prefer a cleaner look or if it overlaps with stack counts.", width = "normal", arg = "auraTracker.showDuration", order = 1 },
									textOutline = { type = "select", name = "Text Outline", desc = "Text outline style for aura tracker text.", values = textOutlineValuesInherit, sorting = textOutlineSortingInherit, arg = "auraTracker.textOutline", order = 1.5 },
									slideAnimation = { type = "toggle", name = "Slide Animation", desc = "When auras appear or disappear, the remaining icons smoothly slide to re-center instead of snapping instantly. Disable for instant repositioning.", width = "normal", arg = "auraTracker.slideAnimation", order = 2 },
									punchScale = { type = "range", name = "Activation Pop", desc = "How much the icon briefly grows when an aura activates or refreshes. Set to 100% to disable the pop animation.", min = 1.0, max = 2.0, step = 0.05, isPercent = true, arg = "auraTracker.punchScale", order = 3 },
									sortOrder = { type = "select", name = "Sort Order", desc = "How active aura icons are arranged.\n\n|cffffffffActivation Order|r — First-activated aura appears on the left, newest on the right.\n\n|cffffffffFixed|r — Icons stay in a consistent order based on spell registration (class procs first, then externals, then custom).\n\n|cffffffffLeast Remaining|r — Aura closest to expiring appears on the left. Icons re-sort as durations tick down.", values = { [C.AURA_SORT_ORDER.FIFO] = "Activation Order", [C.AURA_SORT_ORDER.FIXED] = "Fixed", [C.AURA_SORT_ORDER.REMAINING] = "Least Remaining" }, sorting = { C.AURA_SORT_ORDER.FIFO, C.AURA_SORT_ORDER.FIXED, C.AURA_SORT_ORDER.REMAINING }, arg = "auraTracker.sortOrder", order = 4 },
								},
							},
							soundGroup = {
								type = "group",
								name = "Sound",
								inline = true,
								order = 5,
								disabled = function() return addon.db and addon.db.profile and not addon.db.profile.auraTracker.enabled end,
								args = {
									soundOnProc = SoundDropdown({
										name = "Default Sound",
										desc = "Sound to play when any aura activates. Individual auras can override this in the aura list tabs.",
										arg = "auraTracker.soundOnProc",
										order = 1,
									}),
									soundOnRefresh = {
										type = "toggle",
										name = "Play on Refresh",
										desc = "Also play the sound when an aura refreshes (is reapplied while already active). Useful for procs like Mace Stun where each trigger matters. Individual auras can override this in the aura list tabs.",
										arg = "auraTracker.soundOnRefresh",
										order = 2,
									},
								},
							},
						},
					},
					swingbar = {
						type = "group",
						name = "Swing Bar",
						order = 3,
						args = {
							classInfo = {
								type = "description",
								name = function()
									local class = addon.playerClass
									local spec = addon.playerSpec
									if class == C.CLASS.HUNTER then
										return Dim("Your character automatically fires auto-shots on a timer. If you cast an ability too late in the timer, it 'clips' (delays) your next auto-shot, costing you DPS. The bar turns green when it's safe to cast and red when casting would clip. Once you learn Steady Shot, a yellow zone appears for the window where Steady Shot would clip but instants and movement are still safe.") .. "\n"
									elseif class == C.CLASS.PALADIN then
										if spec == "RETRIBUTION" then
											return Dim("Seal twisting lets you get two seal procs on a single melee swing by swapping seals right before the hit lands. The bar turns green during the twist window — the last ~0.4 seconds before impact — telling you when to swap to your second seal.") .. "\n"
										else
											return Dim("Tracks your melee swing timer — a bar that fills up as your next auto-attack approaches. Auto-hides between pulls.") .. "\n"
										end
									elseif class == C.CLASS.SHAMAN then
										if spec == "ENHANCEMENT" then
											return Dim("Two bars track your main-hand and off-hand swing timers. When both weapons swing at the same time (synced), your Flurry haste charges aren't wasted on isolated off-hand hits, and Windfury extra attacks land alongside your normal swings. Bars turn green when synced and red when desynced — meaning one weapon has drifted ahead of the other.") .. "\n"
										else
											return Dim("Tracks your melee swing timer — a bar that fills up as your next auto-attack approaches. Auto-hides between pulls.") .. "\n"
										end
									elseif class == C.CLASS.WARRIOR then
										if spec == "FURY" then
											return Dim("Two bars track your main-hand and off-hand swing timers. You want your weapons desynced — when Heroic Strike is queued, your off-hand's dual-wield miss penalty is removed, but only if the off-hand swings while HS is still queued (not at the same instant the main-hand consumes it). Bars turn green when desynced and red when synced. Use a desync macro if they drift together.") .. "\n"
										elseif spec == "ARMS" then
											return Dim("Tracks your melee swing timer. Slam resets this timer, so for maximum DPS you want to Slam right after a swing lands (when the bar reaches the end and resets). This avoids losing auto-attack time to the Slam cast.") .. "\n"
										else
											return Dim("Tracks your melee swing timer — a bar that fills up as your next auto-attack approaches. Auto-hides between pulls.") .. "\n"
										end
									elseif class == C.CLASS.MAGE or class == C.CLASS.PRIEST or class == C.CLASS.WARLOCK then
										return Dim("Tracks your auto-attack timer for wanding or melee. Only appears while actively attacking and auto-hides when you stop.") .. "\n"
									elseif class == C.CLASS.ROGUE then
										return Dim("Tracks your melee swing timer. Shows separate main-hand and off-hand bars when dual-wielding.") .. "\n"
									elseif class == C.CLASS.DRUID then
										return Dim("Tracks your melee swing timer in Cat or Bear Form. Bear Form's 2.5s swing is useful for timing Maul. Auto-hides when not actively swinging.") .. "\n"
									end
									return ""
								end,
								order = 0,
								fontSize = "medium",
							},
							enabled = { type = "toggle", name = "Enabled", desc = "Shows a weapon swing timer bar that fills as your next auto-attack approaches. Includes class-specific colored zones: Hunter shot clipping, Ret Paladin seal twisting, Enhancement/Fury dual-wield sync. Auto-hides when not actively swinging.", arg = "swingBar.enabled", order = 1 },
							layout = {
								type = "group",
								name = "Layout",
								inline = true,
								order = 2,
								disabled = function() return not addon.db.profile.swingBar.enabled end,
								args = {
									width = { type = "range", name = "Width", desc = "Width of the swing bar in pixels.", min = 50, max = 600, step = 1, arg = "swingBar.width", order = 1 },
									height = {
										type = "range", name = "Height", order = 2,
										desc = "Height of the swing bar in pixels (single weapon). Per-class/spec: each class or spec remembers its own height.",
										min = 1, max = 20, step = 1,
										get = function()
											local db = addon.db.profile.swingBar
											return db.specHeight[addon.playerSpec] or db.classHeight[addon.playerClass] or db.height
										end,
										set = function(_, val)
											local db = addon.db.profile.swingBar
											if db.specHeight[addon.playerSpec] ~= nil then
												db.specHeight[addon.playerSpec] = val
												Options:ApplySettingChange("swingBar.specHeight")
											else
												db.classHeight[addon.playerClass] = val
												Options:ApplySettingChange("swingBar.classHeight")
											end
										end,
									},
									wandHeight = { type = "range", name = "Wand Height", desc = "Height of the swing bar in pixels for wand users (Mage, Priest, Warlock).", min = 1, max = 20, step = 1, arg = "swingBar.wandHeight", order = 3, hidden = function() local c = addon.playerClass; return c ~= C.CLASS.MAGE and c ~= C.CLASS.PRIEST and c ~= C.CLASS.WARLOCK end },
									dualWieldHeight = { type = "range", name = "Dual-Wield Height", desc = "Height of each bar when dual-wielding (MH and OH bars shown separately).", min = 1, max = 20, step = 1, arg = "swingBar.dualWieldHeight", order = 4, hidden = function() local c = addon.playerClass; return c == C.CLASS.MAGE or c == C.CLASS.PRIEST or c == C.CLASS.WARLOCK or c == C.CLASS.DRUID or c == C.CLASS.PALADIN end },
									dualWieldSpacing = { type = "range", name = "Dual-Wield Spacing", desc = "Gap in pixels between the main-hand and off-hand bars.", min = 0, max = 10, step = 1, arg = "swingBar.dualWieldSpacing", order = 5, hidden = function() local c = addon.playerClass; return c == C.CLASS.MAGE or c == C.CLASS.PRIEST or c == C.CLASS.WARLOCK or c == C.CLASS.DRUID or c == C.CLASS.PALADIN end },
								},
							},
							display = {
								type = "group",
								name = "Display",
								inline = true,
								order = 3,
								disabled = function() return not addon.db.profile.swingBar.enabled end,
								args = {
									showSpark = { type = "toggle", name = "Show Spark", desc = "Show a glowing spark at the fill edge of the bar.", arg = "swingBar.showSpark", order = 1 },
									hideDelay = { type = "range", name = "Hide Delay", desc = "Seconds to wait after the last swing before auto-hiding the bar.", min = 0, max = 10, step = 0.1, arg = "swingBar.hideDelay", order = 2 },
									color = {
										type = "color", name = "Bar Color", hasAlpha = false,
										desc = "The fill color of the swing bar. Disabled when class-specific coloring overrides the entire bar.",
										get = colorGet, set = colorSet, arg = "swingBar.color", order = 3,
										disabled = function()
											if not addon.db.profile.swingBar.enabled then return true end
											local class = addon.playerClass
											local spec = addon.playerSpec
											local db = addon.db.profile.swingBar
											-- Full override: entire bar is zone-colored, base color unused
											-- Hunter shot zones only override ranged bar; melee still uses base color
											if (class == C.CLASS.SHAMAN and spec == "ENHANCEMENT") and db.enableSyncColors then return true end
											if (class == C.CLASS.WARRIOR and spec == "FURY") and db.enableSyncColors then return true end
											return false
										end,
									},
								},
							},
							text = {
								type = "group",
								name = "Timer Text",
								inline = true,
								order = 4,
								disabled = function() return not addon.db.profile.swingBar.enabled end,
								args = {
									showText = { type = "toggle", name = "Show Timer Text", desc = "Show a countdown timer on the bar.", arg = "swingBar.showText", order = 1 },
									textSize = { type = "range", name = "Text Size", desc = "Font size for the timer text.", min = 6, max = 24, step = 1, arg = "swingBar.textSize", order = 2, disabled = function() return not addon.db.profile.swingBar.showText end },
									textOutline = { type = "select", name = "Text Outline", desc = "Text outline style for the swing bar.", values = textOutlineValuesInherit, sorting = textOutlineSortingInherit, arg = "swingBar.textOutline", order = 3, disabled = function() return not addon.db.profile.swingBar.showText end },
								},
							},
							classOptions = {
								type = "group",
								name = "Class Options",
								inline = true,
								order = 5,
								disabled = function() return not addon.db.profile.swingBar.enabled end,
								hidden = function()
									local class = addon.playerClass
									local spec = addon.playerSpec
									return class ~= C.CLASS.HUNTER
										and not (class == C.CLASS.SHAMAN and spec == "ENHANCEMENT")
										and not (class == C.CLASS.WARRIOR and spec == "FURY")
										and not (class == C.CLASS.PALADIN and spec == "RETRIBUTION")
								end,
								args = {
									-- Hunter: shot zones
									enableClipZones = { type = "toggle", name = "Enable Shot Zones", desc = "Color the bar by auto-shot timing:\n\n|cffffffffGreen|r — Safe to cast anything and move freely.\n|cffffffffYellow|r — Steady Shot would clip, but instants and movement are safe.\n|cffffffffRed|r — Don't move or cast Multi-Shot (auto-shot animation playing).", arg = "swingBar.enableClipZones", order = 1, width = "full", hidden = function() return addon.playerClass ~= C.CLASS.HUNTER end },
									hunterSafeColor = { type = "color", name = "Safe Zone (Green)", desc = "Bar color when it's safe to cast and move.", hasAlpha = false, get = colorGet, set = colorSet, arg = "swingBar.safeColor", order = 2, hidden = function() return addon.playerClass ~= C.CLASS.HUNTER end, disabled = function() return not addon.db.profile.swingBar.enableClipZones end },
									hunterCautionColor = { type = "color", name = "Steady Zone (Yellow)", desc = "Bar color when Steady Shot would clip, but instant shots and movement are still safe.", hasAlpha = false, get = colorGet, set = colorSet, arg = "swingBar.cautionColor", order = 3, hidden = function() return addon.playerClass ~= C.CLASS.HUNTER end, disabled = function() return not addon.db.profile.swingBar.enableClipZones end },
									hunterDangerColor = { type = "color", name = "Stop Zone (Red)", desc = "Bar color when moving would cancel your auto-shot and Multi-Shot would clip.", hasAlpha = false, get = colorGet, set = colorSet, arg = "swingBar.dangerColor", order = 4, hidden = function() return addon.playerClass ~= C.CLASS.HUNTER end, disabled = function() return not addon.db.profile.swingBar.enableClipZones end },

									-- Ret Paladin: twist window
									enableTwistWindow = { type = "toggle", name = "Enable Twist Window", desc = "Highlight the last ~0.4 seconds before your melee swing with a different color — your cue to swap seals for seal twisting.", arg = "swingBar.enableTwistWindow", order = 5, width = "full", hidden = function() return not (addon.playerClass == C.CLASS.PALADIN and addon.playerSpec == "RETRIBUTION") end },
									twistColor = { type = "color", name = "Twist Window Color", desc = "Bar color during the seal twist window.", hasAlpha = false, get = colorGet, set = colorSet, arg = "swingBar.safeColor", order = 6, hidden = function() return not (addon.playerClass == C.CLASS.PALADIN and addon.playerSpec == "RETRIBUTION") end, disabled = function() return not addon.db.profile.swingBar.enableTwistWindow end },

									-- Zone opacity (Hunter shot zones + Ret twist window)
									zoneAlpha = {
										type = "range", name = "Zone Opacity", min = 0, max = 1, step = 0.05,
										desc = "Opacity of the background zone indicators that preview upcoming color changes on the bar.",
										arg = "swingBar.zoneAlpha", order = 7, isPercent = true,
										hidden = function()
											return addon.playerClass ~= C.CLASS.HUNTER
												and not (addon.playerClass == C.CLASS.PALADIN and addon.playerSpec == "RETRIBUTION")
										end,
										disabled = function()
											local db = addon.db.profile.swingBar
											if addon.playerClass == C.CLASS.HUNTER and db.enableClipZones then return false end
											if addon.playerClass == C.CLASS.PALADIN and addon.playerSpec == "RETRIBUTION" and db.enableTwistWindow then return false end
											return true
										end,
									},

									-- Hunter: melee weaving (not zone-related, placed after zone options)
									enableMeleeWeaving = { type = "toggle", name = "Melee Weaving", desc = "Show both ranged and melee swing bars simultaneously. For advanced hunters who weave melee attacks (e.g., Raptor Strike) between auto-shots.", arg = "swingBar.enableMeleeWeaving", order = 10, width = "full", hidden = function() return addon.playerClass ~= C.CLASS.HUNTER end },

									-- Enhancement Shaman / Fury Warrior: sync colors
									enableSyncColors = {
										type = "toggle", name = "Enable Sync Colors",
										desc = function()
											if addon.playerClass == C.CLASS.WARRIOR then
												return "Color both bars by how well your weapons are desynced. |cffffffffGreen|r when desynced (ideal for Heroic Strike queue), |cffffffffRed|r when synced (off-hand misses the HS hit bonus)."
											end
											return "Color both bars by how well your main-hand and off-hand swings are synced. |cffffffffGreen|r when synced, |cffffffffRed|r when drifted apart."
										end,
										arg = "swingBar.enableSyncColors", order = 20, width = "full",
										hidden = function() return not ((addon.playerClass == C.CLASS.SHAMAN and addon.playerSpec == "ENHANCEMENT") or (addon.playerClass == C.CLASS.WARRIOR and addon.playerSpec == "FURY")) end,
									},
									syncThreshold = {
										type = "range", name = "Sync Threshold",
										desc = function()
											if addon.playerClass == C.CLASS.WARRIOR then
												return "How close (in seconds) your swings need to be to count as synced (red). If the bars flicker too often, increase this value."
											end
											return "How close (in seconds) your main-hand and off-hand swings need to be to count as synced (green). If the bars flicker between green and red too often, increase this value."
										end,
										min = 0.1, max = 2.0, step = 0.05, arg = "swingBar.syncThreshold", order = 21,
										hidden = function() return not ((addon.playerClass == C.CLASS.SHAMAN and addon.playerSpec == "ENHANCEMENT") or (addon.playerClass == C.CLASS.WARRIOR and addon.playerSpec == "FURY")) or not addon.db.profile.swingBar.enableSyncColors end,
									},
									syncSafeColor = {
										type = "color",
										name = function()
											if addon.playerClass == C.CLASS.WARRIOR then return "Desynced Color" end
											return "Synced Color"
										end,
										desc = function()
											if addon.playerClass == C.CLASS.WARRIOR then return "Bar color when your weapons are well-separated (good — HS queue effective)." end
											return "Bar color when both weapons are swinging in sync."
										end,
										hasAlpha = false, get = colorGet, set = colorSet, arg = "swingBar.safeColor", order = 22,
										hidden = function() return not ((addon.playerClass == C.CLASS.SHAMAN and addon.playerSpec == "ENHANCEMENT") or (addon.playerClass == C.CLASS.WARRIOR and addon.playerSpec == "FURY")) or not addon.db.profile.swingBar.enableSyncColors end,
									},
									syncDangerColor = {
										type = "color",
										name = function()
											if addon.playerClass == C.CLASS.WARRIOR then return "Synced Color" end
											return "Desynced Color"
										end,
										desc = function()
											if addon.playerClass == C.CLASS.WARRIOR then return "Bar color when both weapons are swinging together (bad — HS queue ineffective)." end
											return "Bar color when your weapons have drifted apart."
										end,
										hasAlpha = false, get = colorGet, set = colorSet, arg = "swingBar.dangerColor", order = 23,
										hidden = function() return not ((addon.playerClass == C.CLASS.SHAMAN and addon.playerSpec == "ENHANCEMENT") or (addon.playerClass == C.CLASS.WARRIOR and addon.playerSpec == "FURY")) or not addon.db.profile.swingBar.enableSyncColors end,
									},
								},
							},
						},
					},
				},
			},

			spells = {
				type = "group",
				name = "Spell Config",
				order = 3,
				args = {
					_desc = {
						type = "description",
						name = Dim("Click the button below to open the spell configuration window — enable/disable spells, reorder them, and drag between rows."),
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
					soundDesc = {
						type = "description",
						name = "\n" .. Dim("Play a sound when an ability becomes ready — when it comes off cooldown, becomes usable, or meets resource requirements. Set a default sound for all abilities, or override individual spells below.\n\nSound plays for all rows regardless of the Ready Glow row filter. Other settings still apply: combat-only, pre-trigger time, and once vs. re-trigger mode."),
						fontSize = "medium",
						order = 2.5,
					},
					readyGlowSoundOverrides = {
						type = "group",
						name = "Ready Glow Sound",
						inline = true,
						order = 3,
						args = self:BuildReadyGlowSoundOverrideArgs(),
					},
				},
			},

			support = {
				type = "group",
				name = "Support",
				order = 9,
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

	-- Inject per-row settings as sub-tabs of Ability Rows
	-- Display order: Primary, Secondary, Utility, Auxiliary (by importance)
	local rowTabOrder = { 7, 8, 9, 10 }  -- row1=7, row2=8, row3=9, row4=10
	for key, rowDef in pairs(rowArgs) do
		local rowIndex = tonumber(key:match("(%d+)$"))
		rowDef.order = rowTabOrder[rowIndex] or (rowIndex + 6)
		if rowDef.name and not rowDef.name:match("Row$") then
			rowDef.name = rowDef.name .. " Row"
		end
		optionsTable.args.icons.args[key] = rowDef
	end

	-- Restructure Bars: reorder sub-tabs
	local barsArgs = optionsTable.args.bars.args
	barsArgs.health.order = 1
	barsArgs.resource.order = 2
	barsArgs.combopoints.order = 3
	barsArgs.swingbar.order = 4

	-- Nest Energy Ticker, Mana Ticker, Druid Mana Bar as inline groups within Resource Bar
	local resourceArgs = barsArgs.resource.args
	barsArgs.energyTicker.inline = true
	barsArgs.energyTicker.order = 10
	resourceArgs.energyTicker = barsArgs.energyTicker
	barsArgs.energyTicker = nil

	barsArgs.manaTicker.inline = true
	barsArgs.manaTicker.order = 11
	resourceArgs.manaTicker = barsArgs.manaTicker
	barsArgs.manaTicker = nil

	barsArgs.druidManaBar.inline = true
	barsArgs.druidManaBar.order = 12
	resourceArgs.druidManaBar = barsArgs.druidManaBar
	barsArgs.druidManaBar = nil

	-- Promote Aura Tracker, Buff Reminders to top-level tabs
	local auraTrackerOpts = self:BuildAuraTrackerOptions(barsArgs.procs)
	if auraTrackerOpts then
		auraTrackerOpts.order = 5
		optionsTable.args.procs = auraTrackerOpts
	end
	barsArgs.procs = nil

	-- Remove deprecated Totem Bar section (totems now live in icon rows)
	barsArgs.totembar = nil

	-- Cooldown Pulse tab
	optionsTable.args.cooldownPulse = {
		type = "group",
		name = "Cooldown Pulse",
		order = 6,
		args = {
			introDesc = {
				type = "description",
				name = Dim("Flashes a large icon in the center of the screen when a tracked ability comes off cooldown. A prominent visual cue that complements the ready glow on ability icons.") .. "\n",
				fontSize = "medium",
				order = 0,
			},
			enabled = {
				type = "toggle",
				name = "Enable Cooldown Pulse",
				desc = "Master toggle for the cooldown pulse effect. When enabled, a large icon briefly flashes on screen each time a tracked ability finishes its cooldown.",
				arg = "cooldownPulse.enabled",
				order = 1,
				width = "full",
			},
			appearance = {
				type = "group",
				name = "Appearance",
				inline = true,
				order = 2,
				disabled = function() return not addon.db.profile.cooldownPulse.enabled end,
				args = {
					iconSize = {
						type = "range",
						name = "Icon Size",
						desc = "How large the flashing icon appears on screen, in pixels.",
						min = 16, max = 120, step = 1,
						arg = "cooldownPulse.iconSize",
						order = 1,
					},
					maxAlpha = {
						type = "range",
						name = "Opacity",
						desc = "Peak opacity of the icon during the flash. Lower values create a more subtle, ghostly effect.",
						min = 0.1, max = 1.0, step = 0.05,
						isPercent = true,
						arg = "cooldownPulse.maxAlpha",
						order = 2,
					},
					positionSpacer = {
						type = "description",
						name = "",
						width = "full",
						order = 2.5,
					},
					xOffset = {
						type = "range",
						name = "X Offset",
						desc = "Horizontal offset from the center of your screen. Negative values move left, positive values move right.",
						min = -screenW, max = screenW, step = 1,
						arg = "cooldownPulse.anchor.x",
						order = 3,
					},
					yOffset = {
						type = "range",
						name = "Y Offset",
						desc = "Vertical offset from the center of your screen. Negative values move down, positive values move up.",
						min = -screenH, max = screenH, step = 1,
						arg = "cooldownPulse.anchor.y",
						order = 4,
					},
				},
			},
			filtering = {
				type = "group",
				name = "Filtering",
				inline = true,
				order = 3,
				disabled = function() return not addon.db.profile.cooldownPulse.enabled end,
				args = {
					pulseRows = {
						type = "select",
						name = "Ability Rows",
						desc = "Which ability rows trigger the cooldown pulse. Primary Row is your core rotation — the most impactful notifications. Add Secondary to include throughput cooldowns too.",
						values = rowSettingAll,
						arg = "cooldownPulse.pulseRows",
						width = "normal",
						order = 1,
					},
					onlyInCombat = {
						type = "toggle",
						name = "Only In Combat",
						desc = "Only show cooldown pulses while you are in combat.",
						arg = "cooldownPulse.onlyInCombat",
						width = "normal",
						order = 2,
					},
					filteringSpacer = {
						type = "description",
						name = "",
						width = "full",
						order = 2.5,
					},
					minCooldown = {
						type = "range",
						name = "Ignore Cooldowns Below",
						desc = "Skip pulses for abilities with cooldowns shorter than this. Useful for filtering out short-cooldown rotational spells. Set to 0 to include everything.",
						min = 0, max = 300, step = 1, bigStep = 5,
						arg = "cooldownPulse.minCooldown",
						width = "normal",
						order = 3,
					},
				},
			},
			animation = {
				type = "group",
				name = "Animation",
				inline = true,
				order = 4,
				disabled = function() return not addon.db.profile.cooldownPulse.enabled end,
				args = {
					animationIn = {
						type = "select",
						name = "Fade In Effect",
						desc = "Size effect while the icon fades in. Grow: starts small, grows to normal. Shrink: starts big, shrinks to normal. None: no size change.",
						values = {
							[C.PULSE_EFFECT.GROW] = "Grow",
							[C.PULSE_EFFECT.SHRINK] = "Shrink",
							[C.PULSE_EFFECT.NONE] = "None",
						},
						arg = "cooldownPulse.animationIn",
						width = "normal",
						order = 1,
					},
					animationOut = {
						type = "select",
						name = "Fade Out Effect",
						desc = "Size effect while the icon fades out. Grow: grows from normal to big. Shrink: shrinks from normal to small. None: no size change.",
						values = {
							[C.PULSE_EFFECT.GROW] = "Grow",
							[C.PULSE_EFFECT.SHRINK] = "Shrink",
							[C.PULSE_EFFECT.NONE] = "None",
						},
						arg = "cooldownPulse.animationOut",
						width = "normal",
						order = 2,
					},
					animationSpacer = {
						type = "description",
						name = "",
						width = "full",
						order = 2.1,
					},
					fadeInTime = {
						type = "range",
						name = "Fade In",
						desc = "How long the icon takes to fade in, in seconds.",
						min = 0.05, max = 1.0, step = 0.05,
						arg = "cooldownPulse.fadeInTime",
						width = "normal",
						order = 3,
					},
					holdTime = {
						type = "range",
						name = "Hold Time",
						desc = "How long the icon stays at peak opacity before fading out. Set to 0 for a quick flash, or increase for a longer notification.",
						min = 0, max = 1.5, step = 0.05,
						arg = "cooldownPulse.holdTime",
						width = "normal",
						order = 4,
					},
					timingSpacer = {
						type = "description",
						name = "",
						width = "full",
						order = 4.5,
					},
					fadeOutTime = {
						type = "range",
						name = "Fade Out",
						desc = "How long the icon takes to fade out, in seconds.",
						min = 0.05, max = 1.5, step = 0.05,
						arg = "cooldownPulse.fadeOutTime",
						width = "normal",
						order = 5,
					},
					preTriggerTime = {
						type = "range",
						name = "Early Trigger",
						desc = "Fire the pulse this many seconds before the cooldown finishes. Gives you a head start on reacting. Set to 0 to pulse at the exact moment the ability becomes ready.",
						min = 0, max = 3, step = 0.1,
						arg = "cooldownPulse.preTriggerTime",
						width = "normal",
						order = 6,
					},
				},
			},
			testButton = {
				type = "execute",
				name = "Test Pulse",
				desc = "Plays a test pulse so you can preview your current settings.",
				func = function()
					local pulse = addon:GetModule("CooldownPulse")
					if pulse then
						local db = addon.db.profile.cooldownPulse
						pulse:StartPulse("Interface\\Icons\\Spell_Nature_Earthbind", db)
					end
				end,
				disabled = function() return not addon.db.profile.cooldownPulse.enabled end,
				order = 10,
			},
		},
	}

	local buffRemindersOpts = self:BuildBuffRemindersOptions()
	if buffRemindersOpts then
		buffRemindersOpts.order = 7
		optionsTable.args.buffReminders = buffRemindersOpts
	end

	-- Create Advanced tab from Layout
	optionsTable.args.advanced = {
		type = "group",
		name = "Layout",
		order = 8,
		args = layoutArgs,
	}

	-- Enrich all setting tooltips with their default values
	enrichDescsWithDefaults(optionsTable.args)

	return optionsTable
end

-------------------------------------------------------------------------------
-- Aura Tracker Options Tab
-------------------------------------------------------------------------------

-- Shared dropdown values for aura source filter (used by external + custom aura config)
local auraSourceFilterValues = {
	[C.AURA_SOURCE_ANY] = "Any",
	[C.AURA_SOURCE_OWN] = "Own",
	[C.AURA_SOURCE_NOT_OWN] = "Others",
}

function Options:BuildAuraTrackerOptions(settingsGroup)
	local LibSpellDB = addon.LibSpellDB

	local function buildProcSpellArgs()
		local args = {}
		if not LibSpellDB then return args end

		local playerClass = addon.playerClass
		if not playerClass then return args end

		local classProcs = LibSpellDB:GetProcs(playerClass)
		if not classProcs or #classProcs == 0 then return args end

		-- Sort: normal procs alphabetically, then low priority alphabetically
		-- Filter out equipment-gated procs if required items aren't equipped
		local sorted = {}
		for _, procData in ipairs(classProcs) do
			local include = true
			local requiredItems = procData.requiredItemIDs
			if requiredItems then
				include = false
				for _, itemID in ipairs(requiredItems) do
					if IsEquippedItem(itemID) then
						include = true
						break
					end
				end
			end
			if include then
				table.insert(sorted, procData)
			end
		end
		table.sort(sorted, function(a, b)
			local aLow = a.procInfo and a.procInfo.lowPriority
			local bLow = b.procInfo and b.procInfo.lowPriority
			if aLow ~= bLow then return not aLow end
			return (a.name or "") < (b.name or "")
		end)

		-- Intro description
		args["introDesc"] = {
			type = "description",
			name = Dim("Toggle which class procs are tracked. Enabled procs appear as icons in the Aura Tracker when active.") .. "\n",
			fontSize = "medium",
			order = 0,
		}

		-- Spec indicator at top
		args["specIndicator"] = {
			type = "description",
			name = function()
				local sk = addon.Database:GetSpecKey()
				if sk then
					return Dim("Current spec: " .. addon:FormatSpecKey(sk))
				end
				return Dim("Spec not yet detected")
			end,
			fontSize = "medium",
			order = 1,
			width = "full",
		}

		local order = 10
		for _, procData in ipairs(sorted) do
			local spellID = procData.spellID
			local spellName = GetSpellInfo(spellID)
			spellName = spellName or procData.name or ("Spell " .. spellID)
			-- Use LibSpellDB icon (handles overrides like Mace Spec talent icon)
			local displayIcon = LibSpellDB and LibSpellDB:GetSpellIcon(spellID)
			-- For equipment-gated procs, use the equipped item's icon
			if procData.requiredItemIDs then
				for _, itemID in ipairs(procData.requiredItemIDs) do
					if IsEquippedItem(itemID) then
						displayIcon = GetItemIcon(itemID) or displayIcon
						break
					end
				end
			end
			local iconString = displayIcon and ("|T" .. displayIcon .. ":16|t ") or ""

			local procDesc = procData.procInfo and procData.procInfo.description or ""
			local spellKey = "proc_" .. spellID

			args[spellKey] = {
				type = "group",
				name = iconString .. spellName,
				inline = true,
				order = order,
				args = {
					enabled = {
						type = "toggle",
						name = "Enabled",
						desc = "Show this aura in the tracker.",
						get = function()
							return addon:IsAuraEnabled(spellID)
						end,
						set = function(_, value)
							addon:SetAuraEnabled(spellID, value)
							Options:ApplySettingChange("auraTracker.auraConfig")
						end,
						order = 1,
						width = 0.5,
					},
					glow = {
						type = "toggle",
						name = "Glow",
						desc = "Show the glowing border and backdrop halo when this aura is active. Disable for auras you want to track quietly without the glow drawing your eye.",
						get = function()
							return addon:IsAuraGlowEnabled(spellID)
						end,
						set = function(_, value)
							addon:SetAuraGlowEnabled(spellID, value)
							Options:ApplySettingChange("auraTracker.auraGlowConfig")
						end,
						order = 1.5,
						width = 0.4,
						disabled = function()
							return not addon:IsAuraEnabled(spellID)
						end,
					},
					sound = SoundDropdown({
						desc = "Sound to play when this aura activates. 'None' uses the global default from the Sound section above.",
						get = function() return addon:GetAuraSound(spellID) or "None" end,
						set = function(_, value) addon:SetAuraSound(spellID, value) end,
						order = 1.6,
						disabled = function() return not addon:IsAuraEnabled(spellID) end,
					}),
					soundOnRefresh = {
						type = "toggle",
						name = "Refresh",
						desc = "Also play the sound when this aura refreshes (is reapplied while already active).",
						get = function()
							return addon:GetAuraSoundOnRefresh(spellID)
						end,
						set = function(_, value)
							addon:SetAuraSoundOnRefresh(spellID, value)
						end,
						order = 1.7,
						width = 0.45,
						disabled = function()
							return not addon:IsAuraEnabled(spellID)
						end,
					},
					description = {
						type = "description",
						name = Dim(procDesc),
						order = 2,
						width = "full",
					},
				},
			}
			order = order + 1
		end

		return args
	end

	-- Store args table reference for rebuilding on spec change
	local spellsArgs = buildProcSpellArgs()
	self._auraSpellArgs = spellsArgs
	self._buildAuraSpellArgs = buildProcSpellArgs

	-- Build External Buffs tab
	local externalArgs = self:BuildExternalBuffsArgs()

	-- Build Custom Auras tab
	local customArgs = self:BuildCustomAurasArgs()

	-- Wrap existing settings into a Settings sub-tab, add Spells sub-tab
	settingsGroup.order = 1
	settingsGroup.name = "Settings"

	return {
		type = "group",
		name = "Aura Tracker",
		childGroups = "tab",
		args = {
			settings = settingsGroup,
			spellsTab = {
				type = "group",
				name = "Class Procs",
				order = 2,
				disabled = function()
					return addon.db and addon.db.profile and not addon.db.profile.auraTracker.enabled
				end,
				args = spellsArgs,
			},
			externalsTab = {
				type = "group",
				name = "External Buffs",
				order = 3,
				disabled = function()
					return addon.db and addon.db.profile and not addon.db.profile.auraTracker.enabled
				end,
				args = externalArgs,
			},
			customTab = {
				type = "group",
				name = "Custom Auras",
				order = 4,
				disabled = function()
					return addon.db and addon.db.profile and not addon.db.profile.auraTracker.enabled
				end,
				args = customArgs,
			},
		},
	}
end

-------------------------------------------------------------------------------
-- External Buffs Args
-------------------------------------------------------------------------------

-- Classify an external spell into a UI category based on its LibSpellDB tags.
-- Returns categoryName, categoryOrder. First matching rule wins.
local function ClassifyExternal(lib, spellID, isMinor)
	if lib:HasTag(spellID, "PVP_POWERUP") then return "PvP Powerups", 5 end
	if lib:HasTag(spellID, "DRUMS") then return "Drums", 4 end
	if not isMinor then
		if lib:HasTag(spellID, "RAID_DEFENSIVE") then return "Raid Cooldowns", 1 end
		if lib:HasTag(spellID, "EXTERNAL_DEFENSIVE") or lib:HasTag(spellID, "DEFENSIVE") then return "Defensive Externals", 2 end
		return "Other Externals", 3
	end
	return "Minor Externals", 6
end

function Options:BuildExternalBuffsArgs()
	local args = {}

	args["description"] = {
		type = "description",
		name = Dim("Toggle which external buffs are tracked (from other players, consumables, or PvP powerups). These appear as icons in the Aura Tracker when active on you.") .. "\n",
		fontSize = "medium",
		order = 0,
	}

	local lib = addon.LibSpellDB
	if not lib then return args end

	-- Collect all external spells from LibSpellDB and classify into categories
	local categories = {}  -- name -> {order, spells={{spellID, sortName}}}
	for _, tag in ipairs({"IMPORTANT_EXTERNAL", "MINOR_EXTERNAL"}) do
		local isMinor = (tag == "MINOR_EXTERNAL")
		local tagged = lib:GetSpellsByTag(tag)
		for _, spellData in pairs(tagged) do
			local catName, catOrder = ClassifyExternal(lib, spellData.spellID, isMinor)
			if not categories[catName] then
				categories[catName] = {order = catOrder, spells = {}}
			end
			local sortName = spellData.name or GetSpellInfo(spellData.spellID) or ""
			table.insert(categories[catName].spells, {spellID = spellData.spellID, sortName = sortName})
		end
	end

	-- Sort spells alphabetically within each category
	for _, cat in pairs(categories) do
		table.sort(cat.spells, function(a, b) return a.sortName < b.sortName end)
	end

	-- Build sorted category list
	local sortedCats = {}
	for catName, cat in pairs(categories) do
		table.insert(sortedCats, {name = catName, order = cat.order, spells = cat.spells})
	end
	table.sort(sortedCats, function(a, b) return a.order < b.order end)

	-- Build AceConfig args
	for _, category in ipairs(sortedCats) do
		local groupArgs = {}
		local spellOrder = 1

		for _, entry in ipairs(category.spells) do
			local spellID = entry.spellID
			local spellName, _, spellIcon = GetSpellInfo(spellID)
			spellName = spellName or ("Spell " .. spellID)
			local iconString = spellIcon and ("|T" .. spellIcon .. ":16|t ") or ""
			local spellKey = "ext_" .. spellID

			groupArgs[spellKey] = {
				type = "group",
				name = iconString .. spellName,
				inline = true,
				order = spellOrder,
				args = {
					enabled = {
						type = "toggle",
						name = "Enabled",
						desc = "Track " .. spellName .. " (ID: " .. spellID .. ")",
						get = function() return addon:IsAuraEnabled(spellID) end,
						set = function(_, value)
							addon:SetAuraEnabled(spellID, value)
							Options:ApplySettingChange("auraTracker.auraConfig")
						end,
						order = 1,
						width = 0.5,
					},
					glow = {
						type = "toggle",
						name = "Glow",
						desc = "Show the glowing border and backdrop halo when this aura is active.",
						get = function() return addon:IsAuraGlowEnabled(spellID) end,
						set = function(_, value)
							addon:SetAuraGlowEnabled(spellID, value)
							Options:ApplySettingChange("auraTracker.auraGlowConfig")
						end,
						order = 2,
						width = 0.4,
						disabled = function() return not addon:IsAuraEnabled(spellID) end,
					},
					source = {
						type = "select",
						name = "",
						values = auraSourceFilterValues,
						get = function() return addon:GetAuraSourceFilter(spellID, "external") end,
						set = function(_, value)
							addon:SetAuraSourceFilter(spellID, value, "external")
							Options:ApplySettingChange("auraTracker.auraSourceFilter")
						end,
						order = 3,
						width = 0.5,
						disabled = function() return not addon:IsAuraEnabled(spellID) end,
					},
					sound = SoundDropdown({
						desc = "Sound to play when this aura activates. 'None' uses the global default.",
						get = function() return addon:GetAuraSound(spellID) or "None" end,
						set = function(_, value) addon:SetAuraSound(spellID, value) end,
						order = 4,
						disabled = function() return not addon:IsAuraEnabled(spellID) end,
					}),
					soundRefresh = {
						type = "toggle",
						name = "Refresh",
						desc = "Also play the sound when this aura refreshes.",
						get = function() return addon:GetAuraSoundOnRefresh(spellID) end,
						set = function(_, value) addon:SetAuraSoundOnRefresh(spellID, value) end,
						order = 5,
						width = 0.4,
						disabled = function() return not addon:IsAuraEnabled(spellID) end,
					},
				},
			}
			spellOrder = spellOrder + 1
		end

		args["cat_" .. category.order] = {
			type = "group",
			name = category.name,
			inline = true,
			order = category.order,
			args = groupArgs,
		}
	end

	return args
end

-------------------------------------------------------------------------------
-- Custom Auras Args
-------------------------------------------------------------------------------

function Options:BuildCustomAurasArgs()
	local args = {}

	-- Temp state for input field and status message (not saved to profile)
	self._customAuraInput = self._customAuraInput or ""
	self._customAuraStatus = self._customAuraStatus or ""

	args["description"] = {
		type = "description",
		name = Dim("Add custom auras to track by spell ID or spell name. These work like procs — the icon appears when the buff is active on you.") .. "\n",
		fontSize = "medium",
		order = 0,
	}

	args["inputField"] = {
		type = "input",
		name = "Spell ID or Name",
		desc = "Enter a numeric spell ID or exact spell name and press Enter to add.\n\nYou can find spell IDs on Wowhead (the number at the end of the spell URL), or install the idTip addon to see spell IDs directly in tooltips.",
		get = function() return self._customAuraInput or "" end,
		set = function(_, value)
			if not value or value == "" then
				self._customAuraInput = ""
				self._customAuraStatus = ""
				return
			end

			local spellID = tonumber(value)
			local entry = {}
			local resolvedName, _, resolvedIcon
			if spellID then
				-- Numeric input: resolve by spell ID (may be nil for NPC/encounter buffs)
				resolvedName, _, resolvedIcon = GetSpellInfo(spellID)
				entry.id = spellID
			else
				-- Name input: try to resolve to a spell ID for reliable tracking
				local resolvedID
				-- 1. Try GetSpellInfo(name) — works for spells the player knows
				resolvedName, _, resolvedIcon, _, _, _, resolvedID = GetSpellInfo(value)
				if resolvedName and resolvedID then
					entry.id = resolvedID
				elseif not resolvedName then
					-- 2. Search LibSpellDB by name (case-insensitive)
					local lib = addon.LibSpellDB
					if lib then
						local lowerValue = value:lower()
						for id, data in pairs(lib:GetAllSpells()) do
							if data.name and data.name:lower() == lowerValue then
								resolvedName, _, resolvedIcon = GetSpellInfo(id)
								if resolvedName then
									entry.id = id
									break
								end
							end
						end
					end
				end
				-- 3. Still unresolved — store by name; will match at runtime when buff appears
				if not resolvedName then
					resolvedName = value
					entry.name = value
				elseif not entry.id then
					-- GetSpellInfo found the name but no ID (known spell, no ID returned)
					entry.name = value
				end
			end

			-- Check for duplicates
			local customAuras = addon.db.profile.auraTracker.customAuras
			for _, existing in ipairs(customAuras) do
				if (entry.id and existing.id == entry.id)
					or (entry.name and existing.name == entry.name) then
					self._customAuraInput = ""
					self._customAuraStatus = "|cffff8800" .. (resolvedName or ("ID " .. (entry.id or entry.name))) .. " is already being tracked.|r"
					return
				end
			end
			table.insert(customAuras, entry)

			-- Clear input and show success
			self._customAuraInput = ""
			local iconString = resolvedIcon and ("|T" .. resolvedIcon .. ":16|t ") or ""
			if not resolvedName then
				self._customAuraStatus = "|cff00ff00Added:|r ID " .. entry.id .. " |cff888888(icon shows when buff is active)|r"
			elseif entry.name and not entry.id then
				self._customAuraStatus = "|cff00ff00Added:|r " .. resolvedName .. " |cff888888(by name — icon shows when buff is active)|r"
			else
				self._customAuraStatus = "|cff00ff00Added:|r " .. iconString .. resolvedName
			end
			self:RebuildCustomAuraEntries()

			-- Rebuild tracker frames to pick up the new aura
			local tracker = addon:GetModule("AuraTracker")
			if tracker then tracker:RebuildFrames() end
		end,
		order = 1,
		width = 1.5,
	}

	args["status"] = {
		type = "description",
		name = function()
			return self._customAuraStatus or ""
		end,
		fontSize = "medium",
		order = 2,
		width = "full",
	}

	args["spacer"] = {
		type = "description",
		name = "\n",
		order = 4,
	}

	-- Build entries for existing custom auras
	args["entries"] = {
		type = "group",
		name = "Current Custom Auras",
		inline = true,
		order = 5,
		args = {},
	}

	self._customEntriesArgs = args["entries"].args
	self:RebuildCustomAuraEntries()

	-- Recently seen buffs section (rebuilds on every render pass via hidden callback)
	args["recentBuffs"] = {
		type = "group",
		name = "Recently Seen Buffs",
		inline = true,
		order = 10,
		hidden = function()
			self:RebuildRecentBuffEntries()
			return false
		end,
		args = {},
	}

	self._recentBuffsArgs = args["recentBuffs"].args

	return args
end

-- Rebuild the custom aura entries list
function Options:RebuildCustomAuraEntries()
	local entriesArgs = self._customEntriesArgs
	if not entriesArgs then return end

	wipe(entriesArgs)

	local customAuras = addon.db and addon.db.profile
		and addon.db.profile.auraTracker and addon.db.profile.auraTracker.customAuras
	if not customAuras or #customAuras == 0 then
		entriesArgs["empty"] = {
			type = "description",
			name = Dim("No custom auras added yet."),
			order = 1,
		}
		return
	end

	for i, entry in ipairs(customAuras) do
		local spellID = entry.id
		local spellName = entry.name
		local resolvedName, _, resolvedIcon
		if spellID then
			resolvedName, _, resolvedIcon = GetSpellInfo(spellID)
		elseif spellName then
			resolvedName, _, resolvedIcon = GetSpellInfo(spellName)
		end
		resolvedName = resolvedName or spellName or ("Unknown Spell " .. (spellID or ""))
		local iconString = resolvedIcon and ("|T" .. resolvedIcon .. ":16|t ") or ""
		local idStr = spellID and (" |cff888888(ID: " .. spellID .. ")|r") or ""

		-- Resolve spell ID for source filter config key
		local filterSpellID = spellID
		if not filterSpellID and resolvedName then
			local _, _, _, _, _, _, resolvedID = GetSpellInfo(spellName)
			filterSpellID = resolvedID or 0
		end

		local entryKey = "custom_" .. i
		entriesArgs[entryKey] = {
			type = "group",
			name = iconString .. resolvedName .. idStr,
			inline = true,
			order = i,
			args = {
				glow = {
					type = "toggle",
					name = "Glow",
					desc = "Show the glowing border and backdrop halo when this aura is active.",
					get = function()
						if not filterSpellID then return true end
						return addon:IsAuraGlowEnabled(filterSpellID)
					end,
					set = function(_, value)
						if filterSpellID then
							addon:SetAuraGlowEnabled(filterSpellID, value)
							Options:ApplySettingChange("auraTracker.auraGlowConfig")
						end
					end,
					order = 1,
					width = 0.4,
				},
				source = {
					type = "select",
					name = "",
					values = auraSourceFilterValues,
					get = function() return addon:GetAuraSourceFilter(filterSpellID, "custom") end,
					set = function(_, value)
						addon:SetAuraSourceFilter(filterSpellID, value, "custom")
						Options:ApplySettingChange("auraTracker.auraSourceFilter")
					end,
					order = 2,
					width = 0.45,
				},
				sound = SoundDropdown({
					desc = "Sound to play when this aura activates. 'None' uses the global default.",
					get = function()
						if not filterSpellID then return "None" end
						return addon:GetAuraSound(filterSpellID) or "None"
					end,
					set = function(_, value)
						if filterSpellID then
							addon:SetAuraSound(filterSpellID, value)
						end
					end,
					order = 3,
				}),
				soundRefresh = {
					type = "toggle",
					name = "Refresh",
					desc = "Also play the sound when this aura refreshes.",
					get = function()
						if not filterSpellID then return false end
						return addon:GetAuraSoundOnRefresh(filterSpellID)
					end,
					set = function(_, value)
						if filterSpellID then
							addon:SetAuraSoundOnRefresh(filterSpellID, value)
						end
					end,
					order = 4,
					width = 0.35,
				},
				remove = {
					type = "execute",
					name = "Del",
					desc = "Remove this custom aura.",
					order = 5,
					width = 0.3,
					func = function()
						if filterSpellID then
							addon:SetAuraGlowEnabled(filterSpellID, true)
							addon:SetAuraSourceFilter(filterSpellID, C.AURA_SOURCE_ANY, "custom")
							addon:SetAuraSound(filterSpellID, nil)
							addon:SetAuraSoundOnRefresh(filterSpellID, addon.db.profile.auraTracker.soundOnRefresh)
						end
						table.remove(customAuras, i)
						self:RebuildCustomAuraEntries()
						self:RebuildRecentBuffEntries()
						local tracker = addon:GetModule("AuraTracker")
						if tracker then tracker:RebuildFrames() end
						local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
						if AceConfigRegistry then
							AceConfigRegistry:NotifyChange("VeevHUD")
						end
					end,
				},
			},
		}
	end
end

-- Rebuild the recently seen buffs list
function Options:RebuildRecentBuffEntries()
	local recentArgs = self._recentBuffsArgs
	if not recentArgs then return end

	wipe(recentArgs)

	local recentBuffs = addon.Utils and addon.Utils.recentPlayerBuffs
	if not recentBuffs or not next(recentBuffs) then
		recentArgs["empty"] = {
			type = "description",
			name = Dim("No recent buffs recorded yet. Play for a bit and reopen this tab."),
			order = 1,
		}
		return
	end

	-- Build sets of already-tracked spell IDs and names
	local trackedIDs = {}
	local trackedNames = {}
	local tracker = addon:GetModule("AuraTracker")
	if tracker then
		-- Class procs
		local procs = tracker:GetProcsForClass(addon.playerClass)
		for _, proc in ipairs(procs) do
			trackedIDs[proc.spellID] = true
			if proc.name then trackedNames[proc.name] = true end
			if proc.allRankIDs then
				for rankID in pairs(proc.allRankIDs) do
					trackedIDs[rankID] = true
				end
			end
		end
		-- External buffs
		local externals = tracker:GetExternalAuras()
		for _, ext in ipairs(externals) do
			trackedIDs[ext.spellID] = true
			if ext.name then trackedNames[ext.name] = true end
			if ext.allRankIDs then
				for rankID in pairs(ext.allRankIDs) do
					trackedIDs[rankID] = true
				end
			end
		end
	end
	-- Custom auras
	local customAuras = addon.db and addon.db.profile
		and addon.db.profile.auraTracker and addon.db.profile.auraTracker.customAuras
	if customAuras then
		for _, entry in ipairs(customAuras) do
			if entry.id then
				trackedIDs[entry.id] = true
			end
			if entry.name then trackedNames[entry.name] = true end
		end
	end

	-- Filter and sort by most recent
	local filtered = {}
	for spellID, data in pairs(recentBuffs) do
		if not trackedIDs[spellID] and not trackedNames[data.name] then
			filtered[#filtered + 1] = { spellID = spellID, name = data.name, icon = data.icon, lastSeen = data.lastSeen }
		end
	end
	table.sort(filtered, function(a, b) return a.lastSeen > b.lastSeen end)

	-- Show only the 20 most recent
	local MAX_DISPLAY = 20
	if #filtered == 0 then
		recentArgs["empty"] = {
			type = "description",
			name = Dim("All recent buffs are already tracked."),
			order = 1,
		}
		return
	end

	for i = 1, math.min(#filtered, MAX_DISPLAY) do
		local entry = filtered[i]
		local iconString = entry.icon and ("|T" .. entry.icon .. ":16|t ") or ""
		local entryKey = "recent_" .. i

		recentArgs[entryKey .. "_label"] = {
			type = "description",
			name = iconString .. (entry.name or ("Spell " .. entry.spellID)) .. " |cff888888(ID: " .. entry.spellID .. ")|r",
			fontSize = "medium",
			order = i * 2 - 1,
			width = 1.4,
		}

		local capturedSpellID = entry.spellID
		recentArgs[entryKey .. "_add"] = {
			type = "execute",
			name = "Add",
			order = i * 2,
			width = 0.5,
			func = function()
				local auras = addon.db.profile.auraTracker.customAuras
				-- Check for duplicates
				for _, existing in ipairs(auras) do
					if existing.id == capturedSpellID then return end
				end
				table.insert(auras, { id = capturedSpellID })
				self:RebuildCustomAuraEntries()
				self:RebuildRecentBuffEntries()
				local tr = addon:GetModule("AuraTracker")
				if tr then tr:RebuildFrames() end
				local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
				if AceConfigRegistry then
					AceConfigRegistry:NotifyChange("VeevHUD")
				end
			end,
		}
	end
end

-- Rebuild the aura spell list in-place (called on spec change)
function Options:RebuildAuraSpellArgs()
	local argsTable = self._auraSpellArgs
	local buildFn = self._buildAuraSpellArgs
	if not argsTable or not buildFn then return end

	wipe(argsTable)
	local newArgs = buildFn()
	for k, v in pairs(newArgs) do
		argsTable[k] = v
	end

	local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
	if AceConfigRegistry then
		AceConfigRegistry:NotifyChange("VeevHUD")
	end
end

-------------------------------------------------------------------------------
-- Buff Reminders Options Tab
-------------------------------------------------------------------------------

function Options:BuildBuffRemindersOptions()
	local LibSpellDB = addon.LibSpellDB

	-- Custom getter/setter for buffReminders settings
	local function brGet(info)
		return addon.Database:GetSettingValue(info.arg)
	end

	local function brSet(info, value)
		addon.Database:SetOverride(info.arg, value)
		Options:ApplySettingChange(info.arg)
	end

	local combatStateValues = {
		["any"] = "Any",
		["combat"] = "In Combat",
		["ooc"] = "Out of Combat",
	}

	local trackTargetValues = {
		["player"] = "Player",
		["party"] = "Party",
		["raid"] = "Raid",
	}

	-- Dynamically build spell config args
	local function buildSpellArgs()
		local args = {}
		if not LibSpellDB then return args end

		local playerClass = addon.playerClass
		if not playerClass then return args end

		-- Per-spec config helpers
		local specKey = addon.Database:GetSpecKey()

		local function getBRSpellConfig(sid)
			local db = addon.db and addon.db.profile and addon.db.profile.buffReminders
			local sc = specKey and db and db.spellConfig[specKey]
			return sc and sc[sid]
		end

		local function setBRSpellConfig(sid, field, value)
			local db = addon.db and addon.db.profile and addon.db.profile.buffReminders
			if not db or not specKey then return end
			if not db.spellConfig[specKey] then db.spellConfig[specKey] = {} end
			if not db.spellConfig[specKey][sid] then db.spellConfig[specKey][sid] = {} end
			db.spellConfig[specKey][sid][field] = value
		end

		local longBuffs = LibSpellDB:GetSpellsByClassAndTag(playerClass, "LONG_BUFF")
		local seenGroups = {}
		local order = 10

		-- Build deduplicated list, resolving groups to canonical representatives.
		-- Mixed-target exclusive groups (e.g., SHAMAN_SHIELD with Earth Shield
		-- on allies + Water/Lightning Shield on self) are split into separate
		-- entries, matching BuildReminderList behavior.
		local brModule = addon:GetModule("BuffReminders")
		local SM = brModule and brModule.SPLIT_MODE
		local entries = {}
		for spellID, spellData in pairs(longBuffs) do
			local groupName = spellData.buffGroup
			if groupName then
				if not seenGroups[groupName] then
					seenGroups[groupName] = true
					local groupInfo = LibSpellDB.BuffGroups[groupName]
					if groupInfo and groupInfo.spells and groupInfo.spells[1] then
						-- Check for mixed-target exclusive groups via cached module method
						local selfSpells, allySpells
						if brModule then
							selfSpells, allySpells = brModule:GetMixedTargetSplit(groupName)
						end
						if selfSpells and allySpells then
							-- Self-target entry (Water Shield / Lightning Shield)
							local selfRep = selfSpells[1]
							local selfData = LibSpellDB:GetSpellInfo(selfRep)
							if selfData then
								table.insert(entries, { spellID = selfRep, data = selfData, groupName = groupName, splitMode = SM.SELF, splitSelfSpells = selfSpells })
							end
							-- Ally-target entries (Earth Shield)
							for _, allyID in ipairs(allySpells) do
								local allyData = LibSpellDB:GetSpellInfo(allyID)
								if allyData then
									table.insert(entries, { spellID = allyID, data = allyData, groupName = groupName, splitMode = SM.ALLY })
								end
							end
						else
							local repID = groupInfo.spells[1]
							local repData = LibSpellDB:GetSpellInfo(repID)
							if repData then
								table.insert(entries, { spellID = repID, data = repData, groupName = groupName })
							end
						end
					end
				end
			else
				table.insert(entries, { spellID = spellID, data = spellData, groupName = nil })
			end
		end

		-- Always filter out spells for other races (a Dwarf can never cast Shadowguard)
		do
			local filteredEntries = {}
			for _, entry in ipairs(entries) do
				if LibSpellDB:IsRaceRelevant(entry.spellID) then
					table.insert(filteredEntries, entry)
				end
			end
			entries = filteredEntries
		end

		-- Filter to only known spells when showOnlyKnown is enabled
		if addon.db.profile.buffReminders.showOnlyKnown then
			local knownEntries = {}
			for _, entry in ipairs(entries) do
				local known = false
				if entry.splitMode then
					-- Split entries: check only the relevant spell(s)
					if entry.splitMode == SM.SELF and entry.splitSelfSpells then
						for _, gSpellID in ipairs(entry.splitSelfSpells) do
							local hr = LibSpellDB:GetHighestKnownRank(gSpellID)
							if hr and IsSpellKnown(hr) then
								known = true
								break
							end
						end
					else
						-- Ally split: check the single spell
						local hr = LibSpellDB:GetHighestKnownRank(entry.spellID)
						known = hr and IsSpellKnown(hr)
					end
				elseif entry.groupName then
					local groupInfo = LibSpellDB.BuffGroups[entry.groupName]
					if groupInfo then
						if groupInfo.talentGate then
							known = IsSpellKnown(groupInfo.talentGate)
						elseif groupInfo.weaponEnchant and groupInfo.itemBased then
							known = UnitLevel("player") >= (groupInfo.minLevel or 1)
						else
							for _, gSpellID in ipairs(groupInfo.spells) do
								local hr = LibSpellDB:GetHighestKnownRank(gSpellID)
								if hr and IsSpellKnown(hr) then
									known = true
									break
								end
							end
						end
					end
				else
					local hr = LibSpellDB:GetHighestKnownRank(entry.spellID)
					known = hr and IsSpellKnown(hr)
				end
				if known then
					table.insert(knownEntries, entry)
				end
			end
			entries = knownEntries
		end

		-- Sort: enabled-by-default first, then alphabetically by display name
		table.sort(entries, function(a, b)
			local aDefaults = brModule and brModule.GetSpellDefaults and brModule:GetSpellDefaults(a.spellID)
			local bDefaults = brModule and brModule.GetSpellDefaults and brModule:GetSpellDefaults(b.spellID)
			local aEnabled = not aDefaults or aDefaults.enabled ~= false
			local bEnabled = not bDefaults or bDefaults.enabled ~= false
			if aEnabled ~= bEnabled then
				return aEnabled  -- enabled first
			end
			-- Within same enabled state, use display name.
			-- Ally-split entries use spell name; self-split and non-split use group description.
			local aName = (a.groupName and a.splitMode ~= SM.ALLY) and LibSpellDB.BuffGroups[a.groupName] and LibSpellDB.BuffGroups[a.groupName].description or (a.data.name or "")
			local bName = (b.groupName and b.splitMode ~= SM.ALLY) and LibSpellDB.BuffGroups[b.groupName] and LibSpellDB.BuffGroups[b.groupName].description or (b.data.name or "")
			return aName < bName
		end)

		for _, entry in ipairs(entries) do
			local spellID = entry.spellID
			local spellData = entry.data
			local groupName = entry.groupName

			do
				local spellName = spellData.name or ("Spell " .. spellID)
				local spellIcon = spellData.icon
				local iconString = spellIcon and ("|T" .. spellIcon .. ":16|t ") or ""

				-- Get the BuffReminders module defaults for this spell
				local defaults = brModule and brModule.GetSpellDefaults and brModule:GetSpellDefaults(spellID)
				local defaultEnabled = not defaults or defaults.enabled ~= false
				local defaultCombatState = defaults and defaults.combatState or "any"
				local defaultTrackTarget = defaults and defaults.trackTarget or "player"

				-- Group label: ally-split entries use the spell name directly ("Earth Shield")
				-- since they track a single spell. Self-split and non-split groups use
				-- the group description ("Shaman shields") since they cover multiple spells.
				local groupLabel = spellName
				if groupName and entry.splitMode ~= SM.ALLY then
					local groupInfo = LibSpellDB.BuffGroups[groupName]
					if groupInfo and groupInfo.description then
						groupLabel = groupInfo.description
					end
				end

				local spellKey = "spell_" .. spellID

				-- Shared disabled check: grey out settings when this reminder is disabled
				local function isSpellDisabled()
					local cfg = getBRSpellConfig(spellID)
					if cfg and cfg.enabled ~= nil then
						return not cfg.enabled
					end
					return not defaultEnabled
				end

				args[spellKey] = {
					type = "group",
					name = iconString .. groupLabel,
					inline = true,
					order = order,
					args = {
						enabled = {
							type = "toggle",
							name = "Enabled",
							desc = "Enable or disable this buff reminder.",
							get = function()
								local cfg = getBRSpellConfig(spellID)
								if cfg and cfg.enabled ~= nil then
									return cfg.enabled
								end
								return defaultEnabled
							end,
							set = function(_, value)
								setBRSpellConfig(spellID, "enabled", value)
								Options:ApplySettingChange("buffReminders.spellConfig")
							end,
							order = 1,
							width = 0.5,
						},
						timeRemaining = {
							type = "range",
							name = "Time Threshold",
							desc = "Show the reminder when the buff has less than this many seconds remaining. Set to 0 to only remind when the buff is completely missing.",
							min = 0, max = 600, step = 5,
							hidden = not spellData.duration or spellData.duration == 0,  -- Hide for permanent auras/toggles
							disabled = isSpellDisabled,
							get = function()
								local cfg = getBRSpellConfig(spellID)
								if cfg and cfg.timeRemaining then
									return cfg.timeRemaining
								end
								return 0
							end,
							set = function(_, value)
								setBRSpellConfig(spellID, "timeRemaining", value)
								Options:ApplySettingChange("buffReminders.spellConfig")
							end,
							order = 2,
							width = 0.8,
						},
						combatState = {
							type = "select",
							name = "Combat",
							desc = "When to show this reminder based on combat state.",
							values = combatStateValues,
							disabled = isSpellDisabled,
							get = function()
								local cfg = getBRSpellConfig(spellID)
								if cfg and cfg.combatState then
									return cfg.combatState
								end
								return defaultCombatState
							end,
							set = function(_, value)
								setBRSpellConfig(spellID, "combatState", value)
								Options:ApplySettingChange("buffReminders.spellConfig")
							end,
							order = 4,
							width = 0.7,
						},
						trackTarget = {
							type = "select",
							name = "Track",
							desc = "Who to check for this buff.\n\n|cffffffffPlayer|r: Only check yourself.\n|cffffffffParty|r: Check all party members (or only yourself if solo).\n|cffffffffRaid|r: Check all raid members (downsizes to party if not in a raid).",
							values = trackTargetValues,
							sorting = {"player", "party", "raid"},
							hidden = not (defaults and defaults.groupTrackable),  -- Hide for self-only buffs / weapon enchants
							disabled = isSpellDisabled,
							get = function()
								local cfg = getBRSpellConfig(spellID)
								if cfg and cfg.trackTarget then
									return cfg.trackTarget
								end
								return defaultTrackTarget
							end,
							set = function(_, value)
								setBRSpellConfig(spellID, "trackTarget", value)
								Options:ApplySettingChange("buffReminders.spellConfig")
							end,
							order = 5,
							width = 0.7,
						},
						sound = SoundDropdown({
							desc = "Sound to play when this buff reminder appears. 'None' uses the global default from the General tab.",
							disabled = isSpellDisabled,
							get = function() return addon:GetBuffReminderSound(spellID) or "None" end,
							set = function(_, value) addon:SetBuffReminderSound(spellID, value) end,
							order = 6,
						}),
					},
				}

				-- Add min stacks option for spells with charges (Inner Fire, Water Shield, Lightning Shield)
				if spellData.duration and spellData.duration <= 600 then
					-- Check if any spell in this entry (or its group) has charges.
					-- For split entries, only check the relevant subset.
					local maxCharges = 0
					local chargeSpells = nil
					if entry.splitMode == SM.SELF and entry.splitSelfSpells then
						chargeSpells = entry.splitSelfSpells
					elseif entry.splitMode == SM.ALLY then
						chargeSpells = {spellID}
					elseif groupName and LibSpellDB then
						local groupInfo = LibSpellDB.BuffGroups[groupName]
						if groupInfo and groupInfo.spells then
							chargeSpells = groupInfo.spells
						end
					end
					if chargeSpells then
						for _, gSpellID in ipairs(chargeSpells) do
							local gData = LibSpellDB:GetSpellInfo(gSpellID)
							if gData and gData.charges and gData.charges > maxCharges then
								maxCharges = gData.charges
							end
						end
					elseif spellData.charges then
						maxCharges = spellData.charges
					end
					if maxCharges > 0 then
						args[spellKey].args.minStacks = {
							type = "range",
							name = "Min Stacks",
							desc = "Show the reminder when stacks fall below this number. Set to 0 to disable stack checking. This is an OR condition with the time threshold.",
							min = 0, max = maxCharges, step = 1,
							disabled = isSpellDisabled,
							get = function()
								local cfg = getBRSpellConfig(spellID)
								if cfg and cfg.minStacks then
									return cfg.minStacks
								end
								return 0
							end,
							set = function(_, value)
								setBRSpellConfig(spellID, "minStacks", value)
								Options:ApplySettingChange("buffReminders.spellConfig")
							end,
							order = 3,
							width = 0.6,
						}
					end
				end

				-- Add priority selector for exclusive buff groups (always on its own line).
				-- Skip for weapon enchant groups and split entries — split groups already
				-- show the correct spell directly, so priority selection is not needed.
				if groupName and not entry.splitMode then
					local groupInfo = LibSpellDB.BuffGroups[groupName]
					if groupInfo and groupInfo.relationship == "exclusive" and not groupInfo.weaponEnchant then
						local priorityValues = {}
						for _, gSpellID in ipairs(groupInfo.spells) do
							local gData = LibSpellDB:GetSpellInfo(gSpellID)
							if gData then
								priorityValues[gSpellID] = gData.name or ("Spell " .. gSpellID)
							end
						end
						-- Line break before priority to keep layout consistent
						args[spellKey].args.priorityBreak = {
							type = "description",
							name = "",
							order = 10,
							width = "full",
						}
						-- Build sorting with default (first in group) at the top
						local prioritySorting = {}
						local defaultPriority = groupInfo.spells[1]
						table.insert(prioritySorting, defaultPriority)
						for _, gSpellID in ipairs(groupInfo.spells) do
							if gSpellID ~= defaultPriority and priorityValues[gSpellID] then
								table.insert(prioritySorting, gSpellID)
							end
						end

						args[spellKey].args.priority = {
							type = "select",
							name = "Priority",
							desc = "Which spell to remind first when no buff from this group is active.",
							values = priorityValues,
							sorting = prioritySorting,
							disabled = isSpellDisabled,
							get = function()
								local cfg = getBRSpellConfig(spellID)
								if cfg and cfg.priority then
									return cfg.priority
								end
								return defaultPriority
							end,
							set = function(_, value)
								setBRSpellConfig(spellID, "priority", value)
								Options:ApplySettingChange("buffReminders.spellConfig")
							end,
							order = 11,
							width = 1.2,
						}
					end
				end

				-- Add per-hand toggles for weapon enchant groups (poisons, imbues)
				if groupName then
					local groupInfo = LibSpellDB.BuffGroups[groupName]
					if groupInfo and groupInfo.weaponEnchant then
						args[spellKey].args.handBreak = {
							type = "description",
							name = "",
							order = 12,
							width = "full",
						}
						args[spellKey].args.weaponEnchantMH = {
							type = "toggle",
							name = "Main Hand",
							desc = "Show a reminder when your main hand weapon is missing an enchant. Disable this if you prefer to benefit from a Shaman's Windfury Totem instead.",
							disabled = isSpellDisabled,
							arg = "buffReminders.weaponEnchantMH",
							order = 13,
						}
						args[spellKey].args.weaponEnchantOH = {
							type = "toggle",
							name = "Off Hand",
							desc = "Show a reminder when your off hand weapon is missing an enchant.",
							disabled = isSpellDisabled,
							arg = "buffReminders.weaponEnchantOH",
							order = 14,
						}
					end
				end

				order = order + 1
			end
		end

		-- Intro description
		args["introDesc"] = {
			type = "description",
			name = Dim("Configure which buff reminders are active. Settings on this tab are per-spec — switching specs loads that spec's configuration.") .. "\n",
			fontSize = "medium",
			order = 0,
		}

		-- Spec indicator at top of spell list
		args["specIndicator"] = {
			type = "description",
			name = function()
				local sk = addon.Database:GetSpecKey()
				if sk then
					return Dim("Current spec: " .. addon:FormatSpecKey(sk))
				end
				return Dim("Spec not yet detected")
			end,
			fontSize = "medium",
			order = 1,
			width = "full",
		}

		-- Add "show only known" toggle at top of spell list
		args["showOnlyKnown"] = {
			type = "toggle",
			name = "Show Only Known Spells",
			desc = "Only shows spells you currently know. Disable to see all class buff spells, including ones you haven't learned yet.",
			get = function()
				return addon.db.profile.buffReminders.showOnlyKnown
			end,
			set = function(_, value)
				addon.Database:SetOverride("buffReminders.showOnlyKnown", value)
				Options:ApplySettingChange("buffReminders.showOnlyKnown")
				-- Rebuild the spell list in-place so the UI reflects the new filter
				Options:RebuildBuffReminderSpellArgs()
			end,
			order = 2,
			width = "full",
		}

		return args
	end

	-- Store the spells args table so it can be rebuilt when showOnlyKnown toggles
	local spellsArgs = buildSpellArgs()
	self._buffReminderSpellArgs = spellsArgs
	self._buildBuffReminderSpellArgs = buildSpellArgs

	return {
		type = "group",
		name = "Buff Reminders",
		childGroups = "tab",
		order = 6,
		args = {
			settings = {
				type = "group",
				name = "Settings",
				order = 1,
				args = {
					description = {
						type = "description",
						name = Dim("Buff Reminders show a large, semi-transparent icon when a long-duration buff you should maintain is missing or about to expire. They are separate from the main HUD icons and only appear when action is needed.\n\nReminders automatically check that you know the spell and have the resources to cast it. Use the Spells tab to configure individual reminders.") .. "\n",
						fontSize = "medium",
						order = 0,
					},
					enabled = {
						type = "toggle",
						name = "Enable Buff Reminders",
						desc = "Master toggle for the Buff Reminders feature. When disabled, no buff reminder icons will be shown.",
						arg = "buffReminders.enabled",
						order = 1,
						width = "full",
					},
					appearance = {
						type = "group",
						name = "Appearance",
						inline = true,
						order = 2,
						disabled = function()
							local db = addon.db and addon.db.profile
							return db and not db.buffReminders.enabled
						end,
						args = {
							iconSize = {
								type = "range",
								name = "Icon Size",
								desc = "The size of buff reminder icons in pixels.",
								min = 24, max = 400, step = 1,
								arg = "buffReminders.iconSize",
								order = 1,
							},
							iconSpacing = {
								type = "range",
								name = "Icon Spacing",
								desc = "The horizontal gap between buff reminder icons.",
								min = -10, max = 64, step = 1,
								arg = "buffReminders.iconSpacing",
								order = 2,
							},
							alpha = {
								type = "range",
								name = "Icon Opacity",
								desc = "The opacity of the buff reminder icons.",
								min = 0.05, max = 1.0, step = 0.05,
								isPercent = true,
								arg = "buffReminders.alpha",
								order = 3,
							},
							textOutline = {
								type = "select",
								name = "Text Outline",
								desc = "Text outline style for buff reminder text.",
								values = textOutlineValuesInherit,
								sorting = textOutlineSortingInherit,
								arg = "buffReminders.textOutline",
								order = 4,
							},
						},
					},
					behavior = {
						type = "group",
						name = "Behavior",
						inline = true,
						order = 2.5,
						disabled = function()
							local db = addon.db and addon.db.profile
							return db and not db.buffReminders.enabled
						end,
						args = {
							pulseEnabled = {
								type = "toggle",
								name = "Pulse Animation",
								desc = "Reminder icons gently pulse to draw attention.",
								arg = "buffReminders.pulseEnabled",
								order = 1,
							},
							respectResourceCost = {
								type = "toggle",
								name = "Respect Resource Cost",
								desc = "Only show buff reminders when you have enough resources (mana, rage, energy) to cast the spell. Uncheck to always show reminders for missing buffs regardless of your current resource level.",
								arg = "buffReminders.respectResourceCost",
								order = 2,
							},
							showWhileResting = {
								type = "toggle",
								name = "Show While Resting",
								desc = "Show buff reminders while in inns and cities.",
								arg = "buffReminders.showWhileResting",
								order = 3,
							},
							showWhileMounted = {
								type = "toggle",
								name = "Show While Mounted",
								desc = "Show buff reminders while mounted.",
								arg = "buffReminders.showWhileMounted",
								order = 4,
							},
							slideAnimation = {
								type = "toggle",
								name = "Slide Animation",
								desc = "When buff reminders appear or disappear, the remaining icons smoothly slide to re-center instead of snapping instantly. Disable for instant repositioning.",
								arg = "buffReminders.slideAnimation",
								order = 5,
							},
						},
					},
					soundGroup = {
						type = "group",
						name = "Sound",
						inline = true,
						order = 2.7,
						disabled = function()
							local db = addon.db and addon.db.profile
							return db and not db.buffReminders.enabled
						end,
						args = {
							soundOnMissing = SoundDropdown({
								name = "Default Sound",
								desc = "Sound to play when a buff reminder first appears. Individual spells can override this in the Spells tab.",
								arg = "buffReminders.soundOnMissing",
								order = 1,
							}),
						},
					},
					position = {
						type = "group",
						name = "Position",
						inline = true,
						order = 3,
						disabled = function()
							local db = addon.db and addon.db.profile
							return db and not db.buffReminders.enabled
						end,
						args = {
							xOffset = {
								type = "range",
								name = "X Offset",
								desc = "Horizontal offset of buff reminder icons relative to the HUD. The range adjusts to your screen resolution.",
								min = -screenW, max = screenW, step = 1,
								arg = "buffReminders.anchor.x",
								order = 1,
							},
							yOffset = {
								type = "range",
								name = "Y Offset",
								desc = "Vertical offset of buff reminder icons relative to the HUD. The range adjusts to your screen resolution.",
								min = -screenH, max = screenH, step = 1,
								arg = "buffReminders.anchor.y",
								order = 2,
							},
						},
					},
					preview = {
						type = "execute",
						name = function()
							local m = addon:GetModule("BuffReminders")
							if m and m:IsPreviewActive() then
								return "Hide Preview"
							end
							return "Show Preview"
						end,
						desc = "Toggle a sample buff reminder icon so you can see your settings in action.",
						func = function()
							local m = addon:GetModule("BuffReminders")
							if not m then return end
							if m:IsPreviewActive() then
								m:HidePreview()
							else
								m:ShowPreview()
							end
						end,
						order = 4,
						disabled = function()
							local db = addon.db and addon.db.profile
							return db and not db.buffReminders.enabled
						end,
						width = 1,
					},
				},
			},
			spellsTab = {
				type = "group",
				name = "Spells",
				order = 2,
				disabled = function()
					local db = addon.db and addon.db.profile
					return db and not db.buffReminders.enabled
				end,
				args = spellsArgs,
			},
		},
	}
end

-- Refresh on profile/spec change — rebuild per-spec spell args
function Options:Refresh()
	self:RebuildAuraSpellArgs()
	self:RebuildBuffReminderSpellArgs()
	self:RebuildReadyGlowSoundOverrideArgs()
end

function Options:BuildReadyGlowSoundOverrideArgs()
	local overrideArgs = {}
	overrideArgs.defaultGroup = {
		type = "group",
		name = "Default",
		inline = true,
		order = 0,
		args = {
			sound = SoundDropdown({
				name = "Default Sound",
				desc = "Sound to play when the ready glow activates on any ability. Per-spell overrides below take priority.",
				arg = "icons.readyGlowSound",
				order = 1,
			}),
		},
	}

	local cooldownIcons = addon:GetModule("CooldownIcons")
	local iconsByRow = cooldownIcons and cooldownIcons.iconsByRow
	local rowConfigs = addon.db and addon.db.profile and addon.db.profile.rows

	if iconsByRow and rowConfigs then
		local ROW_NAMES = { "Primary", "Secondary", "Utility", "Auxiliary" }
		for rowIndex = 1, #rowConfigs do
			local spells = iconsByRow[rowIndex]
			if spells and #spells > 0 then
				local rowArgs = {}
				for spellOrder, entry in ipairs(spells) do
					local sid = entry.spellID
					local spellName, _, spellIcon = GetSpellInfo(sid)
					if spellName then
						local iconStr = spellIcon and ("|T" .. spellIcon .. ":16|t ") or ""
						rowArgs["spell_" .. sid] = SoundDropdown({
							name = iconStr .. spellName,
							get = function()
								local cfg = addon.Database:GetSpellConfigForSpell(sid)
								return cfg.readyGlowSound or "None"
							end,
							set = function(_, value)
								if value == "None" then value = nil end
								addon:SetSpellConfigOverride(sid, "readyGlowSound", value)
							end,
							order = spellOrder,
						})
					end
				end
				overrideArgs["row_" .. rowIndex] = {
					type = "group",
					name = ROW_NAMES[rowIndex] or ("Row " .. rowIndex),
					inline = true,
					order = rowIndex,
					args = rowArgs,
				}
			end
		end
	end

	self._readyGlowSoundArgs = overrideArgs
	return overrideArgs
end

function Options:RebuildReadyGlowSoundOverrideArgs()
	local argsTable = self._readyGlowSoundArgs
	if not argsTable then return end

	local newArgs = self:BuildReadyGlowSoundOverrideArgs()
	wipe(argsTable)
	for k, v in pairs(newArgs) do
		argsTable[k] = v
	end

	local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
	if AceConfigRegistry then
		AceConfigRegistry:NotifyChange("VeevHUD")
	end
end

-- Rebuild the buff reminder spell list in-place (called when showOnlyKnown toggles or spec changes)
function Options:RebuildBuffReminderSpellArgs()
	local argsTable = self._buffReminderSpellArgs
	local buildFn = self._buildBuffReminderSpellArgs
	if not argsTable or not buildFn then return end

	wipe(argsTable)
	local newArgs = buildFn()
	for k, v in pairs(newArgs) do
		argsTable[k] = v
	end

	local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
	if AceConfigRegistry then
		AceConfigRegistry:NotifyChange("VeevHUD")
	end
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
			-- Clean up buff reminder preview when options close
			local brModule = addon:GetModule("BuffReminders")
			if brModule and brModule.IsPreviewActive and brModule:IsPreviewActive() then
				brModule:HidePreview()
			end
		end)
	end

	Options.isConfigOpen = frame:IsShown() or false
end

-------------------------------------------------------------------------------
-- Module Lifecycle
-------------------------------------------------------------------------------

function Options:Initialize()
	-- Don't call Register() here. InitializeModules() uses pairs() which has
	-- non-deterministic order, so other modules (e.g. BuffReminders) may not be
	-- initialized yet. Register() builds the options table and needs module
	-- defaults to be available. Instead, defer to Open() / first use, which is
	-- guaranteed to happen after all modules are initialized.

	-- Register an entry in the native addon options (ESC > Options > AddOns)
	self:RegisterSettingsPanel()
end

function Options:RegisterSettingsPanel()
	if not Settings or not Settings.RegisterCanvasLayoutCategory then return end

	local panel = CreateFrame("Frame")
	panel.name = "VeevHUD |TInterface\\Icons\\Spell_Nature_Reincarnation:16:16|t"

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("VeevHUD")

	local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	desc:SetText("Type |cff00ccff/vh|r to open settings.")

	local openBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	openBtn:SetText("Open VeevHUD Settings")
	openBtn:SetWidth(180)
	openBtn:SetHeight(24)
	openBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
	openBtn:SetScript("OnClick", function()
		-- Close the Blizzard settings window via HideUIPanel (preserves ESC key handling)
		if SettingsPanel and SettingsPanel:IsShown() then
			HideUIPanel(SettingsPanel)
		end
		Options:Open()
	end)

	local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name, panel.name)
	Settings.RegisterAddOnCategory(category)
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
				-- Sync AceConfigDialog's status table so future Open() calls
				-- (triggered by control interactions) don't revert the position.
				local status = widget.status or widget.localstatus
				if status then
					status.top = frame:GetTop()
					status.left = frame:GetLeft()
				end
			end
		end)
	end
end

-------------------------------------------------------------------------------
-- Register as module
-------------------------------------------------------------------------------

addon:RegisterModule("Options", Options)
