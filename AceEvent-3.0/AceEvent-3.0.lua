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

local MAJOR, MINOR = "AceEvent-3.0", 6  -- Increased minor version for further optimization
local AceEvent = LibStub:NewLibrary(MAJOR, MINOR)

if not AceEvent then return end

-- Lua APIs - cache frequently used functions to local variables for performance
local pairs, type, next, select = pairs, type, next, select
local tostring, error = tostring, error
local tinsert, tremove, tconcat = table.insert, table.remove, table.concat
local format = string.format
local mmin, mmax, mfloor = math.min, math.max, math.floor
local strfind = string.find
-- In WoW Lua 5.1, unpack is a global function, not in table namespace
local unpack = unpack

-- Cache WoW API functions for better performance
local GetTime = GetTime
local C_TimerAfter = C_Timer and C_Timer.After or function() error("C_Timer.After not available") end
local CreateFrame = CreateFrame
local tostringall = tostringall
local debugprofilestop = debugprofilestop
local collectgarbage = collectgarbage

-- Create or reuse the event frame
AceEvent.frame = AceEvent.frame or CreateFrame("Frame", "AceEvent30Frame")
AceEvent.embeds = AceEvent.embeds or {} -- what objects embed this lib

-- Further optimization: Add version detection for better compatibility
AceEvent.isRetail = (WOW_PROJECT_ID == 1) or false
AceEvent.isClassic = (WOW_PROJECT_ID == 2) or false
AceEvent.isWrath = (WOW_PROJECT_ID == 3) or false
AceEvent.isCata = (WOW_PROJECT_ID == 5) or false
AceEvent.isDragon = select(4, GetBuildInfo()) >= 100000 or false
AceEvent.isTWW = select(4, GetBuildInfo()) >= 110000 or false

-- Optimization: Event frequency tracking
AceEvent.eventFrequency = AceEvent.eventFrequency or {}
AceEvent.highFrequencyThreshold = 60 -- Events firing more than X times per minute are considered high frequency
AceEvent.combatEventCount = AceEvent.combatEventCount or {}
AceEvent.lastEventTime = AceEvent.lastEventTime or {}
AceEvent.eventRegistrationCount = AceEvent.eventRegistrationCount or {}
AceEvent.eventTiming = AceEvent.eventTiming or {} -- Track how long event handlers take
AceEvent.eventMemoryUsage = AceEvent.eventMemoryUsage or {} -- Track memory allocation during event handling

-- Optimization: Cache for optimization routines
AceEvent.eventCache = AceEvent.eventCache or {}
AceEvent.messageBatch = AceEvent.messageBatch or {}
AceEvent.batchMessageThreshold = 5 -- Number of identical messages within 0.1s to batch
AceEvent.batchMessageTimer = 0.1 -- Time window for batching in seconds
AceEvent.lastMessageTime = AceEvent.lastMessageTime or {}
AceEvent.inCombat = AceEvent.inCombat or false
AceEvent.pendingTimers = AceEvent.pendingTimers or {} -- Track timers so they can be canceled if needed
AceEvent.timerPool = AceEvent.timerPool or {} -- Timer object pool for recycling

-- Optimized timer functions using a pool system
local function AcquireTimer()
    local timer = tremove(AceEvent.timerPool) or {}
    return timer
end

local function ReleaseTimer(timer)
    if not timer then return end
    timer.callback = nil
    timer.args = nil
    timer.delay = nil
    timer.id = nil
    tinsert(AceEvent.timerPool, timer)
end

-- Performance monitoring
AceEvent.enablePerformanceTracking = AceEvent.enablePerformanceTracking ~= nil and AceEvent.enablePerformanceTracking or false
AceEvent.performanceThreshold = 5 -- milliseconds
AceEvent.slowEventThreshold = 15 -- milliseconds
AceEvent.eventHandlerTimes = AceEvent.eventHandlerTimes or {}

-- APIs and registry for blizzard events, using CallbackHandler lib
if not AceEvent.events then
	AceEvent.events = CallbackHandler:New(AceEvent,
		"RegisterEvent", "UnregisterEvent", "UnregisterAllEvents")
end

-- Event frequency tracking with optimization for high frequency events
local function TrackEventFrequency(event)
	if not event then return end
	local time = GetTime()
	local lastTime = AceEvent.lastEventTime[event]

	if lastTime then
		local freq = AceEvent.eventFrequency[event] or 0
		-- Exponential moving average to smooth out frequency calculation
		AceEvent.eventFrequency[event] = freq * 0.95 + (0.05 / mmax(0.001, time - lastTime))
	end

	AceEvent.lastEventTime[event] = time

	-- Track combat-specific events
	if AceEvent.inCombat then
		AceEvent.combatEventCount[event] = (AceEvent.combatEventCount[event] or 0) + 1
	end
end

-- Optimized OnUsed handler with frequency tracking and memory optimization
function AceEvent.events:OnUsed(target, eventname)
	if not eventname then return end
	AceEvent.frame:RegisterEvent(eventname)
	AceEvent.eventRegistrationCount[eventname] = (AceEvent.eventRegistrationCount[eventname] or 0) + 1

	-- Initialize tracking for this event
	if not AceEvent.lastEventTime[eventname] then
		AceEvent.lastEventTime[eventname] = GetTime()
		AceEvent.eventFrequency[eventname] = 0
		AceEvent.eventTiming[eventname] = {
            total = 0,
            count = 0,
            max = 0,
            lastCheck = GetTime()
        }
	end
end

-- Optimized OnUnused handler with cleanup
function AceEvent.events:OnUnused(target, eventname)
	if not eventname then return end
	AceEvent.frame:UnregisterEvent(eventname)
	AceEvent.eventRegistrationCount[eventname] = (AceEvent.eventRegistrationCount[eventname] or 1) - 1

	-- Clean up tracking if no more registrations
	if AceEvent.eventRegistrationCount[eventname] <= 0 then
		AceEvent.eventRegistrationCount[eventname] = nil
		AceEvent.eventFrequency[eventname] = nil
		AceEvent.lastEventTime[eventname] = nil
		AceEvent.combatEventCount[eventname] = nil
		AceEvent.eventCache[eventname] = nil
		AceEvent.eventTiming[eventname] = nil
		AceEvent.eventMemoryUsage[eventname] = nil
		AceEvent.eventHandlerTimes[eventname] = nil
	end
end

-- APIs and registry for IPC messages, using CallbackHandler lib
if not AceEvent.messages then
	AceEvent.messages = CallbackHandler:New(AceEvent,
		"RegisterMessage", "UnregisterMessage", "UnregisterAllMessages"
	)

	-- Optimized SendMessage with batching for high-frequency messages
	local OLD_SendMessage = AceEvent.messages.Fire
	AceEvent.SendMessage = function(self, message, ...)
		if not message then return end
		local currentTime = GetTime()
		local lastTime = AceEvent.lastMessageTime[message] or 0
		local timeDiff = currentTime - lastTime
		local args = {...}
		local msgKey = message

		-- Create a unique key for this message+args combination
		-- Only include the first arg in the key if it's a simple type
		if select("#", ...) > 0 then
			local firstArg = ...
			if type(firstArg) == "string" or type(firstArg) == "number" or type(firstArg) == "boolean" then
				msgKey = message .. "-" .. tostring(firstArg)
			end
		end

		-- Store last message time
		AceEvent.lastMessageTime[message] = currentTime

		-- Check if we should batch this message
		if timeDiff < AceEvent.batchMessageTimer then
			-- Initialize batch table if needed
			AceEvent.messageBatch[msgKey] = AceEvent.messageBatch[msgKey] or {
				count = 0,
				lastArgs = {},
				timer = 0,
				scheduled = false
			}

			local batch = AceEvent.messageBatch[msgKey]
			batch.count = batch.count + 1

			-- Store the latest args
			for i = 1, select("#", ...) do
				batch.lastArgs[i] = select(i, ...)
			end

			-- If already scheduled or not reached threshold, skip
			if batch.scheduled or batch.count < AceEvent.batchMessageThreshold then
				return
			end

			-- Schedule batched delivery with recycled timer
			batch.scheduled = true

			local timer = AcquireTimer()
			timer.callback = function()
				if not AceEvent.messageBatch[msgKey] then
                    ReleaseTimer(timer)
                    return
                end

				-- Use pcall for safety when handling batch delivery
				local ok, err = pcall(function()
					OLD_SendMessage(self, message, unpack(batch.lastArgs))
				end)

				if not ok and err then
					-- Just log the error but don't propagate it to avoid breaking addons
					-- Silent failure is better than corrupting the event system
					geterrorhandler()(format("AceEvent batch delivery error: %s", tostring(err)))
				end

				-- Reset batch after sending
				AceEvent.messageBatch[msgKey] = nil
				ReleaseTimer(timer)
			end

			local timerId = C_TimerAfter(AceEvent.batchMessageTimer, timer.callback)
			AceEvent.pendingTimers[msgKey] = timerId
		else
			-- Not a candidate for batching, send immediately
			OLD_SendMessage(self, message, ...)
		end
	end
end

-- Add ability to cancel pending message batches
function AceEvent:CancelPendingMessage(message)
	if not message then return end
	for msgKey, timerId in pairs(AceEvent.pendingTimers) do
		if strfind(msgKey, message, 1, true) == 1 then
			if AceEvent.messageBatch[msgKey] then
				AceEvent.messageBatch[msgKey] = nil
			end
			AceEvent.pendingTimers[msgKey] = nil
		end
	end
end

-- Utility function for addon developers to pre-cache event data
function AceEvent:PreCacheEventData(event, processor)
	if type(event) ~= "string" then
		error("Usage: PreCacheEventData(event, processor): 'event' - string expected.", 2)
	end

	if type(processor) ~= "function" then
		error("Usage: PreCacheEventData(event, processor): 'processor' - function expected.", 2)
	end

	-- Store the processor function
	AceEvent.eventCache[event] = {
		processor = processor,
		data = {},
		lastUpdate = 0,
		throttle = 0.030 -- Default throttle time in seconds
	}
end

-- Allow setting custom throttle for specific events
function AceEvent:SetEventThrottle(event, throttleTime)
	if not event then return end
	if AceEvent.eventCache[event] and type(throttleTime) == "number" and throttleTime >= 0 then
		AceEvent.eventCache[event].throttle = throttleTime
	end
end

-- Utility function to set custom thresholds
function AceEvent:SetBatchThreshold(threshold)
	if type(threshold) == "number" and threshold > 0 then
		AceEvent.batchMessageThreshold = threshold
	end
end

function AceEvent:SetBatchTimer(timer)
	if type(timer) == "number" and timer > 0 then
		AceEvent.batchMessageTimer = timer
	end
end

-- Enable or disable performance tracking
function AceEvent:SetPerformanceTracking(enable, threshold)
	AceEvent.enablePerformanceTracking = enable and true or false

	if threshold and type(threshold) == "number" and threshold > 0 then
		AceEvent.performanceThreshold = threshold
	end
end

-- Clear performance tracking data
function AceEvent:ClearPerformanceData()
	for event in pairs(AceEvent.eventHandlerTimes) do
		AceEvent.eventHandlerTimes[event] = nil
		if AceEvent.eventTiming[event] then
			AceEvent.eventTiming[event].total = 0
			AceEvent.eventTiming[event].count = 0
			AceEvent.eventTiming[event].max = 0
			AceEvent.eventTiming[event].lastCheck = GetTime()
		end
	end
end

-- Function to get event frequency statistics with additional performance data
function AceEvent:GetEventStatistics()
	local stats = {}

	for event, freq in pairs(AceEvent.eventFrequency) do
		stats[event] = {
			frequency = freq,
			registrations = AceEvent.eventRegistrationCount[event] or 0,
			combatCount = AceEvent.combatEventCount[event] or 0
		}

		-- Add performance metrics if available
		if AceEvent.eventTiming[event] then
			local timing = AceEvent.eventTiming[event]
			stats[event].avgTime = timing.count > 0 and (timing.total / timing.count) or 0
			stats[event].maxTime = timing.max
			stats[event].count = timing.count
		end

		-- Add memory usage if tracked
		if AceEvent.eventMemoryUsage[event] then
			stats[event].memoryUsage = AceEvent.eventMemoryUsage[event]
		end

		-- Add handler times if tracked
		if AceEvent.eventHandlerTimes[event] then
			stats[event].slowHandlers = AceEvent.eventHandlerTimes[event]
		end
	end

	return stats
end

-- Function to get detailed statistics for optimization guidance
function AceEvent:GetOptimizationReport()
	local report = {
		highFrequencyEvents = {},
		slowEvents = {},
		memoryIntensiveEvents = {},
		recommendations = {}
	}

	-- Find high frequency events
	for event, freq in pairs(AceEvent.eventFrequency) do
		if freq > AceEvent.highFrequencyThreshold then
			report.highFrequencyEvents[event] = freq

			if not AceEvent.eventCache[event] then
				tinsert(report.recommendations, {
					event = event,
					recommendation = "Consider using PreCacheEventData for high-frequency event: " .. event,
					priority = "High"
				})
			end
		end
	end

	-- Find slow events
	for event, timing in pairs(AceEvent.eventTiming) do
		if timing.count > 0 and (timing.total / timing.count) > (AceEvent.performanceThreshold / 1000) then
			report.slowEvents[event] = timing.total / timing.count

			tinsert(report.recommendations, {
				event = event,
				recommendation = "Optimize handler for slow event: " .. event,
				priority = timing.max > (AceEvent.slowEventThreshold / 1000) and "Critical" or "Medium"
			})
		end
	end

	return report
end

-- embedding and embed handling
local mixins = {
	"RegisterEvent", "UnregisterEvent",
	"RegisterMessage", "UnregisterMessage",
	"SendMessage",
	"UnregisterAllEvents", "UnregisterAllMessages",
	-- Utility functions for addon developers
	"PreCacheEventData", "SetEventThrottle",
	"SetBatchThreshold", "SetBatchTimer",
	"SetPerformanceTracking", "ClearPerformanceData",
	"GetEventStatistics", "GetOptimizationReport",
	"CancelPendingMessage"
}

-- Embeds AceEvent into the target object making the functions from the mixins list available on target:..
-- @param target target object to embed AceEvent in
function AceEvent:Embed(target)
	if not target then return end
	for k, v in pairs(mixins) do
		target[v] = self[v]
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
	if not target then return end
	target:UnregisterAllEvents()
	target:UnregisterAllMessages()
end

-- Combat tracking for performance optimizations
local function OnEnterCombat()
	AceEvent.inCombat = true

	-- Reset combat event counters
	for k in pairs(AceEvent.combatEventCount) do
		AceEvent.combatEventCount[k] = 0
	end

	-- Clear performance data at combat start for a fresh sample
	if AceEvent.enablePerformanceTracking then
		AceEvent:ClearPerformanceData()
	end
end

local function OnLeaveCombat()
	AceEvent.inCombat = false

	-- Analyze combat event data to optimize for next combat
	for event, count in pairs(AceEvent.combatEventCount) do
		if count > 300 then -- More than 5 per second in a 1-minute combat
			-- This is a very high frequency combat event
			if not AceEvent.eventCache[event] then
				-- Automatically set up caching for extremely high frequency events in combat
				AceEvent:PreCacheEventData(event, function(...) return {...} end)
			end
		end
	end
end

-- Register combat state tracking
AceEvent.frame:RegisterEvent("PLAYER_REGEN_DISABLED")
AceEvent.frame:RegisterEvent("PLAYER_REGEN_ENABLED")

-- Enhanced event handler with caching, optimization, and performance tracking
local events = AceEvent.events
local eventPriorities = {
	-- Key combat events get priority processing
	UNIT_SPELLCAST_SUCCEEDED = 1,
	COMBAT_LOG_EVENT_UNFILTERED = 1,
	PLAYER_TARGET_CHANGED = 2,
	UNIT_HEALTH = 2,
	ACTIONBAR_UPDATE_COOLDOWN = 1
}

-- Priority based event queue
AceEvent.eventQueue = AceEvent.eventQueue or {}
local eventQueue = AceEvent.eventQueue

-- Process event queue based on priority
local function ProcessEventQueue()
	-- Sort by priority (lower number = higher priority)
	table.sort(eventQueue, function(a, b)
		local priorityA = eventPriorities[a.event] or 10
		local priorityB = eventPriorities[b.event] or 10
		return priorityA < priorityB
	end)

	-- Process events in priority order
	for i, entry in ipairs(eventQueue) do
		-- Handle event with cached data if configured
		if AceEvent.eventCache[entry.event] then
			local cache = AceEvent.eventCache[entry.event]
			events:Fire(entry.event, cache.data)
		else
			-- Standard event firing
			events:Fire(entry.event, unpack(entry.args))
		end

		-- Clear entry
		eventQueue[i] = nil
	end
end

AceEvent.frame:SetScript("OnEvent", function(this, event, ...)
	if not event then return end

	-- Track event frequency
	TrackEventFrequency(event)

	-- Handle special events immediately (not queued)
	if event == "PLAYER_REGEN_DISABLED" then
		OnEnterCombat()
		events:Fire(event, ...)
		return
	elseif event == "PLAYER_REGEN_ENABLED" then
		OnLeaveCombat()
		events:Fire(event, ...)
		return
	end

	-- Performance tracking
	local startTime, memoryBefore
	if AceEvent.enablePerformanceTracking then
		startTime = debugprofilestop()
		memoryBefore = collectgarbage("count")
	end

	-- Apply event caching if configured
	if AceEvent.eventCache[event] then
		local cache = AceEvent.eventCache[event]
		local currentTime = GetTime()

		-- Only process cached events if time has advanced enough
		if (currentTime - cache.lastUpdate) > cache.throttle then
			-- Use pcall for safety when running processor functions
			local ok, result = pcall(cache.processor, event, ...)
			if ok then
				cache.data = result
			else
				-- Just log the error but don't propagate it to avoid breaking addons
				geterrorhandler()(format("AceEvent cache processor error for %s: %s",
					event, tostring(result)))
			end
			cache.lastUpdate = currentTime
		end

		-- Add to priority queue instead of firing immediately
		tinsert(eventQueue, {
			event = event,
			args = {cache.data},
			priority = eventPriorities[event] or 10
		})
	else
		-- Add to priority queue with args
		local args = {...}
		tinsert(eventQueue, {
			event = event,
			args = args,
			priority = eventPriorities[event] or 10
		})
	end

	-- Process the queue on next frame if not already scheduled
	if not AceEvent.queueProcessScheduled then
		AceEvent.queueProcessScheduled = true
		C_TimerAfter(0, function()
			ProcessEventQueue()
			AceEvent.queueProcessScheduled = false
		end)
	end

	-- Record performance metrics
	if AceEvent.enablePerformanceTracking and startTime then
		local elapsed = debugprofilestop() - startTime
		local memoryAfter = collectgarbage("count")
		local memoryUsed = memoryAfter - memoryBefore

		-- Update timing stats
		if not AceEvent.eventTiming[event] then
			AceEvent.eventTiming[event] = { total = 0, count = 0, max = 0, lastCheck = GetTime() }
		end

		local timing = AceEvent.eventTiming[event]
		timing.total = timing.total + elapsed
		timing.count = timing.count + 1
		timing.max = mmax(timing.max, elapsed)

		-- Track memory usage
		AceEvent.eventMemoryUsage[event] = memoryUsed > 0 and memoryUsed or AceEvent.eventMemoryUsage[event]

		-- Log slow events for debugging
		if elapsed > AceEvent.performanceThreshold then
			AceEvent.eventHandlerTimes[event] = AceEvent.eventHandlerTimes[event] or {}
			tinsert(AceEvent.eventHandlerTimes[event], {
				time = GetTime(),
				elapsed = elapsed,
				memory = memoryUsed
			})

			-- Keep only the last 10 slow handlers
			while #AceEvent.eventHandlerTimes[event] > 10 do
				tremove(AceEvent.eventHandlerTimes[event], 1)
			end
		end
	end
end)

-- Finally: upgrade our old embeds
for target, v in pairs(AceEvent.embeds) do
	AceEvent:Embed(target)
end
