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
	nonCriticalDelayFactor = 1.5,  -- Multiply delay for non-critical timers
	lastCleanupTime = GetTime(),   -- Last time cleanup was performed
	useBatchProcessing = true,     -- Process timers in batches to reduce per-frame overhead
	batchInterval = 0.01,          -- How frequently to process timer batches (seconds)
	maxBatchSize = 20,             -- Maximum number of timers to process in a single batch
	usePriorityQueue = true,       -- Use a priority queue to optimize timer sorting
	validateMethodsBeforeCall = true, -- Validate method existence before calling
	autoSkipMissingMethods = true, -- Skip execution of missing methods instead of generating errors
	verboseErrors = false,         -- Show detailed error messages with stack traces
	errorThrottling = true,        -- Prevent excessive error spam from the same timer
	maxErrorsPerMethod = 3         -- Maximum number of errors to show for each method before throttling
}

AceTimer.activeTimers = AceTimer.activeTimers or {} -- Active timer list
local activeTimers = AceTimer.activeTimers -- Upvalue our private data
local activeTimerCount = 0 -- Direct counter to avoid frequent table iteration

-- Registry for named timers to prevent redundant timer creation
-- Format: { [object] = { [timerName] = timerHandle } }
AceTimer.namedTimers = AceTimer.namedTimers or {}
local namedTimers = AceTimer.namedTimers

-- Priority queue for efficient timer sorting
AceTimer.timerHeap = AceTimer.timerHeap or {}
local timerHeap = AceTimer.timerHeap

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
local ERROR_NAMED_TIMER_NAME = getPooledString(MAJOR..": ScheduleNamedTimer(name, callback, delay, args...): 'name' must be a string.")

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

    -- Clear the timer object for reuse - more thorough cleanup
    for k, v in pairs(timer) do
        -- Handle nested tables by emptying them first
        if type(v) == "table" then
            -- Only clear tables that are not shared/referenced elsewhere
            if v ~= activeTimers and v ~= namedTimers and v ~= timerHeap then
                wipe(v)
            end
        end
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

-- Forward declarations for cleanup and batch processing
local performCleanup
local processBatchedTimers
local createTimerCallback

-- At the top with other forward declarations
local heapInsert, heapExtract, heapifyUp, heapifyDown, heapUpdate

-- Forward declare new function
local new

-- Track error occurrences to prevent spam
local errorCounts = {}

-- Cache for TimeLeft function to avoid repeated GetTime() calls
local timeLeftCache = { time = 0, values = {} }

-- Fast per-object timer cancelation cache
local cancelCache = {}

-- Reset error tracking periodically
local function resetErrorTracking()
    wipe(errorCounts)
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

    -- Clean up the time left cache - use wipe consistently
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

    -- Clean up empty named timer entries
    for obj in pairs(namedTimers) do
        if not next(namedTimers[obj]) then
            namedTimers[obj] = nil
        end
    end

    -- Clean up and validate the priority queue if enabled
    if AceTimer.highEndConfig.usePriorityQueue then
        -- Remove any cancelled timers from the heap
        for i = #timerHeap, 1, -1 do
            if timerHeap[i].cancelled or not activeTimers[timerHeap[i]] then
                tremove(timerHeap, i)
            end
        end

        -- Re-heapify to ensure proper order
        heapUpdate(timerHeap)
    end

    -- Reset error tracking to prevent memory growth
    resetErrorTracking()
end

-- Batch processing timer
local batchProcessingTimer = nil
local isBatchProcessing = false

-- Update performance statistics
local function updateStats()
    AceTimer.stats.activeTimerCount = activeTimerCount
    AceTimer.stats.pooledTimerCount = timerPoolSize

    -- Track peak usage
    if activeTimerCount > AceTimer.stats.peakActiveTimers then
        AceTimer.stats.peakActiveTimers = activeTimerCount
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

	local timer = new(self, nil, func, delay, nil, ...)

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

	local timer = new(self, true, func, delay, nil, ...)

	-- Update statistics
	AceTimer.stats.totalTimersCreated = AceTimer.stats.totalTimersCreated + 1
	updateStats()

	return timer
end

--- Schedule a new one-shot non-critical timer.
-- This timer multiplies the delay by a configurable factor for tasks that don't need precise timing.
-- Useful for cosmetic updates, background tasks, or any timer where exact precision isn't critical.
-- @param func Callback function for the timer pulse (funcref or method name).
-- @param delay Base delay for the timer, in seconds (will be multiplied by nonCriticalDelayFactor).
-- @param ... An optional, unlimited amount of arguments to pass to the callback function.
function AceTimer:ScheduleNonCriticalTimer(func, delay, ...)
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

	local timer = new(self, nil, func, delay, { nonCritical = true }, ...)

	-- Update statistics
	AceTimer.stats.totalTimersCreated = AceTimer.stats.totalTimersCreated + 1
	updateStats()

	return timer
end

--- Schedule a named timer that prevents duplicate timers with the same name from being created.
-- If a timer with the same name already exists for this object, the existing timer is returned.
-- This is useful for preventing redundant timer creation, which is a common performance issue.
-- @param name A string identifier for the timer.
-- @param func Callback function for the timer pulse (funcref or method name).
-- @param delay Delay for the timer, in seconds.
-- @param ... An optional, unlimited amount of arguments to pass to the callback function.
-- @return The timer handle of either the existing timer or the newly created one.
-- @usage
-- -- This will only create one timer even if called multiple times
-- self:ScheduleNamedTimer("UpdateUI", "UpdateFunc", 0.1)
-- self:ScheduleNamedTimer("UpdateUI", "UpdateFunc", 0.1) -- Reuses existing timer
function AceTimer:ScheduleNamedTimer(name, func, delay, ...)
    if type(name) ~= "string" then
        error(ERROR_NAMED_TIMER_NAME, 2)
    end

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

    -- Check if a timer with this name already exists
    if namedTimers[self] and namedTimers[self][name] then
        local existingTimer = namedTimers[self][name]

        -- Check if the timer is still active
        if activeTimers[existingTimer] and not existingTimer.cancelled then
            -- Reuse the existing timer
            AceTimer.stats.namedTimerReused = AceTimer.stats.namedTimerReused + 1
            return existingTimer
        end
    end

    -- Create a new timer
    local timer = new(self, nil, func, delay, { name = name }, ...)

    -- Register the timer in the named timers registry
    if not namedTimers[self] then
        namedTimers[self] = {}
    end
    namedTimers[self][name] = timer

    -- Update statistics
    AceTimer.stats.totalTimersCreated = AceTimer.stats.totalTimersCreated + 1
    updateStats()

    return timer
end

--- Schedule a repeating named timer that prevents duplicate timers with the same name.
-- If a timer with the same name already exists for this object, the existing timer is returned.
-- @param name A string identifier for the timer.
-- @param func Callback function for the timer pulse (funcref or method name).
-- @param delay Delay for the timer, in seconds.
-- @param ... An optional, unlimited amount of arguments to pass to the callback function.
-- @return The timer handle of either the existing timer or the newly created one.
function AceTimer:ScheduleRepeatingNamedTimer(name, func, delay, ...)
    if type(name) ~= "string" then
        error(ERROR_NAMED_TIMER_NAME, 2)
    end

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

    -- Check if a timer with this name already exists
    if namedTimers[self] and namedTimers[self][name] then
        local existingTimer = namedTimers[self][name]

        -- Check if the timer is still active
        if activeTimers[existingTimer] and not existingTimer.cancelled then
            -- Reuse the existing timer
            AceTimer.stats.namedTimerReused = AceTimer.stats.namedTimerReused + 1
            return existingTimer
        end
    end

    -- Create a new timer
    local timer = new(self, true, func, delay, { name = name }, ...)

    -- Register the timer in the named timers registry
    if not namedTimers[self] then
        namedTimers[self] = {}
    end
    namedTimers[self][name] = timer

    -- Update statistics
    AceTimer.stats.totalTimersCreated = AceTimer.stats.totalTimersCreated + 1
    updateStats()

    return timer
end

--- Schedule a non-critical named timer that prevents duplicate timers with the same name.
-- If a timer with the same name already exists for this object, the existing timer is returned.
-- Non-critical timers apply the nonCriticalDelayFactor to the delay for less frequent updates.
-- @param name A string identifier for the timer.
-- @param func Callback function for the timer pulse (funcref or method name).
-- @param delay Base delay for the timer, in seconds (will be multiplied by nonCriticalDelayFactor).
-- @param ... An optional, unlimited amount of arguments to pass to the callback function.
-- @return The timer handle of either the existing timer or the newly created one.
function AceTimer:ScheduleNonCriticalNamedTimer(name, func, delay, ...)
    if type(name) ~= "string" then
        error(ERROR_NAMED_TIMER_NAME, 2)
    end

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

    -- Check if a timer with this name already exists
    if namedTimers[self] and namedTimers[self][name] then
        local existingTimer = namedTimers[self][name]

        -- Check if the timer is still active
        if activeTimers[existingTimer] and not existingTimer.cancelled then
            -- Reuse the existing timer
            AceTimer.stats.namedTimerReused = AceTimer.stats.namedTimerReused + 1
            return existingTimer
        end
    end

    -- Create a new timer
    local timer = new(self, nil, func, delay, { name = name, nonCritical = true }, ...)

    -- Register the timer in the named timers registry
    if not namedTimers[self] then
        namedTimers[self] = {}
    end
    namedTimers[self][name] = timer

    -- Update statistics
    AceTimer.stats.totalTimersCreated = AceTimer.stats.totalTimersCreated + 1
    updateStats()

    return timer
end

--- Cancel a named timer by its name.
-- @param name The name of the timer to cancel.
-- @return True if a timer was found and canceled, false otherwise.
function AceTimer:CancelNamedTimer(name)
    if not namedTimers[self] or not namedTimers[self][name] then
        return false
    end

    local timer = namedTimers[self][name]
    local result = self:CancelTimer(timer)

    if result then
        namedTimers[self][name] = nil

        -- Clean up empty tables
        if not next(namedTimers[self]) then
            namedTimers[self] = nil
        end
    end

    return result
end

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
		activeTimerCount = activeTimerCount - 1

        -- Remove from named timers if this is a named timer
        if timer.name and timer.object then
            if namedTimers[timer.object] then
                namedTimers[timer.object][timer.name] = nil
                -- Clean up the object entry if there are no more named timers
                if not next(namedTimers[timer.object]) then
                    namedTimers[timer.object] = nil
                end
            end
        end

        -- Remove from priority queue if applicable
        if AceTimer.highEndConfig.usePriorityQueue then
            for i = 1, #timerHeap do
                if timerHeap[i] == timer then
                    tremove(timerHeap, i)
                    heapUpdate(timerHeap)
                    break
                end
            end
        end

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

	-- Clear named timers for this object
	namedTimers[self] = nil

	-- Force cleanup after canceling multiple timers
	performCleanup()

	-- Update statistics
	updateStats()
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

--- Returns the time left for a named timer.
-- This function will return 0 when the timer name is invalid or the timer doesn't exist.
-- @param name The name of the timer, as used in ScheduleNamedTimer.
-- @return The time left on the timer.
function AceTimer:TimeLeftNamed(name)
    if not namedTimers[self] or not namedTimers[self][name] then
        return 0
    end

    return self:TimeLeft(namedTimers[self][name])
end

--- Check if a method exists before scheduling a timer for it
-- This is a helper function to validate that a method exists before scheduling a timer
-- @param methodName The name of the method to check
-- @return True if the method exists and is callable, false otherwise
function AceTimer:MethodExists(methodName)
    if type(self) ~= "table" or type(methodName) ~= "string" then
        return false
    end
    return type(self[methodName]) == "function"
end

--- Schedule a timer with automatic method existence validation
-- This is a safer version of ScheduleTimer that checks if the method exists first
-- @param func Callback function for the timer pulse (funcref or method name)
-- @param delay Delay for the timer, in seconds
-- @param ... An optional, unlimited amount of arguments to pass to the callback function
-- @return Timer handle if scheduled successfully, nil if the method doesn't exist
function AceTimer:ScheduleSafeTimer(func, delay, ...)
    if not func or not delay then
		error(ERROR_NO_FUNC_DELAY, 2)
	end

	if type(func) == "string" then
		if type(self) ~= "table" then
			error(ERROR_SELF_NOT_TABLE, 2)
		end

		-- Check if the method exists before scheduling
		if not self[func] or type(self[func]) ~= "function" then
		    -- Method doesn't exist, return nil instead of scheduling
		    return nil
		end
	end

	-- Method exists, schedule normally
	return self:ScheduleTimer(func, delay, ...)
end

--- Reset error tracking manually
-- This function can be called to clear the error counters if needed
function AceTimer:ResetErrorTracking()
    resetErrorTracking()
end

--- Configure error handling behavior
-- @param verbose Whether to show detailed error messages with stack traces
-- @param throttle Whether to limit the number of error messages for the same method
-- @param autoSkip Whether to automatically skip execution of missing methods
function AceTimer:ConfigureErrorHandling(verbose, throttle, autoSkip)
    if verbose ~= nil then
        AceTimer.highEndConfig.verboseErrors = verbose
    end

    if throttle ~= nil then
        AceTimer.highEndConfig.errorThrottling = throttle
    end

    if autoSkip ~= nil then
        AceTimer.highEndConfig.autoSkipMissingMethods = autoSkip
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
    ScheduleNonCriticalTimer = AceTimer.ScheduleNonCriticalTimer,
    ScheduleNamedTimer = AceTimer.ScheduleNamedTimer,
    ScheduleRepeatingNamedTimer = AceTimer.ScheduleRepeatingNamedTimer,
    ScheduleNonCriticalNamedTimer = AceTimer.ScheduleNonCriticalNamedTimer,
    CancelTimer = AceTimer.CancelTimer,
    CancelNamedTimer = AceTimer.CancelNamedTimer,
    CancelAllTimers = AceTimer.CancelAllTimers,
    TimeLeft = AceTimer.TimeLeft,
    TimeLeftNamed = AceTimer.TimeLeftNamed
}

-- Pre-allocate array of function names for consistent usage
local mixins = {
	"ScheduleTimer", "ScheduleRepeatingTimer", "ScheduleNonCriticalTimer",
	"ScheduleNamedTimer", "ScheduleRepeatingNamedTimer", "ScheduleNonCriticalNamedTimer",
	"CancelTimer", "CancelNamedTimer", "CancelAllTimers",
	"TimeLeft", "TimeLeftNamed"
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
        nonCriticalDelayFactor = 1.5,  -- Multiply delay for non-critical timers
        lastCleanupTime = GetTime(),   -- Last time cleanup was performed
        useBatchProcessing = true,     -- Process timers in batches to reduce per-frame overhead
        batchInterval = 0.01,          -- How frequently to process timer batches (seconds)
        maxBatchSize = 20,             -- Maximum number of timers to process in a single batch
        usePriorityQueue = true,       -- Use a priority queue to optimize timer sorting
        validateMethodsBeforeCall = true, -- Validate method existence before calling
        autoSkipMissingMethods = true, -- Skip execution of missing methods instead of generating errors
        verboseErrors = false,         -- Show detailed error messages with stack traces
        errorThrottling = true,        -- Prevent excessive error spam from the same timer
        maxErrorsPerMethod = 3         -- Maximum number of errors to show for each method before throttling
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

    -- Reset batch processing
    self:ResetBatchProcessing()

    -- Reset priority queue
    wipe(timerHeap)

    -- Refill priority queue from active timers if enabled
    if AceTimer.highEndConfig.usePriorityQueue then
        for _, timer in pairs(activeTimers) do
            if not timer.cancelled then
                heapInsert(timerHeap, timer)
            end
        end
    end
end

--- Get the current performance statistics
-- @return A table containing performance statistics
function AceTimer:GetPerformanceStats()
    updateStats() -- Update stats before returning
    return AceTimer.stats
end

-- Reset the batch processing configuration
function AceTimer:ResetBatchProcessing()
    -- Stop the current batch processor if it exists
    if batchProcessingTimer then
        batchProcessingTimer:Cancel()
        batchProcessingTimer = nil
        isBatchProcessing = false
    end

    -- Restart if it should be enabled
    if AceTimer.highEndConfig.useBatchProcessing and activeTimerCount > 0 then
        batchProcessingTimer = C_Timer.NewTicker(AceTimer.highEndConfig.batchInterval, processBatchedTimers)
        isBatchProcessing = true
    end
end

-- Configure priority queue settings
function AceTimer:SetPriorityQueueEnabled(enabled)
    AceTimer.highEndConfig.usePriorityQueue = (enabled == true)

    -- Reset the priority queue
    wipe(timerHeap)

    -- Refill queue if enabled
    if AceTimer.highEndConfig.usePriorityQueue then
        for _, timer in pairs(activeTimers) do
            if not timer.cancelled then
                heapInsert(timerHeap, timer)
            end
        end
    end
end

-- Redefine processBatchedTimers with consistent function style
processBatchedTimers = function()
	-- If no active timers, stop the batch processor
	if activeTimerCount == 0 then
		if batchProcessingTimer then
			batchProcessingTimer:Cancel()
			batchProcessingTimer = nil
			isBatchProcessing = false
		end
		return
	end

	local currentTime = GetTime()
	local processed = 0
	local maxToProcess = AceTimer.highEndConfig.maxBatchSize

	-- Process ready timers up to the batch size limit
	if AceTimer.highEndConfig.usePriorityQueue then
	    -- Use the priority queue for efficient timer processing
	    while processed < maxToProcess and #timerHeap > 0 do
	        -- Peek at the top timer without removing it
	        local timer = timerHeap[1]

	        -- If the timer isn't ready yet, break from the loop
	        if timer.ends > currentTime or timer.cancelled then
	            break
	        end

	        -- Extract the timer
	        heapExtract(timerHeap)

	        -- Process the timer
	        if not timer.cancelled then
	            timer.callback()
	        end

	        processed = processed + 1
	    end
	else
    	-- Standard approach - loop through all timers
    	for handle, timer in pairs(activeTimers) do
    		if timer.ends <= currentTime and not timer.cancelled then
    			timer.callback()
    			processed = processed + 1

    			-- Don't process too many timers in one batch to avoid frame lag
    			if processed >= maxToProcess then
    				break
    			end
    		end
    	end
	end

	-- Update the performance statistics
	AceTimer.stats.batchesProcessed = AceTimer.stats.batchesProcessed + 1
	AceTimer.stats.timersProcessedInBatch = AceTimer.stats.timersProcessedInBatch + processed

	-- Occasionally perform cleanup operations
	performCleanup()
end
