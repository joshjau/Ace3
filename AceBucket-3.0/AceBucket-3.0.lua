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

local MAJOR, MINOR = "AceBucket-3.0", 5
local AceBucket, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceBucket then return end -- No Upgrade needed

-- Upvalued from earlier version
AceBucket.buckets = AceBucket.buckets or {}
AceBucket.embeds = AceBucket.embeds or {}

-- the libraries will be lazyly bound later, to avoid errors due to loading order issues
local AceEvent, AceTimer

-- Lua APIs - extensively cache all used functions for performance
local tconcat, tinsert, tremove, wipe = table.concat, table.insert, table.remove, table.wipe
local type, next, pairs, ipairs, select = type, next, pairs, ipairs, select
local tonumber, tostring, rawset, rawget = tonumber, tostring, rawset, rawget
local assert, error, pcall = assert, error, pcall
local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil
local format, gsub, strfind = string.format, string.gsub, string.find
local band = bit.band

-- WoW APIs
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown

-- Recycled tables cache
local bucketCache = setmetatable({}, {__mode='k'})
local receivedCache = setmetatable({}, {__mode='k'})

-- Combat state tracking for optimizations
local inCombat = false
local combatBuckets = {}

-- Performance tracking
local eventCount = 0
local bucketsFired = 0
local lastResetTime = GetTime()

-- Create a local error handler to avoid creating closures in hot code paths
local errorhandler = geterrorhandler()

-- Safecall implementation
local xpcall = xpcall
local function safeCallHandler(err)
    return errorhandler(err)
end

local function safecall(func, ...)
    if func then
        return xpcall(func, safeCallHandler, ...)
    end
end

-- Get a recycled received table or create a new one
local function getReceivedTable()
    local tbl = next(receivedCache)
    if tbl then
        receivedCache[tbl] = nil
        return tbl
    end
    return {}
end

-- FireBucket ( bucket )
--
-- send the bucket to the callback function and schedule the next FireBucket in interval seconds
local function FireBucket(bucket)
    bucketsFired = bucketsFired + 1
    
    local received = bucket.received
    if not received then return end -- Safety check
    
    -- we dont want to fire empty buckets
    if next(received) ~= nil then
        local callback = bucket.callback
        
        -- Get current combat state
        local inCombatNow = InCombatLockdown()
        
        if type(callback) == "string" then
            safecall(bucket.object[callback], bucket.object, received)
        else
            safecall(callback, received)
        end

        -- Recycle the received table instead of clearing it in place
        -- This helps avoid memory fragmentation
        local oldReceived = bucket.received
        bucket.received = getReceivedTable()
        
        -- Clear and cache the old table
        wipe(oldReceived)
        receivedCache[oldReceived] = true
        
        -- Adjust interval based on combat status if needed
        local interval = bucket.interval
        if inCombatNow and bucket.combatInterval then
            interval = bucket.combatInterval
        end

        -- if the bucket was not empty, schedule another FireBucket in interval seconds
        bucket.timer = AceTimer.ScheduleTimer(bucket, FireBucket, interval, bucket)
    else -- if it was empty, clear the timer and wait for the next event
        bucket.timer = nil
    end
end

-- BucketHandler ( event, arg1 )
--
-- callback func for AceEvent
-- stores arg1 in the received table, and schedules the bucket if necessary
local function BucketHandler(self, event, arg1)
    if not self or not self.received then return end -- Safety check
    
    eventCount = eventCount + 1
    
    if (eventCount % 10000) == 0 then
        -- Periodically report metrics if enabled
        if AceBucket.debugMode then
            local currentTime = GetTime()
            local elapsed = currentTime - lastResetTime
            print(format("AceBucket-3.0: Processed %d events, fired %d buckets in %.2f seconds", 
                  eventCount, bucketsFired, elapsed))
            eventCount, bucketsFired = 0, 0
            lastResetTime = currentTime
        end
    end
    
    if arg1 == nil then
        arg1 = "nil"
    end

    self.received[arg1] = (self.received[arg1] or 0) + 1

    -- if we are not scheduled yet, start a timer on the interval for our bucket to be cleared
    if not self.timer then
        -- Use combat interval if we're in combat and it's specified
        local interval = self.interval
        if interval and InCombatLockdown() and self.combatInterval then
            interval = self.combatInterval
        end
        
        self.timer = AceTimer.ScheduleTimer(self, FireBucket, interval, self)
    end
end

-- RegisterBucket( event, interval, callback, isMessage )
--
-- event(string or table) - the event, or a table with the events, that this bucket listens to
-- interval(int) - time between bucket fireings
-- callback(func or string) - function pointer, or method name of the object, that gets called when the bucket is cleared
-- isMessage(boolean) - register AceEvent Messages instead of game events
-- options(table) - optional table with additional settings: combatInterval, combatPriority
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

    local bucket = next(bucketCache)
    if bucket then
        bucketCache[bucket] = nil
        -- Clean the bucket object to ensure no old data remains
        for k in pairs(bucket) do
            if k ~= "handler" then -- Keep the handler function
                bucket[k] = nil
            end
        end
    else
        bucket = { handler = BucketHandler }
    end
    
    -- Initialize or recycle the received table
    bucket.received = getReceivedTable()
    
    -- Set main properties
    bucket.object = self
    bucket.callback = callback
    bucket.interval = tonumber(interval)
    
    -- Set combat-specific options if provided
    if options then
        if options.combatInterval then
            bucket.combatInterval = tonumber(options.combatInterval)
        end
        if options.combatPriority then
            bucket.combatPriority = (options.combatPriority == true)
            if bucket.combatPriority then
                combatBuckets[bucket] = true
            end
        end
    end

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

    return handle
end

--- Register a Bucket for an event (or a set of events)
-- @param event The event to listen for, or a table of events.
-- @param interval The Bucket interval (burst interval)
-- @param callback The callback function, either as a function reference, or a string pointing to a method of the addon object.
-- @param options Optional table with additional settings: combatInterval, combatPriority
-- @return The handle of the bucket (for unregistering)
-- @usage
-- MyAddon = LibStub("AceAddon-3.0"):NewAddon("MyAddon", "AceBucket-3.0")
-- MyAddon:RegisterBucketEvent("BAG_UPDATE", 0.2, "UpdateBags")
--
-- -- Advanced usage with combat optimizations
-- MyAddon:RegisterBucketEvent("UNIT_AURA", 0.5, "ProcessAuras", {
--   combatInterval = 0.1,  -- Update more frequently in combat
--   combatPriority = true  -- Mark as high priority during combat
-- })
--
-- function MyAddon:UpdateBags()
--   -- do stuff
-- end
function AceBucket:RegisterBucketEvent(event, interval, callback, options)
    return RegisterBucket(self, event, interval, callback, false, options)
end

--- Register a Bucket for an AceEvent-3.0 addon message (or a set of messages)
-- @param message The message to listen for, or a table of messages.
-- @param interval The Bucket interval (burst interval)
-- @param callback The callback function, either as a function reference, or a string pointing to a method of the addon object.
-- @param options Optional table with additional settings: combatInterval, combatPriority
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

--- Unregister any events and messages from the bucket and clear any remaining data.
-- @param handle The handle of the bucket as returned by RegisterBucket*
function AceBucket:UnregisterBucket(handle)
    local bucket = AceBucket.buckets[handle]
    if bucket then
        AceEvent.UnregisterAllEvents(bucket)
        AceEvent.UnregisterAllMessages(bucket)

        -- Remove from combat buckets if present
        if bucket.combatPriority then
            combatBuckets[bucket] = nil
        end

        -- Recycle the received table instead of just clearing it
        local oldReceived = bucket.received
        if oldReceived then
            wipe(oldReceived)
            receivedCache[oldReceived] = true
            bucket.received = nil
        end

        if bucket.timer then
            AceTimer.CancelTimer(bucket, bucket.timer)
            bucket.timer = nil
        end

        AceBucket.buckets[handle] = nil
        -- store our bucket in the cache
        bucketCache[bucket] = true
    end
end

--- Unregister all buckets of the current addon object (or custom "self").
function AceBucket:UnregisterAllBuckets()
    for handle, bucket in pairs(AceBucket.buckets) do
        if bucket.object == self then
            AceBucket.UnregisterBucket(self, handle)
        end
    end
end

--- Set the interval of a bucket.
-- @param handle The handle of the bucket as returned by RegisterBucket*
-- @param interval The new interval for the bucket (burst interval)
-- @param combatInterval Optional combat-specific interval
function AceBucket:SetBucketInterval(handle, interval, combatInterval)
    local bucket = AceBucket.buckets[handle]
    if bucket then
        bucket.interval = tonumber(interval)
        if combatInterval then
            bucket.combatInterval = tonumber(combatInterval)
        end
    end
end

--- Enable or disable debug mode for performance metrics
-- @param enable Boolean to enable or disable debugging
function AceBucket:SetDebugMode(enable)
    AceBucket.debugMode = (enable == true)
    eventCount, bucketsFired = 0, 0
    lastResetTime = GetTime()
end

-- Combat optimization handlers
local function OnEnterCombat()
    inCombat = true
    -- Optionally adjust intervals for combat-specific buckets
    for bucket in pairs(combatBuckets) do
        if bucket.timer and bucket.combatInterval then
            -- Cancel and reschedule with combat interval
            AceTimer.CancelTimer(bucket, bucket.timer)
            bucket.timer = AceTimer.ScheduleTimer(bucket, FireBucket, bucket.combatInterval, bucket)
        end
    end
end

local function OnLeaveCombat()
    inCombat = false
    -- Reset intervals for combat-specific buckets
    for bucket in pairs(combatBuckets) do
        if bucket.timer and bucket.combatInterval then
            -- Cancel and reschedule with normal interval
            AceTimer.CancelTimer(bucket, bucket.timer)
            bucket.timer = AceTimer.ScheduleTimer(bucket, FireBucket, bucket.interval, bucket)
        end
    end
end

-- Register for combat events to enable combat-specific optimizations
local function InitializeCombatOptimization()
    -- Only initialize once
    if not AceBucket.combatInitialized then
        local combatFrame = CreateFrame("Frame")
        combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
        combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        combatFrame:SetScript("OnEvent", function(self, event)
            if event == "PLAYER_REGEN_DISABLED" then
                OnEnterCombat()
            elseif event == "PLAYER_REGEN_ENABLED" then
                OnLeaveCombat()
            end
        end)
        
        -- Initialize current combat state
        inCombat = InCombatLockdown()
        AceBucket.combatInitialized = true
    end
end

-- embedding and embed handling
local mixins = {
    "RegisterBucketEvent",
    "RegisterBucketMessage",
    "UnregisterBucket",
    "UnregisterAllBuckets",
    "SetBucketInterval",
    "SetDebugMode",
}

-- Embeds AceBucket into the target object making the functions from the mixins list available on target:..
-- @param target target object to embed AceBucket in
function AceBucket:Embed(target)
    for _, v in pairs(mixins) do
        target[v] = self[v]
    end
    self.embeds[target] = true
    
    -- Initialize combat optimization
    InitializeCombatOptimization()
    
    return target
end

function AceBucket:OnEmbedDisable(target)
    target:UnregisterAllBuckets()
end

-- Initialize combat tracking if loaded directly
InitializeCombatOptimization()

for addon in pairs(AceBucket.embeds) do
    AceBucket:Embed(addon)
end
