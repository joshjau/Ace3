--[[-----------------------------------------------------------------------------
InteractiveLabel Widget
Displays text that responds to mouse events.
-------------------------------------------------------------------------------]]
local Type, Version = "InteractiveLabel", 22 -- Bumped version number
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(Type) or 0) >= Version then return end

-- Lua APIs - Localize frequently used functions for performance
local select, pairs, type, rawset = select, pairs, type, rawset
local min, max = math.min, math.max

-- WoW APIs - Localize frequently used functions
local CreateFrame, UIParent = CreateFrame, UIParent
local GetCursorPosition = GetCursorPosition

-- Local cache for frequently accessed data
local textureCache = {}
local stringCache = setmetatable({}, {
	__index = function(t, k)
		if type(k) == "string" then
			rawset(t, k, k)
		end
		return k
	end
})

-- Preallocate event response cache to reduce GC pressure
local eventCache = {
	OnEnter = {},
	OnLeave = {},
	OnClick = {}
}

--[[-----------------------------------------------------------------------------
Scripts - Optimized for minimal overhead
-------------------------------------------------------------------------------]]
local function Control_OnEnter(frame)
	-- Simplified event handling with cached data
	local obj = frame.obj
	if obj and obj.Fire then
		obj:Fire("OnEnter", eventCache.OnEnter)
	end
end

local function Control_OnLeave(frame)
	local obj = frame.obj
	if obj and obj.Fire then
		obj:Fire("OnLeave", eventCache.OnLeave)
	end
end

local function Label_OnClick(frame, button)
	local obj = frame.obj
	if obj and obj.Fire then
		-- Cache click data to avoid allocations during repetitive clicks
		eventCache.OnClick.button = button
		eventCache.OnClick.cursorX, eventCache.OnClick.cursorY = GetCursorPosition()
		obj:Fire("OnClick", button, eventCache.OnClick)
		AceGUI:ClearFocus()
	end
end

--[[-----------------------------------------------------------------------------
Methods - Optimized for performance
-------------------------------------------------------------------------------]]
local methods = {
	["OnAcquire"] = function(self)
		self:LabelOnAcquire()
		self:SetHighlight()
		self:SetHighlightTexCoord()
		self:SetDisabled(false)
		-- Preload interactive state
		self._isHovered = false
		self._lastTextWidth = 0
	end,

	-- ["OnRelease"] = nil,

	["SetHighlight"] = function(self, ...)
		local tex = ...
		-- Check texture cache to avoid redundant SetTexture calls
		if tex and textureCache[tex] == self.lastHighlightTex then
			return
		end

		self.highlight:SetTexture(...)
		self.lastHighlightTex = tex
		if tex then
			textureCache[tex] = tex
		end
	end,

	["SetHighlightTexCoord"] = function(self, ...)
		local c = select("#", ...)
		if c == 4 or c == 8 then
			self.highlight:SetTexCoord(...)
		else
			self.highlight:SetTexCoord(0, 1, 0, 1)
		end
	end,

	["SetDisabled"] = function(self, disabled)
		if self.disabled == disabled then return end -- Skip redundant updates

		self.disabled = disabled
		if disabled then
			self.frame:EnableMouse(false)
			self.label:SetTextColor(0.5, 0.5, 0.5)
		else
			self.frame:EnableMouse(true)
			self.label:SetTextColor(1, 1, 1)
		end
	end
}

--[[-----------------------------------------------------------------------------
Constructor - Optimized for efficient object creation
-------------------------------------------------------------------------------]]
local function Constructor()
	-- Create a Label type that we will hijack
	local label = AceGUI:Create("Label")
	---@class InteractiveLabelWidget: AceGUIWidget
	---@field OnAcquire function
	---@field LabelOnAcquire function
	---@field SetText function
	---@field label table
	---@field highlight table
	---@field frame table
	---@field disabled boolean
	---@field lastHighlightTex string|nil
	---@field type string
	label = label

	-- Get the frame from the label widget
	local frame = label.frame
	frame:EnableMouse(true)

	-- Use faster script assignment
	frame:HookScript("OnEnter", Control_OnEnter)
	frame:HookScript("OnLeave", Control_OnLeave)
	frame:HookScript("OnMouseDown", Label_OnClick)

	-- Create highlight texture with optimized settings
	local highlight = frame:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetTexture(nil)
	highlight:SetAllPoints()
	highlight:SetBlendMode("ADD")

	-- Store objects in the widget
	label.highlight = highlight
	label.type = Type
	label.LabelOnAcquire = label.OnAcquire
	label.lastHighlightTex = nil

	-- Apply methods with optimized bulk assignment
	for method, func in pairs(methods) do
		label[method] = func
	end

	-- Add optimized SetText method directly
	local originalSetText = label.SetText
	label.SetText = function(self, text)
		-- Use cached strings when possible to reduce memory fragmentation
		if text and self.label:GetText() == text then
			return -- Skip if text hasn't changed
		end

		if type(text) == "string" then
			text = stringCache[text]
		end

		-- Call the original method
		originalSetText(self, text)
	end

	return label
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)

