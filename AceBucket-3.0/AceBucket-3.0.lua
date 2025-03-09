--- A bucket to catch events in. **AceBucket-3.0** provides throttling of events that fire in bursts and
-- your addon only needs to know about the full burst.
--
-- This Bucket implementation works as follows:\\
--   Initially, no schedule is running, and its waiting for the first event to happen.\\
--   The first event will start the bucket, and get the scheduler running, which will collect all
--   events in the given interval. When that interval is reached, the bucket is pushed to the
--   callback and a new schedule is started. When a bucket is empty after its interval, the scheduler is
--   stopped, and the bucket is only listening for the next event to happen, basically back in its initial state.
--
-- In addition, the buckets collect information about the "arg1" argument of the events that fire, and pass those as a
-- table to your callback. This functionality was mostly designed for the UNIT_* events.\\
-- The table will have the different values of "arg1" as keys, and the number of occurances as their value, e.g.\\
--   { ["player"] = 2, ["target"] = 1, ["party1"] = 1 }
--
-- **AceBucket-3.0** can be embeded into your addon, either explicitly by calling AceBucket:Embed(MyAddon) or by
-- specifying it as an embeded library in your AceAddon. All functions will be available on your addon object
-- and can be accessed directly, without having to explicitly call AceBucket itself.\\
-- It is recommended to embed AceBucket, otherwise you'll have to specify a custom `self` on all calls you
-- make into AceBucket.
-- @usage
-- MyAddon = LibStub("AceAddon-3.0"):NewAddon("BucketExample", "AceBucket-3.0")
--
-- function MyAddon:OnEnable()
--   -- Register a bucket that listens to all the HP related events,
--   -- and fires once per second
--   self:RegisterBucketEvent({"UNIT_HEALTH", "UNIT_MAXHEALTH"}, 1, "UpdateHealth")
-- end
--
-- function MyAddon:UpdateHealth(units)
--   if units.player then
--     print("Your HP changed!")
--   end
-- end
-- @class file
-- @name AceBucket-3.0.lua
-- @release $Id$

local MAJOR, MINOR = "AceBucket-3.0", 6 -- Bumped minor version
local AceBucket, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceBucket then return end -- No Upgrade needed

AceBucket.buckets = AceBucket.buckets or {}
AceBucket.embeds = AceBucket.embeds or {}
AceBucket.highPriorityBuckets = AceBucket.highPriorityBuckets or {}
AceBucket.stats = AceBucket.stats or {
    totalEvents = 0,
    totalFires = 0,
    lastGCTime = 0,
    avgProcessTime = 0
}

-- the libraries will be lazyly bound later, to avoid errors due to loading order issues
local AceEvent, AceTimer

-- Lua APIs
local tconcat = table.concat
local tinsert, tremove, tcopy = table.insert, table.remove, table.wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
local type, next, pairs, select, ipairs = type, next, pairs, select, ipairs
local tonumber, tostring, rawset, rawget = tonumber, tostring, rawset, rawget
local assert, error = assert, error
local ceil, floor, min, max = math.ceil, math.floor, math.min, math.max
local GetTime = GetTime

-- WoW retail APIs
local C_Timer_After = C_Timer and C_Timer.After

-- Configuration constants
local MAX_BUCKET_SIZE = 1000 -- Maximum number of entries to store in a single bucket
local MAX_EVENT_FREQUENCY = 10000 -- Events per second threshold before throttling
local BUCKET_POOL_SIZE = 50 -- Maximum number of buckets to keep in cache
local GC_INTERVAL = 60 -- Time in seconds between garbage collection checks

-- Reusable tables to reduce GC pressure
local bucketCache = setmetatable({}, {__mode='k'})
local tablePools = {}
local receivedPool = setmetatable({}, {__mode='k'})

-- Performance tracking
local lastEventTime = 0
local eventCounter = 0

-- Get a table from the pool or create a new one
local function AcquireTable()
    local t = next(tablePools)
    if t then
        tablePools[t] = nil
        return t
    end
    return {}
end

-- Release a table back to the pool
local function ReleaseTable(t)
    if type(t) ~= "table" then return end
    tcopy(t)
    tablePools[t] = true
end

--[[
     xpcall safecall implementation
]]
local xpcall = xpcall

local function errorhandler(err)
    return geterrorhandler()(err)
end

local function safecall(func, ...)
    if func then
        return xpcall(func, errorhandler, ...)
    end
end

-- Track performance of bucket processing
local function TrackPerformance(bucket, startTime)
    if not bucket then return end
    
    local elapsedTime = GetTime() - startTime
    AceBucket.stats.totalFires = AceBucket.stats.totalFires + 1
    
    -- Update average processing time with weighted average
    local oldAvg = AceBucket.stats.avgProcessTime
    local fireCount = AceBucket.stats.totalFires
    AceBucket.stats.avgProcessTime = oldAvg + (elapsedTime - oldAvg) / fireCount
    
    -- Store processing time on the bucket for adaptive throttling
    bucket.lastProcessTime = elapsedTime
    
    -- Throttle if processing is taking too long
    if elapsedTime > 0.016 and bucket.throttleLevel == nil then  -- More than ~1ms
        bucket.throttleLevel = 1
    elseif elapsedTime > 0.033 and bucket.throttleLevel ~= nil then  -- More than ~2ms
        bucket.throttleLevel = min((bucket.throttleLevel or 0) + 1, 3)
    elseif elapsedTime < 0.008 and bucket.throttleLevel ~= nil then
        bucket.throttleLevel = max((bucket.throttleLevel or 1) - 0.5, 0)
        if bucket.throttleLevel == 0 then bucket.throttleLevel = nil end
    end
end

-- FireBucket ( bucket )
--
-- send the bucket to the callback function and schedule the next FireBucket in interval seconds
local function FireBucket(bucket)
    if not bucket then return end
    
    local received = bucket.received
    if not received then return end
    
    -- we dont want to fire empty buckets
    if next(received) ~= nil then
        local startTime = GetTime()
        local callback = bucket.callback
        
        -- Create a copy of the received table to pass to the callback
        -- This allows the callback to keep the data if needed
        local callbackData = AcquireTable()
        for k, v in pairs(received) do
            callbackData[k] = v
        end
        
        if type(callback) == "string" then
            safecall(bucket.object[callback], bucket.object, callbackData)
        else
            safecall(callback, callbackData)
        end
        
        -- If the callback doesn't store the data, release it back to pool
        if not bucket.keepCallbackData then
            ReleaseTable(callbackData)
        end
        
        -- Track performance
        TrackPerformance(bucket, startTime)
        
        -- Clear the received table for reuse instead of creating a new one
        tcopy(received)
        
        -- Apply adaptive throttling if needed
        local interval = bucket.interval
        if bucket.throttleLevel then
            -- Increase interval based on throttling level
            interval = interval * (1 + bucket.throttleLevel * 0.2)
        end
        
        -- Check if we should skip scheduling (for C_Timer that can't be canceled)
        if bucket.skipNextScheduledFire then
            bucket.skipNextScheduledFire = nil
            bucket.timer = nil
            return
        end
        
        -- if the bucket was not empty, schedule another FireBucket in interval seconds
        if C_Timer_After and not bucket.forceAceTimer then
            bucket.timer = C_Timer_After(interval, function() FireBucket(bucket) end)
        else
            bucket.timer = AceTimer.ScheduleTimer(bucket, FireBucket, interval, bucket)
        end
    else -- if it was empty, clear the timer and wait for the next event
        bucket.timer = nil
    end
end

-- Quick debounce check to reduce event processing during frame drops
local function ShouldProcessEvent()
    local now = GetTime()
    local timeDiff = now - lastEventTime
    
    if timeDiff < 0.001 then
        eventCounter = eventCounter + 1
        if eventCounter > MAX_EVENT_FREQUENCY then
            return false
        end
    else
        lastEventTime = now
        eventCounter = 1
    end
    
    return true
end

-- BucketHandler ( event, arg1 )
--
-- callback func for AceEvent
-- stores arg1 in the received table, and schedules the bucket if necessary
local function BucketHandler(self, event, arg1, ...)
    -- Track total event count
    AceBucket.stats.totalEvents = AceBucket.stats.totalEvents + 1
    
    -- High frequency event throttling
    if not ShouldProcessEvent() and not self.highPriority then
        return
    end
    
    -- Set default value for nil args
    if arg1 == nil then
        arg1 = "nil"
    end
    
    -- Store event data
    local received = self.received
    received[arg1] = (received[arg1] or 0) + 1
    
    -- Store additional args if bucket is configured to collect them
    if self.collectAllArgs and select(1, ...) ~= nil then
        if not received.__extraArgs then 
            received.__extraArgs = AcquireTable()
        end
        
        local extraArgs = received.__extraArgs
        local argKey = tostring(arg1)
        if not extraArgs[argKey] then
            extraArgs[argKey] = AcquireTable()
        end
        
        local argList = extraArgs[argKey]
        local argEntry = AcquireTable()
        local n = select("#", ...)
        for i = 1, n do
            argEntry[i] = select(i, ...)
        end
        tinsert(argList, argEntry)
        
        -- Limit bucket size to prevent memory issues
        if #argList > MAX_BUCKET_SIZE then
            local oldestEntry = tremove(argList, 1)
            ReleaseTable(oldestEntry)
        end
    end
    
    -- Limit bucket size to prevent memory issues
    if received[arg1] > MAX_BUCKET_SIZE and arg1 ~= "nil" then
        received[arg1] = MAX_BUCKET_SIZE
    end
    
    -- if we are not scheduled yet, start a timer on the interval for our bucket to be cleared
    if not self.timer then
        if self.highPriority and C_Timer_After and not self.forceAceTimer then
            self.timer = C_Timer_After(self.interval, function() FireBucket(self) end)
        else
            self.timer = AceTimer.ScheduleTimer(self, FireBucket, self.interval, self)
        end
    end
    
    -- For immediate mode buckets, fire right away if a threshold is reached
    if self.immediate and received[arg1] >= self.immediateThreshold then
        if self.timer then
            if not self.forceAceTimer and C_Timer_After then
                -- No direct way to cancel C_Timer, so we just let it expire
                -- and set a flag to prevent double firing
                self.skipNextScheduledFire = true
            else
                AceTimer.CancelTimer(self, self.timer)
            end
            self.timer = nil
        end
        FireBucket(self)
    end
end

-- Periodically clean up unused tables to reduce memory footprint
local function PerformGarbageCollection()
    local now = GetTime()
    
    -- Only run GC periodically
    if now - AceBucket.stats.lastGCTime < GC_INTERVAL then
        return
    end
    
    AceBucket.stats.lastGCTime = now
    
    -- Trim the table pools if they've grown too large
    local tableCount = 0
    for _ in pairs(tablePools) do
        tableCount = tableCount + 1
    end
    
    if tableCount > BUCKET_POOL_SIZE * 2 then
        local removed = 0
        for t in pairs(tablePools) do
            tablePools[t] = nil
            removed = removed + 1
            if removed >= tableCount - BUCKET_POOL_SIZE then
                break
            end
        end
    end
    
    -- Schedule next garbage collection
    if C_Timer_After then
        C_Timer_After(GC_INTERVAL, PerformGarbageCollection)
    else
        AceTimer.ScheduleTimer(AceBucket, PerformGarbageCollection, GC_INTERVAL)
    end
end

-- RegisterBucket( event, interval, callback, isMessage, options )
--
-- event(string or table) - the event, or a table with the events, that this bucket listens to
-- interval(int) - time between bucket fireings
-- callback(func or string) - function pointer, or method name of the object, that gets called when the bucket is cleared
-- isMessage(boolean) - register AceEvent Messages instead of game events
-- options(table) - optional table with additional settings:
--   highPriority(boolean) - bucket should use C_Timer directly for more responsive firing
--   immediate(boolean) - bucket should fire immediately when threshold is reached
--   immediateThreshold(int) - threshold to trigger immediate firing (default: 10)
--   collectAllArgs(boolean) - collect all event args, not just arg1
--   forceAceTimer(boolean) - force using AceTimer even when C_Timer is available
--   keepCallbackData(boolean) - if true, don't release the callbackData table after callback
local function RegisterBucket(self, event, interval, callback, isMessage, options)
    -- try to fetch the librarys
    if not AceEvent or not AceTimer then
        AceEvent = LibStub:GetLibrary("AceEvent-3.0", true)
        AceTimer = LibStub:GetLibrary("AceTimer-3.0", true)
        if not AceEvent or not AceTimer then
            error(MAJOR .. " requires AceEvent-3.0 and AceTimer-3.0", 3)
        end
    end

    if type(event) ~= "string" and type(event) ~= "table" then error("Usage: RegisterBucket(event, interval, callback): 'event' - string or table expected.", 3) end
    if not callback then
        if type(event) == "string" then
            callback = event
        else
            error("Usage: RegisterBucket(event, interval, callback): cannot omit callback when event is not a string.", 3)
        end
    end
    if not tonumber(interval) then error("Usage: RegisterBucket(event, interval, callback): 'interval' - number expected.", 3) end
    if type(callback) ~= "string" and type(callback) ~= "function" then error("Usage: RegisterBucket(event, interval, callback): 'callback' - string or function or nil expected.", 3) end
    if type(callback) == "string" and type(self[callback]) ~= "function" then error("Usage: RegisterBucket(event, interval, callback): 'callback' - method not found on target object.", 3) end

    options = options or {}
    
    -- Reuse a bucket from the cache if available
    local bucket = next(bucketCache)
    if bucket then
        bucketCache[bucket] = nil
        -- Clear any existing fields
        for k in pairs(bucket) do
            bucket[k] = nil
        end
    else
        bucket = { handler = BucketHandler }
    end
    
    -- Use a pooled received table or create a new one
    local received = next(receivedPool)
    if received then
        receivedPool[received] = nil
    else
        received = {}
    end
    
    bucket.received = received
    bucket.object = self
    bucket.callback = callback
    bucket.interval = tonumber(interval)
    bucket.highPriority = options.highPriority
    bucket.immediate = options.immediate
    bucket.immediateThreshold = options.immediateThreshold or 10
    bucket.collectAllArgs = options.collectAllArgs
    bucket.forceAceTimer = options.forceAceTimer
    bucket.keepCallbackData = options.keepCallbackData
    
    local regFunc = isMessage and AceEvent.RegisterMessage or AceEvent.RegisterEvent

    if type(event) == "table" then
        for _,e in pairs(event) do
            regFunc(bucket, e, "handler")
        end
    else
        regFunc(bucket, event, "handler")
    end

    local handle = tostring(bucket)
    AceBucket.buckets[handle] = bucket
    
    -- Track high priority buckets for easier access
    if bucket.highPriority then
        AceBucket.highPriorityBuckets[handle] = true
    end
    
    -- Start garbage collection timer if not already running
    if GetTime() - AceBucket.stats.lastGCTime > GC_INTERVAL then
        AceBucket.stats.lastGCTime = GetTime()
        if C_Timer_After then
            C_Timer_After(GC_INTERVAL, PerformGarbageCollection)
        else
            AceTimer.ScheduleTimer(AceBucket, PerformGarbageCollection, GC_INTERVAL)
        end
    end

    return handle
end

--- Register a Bucket for an event (or a set of events)
-- @param event The event to listen for, or a table of events.
-- @param interval The Bucket interval (burst interval)
-- @param callback The callback function, either as a function reference, or a string pointing to a method of the addon object.
-- @param options Optional table of advanced configuration options (see RegisterPriorityBucket)
-- @return The handle of the bucket (for unregistering)
-- @usage
-- MyAddon = LibStub("AceAddon-3.0"):NewAddon("MyAddon", "AceBucket-3.0")
-- MyAddon:RegisterBucketEvent("BAG_UPDATE", 0.2, "UpdateBags")
--
-- function MyAddon:UpdateBags()
--   -- do stuff
-- end
function AceBucket:RegisterBucketEvent(event, interval, callback, options)
    return RegisterBucket(self, event, interval, callback, false, options)
end

--- Register a high priority Bucket for an event (or a set of events)
-- @param event The event to listen for, or a table of events.
-- @param interval The Bucket interval (burst interval)
-- @param callback The callback function, either as a function reference, or a string pointing to a method of the addon object.
-- @param options Optional table of advanced configuration options:
--   - immediate(boolean) - bucket should fire immediately when threshold is reached
--   - immediateThreshold(int) - threshold to trigger immediate firing (default: 10)
--   - collectAllArgs(boolean) - collect all event args, not just arg1
--   - forceAceTimer(boolean) - force using AceTimer even when C_Timer is available
-- @return The handle of the bucket (for unregistering)
-- @usage
-- MyAddon = LibStub("AceAddon-3.0"):NewAddon("MyAddon", "AceBucket-3.0")
-- MyAddon:RegisterPriorityBucketEvent("COMBAT_LOG_EVENT_UNFILTERED", 0.1, "ProcessCombatLog", {immediate=true})
--
-- function MyAddon:ProcessCombatLog(events)
--   -- prioritized processing
-- end
function AceBucket:RegisterPriorityBucketEvent(event, interval, callback, options)
    options = options or {}
    options.highPriority = true
    return RegisterBucket(self, event, interval, callback, false, options)
end

--- Register a Bucket for an AceEvent-3.0 addon message (or a set of messages)
-- @param message The message to listen for, or a table of messages.
-- @param interval The Bucket interval (burst interval)
-- @param callback The callback function, either as a function reference, or a string pointing to a method of the addon object.
-- @param options Optional table of advanced configuration options (see RegisterPriorityBucket)
-- @return The handle of the bucket (for unregistering)
-- @usage
-- MyAddon = LibStub("AceAddon-3.0"):NewAddon("MyAddon", "AceBucket-3.0")
-- MyAddon:RegisterBucketMessage("SomeAddon_InformationMessage", 0.2, "ProcessData")
--
-- function MyAddon:ProcessData()
--   -- do stuff
-- end
function AceBucket:RegisterBucketMessage(message, interval, callback, options)
    return RegisterBucket(self, message, interval, callback, true, options)
end

--- Register a high priority Bucket for an AceEvent-3.0 addon message (or a set of messages)
-- @param message The message to listen for, or a table of messages.
-- @param interval The Bucket interval (burst interval)
-- @param callback The callback function, either as a function reference, or a string pointing to a method of the addon object.
-- @param options Optional table of advanced configuration options (see RegisterPriorityBucket)
-- @return The handle of the bucket (for unregistering)
function AceBucket:RegisterPriorityBucketMessage(message, interval, callback, options)
    options = options or {}
    options.highPriority = true
    return RegisterBucket(self, message, interval, callback, true, options)
end

--- Unregister any events and messages from the bucket and clear any remaining data.
-- @param handle The handle of the bucket as returned by RegisterBucket*
function AceBucket:UnregisterBucket(handle)
    local bucket = AceBucket.buckets[handle]
    if bucket then
        AceEvent.UnregisterAllEvents(bucket)
        AceEvent.UnregisterAllMessages(bucket)

        -- clear any remaining data in the bucket
        local received = bucket.received
        if received.__extraArgs then
            for _, argList in pairs(received.__extraArgs) do
                for _, entry in ipairs(argList) do
                    ReleaseTable(entry)
                end
                ReleaseTable(argList)
            end
            ReleaseTable(received.__extraArgs)
        end
        
        -- Clear the received table and return it to the pool
        tcopy(received)
        receivedPool[received] = true
        bucket.received = nil

        if bucket.timer then
            if not bucket.forceAceTimer and C_Timer_After and type(bucket.timer) ~= "number" then
                -- Can't cancel C_Timer directly, but we can set a flag
                bucket.skipNextScheduledFire = true
            else
                AceTimer.CancelTimer(bucket, bucket.timer)
            end
            bucket.timer = nil
        end

        -- Remove from high priority tracking if needed
        if bucket.highPriority then
            AceBucket.highPriorityBuckets[handle] = nil
        end
        
        AceBucket.buckets[handle] = nil
        
        -- store our bucket in the cache
        if next(bucketCache) == nil or bucket ~= next(bucketCache) then
            bucketCache[bucket] = true
        end
    end
end

--- Unregister all buckets of the current addon object (or custom "self").
function AceBucket:UnregisterAllBuckets()
    -- Collect handles first to avoid iterator invalidation
    local handles = {}
    for handle, bucket in pairs(AceBucket.buckets) do
        if bucket.object == self then
            handles[#handles + 1] = handle
        end
    end
    
    -- Now unregister all collected buckets
    for _, handle in ipairs(handles) do
        AceBucket:UnregisterBucket(handle)
    end
end

--- Get performance statistics for all buckets
-- @return A table containing performance statistics
function AceBucket:GetPerformanceStats()
    -- Copy stats to avoid external modification
    local stats = {}
    for k, v in pairs(AceBucket.stats) do
        stats[k] = v
    end
    
    -- Add bucket count
    local bucketCount = 0
    for _ in pairs(AceBucket.buckets) do
        bucketCount = bucketCount + 1
    end
    stats.bucketCount = bucketCount
    
    -- Add high priority bucket count
    local highPriorityCount = 0
    for _ in pairs(AceBucket.highPriorityBuckets) do
        highPriorityCount = highPriorityCount + 1
    end
    stats.highPriorityCount = highPriorityCount
    
    return stats
end

--- Reset performance statistics
function AceBucket:ResetPerformanceStats()
    AceBucket.stats.totalEvents = 0
    AceBucket.stats.totalFires = 0
    AceBucket.stats.avgProcessTime = 0
end

--- Apply optimizations to high-traffic buckets
-- This function analyzes all registered buckets and applies optimizations
-- to those that are receiving a high volume of events.
function AceBucket:OptimizeBuckets()
    for handle, bucket in pairs(AceBucket.buckets) do
        -- Check processing time and event volume
        if bucket.lastProcessTime and bucket.lastProcessTime > 0.008 then
            -- Make it high priority if it's not already
            if not bucket.highPriority then
                bucket.highPriority = true
                AceBucket.highPriorityBuckets[handle] = true
            end
            
            -- Increase interval slightly for extremely heavy buckets
            if bucket.lastProcessTime > 0.016 and not bucket.intervalAdjusted then
                bucket.interval = bucket.interval * 1.25
                bucket.intervalAdjusted = true
            end
        end
    end
    
    return true
end

-- embedding and embed handling
local mixins = {
    "RegisterBucketEvent",
    "RegisterBucketMessage",
    "RegisterPriorityBucketEvent",
    "RegisterPriorityBucketMessage",
    "UnregisterBucket",
    "UnregisterAllBuckets",
    "GetPerformanceStats",
    "ResetPerformanceStats",
    "OptimizeBuckets"
}

-- Embeds AceBucket into the target object making the functions from the mixins list available on target:..
-- @param target target object to embed AceBucket in
function AceBucket:Embed(target)
    for _, v in pairs(mixins) do
        target[v] = self[v]
    end
    self.embeds[target] = true
    return target
end

function AceBucket:OnEmbedDisable(target)
    target:UnregisterAllBuckets()
end

for addon in pairs(AceBucket.embeds) do
    AceBucket:Embed(addon)
end
