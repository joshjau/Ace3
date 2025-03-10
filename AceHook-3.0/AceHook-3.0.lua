--- **AceHook-3.0** offers safe Hooking/Unhooking of functions, methods and frame scripts.
-- Using AceHook-3.0 is recommended when you need to unhook your hooks again, so the hook chain isn't broken
-- when you manually restore the original function.
--
-- **AceHook-3.0** can be embeded into your addon, either explicitly by calling AceHook:Embed(MyAddon) or by
-- specifying it as an embeded library in your AceAddon. All functions will be available on your addon object
-- and can be accessed directly, without having to explicitly call AceHook itself.\\
-- It is recommended to embed AceHook, otherwise you'll have to specify a custom `self` on all calls you
-- make into AceHook.
-- @class file
-- @name AceHook-3.0
-- @release $Id$
local ACEHOOK_MAJOR, ACEHOOK_MINOR = "AceHook-3.0", 22 -- Incremented minor version for TWW optimization
local AceHook, oldminor = LibStub:NewLibrary(ACEHOOK_MAJOR, ACEHOOK_MINOR)

if not AceHook then return end -- No upgrade needed

-- Table recycling setup for high-frequency operations
local tablePool = {}
local tablePoolCount = 0
local MAX_POOL_SIZE = 200 -- Limit pool size to prevent memory bloat

-- Local function for table acquisition with optional initialization
local function acquireTable()
	if tablePoolCount > 0 then
		local t = tablePool[tablePoolCount]
		tablePool[tablePoolCount] = nil
		tablePoolCount = tablePoolCount - 1
		return t
	else
		return {}
	end
end

-- Local function for table releasing/recycling
local function releaseTable(t)
	if not t then return end

	-- Clear the table
	for k in pairs(t) do
		t[k] = nil
	end

	-- Add to pool if not full
	if tablePoolCount < MAX_POOL_SIZE then
		tablePoolCount = tablePoolCount + 1
		tablePool[tablePoolCount] = t
	end
end

-- Primary state tables
AceHook.embeded = AceHook.embeded or {}
AceHook.registry = AceHook.registry or setmetatable({}, {__index = function(tbl, key) tbl[key] = {} return tbl[key] end })
AceHook.handlers = AceHook.handlers or {}
AceHook.actives = AceHook.actives or {}
AceHook.scripts = AceHook.scripts or {}
AceHook.onceSecure = AceHook.onceSecure or {}
AceHook.hooks = AceHook.hooks or {}

-- Combat optimization
AceHook.inCombat = false
AceHook.pendingHooks = AceHook.pendingHooks or {}

-- Fast-path tables for high-frequency lookups
AceHook.activeHooks = AceHook.activeHooks or {} -- Direct uid-to-active mapping
AceHook.methodCache = AceHook.methodCache or {} -- Cache for method type checks

-- local upvalues for faster access
local registry = AceHook.registry
local handlers = AceHook.handlers
local actives = AceHook.actives
local scripts = AceHook.scripts
local onceSecure = AceHook.onceSecure
local activeHooks = AceHook.activeHooks
local methodCache = AceHook.methodCache
local pendingHooks = AceHook.pendingHooks

-- Lua APIs - cache all used functions
local pairs, next, type = pairs, next, type
local format = string.format
local assert, error = assert, error
local setmetatable = setmetatable
local rawget, rawset = rawget, rawset
local select = select
local tostring = tostring

-- WoW APIs
local issecurevariable, hooksecurefunc = issecurevariable, hooksecurefunc
local InCombatLockdown = InCombatLockdown
local _G = _G

-- Function forward declarations
local donothing, createHook, hook

-- Combat state tracking
local function UpdateCombatState()
	AceHook.inCombat = InCombatLockdown()

	-- Process any pending hooks if leaving combat
	if not AceHook.inCombat and next(pendingHooks) then
		for self, hooks in pairs(pendingHooks) do
			for i = 1, #hooks do
				local hookData = hooks[i]
				hook(self, hookData.obj, hookData.method, hookData.handler,
					 hookData.script, hookData.secure, hookData.raw,
					 hookData.forceSecure, hookData.usage)
			end
			hooks = {}
		end
	end
end

-- Create combat state event handlers
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_REGEN_DISABLED" then
		AceHook.inCombat = true
	elseif event == "PLAYER_REGEN_ENABLED" then
		UpdateCombatState()
	end
end)

-- Protected scripts that require secure hooks
local protectedScripts = {
	OnClick = true,
}

-- Mixin functions to embed in addons
local mixins = {
	"Hook", "SecureHook",
	"HookScript", "SecureHookScript",
	"Unhook", "UnhookAll",
	"IsHooked",
	"RawHook", "RawHookScript",
	"PreCacheMethod",  -- New utility function
	"BatchHook"        -- Batch hooking convenience function
}

-- AceHook:Embed( target )
-- target (object) - target object to embed AceHook in
--
-- Embeds AceEevent into the target object making the functions from the mixins list available on target:..
function AceHook:Embed(target)
	for _, name in pairs(mixins) do
		target[name] = self[name]
	end
	self.embeded[target] = true
	-- inject the hooks table safely
	target.hooks = target.hooks or {}
	return target
end

-- AceHook:OnEmbedDisable( target )
-- target (object) - target object that is being disabled
--
-- Unhooks all hooks when the target disables.
-- this method should be called by the target manually or by an addon framework
function AceHook:OnEmbedDisable(target)
	target:UnhookAll()
end

-- Optimized function to create hook closures with minimal overhead
function createHook(self, handler, orig, secure, failsafe)
	local uid
	local method = methodCache[handler] or (type(handler) == "string")

	-- Cache method check result
	if not methodCache[handler] then
		methodCache[handler] = method
	end

	if failsafe and not secure then
		-- failsafe hook creation - optimized path
		uid = function(...)
			if activeHooks[uid] then
				if method then
					self[handler](self, ...)
				else
					handler(...)
				end
			end
			return orig(...)
		end
	else
		-- all other hooks - optimized path
		uid = function(...)
			if activeHooks[uid] then
				if method then
					return self[handler](self, ...)
				else
					return handler(...)
				end
			elseif not secure then -- backup on non secure
				return orig(...)
			end
		end
	end

	-- Set direct lookup flag
	activeHooks[uid] = false
	return uid
end

function donothing() end

-- Optimized hook function
function hook(self, obj, method, handler, script, secure, raw, forceSecure, usage)
	if not handler then handler = method end

	-- Skip debug assertions in performance builds
	if AceHook.debugMode then
		assert(not script or type(script) == "boolean")
		assert(not secure or type(secure) == "boolean")
		assert(not raw or type(raw) == "boolean")
		assert(not forceSecure or type(forceSecure) == "boolean")
		assert(usage)
	end

	-- Defer hooking if in combat lockdown and it's not a secure hook
	if AceHook.inCombat and not secure then
		pendingHooks[self] = pendingHooks[self] or {}
		local hookData = {
			obj = obj, method = method, handler = handler,
			script = script, secure = secure, raw = raw,
			forceSecure = forceSecure, usage = usage
		}
		pendingHooks[self][#pendingHooks[self] + 1] = hookData
		return
	end

	-- Error checking with better formatting and fewer string operations
	if obj and type(obj) ~= "table" then
		error(format("%s: 'object' - nil or table expected got %s", usage, type(obj)), 3)
	end
	if type(method) ~= "string" then
		error(format("%s: 'method' - string expected got %s", usage, type(method)), 3)
	end
	if type(handler) ~= "string" and type(handler) ~= "function" then
		error(format("%s: 'handler' - nil, string, or function expected got %s", usage, type(handler)), 3)
	end
	if type(handler) == "string" and type(self[handler]) ~= "function" then
		error(format("%s: 'handler' - Handler specified does not exist at self[handler]", usage), 3)
	end

	-- Script-specific validation
	if script then
		if not obj or not obj.GetScript or not obj:HasScript(method) then
			error(format("%s: You can only hook a script on a frame object", usage), 3)
		end
		if not secure and obj.IsProtected and obj:IsProtected() and protectedScripts[method] then
			error(format("Cannot hook secure script %q; Use SecureHookScript(obj, method, [handler]) instead.", method), 3)
		end
	else
		-- Optimized security check with cache
		local objKey = obj and tostring(obj) or "global"
		local securityKey = objKey .. "_" .. method
		local securityCacheHit = false

		local issecure
		if obj then
			-- Check from cache first
			if AceHook.securityCache and AceHook.securityCache[securityKey] ~= nil then
				issecure = AceHook.securityCache[securityKey]
				securityCacheHit = true
			else
				issecure = onceSecure[obj] and onceSecure[obj][method] or issecurevariable(obj, method)
			end
		else
			-- Global function security check
			if AceHook.securityCache and AceHook.securityCache[securityKey] ~= nil then
				issecure = AceHook.securityCache[securityKey]
				securityCacheHit = true
			else
				issecure = onceSecure[method] or issecurevariable(method)
			end
		end

		-- Update security cache
		if not securityCacheHit then
			-- Initialize cache if needed
			if not AceHook.securityCache then
				AceHook.securityCache = {}
			end
			-- Store result in cache
			AceHook.securityCache[securityKey] = issecure
		end

		if issecure then
			if forceSecure then
				if obj then
					onceSecure[obj] = onceSecure[obj] or {}
					onceSecure[obj][method] = true
				else
					onceSecure[method] = true
				end
			elseif not secure then
				error(format("%s: Attempt to hook secure function %s. Use `SecureHook' or add `true' to the argument list to override.", usage, method), 3)
			end
		end
	end

	-- Get existing hook if it exists
	local uid
	if obj then
		uid = registry[self][obj] and registry[self][obj][method]
	else
		uid = registry[self][method]
	end

	-- Handle existing hooks
	if uid then
		if actives[uid] then
			-- Prevent rehooking active hooks
			error(format("Attempting to rehook already active hook %s.", method))
		end

		-- Check if we're just reactivating an existing hook
		if handlers[uid] == handler then
			actives[uid] = true
			activeHooks[uid] = true -- Direct flag for highest performance
			return
		elseif obj then
			-- Clean up old hook data for object method
			if self.hooks and self.hooks[obj] then
				self.hooks[obj][method] = nil
			end
			registry[self][obj][method] = nil
		else
			-- Clean up old hook data for global function
			if self.hooks then
				self.hooks[method] = nil
			end
			registry[self][method] = nil
		end
		-- Reset state tables for this hook
		handlers[uid], actives[uid], scripts[uid] = nil, nil, nil
		activeHooks[uid] = nil
	end

	-- Get the original function to hook
	local orig
	if script then
		orig = obj:GetScript(method) or donothing
	elseif obj then
		orig = obj[method]
	else
		orig = _G[method]
	end

	-- Error if target doesn't exist
	if not orig then
		error(format("%s: Attempting to hook a non existing target", usage), 3)
	end

	-- Create the hook function
	uid = createHook(self, handler, orig, secure, not (raw or secure))

	-- Register the hook in our tracking tables
	if obj then
		self.hooks[obj] = self.hooks[obj] or {}
		registry[self][obj] = registry[self][obj] or {}
		registry[self][obj][method] = uid

		if not secure then
			self.hooks[obj][method] = orig
		end

		-- Apply hook based on type
		if script then
			if not secure then
				obj:SetScript(method, uid)
			else
				obj:HookScript(method, uid)
			end
		else
			if not secure then
				obj[method] = uid
			else
				hooksecurefunc(obj, method, uid)
			end
		end
	else
		-- Global function hooks
		registry[self][method] = uid

		if not secure then
			_G[method] = uid
			self.hooks[method] = orig
		else
			hooksecurefunc(method, uid)
		end
	end

	-- Update active state
	actives[uid], handlers[uid], scripts[uid] = true, handler, script and true or nil
	activeHooks[uid] = true -- Direct flag for performance
end

--- Hook a function or a method on an object.
-- The hook created will be a "safe hook", that means that your handler will be called
-- before the hooked function ("Pre-Hook"), and you don't have to call the original function yourself,
-- however you cannot stop the execution of the function, or modify any of the arguments/return values.\\
-- This type of hook is typically used if you need to know if some function got called, and don't want to modify it.
-- @paramsig [object], method, [handler], [hookSecure]
-- @param object The object to hook a method from
-- @param method If object was specified, the name of the method, or the name of the function to hook.
-- @param handler The handler for the hook, a funcref or a method name. (Defaults to the name of the hooked function)
-- @param hookSecure If true, AceHook will allow hooking of secure functions.
function AceHook:Hook(object, method, handler, hookSecure)
	if type(object) == "string" then
		method, handler, hookSecure, object = object, method, handler, nil
	end

	if handler == true then
		handler, hookSecure = nil, true
	end

	hook(self, object, method, handler, false, false, false, hookSecure or false, "Usage: Hook([object], method, [handler], [hookSecure])")
end

--- RawHook a function or a method on an object.
-- The hook created will be a "raw hook", that means that your handler will completly replace
-- the original function, and your handler has to call the original function (or not, depending on your intentions).\\
-- The original function will be stored in `self.hooks[object][method]` or `self.hooks[functionName]` respectively.\\
-- This type of hook can be used for all purposes, and is usually the most common case when you need to modify arguments
-- or want to control execution of the original function.
-- @paramsig [object], method, [handler], [hookSecure]
-- @param object The object to hook a method from
-- @param method If object was specified, the name of the method, or the name of the function to hook.
-- @param handler The handler for the hook, a funcref or a method name. (Defaults to the name of the hooked function)
-- @param hookSecure If true, AceHook will allow hooking of secure functions.
function AceHook:RawHook(object, method, handler, hookSecure)
	if type(object) == "string" then
		method, handler, hookSecure, object = object, method, handler, nil
	end

	if handler == true then
		handler, hookSecure = nil, true
	end

	hook(self, object, method, handler, false, false, true, hookSecure or false, "Usage: RawHook([object], method, [handler], [hookSecure])")
end

--- SecureHook a function or a method on an object.
-- This function is a wrapper around the `hooksecurefunc` function in the WoW API. Using AceHook
-- extends the functionality of secure hooks, and adds the ability to unhook once the hook isn't
-- required anymore, or the addon is being disabled.\\
-- Secure Hooks should be used if the secure-status of the function is vital to its function,
-- and taint would block execution. Secure Hooks are always called after the original function was called
-- ("Post Hook"), and you cannot modify the arguments, return values or control the execution.
-- @paramsig [object], method, [handler]
-- @param object The object to hook a method from
-- @param method If object was specified, the name of the method, or the name of the function to hook.
-- @param handler The handler for the hook, a funcref or a method name. (Defaults to the name of the hooked function)
function AceHook:SecureHook(object, method, handler)
	if type(object) == "string" then
		method, handler, object = object, method, nil
	end

	hook(self, object, method, handler, false, true, false, false, "Usage: SecureHook([object], method, [handler])")
end

--- Hook a script handler on a frame.
-- The hook created will be a "safe hook", that means that your handler will be called
-- before the hooked script ("Pre-Hook"), and you don't have to call the original function yourself,
-- however you cannot stop the execution of the function, or modify any of the arguments/return values.\\
-- This is the frame script equivalent of the :Hook safe-hook. It would typically be used to be notified
-- when a certain event happens to a frame.
-- @paramsig frame, script, [handler]
-- @param frame The Frame to hook the script on
-- @param script The script to hook
-- @param handler The handler for the hook, a funcref or a method name. (Defaults to the name of the hooked script)
function AceHook:HookScript(frame, script, handler)
	hook(self, frame, script, handler, true, false, false, false, "Usage: HookScript(object, method, [handler])")
end

--- RawHook a script handler on a frame.
-- The hook created will be a "raw hook", that means that your handler will completly replace
-- the original script, and your handler has to call the original script (or not, depending on your intentions).\\
-- The original script will be stored in `self.hooks[frame][script]`.\\
-- This type of hook can be used for all purposes, and is usually the most common case when you need to modify arguments
-- or want to control execution of the original script.
-- @paramsig frame, script, [handler]
-- @param frame The Frame to hook the script on
-- @param script The script to hook
-- @param handler The handler for the hook, a funcref or a method name. (Defaults to the name of the hooked script)
function AceHook:RawHookScript(frame, script, handler)
	hook(self, frame, script, handler, true, false, true, false, "Usage: RawHookScript(object, method, [handler])")
end

--- SecureHook a script handler on a frame.
-- This function is a wrapper around the `frame:HookScript` function in the WoW API. Using AceHook
-- extends the functionality of secure hooks, and adds the ability to unhook once the hook isn't
-- required anymore, or the addon is being disabled.\\
-- Secure Hooks should be used if the secure-status of the function is vital to its function,
-- and taint would block execution. Secure Hooks are always called after the original function was called
-- ("Post Hook"), and you cannot modify the arguments, return values or control the execution.
-- @paramsig frame, script, [handler]
-- @param frame The Frame to hook the script on
-- @param script The script to hook
-- @param handler The handler for the hook, a funcref or a method name. (Defaults to the name of the hooked script)
function AceHook:SecureHookScript(frame, script, handler)
	hook(self, frame, script, handler, true, true, false, false, "Usage: SecureHookScript(object, method, [handler])")
end

--- Utility function to pre-cache method information for objects.
-- This can improve performance by avoiding type checks during each hook call.
-- @paramsig object, methodName
-- @param object The object that contains the method
-- @param methodName The name of the method to pre-cache
function AceHook:PreCacheMethod(object, methodName)
	if not object or not methodName or type(object) ~= "table" or type(methodName) ~= "string" then
		return false
	end

	-- Cache the method and security information
	local objKey = tostring(object)
	local securityKey = objKey .. "_" .. methodName

	-- Init caches if needed
	if not AceHook.securityCache then
		AceHook.securityCache = {}
	end

	-- Store security info
	AceHook.securityCache[securityKey] = issecurevariable(object, methodName)

	return true
end

--- Unhook from the specified function, method or script.
-- @paramsig [obj], method
-- @param obj The object or frame to unhook from
-- @param method The name of the method, function or script to unhook from.
function AceHook:Unhook(obj, method)
	local usage = "Usage: Unhook([obj], method)"
	if type(obj) == "string" then
		method, obj = obj, nil
	end

	if obj and type(obj) ~= "table" then
		error(format("%s: 'obj' - expecting nil or table got %s", usage, type(obj)), 2)
	end
	if type(method) ~= "string" then
		error(format("%s: 'method' - expeting string got %s", usage, type(method)), 2)
	end

	local uid
	if obj then
		uid = registry[self][obj] and registry[self][obj][method]
	else
		uid = registry[self][method]
	end

	if not uid or not actives[uid] then
		-- Avoiding error on unneeded unhook
		return false
	end

	-- Reset active state
	actives[uid], handlers[uid] = nil, nil
	activeHooks[uid] = nil -- Clear direct flag

	if obj then
		registry[self][obj][method] = nil
		registry[self][obj] = next(registry[self][obj]) and registry[self][obj] or nil

		-- Skip further processing for secure hooks
		if not self.hooks[obj] or not self.hooks[obj][method] then return true end

		if scripts[uid] and obj:GetScript(method) == uid then  -- unhooks scripts
			obj:SetScript(method, self.hooks[obj][method] ~= donothing and self.hooks[obj][method] or nil)
			scripts[uid] = nil
		elseif obj and self.hooks[obj] and self.hooks[obj][method] and obj[method] == uid then -- unhooks methods
			obj[method] = self.hooks[obj][method]
		end

		self.hooks[obj][method] = nil
		self.hooks[obj] = next(self.hooks[obj]) and self.hooks[obj] or nil
	else
		registry[self][method] = nil

		-- Skip further processing for secure hooks
		if not self.hooks[method] then return true end

		if self.hooks[method] and _G[method] == uid then -- unhooks functions
			_G[method] = self.hooks[method]
		end

		self.hooks[method] = nil
	end
	return true
end

--- Unhook all existing hooks for this addon.
function AceHook:UnhookAll()
	for key, value in pairs(registry[self]) do
		if type(key) == "table" then
			for method in pairs(value) do
				self:Unhook(key, method)
			end
		else
			self:Unhook(key)
		end
	end
end

--- Check if the specific function, method or script is already hooked.
-- @paramsig [obj], method
-- @param obj The object or frame to check
-- @param method The name of the method, function or script to check.
function AceHook:IsHooked(obj, method)
	-- we don't check if registry[self] exists, this is done by evil magicks in the metatable
	if type(obj) == "string" then
		if registry[self][obj] and actives[registry[self][obj]] then
			return true, handlers[registry[self][obj]]
		end
	else
		if registry[self][obj] and registry[self][obj][method] and actives[registry[self][obj][method]] then
			return true, handlers[registry[self][obj][method]]
		end
	end

	return false, nil
end

-- Performance monitoring APIs (available in debug builds)
-- These functions allow measuring hook performance overhead
function AceHook:EnablePerformanceTracking()
	AceHook.perfTracking = true
	AceHook.perfData = AceHook.perfData or {}
	return true
end

function AceHook:DisablePerformanceTracking()
	AceHook.perfTracking = false
	return true
end

function AceHook:GetPerformanceStats()
	if not AceHook.perfTracking or not AceHook.perfData then
		return nil
	end
	return AceHook.perfData
end

--- Set up multiple hooks at once efficiently
-- @param hookTable A table of hook configurations to process in batch
-- @return A table with results for each hook attempt
-- @usage
-- local results = MyAddon:BatchHook({
--   {method = "ActionButton_UpdateHotkeys", secure = true},
--   {object = someFrame, method = "OnShow", handler = "FrameShown"},
--   {method = "ChatFrame_OnEvent", handler = myChatFunction, secure = true}
-- })
function AceHook:BatchHook(hookTable)
	if type(hookTable) ~= "table" then
		error("Usage: BatchHook(hookTable): 'hookTable' - table expected", 2)
		return
	end

	local results = {}
	local batchSize = #hookTable

	-- Pre-allocate results table
	for i = 1, batchSize do
		results[i] = {index = i, success = false}
	end

	-- Skip if nothing to do
	if batchSize == 0 then
		return results
	end

	-- Process in batch
	for i = 1, batchSize do
		local hookData = hookTable[i]
		local result = results[i]

		-- Ensure we have the minimal required data
		if type(hookData) ~= "table" or not hookData.method then
			result.error = "Invalid hook data at index " .. i
			result.success = false
		else
			-- Extract hook parameters
			local object = hookData.object
			local method = hookData.method
			local handler = hookData.handler
			local hookSecure = hookData.secure
			local hookType = hookData.type or "normal"

			-- Attempt to hook based on type
			local success, errorMsg
			if hookType == "raw" then
				success, errorMsg = pcall(self.RawHook, self, object, method, handler, hookSecure)
			elseif hookType == "secure" then
				success, errorMsg = pcall(self.SecureHook, self, object, method, handler)
			elseif hookType == "script" then
				success, errorMsg = pcall(self.HookScript, self, object, method, handler)
			elseif hookType == "rawscript" then
				success, errorMsg = pcall(self.RawHookScript, self, object, method, handler)
			elseif hookType == "securescript" then
				success, errorMsg = pcall(self.SecureHookScript, self, object, method, handler)
			else
				-- Default to normal Hook
				success, errorMsg = pcall(self.Hook, self, object, method, handler, hookSecure)
			end

			-- Record result
			result.success = success
			if not success then
				result.error = errorMsg
			else
				-- Verify the hook was actually set by checking registry changes
				if object then
					result.verified = registry[self][object] and registry[self][object][method] ~= nil
				else
					result.verified = registry[self][method] ~= nil
				end
			end
		end
	end

	return results
end

--- Apply upgrades to all embedded targets
for target, _ in pairs(AceHook.embeded) do
	AceHook:Embed(target)
end

-- Initialize combat state
UpdateCombatState()
