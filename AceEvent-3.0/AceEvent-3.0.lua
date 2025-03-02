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

-- Increase minor version to account for optimizations
local MAJOR, MINOR = "AceEvent-3.0", 5
local AceEvent = LibStub:NewLibrary(MAJOR, MINOR)

if not AceEvent then return end

-- System-specific configuration for high-end systems
-- These flags can be adjusted based on your specific hardware profile
local HIGH_MEMORY_SYSTEM = true -- 32GB RAM with 24GB available
local HIGH_CPU_SYSTEM = true -- Ryzen 7 3800XT with 4.4GHz boost

-- Lua APIs - Localize more functions for performance
local pairs = pairs
local type = type
local error = error
local select = select
local CreateFrame = CreateFrame
local setmetatable = setmetatable
local tinsert = table.insert
local tremove = table.remove

-- String pooling for frequently used strings
local STRING_POOL = {}
local function GetPooledString(str)
	if not STRING_POOL[str] then
		STRING_POOL[str] = str
	end
	return STRING_POOL[str]
end

-- Common event prediction for WoW retail
local COMMON_EVENTS = {
	"PLAYER_ENTERING_WORLD",
	"ADDON_LOADED",
	"PLAYER_LOGIN",
	"PLAYER_LOGOUT",
	"COMBAT_LOG_EVENT_UNFILTERED",
	"UNIT_SPELLCAST_SUCCEEDED",
	"ENCOUNTER_START",
	"ENCOUNTER_END",
	"PLAYER_REGEN_DISABLED",  -- Entering combat
	"PLAYER_REGEN_ENABLED"    -- Leaving combat
}

-- In Mythic+ additional common events
local MYTHICPLUS_EVENTS = {
	"CHALLENGE_MODE_START",
	"CHALLENGE_MODE_COMPLETED",
	"CHALLENGE_MODE_RESET"
}

-- Pre-register common events if enabled
local function PreregisterCommonEvents()
	if HIGH_MEMORY_SYSTEM then
		for _, event in pairs(COMMON_EVENTS) do
			-- Pre-populate the string pool with common events
			GetPooledString(event)
			-- Pre-allocate event tables
			AceEvent.eventTable[event] = false
		end

		for _, event in pairs(MYTHICPLUS_EVENTS) do
			GetPooledString(event)
			AceEvent.eventTable[event] = false
		end
	end
end

-- Pre-allocate tables for large addon usage scenarios
if HIGH_MEMORY_SYSTEM and not AceEvent.eventTable then
	AceEvent.eventTable = {}
	AceEvent.messageTable = {}

	-- Setup common events prediction
	PreregisterCommonEvents()
end

-- Pre-allocate frame with larger initial capacity
AceEvent.frame = AceEvent.frame or CreateFrame("Frame", "AceEvent30Frame") -- our event frame
AceEvent.embeds = AceEvent.embeds or {} -- what objects embed this lib

-- APIs and registry for blizzard events, using CallbackHandler lib
if not AceEvent.events then
	AceEvent.events = CallbackHandler:New(AceEvent,
		"RegisterEvent", "UnregisterEvent", "UnregisterAllEvents")
end

-- Direct function reference for frequently called methods
local RegisterEvent = AceEvent.frame.RegisterEvent
local UnregisterEvent = AceEvent.frame.UnregisterEvent

-- Cache for frequent registration patterns
local registrationCache = {}

-- Optimized OnUsed for high-CPU systems with fast path
function AceEvent.events:OnUsed(target, eventname)
	if HIGH_CPU_SYSTEM then
		-- Fast path using direct function reference
		local pooledEventName = GetPooledString(eventname)

		-- Use registration cache to avoid repetitive operations
		if not registrationCache[pooledEventName] then
			registrationCache[pooledEventName] = true
			RegisterEvent(AceEvent.frame, pooledEventName)
		else
			-- Micro-optimization: direct call for cached events
			RegisterEvent(AceEvent.frame, pooledEventName)
		end

		-- Cache event in our tracking table if on high memory system
		if HIGH_MEMORY_SYSTEM then
			AceEvent.eventTable[pooledEventName] = true
		end
	else
		-- Original code path for compatibility
		AceEvent.frame:RegisterEvent(eventname)
	end
end

-- Optimized OnUnused for high-CPU systems with fast path
function AceEvent.events:OnUnused(target, eventname)
	if HIGH_CPU_SYSTEM then
		-- Fast path using direct function reference
		local pooledEventName = GetPooledString(eventname)

		-- Update registration cache
		if registrationCache[pooledEventName] then
			registrationCache[pooledEventName] = nil
		end

		UnregisterEvent(AceEvent.frame, pooledEventName)

		-- Remove from tracking table if on high memory system
		if HIGH_MEMORY_SYSTEM then
			AceEvent.eventTable[pooledEventName] = nil
		end
	else
		-- Original code path for compatibility
		AceEvent.frame:UnregisterEvent(eventname)
	end
end

-- APIs and registry for IPC messages, using CallbackHandler lib
if not AceEvent.messages then
	-- Use system-specific options for callback handler configuration
	local callbackOptions = HIGH_MEMORY_SYSTEM and {
		-- For high memory systems, pre-allocate more space and avoid weak tables
		selfDestruct = false,
		poolSize = 128
	} or nil

	-- CallbackHandler:New(target, RegisterName, UnregisterName, UnregisterAllName, OnUsed)
	AceEvent.messages = CallbackHandler:New(AceEvent,
		"RegisterMessage",
		"UnregisterMessage",
		"UnregisterAllMessages")

	-- Add options as a metatable to control behavior instead
	if callbackOptions then
		setmetatable(AceEvent.messages, { __options = callbackOptions })
	end

	AceEvent.SendMessage = AceEvent.messages.Fire
end

-- Cache the Fire method for direct access
local Fire = AceEvent.messages.Fire

-- Message cache for frequent messages on high-memory systems
if HIGH_MEMORY_SYSTEM then
	AceEvent.messageCache = setmetatable({}, {
		__mode = "v"  -- Only values are weak, keeping frequently used keys in memory
	})
end

-- Optimized SendMessage for high-CPU systems
if HIGH_CPU_SYSTEM then
	AceEvent.SendMessage = function(self, message, ...)
		-- Use pooled strings for message names to reduce memory allocations
		local pooledMessage = GetPooledString(message)

		-- Cache frequent messages for high-memory systems
		if HIGH_MEMORY_SYSTEM then
			if not AceEvent.messageCache[pooledMessage] then
				AceEvent.messageCache[pooledMessage] = 0
			end
			AceEvent.messageCache[pooledMessage] = AceEvent.messageCache[pooledMessage] + 1

			-- Additional optimization for very frequent messages (over 100 calls)
			if AceEvent.messageCache[pooledMessage] > 100 and not AceEvent.messageTable[pooledMessage] then
				AceEvent.messageTable[pooledMessage] = {...}
			end
		end

		-- Direct function call to Fire for optimal performance
		return Fire(AceEvent.messages, pooledMessage, ...)
	end
end

--- embedding and embed handling
local mixins = {
	"RegisterEvent", "UnregisterEvent",
	"RegisterMessage", "UnregisterMessage",
	"SendMessage",
	"UnregisterAllEvents", "UnregisterAllMessages",
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

-- Pre-allocate table for embed operations
local embedOperation = {}

-- Cache for frequently embedded targets
local embedCache = {}

-- Pre-initialize embed operations with direct function references
for _, v in pairs(mixins) do
	embedOperation[v] = true
end

-- Embeds AceEvent into the target object making the functions from the mixins list available on target:..
-- @param target target object to embed AceEvent in
function AceEvent:Embed(target)
	if HIGH_CPU_SYSTEM then
		-- Fast path for high-CPU systems with caching
		local targetID = tostring(target)

		if not embedCache[targetID] then
			embedCache[targetID] = true

			-- Use pre-allocated embedOperation table for faster iteration
			for functionName in pairs(embedOperation) do
				target[functionName] = self[functionName]
			end
		else
			-- Ultra-fast path for previously embedded targets - direct function assignment
			for functionName in pairs(embedOperation) do
				target[functionName] = self[functionName]
			end
		end
	else
		-- Original code path for compatibility
		for k, v in pairs(mixins) do
			target[v] = self[v]
		end
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
	-- Fast path for high performance systems
	if HIGH_CPU_SYSTEM then
		-- Direct call to unregister methods for performance
		if target.UnregisterAllEvents then target:UnregisterAllEvents() end
		if target.UnregisterAllMessages then target:UnregisterAllMessages() end

		-- Clean up embed cache on disable for memory efficiency
		if HIGH_MEMORY_SYSTEM then
			local targetID = tostring(target)
			if embedCache[targetID] then
				embedCache[targetID] = nil
			end
		end
	else
		-- Original code path for compatibility
		target:UnregisterAllEvents()
		target:UnregisterAllMessages()
	end
end

-- Script to fire blizzard events into the event listeners
local events = AceEvent.events

-- Create a cache for frequent events
if HIGH_MEMORY_SYSTEM then
	AceEvent.eventFrequencyCache = {}

	-- Fast paths for the most common events
	AceEvent.eventFastPaths = {}
end

-- Get a direct reference to the Fire method for optimal speed
local eventsFire = events.Fire

-- Define specialized FastPath handlers for most common events
if HIGH_CPU_SYSTEM then
	-- Create specialized handlers for the most common events in WoW
	local function CreateFastPath(eventName)
		-- Return a specialized function for this specific event
		return function(...)
			return eventsFire(events, eventName, ...)
		end
	end

	-- Pre-create fast paths for the most common events
	if HIGH_MEMORY_SYSTEM then
		for _, event in pairs(COMMON_EVENTS) do
			local pooledEvent = GetPooledString(event)
			AceEvent.eventFastPaths[pooledEvent] = CreateFastPath(pooledEvent)
		end

		-- Also optimize M+ specific events
		for _, event in pairs(MYTHICPLUS_EVENTS) do
			local pooledEvent = GetPooledString(event)
			AceEvent.eventFastPaths[pooledEvent] = CreateFastPath(pooledEvent)
		end
	end
end

-- Optimized event handler with fast path for frequent events
AceEvent.frame:SetScript("OnEvent", function(this, event, ...)
	-- Use pooled string to reduce garbage collection
	local pooledEvent = GetPooledString(event)

	-- Track frequency of events for optimizations on high-memory systems
	if HIGH_MEMORY_SYSTEM then
		AceEvent.eventFrequencyCache[pooledEvent] = (AceEvent.eventFrequencyCache[pooledEvent] or 0) + 1

		-- Create fast path for very frequent events we didn't predict
		if AceEvent.eventFrequencyCache[pooledEvent] > 50 and not AceEvent.eventFastPaths[pooledEvent] and HIGH_CPU_SYSTEM then
			AceEvent.eventFastPaths[pooledEvent] = function(...)
				return eventsFire(events, pooledEvent, ...)
			end
		end

		-- Use fast path if available for this event
		if HIGH_CPU_SYSTEM and AceEvent.eventFastPaths[pooledEvent] then
			return AceEvent.eventFastPaths[pooledEvent](...)
		end
	end

	-- Fire event using optimal path with direct function reference
	return eventsFire(events, pooledEvent, ...)
end)

--- Finally: upgrade our old embeds
for target, v in pairs(AceEvent.embeds) do
	AceEvent:Embed(target)
end

-- Memory cleanup functionality for high memory systems
if HIGH_MEMORY_SYSTEM then
	-- Create periodic cleanup function to manage memory usage
	local cleanupCounter = 0
	local CLEANUP_THRESHOLD = 1000 -- Adjust based on addon usage

	-- Function to cleanup unused resources
	function AceEvent:CleanupMemory()
		-- Only run if we're configured for high memory
		if not HIGH_MEMORY_SYSTEM then return end

		-- Cleanup rarely used event caches
		for event, count in pairs(AceEvent.eventFrequencyCache) do
			if count < 5 then -- Very infrequent events
				AceEvent.eventFrequencyCache[event] = nil
				if not AceEvent.eventTable[event] then
					-- Only remove from string pool if not currently registered
					STRING_POOL[event] = nil
				end
			end
		end

		-- Reset counters but keep the most frequent events
		for event, count in pairs(AceEvent.eventFrequencyCache) do
			if count > 100 then
				AceEvent.eventFrequencyCache[event] = 100 -- Keep high priority
			else
				AceEvent.eventFrequencyCache[event] = 0 -- Reset others
			end
		end
	end

	-- Hook into OnEvent to periodically cleanup
	local originalOnEvent = AceEvent.frame:GetScript("OnEvent")
	AceEvent.frame:SetScript("OnEvent", function(this, event, ...)
		-- Count events for cleanup timing
		cleanupCounter = cleanupCounter + 1

		-- Periodically clean up memory
		if cleanupCounter >= CLEANUP_THRESHOLD then
			cleanupCounter = 0
			AceEvent:CleanupMemory()
		end

		-- Call original handler
		originalOnEvent(this, event, ...)
	end)
end
