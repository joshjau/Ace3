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

-- Lua APIs
local type, next, pairs, tostring = type, next, pairs, tostring
local strsub, strfind, strlen = string.sub, string.find, string.len
local match, gmatch = string.match, string.gmatch
local tinsert, tconcat, tremove = table.insert, table.concat, table.remove
local error, assert = error, assert
local floor = math.floor
local bit = bit or _G.bit

-- WoW APIs
local Ambiguate = Ambiguate
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime

local MAJOR, MINOR = "AceComm-3.0", 15 -- Increment minor version
local AceComm,oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceComm then return end

-- Configuration for high-end systems
AceComm.config = {
	-- System-specific optimizations
	highEndSystem = true,  -- Flag for high-end system optimizations
	enableStringPool = true, -- Enable string pooling
	largeTableCache = 100,  -- Number of tables to pre-allocate
	messageChunkSize = 255, -- Maximum message chunk size (WoW limit)
	aggressiveCaching = true, -- Enable aggressive caching
}

-- Pre-allocate tables for message reassembly
AceComm.tableCache = AceComm.tableCache or {}
AceComm.tableCacheSize = 0
AceComm.maxTableCacheSize = AceComm.config.largeTableCache
AceComm.stringPool = AceComm.stringPool or {}

AceComm.embeds = AceComm.embeds or {}

-- for my sanity and yours, let's give the message type bytes some names
local MSG_MULTI_FIRST = "\001"
local MSG_MULTI_NEXT  = "\002"
local MSG_MULTI_LAST  = "\003"
local MSG_ESCAPE = "\004"

-- Storage for frequently used strings to avoid recreating them
local CommonStrings = {
	NORMAL = "NORMAL",
	BULK = "BULK",
	ALERT = "ALERT",
	multiPartPrefix = {},
}

-- Cache common prefixes with distributions
local function getCachedMultipartKey(prefix, distribution, sender)
	local prefixTable = CommonStrings.multiPartPrefix[prefix]
	if not prefixTable then
		prefixTable = {}
		CommonStrings.multiPartPrefix[prefix] = prefixTable
	end

	local distTable = prefixTable[distribution]
	if not distTable then
		distTable = {}
		prefixTable[distribution] = distTable
	end

	local key = distTable[sender]
	if not key then
		key = prefix.."\t"..distribution.."\t"..sender
		distTable[sender] = key
	end

	return key
end

-- remove old structures (pre WoW 4.0)
AceComm.multipart_origprefixes = nil
AceComm.multipart_reassemblers = nil

-- the multipart message spool: indexed by a combination of sender+distribution+
AceComm.multipart_spool = AceComm.multipart_spool or {}

--- Register for Addon Traffic on a specified prefix
-- @param prefix A printable character (\032-\255) classification of the message (typically AddonName or AddonNameEvent), max 16 characters
-- @param method Callback to call on message reception: Function reference, or method name (string) to call on self. Defaults to "OnCommReceived"
function AceComm:RegisterComm(prefix, method)
	if method == nil then
		method = "OnCommReceived"
	end

	if AceComm.config.highEndSystem then
		-- Fast path validation for high-performance systems
		if #prefix > 16 then
			error("AceComm:RegisterComm(prefix,method): prefix length is limited to 16 characters")
		end
	else
		-- Original validation path
		if #prefix > 16 then -- TODO: 15?
			error("AceComm:RegisterComm(prefix,method): prefix length is limited to 16 characters")
		end
	end

	-- Cache the C_ChatInfo call reference for better performance
	if C_ChatInfo then
		C_ChatInfo.RegisterAddonMessagePrefix(prefix)
	else
		RegisterAddonMessagePrefix(prefix)
	end

	return AceComm._RegisterComm(self, prefix, method)	-- created by CallbackHandler
end

--- Send a message over the Addon Channel
-- @param prefix A printable character (\032-\255) classification of the message (typically AddonName or AddonNameEvent)
-- @param text Data to send, nils (\000) not allowed. Any length.
-- @param distribution Addon channel, e.g. "RAID", "GUILD", etc; see SendAddonMessage API
-- @param target Destination for some distributions; see SendAddonMessage API
-- @param prio OPTIONAL: ChatThrottleLib priority, "BULK", "NORMAL" or "ALERT". Defaults to "NORMAL".
-- @param callbackFn OPTIONAL: callback function to be called as each chunk is sent. receives 3 args: the user supplied arg (see next), the number of bytes sent so far, and the number of bytes total to send.
-- @param callbackArg: OPTIONAL: first arg to the callback function. nil will be passed if not specified.
function AceComm:SendCommMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
	-- Use cached priority strings
	prio = prio or CommonStrings.NORMAL

	-- Fast path validation for high-performance systems
	if AceComm.config.highEndSystem then
		-- Fast path validation for common parameters
		if not(prefix and text and distribution) then
			error('Usage: SendCommMessage(addon, "prefix", "text", "distribution"[, "target"[, "prio"[, callbackFn, callbackarg]]])', 2)
		end
	else
		-- Original validation path
		if not(type(prefix)=="string" and
				type(text)=="string" and
				type(distribution)=="string" and
				(target==nil or type(target)=="string" or type(target)=="number") and
				(prio==CommonStrings.BULK or prio==CommonStrings.NORMAL or prio==CommonStrings.ALERT)
			) then
			error('Usage: SendCommMessage(addon, "prefix", "text", "distribution"[, "target"[, "prio"[, callbackFn, callbackarg]]])', 2)
		end
	end

	local textlen = strlen(text)
	local maxtextlen = AceComm.config.messageChunkSize  -- Maximum message length
	local queueName = prefix

	local ctlCallback = nil
	if callbackFn then
		ctlCallback = function(sent, sendResult)
			return callbackFn(callbackArg, sent, textlen, sendResult)
		end
	end

	-- Fast path for short messages (most common case)
	if textlen <= maxtextlen and not match(text, "^[\001-\009]") then
		CTL:SendAddonMessage(prio, prefix, text, distribution, target, queueName, ctlCallback, textlen)
		return
	end

	local forceMultipart
	if match(text, "^[\001-\009]") then -- 4.1+: see if the first character is a control character
		-- we need to escape the first character with a \004
		if textlen+1 > maxtextlen then	-- would we go over the size limit?
			forceMultipart = true	-- just make it multipart, no escape problems then
		else
			text = MSG_ESCAPE .. text
		end
	end

	if not forceMultipart and textlen <= maxtextlen then
		-- fits all in one message
		CTL:SendAddonMessage(prio, prefix, text, distribution, target, queueName, ctlCallback, textlen)
	else
		maxtextlen = maxtextlen - 1	-- 1 extra byte for part indicator in prefix(4.0)/start of message(4.1)

		-- Pre-calculate maximum chunk size and positions for better performance
		local numChunks = floor(textlen / maxtextlen) + (textlen % maxtextlen > 0 and 1 or 0)

		-- first part
		local chunk = strsub(text, 1, maxtextlen)
		CTL:SendAddonMessage(prio, prefix, MSG_MULTI_FIRST..chunk, distribution, target, queueName, ctlCallback, maxtextlen)

		-- continuation
		local pos = 1+maxtextlen
		local chunkNum = 2  -- Start at 2 since we already sent the first chunk

		-- Using a while loop with pre-calculated positions for efficiency
		while chunkNum < numChunks do
			chunk = strsub(text, pos, pos+maxtextlen-1)
			CTL:SendAddonMessage(prio, prefix, MSG_MULTI_NEXT..chunk, distribution, target, queueName, ctlCallback, pos+maxtextlen-1)
			pos = pos + maxtextlen
			chunkNum = chunkNum + 1
		end

		-- final part
		chunk = strsub(text, pos)
		CTL:SendAddonMessage(prio, prefix, MSG_MULTI_LAST..chunk, distribution, target, queueName, ctlCallback, textlen)
	end
end


----------------------------------------
-- Message receiving
----------------------------------------

do
	-- Replace weak table with direct table for high-end systems
	-- Pre-allocate a pool of tables for message reassembly
	local function initializeTableCache()
		if AceComm.tableCacheSize < AceComm.maxTableCacheSize then
			local numToCreate = AceComm.maxTableCacheSize - AceComm.tableCacheSize
			for i = 1, numToCreate do
				AceComm.tableCache[AceComm.tableCacheSize + i] = {}
			end
			AceComm.tableCacheSize = AceComm.maxTableCacheSize
		end
	end

	-- Initialize table cache on library load
	initializeTableCache()

	-- Get a table from cache or create a new one
	local function new()
		if AceComm.tableCacheSize > 0 then
			local t = AceComm.tableCache[AceComm.tableCacheSize]
			AceComm.tableCache[AceComm.tableCacheSize] = nil
			AceComm.tableCacheSize = AceComm.tableCacheSize - 1
			return t
		end
		return {}
	end

	-- Recycle a table back to the cache
	local function recycle(t)
		if AceComm.tableCacheSize < AceComm.maxTableCacheSize then
			for i = #t, 1, -1 do
				t[i] = nil
			end
			AceComm.tableCacheSize = AceComm.tableCacheSize + 1
			AceComm.tableCache[AceComm.tableCacheSize] = t
			return true
		end
		return false
	end

	local function lostdatawarning(prefix,sender,where)
		DEFAULT_CHAT_FRAME:AddMessage(MAJOR..": Warning: lost network data regarding '"..tostring(prefix).."' from '"..tostring(sender).."' (in "..where..")")
	end

	-- Internal methods with underscore prefix to indicate they're private
	function AceComm:_OnReceiveMultipartFirst(prefix, message, distribution, sender)
		-- Use cached keys for common prefix+distribution+sender combinations
		local key = getCachedMultipartKey(prefix, distribution, sender)
		local spool = AceComm.multipart_spool

		--[[
		if spool[key] then
			lostdatawarning(prefix,sender,"First")
			-- continue and overwrite
		end
		--]]

		spool[key] = message  -- plain string for now
	end

	function AceComm:_OnReceiveMultipartNext(prefix, message, distribution, sender)
		-- Use cached keys for common prefix+distribution+sender combinations
		local key = getCachedMultipartKey(prefix, distribution, sender)
		local spool = AceComm.multipart_spool
		local olddata = spool[key]

		if not olddata then
			--lostdatawarning(prefix,sender,"Next")
			return
		end

		if type(olddata)~="table" then
			-- ... but what we have is not a table. So make it one.
			local t = new()
			t[1] = olddata    -- add old data as first string
			t[2] = message    -- and new message as second string
			spool[key] = t    -- and put the table in the spool instead of the old string
		else
			tinsert(olddata, message)
		end
	end

	function AceComm:_OnReceiveMultipartLast(prefix, message, distribution, sender)
		-- Use cached keys for common prefix+distribution+sender combinations
		local key = getCachedMultipartKey(prefix, distribution, sender)
		local spool = AceComm.multipart_spool
		local olddata = spool[key]

		if not olddata then
			--lostdatawarning(prefix,sender,"End")
			return
		end

		spool[key] = nil

		if type(olddata) == "table" then
			-- if we've received a "next", the spooled data will be a table for rapid & garbage-free tconcat
			tinsert(olddata, message)
			AceComm.callbacks:Fire(prefix, tconcat(olddata, ""), distribution, sender)
			recycle(olddata)
		else
			-- if we've only received a "first", the spooled data will still only be a string
			AceComm.callbacks:Fire(prefix, olddata..message, distribution, sender)
		end
	end
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

-- Create direct references to control bytes for faster comparison
local CONTROL_BYTE_MULTI_FIRST = strsub(MSG_MULTI_FIRST, 1, 1)
local CONTROL_BYTE_MULTI_NEXT = strsub(MSG_MULTI_NEXT, 1, 1)
local CONTROL_BYTE_MULTI_LAST = strsub(MSG_MULTI_LAST, 1, 1)
local CONTROL_BYTE_ESCAPE = strsub(MSG_ESCAPE, 1, 1)

local function OnEvent(self, event, prefix, message, distribution, sender)
	if event == "CHAT_MSG_ADDON" then
		sender = Ambiguate(sender, "none")

		-- Fast path for single-part messages (most common case)
		local firstChar = strsub(message, 1, 1)
		if firstChar < "\001" or firstChar > "\009" then
			-- Not a control character, so it's a single-part message
			AceComm.callbacks:Fire(prefix, message, distribution, sender)
			return
		end

		-- Process multi-part or escaped messages
		local control, rest = strsub(message, 1, 1), strsub(message, 2)

		if control == CONTROL_BYTE_MULTI_FIRST then
			AceComm:_OnReceiveMultipartFirst(prefix, rest, distribution, sender)
		elseif control == CONTROL_BYTE_MULTI_NEXT then
			AceComm:_OnReceiveMultipartNext(prefix, rest, distribution, sender)
		elseif control == CONTROL_BYTE_MULTI_LAST then
			AceComm:_OnReceiveMultipartLast(prefix, rest, distribution, sender)
		elseif control == CONTROL_BYTE_ESCAPE then
			AceComm.callbacks:Fire(prefix, rest, distribution, sender)
		else
			-- unknown control character, ignore SILENTLY (dont warn unnecessarily about future extensions!)
		end
	else
		assert(false, "Received "..tostring(event).." event?!")
	end
end

-- Pre-create frame on library load
AceComm.frame = AceComm.frame or CreateFrame("Frame", "AceComm30Frame")
AceComm.frame:SetScript("OnEvent", OnEvent)
AceComm.frame:UnregisterAllEvents()
AceComm.frame:RegisterEvent("CHAT_MSG_ADDON")


----------------------------------------
-- Base library stuff
----------------------------------------

local mixins = {
	"RegisterComm",
	"UnregisterComm",
	"UnregisterAllComm",
	"SendCommMessage",
}

-- Embeds AceComm-3.0 into the target object making the functions from the mixins list available on target:..
-- @param target target object to embed AceComm-3.0 in
function AceComm:Embed(target)
	for k, v in pairs(mixins) do
		target[v] = self[v]
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

-- Initialize performance optimizations
do
    -- Pre-allocate string pool for common message types
    if AceComm.config.enableStringPool then
        -- Create pools for common message strings
        for i = 1, 20 do
            local msg = "PING" .. i
            AceComm.stringPool[msg] = msg
            msg = "ACK" .. i
            AceComm.stringPool[msg] = msg
        end
    end

    -- Initialize the message chunk size
    if AceComm.config.messageChunkSize > 255 then
        AceComm.config.messageChunkSize = 255 -- Enforce WoW limit
    end

    -- Create a direct reference to the Fire method with correct context
    AceComm.FireCallback = function(prefix, message, distribution, sender)
        return AceComm.callbacks:Fire(prefix, message, distribution, sender)
    end

    -- System-specific optimizations log
    if AceComm.config.highEndSystem then
        -- Log optimization status to help with debugging
        -- Keep commented out by default, uncomment for debugging
        --print(MAJOR .. ": High-end system optimizations enabled (v" .. MINOR .. ")")
    end
end
