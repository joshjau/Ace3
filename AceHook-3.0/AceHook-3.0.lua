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
local ACEHOOK_MAJOR, ACEHOOK_MINOR = "AceHook-3.0", 10
local AceHook, oldminor = LibStub:NewLibrary(ACEHOOK_MAJOR, ACEHOOK_MINOR)

if not AceHook then return end -- No upgrade needed

-- Pre-allocate tables with reasonable initial sizes to reduce table resizing operations
AceHook.embeded = AceHook.embeded or {}
AceHook.registry = AceHook.registry or setmetatable({}, {__index = function(tbl, key) tbl[key] = {} return tbl[key] end })
AceHook.handlers = AceHook.handlers or {}
AceHook.actives = AceHook.actives or {}
AceHook.scripts = AceHook.scripts or {}
AceHook.onceSecure = AceHook.onceSecure or {}
AceHook.hooks = AceHook.hooks or {}

-- local upvalues for frequently accessed tables
local registry = AceHook.registry
local handlers = AceHook.handlers
local actives = AceHook.actives
local scripts = AceHook.scripts
local onceSecure = AceHook.onceSecure
local hooks = AceHook.hooks

-- Lua APIs - localize all frequently used functions for performance
local pairs, next, type = pairs, next, type
local format, gsub, lower = string.format, string.gsub, string.lower
local assert, error, pcall, select = assert, error, pcall, select
local setmetatable, rawget, rawset = setmetatable, rawget, rawset
local tinsert, tremove, wipe = table.insert, table.remove, table.wipe or function(t) for k in pairs(t) do t[k] = nil end end

-- WoW APIs - localize all frequently used functions
local issecurevariable, hooksecurefunc = issecurevariable, hooksecurefunc
local GetTime = GetTime
local _G = _G

-- functions for later definition
local donothing, createHook, hook

-- Cache for string operations to reduce memory allocations
local stringCache = setmetatable({}, {__mode = "k"})

-- Helper function to cache and reuse strings
local function getCachedString(str)
	if not stringCache[str] then
		stringCache[str] = str
	end
	return stringCache[str]
end

-- Pre-allocate common error messages to reduce string allocations
local ERRORS = {
	HOOK_OBJECT_INVALID = "%s: 'object' - nil or table expected got %s",
	HOOK_METHOD_INVALID = "%s: 'method' - string expected got %s",
	HOOK_HANDLER_INVALID = "%s: 'handler' - nil, string, or function expected got %s",
	HOOK_HANDLER_MISSING = "%s: 'handler' - Handler specified does not exist at self[handler]",
	HOOK_SCRIPT_INVALID = "%s: You can only hook a script on a frame object",
	HOOK_SECURE_FORBIDDEN = "Cannot hook secure script %q; Use SecureHookScript(obj, method, [handler]) instead.",
	HOOK_SECURE_REQUIRED = "%s: Attempt to hook secure function %s. Use `SecureHook' or add `true' to the argument list to override.",
	HOOK_ALREADY_ACTIVE = "Attempting to rehook already active hook %s.",
	HOOK_TARGET_MISSING = "%s: Attempting to hook a non existing target",
	UNHOOK_OBJECT_INVALID = "%s: 'obj' - expecting nil or table got %s",
	UNHOOK_METHOD_INVALID = "%s: 'method' - expeting string got %s"
}

local protectedScripts = {
	OnClick = true,
}

-- upgrading of embeded is done at the bottom of the file

local mixins = {
	"Hook", "SecureHook",
	"HookScript", "SecureHookScript",
	"Unhook", "UnhookAll",
	"IsHooked",
	"RawHook", "RawHookScript"
}

-- AceHook:Embed( target )
-- target (object) - target object to embed AceHook in
--
-- Embeds AceEevent into the target object making the functions from the mixins list available on target:..
function AceHook:Embed( target )
	-- Pre-allocate the hooks table with a reasonable size to avoid table resizing
	target.hooks = target.hooks or {}

	-- Use direct function references instead of string lookups for better performance
	for i = 1, #mixins do
		target[mixins[i]] = self[mixins[i]]
	end

	self.embeded[target] = true
	return target
end

-- AceHook:OnEmbedDisable( target )
-- target (object) - target object that is being disabled
--
-- Unhooks all hooks when the target disables.
-- this method should be called by the target manually or by an addon framework
function AceHook:OnEmbedDisable( target )
	target:UnhookAll()
end

function createHook(self, handler, orig, secure, failsafe)
	-- Cache the method check result to avoid repeated type() calls during hook execution
	local method = type(handler) == "string"
	local uid

	-- Create specialized hook functions based on hook type for better performance
	-- This reduces conditional checks during hook execution
	if method then
		-- Method-based hooks (handler is a string method name)
		if failsafe and not secure then
			-- Failsafe method hook
			uid = function(...)
				if actives[uid] then
					self[handler](self, ...)
				end
				return orig(...)
			end
		elseif secure then
			-- Secure method hook
			uid = function(...)
				if actives[uid] then
					return self[handler](self, ...)
				end
			end
		else
			-- Standard method hook
			uid = function(...)
				if actives[uid] then
					return self[handler](self, ...)
				else
					return orig(...)
				end
			end
		end
	else
		-- Function-based hooks (handler is a function reference)
		if failsafe and not secure then
			-- Failsafe function hook
			uid = function(...)
				if actives[uid] then
					handler(...)
				end
				return orig(...)
			end
		elseif secure then
			-- Secure function hook
			uid = function(...)
				if actives[uid] then
					return handler(...)
				end
			end
		else
			-- Standard function hook
			uid = function(...)
				if actives[uid] then
					return handler(...)
				else
					return orig(...)
				end
			end
		end
	end

	return uid
end

function donothing() end

function hook(self, obj, method, handler, script, secure, raw, forceSecure, usage)
	if not handler then handler = method end

	-- These asserts make sure AceHooks's devs play by the rules.
	assert(not script or type(script) == "boolean")
	assert(not secure or type(secure) == "boolean")
	assert(not raw or type(raw) == "boolean")
	assert(not forceSecure or type(forceSecure) == "boolean")
	assert(usage)

	-- Error checking Battery!
	if obj and type(obj) ~= "table" then
		error(format(ERRORS.HOOK_OBJECT_INVALID, usage, type(obj)), 3)
	end
	if type(method) ~= "string" then
		error(format(ERRORS.HOOK_METHOD_INVALID, usage, type(method)), 3)
	end
	if type(handler) ~= "string" and type(handler) ~= "function" then
		error(format(ERRORS.HOOK_HANDLER_INVALID, usage, type(handler)), 3)
	end
	if type(handler) == "string" and type(self[handler]) ~= "function" then
		error(format(ERRORS.HOOK_HANDLER_MISSING, usage), 3)
	end

	-- Use cached string for method name to reduce memory allocations
	method = getCachedString(method)

	-- Fast path for script hooks - check script validity early
	if script then
		if not obj or not obj.GetScript or not obj:HasScript(method) then
			error(format(ERRORS.HOOK_SCRIPT_INVALID, usage), 3)
		end
		if not secure and obj.IsProtected and obj:IsProtected() and protectedScripts[method] then
			error(format(ERRORS.HOOK_SECURE_FORBIDDEN, method), 3)
		end
	else
		-- Fast path for secure checks
		local issecure
		if obj then
			-- Cache secure status check for objects
			issecure = onceSecure[obj] and onceSecure[obj][method] or issecurevariable(obj, method)
		else
			-- Cache secure status check for global functions
			issecure = onceSecure[method] or issecurevariable(method)
		end

		if issecure then
			if forceSecure then
				-- Cache the secure status for future checks
				if obj then
					onceSecure[obj] = onceSecure[obj] or {}
					onceSecure[obj][method] = true
				else
					onceSecure[method] = true
				end
			elseif not secure then
				error(format(ERRORS.HOOK_SECURE_REQUIRED, usage, method), 3)
			end
		end
	end

	-- Check for existing hook and handle appropriately
	local uid
	if obj then
		uid = registry[self][obj] and registry[self][obj][method]
	else
		uid = registry[self][method]
	end

	if uid then
		if actives[uid] then
			-- Only two sane choices exist here.  We either a) error 100% of the time or b) always unhook and then hook
			-- choice b would likely lead to odd debuging conditions or other mysteries so we're going with a.
			error(format(ERRORS.HOOK_ALREADY_ACTIVE, method))
		end

		if handlers[uid] == handler then
			-- Fast path: reactivate an existing hook with the same handler
			actives[uid] = true
			return
		else
			-- Clean up the old hook completely
			if obj then
				if self.hooks and self.hooks[obj] then
					self.hooks[obj][method] = nil
				end
				registry[self][obj][method] = nil
			else
				if self.hooks then
					self.hooks[method] = nil
				end
				registry[self][method] = nil
			end
			handlers[uid], actives[uid], scripts[uid] = nil, nil, nil
		end
	end

	-- Get the original function reference
	local orig
	if script then
		orig = obj:GetScript(method) or donothing
	elseif obj then
		orig = obj[method]
	else
		orig = _G[method]
	end

	if not orig then
		error(format(ERRORS.HOOK_TARGET_MISSING, usage), 3)
	end

	-- Create the hook function
	uid = createHook(self, handler, orig, secure, not (raw or secure))

	-- Set up all the hook infrastructure
	if obj then
		-- Pre-allocate tables to avoid repeated table creation
		self.hooks[obj] = self.hooks[obj] or {}
		registry[self][obj] = registry[self][obj] or {}
		registry[self][obj][method] = uid

		if not secure then
			self.hooks[obj][method] = orig
		end

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
		registry[self][method] = uid

		if not secure then
			_G[method] = uid
			self.hooks[method] = orig
		else
			hooksecurefunc(method, uid)
		end
	end

	-- Activate the hook and store metadata
	actives[uid], handlers[uid], scripts[uid] = true, handler, script and true or nil
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
-- @usage
-- -- create an addon with AceHook embeded
-- MyAddon = LibStub("AceAddon-3.0"):NewAddon("HookDemo", "AceHook-3.0")
--
-- function MyAddon:OnEnable()
--   -- Hook ActionButton_UpdateHotkeys, overwriting the secure status
--   self:Hook("ActionButton_UpdateHotkeys", true)
-- end
--
-- function MyAddon:ActionButton_UpdateHotkeys(button, type)
--   print(button:GetName() .. " is updating its HotKey")
-- end
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
-- @usage
-- -- create an addon with AceHook embeded
-- MyAddon = LibStub("AceAddon-3.0"):NewAddon("HookDemo", "AceHook-3.0")
--
-- function MyAddon:OnEnable()
--   -- Hook ActionButton_UpdateHotkeys, overwriting the secure status
--   self:RawHook("ActionButton_UpdateHotkeys", true)
-- end
--
-- function MyAddon:ActionButton_UpdateHotkeys(button, type)
--   if button:GetName() == "MyButton" then
--     -- do stuff here
--   else
--     self.hooks.ActionButton_UpdateHotkeys(button, type)
--   end
-- end
function AceHook:RawHook(object, method, handler, hookSecure)
	if type(object) == "string" then
		method, handler, hookSecure, object = object, method, handler, nil
	end

	if handler == true then
		handler, hookSecure = nil, true
	end

	hook(self, object, method, handler, false, false, true, hookSecure or false,  "Usage: RawHook([object], method, [handler], [hookSecure])")
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

	hook(self, object, method, handler, false, true, false, false,  "Usage: SecureHook([object], method, [handler])")
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
-- @usage
-- -- create an addon with AceHook embeded
-- MyAddon = LibStub("AceAddon-3.0"):NewAddon("HookDemo", "AceHook-3.0")
--
-- function MyAddon:OnEnable()
--   -- Hook the OnShow of FriendsFrame
--   self:HookScript(FriendsFrame, "OnShow", "FriendsFrameOnShow")
-- end
--
-- function MyAddon:FriendsFrameOnShow(frame)
--   print("The FriendsFrame was shown!")
-- end
function AceHook:HookScript(frame, script, handler)
	hook(self, frame, script, handler, true, false, false, false,  "Usage: HookScript(object, method, [handler])")
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
-- @usage
-- -- create an addon with AceHook embeded
-- MyAddon = LibStub("AceAddon-3.0"):NewAddon("HookDemo", "AceHook-3.0")
--
-- function MyAddon:OnEnable()
--   -- Hook the OnShow of FriendsFrame
--   self:RawHookScript(FriendsFrame, "OnShow", "FriendsFrameOnShow")
-- end
--
-- function MyAddon:FriendsFrameOnShow(frame)
--   -- Call the original function
--   self.hooks[frame].OnShow(frame)
--   -- Do our processing
--   -- .. stuff
-- end
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

--- Unhook from the specified function, method or script.
-- @paramsig [obj], method
-- @param obj The object or frame to unhook from
-- @param method The name of the method, function or script to unhook from.
function AceHook:Unhook(obj, method)
	local usage = "Usage: Unhook([obj], method)"

	-- Handle case where obj is not provided (global function)
	if type(obj) == "string" then
		method, obj = obj, nil
	end

	-- Validate parameters
	if obj and type(obj) ~= "table" then
		error(format(ERRORS.UNHOOK_OBJECT_INVALID, usage, type(obj)), 2)
	end
	if type(method) ~= "string" then
		error(format(ERRORS.UNHOOK_METHOD_INVALID, usage, type(method)), 2)
	end

	-- Use cached string for method name to reduce memory allocations
	method = getCachedString(method)

	-- Fast lookup for the hook UID
	local uid
	if obj then
		-- Fast path: check if registry exists for this object
		local objRegistry = registry[self][obj]
		if not objRegistry then return false end
		uid = objRegistry[method]
	else
		uid = registry[self][method]
	end

	-- If no hook exists or it's not active, return early
	if not uid or not actives[uid] then
		return false
	end

	-- Deactivate the hook
	actives[uid], handlers[uid] = nil, nil

	-- Clean up registry and restore original function if needed
	if obj then
		registry[self][obj][method] = nil

		-- Fast path: check if this was the last method for this object
		if not next(registry[self][obj]) then
			registry[self][obj] = nil
		end

		-- If not a secure hook, we need to restore the original function
		if self.hooks[obj] and self.hooks[obj][method] then
			if scripts[uid] and obj:GetScript(method) == uid then
				-- Restore original script handler
				local original = self.hooks[obj][method]
				obj:SetScript(method, original ~= donothing and original or nil)
			elseif obj[method] == uid then
				-- Restore original method
				obj[method] = self.hooks[obj][method]
			end

			-- Clean up hooks table
			self.hooks[obj][method] = nil

			-- Fast path: check if this was the last method for this object
			if not next(self.hooks[obj]) then
				self.hooks[obj] = nil
			end
		end
	else
		registry[self][method] = nil

		-- If not a secure hook, restore the original global function
		if self.hooks[method] then
			if _G[method] == uid then
				_G[method] = self.hooks[method]
			end
			self.hooks[method] = nil
		end
	end

	-- Clean up scripts table
	scripts[uid] = nil

	return true
end

--- Unhook all existing hooks for this addon.
function AceHook:UnhookAll()
	-- Optimized version with cached local references and direct table access
	local self_registry = registry[self]
	if not self_registry then return end

	-- Use a two-phase approach to avoid modification during iteration issues
	local unhookQueue = {}

	-- First phase: collect all hooks that need to be unhooked
	for key, value in pairs(self_registry) do
		if type(key) == "table" then
			-- Object methods
			for method in pairs(value) do
				tinsert(unhookQueue, {obj = key, method = method})
			end
		else
			-- Global functions
			tinsert(unhookQueue, {method = key})
		end
	end

	-- Second phase: unhook everything in the queue
	for i = 1, #unhookQueue do
		local hookData = unhookQueue[i]
		if hookData.obj then
			self:Unhook(hookData.obj, hookData.method)
		else
			self:Unhook(hookData.method)
		end
	end
end

--- Check if the specific function, method or script is already hooked.
-- @paramsig [obj], method
-- @param obj The object or frame to unhook from
-- @param method The name of the method, function or script to unhook from.
function AceHook:IsHooked(obj, method)
	-- Handle case where obj is not provided (global function)
	if type(obj) == "string" then
		method, obj = obj, nil
	end

	-- Fast path with direct table access
	if obj then
		-- Check if the object exists in registry
		local objRegistry = registry[self][obj]
		if not objRegistry then return false, nil end

		-- Check if the method exists and is active
		local uid = objRegistry[method]
		if uid and actives[uid] then
			return true, handlers[uid]
		end
	else
		-- Check if the global function exists and is active
		local uid = registry[self][method]
		if uid and actives[uid] then
			return true, handlers[uid]
		end
	end

	return false, nil
end

--- Upgrade our old embeded
for target, v in pairs( AceHook.embeded ) do
	AceHook:Embed( target )
end

