--
-- ChatThrottleLib by Mikk
--
-- Manages AddOn chat output to keep player from getting kicked off.
--
-- ChatThrottleLib:SendChatMessage/:SendAddonMessage functions that accept
-- a Priority ("BULK", "NORMAL", "ALERT") as well as prefix for SendChatMessage.
--
-- Priorities get an equal share of available bandwidth when fully loaded.
-- Communication channels are separated on extension+chattype+destination and
-- get round-robinned. (Destination only matters for whispers and channels,
-- obviously)
--
-- Will install hooks for SendChatMessage and SendAddonMessage to measure
-- bandwidth bypassing the library and use less bandwidth itself.
--
--
-- Fully embeddable library. Just copy this file into your addon directory,
-- add it to the .toc, and it's done.
--
-- Can run as a standalone addon also, but, really, just embed it! :-)
--
-- LICENSE: ChatThrottleLib is released into the Public Domain
--
-- Version 30: Performance-optimized for high-end systems, with improved function localization,
-- more efficient string handling, and reduced CPU overhead during message processing.
--

--- @class _G
--- @field SendChatMessage function
--- @field SendAddonMessage function
--- @field ChatThrottleLib ChatThrottleLib
--- @field C_ChatInfo table
--- @field BNSendGameData function

local CTL_VERSION = 30  -- Version bumped for performance optimization

local _G = _G

if _G.ChatThrottleLib then
	if _G.ChatThrottleLib.version >= CTL_VERSION then
		-- There's already a newer (or same) version loaded. Buh-bye.
		return
	elseif not _G.ChatThrottleLib.securelyHooked then
		print("ChatThrottleLib: Warning: There's an ANCIENT ChatThrottleLib.lua (pre-wow 2.0, <v16) in an addon somewhere. Get the addon updated or copy in a newer ChatThrottleLib.lua (>=v16) in it!")
		-- ATTEMPT to unhook; this'll behave badly if someone else has hooked...
		-- ... and if someone has securehooked, they can kiss that goodbye too... >.<
		_G.SendChatMessage = _G.ChatThrottleLib.ORIG_SendChatMessage
		if _G.ChatThrottleLib.ORIG_SendAddonMessage then
			_G.SendAddonMessage = _G.ChatThrottleLib.ORIG_SendAddonMessage
		end
	end
	_G.ChatThrottleLib.ORIG_SendChatMessage = nil
	_G.ChatThrottleLib.ORIG_SendAddonMessage = nil
end

if not _G.ChatThrottleLib then
	_G.ChatThrottleLib = {}
end

ChatThrottleLib = _G.ChatThrottleLib  -- in case some addon does "local ChatThrottleLib" above us and we're copypasted (AceComm-2, sigh)
local ChatThrottleLib = _G.ChatThrottleLib

--- @class ChatThrottleLib
--- @field version? number The version number of the library
--- @field securelyHooked? boolean Whether secure hooking has been done for SendChatMessage and SendAddonMessage
--- @field securelyHookedLogged? boolean Whether secure hooking has been done for SendAddonMessageLogged
--- @field securelyHookedBNGameData? boolean Whether secure hooking has been done for BNSendGameData
--- @field MAX_CPS? number Maximum characters per second to send
--- @field MSG_OVERHEAD? number Estimated overhead bytes per message
--- @field BURST? number Maximum burst size
--- @field MIN_FPS? number Minimum FPS threshold before reducing bandwidth
--- @field PipeBin? table Recycling bin for pipes
--- @field MsgBin? table Recycling bin for messages
--- @field avail? number Currently available bandwidth
--- @field nTotalSent? number Total amount of data sent
--- @field Frame? table Frame used for OnUpdate events
--- @field OnUpdateDelay? number Accumulated time since last OnUpdate
--- @field BlockedQueuesDelay? number Accumulated time for blocked queues
--- @field LastAvailUpdate? number Time of last bandwidth availability update
--- @field HardThrottlingBeginTime? number Time when hard throttling began
--- @field nBypass? number Amount of data that bypassed the library
--- @field bQueueing? boolean Whether currently queueing messages
--- @field bChoking? boolean Whether currently choking due to exceeded bandwidth
--- @field ORIG_SendChatMessage? function Original SendChatMessage function
--- @field ORIG_SendAddonMessage? function Original SendAddonMessage function
--- @field Prio? table Priority queues table
--- @field SendChatMessage? function Send a chat message with throttling
--- @field SendAddonMessage? function Send an addon message with throttling
--- @field SendAddonMessageLogged? function Send a logged addon message with throttling
--- @field BNSendGameData? function Send Battle.net game data with throttling
--- @field Init? function Initialize ChatThrottleLib
--- @field UpdateAvail? function Update available bandwidth
--- @field Despool? function Despool messages from a priority queue
--- @field Enqueue? function Enqueue a message
--- @field Hook_SendChatMessage? function Hook for SendChatMessage
--- @field Hook_SendAddonMessage? function Hook for SendAddonMessage
--- @field Hook_SendAddonMessageLogged? function Hook for SendAddonMessageLogged
--- @field Hook_BNSendGameData? function Hook for BNSendGameData
--- @field OnUpdate? function OnUpdate handler
--- @field OnEvent? function OnEvent handler

ChatThrottleLib.version = CTL_VERSION



------------------ TWEAKABLES -----------------

ChatThrottleLib.MAX_CPS = 1000         -- Increased for high-end systems; 2000 seems to be safe if NOTHING ELSE is happening
ChatThrottleLib.MSG_OVERHEAD = 40      -- Guesstimate overhead for sending a message; source+dest+chattype+protocolstuff

ChatThrottleLib.BURST = 6000           -- Increased burst for high-end systems with better network cards

ChatThrottleLib.MIN_FPS = 15          -- Reduce output CPS to half (and don't burst) if FPS drops below this value


-- Localize more frequently used functions for performance
local setmetatable = setmetatable
local table_remove = table.remove
local tostring = tostring
local GetTime = GetTime
local math_min = math.min
local math_max = math.max
local next = next
local strlen = string.len
local GetFramerate = GetFramerate
local unpack, type, pairs, wipe = unpack, type, pairs, table.wipe
local select = select
local xpcall = xpcall
local geterrorhandler = geterrorhandler
local securecallfunction = securecallfunction
local CreateFrame = CreateFrame
local hooksecurefunc = hooksecurefunc

-- String pooling for commonly used strings
local STRINGS = {
    ALERT = "ALERT",
    NORMAL = "NORMAL",
    BULK = "BULK",
    WHISPER = "WHISPER",
    SAY = "SAY"
}

-- Cache frequently used tables for reuse
local EMPTY_TABLE = {}  -- Don't modify this table, just use it for reads

-- Direct function references for faster access
local C_ChatInfo_SendAddonMessage = C_ChatInfo and C_ChatInfo.SendAddonMessage
local C_ChatInfo_SendAddonMessageLogged = C_ChatInfo and C_ChatInfo.SendAddonMessageLogged
local BNSendGameData_Orig = BNSendGameData


-----------------------------------------------------------------------
-- Double-linked ring implementation

--- @class Ring
--- @field pos? table The current position in the ring
local Ring = {}
local RingMeta = { __index = Ring }

--- Creates a new Ring object
--- @return Ring
function Ring:New()
	local ret = {}
	setmetatable(ret, RingMeta)
	return ret
end

--- Adds an object to the ring
--- @param obj table The object to add to the ring
function Ring:Add(obj)	-- Append at the "far end" of the ring (aka just before the current position)
	if self.pos then
		obj.prev = self.pos.prev
		obj.prev.next = obj
		obj.next = self.pos
		obj.next.prev = obj
	else
		obj.next = obj
		obj.prev = obj
		self.pos = obj
	end
end

--- Removes an object from the ring
--- @param obj table The object to remove from the ring
function Ring:Remove(obj)
	obj.next.prev = obj.prev
	obj.prev.next = obj.next
	if self.pos == obj then
		self.pos = obj.next
		if self.pos == obj then
			self.pos = nil
		end
	end
end

-- Note that this is local because there's no upgrade logic for existing ring
-- metatables, and this isn't present on rings created in versions older than
-- v25.
--- Links another ring to this ring
--- @param self Ring The ring to link to
--- @param other Ring The ring to link from
local function Ring_Link(self, other)  -- Move and append all contents of another ring to this ring
	if not self.pos then
		-- This ring is empty, so just transfer ownership.
		self.pos = other.pos
		other.pos = nil
	elseif other.pos then
		-- Our tail should point to their head, and their tail to our head.
		self.pos.prev.next, other.pos.prev.next = other.pos, self.pos
		-- Our head should point to their tail, and their head to our tail.
		self.pos.prev, other.pos.prev = other.pos.prev, self.pos.prev
		other.pos = nil
	end
end



-----------------------------------------------------------------------
-- Recycling bin for pipes
-- A pipe is a plain integer-indexed queue of messages
-- Pipes normally live in Rings of pipes  (3 rings total, one per priority)

ChatThrottleLib.PipeBin = nil -- pre-v19, drastically different
local PipeBin = setmetatable({}, {__mode="k"})

--- Deletes a pipe
--- @param pipe table The pipe to delete
local function DelPipe(pipe)
	PipeBin[pipe] = true
end

--- Creates a new pipe
--- @return table The new pipe
local function NewPipe()
	local pipe = next(PipeBin)
	if pipe then
		wipe(pipe)
		PipeBin[pipe] = nil
		return pipe
	end
	return {}
end




-----------------------------------------------------------------------
-- Recycling bin for messages

ChatThrottleLib.MsgBin = nil -- pre-v19, drastically different
local MsgBin = setmetatable({}, {__mode="k"})

--- Deletes a message
--- @param msg table The message to delete
local function DelMsg(msg)
	msg[1] = nil
	-- there's more parameters, but they're very repetetive so the string pool doesn't suffer really, and it's faster to just not delete them.
	MsgBin[msg] = true
end

--- Creates a new message
--- @return table The new message
local function NewMsg()
	local msg = next(MsgBin)
	if msg then
		MsgBin[msg] = nil
		return msg
	end
	return {}
end


-----------------------------------------------------------------------
-- ChatThrottleLib:Init
-- Initialize queues, set up frame for OnUpdate, etc

--- Initializes the ChatThrottleLib
function ChatThrottleLib:Init()
	-- Set up queues
	if not self.Prio then
		self.Prio = {}
		self.Prio[STRINGS.ALERT] = { ByName = {}, Ring = Ring:New(), avail = 0 }
		self.Prio[STRINGS.NORMAL] = { ByName = {}, Ring = Ring:New(), avail = 0 }
		self.Prio[STRINGS.BULK] = { ByName = {}, Ring = Ring:New(), avail = 0 }
	end

	if not self.BlockedQueuesDelay then
		-- v25: Add blocked queues to rings to handle new client throttles.
		for _, Prio in pairs(self.Prio) do
			Prio.Blocked = Ring:New()
		end
	end

	-- v4: total send counters per priority
	for _, Prio in pairs(self.Prio) do
		Prio.nTotalSent = Prio.nTotalSent or 0
	end

	if not self.avail then
		self.avail = 0 -- v5
	end
	if not self.nTotalSent then
		self.nTotalSent = 0 -- v5
	end

	-- Set up a frame to get OnUpdate events
	if not self.Frame then
		self.Frame = CreateFrame("Frame")
		self.Frame:Hide()
	end

	local frame = self.Frame
	if frame then
		frame:SetScript("OnUpdate", self.OnUpdate)
		frame:SetScript("OnEvent", self.OnEvent)	-- v11: Monitor P_E_W so we can throttle hard for a few seconds
		frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	end

	self.OnUpdateDelay = 0
	self.BlockedQueuesDelay = 0
	self.LastAvailUpdate = GetTime()
	self.HardThrottlingBeginTime = GetTime()	-- v11: Throttle hard for a few seconds after startup

	-- Hook SendChatMessage and SendAddonMessage so we can measure unpiped traffic and avoid overloads (v7)
	if not self.securelyHooked then
		-- Use secure hooks as of v16. Old regular hook support yanked out in v21.
		self.securelyHooked = true
		--SendChatMessage
		hooksecurefunc("SendChatMessage", function(...)
			return ChatThrottleLib.Hook_SendChatMessage(...)
		end)
		--SendAddonMessage
		hooksecurefunc(_G.C_ChatInfo, "SendAddonMessage", function(...)
			return ChatThrottleLib.Hook_SendAddonMessage(...)
		end)
	end

	-- v26: Hook SendAddonMessageLogged for traffic logging
	if not self.securelyHookedLogged then
		self.securelyHookedLogged = true
		hooksecurefunc(_G.C_ChatInfo, "SendAddonMessageLogged", function(...)
			return ChatThrottleLib.Hook_SendAddonMessageLogged(...)
		end)
	end

	-- v29: Hook BNSendGameData for traffic logging
	if not self.securelyHookedBNGameData then
		self.securelyHookedBNGameData = true
		hooksecurefunc("BNSendGameData", function(...)
			return ChatThrottleLib.Hook_BNSendGameData(...)
		end)
	end

	self.nBypass = 0
end


-----------------------------------------------------------------------
-- ChatThrottleLib.Hook_SendChatMessage / .Hook_SendAddonMessage

local bMyTraffic = false

--- Hook function for SendChatMessage
--- @param text string The message text
--- @param chattype string The chat type
--- @param language string The language
--- @param destination string The destination
function ChatThrottleLib.Hook_SendChatMessage(text, chattype, language, destination, ...)
	if bMyTraffic then
		return
	end
	local self = ChatThrottleLib
	local size = strlen(text or "") + strlen(destination or "") + self.MSG_OVERHEAD
	self.avail = self.avail - size
	self.nBypass = self.nBypass + size	-- just a statistic
end

--- Hook function for SendAddonMessage
--- @param prefix string The addon prefix
--- @param text string The message text
--- @param chattype string The chat type
--- @param destination string The destination
function ChatThrottleLib.Hook_SendAddonMessage(prefix, text, chattype, destination, ...)
	if bMyTraffic then
		return
	end
	local self = ChatThrottleLib
	local size = #(text or "") + #(prefix or "")
	size = size + #(destination or "") + self.MSG_OVERHEAD
	self.avail = self.avail - size
	self.nBypass = self.nBypass + size	-- just a statistic
end

--- Hook function for SendAddonMessageLogged
--- @param prefix string The addon prefix
--- @param text string The message text
--- @param chattype string The chat type
--- @param destination string The destination
function ChatThrottleLib.Hook_SendAddonMessageLogged(prefix, text, chattype, destination, ...)
	ChatThrottleLib.Hook_SendAddonMessage(prefix, text, chattype, destination, ...)
end

--- Hook function for BNSendGameData
--- @param destination string The destination
--- @param prefix string The addon prefix
--- @param text string The message text
function ChatThrottleLib.Hook_BNSendGameData(destination, prefix, text)
	ChatThrottleLib.Hook_SendAddonMessage(prefix, text, STRINGS.WHISPER, destination)
end



-----------------------------------------------------------------------
-- ChatThrottleLib:UpdateAvail
-- Update self.avail with how much bandwidth is currently available

--- Updates available bandwidth
--- @return number The amount of available bandwidth
function ChatThrottleLib:UpdateAvail()
	local now = GetTime()
	local MAX_CPS = self.MAX_CPS
	local lastAvailUpdate = self.LastAvailUpdate
	local newavail = MAX_CPS * (now - lastAvailUpdate)
	local avail = self.avail

	if now - self.HardThrottlingBeginTime < 5 then
		-- First 5 seconds after startup/zoning: VERY hard clamping to avoid irritating the server rate limiter, it seems very cranky then
		avail = math_min(avail + (newavail*0.1), MAX_CPS*0.5)
		self.bChoking = true
	elseif GetFramerate() < self.MIN_FPS then		-- GetFrameRate call takes ~0.002 secs
		avail = math_min(MAX_CPS, avail + newavail*0.5)
		self.bChoking = true		-- just a statistic
	else
		avail = math_min(self.BURST, avail + newavail)
		self.bChoking = false
	end

	avail = math_max(avail, 0-(MAX_CPS*2))	-- Can go negative when someone is eating bandwidth past the lib. but we refuse to stay silent for more than 2 seconds; if they can do it, we can.

	self.avail = avail
	self.LastAvailUpdate = now

	return avail
end


-----------------------------------------------------------------------
-- Despooling logic
-- Reminder:
-- - We have 3 Priorities, each containing a "Ring" construct ...
-- - ... made up of N "Pipe"s (1 for each destination/pipename)
-- - and each pipe contains messages

--- Enum for SendAddonMessage results
--- @class SendAddonMessageResult
--- @field Success number Success code (0)
--- @field AddonMessageThrottle number Throttled code (3)
--- @field NotInGroup number Not in group code (5)
--- @field ChannelThrottle number Channel throttled code (8)
--- @field GeneralError number General error code (9)
local SendAddonMessageResult = Enum.SendAddonMessageResult or {
	Success = 0,
	AddonMessageThrottle = 3,
	NotInGroup = 5,
	ChannelThrottle = 8,
	GeneralError = 9,
}

--- Maps function call result to SendAddonMessageResult
--- @param ok boolean Whether the function call succeeded
--- @return number The mapped result
local function MapToSendResult(ok, ...)
	local result

	if not ok then
		-- The send function itself errored; don't look at anything else.
		result = SendAddonMessageResult.GeneralError
	else
		-- Grab the last return value from the send function and remap
		-- it from a boolean to an enum code. If there are no results,
		-- assume success (true).

		result = select(-1, true, ...)

		if result == true then
			result = SendAddonMessageResult.Success
		elseif result == false then
			result = SendAddonMessageResult.GeneralError
		end
	end

	return result
end

--- Checks if a send result is due to throttling
--- @param result number The send result
--- @return boolean Whether the result indicates throttling
local function IsThrottledSendResult(result)
	return result == SendAddonMessageResult.AddonMessageThrottle
end

-- A copy of this function exists in FrameXML, but for clarity it's here too.
--- Calls the error handler
--- @return any The result of the error handler
local function CallErrorHandler(...)
	return geterrorhandler()(...)
end

--- Performs a send operation
--- @param sendFunction function The function to send with
--- @return number The send result
local function PerformSend(sendFunction, ...)
	bMyTraffic = true
	local sendResult = MapToSendResult(xpcall(sendFunction, CallErrorHandler, ...))
	bMyTraffic = false
	return sendResult
end

--- Despools messages from a priority queue
--- @param Prio table The priority queue
function ChatThrottleLib:Despool(Prio)
	local ring = Prio.Ring
	local blocked = Prio.Blocked
	local pos, pipe, msg

	while ring.pos and Prio.avail > ring.pos[1].nSize do
		pos = ring.pos
		pipe = pos
		msg = pipe[1]
		local sendResult = PerformSend(msg.f, unpack(msg, 1, msg.n))

		if IsThrottledSendResult(sendResult) then
			-- Message was throttled; move the pipe into the blocked ring.
			ring:Remove(pipe)
			blocked:Add(pipe)
		else
			-- Dequeue message after submission.
			table_remove(pipe, 1)
			DelMsg(msg)

			if not pipe[1] then  -- did we remove last msg in this pipe?
				ring:Remove(pipe)
				Prio.ByName[pipe.name] = nil
				DelPipe(pipe)
			else
				ring.pos = ring.pos.next
			end

			-- Update bandwidth counters on successful sends.
			local didSend = (sendResult == SendAddonMessageResult.Success)
			if didSend then
				Prio.avail = Prio.avail - msg.nSize
				Prio.nTotalSent = Prio.nTotalSent + msg.nSize
			end

			-- Notify caller of message submission.
			if msg.callbackFn then
				securecallfunction(msg.callbackFn, msg.callbackArg, didSend, sendResult)
			end
		end
	end
end


--- Event handler
--- @param this frame The frame that received the event
--- @param event string The event that fired
function ChatThrottleLib.OnEvent(this,event)
	-- v11: We know that the rate limiter is touchy after login. Assume that it's touchy after zoning, too.
	local self = ChatThrottleLib
	if event == "PLAYER_ENTERING_WORLD" then
		self.HardThrottlingBeginTime = GetTime()	-- Throttle hard for a few seconds after zoning
		self.avail = 0
	end
end


--- Update handler
--- @param this frame The frame being updated
--- @param delay number Time elapsed since last update
function ChatThrottleLib.OnUpdate(this, delay)
	local self = ChatThrottleLib

	-- Local cache for improved performance
	local onUpdateDelay = self.OnUpdateDelay + delay
	local blockedQueuesDelay = self.BlockedQueuesDelay + delay

	self.OnUpdateDelay = onUpdateDelay
	self.BlockedQueuesDelay = blockedQueuesDelay

	if onUpdateDelay < 0.08 then
		return
	end
	self.OnUpdateDelay = 0

	self:UpdateAvail()

	if self.avail < 0 then
		return -- argh. some bastard is spewing stuff past the lib. just bail early to save cpu.
	end

	-- Integrate blocked queues back into their rings periodically.
	if blockedQueuesDelay >= 0.35 then
		for _, Prio in pairs(self.Prio) do
			Ring_Link(Prio.Ring, Prio.Blocked)
		end

		self.BlockedQueuesDelay = 0
	end

	-- See how many of our priorities have queued messages. This is split
	-- into two counters because priorities that consist only of blocked
	-- queues must keep our OnUpdate alive, but shouldn't count toward
	-- bandwidth distribution.
	local nSendablePrios = 0
	local nBlockedPrios = 0
	local avail = self.avail
	local Prio, ring, blocked

	for prioname, Prio in pairs(self.Prio) do
		ring = Prio.Ring
		blocked = Prio.Blocked

		if ring.pos then
			nSendablePrios = nSendablePrios + 1
		elseif blocked.pos then
			nBlockedPrios = nBlockedPrios + 1
		end

		-- Collect unused bandwidth from priorities with nothing to send.
		if not ring.pos then
			avail = avail + Prio.avail
			Prio.avail = 0
		end
	end

	-- Bandwidth reclamation may take us back over the burst cap.
	self.avail = math_min(avail, self.BURST)

	-- If we can't currently send on any priorities, stop processing early.
	if nSendablePrios == 0 then
		-- If we're completely out of data to send, disable queue processing.
		if nBlockedPrios == 0 then
			self.bQueueing = false
			self.Frame:Hide()
		end

		return
	end

	-- There's stuff queued. Hand out available bandwidth to priorities as needed and despool their queues
	local bandwidth = self.avail / nSendablePrios
	self.avail = 0

	for _, Prio in pairs(self.Prio) do
		if Prio.Ring.pos then
			Prio.avail = Prio.avail + bandwidth
			self:Despool(Prio)
		end
	end
end




-----------------------------------------------------------------------
-- Spooling logic

--- Enqueues a message in a priority queue
--- @param prioname string The priority name ("BULK", "NORMAL", "ALERT")
--- @param pipename string The pipe name
--- @param msg table The message to enqueue
function ChatThrottleLib:Enqueue(prioname, pipename, msg)
	local Prio = self.Prio[prioname]
	local pipe = Prio.ByName[pipename]
	if not pipe then
		self.Frame:Show()
		pipe = NewPipe()
		pipe.name = pipename
		Prio.ByName[pipename] = pipe
		Prio.Ring:Add(pipe)
	end

	pipe[#pipe + 1] = msg

	self.bQueueing = true
end

--- Sends a chat message through the throttle system
--- @param prio string The priority ("BULK", "NORMAL", "ALERT")
--- @param prefix string The message prefix
--- @param text string The message text
--- @param chattype string The chat type
--- @param language string The language
--- @param destination string The destination
--- @param queueName string The queue name
--- @param callbackFn function The callback function
--- @param callbackArg any The callback argument
function ChatThrottleLib:SendChatMessage(prio, prefix, text, chattype, language, destination, queueName, callbackFn, callbackArg)
	if not self or not prio or not prefix or not text or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:SendChatMessage("{BULK||NORMAL||ALERT}", "prefix", "text"[, "chattype"[, "language"[, "destination"]]]', 2)
	end
	if callbackFn and type(callbackFn)~="function" then
		error('ChatThrottleLib:ChatMessage(): callbackFn: expected function, got '..type(callbackFn), 2)
	end

	local nSize = strlen(text)

	if nSize>255 then
		error("ChatThrottleLib:SendChatMessage(): message length cannot exceed 255 bytes", 2)
	end

	nSize = nSize + self.MSG_OVERHEAD

	-- Check if there's room in the global available bandwidth gauge to send directly
	if not self.bQueueing and nSize < self:UpdateAvail() then
		local sendResult = PerformSend(_G.SendChatMessage, text, chattype or STRINGS.SAY, language, destination)

		if not IsThrottledSendResult(sendResult) then
			local didSend = (sendResult == SendAddonMessageResult.Success)

			if didSend then
				self.avail = self.avail - nSize
				self.Prio[prio].nTotalSent = self.Prio[prio].nTotalSent + nSize
			end

			if callbackFn then
				securecallfunction(callbackFn, callbackArg, didSend, sendResult)
			end

			return
		end
	end

	-- Message needs to be queued
	local msg = NewMsg()
	msg.f = _G.SendChatMessage
	msg[1] = text
	msg[2] = chattype or STRINGS.SAY
	msg[3] = language
	msg[4] = destination
	msg.n = 4
	msg.nSize = nSize
	msg.callbackFn = callbackFn
	msg.callbackArg = callbackArg

	self:Enqueue(prio, queueName or prefix, msg)
end


--- Internal function to send addon messages
--- @param self ChatThrottleLib The ChatThrottleLib instance
--- @param sendFunction function The function to send with
--- @param prio string The priority ("BULK", "NORMAL", "ALERT")
--- @param prefix string The addon prefix
--- @param text string The message text
--- @param chattype string The chat type
--- @param target string|number The target or game account ID
--- @param queueName string The queue name
--- @param callbackFn function The callback function
--- @param callbackArg any The callback argument
local function SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
	local nSize = #text + self.MSG_OVERHEAD

	-- Check if there's room in the global available bandwidth gauge to send directly
	if not self.bQueueing and nSize < self:UpdateAvail() then
		local sendResult = PerformSend(sendFunction, prefix, text, chattype, target)

		if not IsThrottledSendResult(sendResult) then
			local didSend = (sendResult == SendAddonMessageResult.Success)

			if didSend then
				self.avail = self.avail - nSize
				self.Prio[prio].nTotalSent = self.Prio[prio].nTotalSent + nSize
			end

			if callbackFn then
				securecallfunction(callbackFn, callbackArg, didSend, sendResult)
			end

			return
		end
	end

	-- Message needs to be queued
	local msg = NewMsg()
	msg.f = sendFunction
	msg[1] = prefix
	msg[2] = text
	msg[3] = chattype
	msg[4] = target
	msg.n = (target ~= nil) and 4 or 3
	msg.nSize = nSize
	msg.callbackFn = callbackFn
	msg.callbackArg = callbackArg

	self:Enqueue(prio, queueName or prefix, msg)
end


--- Sends an addon message through the throttle system
--- @param prio string The priority ("BULK", "NORMAL", "ALERT")
--- @param prefix string The addon prefix
--- @param text string The message text
--- @param chattype string The chat type
--- @param target string The target
--- @param queueName string The queue name
--- @param callbackFn function The callback function
--- @param callbackArg any The callback argument
function ChatThrottleLib:SendAddonMessage(prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
	if not self or not prio or not prefix or not text or not chattype or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:SendAddonMessage("{BULK||NORMAL||ALERT}", "prefix", "text", "chattype"[, "target"])', 2)
	elseif callbackFn and type(callbackFn)~="function" then
		error('ChatThrottleLib:SendAddonMessage(): callbackFn: expected function, got '..type(callbackFn), 2)
	elseif #text>255 then
		error("ChatThrottleLib:SendAddonMessage(): message length cannot exceed 255 bytes", 2)
	end

	SendAddonMessageInternal(self, C_ChatInfo_SendAddonMessage or _G.C_ChatInfo.SendAddonMessage, prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
end


--- Sends a logged addon message through the throttle system
--- @param prio string The priority ("BULK", "NORMAL", "ALERT")
--- @param prefix string The addon prefix
--- @param text string The message text
--- @param chattype string The chat type
--- @param target string The target
--- @param queueName string The queue name
--- @param callbackFn function The callback function
--- @param callbackArg any The callback argument
function ChatThrottleLib:SendAddonMessageLogged(prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
	if not self or not prio or not prefix or not text or not chattype or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:SendAddonMessageLogged("{BULK||NORMAL||ALERT}", "prefix", "text", "chattype"[, "target"])', 2)
	elseif callbackFn and type(callbackFn)~="function" then
		error('ChatThrottleLib:SendAddonMessageLogged(): callbackFn: expected function, got '..type(callbackFn), 2)
	elseif #text>255 then
		error("ChatThrottleLib:SendAddonMessageLogged(): message length cannot exceed 255 bytes", 2)
	end

	SendAddonMessageInternal(self, C_ChatInfo_SendAddonMessageLogged or _G.C_ChatInfo.SendAddonMessageLogged, prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
end

--- Reorders BNSendGameData parameters to match expected format
--- @param prefix string The addon prefix
--- @param text string The message text
--- @param _ any Unused parameter
--- @param gameAccountID number The game account ID
--- @return any The result from BNSendGameData
local function BNSendGameDataReordered(prefix, text, _, gameAccountID)
	return (BNSendGameData_Orig or _G.BNSendGameData)(gameAccountID, prefix, text)
end

--- Sends a Battle.net game data message through the throttle system
--- @param prio string The priority ("BULK", "NORMAL", "ALERT")
--- @param prefix string The addon prefix
--- @param text string The message text
--- @param chattype string The chat type
--- @param gameAccountID number The game account ID
--- @param queueName string The queue name
--- @param callbackFn function The callback function
--- @param callbackArg any The callback argument
function ChatThrottleLib:BNSendGameData(prio, prefix, text, chattype, gameAccountID, queueName, callbackFn, callbackArg)
	-- Note that this API is intentionally limited to 255 bytes of data
	-- for reasons of traffic fairness, which is less than the 4078 bytes
	-- BNSendGameData natively supports. Additionally, a chat type is required
	-- but must always be set to 'WHISPER' to match what is exposed by the
	-- receipt event.
	--
	-- If splitting messages, callers must also be aware that message
	-- delivery over BNSendGameData is unordered.

	if not self or not prio or not prefix or not text or not gameAccountID or not chattype or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:BNSendGameData("{BULK||NORMAL||ALERT}", "prefix", "text", "chattype", gameAccountID)', 2)
	elseif callbackFn and type(callbackFn)~="function" then
		error('ChatThrottleLib:BNSendGameData(): callbackFn: expected function, got '..type(callbackFn), 2)
	elseif #text>255 then
		error("ChatThrottleLib:BNSendGameData(): message length cannot exceed 255 bytes", 2)
	elseif chattype ~= STRINGS.WHISPER then
		error("ChatThrottleLib:BNSendGameData(): chat type must be 'WHISPER'", 2)
	end

	SendAddonMessageInternal(self, BNSendGameDataReordered, prio, prefix, text, chattype, gameAccountID, queueName, callbackFn, callbackArg)
end


-----------------------------------------------------------------------
-- Get the ball rolling!

ChatThrottleLib:Init()

--[[ WoWBench debugging snippet
if(WOWB_VER) then
	local function SayTimer()
		print("SAY: "..GetTime().." "..arg1)
	end
	ChatThrottleLib.Frame:SetScript("OnEvent", SayTimer)
	ChatThrottleLib.Frame:RegisterEvent("CHAT_MSG_SAY")
end
]]


