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

-- Configuration flags for high-end systems
local HIGH_END_SYSTEM = true  -- Enables memory-intensive optimizations for systems with 16GB+ RAM
local PREALLOCATE_SIZE = 32   -- Number of table slots to pre-allocate; higher values use more memory but reduce resizing
local STRING_POOLING = true   -- Reduces string GC pressure by storing common strings once in memory

AceBucket.buckets = AceBucket.buckets or {}
AceBucket.embeds = AceBucket.embeds or {}

-- the libraries will be lazyly bound later, to avoid errors due to loading order issues
local AceEvent, AceTimer

-- Lua APIs - Expanded and more complete set of localized functions
local tconcat, tremove, tinsert = table.concat, table.remove, table.insert
local type, next, pairs, ipairs, select = type, next, pairs, ipairs, select
local tonumber, tostring, rawset, rawget = tonumber, tostring, rawset, rawget
local assert, loadstring, error, pcall = assert, loadstring, error, pcall
local math_floor, math_ceil = math.floor, math.ceil
local string_format = string.format
local geterrorhandler = geterrorhandler

-- String pool for common strings to reduce memory allocations
-- This helps reduce GC pressure by ensuring frequently used strings exist only once in memory
-- Particularly useful for unit IDs and event names that get reused often
local StringPool = {}
local function GetPooledString(str)
	if not STRING_POOLING then return str end
	if not StringPool[str] then
		StringPool[str] = str
	end
	return StringPool[str]
end

-- Common strings that will be pooled
local NIL_STRING = GetPooledString("nil")  -- Used for nil arguments in events
local HANDLER_STRING = GetPooledString("handler")  -- Used as the handler method name

-- Replace weak table with standard table to fully utilize memory
-- On high-end systems, caching more objects improves performance at the cost of higher memory usage
local bucketCache = {}
local bucketCacheSize = 0
local MAX_CACHE_SIZE = HIGH_END_SYSTEM and 100 or 20  -- Cache size tuned for available system memory

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

-- Table handling utility for high-performance operations
-- More reliable pre-allocation technique for Lua 5.1
local function PreAllocateTable(tbl, size)
    -- Only pre-allocate if we're on a high-end system and a size is specified
    if HIGH_END_SYSTEM and size and size > 0 then
        -- This forces Lua to allocate hash table space, reducing incremental growth costs
        -- First set values to force hash table allocation
        for i = 1, size do
            tbl[i] = true
        end
        -- Then clear the table while preserving the allocated capacity
        for i = 1, size do
            tbl[i] = nil
        end
    end
    return tbl
end

-- Creates a new pre-allocated table with reserved capacity
local function CreateTable(size)
    local tbl = {}
    return PreAllocateTable(tbl, size)
end

-- Wipe a table and optionally pre-allocate slots
-- More efficient than creating new tables repeatedly
local function WipeTable(tbl, size)
    if not tbl then return tbl end

    -- Clear existing contents
    for k in pairs(tbl) do
        tbl[k] = nil
    end

    -- Pre-allocate if requested
    return PreAllocateTable(tbl, size)
end

-- Do NOT create a table.wipe global as it doesn't exist in vanilla Lua 5.1

-- FireBucket ( bucket )
--
-- send the bucket to the callback function and schedule the next FireBucket in interval seconds
-- Optimized to minimize table churn and maximize reuse of allocated memory
local function FireBucket(bucket)
	local received = bucket.received

	-- Fast check for empty buckets
	if next(received) ~= nil then
		-- Cache the callback information for faster access
		local callback = bucket.callback
		local object = bucket.object

		-- Fast path for string callbacks (most common)
		if type(callback) == "string" then
			local method = object[callback]
			safecall(method, object, received)
		else
			safecall(callback, received)
		end

		-- Pre-allocate a new received table for better performance
		-- This avoids the need to clear the old one which can be expensive
		if HIGH_END_SYSTEM then
			-- On high-end systems, we can afford to create a new table
			-- and cache the old one for later reuse
			local oldReceived = received
			local newReceived = CreateTable(PREALLOCATE_SIZE)
			bucket.received = newReceived

			-- Clear the old table for reuse
			WipeTable(oldReceived)

			-- Store in a temporary cache if cache isn't too large
			if bucketCacheSize < MAX_CACHE_SIZE then
				bucketCacheSize = bucketCacheSize + 1
				bucketCache[bucketCacheSize] = oldReceived
			end
		else
			-- On lower-end systems, just clear the existing table
			WipeTable(received)
		end

		-- Schedule the next execution
		bucket.timer = AceTimer.ScheduleTimer(bucket, FireBucket, bucket.interval, bucket)
	else -- if it was empty, clear the timer and wait for the next event
		bucket.timer = nil
	end
end

-- BucketHandler ( event, arg1 )
--
-- callback func for AceEvent
-- stores arg1 in the received table, and schedules the bucket if necessary
-- Optimized with string pooling and fast paths for common operations
local function BucketHandler(self, event, arg1)
	-- Fast path for nil (common case)
	if arg1 == nil then
		arg1 = NIL_STRING
	elseif STRING_POOLING and type(arg1) == "string" then
		-- Use string pooling for string arguments
		arg1 = GetPooledString(arg1)
	end

	-- Fast path for first occurrence of this arg1
	local received = self.received
	local count = received[arg1]
	if count then
		received[arg1] = count + 1
	else
		received[arg1] = 1
	end

	-- Fast scheduling check
	if not self.timer then
		self.timer = AceTimer.ScheduleTimer(self, FireBucket, self.interval, self)
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

	-- Use cached bucket if available or create a pre-allocated one
	local bucket

	-- Try to get a bucket from the cache first
	if bucketCacheSize > 0 then
		bucket = bucketCache[bucketCacheSize]
		bucketCache[bucketCacheSize] = nil
		bucketCacheSize = bucketCacheSize - 1

		-- Make sure we have a received table
		if not bucket.received then
			-- Pre-allocate with estimated size when possible
			bucket.received = WipeTable({}, PREALLOCATE_SIZE)
		end
	else
		-- Create a new bucket with pre-allocated table
		local received = CreateTable(PREALLOCATE_SIZE)
		bucket = { handler = BucketHandler, received = received }
	end

	bucket.object, bucket.callback, bucket.interval = self, callback, tonumber(interval)

	-- Use cached function references for faster registration
	local regFunc = isMessage and AceEvent.RegisterMessage or AceEvent.RegisterEvent

	-- Optimize event registration loop
	if type(event) == "table" then
		-- First pass: handle array part (numerically indexed values)
		-- This optimizes for the common case of array-style event tables
		for i = 1, #event do
			local e = event[i]
			if type(e) == "string" then -- Only register string events
				regFunc(bucket, e, HANDLER_STRING)
			end
		end

		-- Second pass: handle hash part (named keys)
		-- This handles the less common case of events stored as table keys
		for k, v in pairs(event) do
			-- Skip numeric keys that were already processed in the array part
			if type(k) == "string" then
				regFunc(bucket, k, HANDLER_STRING)
			end
		end
	else
		regFunc(bucket, event, HANDLER_STRING)
	end

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
-- Optimized to reuse buckets and maintain the performance benefits of pre-allocated tables
-- @param handle The handle of the bucket as returned by RegisterBucket*
function AceBucket:UnregisterBucket(handle)
	local bucket = AceBucket.buckets[handle]
	if bucket then
		-- Use direct function references for faster unregistration
		AceEvent.UnregisterAllEvents(bucket)
		AceEvent.UnregisterAllMessages(bucket)

		-- If the timer exists, cancel it
		if bucket.timer then
			AceTimer.CancelTimer(bucket, bucket.timer)
			bucket.timer = nil
		end

		-- Reuse the received table by clearing it
		local received = bucket.received
		if received then
			WipeTable(received)
		end

		-- Remove from active buckets
		AceBucket.buckets[handle] = nil

		-- Store the bucket in our cache for reuse
		if bucketCacheSize < MAX_CACHE_SIZE then
			bucketCacheSize = bucketCacheSize + 1
			bucketCache[bucketCacheSize] = bucket
		end
	end
end

--- Unregister all buckets of the current addon object (or custom "self").
-- Optimized to avoid modifying tables during iteration
function AceBucket:UnregisterAllBuckets()
	-- Collect handles first to avoid table modification during iteration
	local toUnregister = {}
	local count = 0

	-- Find all buckets belonging to this object
	for handle, bucket in pairs(AceBucket.buckets) do
		if bucket.object == self then
			count = count + 1
			toUnregister[count] = handle
		end
	end

	-- Unregister each bucket
	for i = 1, count do
		AceBucket.UnregisterBucket(self, toUnregister[i])
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
function AceBucket:Embed( target )
	for _, v in pairs( mixins ) do
		target[v] = self[v]
	end
	self.embeds[target] = true
	return target
end

function AceBucket:OnEmbedDisable( target )
	target:UnregisterAllBuckets()
end

for addon in pairs(AceBucket.embeds) do
	AceBucket:Embed(addon)
end
