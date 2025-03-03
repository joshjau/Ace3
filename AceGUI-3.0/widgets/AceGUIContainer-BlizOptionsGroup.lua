--[[-----------------------------------------------------------------------------
BlizOptionsGroup Container
Simple container widget for the integration of AceGUI into the Blizzard Interface Options
-------------------------------------------------------------------------------]]
local Type, Version = "BlizOptionsGroup", 27
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(Type) or 0) >= Version then return end

-- Lua APIs
local pairs, type, rawset = pairs, type, rawset
local min, max = math.min, math.max

-- WoW APIs
local CreateFrame, UIParent = CreateFrame, UIParent
local Settings = Settings

-- Cache frequently accessed globals
local _G = _G

-- Pre-allocate layout cache tables
local layoutCache = {}

--[[-----------------------------------------------------------------------------
Scripts
-------------------------------------------------------------------------------]]

local function OnShow(frame)
	frame.obj:Fire("OnShow")
end

local function OnHide(frame)
	frame.obj:Fire("OnHide")
end

--[[-----------------------------------------------------------------------------
Support functions
-------------------------------------------------------------------------------]]

local function okay(frame)
	frame.obj:Fire("okay")
end

local function cancel(frame)
	frame.obj:Fire("cancel")
end

local function default(frame)
	frame.obj:Fire("default")
end

local function refresh(frame)
	frame.obj:Fire("refresh")
end

-- Optimized layout calculation with caching
local function calculateContentWidth(width)
	local contentwidth = width - 63
	return max(contentwidth, 0)
end

local function calculateContentHeight(height)
	local contentheight = height - 26
	return max(contentheight, 0)
end

--[[-----------------------------------------------------------------------------
Methods
-------------------------------------------------------------------------------]]

local methods = {
	["OnAcquire"] = function(self)
		self:SetName()

		-- Reset layout cache for this instance
		layoutCache[self] = layoutCache[self] or {}

		self:SetTitle()
	end,

	["OnRelease"] = function(self)
		-- Clear layout cache when released
		layoutCache[self] = nil
	end,

	["OnWidthSet"] = function(self, width)
		local content = self.content
		local cache = layoutCache[self]

		-- Use cached value if width hasn't changed
		if cache.lastWidth ~= width then
			cache.lastWidth = width
			cache.contentWidth = calculateContentWidth(width)
			content:SetWidth(cache.contentWidth)
			content.width = cache.contentWidth
		end
	end,

	["OnHeightSet"] = function(self, height)
		local content = self.content
		local cache = layoutCache[self]

		-- Use cached value if height hasn't changed
		if cache.lastHeight ~= height then
			cache.lastHeight = height
			cache.contentHeight = calculateContentHeight(height)
			content:SetHeight(cache.contentHeight)
			content.height = cache.contentHeight
		end
	end,

	["SetName"] = function(self, name, parent)
		self.frame.name = name
		self.frame.parent = parent
	end,

	["SetTitle"] = function(self, title)
		local content = self.content
		local cache = layoutCache[self]

		-- Only update layout if title has changed
		if cache.lastTitle ~= title then
			cache.lastTitle = title

			content:ClearAllPoints()
			if not title or title == "" then
				content:SetPoint("TOPLEFT", 10, -10)
				self.label:SetText("")
			else
				content:SetPoint("TOPLEFT", 10, -40)
				self.label:SetText(title)
			end
			content:SetPoint("BOTTOMRIGHT", -10, 10)
		end
	end
}

--[[-----------------------------------------------------------------------------
Constructor
-------------------------------------------------------------------------------]]
local function Constructor()
	local frame
	-- Use Settings.CreateInterfaceOptionsPanelFrame for WoW 10.0+ or fall back to the old method
	if Settings and Settings.CreateInterfaceOptionsPanelFrame then
		frame = Settings.CreateInterfaceOptionsPanelFrame("")
	else
		-- For older WoW versions, use UIParent as fallback since InterfaceOptionsFramePanelContainer may not exist
		local parent = UIParent
		if _G["InterfaceOptionsFramePanelContainer"] ~= nil then
			parent = _G["InterfaceOptionsFramePanelContainer"]
		end
		frame = CreateFrame("Frame", nil, parent)
	end
	frame:Hide()

	-- support functions for the Blizzard Interface Options
	frame.okay = okay
	frame.cancel = cancel
	frame.default = default
	frame.refresh = refresh

	-- 10.0 support function aliases (cancel has been removed)
	frame.OnCommit = okay
	frame.OnDefault = default
	frame.OnRefresh = refresh

	frame:SetScript("OnHide", OnHide)
	frame:SetScript("OnShow", OnShow)

	local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	label:SetPoint("TOPLEFT", 10, -15)
	label:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 10, -45)
	label:SetJustifyH("LEFT")
	label:SetJustifyV("TOP")

	--Container Support
	local content = CreateFrame("Frame", nil, frame)
	content:SetPoint("TOPLEFT", 10, -10)
	content:SetPoint("BOTTOMRIGHT", -10, 10)

	local widget = {
		label   = label,
		frame   = frame,
		content = content,
		type    = Type,
		-- Add required fields
		userdata = {},
		events = {},
		-- Explicitly define methods
		OnAcquire = methods.OnAcquire,
		OnRelease = methods.OnRelease,
		OnWidthSet = methods.OnWidthSet,
		OnHeightSet = methods.OnHeightSet,
		SetName = methods.SetName,
		SetTitle = methods.SetTitle
	}

	return AceGUI:RegisterAsContainer(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
