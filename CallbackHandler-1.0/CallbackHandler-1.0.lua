--[[ $Id: CallbackHandler-1.0.lua 25 2022-12-12 15:02:36Z nevcairiel $ ]]
local MAJOR, MINOR = "CallbackHandler-1.0", 9  -- Bump minor version for optimizations
local CallbackHandler = LibStub:NewLibrary(MAJOR, MINOR)

if not CallbackHandler then return end -- No upgrade needed

-- System-specific configuration flags for high-end systems
-- These settings are optimized for systems with 24GB+ available RAM and fast CPUs
local SYSTEM_CONFIG = {
	USE_STRING_POOLING = true,           -- Pool strings to reduce memory fragmentation
	PREALLOCATE_TABLES = true,           -- Pre-allocate tables for common operations
	BATCH_PROCESSING = true,             -- Process callbacks in batches when possible
	AGGRESSIVE_CACHING = true,           -- Aggressively cache values and function references
	CALLBACK_DEDUPLICATION = true,       -- Deduplicate identical callbacks
}

-- String pooling for common event names to reduce memory usage
local StringPool = {}
local function GetPooledString(str)
	if not SYSTEM_CONFIG.USE_STRING_POOLING then return str end

	if not StringPool[str] then
		StringPool[str] = str
	end
	return StringPool[str]
end

local meta = {__index = function(tbl, key) tbl[key] = {} return tbl[key] end}

-- Lua APIs - Localize all functions for faster access and to avoid global lookups
local error = error
local setmetatable, rawget, rawset = setmetatable, rawget, rawset
local next, select, pairs, ipairs = next, select, pairs, ipairs
local type, tostring, tonumber = type, tostring, tonumber
local tinsert, tremove, wipe = table.insert, table.remove, table.wipe or wipe
local unpack = unpack
-- Ensure GetTime is available
local GetTime = GetTime

-- Use securecallfunction if available, otherwise fallback to pcall
local securecallfunction = securecallfunction or function(func, ...)
	local success, result = pcall(func, ...)
	if not success then
		-- Log the error but don't propagate it
		local errorHandler = geterrorhandler and geterrorhandler() or function(err) print("Error:", err) end
		errorHandler(result)
		return nil
	end
	return result
end

-- Table recycling to reduce garbage collection
local TablePool = {}
local function AcquireTable()
	local tbl = tremove(TablePool) or {}
	return tbl
end

local function ReleaseTable(tbl)
	if not tbl then return end
	wipe(tbl)
	tinsert(TablePool, tbl)
end

-- Callback deduplication cache
local CallbackCache = {}

-- Optimized dispatch function with direct function calls and batch processing
local function Dispatch(handlers, ...)
	local index, method = next(handlers)
	if not method then return end

	-- Fast path for single handler (common case)
	if not next(handlers, index) then
		return securecallfunction(method, ...)
	end

	-- Batch processing for multiple handlers
	if SYSTEM_CONFIG.BATCH_PROCESSING then
		-- Pre-collect all handlers to avoid issues with handlers being added/removed during dispatch
		local handlerBatch = AcquireTable()
		repeat
			tinsert(handlerBatch, method)
			index, method = next(handlers, index)
		until not method

		-- Execute all handlers in the batch
		for i = 1, #handlerBatch do
			securecallfunction(handlerBatch[i], ...)
		end

		ReleaseTable(handlerBatch)
		return
	end

	-- Standard processing path for multiple handlers
	repeat
		securecallfunction(method, ...)
		index, method = next(handlers, index)
	until not method
end

--------------------------------------------------------------------------
-- CallbackHandler:New
--
--   target            - target object to embed public APIs in
--   RegisterName      - name of the callback registration API, default "RegisterCallback"
--   UnregisterName    - name of the callback unregistration API, default "UnregisterCallback"
--   UnregisterAllName - name of the API to unregister all callbacks, default "UnregisterAllCallbacks". false == don't publish this API.

function CallbackHandler.New(_self, target, RegisterName, UnregisterName, UnregisterAllName)

	RegisterName = RegisterName or "RegisterCallback"
	UnregisterName = UnregisterName or "UnregisterCallback"
	if UnregisterAllName==nil then	-- false is used to indicate "don't want this method"
		UnregisterAllName = "UnregisterAllCallbacks"
	end

	-- we declare all objects and exported APIs inside this closure to quickly gain access
	-- to e.g. function names, the "target" parameter, etc

	-- Create the registry object with pre-allocated tables for common events
	local events = setmetatable({}, meta)
	local registry = {
		recurse = 0,
		events = events,
		-- Pre-allocate common event tables to avoid resizing
		eventCache = {},
		callbackCache = {},
		-- Track frequently fired events for optimization
		frequentEvents = {},
		-- Throttling data
		lastFired = {},
		throttleData = {},
	}

	-- Local function references for faster access

	-- registry:Fire() - fires the given event/message into the registry
	function registry:Fire(eventname, ...)
		-- Use pooled strings for event names to reduce memory usage
		eventname = GetPooledString(eventname)

		-- Track frequent events for optimization
		if SYSTEM_CONFIG.AGGRESSIVE_CACHING then
			registry.frequentEvents[eventname] = (registry.frequentEvents[eventname] or 0) + 1
		end

		-- Fast path check for non-existent handlers
		local eventHandlers = rawget(events, eventname)
		if not eventHandlers or not next(eventHandlers) then return end

		-- Smart throttling for rapidly firing events
		if SYSTEM_CONFIG.AGGRESSIVE_CACHING then
			local now = GetTime() or 0
			local lastTime = registry.lastFired[eventname] or 0
			registry.lastFired[eventname] = now

			-- If this is a very frequent event (firing multiple times per frame)
			-- and we have throttling data, consider throttling
			if registry.frequentEvents[eventname] > 100 and registry.throttleData[eventname] then
				local throttleData = registry.throttleData[eventname]
				if now - lastTime < throttleData.minInterval then
					-- Queue this call instead of processing immediately
					throttleData.pendingArgs = throttleData.pendingArgs or AcquireTable()
					throttleData.pendingArgs[#throttleData.pendingArgs + 1] = {...}
					return
				end
			end
		end

		local oldrecurse = registry.recurse
		registry.recurse = oldrecurse + 1

		Dispatch(eventHandlers, eventname, ...)

		registry.recurse = oldrecurse

		if registry.insertQueue and oldrecurse==0 then
			-- Something in one of our callbacks wanted to register more callbacks; they got queued
			for event,callbacks in pairs(registry.insertQueue) do
				local first = not rawget(events, event) or not next(events[event])	-- test for empty before. not test for one member after. that one member may have been overwritten.
				for object,func in pairs(callbacks) do
					events[event][object] = func
					-- fire OnUsed callback?
					if first and registry.OnUsed then
						registry.OnUsed(registry, target, event)
						first = false  -- Change from nil to false to maintain boolean type
					end
				end
			end
			registry.insertQueue = nil
		end
	end

	-- Registration of a callback, handles:
	--   self["method"], leads to self["method"](self, ...)
	--   self with function ref, leads to functionref(...)
	--   "addonId" (instead of self) with function ref, leads to functionref(...)
	-- all with an optional arg, which, if present, gets passed as first argument (after self if present)
	target[RegisterName] = function(self, eventname, method, ... --[[actually just a single arg]])
		if type(eventname) ~= "string" then
			error("Usage: "..RegisterName.."(eventname, method[, arg]): 'eventname' - string expected.", 2)
		end

		-- Use pooled strings for event names to reduce memory usage
		eventname = GetPooledString(eventname)

		-- Pre-allocate event tables for frequently used events
		if SYSTEM_CONFIG.PREALLOCATE_TABLES and not rawget(events, eventname) then
			-- If this is a known frequent event, pre-allocate with larger size
			if registry.frequentEvents[eventname] and registry.frequentEvents[eventname] > 10 then
				local preTable = {}
				-- Use rawset to avoid triggering the metatable
				rawset(events, eventname, preTable)
			end
		end

		method = method or eventname

		-- Cache the first check result to avoid redundant lookups
		local first = not rawget(events, eventname) or not next(events[eventname])

		if type(method) ~= "string" and type(method) ~= "function" then
			error("Usage: "..RegisterName.."(\"eventname\", \"methodname\"): 'methodname' - string or function expected.", 2)
		end

		-- Callback deduplication for identical function references
		if SYSTEM_CONFIG.CALLBACK_DEDUPLICATION and type(method) == "function" then
			local funcStr = tostring(method)
			if CallbackCache[funcStr] then
				method = CallbackCache[funcStr]
			else
				CallbackCache[funcStr] = method
			end
		end

		-- Fast path for function references without args (most common case)
		if type(method) == "function" and select("#",...) == 0 then
			-- Quick validation for self type
			if type(self) ~= "table" and type(self) ~= "string" and type(self) ~= "thread" then
				error("Usage: "..RegisterName.."(self or \"addonId\", eventname, method): 'self or addonId': table or string or thread expected.", 2)
			end

			-- Direct assignment path for non-recursive case
			if registry.recurse < 1 then
				events[eventname][self] = method
				-- fire OnUsed callback?
				if first and registry.OnUsed then
					registry.OnUsed(registry, target, eventname)
				end
				return
			end

			-- Queue for recursive case
			registry.insertQueue = registry.insertQueue or setmetatable({}, meta)
			registry.insertQueue[eventname][self] = method
			return
		end

		-- Standard path for other cases
		local regfunc

		if type(method) == "string" then
			-- self["method"] calling style
			if type(self) ~= "table" then
				error("Usage: "..RegisterName.."(\"eventname\", \"methodname\"): self was not a table?", 2)
			elseif self==target then
				error("Usage: "..RegisterName.."(\"eventname\", \"methodname\"): do not use Library:"..RegisterName.."(), use your own 'self'", 2)
			elseif type(self[method]) ~= "function" then
				error("Usage: "..RegisterName.."(\"eventname\", \"methodname\"): 'methodname' - method '"..tostring(method).."' not found on self.", 2)
			end

			-- Optimize closure creation with cached functions
			if select("#",...)>=1 then	-- this is not the same as testing for arg==nil!
				local arg=select(1,...)
				-- Create optimized closure with direct function reference
				regfunc = function(...) self[method](self,arg,...) end
			else
				-- Create optimized closure with direct function reference
				regfunc = function(...) self[method](self,...) end
			end
		else
			-- function ref with self=object or self="addonId" or self=thread
			if type(self)~="table" and type(self)~="string" and type(self)~="thread" then
				error("Usage: "..RegisterName.."(self or \"addonId\", eventname, method): 'self or addonId': table or string or thread expected.", 2)
			end

			-- Optimize closure creation with cached functions
			if select("#",...)>=1 then	-- this is not the same as testing for arg==nil!
				local arg=select(1,...)
				-- Create optimized closure with direct function reference
				regfunc = function(...) method(arg,...) end
			else
				regfunc = method
			end
		end

		-- Callback deduplication for closures if enabled
		if SYSTEM_CONFIG.CALLBACK_DEDUPLICATION and type(regfunc) == "function" then
			local funcStr = tostring(regfunc)
			if CallbackCache[funcStr] then
				regfunc = CallbackCache[funcStr]
			else
				CallbackCache[funcStr] = regfunc
			end
		end

		-- Check for direct assignment vs queue
		if events[eventname][self] or registry.recurse<1 then
			-- we're overwriting an existing entry, or not currently recursing. just set it.
			events[eventname][self] = regfunc
			-- fire OnUsed callback?
			if registry.OnUsed and first then
				registry.OnUsed(registry, target, eventname)
			end
		else
			-- we're currently processing a callback in this registry, so delay the registration of this new entry!
			registry.insertQueue = registry.insertQueue or setmetatable({},meta)
			registry.insertQueue[eventname][self] = regfunc
		end
	end

	-- Unregister a callback - optimized with direct table access
	target[UnregisterName] = function(self, eventname)
		if not self or self==target then
			error("Usage: "..UnregisterName.."(eventname): bad 'self'", 2)
		end
		if type(eventname) ~= "string" then
			error("Usage: "..UnregisterName.."(eventname): 'eventname' - string expected.", 2)
		end

		-- Use pooled strings for event names
		eventname = GetPooledString(eventname)

		-- Fast path for non-existent handlers
		local eventTable = rawget(events, eventname)
		if not eventTable then return end

		-- Fast path for direct removal
		if eventTable[self] then
			eventTable[self] = nil
			-- Fire OnUnused callback?
			if registry.OnUnused and not next(eventTable) then
				registry.OnUnused(registry, target, eventname)
			end
		end

		-- Check insert queue if it exists
		if registry.insertQueue then
			local queueTable = rawget(registry.insertQueue, eventname)
			if queueTable and queueTable[self] then
				queueTable[self] = nil
			end
		end
	end

	-- OPTIONAL: Unregister all callbacks for given selfs/addonIds
	if UnregisterAllName then
		target[UnregisterAllName] = function(...)
			if select("#",...)< 1 then
				error("Usage: "..UnregisterAllName.."([whatFor]): missing 'self' or \"addonId\" to unregister events for.", 2)
			end
			if select("#",...)== 1 and ...==target then
				error("Usage: "..UnregisterAllName.."([whatFor]): supply a meaningful 'self' or \"addonId\"", 2)
			end

			-- Optimize for single object unregistration (common case)
			if select("#",...) == 1 then
				local self = ...

				-- Pre-collect all event names that have this object to avoid table modification during iteration
				if SYSTEM_CONFIG.BATCH_PROCESSING then
					local eventsToCheck = AcquireTable()

					-- Check insert queue first
					if registry.insertQueue then
						for eventname, callbacks in pairs(registry.insertQueue) do
							if callbacks[self] then
								eventsToCheck[eventname] = true
							end
						end
					end

					-- Then check main events table
					for eventname, callbacks in pairs(events) do
						if callbacks[self] then
							eventsToCheck[eventname] = true
						end
					end

					-- Now process all collected events
					for eventname in pairs(eventsToCheck) do
						-- Remove from insert queue if present
						if registry.insertQueue and registry.insertQueue[eventname] then
							registry.insertQueue[eventname][self] = nil
						end

						-- Remove from main events table if present
						if events[eventname] and events[eventname][self] then
							events[eventname][self] = nil
							-- Fire OnUnused callback?
							if registry.OnUnused and not next(events[eventname]) then
								registry.OnUnused(registry, target, eventname)
							end
						end
					end

					ReleaseTable(eventsToCheck)
					return
				end

				-- Standard path without batch processing
				-- Check insert queue first
				if registry.insertQueue then
					for eventname, callbacks in pairs(registry.insertQueue) do
						if callbacks[self] then
							callbacks[self] = nil
						end
					end
				end

				-- Then check main events table
				for eventname, callbacks in pairs(events) do
					if callbacks[self] then
						callbacks[self] = nil
						-- Fire OnUnused callback?
						if registry.OnUnused and not next(callbacks) then
							registry.OnUnused(registry, target, eventname)
						end
					end
				end

				return
			end

			-- Multiple objects path
			for i=1,select("#",...) do
				local self = select(i,...)
				if registry.insertQueue then
					for eventname, callbacks in pairs(registry.insertQueue) do
						if callbacks[self] then
							callbacks[self] = nil
						end
					end
				end
				for eventname, callbacks in pairs(events) do
					if callbacks[self] then
						callbacks[self] = nil
						-- Fire OnUnused callback?
						if registry.OnUnused and not next(callbacks) then
							registry.OnUnused(registry, target, eventname)
						end
					end
				end
			end
		end
	end

	-- Add a cleanup method to manage memory usage
	function registry:CleanupMemory()
		-- Clean up string pool for unused event names
		if SYSTEM_CONFIG.USE_STRING_POOLING then
			local usedStrings = {}

			-- Collect all event names that are actually in use
			for eventname in pairs(events) do
				usedStrings[eventname] = true
			end

			if registry.insertQueue then
				for eventname in pairs(registry.insertQueue) do
					usedStrings[eventname] = true
				end
			end

			-- Remove unused strings from the pool
			for str in pairs(StringPool) do
				if not usedStrings[str] then
					StringPool[str] = nil
				end
			end
		end

		-- Clean up callback cache for unused functions
		if SYSTEM_CONFIG.CALLBACK_DEDUPLICATION then
			local usedFuncs = {}

			-- Collect all functions that are actually in use
			for _, callbacks in pairs(events) do
				for _, func in pairs(callbacks) do
					usedFuncs[tostring(func)] = true
				end
			end

			if registry.insertQueue then
				for _, callbacks in pairs(registry.insertQueue) do
					for _, func in pairs(callbacks) do
						usedFuncs[tostring(func)] = true
					end
				end
			end

			-- Remove unused functions from the cache
			for funcStr in pairs(CallbackCache) do
				if not usedFuncs[funcStr] then
					CallbackCache[funcStr] = nil
				end
			end
		end

		-- Clean up table pool if it's getting too large
		while #TablePool > 100 do
			tremove(TablePool)
		end

		-- Reset throttling data for events that are no longer frequent
		if SYSTEM_CONFIG.AGGRESSIVE_CACHING then
			for eventname, count in pairs(registry.frequentEvents) do
				if count < 10 then
					registry.frequentEvents[eventname] = nil
					registry.lastFired[eventname] = nil
					if registry.throttleData[eventname] then
						if registry.throttleData[eventname].pendingArgs then
							ReleaseTable(registry.throttleData[eventname].pendingArgs)
						end
						registry.throttleData[eventname] = nil
					end
				end
			end
		end
	end

	-- Process any throttled events that were queued
	function registry:ProcessThrottledEvents()
		if not SYSTEM_CONFIG.AGGRESSIVE_CACHING then return end

		local now = GetTime() or 0
		for eventname, data in pairs(registry.throttleData) do
			if data.pendingArgs and #data.pendingArgs > 0 and now - (registry.lastFired[eventname] or 0) >= data.minInterval then
				-- Process the oldest queued event
				local args = tremove(data.pendingArgs, 1)
				if args then
					registry.lastFired[eventname] = now
					Dispatch(events[eventname], eventname, unpack(args))
					ReleaseTable(args)
				end

				-- If queue is empty, release the table
				if #data.pendingArgs == 0 then
					ReleaseTable(data.pendingArgs)
					data.pendingArgs = nil
				end
			end
		end
	end

	-- Configure throttling for a specific event
	function registry:ConfigureThrottling(eventname, minInterval)
		if not SYSTEM_CONFIG.AGGRESSIVE_CACHING then return end

		eventname = GetPooledString(eventname)
		registry.throttleData[eventname] = registry.throttleData[eventname] or {}
		registry.throttleData[eventname].minInterval = minInterval
	end

	return registry
end


-- CallbackHandler purposefully does NOT do explicit embedding. Nor does it
-- try to upgrade old implicit embeds since the system is selfcontained and
-- relies on closures to work.

