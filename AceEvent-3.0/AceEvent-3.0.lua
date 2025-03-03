--- AceEvent-3.0 provides event registration and secure dispatching.
-- All dispatching is done using **CallbackHandler-1.0**. AceEvent is a simple wrapper around
-- CallbackHandler, and dispatches all game events or addon message to the registrees.
--
-- **AceEvent-3.0** can be embeded into your addon, either explicitly by calling AceEvent:Embed(MyAddon) or by
-- specifying it as an embeded library in your AceAddon. All functions will be available on your addon object
-- and can be accessed directly, without having to explicitly call AceEvent itself.\\
-- It is recommended to embed AceEvent, otherwise you'll have to specify a custom `self` on all calls you
-- make into AceEvent.
-- @class file
-- @name AceEvent-3.0
-- @release $Id$
local CallbackHandler = LibStub("CallbackHandler-1.0")

local MAJOR, MINOR = "AceEvent-3.0", 6  -- Bumped minor version for optimizations
local AceEvent = LibStub:NewLibrary(MAJOR, MINOR)

if not AceEvent then return end

-- Lua APIs - Localize frequently used functions for performance
local pairs, type, error = pairs, type, error
local tinsert, tremove, tconcat = table.insert, table.remove, table.concat
local select, unpack = select, unpack
local format, tostring = string.format, tostring
local next, wipe, setmetatable = next, wipe, setmetatable
local rawget, rawset = rawget, rawset

-- WoW APIs
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer

-- Check for precise time function availability
local GetTimePreciseSec = GetTimePreciseSec
local getTimeFunc = GetTimePreciseSec or GetTime

-- Configuration options for performance tuning
AceEvent.config = AceEvent.config or {
	-- Batch processing settings
	batchProcessingEnabled = true,
	batchInterval = 0.001, -- 1ms batch interval for high-end systems
	-- Throttling settings for high-frequency events
	throttleHighFrequencyEvents = true,
	throttleInterval = 0.016, -- ~60fps equivalent
	-- Event queue size pre-allocation
	eventQueueSize = 128, -- Pre-allocate for 128 events in queue
	-- Memory management
	reuseEventTables = true,
	tablePoolSize = 32, -- Number of tables to pre-allocate in the pool
	-- Debug settings
	debugMode = false
}

-- String pool for event names to reduce memory allocations and GC pressure
local stringPool = setmetatable({}, {
	__index = function(t, k)
		rawset(t, k, k)
		return k
	end
})

local function poolString(str)
	return stringPool[str]
end

-- Frame and embeds initialization with pre-allocation
AceEvent.frame = AceEvent.frame or CreateFrame("Frame", "AceEvent30Frame") -- our event frame
AceEvent.embeds = AceEvent.embeds or {} -- what objects embed this lib
AceEvent.eventCache = AceEvent.eventCache or {} -- cache for fast event lookup
AceEvent.messageCache = AceEvent.messageCache or {} -- cache for fast message lookup

-- Event batching system
AceEvent.eventQueue = AceEvent.eventQueue or {}
AceEvent.highFrequencyEvents = AceEvent.highFrequencyEvents or {}
AceEvent.lastEventTime = AceEvent.lastEventTime or {}
AceEvent.eventTablePool = AceEvent.eventTablePool or {}
AceEvent.eventTablePoolSize = 0

-- Pre-allocate event queue to reduce resizing
for i = 1, AceEvent.config.eventQueueSize do
	AceEvent.eventQueue[i] = AceEvent.eventQueue[i] or {}
end

-- Pre-allocate event table pool
for i = 1, AceEvent.config.tablePoolSize do
	AceEvent.eventTablePool[i] = {}
	AceEvent.eventTablePoolSize = AceEvent.eventTablePoolSize + 1
end

-- Get a table from the pool or create a new one
local function getPooledTable()
	if AceEvent.eventTablePoolSize > 0 then
		local tbl = AceEvent.eventTablePool[AceEvent.eventTablePoolSize]
		AceEvent.eventTablePool[AceEvent.eventTablePoolSize] = nil
		AceEvent.eventTablePoolSize = AceEvent.eventTablePoolSize - 1
		return tbl
	else
		return {}
	end
end

-- Return a table to the pool
local function releaseTable(tbl)
	if not tbl then return end

	wipe(tbl)
	if AceEvent.config.reuseEventTables then
		AceEvent.eventTablePoolSize = AceEvent.eventTablePoolSize + 1
		AceEvent.eventTablePool[AceEvent.eventTablePoolSize] = tbl
	end
end

-- Batch processing function
local function processBatchedEvents()
	if not next(AceEvent.eventQueue) then return end

	local currentTime = getTimeFunc()
	local events = AceEvent.events
	local fireEvent = events.Fire

	for i = 1, #AceEvent.eventQueue do
		local eventData = AceEvent.eventQueue[i]
		if eventData.event then
			-- Check if this is a high-frequency event that needs throttling
			local shouldProcess = true
			if AceEvent.config.throttleHighFrequencyEvents and AceEvent.highFrequencyEvents[eventData.event] then
				local lastTime = AceEvent.lastEventTime[eventData.event] or 0
				if (currentTime - lastTime) < AceEvent.config.throttleInterval then
					shouldProcess = false
				else
					AceEvent.lastEventTime[eventData.event] = currentTime
				end
			end

			if shouldProcess then
				-- Use pcall for error handling to prevent event processing from breaking
				local success, err = pcall(function()
					if eventData.args then
						fireEvent(events, eventData.event, unpack(eventData.args, 1, eventData.argCount))
					else
						fireEvent(events, eventData.event)
					end
				end)

				if not success and AceEvent.config.debugMode then
					-- Only log errors in debug mode
					error(format("AceEvent-3.0: Error processing event '%s': %s",
						tostring(eventData.event), tostring(err)))
				end
			end

			-- Clear the event data for reuse
			local args = eventData.args
			eventData.event = nil
			eventData.args = nil
			eventData.argCount = nil

			-- Return the args table to the pool
			if args then
				releaseTable(args)
			end
		end
	end
end

-- APIs and registry for blizzard events, using CallbackHandler lib
if not AceEvent.events then
	AceEvent.events = CallbackHandler:New(AceEvent,
		"RegisterEvent", "UnregisterEvent", "UnregisterAllEvents")
end

-- Optimized OnUsed handler with event name pooling
function AceEvent.events:OnUsed(target, eventname)
	-- Pool the event name to reduce string allocations
	eventname = poolString(eventname)
	-- Cache the event registration for faster lookups
	AceEvent.eventCache[eventname] = true
	AceEvent.frame:RegisterEvent(eventname)
end

-- Optimized OnUnused handler with cache management
function AceEvent.events:OnUnused(target, eventname)
	AceEvent.eventCache[eventname] = nil
	AceEvent.frame:UnregisterEvent(eventname)
end

-- APIs and registry for IPC messages, using CallbackHandler lib
if not AceEvent.messages then
	AceEvent.messages = CallbackHandler:New(AceEvent,
		"RegisterMessage", "UnregisterMessage", "UnregisterAllMessages"
	)
	AceEvent.SendMessage = AceEvent.messages.Fire
end

-- Optimized SendMessage with string pooling
local originalSendMessage = AceEvent.SendMessage
AceEvent.SendMessage = function(self, message, ...)
	message = poolString(message)
	return originalSendMessage(self, message, ...)
end

-- Configuration API for tuning performance settings
function AceEvent:SetConfig(key, value)
	if self.config[key] ~= nil then
		self.config[key] = value
		return true
	end
	return false
end

function AceEvent:GetConfig(key)
	return self.config[key]
end

-- Mark an event as high-frequency for throttling
function AceEvent:MarkHighFrequencyEvent(eventName, isHighFrequency)
	if isHighFrequency then
		self.highFrequencyEvents[poolString(eventName)] = true
	else
		self.highFrequencyEvents[eventName] = nil
	end
end

-- Optimized event registration with handler caching
local originalRegisterEvent = AceEvent.RegisterEvent
if originalRegisterEvent then
	AceEvent.RegisterEvent = function(self, event, callback, arg)
		event = poolString(event)
		return originalRegisterEvent(self, event, callback, arg)
	end
end

local originalRegisterMessage = AceEvent.RegisterMessage
if originalRegisterMessage then
	AceEvent.RegisterMessage = function(self, message, callback, arg)
		message = poolString(message)
		return originalRegisterMessage(self, message, callback, arg)
	end
end

-- Optimized unregister functions
local originalUnregisterEvent = AceEvent.UnregisterEvent
if originalUnregisterEvent then
	AceEvent.UnregisterEvent = function(self, event)
		event = poolString(event)
		return originalUnregisterEvent(self, event)
	end
end

local originalUnregisterMessage = AceEvent.UnregisterMessage
if originalUnregisterMessage then
	AceEvent.UnregisterMessage = function(self, message)
		message = poolString(message)
		return originalUnregisterMessage(self, message)
	end
end

--- embedding and embed handling
local mixins = {
	"RegisterEvent", "UnregisterEvent",
	"RegisterMessage", "UnregisterMessage",
	"SendMessage",
	"UnregisterAllEvents", "UnregisterAllMessages",
	"SetConfig", "GetConfig", "MarkHighFrequencyEvent"
}

--- Register for a Blizzard Event.
-- The callback will be called with the optional `arg` as the first argument (if supplied), and the event name as the second (or first, if no arg was supplied)
-- Any arguments to the event will be passed on after that.
-- @name AceEvent:RegisterEvent
-- @class function
-- @paramsig event[, callback [, arg]]
-- @param event The event to register for
-- @param callback The callback function to call when the event is triggered (funcref or method, defaults to a method with the event name)
-- @param arg An optional argument to pass to the callback function

--- Unregister an event.
-- @name AceEvent:UnregisterEvent
-- @class function
-- @paramsig event
-- @param event The event to unregister

--- Register for a custom AceEvent-internal message.
-- The callback will be called with the optional `arg` as the first argument (if supplied), and the event name as the second (or first, if no arg was supplied)
-- Any arguments to the event will be passed on after that.
-- @name AceEvent:RegisterMessage
-- @class function
-- @paramsig message[, callback [, arg]]
-- @param message The message to register for
-- @param callback The callback function to call when the message is triggered (funcref or method, defaults to a method with the event name)
-- @param arg An optional argument to pass to the callback function

--- Unregister a message
-- @name AceEvent:UnregisterMessage
-- @class function
-- @paramsig message
-- @param message The message to unregister

--- Send a message over the AceEvent-3.0 internal message system to other addons registered for this message.
-- @name AceEvent:SendMessage
-- @class function
-- @paramsig message, ...
-- @param message The message to send
-- @param ... Any arguments to the message

--- Set a configuration option for AceEvent-3.0 performance tuning.
-- @name AceEvent:SetConfig
-- @class function
-- @paramsig key, value
-- @param key The configuration key to set
-- @param value The value to set for the configuration key

--- Get a configuration option for AceEvent-3.0.
-- @name AceEvent:GetConfig
-- @class function
-- @paramsig key
-- @param key The configuration key to get
-- @return The current value of the configuration key

--- Mark an event as high-frequency for throttling.
-- High-frequency events will be throttled based on the throttleInterval configuration.
-- @name AceEvent:MarkHighFrequencyEvent
-- @class function
-- @paramsig eventName, isHighFrequency
-- @param eventName The name of the event to mark
-- @param isHighFrequency Whether the event should be considered high-frequency (true) or not (false)

-- Cache for direct function references to avoid repeated table lookups
local functionCache = {}

-- Optimized Embed function with function caching
function AceEvent:Embed(target)
	for k, v in pairs(mixins) do
		if not functionCache[v] then
			functionCache[v] = self[v]
		end
		target[v] = functionCache[v]
	end
	self.embeds[target] = true
	return target
end

-- AceEvent:OnEmbedDisable( target )
-- target (object) - target object that is being disabled
--
-- Unregister all events messages etc when the target disables.
-- this method should be called by the target manually or by an addon framework
function AceEvent:OnEmbedDisable(target)
	target:UnregisterAllEvents()
	target:UnregisterAllMessages()
end

-- Optimized event handler with batch processing
local events = AceEvent.events
local fireEvent = events.Fire
local queueIndex = 1

-- Setup batch processing timer if available
local batchTimer
if C_Timer and C_Timer.NewTicker and AceEvent.config.batchProcessingEnabled then
	batchTimer = C_Timer.NewTicker(AceEvent.config.batchInterval, processBatchedEvents)
end

AceEvent.frame:SetScript("OnEvent", function(this, event, ...)
	-- Pool the event name
	event = poolString(event)

	if AceEvent.config.batchProcessingEnabled and batchTimer then
		-- Add to batch queue
		local eventData = AceEvent.eventQueue[queueIndex]
		if not eventData then
			eventData = {}
			AceEvent.eventQueue[queueIndex] = eventData
		end

		eventData.event = event
		local argCount = select("#", ...)
		if argCount > 0 then
			eventData.args = getPooledTable()
			for i = 1, argCount do
				eventData.args[i] = select(i, ...)
			end
			eventData.argCount = argCount
		end

		queueIndex = queueIndex + 1
		if queueIndex > AceEvent.config.eventQueueSize then
			queueIndex = 1
		end
	else
		-- Direct processing if batching is disabled
		fireEvent(events, event, ...)
	end
end)

-- Initialize batch processing if C_Timer is not available
if not batchTimer and AceEvent.config.batchProcessingEnabled then
	AceEvent.frame:SetScript("OnUpdate", function(self, elapsed)
		processBatchedEvents()
	end)
end

--- Finally: upgrade our old embeds
for target, v in pairs(AceEvent.embeds) do
	AceEvent:Embed(target)
end
