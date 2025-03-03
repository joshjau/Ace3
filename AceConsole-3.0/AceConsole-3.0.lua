--- **AceConsole-3.0** provides registration facilities for slash commands.
-- You can register slash commands to your custom functions and use the `GetArgs` function to parse them
-- to your addons individual needs.
--
-- **AceConsole-3.0** can be embeded into your addon, either explicitly by calling AceConsole:Embed(MyAddon) or by
-- specifying it as an embeded library in your AceAddon. All functions will be available on your addon object
-- and can be accessed directly, without having to explicitly call AceConsole itself.\\
-- It is recommended to embed AceConsole, otherwise you'll have to specify a custom `self` on all calls you
-- make into AceConsole.
-- @class file
-- @name AceConsole-3.0
-- @release $Id$
local MAJOR,MINOR = "AceConsole-3.0", 8

local AceConsole, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceConsole then return end -- No upgrade needed

AceConsole.embeds = AceConsole.embeds or {} -- table containing objects AceConsole is embedded in.
AceConsole.commands = AceConsole.commands or {} -- table containing commands registered
AceConsole.weakcommands = AceConsole.weakcommands or {} -- table containing self, command => func references for weak commands that don't persist through enable/disable

-- Lua APIs
local tconcat, tostring, select = table.concat, tostring, select
local type, pairs, error = type, pairs, error
local format, strfind, strsub = string.format, string.find, string.sub
local max = math.max
local wipe = table.wipe or function(t) for k in pairs(t) do t[k] = nil end return t end -- Compatibility for older Lua without table.wipe

-- WoW APIs
local _G = _G
local DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME
local SlashCmdList = SlashCmdList
local hash_SlashCmdList = hash_SlashCmdList

-- Reused message buffer to reduce GC pressure
local tmp = {}
local function Print(self, frame, ...)
	wipe(tmp)
	local n = 0

	-- Add addon name prefix if not AceConsole itself
	if self ~= AceConsole then
		tmp[1] = "|cff33ff99"..tostring(self).."|r:"
		n = 1
	end

	-- Convert all arguments to strings and add to buffer
	local numArgs = select("#", ...)
	for i = 1, numArgs do
		n = n + 1
		tmp[n] = tostring(select(i, ...))
	end

	-- Deliver message
	frame:AddMessage(tconcat(tmp, " ", 1, n))
end

--- Print to DEFAULT_CHAT_FRAME or given ChatFrame (anything with an .AddMessage function)
-- @paramsig [chatframe ,] ...
-- @param chatframe Custom ChatFrame to print to (or any frame with an .AddMessage function)
-- @param ... List of any values to be printed
function AceConsole:Print(...)
	local frame = ...
	if type(frame) == "table" and frame.AddMessage then	-- Is first argument something with an .AddMessage member?
		return Print(self, frame, select(2,...))
	else
		return Print(self, DEFAULT_CHAT_FRAME, ...)
	end
end


--- Formatted (using format()) print to DEFAULT_CHAT_FRAME or given ChatFrame (anything with an .AddMessage function)
-- @paramsig [chatframe ,] "format"[, ...]
-- @param chatframe Custom ChatFrame to print to (or any frame with an .AddMessage function)
-- @param format Format string - same syntax as standard Lua format()
-- @param ... Arguments to the format string
function AceConsole:Printf(...)
	local frame = ...
	if type(frame) == "table" and frame.AddMessage then	-- Is first argument something with an .AddMessage member?
		return Print(self, frame, format(select(2,...)))
	else
		return Print(self, DEFAULT_CHAT_FRAME, format(...))
	end
end


-- Command registration cache to reduce redundant calls
local cmd_registry_cache = {}

--- Register a simple chat command
-- @param command Chat command to be registered WITHOUT leading "/"
-- @param func Function to call when the slash command is being used (funcref or methodname)
-- @param persist if false, the command will be soft disabled/enabled when aceconsole is used as a mixin (default: true)
function AceConsole:RegisterChatCommand(command, func, persist)
	if type(command) ~= "string" then
		error([[Usage: AceConsole:RegisterChatCommand( "command", func[, persist ]): 'command' - expected a string]], 2)
	end

	if persist == nil then persist = true end	-- Default to persistent commands

	-- Use cached command name if possible to reduce string operations
	local name = cmd_registry_cache[command]
	if not name then
		name = "ACECONSOLE_" .. command:upper()
		cmd_registry_cache[command] = name
	end

	-- Create the slash command handler function
	if type(func) == "string" then
		local self_ref = self
		SlashCmdList[name] = function(input, editBox)
			self_ref[func](self_ref, input, editBox)
		end
	else
		SlashCmdList[name] = func
	end

	-- Set up the slash command
	_G["SLASH_" .. name .. "1"] = "/" .. command:lower()
	AceConsole.commands[command] = name

	-- non-persisting commands are registered for enabling/disabling
	if not persist then
		if not AceConsole.weakcommands[self] then
			AceConsole.weakcommands[self] = {}
		end
		AceConsole.weakcommands[self][command] = func
	end

	return true
end

--- Unregister a chatcommand
-- @param command Chat command to be unregistered WITHOUT leading "/"
function AceConsole:UnregisterChatCommand(command)
	local name = AceConsole.commands[command]
	if name then
		SlashCmdList[name] = nil
		_G["SLASH_" .. name .. "1"] = nil
		hash_SlashCmdList["/" .. command:upper()] = nil
		AceConsole.commands[command] = nil
	end
end

--- Get an iterator over all Chat Commands registered with AceConsole
-- @return Iterator (pairs) over all commands
function AceConsole:IterateChatCommands()
	return pairs(AceConsole.commands)
end

-- Recycle tables to reduce garbage collection
local argsCache = setmetatable({}, {__mode = "k"})

-- Helper function for returning multiple nil values
local function nils(n, ...)
	if n > 1 then
		return nil, nils(n-1, ...)
	elseif n == 1 then
		return nil, ...
	else
		return ...
	end
end

--- Retrieve one or more space-separated arguments from a string.
-- Treats quoted strings and itemlinks as non-spaced.
-- @param str The raw argument string
-- @param numargs How many arguments to get (default 1)
-- @param startpos Where in the string to start scanning (default 1)
-- @return Returns arg1, arg2, ..., nextposition\\
-- Missing arguments will be returned as nils. 'nextposition' is returned as 1e9 at the end of the string.
function AceConsole:GetArgs(str, numargs, startpos)
	numargs = numargs or 1
	startpos = max(startpos or 1, 1)

	-- Quick return if we're at the end of the string
	if startpos > #str then
		return nils(numargs, 1e9)
	end

	local pos = startpos

	-- Find start of the first argument
	pos = strfind(str, "[^ ]", pos)
	if not pos then  -- No more args, end of string
		return nils(numargs, 1e9)
	end

	if numargs < 1 then
		return pos
	end

	-- Determine delimiter pattern based on first character
	local ch = strsub(str, pos, pos)
	local delim_pattern

	if ch == '"' then
		pos = pos + 1
		delim_pattern = '([|"])'
	elseif ch == "'" then
		pos = pos + 1
		delim_pattern = "([|'])"
	else
		delim_pattern = "([| ])"
	end

	local arg_start = pos
	local arg_end = nil
	local delimiter = nil

	-- Find the end of this argument (delimiter or end of string)
	while not arg_end do
		-- Find next delimiter or hyperlink
		pos, _, delimiter = strfind(str, delim_pattern, pos)

		if not pos then
			-- End of string, return remainder as last argument
			return strsub(str, arg_start), nils(numargs-1, 1e9)
		end

		if delimiter == "|" then
			-- Handle WoW UI escape sequences
			if strsub(str, pos, pos+1) == "|H" then
				-- It's a |H....|hhyper link!|h
				pos = strfind(str, "|h", pos+2)  -- first |h
				if not pos then break end

				pos = strfind(str, "|h", pos+2)  -- second |h
				if not pos then break end

			elseif strsub(str, pos, pos+1) == "|T" then
				-- It's a |T....|t texture
				pos = strfind(str, "|t", pos+2)
				if not pos then break end
			end

			pos = pos + 2  -- Skip past this escape (or last |h)
		else
			-- Real delimiter found, extract the argument
			arg_end = pos - 1
		end
	end

	-- Extract the current argument and recursively get the next ones
	if arg_end then
		return strsub(str, arg_start, arg_end), AceConsole:GetArgs(str, numargs-1, pos+1)
	else
		-- This shouldn't normally happen, but handle it just in case
		return strsub(str, arg_start), nils(numargs-1, 1e9)
	end
end


--- embedding and embed handling

local mixins = {
	"Print",
	"Printf",
	"RegisterChatCommand",
	"UnregisterChatCommand",
	"GetArgs",
}

-- Cache for embed targets to prevent duplicate embedding
local embed_cache = {}

-- Embeds AceConsole into the target object making the functions from the mixins list available on target:..
-- @param target target object to embed AceBucket in
function AceConsole:Embed(target)
	-- Skip if already embedded
	if embed_cache[target] then return target end

	-- Add all mixin functions to the target
	for _, v in pairs(mixins) do
		target[v] = self[v]
	end

	-- Register in embeds table and cache
	self.embeds[target] = true
	embed_cache[target] = true

	return target
end

function AceConsole:OnEmbedEnable(target)
	if AceConsole.weakcommands[target] then
		-- Fast re-register all weak commands
		local wc = AceConsole.weakcommands[target]
		for command, func in pairs(wc) do
			target:RegisterChatCommand(command, func, false, true) -- nonpersisting and silent registry
		end
	end
end

function AceConsole:OnEmbedDisable(target)
	if AceConsole.weakcommands[target] then
		-- Fast unregister all weak commands
		local wc = AceConsole.weakcommands[target]
		for command in pairs(wc) do
			target:UnregisterChatCommand(command)
		end
	end
end

-- Initialize embeds for any existing addons
for addon in pairs(AceConsole.embeds) do
	embed_cache[addon] = true
	AceConsole:Embed(addon)
end
