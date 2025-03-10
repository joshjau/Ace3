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

local MAJOR, MINOR = "AceTimer-3.0", 25 -- Bump minor on changes
local AceTimer, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceTimer then return end -- No upgrade needed
AceTimer.activeTimers = AceTimer.activeTimers or {} -- Active timer list
local activeTimers = AceTimer.activeTimers -- Upvalue our private data

-- Cache for performance
local timerCache = {}  -- Reuse timer tables to reduce garbage collection
local closureCache = {} -- Reuse closures to reduce garbage collection
AceTimer.timerCache = timerCache -- Store it on the AceTimer table for upgrading
AceTimer.closureCache = closureCache

-- Constants for cache management
local MAX_TIMER_CACHE_SIZE = 200 -- Maximum number of timer tables to keep in cache
local MAX_CLOSURE_CACHE_SIZE = 50 -- Maximum number of closures to keep in cache
local currentTimerCacheSize = 0
local currentClosureCacheSize = 0

-- Lua APIs - cache to local variables for increased performance
local type, unpack, next, error, select, pairs = type, unpack, next, error, select, pairs
local tinsert, tremove, wipe = table.insert, table.remove, table.wipe
local format, tostring = string.format, tostring

-- WoW APIs - also cache heavily used functions
local GetTime, C_TimerAfter, C_TimerNewTimer, C_TimerNewTicker
    = GetTime, C_Timer.After, C_Timer.NewTimer, C_Timer.NewTicker

-- Flag to determine if we're using the newer C_Timer native API (10.0.0+)
local useNativeTimers = C_TimerNewTimer ~= nil and type(C_TimerNewTimer(1, function() end)) == "userdata"

-- Constants - minimum delay supported by the C_Timer API
local MIN_DELAY = 0.01

-- Combat state tracking
local inCombat = false
local normalTimeThreshold = 0.02
local combatTimeThreshold = 0.01

-- Register combat events
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
    else
        inCombat = false
    end
end)

-- Create a pool of timer tables to reduce garbage collection
local function getTimerTable()
    local timer = next(timerCache)
    if timer then
        timerCache[timer] = nil
        currentTimerCacheSize = currentTimerCacheSize - 1
        return timer
    end
    return {}
end

-- Return a timer table to the cache
local function recycleTimerTable(timer)
    if not timer then return end

    -- Only cache if we haven't exceeded our limit
    if currentTimerCacheSize < MAX_TIMER_CACHE_SIZE then
        wipe(timer)
        timerCache[timer] = true
        currentTimerCacheSize = currentTimerCacheSize + 1
    end
    -- Otherwise just let it be garbage collected
end

-- Cache for callbacks to reduce function creation
local function getCachedCallback(timer, isLooping)
    local key = (isLooping and "loop:" or "oneshot:") .. tostring(timer)
    local callback = closureCache[key]
    if callback then
        closureCache[key] = nil
        currentClosureCacheSize = currentClosureCacheSize - 1
        return callback
    end
    return nil
end

-- Add callback to cache
local function recycleCallback(callback, timer, isLooping)
    if not callback or not timer then return end

    if currentClosureCacheSize < MAX_CLOSURE_CACHE_SIZE then
        local key = (isLooping and "loop:" or "oneshot:") .. tostring(timer or "nil")
        closureCache[key] = callback
        currentClosureCacheSize = currentClosureCacheSize + 1
    end
end

-- Cache of frequently accessed time values to reduce GetTime() calls
local timeCache = {
    lastUpdate = 0,
    value = 0,
    threshold = normalTimeThreshold
}

-- Optimized time function that uses caching to reduce GetTime() calls
local function getCachedTime()
    local now = GetTime()

    -- Update the threshold based on combat state
    timeCache.threshold = inCombat and combatTimeThreshold or normalTimeThreshold

    if now - timeCache.lastUpdate > timeCache.threshold then
        timeCache.value = now
        timeCache.lastUpdate = now
    end
    return timeCache.value
end

-- Create a new timer
local function new(self, loop, func, delay, ...)
    if delay < MIN_DELAY then
        delay = MIN_DELAY -- Restrict to the lowest time that the C_Timer API allows us
    end

    local currentTime = getCachedTime()
    local argsCount = select("#", ...)

    local timer = getTimerTable()
    timer.object = self
    timer.func = func
    timer.looping = loop
    timer.argsCount = argsCount
    timer.delay = delay
    timer.ends = currentTime + delay

    -- Store variable arguments
    for i = 1, argsCount do
        timer[i] = select(i, ...)
    end

    -- Check if we should use native timers (10.0.0+)
    if useNativeTimers then
        -- Try to get a cached callback first
        local callback = getCachedCallback(timer, loop)

        if not callback then
            -- Create a new callback if none is cached
            if loop then
                -- For repeating timers, create a callback that runs the function and checks cancellation
                callback = function()
                    if timer.cancelled then return end

                    if type(timer.func) == "string" then
                        timer.object[timer.func](timer.object, unpack(timer, 1, timer.argsCount))
                    else
                        timer.func(unpack(timer, 1, timer.argsCount))
                    end

                    -- Update the ends time for TimeLeft function
                    timer.ends = getCachedTime() + delay
                end
            else
                -- For one-shot timers
                callback = function()
                    if timer.cancelled then return end

                    if type(timer.func) == "string" then
                        timer.object[timer.func](timer.object, unpack(timer, 1, timer.argsCount))
                    else
                        timer.func(unpack(timer, 1, timer.argsCount))
                    end

                    -- Clean up after execution
                    local timerKey = timer.handle or timer
                    if timerKey then activeTimers[timerKey] = nil end
                    recycleTimerTable(timer)
                end
            end
        end

        -- Attach the callback to the timer for later recycling
        timer.callback = callback

        -- Create the timer and store it directly
        if loop then
            timer.nativeTimer = C_TimerNewTicker(delay, callback)
        else
            timer.nativeTimer = C_TimerNewTimer(delay, callback)
        end
    else
        -- Fallback to legacy implementation using C_Timer.After for older clients
        -- Try to get a cached callback first
        local callback = getCachedCallback(timer, false) -- Always use non-looping for C_Timer.After

        if not callback then
            local function callback_fn()
                if not timer.cancelled then
                    if type(timer.func) == "string" then
                        timer.object[timer.func](timer.object, unpack(timer, 1, timer.argsCount))
                    else
                        timer.func(unpack(timer, 1, timer.argsCount))
                    end

                    if timer.looping and not timer.cancelled then
                        local time = getCachedTime()
                        local ndelay = timer.delay - (time - timer.ends)
                        if ndelay < MIN_DELAY then ndelay = MIN_DELAY end
                        C_TimerAfter(ndelay, callback_fn) -- Use the same callback again
                        timer.ends = time + ndelay
                    else
                        local timerKey = timer.handle or timer
                        if timerKey then activeTimers[timerKey] = nil end
                        recycleCallback(callback_fn, timer, false)
                        recycleTimerTable(timer)
                    end
                end
            end
            callback = callback_fn
        end

        -- Store the callback on the timer object for later reference
        timer.callback = callback
        C_TimerAfter(delay, callback)
    end

    activeTimers[timer] = timer
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
        error(MAJOR..": ScheduleTimer(callback, delay, args...): 'callback' and 'delay' must have set values.", 2)
    end
    if type(func) == "string" then
        if type(self) ~= "table" then
            error(MAJOR..": ScheduleTimer(callback, delay, args...): 'self' - must be a table.", 2)
        elseif not self[func] then
            error(MAJOR..": ScheduleTimer(callback, delay, args...): Tried to register '"..func.."' as the callback, but it doesn't exist in the module.", 2)
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
        error(MAJOR..": ScheduleRepeatingTimer(callback, delay, args...): 'callback' and 'delay' must have set values.", 2)
    end
    if type(func) == "string" then
        if type(self) ~= "table" then
            error(MAJOR..": ScheduleRepeatingTimer(callback, delay, args...): 'self' - must be a table.", 2)
        elseif not self[func] then
            error(MAJOR..": ScheduleRepeatingTimer(callback, delay, args...): Tried to register '"..func.."' as the callback, but it doesn't exist in the module.", 2)
        end
    end
    return new(self, true, func, delay, ...)
end

--- Cancels a timer with the given id, registered by the same addon object as used for `:ScheduleTimer`
-- Both one-shot and repeating timers can be canceled with this function, as long as the `id` is valid
-- and the timer has not fired yet or was canceled before.
-- @param id The id of the timer, as returned by `:ScheduleTimer` or `:ScheduleRepeatingTimer`
function AceTimer:CancelTimer(id)
    local timer = activeTimers[id]

    if not timer then
        return false
    else
        timer.cancelled = true

        -- If using native timers, cancel them directly
        if useNativeTimers and timer.nativeTimer then
            timer.nativeTimer:Cancel()
            timer.nativeTimer = nil
        end

        -- Recycle the callback
        if timer and timer.callback then
            recycleCallback(timer.callback, timer, timer.looping)
        end

        activeTimers[id] = nil
        recycleTimerTable(timer)
        return true
    end
end

--- Cancels all timers registered to the current addon object ('self')
function AceTimer:CancelAllTimers()
    -- Optimized version for cancelling multiple timers
    local toCancel = {}

    -- First pass: collect all timers that belong to this object
    for k, v in next, activeTimers do
        if v.object == self then
            tinsert(toCancel, k)
        end
    end

    -- Second pass: cancel them all (prevents issues with table modification during iteration)
    for i = 1, #toCancel do
        AceTimer.CancelTimer(self, toCancel[i])
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
        return timer.ends - getCachedTime()
    end
end

--- Pre-create timer tables to reduce garbage collection during high-stress situations
-- @param count Number of timer tables to pre-cache
-- @return Array of pre-cached timers (for reference only)
function AceTimer:PreCacheTimers(count)
    count = count or 50 -- Default to 50 if no count specified

    -- Pre-create timer tables
    local precached = {}
    for i = 1, count do
        local timer = {}
        timerCache[timer] = true
        currentTimerCacheSize = currentTimerCacheSize + 1
        tinsert(precached, timer)
    end
    return precached
end

--- Set custom thresholds for time caching in and out of combat
-- @param normal Threshold in seconds for normal (out of combat) operations
-- @param combat Threshold in seconds for combat operations
function AceTimer:SetTimeThresholds(normal, combat)
    if type(normal) == "number" and normal > 0 then
        normalTimeThreshold = normal
    end
    if type(combat) == "number" and combat > 0 then
        combatTimeThreshold = combat
    end
end

--- Get cache statistics for debugging/monitoring
-- @return A table with cache statistics
function AceTimer:GetCacheStats()
    return {
        timerCacheSize = currentTimerCacheSize,
        timerCacheMax = MAX_TIMER_CACHE_SIZE,
        closureCacheSize = currentClosureCacheSize,
        closureCacheMax = MAX_CLOSURE_CACHE_SIZE,
        activeTimers = AceTimer:CountActiveTimers(),
        inCombat = inCombat,
        normalThreshold = normalTimeThreshold,
        combatThreshold = combatTimeThreshold,
        usingNativeTimers = useNativeTimers
    }
end

--- Count active timers
-- @return Number of active timers
function AceTimer:CountActiveTimers()
    local count = 0
    for _ in next, activeTimers do
        count = count + 1
    end
    return count
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
                    newTimer = AceTimer.ScheduleRepeatingTimer(timer.object, timer.callback, timer.delay, timer.arg)
                else
                    newTimer = AceTimer.ScheduleTimer(timer.object, timer.callback, timer.when - GetTime(), timer.arg)
                end
                -- Use the old handle for old timers
                activeTimers[newTimer] = nil
                activeTimers[handle] = newTimer
                rawset(newTimer, "handle", handle)
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
        rawset(newTimer, "handle", handle)
    end

    -- Migrate transitional handles
    if oldminor < 13 and AceTimer.hashCompatTable then
        for handle, id in next, AceTimer.hashCompatTable do
            local t = activeTimers[id]
            if t then
                activeTimers[id] = nil
                activeTimers[handle] = t
                rawset(t, "handle", handle)
            end
        end
        AceTimer.hashCompatTable = nil
    end
elseif oldminor and oldminor < 18 then
    -- Upgrade to the optimized implementation
    -- Transfer any cached items from the old version
    if AceTimer.timerCache then
        timerCache = AceTimer.timerCache
    end
    if AceTimer.closureCache then
        closureCache = AceTimer.closureCache
    end
end

-- ---------------------------------------------------------------------
-- Embed handling

AceTimer.embeds = AceTimer.embeds or {}

local mixins = {
    "ScheduleTimer", "ScheduleRepeatingTimer",
    "CancelTimer", "CancelAllTimers",
    "TimeLeft", "PreCacheTimers", "SetTimeThresholds"
}

function AceTimer:Embed(target)
    AceTimer.embeds[target] = true
    for _,v in next, mixins do
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

for addon in next, AceTimer.embeds do
    AceTimer:Embed(addon)
end
