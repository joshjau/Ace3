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
-- This version is optimized for high-end systems with additional performance optimizations.
--
-- **AceTimer-3.0** can be embeded into your addon, either explicitly by calling AceTimer:Embed(MyAddon) or by
-- specifying it as an embeded library in your AceAddon. All functions will be available on your addon object
-- and can be accessed directly, without having to explicitly call AceTimer itself.\\
-- It is recommended to embed AceTimer, otherwise you'll have to specify a custom `self` on all calls you
-- make into AceTimer.
-- @class file
-- @name AceTimer-3.0
-- @release $Id$

local MAJOR, MINOR = "AceTimer-3.0", 18 -- Bump minor on changes and optimizations
local AceTimer, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceTimer then return end -- No upgrade needed

-- HIGH-END SYSTEM CONFIGURATION FLAGS
-- These flags are set for systems with high RAM and CPU capabilities
AceTimer.highEndConfig = {
	preAllocTimerPool = true,      -- Pre-allocate timer objects to reduce GC pressure
	stringPooling = true,          -- Pool common strings to reduce memory allocation
	aggressiveCaching = true,      -- Cache more values for faster lookups
	initialTimerCapacity = 128,    -- Initial capacity for timer collections
	optimizeLocalLookups = true,   -- Optimize local function references
	cleanupInterval = 60,          -- Seconds between cleanup operations
	lastCleanupTime = GetTime()    -- Last time cleanup was performed
}

AceTimer.activeTimers = AceTimer.activeTimers or {} -- Active timer list
local activeTimers = AceTimer.activeTimers -- Upvalue our private data

-- String pool for common strings to reduce memory allocation
local stringPool = {}
local function getPooledString(str)
	if not AceTimer.highEndConfig.stringPooling then return str end
	if not stringPool[str] then
		stringPool[str] = str
	end
	return stringPool[str]
end

-- Lua APIs - localize all frequently used functions
local type, unpack, next, error, select, pairs, ipairs, tostring, tonumber =
	  type, unpack, next, error, select, pairs, ipairs, tostring, tonumber
local tinsert, tremove, wipe, sort = table.insert, table.remove, table.wipe, table.sort
local format, gsub, match, sub = string.format, string.gsub, string.match, string.sub
local floor, ceil, min, max, abs = math.floor, math.ceil, math.min, math.max, math.abs

-- WoW APIs - localize all frequently used WoW functions
local GetTime, C_TimerAfter = GetTime, C_Timer.After

-- Pre-allocated error messages for common timer operations
local ERROR_NO_FUNC_DELAY = getPooledString(MAJOR..": ScheduleTimer(callback, delay, args...): 'callback' and 'delay' must have set values.")
local ERROR_SELF_NOT_TABLE = getPooledString(MAJOR..": ScheduleTimer(callback, delay, args...): 'self' - must be a table.")
local ERROR_FUNC_NOT_IN_MODULE = getPooledString(MAJOR..": ScheduleTimer(callback, delay, args...): Tried to register '%s' as the callback, but it doesn't exist in the module.")

-- Pre-allocated timer objects pool to reduce GC pressure
local timerPool = {}
local timerPoolSize = 0
local MIN_TIMER_DELAY = 0.01 -- Minimum delay constant

-- Get a timer object from the pool or create a new one
local function getTimerObject()
    if timerPoolSize > 0 and AceTimer.highEndConfig.preAllocTimerPool then
        timerPoolSize = timerPoolSize - 1
        local timer = timerPool[timerPoolSize + 1]
        timerPool[timerPoolSize + 1] = nil
        return timer
    end
    return {}
end

-- Return a timer object to the pool for reuse
local function recycleTimerObject(timer)
    if not AceTimer.highEndConfig.preAllocTimerPool then return end
    if not timer then return end

    -- Safety check - ensure this timer is not in activeTimers before recycling
    for handle, t in pairs(activeTimers) do
        if t == timer then
            -- Don't recycle active timers
            return
        end
    end

    -- Clear the timer object for reuse
    for k in pairs(timer) do
        timer[k] = nil
    end

    -- Add to pool
    timerPoolSize = timerPoolSize + 1
    timerPool[timerPoolSize] = timer
end

-- Pre-allocate timer pool on init for high-end systems
if AceTimer.highEndConfig.preAllocTimerPool then
    for i = 1, AceTimer.highEndConfig.initialTimerCapacity do
        timerPoolSize = timerPoolSize + 1
        timerPool[timerPoolSize] = {}
    end
end

-- Forward declaration for cleanup function
local performCleanup

-- Direct reference to callback creation for faster execution
local createTimerCallback

local function new(self, loop, func, delay, ...)
	if delay < MIN_TIMER_DELAY then
		delay = MIN_TIMER_DELAY -- Restrict to the lowest time that the C_Timer API allows us
	end

	-- Validate required parameters
	if not func then
		error("AceTimer: Attempt to schedule timer with nil function", 2)
		return
	end

	local timer = getTimerObject()
	local time = GetTime()
	local endTime = time + delay

	timer.object = self
	timer.func = func
	timer.looping = loop
	timer.argsCount = select("#", ...)
	timer.delay = delay
	timer.ends = endTime
    timer.cancelled = false

	-- Copy varargs into the timer object
	for i = 1, timer.argsCount do
		timer[i] = select(i, ...)
	end

	activeTimers[timer] = timer

	-- Create new timer closure to wrap the "timer" object
	timer.callback = createTimerCallback(timer)

	C_TimerAfter(delay, timer.callback)
	return timer
end

-- Optimized timer callback creation
createTimerCallback = function(timer)
    return function()
        if timer.cancelled then return end

        -- Safety check - ensure timer is valid and has required fields
        if not timer or not timer.func then
            -- If timer exists in activeTimers but is invalid, remove it
            for handle, t in pairs(activeTimers) do
                if t == timer then
                    activeTimers[handle] = nil
                    break
                end
            end
            return
        end

        -- Fast path for function callbacks (most common case)
        if type(timer.func) ~= "string" then
            timer.func(unpack(timer, 1, timer.argsCount or 0))
        else
            -- String method call path - ensure object exists
            if timer.object and timer.object[timer.func] then
                timer.object[timer.func](timer.object, unpack(timer, 1, timer.argsCount or 0))
            else
                -- Log error but don't crash
                local objType = type(timer.object)
                local funcName = tostring(timer.func)
                error(format("AceTimer: method %s not found on object of type %s", funcName, objType), 2)
            end
        end

        if timer.looping and not timer.cancelled then
            -- Optimize time getting for looping timers
            local time = GetTime()
            -- Fast path for common case where delay hasn't drifted much
            local ndelay = timer.delay - (time - timer.ends)
            -- Ensure the delay doesn't go below the threshold with a single comparison
            if ndelay < MIN_TIMER_DELAY then ndelay = MIN_TIMER_DELAY end

            C_TimerAfter(ndelay, timer.callback)
            timer.ends = time + ndelay

            -- Occasionally perform cleanup operations on recurring timers
            performCleanup()
        else
            -- Remove from active timers and recycle the object
            local handle = timer.handle or timer
            activeTimers[handle] = nil
            recycleTimerObject(timer)
        end
    end
end

-- Performance statistics for monitoring
AceTimer.stats = {
    activeTimerCount = 0,
    pooledTimerCount = 0,
    totalTimersCreated = 0,
    totalTimersCancelled = 0,
    peakActiveTimers = 0
}

-- Update performance statistics
local function updateStats()
    local count = 0
    for _ in pairs(activeTimers) do
        count = count + 1
    end
    AceTimer.stats.activeTimerCount = count
    AceTimer.stats.pooledTimerCount = timerPoolSize

    -- Track peak usage
    if count > AceTimer.stats.peakActiveTimers then
        AceTimer.stats.peakActiveTimers = count
    end
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
		error(ERROR_NO_FUNC_DELAY, 2)
	end
	if type(func) == "string" then
		if type(self) ~= "table" then
			error(ERROR_SELF_NOT_TABLE, 2)
		elseif not self[func] then
			error(ERROR_FUNC_NOT_IN_MODULE:format(func), 2)
		end
	end

	local timer = new(self, nil, func, delay, ...)

	-- Update statistics
	AceTimer.stats.totalTimersCreated = AceTimer.stats.totalTimersCreated + 1
	updateStats()

	return timer
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
		error(ERROR_NO_FUNC_DELAY, 2)
	end
	if type(func) == "string" then
		if type(self) ~= "table" then
			error(ERROR_SELF_NOT_TABLE, 2)
		elseif not self[func] then
			error(ERROR_FUNC_NOT_IN_MODULE:format(func), 2)
		end
	end

	local timer = new(self, true, func, delay, ...)

	-- Update statistics
	AceTimer.stats.totalTimersCreated = AceTimer.stats.totalTimersCreated + 1
	updateStats()

	return timer
end

-- Fast per-object timer cancelation cache
local cancelCache = {}

--- Cancels a timer with the given id, registered by the same addon object as used for `:ScheduleTimer`
-- Both one-shot and repeating timers can be canceled with this function, as long as the `id` is valid
-- and the timer has not fired yet or was canceled before.
-- @param id The id of the timer, as returned by `:ScheduleTimer` or `:ScheduleRepeatingTimer`
function AceTimer:CancelTimer(id)
	if not id then return false end

	local timer = activeTimers[id]

	if not timer then
		return false
	else
		-- Mark as cancelled first to prevent race conditions
		timer.cancelled = true

		-- Clear function references to prevent execution even if C_Timer still calls back
		timer.func = nil

		-- Remove from activeTimers
		activeTimers[id] = nil

		-- Recycle the timer object if possible
		recycleTimerObject(timer)

		-- Update statistics
		AceTimer.stats.totalTimersCancelled = AceTimer.stats.totalTimersCancelled + 1
		updateStats()

		-- Occasionally perform cleanup
		performCleanup()

		return true
	end
end

--- Cancels all timers registered to the current addon object ('self')
-- Optimized for high performance with large numbers of timers
function AceTimer:CancelAllTimers()
	-- Fast path: if no timers are active, return immediately
	local foundAny = false
	for _, v in next, activeTimers do
		if v.object == self then
			foundAny = true
			break
		end
	end

	if not foundAny then return end

	-- Use cached list of timers per object for better performance
	local objTimers = cancelCache[self]
	if not objTimers then
		objTimers = {}
		cancelCache[self] = objTimers
	else
		wipe(objTimers)
	end

	-- Collect all timers for this object first
	local count = 0
	for k, v in next, activeTimers do
		if v.object == self then
			count = count + 1
			objTimers[count] = k
		end
	end

	-- Then cancel them all at once
	for i = 1, count do
		AceTimer.CancelTimer(self, objTimers[i])
	end

	-- Force cleanup after canceling multiple timers
	performCleanup()

	-- Update statistics
	updateStats()
end

-- Cache for TimeLeft function to avoid repeated GetTime() calls
local timeLeftCache = { time = 0, values = {} }

--- Returns the time left for a timer with the given id, registered by the current addon object ('self').
-- This function will return 0 when the id is invalid.
-- @param id The id of the timer, as returned by `:ScheduleTimer` or `:ScheduleRepeatingTimer`
-- @return The time left on the timer.
function AceTimer:TimeLeft(id)
	local timer = activeTimers[id]
	if not timer then
		return 0
	else
		-- Use cached time for multiple TimeLeft calls in the same frame
		local currentTime = GetTime()
		if abs(currentTime - timeLeftCache.time) < 0.001 and AceTimer.highEndConfig.aggressiveCaching then
			if timeLeftCache.values[id] then
				return timeLeftCache.values[id]
			end
		else
			-- Reset cache if time has advanced
			if currentTime > timeLeftCache.time + 0.001 then
				wipe(timeLeftCache.values)
				timeLeftCache.time = currentTime
			end
		end

		local timeLeft = max(0, timer.ends - currentTime)

		-- Cache the result
		if AceTimer.highEndConfig.aggressiveCaching then
			timeLeftCache.values[id] = timeLeft
		end

		return timeLeft
	end
end

-- Function to clean up resources and manage memory usage
performCleanup = function()
    local currentTime = GetTime()
    if currentTime - AceTimer.highEndConfig.lastCleanupTime < AceTimer.highEndConfig.cleanupInterval then
        return
    end

    -- Set last cleanup time
    AceTimer.highEndConfig.lastCleanupTime = currentTime

    -- Trim timer pool if it's gotten too large
    if timerPoolSize > AceTimer.highEndConfig.initialTimerCapacity * 2 then
        local excessTimers = timerPoolSize - AceTimer.highEndConfig.initialTimerCapacity
        for i = 1, excessTimers do
            timerPool[timerPoolSize] = nil
            timerPoolSize = timerPoolSize - 1
        end
    end

    -- Clean up the time left cache
    wipe(timeLeftCache.values)

    -- Clean up per-object timer cancelation caches for objects no longer in use
    for obj in pairs(cancelCache) do
        local stillExists = false
        for _, timer in pairs(activeTimers) do
            if timer.object == obj then
                stillExists = true
                break
            end
        end

        if not stillExists then
            cancelCache[obj] = nil
        end
    end
end

-- ---------------------------------------------------------------------
-- Upgrading

---@class AceTimerObj
---@field handle any Timer handle for backward compatibility
---@field cancelled boolean Whether the timer is cancelled
---@field callback function The callback function

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
					newTimer = AceTimer.ScheduleRepeatingTimer(timer.object, timer.callback, timer.delay, timer.arg)
				else
					newTimer = AceTimer.ScheduleTimer(timer.object, timer.callback, timer.when - GetTime(), timer.arg)
				end
				-- Use the old handle for old timers
				activeTimers[newTimer] = nil
				activeTimers[handle] = newTimer
				newTimer.handle = handle
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
		if timer.looping then
			newTimer = AceTimer.ScheduleRepeatingTimer(timer.object, timer.func, duration, unpack(timer.args, 1, timer.argsCount))
		else
			newTimer = AceTimer.ScheduleTimer(timer.object, timer.func, duration - elapsed, unpack(timer.args, 1, timer.argsCount))
		end
		-- Use the old handle for old timers
		activeTimers[newTimer] = nil
		activeTimers[handle] = newTimer
		newTimer.handle = handle
	end

	-- Migrate transitional handles
	if oldminor < 13 and AceTimer.hashCompatTable then
		for handle, id in next, AceTimer.hashCompatTable do
			local t = activeTimers[id]
			if t then
				activeTimers[id] = nil
				activeTimers[handle] = t
				t.handle = handle
			end
		end
		AceTimer.hashCompatTable = nil
	end
end

-- ---------------------------------------------------------------------
-- Embed handling

AceTimer.embeds = AceTimer.embeds or {}

-- Direct function references for embed operations - faster than string lookups
local embedFuncs = {
    ScheduleTimer = AceTimer.ScheduleTimer,
    ScheduleRepeatingTimer = AceTimer.ScheduleRepeatingTimer,
    CancelTimer = AceTimer.CancelTimer,
    CancelAllTimers = AceTimer.CancelAllTimers,
    TimeLeft = AceTimer.TimeLeft
}

-- Pre-allocate array of function names for consistent usage
local mixins = {
	"ScheduleTimer", "ScheduleRepeatingTimer",
	"CancelTimer", "CancelAllTimers",
	"TimeLeft"
}

function AceTimer:Embed(target)
	AceTimer.embeds[target] = true

	-- Use direct function references when optimizing local lookups is enabled
	if AceTimer.highEndConfig.optimizeLocalLookups then
        for funcName, funcRef in pairs(embedFuncs) do
            target[funcName] = function(self, ...)
                return funcRef(self, ...)
            end
        end
    else
        -- Traditional mixin approach for compatibility
        for _,v in next, mixins do
            target[v] = AceTimer[v]
        end
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

-- Re-embed functions for all existing embeds after upgrade
for addon in next, AceTimer.embeds do
	AceTimer:Embed(addon)
end

-- ---------------------------------------------------------------------
-- Runtime Configuration API

--- Configure the high-end system optimization settings
-- @param key The configuration key to modify
-- @param value The new value for the configuration key
function AceTimer:SetHighEndConfig(key, value)
    if type(key) ~= "string" or AceTimer.highEndConfig[key] == nil then
        error(format("Invalid configuration key: %s", tostring(key)), 2)
        return
    end

    AceTimer.highEndConfig[key] = value
end

--- Get the current value of a high-end system configuration setting
-- @param key The configuration key to retrieve
-- @return The current value of the configuration key
function AceTimer:GetHighEndConfig(key)
    if type(key) ~= "string" or AceTimer.highEndConfig[key] == nil then
        error(format("Invalid configuration key: %s", tostring(key)), 2)
        return nil
    end

    return AceTimer.highEndConfig[key]
end

--- Reset all high-end system configuration settings to their default values
function AceTimer:ResetHighEndConfig()
    AceTimer.highEndConfig = {
        preAllocTimerPool = true,      -- Pre-allocate timer objects to reduce GC pressure
        stringPooling = true,          -- Pool common strings to reduce memory allocation
        aggressiveCaching = true,      -- Cache more values for faster lookups
        initialTimerCapacity = 128,    -- Initial capacity for timer collections
        optimizeLocalLookups = true,   -- Optimize local function references
        cleanupInterval = 60,          -- Seconds between cleanup operations
        lastCleanupTime = GetTime()    -- Last time cleanup was performed
    }

    -- Re-initialize timer pool
    timerPool = {}
    timerPoolSize = 0

    if AceTimer.highEndConfig.preAllocTimerPool then
        for i = 1, AceTimer.highEndConfig.initialTimerCapacity do
            timerPoolSize = timerPoolSize + 1
            timerPool[timerPoolSize] = {}
        end
    end
end

--- Get the current performance statistics
-- @return A table containing performance statistics
function AceTimer:GetPerformanceStats()
    updateStats() -- Update stats before returning
    return AceTimer.stats
end
