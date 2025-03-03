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

local MAJOR, MINOR = "AceBucket-3.0", 5  -- Bumped minor version from 4 to 5 for performance optimizations
local AceBucket, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceBucket then return end -- No Upgrade needed

AceBucket.buckets = AceBucket.buckets or {}
AceBucket.embeds = AceBucket.embeds or {}

-- the libraries will be lazyly bound later, to avoid errors due to loading order issues
local AceEvent, AceTimer

-- Lua APIs - Localize all frequently used functions for performance
local tconcat = table.concat
local tinsert, tremove, twipe = table.insert, table.remove, table.wipe
local type, next, pairs, ipairs, select = type, next, pairs, ipairs, select
local tonumber, tostring, rawset, rawget = tonumber, tostring, rawset, rawget
local assert, error = assert, error
local format, strfind, strsub = string.format, string.find, string.sub
local floor, ceil, abs = math.floor, math.ceil, math.abs
local min, max = math.min, math.max
local GetTime = GetTime

-- WoW API - Localize for performance
local C_Timer = C_Timer

-- String pool for common strings to reduce memory fragmentation
local stringPool = setmetatable({}, {__mode = "k"})
local function poolString(str)
    if not str then return nil end
    if not stringPool[str] then
        stringPool[str] = str
    end
    return stringPool[str]
end

-- Table recycling for bucket data
local bucketCache = setmetatable({}, {__mode = 'k'})
local receivedCache = setmetatable({}, {__mode = 'k'})

-- Get a clean table from cache or create a new one
local function getReceivedTable()
    local tbl = next(receivedCache)
    if tbl then
        receivedCache[tbl] = nil
    else
        tbl = {}
    end
    return tbl
end

-- Release a table back to the cache
local function releaseReceivedTable(tbl)
    if not tbl then return end
    twipe(tbl)
    receivedCache[tbl] = true
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

-- FireBucket ( bucket )
--
-- send the bucket to the callback function and schedule the next FireBucket in interval seconds
local function FireBucket(bucket)
    local received = bucket.received

    -- we dont want to fire empty buckets
    if next(received) ~= nil then
        local callback = bucket.callback
        local object = bucket.object

        -- Call the callback with the received data
        if type(callback) == "string" then
            safecall(object[callback], object, received)
        else
            safecall(callback, received)
        end

        -- Clear the received table for reuse instead of creating a new one
        twipe(received)

        -- If using C_Timer is available and enabled, use it for more precise timing
        if C_Timer and bucket.useNewTimer then
            bucket.timer = C_Timer.NewTimer(bucket.interval, function() FireBucket(bucket) end)
        else
            -- Otherwise fall back to AceTimer
            bucket.timer = AceTimer.ScheduleTimer(bucket, FireBucket, bucket.interval, bucket)
        end
    else -- if it was empty, clear the timer and wait for the next event
        bucket.timer = nil
    end
end

-- BucketHandler ( event, arg1 )
--
-- callback func for AceEvent
-- stores arg1 in the received table, and schedules the bucket if necessary
local function BucketHandler(self, event, arg1)
    -- Pool common arg1 strings to reduce memory fragmentation
    if arg1 == nil then
        arg1 = poolString("nil")
    elseif type(arg1) == "string" then
        arg1 = poolString(arg1)
    end

    -- Increment the counter for this arg1
    self.received[arg1] = (self.received[arg1] or 0) + 1

    -- if we are not scheduled yet, start a timer on the interval for our bucket to be cleared
    if not self.timer then
        -- Use C_Timer if available for more precise timing
        if C_Timer and self.useNewTimer then
            self.timer = C_Timer.NewTimer(self.interval, function() FireBucket(self) end)
        else
            self.timer = AceTimer.ScheduleTimer(self, FireBucket, self.interval, self)
        end
    end
end

-- RegisterBucket( event, interval, callback, isMessage )
--
-- event(string or table) - the event, or a table with the events, that this bucket listens to
-- interval(int) - time between bucket fireings
-- callback(func or string) - function pointer, or method name of the object, that gets called when the bucket is cleared
-- isMessage(boolean) - register AceEvent Messages instead of game events
local function RegisterBucket(self, event, interval, callback, isMessage)
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

    -- Get a bucket from cache or create a new one
    local bucket = next(bucketCache)
    if bucket then
        bucketCache[bucket] = nil
        -- Reset the bucket properties
        bucket.object = self
        bucket.callback = callback
        bucket.interval = tonumber(interval)
        bucket.received = bucket.received or getReceivedTable()
        bucket.handler = BucketHandler
        bucket.timer = nil
        -- Check if we can use C_Timer for more precise timing
        bucket.useNewTimer = C_Timer ~= nil
    else
        bucket = {
            object = self,
            callback = callback,
            interval = tonumber(interval),
            received = getReceivedTable(),
            handler = BucketHandler,
            useNewTimer = C_Timer ~= nil
        }
    end

    -- Cache the registration function for performance
    local regFunc = isMessage and AceEvent.RegisterMessage or AceEvent.RegisterEvent

    -- Register events
    if type(event) == "table" then
        for _, e in pairs(event) do
            -- Pool event strings to reduce memory fragmentation
            e = poolString(e)
            regFunc(bucket, e, "handler")
        end
    else
        -- Pool event string to reduce memory fragmentation
        event = poolString(event)
        regFunc(bucket, event, "handler")
    end

    -- Create a unique handle for this bucket
    local handle = tostring(bucket)
    AceBucket.buckets[handle] = bucket

    return handle
end

--- Register a Bucket for an event (or a set of events)
-- @param event The event to listen for, or a table of events.
-- @param interval The Bucket interval (burst interval)
-- @param callback The callback function, either as a function reference, or a string pointing to a method of the addon object.
-- @return The handle of the bucket (for unregistering)
-- @usage
-- MyAddon = LibStub("AceAddon-3.0"):NewAddon("MyAddon", "AceBucket-3.0")
-- MyAddon:RegisterBucketEvent("BAG_UPDATE", 0.2, "UpdateBags")
--
-- function MyAddon:UpdateBags()
--   -- do stuff
-- end
function AceBucket:RegisterBucketEvent(event, interval, callback)
    return RegisterBucket(self, event, interval, callback, false)
end

--- Register a Bucket for an AceEvent-3.0 addon message (or a set of messages)
-- @param message The message to listen for, or a table of messages.
-- @param interval The Bucket interval (burst interval)
-- @param callback The callback function, either as a function reference, or a string pointing to a method of the addon object.
-- @return The handle of the bucket (for unregistering)
-- @usage
-- MyAddon = LibStub("AceAddon-3.0"):NewAddon("MyAddon", "AceBucket-3.0")
-- MyAddon:RegisterBucketEvent("SomeAddon_InformationMessage", 0.2, "ProcessData")
--
-- function MyAddon:ProcessData()
--   -- do stuff
-- end
function AceBucket:RegisterBucketMessage(message, interval, callback)
    return RegisterBucket(self, message, interval, callback, true)
end

--- Unregister any events and messages from the bucket and clear any remaining data.
-- @param handle The handle of the bucket as returned by RegisterBucket*
function AceBucket:UnregisterBucket(handle)
    local bucket = AceBucket.buckets[handle]
    if bucket then
        -- Unregister all events and messages
        AceEvent.UnregisterAllEvents(bucket)
        AceEvent.UnregisterAllMessages(bucket)

        -- Cancel any pending timer
        if bucket.timer then
            if C_Timer and bucket.useNewTimer then
                bucket.timer:Cancel()
            else
                AceTimer.CancelTimer(bucket, bucket.timer)
            end
            bucket.timer = nil
        end

        -- Release the received table back to the cache
        releaseReceivedTable(bucket.received)
        bucket.received = nil

        -- Remove from active buckets
        AceBucket.buckets[handle] = nil

        -- Store our bucket in the cache for reuse
        bucketCache[bucket] = true
    end
end

--- Unregister all buckets of the current addon object (or custom "self").
function AceBucket:UnregisterAllBuckets()
    -- Create a local cache of handles to avoid modification during iteration
    local handles = {}
    for handle, bucket in pairs(AceBucket.buckets) do
        if bucket.object == self then
            tinsert(handles, handle)
        end
    end

    -- Unregister all buckets in the local cache
    for _, handle in ipairs(handles) do
        AceBucket.UnregisterBucket(self, handle)
    end
end

-- embedding and embed handling
local mixins = {
    "RegisterBucketEvent",
    "RegisterBucketMessage",
    "UnregisterBucket",
    "UnregisterAllBuckets",
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
