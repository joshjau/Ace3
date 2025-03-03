--- **AceTimer-3.0** provides a central facility for registering timers.
-- AceTimer supports one-shot timers and repeating timers. All timers are stored in an efficient
-- data structure that allows easy dispatching and fast rescheduling. Timers can be registered
-- or canceled at any time, even from within a running timer, without conflict or large overhead.\\
-- AceTimer is currently limited to firing timers at a frequency of 0.01s as this is what the WoW timer API
-- restricts us to.
--
-- All `:Schedule` functions will return a handle to the current timer, which you will need to store if you
-- need to cancel the timer you just registered.
--
-- **AceTimer-3.0** can be embeded into your addon, either explicitly by calling AceTimer:Embed(MyAddon) or by
-- specifying it as an embeded library in your AceAddon. All functions will be available on your addon object
-- and can be accessed directly, without having to explicitly call AceTimer itself.\\
-- It is recommended to embed AceTimer, otherwise you'll have to specify a custom `self` on all calls you
-- make into AceTimer.
-- @class file
-- @name AceTimer-3.0
-- @release $Id$

local MAJOR, MINOR = "AceTimer-3.0", 18 -- Bump minor on changes
local AceTimer, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceTimer then return end -- No upgrade needed

-- Pre-allocate the activeTimers table with a larger initial size to reduce resizing overhead
-- This is especially beneficial for high-end systems with plenty of memory
if not AceTimer.activeTimers then
	-- Create a pre-sized table with nil values to avoid rehashing
	-- This technique pre-allocates hash slots without consuming memory for values
	local size = 256 -- Reasonable size for most addons, reduces table resizing operations
	local prealloc = {}
	for i = 1, size do
		prealloc[i] = false
	end
	for i = 1, size do
		prealloc[i] = nil
	end
	AceTimer.activeTimers = prealloc
end

local activeTimers = AceTimer.activeTimers -- Upvalue our private data

-- Lua APIs - localize all frequently used functions for performance
-- This reduces table lookups and improves execution speed on the hot path
local type, unpack, next, error, select, tostring, setmetatable = type, unpack, next, error, select, tostring, setmetatable
local tinsert, tremove, wipe, min, max = table.insert, table.remove, table.wipe, math.min, math.max
local format, gsub, strsub = string.format, string.gsub, string.sub

-- WoW APIs - localize for performance and check for newer APIs
-- Using precise timer when available improves timing accuracy
local GetTime = GetTime
local C_TimerAfter = C_Timer.After
local C_TimerNewTicker = C_Timer.NewTicker
local GetTimePreciseSec = GetTimePreciseSec or GetTime -- Use precise timer if available for better accuracy

-- Constants for performance optimization
-- Using constants reduces string allocations and improves code readability
local MIN_TIMER_DELAY = 0.01 -- Minimum timer delay allowed by C_Timer API
local ERROR_SELF_NOT_TABLE = "%s: %s(callback, delay, args...): 'self' - must be a table."
local ERROR_CALLBACK_NOT_FOUND = "%s: %s(callback, delay, args...): Tried to register '%s' as the callback, but it doesn't exist in the module."
local ERROR_MISSING_ARGS = "%s: %s(callback, delay, args...): 'callback' and 'delay' must have set values."

-- Pre-allocate a table for timer creation to reduce GC pressure
-- Using a metatable allows for efficient method calls on timer objects
local timerPrototype = {}
local timerMT = {__index = timerPrototype}

-- Fast path for timer creation
local function new(self, loop, func, delay, ...)
	-- Enforce minimum delay
	if delay < MIN_TIMER_DELAY then
		delay = MIN_TIMER_DELAY -- Restrict to the lowest time that the C_Timer API allows us
	end

	-- Use GetTimePreciseSec if available for more accurate timing
	local currentTime = GetTimePreciseSec()

	local timer = setmetatable({
		object = self,
		func = func,
		looping = loop,
		argsCount = select("#", ...),
		delay = delay,
		ends = currentTime + delay,
		cancelled = false,
		...
	}, timerMT)

	activeTimers[timer] = timer

	-- Optimize callback function based on type
	if type(func) == "string" then
		-- String function callback (method call)
		-- Cache the method lookup for better performance
		local method = self[func]
		if not method then
			-- Safety check: if method doesn't exist, cancel the timer
			activeTimers[timer] = nil
			return timer
		end

		timer.callback = function()
			if timer.cancelled then return end

			-- Direct method call is faster than dynamic lookup at runtime
			method(self, unpack(timer, 1, timer.argsCount))

			if timer.looping and not timer.cancelled then
				-- Compensate delay to get a perfect average delay
				-- This adjustment helps maintain consistent timing intervals
				local time = GetTimePreciseSec()
				local ndelay = max(MIN_TIMER_DELAY, timer.delay - (time - timer.ends))
				C_TimerAfter(ndelay, timer.callback)
				timer.ends = time + ndelay
			else
				-- Find and remove the timer from activeTimers
				-- This approach avoids the need for handle properties
				activeTimers[timer] = nil
			end
		end
	else
		-- Function reference callback (direct call)
		timer.callback = function()
			if timer.cancelled then return end

			-- Direct function call avoids method lookup overhead
			func(unpack(timer, 1, timer.argsCount))

			if timer.looping and not timer.cancelled then
				-- Compensate delay to get a perfect average delay
				-- This helps maintain consistent intervals even with processing delays
				local time = GetTimePreciseSec()
				local ndelay = max(MIN_TIMER_DELAY, timer.delay - (time - timer.ends))
				C_TimerAfter(ndelay, timer.callback)
				timer.ends = time + ndelay
			else
				-- Remove the timer directly from activeTimers
				activeTimers[timer] = nil
			end
		end
	end

	C_TimerAfter(delay, timer.callback)
	return timer
end

--- Schedule a new one-shot timer.
-- The timer will fire once in `delay` seconds, unless canceled before.
-- @param func Callback function for the timer pulse (funcref or method name).
-- @param delay Delay for the timer, in seconds.
-- @param ... An optional, unlimited amount of arguments to pass to the callback function.
-- @usage
-- MyAddOn = LibStub("AceAddon-3.0"):NewAddon("MyAddOn", "AceTimer-3.0")
--
-- function MyAddOn:OnEnable()
--   self:ScheduleTimer("TimerFeedback", 5)
-- end
--
-- function MyAddOn:TimerFeedback()
--   print("5 seconds passed")
-- end
function AceTimer:ScheduleTimer(func, delay, ...)
	if not func or not delay then
		error(format(ERROR_MISSING_ARGS, MAJOR, "ScheduleTimer"), 2)
	end
	if type(func) == "string" then
		if type(self) ~= "table" then
			error(format(ERROR_SELF_NOT_TABLE, MAJOR, "ScheduleTimer"), 2)
		elseif not self[func] then
			error(format(ERROR_CALLBACK_NOT_FOUND, MAJOR, "ScheduleTimer", func), 2)
		end
	end
	return new(self, nil, func, delay, ...)
end

--- Schedule a repeating timer.
-- The timer will fire every `delay` seconds, until canceled.
-- @param func Callback function for the timer pulse (funcref or method name).
-- @param delay Delay for the timer, in seconds.
-- @param ... An optional, unlimited amount of arguments to pass to the callback function.
-- @usage
-- MyAddOn = LibStub("AceAddon-3.0"):NewAddon("MyAddOn", "AceTimer-3.0")
--
-- function MyAddOn:OnEnable()
--   self.timerCount = 0
--   self.testTimer = self:ScheduleRepeatingTimer("TimerFeedback", 5)
-- end
--
-- function MyAddOn:TimerFeedback()
--   self.timerCount = self.timerCount + 1
--   print(("%d seconds passed"):format(5 * self.timerCount))
--   -- run 30 seconds in total
--   if self.timerCount == 6 then
--     self:CancelTimer(self.testTimer)
--   end
-- end
function AceTimer:ScheduleRepeatingTimer(func, delay, ...)
	if not func or not delay then
		error(format(ERROR_MISSING_ARGS, MAJOR, "ScheduleRepeatingTimer"), 2)
	end
	if type(func) == "string" then
		if type(self) ~= "table" then
			error(format(ERROR_SELF_NOT_TABLE, MAJOR, "ScheduleRepeatingTimer"), 2)
		elseif not self[func] then
			error(format(ERROR_CALLBACK_NOT_FOUND, MAJOR, "ScheduleRepeatingTimer", func), 2)
		end
	end

	-- Enforce minimum delay to prevent timer spam
	delay = max(delay, MIN_TIMER_DELAY)

	-- Use C_Timer.NewTicker if available for repeating timers (more efficient)
	if C_TimerNewTicker and type(func) ~= "string" then
		local args = {...}
		local argsCount = select("#", ...)

		-- Create a wrapper object instead of modifying the ticker directly
		-- This avoids issues with protected function containers
		local wrapper = setmetatable({
			object = self,
			func = func,
			delay = delay,
			ends = GetTimePreciseSec() + delay,
			cancelled = false
		}, timerMT)

		local callback = function()
			if not wrapper.cancelled then
				func(unpack(args, 1, argsCount))
			end
		end

		local ticker = C_TimerNewTicker(delay, callback)
		wrapper.ticker = ticker

		-- Add cancel method to the wrapper
		-- This ensures proper cleanup when the timer is cancelled
		wrapper.Cancel = function()
			if not wrapper.cancelled then
				wrapper.cancelled = true
				ticker:Cancel()
				activeTimers[wrapper] = nil
				return true
			end
			return false
		end

		activeTimers[wrapper] = wrapper
		return wrapper
	else
		-- Fall back to the standard implementation
		-- This ensures compatibility with string-based callbacks
		return new(self, true, func, delay, ...)
	end
end

--- Cancels a timer with the given id, registered by the same addon object as used for `:ScheduleTimer`
-- Both one-shot and repeating timers can be canceled with this function, as long as the `id` is valid
-- and the timer has not fired yet or was canceled before.
-- @param id The id of the timer, as returned by `:ScheduleTimer` or `:ScheduleRepeatingTimer`
function AceTimer:CancelTimer(id)
	-- Quick return if id is nil or not a valid type
	if id == nil then return false end

	local timer = activeTimers[id]

	if not timer then
		return false
	else
		-- Prevent double cancellation
		if timer.cancelled then
			return true
		end

		-- Handle C_Timer.NewTicker objects differently
		if timer.Cancel and type(timer.Cancel) == "function" then
			return timer:Cancel()
		else
			timer.cancelled = true
			activeTimers[id] = nil
			return true
		end
	end
end

--- Cancels all timers registered to the current addon object ('self')
function AceTimer:CancelAllTimers()
	-- Create a temporary table to store timers to cancel
	-- This avoids modifying the activeTimers table while iterating
	-- which could lead to unpredictable behavior
	local toCancel = {}
	local count = 0
	local MAX_TIMERS_PER_FRAME = 100 -- Limit how many timers we process at once

	for k, v in next, activeTimers do
		if v.object == self then
			if not v.cancelled then -- Skip already cancelled timers
				toCancel[k] = true
				count = count + 1
				if count >= MAX_TIMERS_PER_FRAME then
					break -- Process in batches to avoid script timeout
				end
			end
		end
	end

	-- Now cancel all the timers
	-- Two-phase cancellation ensures safe iteration
	for k in next, toCancel do
		AceTimer.CancelTimer(self, k)
	end

	-- If we hit the limit, schedule another run to process remaining timers
	if count >= MAX_TIMERS_PER_FRAME then
		C_Timer.After(0.01, function() self:CancelAllTimers() end)
	end
end

--- Returns the time left for a timer with the given id, registered by the current addon object ('self').
-- This function will return 0 when the id is invalid.
-- @param id The id of the timer, as returned by `:ScheduleTimer` or `:ScheduleRepeatingTimer`
-- @return The time left on the timer.
function AceTimer:TimeLeft(id)
	local timer = activeTimers[id]
	if not timer then
		return 0
	else
		return timer.ends - GetTimePreciseSec()
	end
end


-- ---------------------------------------------------------------------
-- Upgrading

-- Upgrade from old hash-bucket based timers to C_Timer.After timers.
if oldminor and oldminor < 10 then
	-- disable old timer logic
	AceTimer.frame:SetScript("OnUpdate", nil)
	AceTimer.frame:SetScript("OnEvent", nil)
	AceTimer.frame:UnregisterAllEvents()
	-- convert timers
	for object,timers in next, AceTimer.selfs do
		for handle,timer in next, timers do
			if type(timer) == "table" and timer.callback then
				local newTimer
				if timer.delay then
					-- Store the handle in a local variable to pass to the timer creation
					local timerHandle = handle
					newTimer = AceTimer.ScheduleRepeatingTimer(timer.object, timer.callback, timer.delay, timer.arg)
					-- Store the handle in activeTimers directly
					activeTimers[newTimer] = nil
					activeTimers[timerHandle] = newTimer
				else
					local timerHandle = handle
					newTimer = AceTimer.ScheduleTimer(timer.object, timer.callback, timer.when - GetTimePreciseSec(), timer.arg)
					activeTimers[newTimer] = nil
					activeTimers[timerHandle] = newTimer
				end
			end
		end
	end
	AceTimer.selfs = nil
	AceTimer.hash = nil
	AceTimer.debug = nil
elseif oldminor and oldminor < 17 then
	-- Upgrade from old animation based timers to C_Timer.After timers.
	AceTimer.inactiveTimers = nil
	AceTimer.frame = nil
	local oldTimers = AceTimer.activeTimers
	-- Clear old timer table and update upvalue
	AceTimer.activeTimers = {}
	activeTimers = AceTimer.activeTimers
	for handle, timer in next, oldTimers do
		local newTimer
		-- Stop the old timer animation
		local duration, elapsed = timer:GetDuration(), timer:GetElapsed()
		timer:GetParent():Stop()
		local timerHandle = handle
		if timer.looping then
			newTimer = AceTimer.ScheduleRepeatingTimer(timer.object, timer.func, duration, unpack(timer.args, 1, timer.argsCount))
		else
			newTimer = AceTimer.ScheduleTimer(timer.object, timer.func, duration - elapsed, unpack(timer.args, 1, timer.argsCount))
		end
		-- Use the old handle for old timers
		activeTimers[newTimer] = nil
		activeTimers[timerHandle] = newTimer
	end

	-- Migrate transitional handles
	if oldminor < 13 and AceTimer.hashCompatTable then
		for handle, id in next, AceTimer.hashCompatTable do
			local t = activeTimers[id]
			if t then
				activeTimers[id] = nil
				activeTimers[handle] = t
			end
		end
		AceTimer.hashCompatTable = nil
	end
elseif oldminor and oldminor < 18 then
	-- Upgrade from version 17 to 18 (our optimized version)
	-- No structural changes needed, just ensure all timers use the new metatable
	for handle, timer in next, activeTimers do
		if type(timer) == "table" and not getmetatable(timer) then
			setmetatable(timer, timerMT)
		end
	end
end

-- ---------------------------------------------------------------------
-- Embed handling

AceTimer.embeds = AceTimer.embeds or {}

-- Pre-build the list of mixin methods to avoid creating it at each embed call
local mixins = {
	"ScheduleTimer", "ScheduleRepeatingTimer",
	"CancelTimer", "CancelAllTimers",
	"TimeLeft"
}

-- Embeds AceTimer into the target object making the functions from the mixins list available on target:..
-- @param target target object to embed AceTimer in
function AceTimer:Embed(target)
	AceTimer.embeds[target] = true

	-- Optimization: use direct function references instead of method lookups
	for _, v in next, mixins do
		target[v] = AceTimer[v]
	end

	return target
end

-- AceTimer:OnEmbedDisable(target)
-- target (object) - target object that AceTimer is embedded in.
--
-- cancel all timers registered for the object
function AceTimer:OnEmbedDisable(target)
	target:CancelAllTimers()
end

-- Embed AceTimer into all existing embeds
for addon in next, AceTimer.embeds do
	AceTimer:Embed(addon)
end

-- Add timer prototype methods
function timerPrototype:Cancel()
	-- Prevent double cancellation
	if self.cancelled then
		return true
	end

	-- Mark as cancelled immediately to prevent recursive cancellation
	self.cancelled = true

	-- Find the key for this timer in activeTimers
	-- This approach works with both direct timer objects and wrapper objects
	for k, v in next, activeTimers do
		if v == self then
			activeTimers[k] = nil
			return true
		end
	end
	return false
end

function timerPrototype:TimeLeft()
	-- Direct calculation of time remaining is more efficient
	-- than going through the AceTimer.TimeLeft method
	if self.cancelled then
		return 0
	else
		return self.ends - GetTimePreciseSec()
	end
end
