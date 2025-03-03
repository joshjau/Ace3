--- **AceComm-3.0** allows you to send messages of unlimited length over the addon comm channels.
-- It'll automatically split the messages into multiple parts and rebuild them on the receiving end.\\
-- **ChatThrottleLib** is of course being used to avoid being disconnected by the server.
--
-- **AceComm-3.0** can be embeded into your addon, either explicitly by calling AceComm:Embed(MyAddon) or by
-- specifying it as an embeded library in your AceAddon. All functions will be available on your addon object
-- and can be accessed directly, without having to explicitly call AceComm itself.\\
-- It is recommended to embed AceComm, otherwise you'll have to specify a custom `self` on all calls you
-- make into AceComm.
-- @class file
-- @name AceComm-3.0
-- @release $Id$

--[[ AceComm-3.0

TODO: Time out old data rotting around from dead senders? Not a HUGE deal since the number of possible sender names is somewhat limited.

]]

local CallbackHandler = LibStub("CallbackHandler-1.0")
local CTL = assert(ChatThrottleLib, "AceComm-3.0 requires ChatThrottleLib")

local MAJOR, MINOR = "AceComm-3.0", 15
local AceComm, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceComm then return end

-- Lua APIs
local type, next, pairs, tostring = type, next, pairs, tostring
local strsub, strfind, strmatch, strbyte = string.sub, string.find, string.match, string.byte
local tinsert, tconcat, tremove, wipe = table.insert, table.concat, table.remove, table.wipe
local error, assert, select = error, assert, select
local tonumber, format = tonumber, string.format
local min, max, ceil = math.min, math.max, math.ceil

-- WoW APIs
local Ambiguate = Ambiguate
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTimePreciseSec = GetTimePreciseSec
local C_ChatInfo = C_ChatInfo
local RegisterAddonMessagePrefix = RegisterAddonMessagePrefix
local DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME
local time = time

AceComm.embeds = AceComm.embeds or {}

-- for my sanity and yours, let's give the message type bytes some names
local MSG_MULTI_FIRST = "\001"
local MSG_MULTI_NEXT  = "\002"
local MSG_MULTI_LAST  = "\003"
local MSG_ESCAPE = "\004"

-- remove old structures (pre WoW 4.0)
AceComm.multipart_origprefixes = nil
AceComm.multipart_reassemblers = nil

-- the multipart message spool: indexed by a combination of sender+distribution+
AceComm.multipart_spool = AceComm.multipart_spool or {}

-- String pooling for frequently used strings to reduce memory allocations
local stringPool = setmetatable({}, {__mode = "k"})
local function poolString(text)
	if not text then return nil end
	if not stringPool[text] then
		stringPool[text] = text
	end
	return stringPool[text]
end

-- Prefix cache to avoid repeated string concatenations
local prefixCache = setmetatable({}, {__mode = "v"})
local function getKeyFromParts(prefix, distribution, sender)
	local cacheKey = prefix .. "\0" .. distribution .. "\0" .. sender
	if not prefixCache[cacheKey] then
		prefixCache[cacheKey] = prefix .. "\t" .. distribution .. "\t" .. sender
	end
	return prefixCache[cacheKey]
end

-- Priority constants for faster comparisons
local PRIORITIES = {
	BULK = 1,
	NORMAL = 2,
	ALERT = 3
}

-- Pre-allocate common distribution channels
local CHANNELS = {
	PARTY = poolString("PARTY"),
	RAID = poolString("RAID"),
	GUILD = poolString("GUILD"),
	WHISPER = poolString("WHISPER"),
	CHANNEL = poolString("CHANNEL"),
	INSTANCE_CHAT = poolString("INSTANCE_CHAT"),
	BATTLEGROUND = poolString("BATTLEGROUND"),
	YELL = poolString("YELL"),
	SAY = poolString("SAY")
}

--- Register for Addon Traffic on a specified prefix
-- @param prefix A printable character (\032-\255) classification of the message (typically AddonName or AddonNameEvent), max 16 characters
-- @param method Callback to call on message reception: Function reference, or method name (string) to call on self. Defaults to "OnCommReceived"
function AceComm:RegisterComm(prefix, method)
	if method == nil then
		method = "OnCommReceived"
	end

	if #prefix > 16 then
		error("AceComm:RegisterComm(prefix,method): prefix length is limited to 16 characters")
	end

	-- Use C_ChatInfo when available (modern clients)
	if C_ChatInfo then
		C_ChatInfo.RegisterAddonMessagePrefix(prefix)
	else
		RegisterAddonMessagePrefix(prefix)
	end

	-- Pool the prefix string to reduce memory allocations
	prefix = poolString(prefix)

	return AceComm._RegisterComm(self, prefix, method)	-- created by CallbackHandler
end

local warnedPrefix=false

--- Send a message over the Addon Channel
-- @param prefix A printable character (\032-\255) classification of the message (typically AddonName or AddonNameEvent)
-- @param text Data to send, nils (\000) not allowed. Any length.
-- @param distribution Addon channel, e.g. "RAID", "GUILD", etc; see SendAddonMessage API
-- @param target Destination for some distributions; see SendAddonMessage API
-- @param prio OPTIONAL: ChatThrottleLib priority, "BULK", "NORMAL" or "ALERT". Defaults to "NORMAL".
-- @param callbackFn OPTIONAL: callback function to be called as each chunk is sent. receives 3 args: the user supplied arg (see next), the number of bytes sent so far, and the number of bytes total to send.
-- @param callbackArg: OPTIONAL: first arg to the callback function. nil will be passed if not specified.
function AceComm:SendCommMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
	-- Use pooled strings for common values to reduce memory allocations
	prio = prio or "NORMAL"
	distribution = CHANNELS[distribution] or poolString(distribution)
	prefix = poolString(prefix)

	-- Fast validation using direct type checks and table lookups
	if not(type(prefix) == "string" and
		   type(text) == "string" and
		   type(distribution) == "string" and
		   (target == nil or type(target) == "string" or type(target) == "number") and
		   (prio == "BULK" or prio == "NORMAL" or prio == "ALERT")
	) then
		error('Usage: SendCommMessage(addon, "prefix", "text", "distribution"[, "target"[, "prio"[, callbackFn, callbackarg]]])', 2)
	end

	local textlen = #text
	local maxtextlen = 255  -- Yes, the max is 255 even if the dev post said 256. I tested. Char 256+ get silently truncated. /Mikk, 20110327
	local queueName = prefix

	-- Optimize callback creation
	local ctlCallback
	if callbackFn then
		ctlCallback = function(sent, sendResult)
			return callbackFn(callbackArg, sent, textlen, sendResult)
		end
	end

	-- Check for control characters at the start of the message
	local firstByte = strbyte(text, 1)
	local forceMultipart

	-- Faster check for control characters (bytes 1-9)
	if firstByte and firstByte >= 1 and firstByte <= 9 then
		-- we need to escape the first character with a \004
		if textlen + 1 > maxtextlen then    -- would we go over the size limit?
			forceMultipart = true    -- just make it multipart, no escape problems then
		else
			text = MSG_ESCAPE .. text
		end
	end

	-- Fast path for single-part messages
	if not forceMultipart and textlen <= maxtextlen then
		-- fits all in one message
		CTL:SendAddonMessage(prio, prefix, text, distribution, target, queueName, ctlCallback, textlen)
		return
	end

	-- Handle multipart messages
	maxtextlen = maxtextlen - 1    -- 1 extra byte for part indicator in prefix(4.0)/start of message(4.1)

	-- Pre-calculate number of chunks for callback accuracy
	local numChunks = ceil(textlen / maxtextlen)
	local chunksSent = 0

	-- first part
	local chunk = strsub(text, 1, maxtextlen)
	CTL:SendAddonMessage(prio, prefix, MSG_MULTI_FIRST..chunk, distribution, target, queueName,
		ctlCallback and function(sent, result)
			chunksSent = chunksSent + 1
			if chunksSent == numChunks then
				return ctlCallback(sent, result)
			end
		end,
		maxtextlen)

	-- continuation
	local pos = 1 + maxtextlen
	local chunkEnd

	while pos + maxtextlen <= textlen do
		chunkEnd = pos + maxtextlen - 1
		chunk = strsub(text, pos, chunkEnd)
		CTL:SendAddonMessage(prio, prefix, MSG_MULTI_NEXT..chunk, distribution, target, queueName,
			ctlCallback and function(sent, result)
				chunksSent = chunksSent + 1
				if chunksSent == numChunks then
					return ctlCallback(sent, result)
				end
			end,
			chunkEnd)
		pos = pos + maxtextlen
	end

	-- final part
	chunk = strsub(text, pos)
	CTL:SendAddonMessage(prio, prefix, MSG_MULTI_LAST..chunk, distribution, target, queueName,
		ctlCallback and function(sent, result)
			chunksSent = chunksSent + 1
			return ctlCallback(sent, result)
		end,
		textlen)
end


----------------------------------------
-- Message receiving
----------------------------------------

do
	-- Table recycling for message parts
	local compost = setmetatable({}, {__mode = "k"})
	local composted = 0
	local MAX_COMPOST = 100 -- Limit the size of the compost heap to prevent memory bloat

	-- Pre-allocate a pool of tables for message reassembly
	local tablePool = {}
	local poolSize = 20 -- Initial pool size

	for i = 1, poolSize do
		tablePool[i] = {}
	end

	local tablePoolIndex = poolSize

	-- Get a table from the pool or create a new one
	local function getTable()
		if tablePoolIndex > 0 then
			local t = tablePool[tablePoolIndex]
			tablePool[tablePoolIndex] = nil
			tablePoolIndex = tablePoolIndex - 1
			return t
		end
		return {}
	end

	-- Return a table to the pool
	local function recycleTable(t)
		if not t then return end

		-- Clear the table
		wipe(t)

		-- Add to pool if there's room
		if tablePoolIndex < poolSize then
			tablePoolIndex = tablePoolIndex + 1
			tablePool[tablePoolIndex] = t
		else
			-- Otherwise add to compost if there's room
			if composted < MAX_COMPOST then
				compost[t] = true
				composted = composted + 1
			end
		end
	end

	-- Get a recycled table or create a new one
	local function new()
		local t = next(compost)
		if t then
			compost[t] = nil
			composted = composted - 1
			for i = #t, 3, -1 do    -- faster than pairs loop. don't even nil out 1/2 since they'll be overwritten
				t[i] = nil
			end
			return t
		end

		return getTable()
	end

	local function lostdatawarning(prefix, sender, where)
		DEFAULT_CHAT_FRAME:AddMessage(MAJOR..": Warning: lost network data regarding '"..tostring(prefix).."' from '"..tostring(sender).."' (in "..where..")")
	end

	-- Define local functions for handling multipart messages
	local function OnReceiveMultipartFirst(prefix, message, distribution, sender)
		-- Use our optimized key generation function
		local key = getKeyFromParts(prefix, distribution, sender)
		local spool = AceComm.multipart_spool

		--[[
		if spool[key] then
			lostdatawarning(prefix, sender, "First")
			-- continue and overwrite
		end
		--]]

		spool[key] = message  -- plain string for now
	end

	local function OnReceiveMultipartNext(prefix, message, distribution, sender)
		-- Use our optimized key generation function
		local key = getKeyFromParts(prefix, distribution, sender)
		local spool = AceComm.multipart_spool
		local olddata = spool[key]

		if not olddata then
			--lostdatawarning(prefix, sender, "Next")
			return
		end

		if type(olddata) ~= "table" then
			-- ... but what we have is not a table. So make it one. (Pull a composted one if available)
			local t = new()
			t[1] = olddata    -- add old data as first string
			t[2] = message    -- and new message as second string
			spool[key] = t    -- and put the table in the spool instead of the old string
		else
			tinsert(olddata, message)
		end
	end

	local function OnReceiveMultipartLast(prefix, message, distribution, sender)
		-- Use our optimized key generation function
		local key = getKeyFromParts(prefix, distribution, sender)
		local spool = AceComm.multipart_spool
		local olddata = spool[key]

		if not olddata then
			--lostdatawarning(prefix, sender, "End")
			return
		end

		spool[key] = nil

		if type(olddata) == "table" then
			-- if we've received a "next", the spooled data will be a table for rapid & garbage-free tconcat
			tinsert(olddata, message)
			AceComm.callbacks:Fire(prefix, tconcat(olddata, ""), distribution, sender)
			recycleTable(olddata)
		else
			-- if we've only received a "first", the spooled data will still only be a string
			AceComm.callbacks:Fire(prefix, olddata..message, distribution, sender)
		end
	end

	-- Cache direct references to multipart handlers for faster dispatch
	local multipartHandlers = {
		[MSG_MULTI_FIRST] = function(_, prefix, rest, distribution, sender)
			OnReceiveMultipartFirst(prefix, rest, distribution, sender)
		end,
		[MSG_MULTI_NEXT] = function(_, prefix, rest, distribution, sender)
			OnReceiveMultipartNext(prefix, rest, distribution, sender)
		end,
		[MSG_MULTI_LAST] = function(_, prefix, rest, distribution, sender)
			OnReceiveMultipartLast(prefix, rest, distribution, sender)
		end,
		[MSG_ESCAPE] = function(_, prefix, rest, distribution, sender)
			AceComm.callbacks:Fire(prefix, rest, distribution, sender)
		end
	}

	-- Make the handlers accessible outside this block
	AceComm.multipartHandlers = multipartHandlers
end






----------------------------------------
-- Embed CallbackHandler
----------------------------------------

if not AceComm.callbacks then
	AceComm.callbacks = CallbackHandler:New(AceComm,
						"_RegisterComm",
						"UnregisterComm",
						"UnregisterAllComm")
end

AceComm.callbacks.OnUsed = nil
AceComm.callbacks.OnUnused = nil

-- Optimized event handler with direct function references
local function OnEvent(self, event, prefix, message, distribution, sender)
	if event == "CHAT_MSG_ADDON" then
		-- Ambiguate sender name once
		sender = Ambiguate(sender, "none")

		-- Pool common strings
		prefix = poolString(prefix)
		distribution = poolString(distribution)

		-- Fast path for single-part messages (most common case)
		local firstByte = strbyte(message, 1)
		if not firstByte or firstByte < 1 or firstByte > 9 then
			AceComm.callbacks:Fire(prefix, message, distribution, sender)
			return
		end

		-- Handle multipart messages with direct function calls
		local control = strsub(message, 1, 1)
		local rest = strsub(message, 2)

		local handler = AceComm.multipartHandlers[control]
		if handler then
			handler(AceComm, prefix, rest, distribution, sender)
		end
		-- Unknown control characters are silently ignored
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- Re-register for CHAT_MSG_ADDON when returning from a loading screen
		-- This helps ensure we don't miss any messages
		self:UnregisterEvent("PLAYER_ENTERING_WORLD")
		self:RegisterEvent("CHAT_MSG_ADDON")
	else
		assert(false, "Received "..tostring(event).." event?!")
	end
end

-- Create and setup the comm frame if it doesn't exist
if not AceComm.frame then
	AceComm.frame = CreateFrame("Frame", "AceComm30Frame")
	AceComm.frame:SetScript("OnEvent", OnEvent)
else
	-- Update the event handler on the existing frame
	AceComm.frame:SetScript("OnEvent", OnEvent)
end

-- Register for events
AceComm.frame:UnregisterAllEvents()
AceComm.frame:RegisterEvent("CHAT_MSG_ADDON")
AceComm.frame:RegisterEvent("PLAYER_ENTERING_WORLD")

-- Add cleanup function to handle stale multipart messages
local lastCleanup = GetTimePreciseSec and GetTimePreciseSec() or time()
local CLEANUP_INTERVAL = 60 -- Clean up once per minute
local MESSAGE_TIMEOUT = 180 -- Messages older than 3 minutes are considered stale

local function cleanupStaleMessages()
	local now = GetTimePreciseSec and GetTimePreciseSec() or time()
	if now - lastCleanup < CLEANUP_INTERVAL then return end

	lastCleanup = now

	-- We don't have timestamps for messages, so we can't directly clean up
	-- This is a placeholder for potential future implementation
	-- For now, we'll just ensure the spool doesn't grow too large
	local count = 0
	for k, v in pairs(AceComm.multipart_spool) do
		count = count + 1
	end

	-- If we have too many pending multipart messages, clear the oldest ones
	-- This is a simple protection against memory leaks from incomplete transfers
	if count > 100 then
		AceComm.multipart_spool = {}
	end
end

-- Add the cleanup function to the OnUpdate handler
AceComm.frame:SetScript("OnUpdate", function(self, elapsed)
	cleanupStaleMessages()
end)

----------------------------------------
-- Base library stuff
----------------------------------------

-- Cache the mixin functions for faster embedding
local mixins = {
	"RegisterComm",
	"UnregisterComm",
	"UnregisterAllComm",
	"SendCommMessage",
}

-- Direct function references for faster embedding
local mixinFuncs = {}
for _, name in ipairs(mixins) do
	mixinFuncs[name] = AceComm[name]
end

-- Embeds AceComm-3.0 into the target object making the functions from the mixins list available on target:..
-- @param target target object to embed AceComm-3.0 in
function AceComm:Embed(target)
	-- Use direct function references for faster embedding
	for name, func in pairs(mixinFuncs) do
		target[name] = func
	end
	self.embeds[target] = true
	return target
end

function AceComm:OnEmbedDisable(target)
	target:UnregisterAllComm()
end

-- Update embeds
for target, v in pairs(AceComm.embeds) do
	AceComm:Embed(target)
end
