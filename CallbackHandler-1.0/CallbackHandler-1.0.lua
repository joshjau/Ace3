--[[ $Id: CallbackHandler-1.0.lua 25 2022-12-12 15:02:36Z nevcairiel $ ]]
local MAJOR, MINOR = "CallbackHandler-1.0", 9
local CallbackHandler = LibStub:NewLibrary(MAJOR, MINOR)

if not CallbackHandler then return end -- No upgrade needed

local meta = {__index = function(tbl, key) tbl[key] = {} return tbl[key] end}

-- Lua APIs
local securecallfunction, error = securecallfunction, error
local setmetatable, rawget = setmetatable, rawget
local next, select, pairs, type, tostring = next, select, pairs, type, tostring
local tinsert, tremove, sort, wipe = table.insert, table.remove, table.sort, table.wipe
local GetTime = GetTime

-- Performance cache
local funcCache = setmetatable({}, {__mode = "k"}) -- weak table to avoid memory leaks

local function GetCachedFunction(method, self, arg)
	local key = (self or "nil") .. "_" .. tostring(method) .. "_" .. tostring(arg or "nil")
	if not funcCache[key] then
		if arg ~= nil then
			if type(method) == "string" then
				funcCache[key] = function(...) self[method](self, arg, ...) end
			else
				funcCache[key] = function(...) method(arg, ...) end
			end
		else
			if type(method) == "string" then
				funcCache[key] = function(...) self[method](self, ...) end
			else
				funcCache[key] = method
			end
		end
	end
	return funcCache[key]
end

-- Fast dispatch without error protection (for performance critical scenarios)
local function FastDispatch(handlers, ...)
	for _, method in pairs(handlers) do
		method(...)
	end
end

-- Original safe dispatch with error protection
local function SafeDispatch(handlers, ...)
	local index, method = next(handlers)
	if not method then return end
	repeat
		securecallfunction(method, ...)
		index, method = next(handlers, index)
	until not method
end

-- Priority dispatch - handlers with higher priority are called first
local function PriorityDispatch(handlers, priorities, ...)
	if not priorities then return SafeDispatch(handlers, ...) end
	
	-- Sort handlers by priority (higher numbers first)
	local ordered = {}
	for obj, method in pairs(handlers) do
		tinsert(ordered, {obj = obj, method = method, priority = priorities[obj] or 0})
	end
	
	sort(ordered, function(a, b) return a.priority > b.priority end)
	
	-- Execute in priority order
	for i = 1, #ordered do
		securecallfunction(ordered[i].method, ...)
	end
end

-- Throttled dispatch - limits how often a particular event can fire
local function ThrottledDispatch(handlers, eventname, throttle, lastFired, ...)
	local now = GetTime()
	if not lastFired[eventname] or (now - lastFired[eventname] >= throttle) then
		lastFired[eventname] = now
		return SafeDispatch(handlers, eventname, ...)
	end
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


	-- Create the registry object
	local events = setmetatable({}, meta)
	local registry = { 
		recurse = 0, 
		events = events,
		priorities = {},           -- Store callback priorities
		throttle = {},             -- Store throttle intervals for events
		lastFired = {},            -- Track when events were last fired
		dispatchMode = "SAFE",     -- Default dispatch mode (SAFE, FAST, PRIORITY, THROTTLED)
		profiling = false,         -- Performance profiling
		profileData = {}           -- Store profiling information
	}

	-- Performance settings
	function registry:SetDispatchMode(mode)
		if mode == "SAFE" or mode == "FAST" or mode == "PRIORITY" or mode == "THROTTLED" then
			self.dispatchMode = mode
			return true
		end
		return false
	end
	
	-- Enable or disable performance profiling
	function registry:SetProfiling(enabled)
		self.profiling = enabled and true or false
		if not enabled then
			wipe(self.profileData)
		end
		return self.profiling
	end
	
	-- Get profiling data
	function registry:GetProfileData()
		return self.profileData
	end
	
	-- Set throttle interval for an event
	function registry:SetThrottle(eventname, interval)
		if type(eventname) ~= "string" then
			error("Usage: SetThrottle(eventname, interval): 'eventname' - string expected.", 2)
		end
		if type(interval) ~= "number" or interval < 0 then
			error("Usage: SetThrottle(eventname, interval): 'interval' - non-negative number expected.", 2)
		end
		
		self.throttle[eventname] = interval
		return true
	end
	
	-- Set priority for a callback
	function registry:SetPriority(eventname, object, priority)
		if not eventname or not object then return false end
		
		if not self.priorities[eventname] then
			self.priorities[eventname] = {}
		end
		
		self.priorities[eventname][object] = priority
		return true
	end

	-- registry:Fire() - fires the given event/message into the registry
	function registry:Fire(eventname, ...)
		if not rawget(events, eventname) or not next(events[eventname]) then return end
		local oldrecurse = registry.recurse
		registry.recurse = oldrecurse + 1

		local start
		if self.profiling then
			start = GetTime()
		end

		-- Choose dispatch method based on settings
		if self.dispatchMode == "FAST" then
			FastDispatch(events[eventname], eventname, ...)
		elseif self.dispatchMode == "PRIORITY" and self.priorities[eventname] then
			PriorityDispatch(events[eventname], self.priorities[eventname], eventname, ...)
		elseif self.dispatchMode == "THROTTLED" and self.throttle[eventname] then
			ThrottledDispatch(events[eventname], eventname, self.throttle[eventname], self.lastFired, ...)
		else
			SafeDispatch(events[eventname], eventname, ...)
		end

		-- Record profiling data if enabled
		if self.profiling then
			local elapsed = GetTime() - start
			if not self.profileData[eventname] then
				self.profileData[eventname] = {count = 0, totalTime = 0, maxTime = 0}
			end
			self.profileData[eventname].count = self.profileData[eventname].count + 1
			self.profileData[eventname].totalTime = self.profileData[eventname].totalTime + elapsed
			self.profileData[eventname].maxTime = max(self.profileData[eventname].maxTime, elapsed)
		end

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
						first = false
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

		method = method or eventname

		local first = not rawget(events, eventname) or not next(events[eventname])	-- test for empty before. not test for one member after. that one member may have been overwritten.

		if type(method) ~= "string" and type(method) ~= "function" then
			error("Usage: "..RegisterName.."(\"eventname\", \"methodname\"): 'methodname' - string or function expected.", 2)
		end

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

			if select("#",...)>=1 then	-- this is not the same as testing for arg==nil!
				local arg=select(1,...)
				regfunc = GetCachedFunction(method, self, arg)
			else
				regfunc = GetCachedFunction(method, self)
			end
		else
			-- function ref with self=object or self="addonId" or self=thread
			if type(self)~="table" and type(self)~="string" and type(self)~="thread" then
				error("Usage: "..RegisterName.."(self or \"addonId\", eventname, method): 'self or addonId': table or string or thread expected.", 2)
			end

			if select("#",...)>=1 then	-- this is not the same as testing for arg==nil!
				local arg=select(1,...)
				regfunc = GetCachedFunction(method, nil, arg)
			else
				regfunc = method
			end
		end


		if events[eventname][self] or registry.recurse<1 then
		-- if registry.recurse<1 then
			-- we're overwriting an existing entry, or not currently recursing. just set it.
			events[eventname][self] = regfunc
			-- fire OnUsed callback?
			if registry.OnUsed and first then
				registry.OnUsed(registry, target, eventname)
			end
		else
			-- we're currently processing a callback in this registry, so delay the registration of this new entry!
			-- yes, we're a bit wasteful on garbage, but this is a fringe case, so we're picking low implementation overhead over garbage efficiency
			registry.insertQueue = registry.insertQueue or setmetatable({},meta)
			registry.insertQueue[eventname][self] = regfunc
		end
	end

	-- Register with priority
	target.RegisterCallbackWithPriority = function(self, eventname, method, priority, ...)
		target[RegisterName](self, eventname, method, ...)
		registry:SetPriority(eventname, self, priority or 0)
	end

	-- Unregister a callback
	target[UnregisterName] = function(self, eventname)
		if not self or self==target then
			error("Usage: "..UnregisterName.."(eventname): bad 'self'", 2)
		end
		if type(eventname) ~= "string" then
			error("Usage: "..UnregisterName.."(eventname): 'eventname' - string expected.", 2)
		end
		if rawget(events, eventname) and events[eventname][self] then
			events[eventname][self] = nil
			-- Remove priority if it exists
			if registry.priorities[eventname] then
				registry.priorities[eventname][self] = nil
			end
			-- Fire OnUnused callback?
			if registry.OnUnused and not next(events[eventname]) then
				registry.OnUnused(registry, target, eventname)
			end
		end
		if registry.insertQueue and rawget(registry.insertQueue, eventname) and registry.insertQueue[eventname][self] then
			registry.insertQueue[eventname][self] = nil
		end
	end

	-- OPTIONAL: Unregister all callbacks for given selfs/addonIds
	if UnregisterAllName then
		target[UnregisterAllName] = function(...)
			if select("#",...)<1 then
				error("Usage: "..UnregisterAllName.."([whatFor]): missing 'self' or \"addonId\" to unregister events for.", 2)
			end
			if select("#",...)==1 and ...==target then
				error("Usage: "..UnregisterAllName.."([whatFor]): supply a meaningful 'self' or \"addonId\"", 2)
			end


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
						-- Remove priority if it exists
						if registry.priorities[eventname] then
							registry.priorities[eventname][self] = nil
						end
						-- Fire OnUnused callback?
						if registry.OnUnused and not next(callbacks) then
							registry.OnUnused(registry, target, eventname)
						end
					end
				end
			end
		end
	end

	-- Expose the registry object to allow direct manipulation
	target.GetCallbackRegistry = function()
		return registry
	end

	return registry
end


-- CallbackHandler purposefully does NOT do explicit embedding. Nor does it
-- try to upgrade old implicit embeds since the system is selfcontained and
-- relies on closures to work.

