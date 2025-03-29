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

local CTL_VERSION = 29

local _G = _G

-- Cache frequently used functions for performance optimization
-- These local references reduce global table lookups and improve execution speed
-- while maintaining full compatibility with WoW's Lua 5.1 environment
local str_len = string.len
local str_tostring = tostring
local t_insert = table.insert
local t_remove = table.remove
local t_wipe = table.wipe
local t_next = next
local t_pairs = pairs
local t_type = type
local t_unpack = unpack
local m_min = math.min
local m_max = math.max
local GetTime = GetTime
local GetFramerate = GetFramerate
local CreateFrame = CreateFrame
local hooksecurefunc = hooksecurefunc
local securecallfunction = securecallfunction
local xpcall = xpcall
local geterrorhandler = geterrorhandler
local setmetatable = setmetatable

---@class ChatThrottleLib
---@field version number The current version of the library
---@field securelyHooked boolean Whether SendChatMessage is securely hooked
---@field ORIG_SendChatMessage function Original SendChatMessage function
---@field ORIG_SendAddonMessage function Original SendAddonMessage function
---@field Prio table Priority queues for message handling
---@field Frame Frame The OnUpdate frame for processing
---@field avail number Available bandwidth for sending
---@field nTotalSent number Total bytes sent
---@field nBypass number Bytes bypassing the library
---@field bQueueing boolean Whether messages are being queued
---@field bChoking boolean Whether bandwidth is being throttled
---@field OnUpdateDelay number Delay between OnUpdate calls
---@field BlockedQueuesDelay number Delay for blocked queue processing
---@field LastAvailUpdate number Last bandwidth update timestamp
---@field HardThrottlingBeginTime number When hard throttling started
---@field securelyHookedLogged boolean Whether SendAddonMessageLogged is hooked
---@field securelyHookedBNGameData boolean Whether BNSendGameData is hooked
---@field MSG_OVERHEAD number Message overhead in bytes
---@field MAX_CPS number Maximum characters per second
---@field BURST number Maximum burst size
---@field MIN_FPS number FPS threshold for reducing output
---@field UpdateAvail function Updates available bandwidth based on time elapsed and current conditions
---@field Enqueue function Adds a message to the appropriate priority queue

---@class _G
---@field SendChatMessage function WoW's SendChatMessage function
---@field SendAddonMessage function WoW's SendAddonMessage function
---@field C_ChatInfo table WoW's ChatInfo API table
---@field ChatThrottleLib table The library instance

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

ChatThrottleLib.version = CTL_VERSION



------------------ TWEAKABLES -----------------

-- Maximum characters per second that can be sent
-- 2000 seems safe if nothing else is happening, using 800 for safety
ChatThrottleLib.MAX_CPS = 800

-- Estimated overhead for each message (source+dest+chattype+protocol)
-- Used for bandwidth calculations and throttling
ChatThrottleLib.MSG_OVERHEAD = 40

-- Maximum burst size in characters
-- WoW's server buffer is ~32KB, using 4KB for safety after disconnects
ChatThrottleLib.BURST = 4000

-- FPS threshold for reducing output
-- Reduces CPS to half and disables bursting below this FPS
ChatThrottleLib.MIN_FPS = 20


-----------------------------------------------------------------------
-- Double-linked ring implementation
-- Provides efficient circular queue functionality for message handling
-- Each ring maintains a current position and links objects in a circular chain
-- This implementation allows for O(1) insertion and removal operations

---@class Ring
---@field pos table|nil Current position in the ring
---@field prev table|nil Previous node in the ring
---@field next table|nil Next node in the ring

local Ring = {}
local RingMeta = { __index = Ring }

---Creates a new ring instance
---@return Ring
function Ring:New()
	local ret = {}
	setmetatable(ret, RingMeta)
	return ret
end

---Adds an object to the ring at the far end (just before current position)
---@param obj table The object to add
function Ring:Add(obj)
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

---Removes an object from the ring and updates the current position
---@param obj table The object to remove
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

---Links two rings together, moving all contents from other to this ring
---@param self Ring
---@param other Ring The ring whose contents will be moved
local function Ring_Link(self, other)
	if not self.pos then
		-- This ring is empty, so just transfer ownership
		self.pos = other.pos
		other.pos = nil
	elseif other.pos then
		-- Our tail should point to their head, and their tail to our head
		self.pos.prev.next, other.pos.prev.next = other.pos, self.pos
		-- Our head should point to their tail, and their head to our tail
		self.pos.prev, other.pos.prev = other.pos.prev, self.pos.prev
		other.pos = nil
	end
end



-----------------------------------------------------------------------
-- Message and Pipe Recycling System
-- Implements object pooling to reduce garbage collection overhead
-- Pipes are queues of messages, while messages contain the actual data to send

-- Recycling bin for pipes using weak keys to allow garbage collection
ChatThrottleLib.PipeBin = nil -- pre-v19, drastically different
local PipeBin = setmetatable({}, {__mode="k"})

---Recycles a pipe back to the bin for future reuse
---@param pipe table The pipe to recycle
local function DelPipe(pipe)
	PipeBin[pipe] = true
end

---Creates a new pipe or reuses one from the recycling bin
---@return table A new or recycled pipe
local function NewPipe()
	local pipe = next(PipeBin)
	if pipe then
		wipe(pipe)
		PipeBin[pipe] = nil
		return pipe
	end
	return {}
end

-- Recycling bin for messages using weak keys
ChatThrottleLib.MsgBin = nil -- pre-v19, drastically different
local MsgBin = setmetatable({}, {__mode="k"})

---Recycles a message back to the bin for future reuse
---Only clears the first field as other fields are string references
---@param msg table The message to recycle
local function DelMsg(msg)
	msg[1] = nil
	-- there's more parameters, but they're very repetetive so the string pool doesn't suffer really, and it's faster to just not delete them.
	MsgBin[msg] = true
end

---Creates a new message or reuses one from the recycling bin
---@return table A new or recycled message
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


function ChatThrottleLib:Init()

	-- Set up queues
	if not self.Prio then
		self.Prio = {}
		self.Prio["ALERT"] = { ByName = {}, Ring = Ring:New(), avail = 0 }
		self.Prio["NORMAL"] = { ByName = {}, Ring = Ring:New(), avail = 0 }
		self.Prio["BULK"] = { ByName = {}, Ring = Ring:New(), avail = 0 }
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
	self.Frame:SetScript("OnUpdate", self.OnUpdate)
	self.Frame:SetScript("OnEvent", self.OnEvent)	-- v11: Monitor P_E_W so we can throttle hard for a few seconds
	self.Frame:RegisterEvent("PLAYER_ENTERING_WORLD")
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

function ChatThrottleLib.Hook_SendChatMessage(text, chattype, language, destination, ...)
	if bMyTraffic then
		return
	end
	local self = ChatThrottleLib
	local size = str_len(str_tostring(text or "")) + str_len(str_tostring(destination or "")) + self.MSG_OVERHEAD
	self.avail = self.avail - size
	self.nBypass = self.nBypass + size	-- just a statistic
end
function ChatThrottleLib.Hook_SendAddonMessage(prefix, text, chattype, destination, ...)
	if bMyTraffic then
		return
	end
	local self = ChatThrottleLib
	local size = str_tostring(text or ""):len() + str_tostring(prefix or ""):len();
	size = size + str_tostring(destination or ""):len() + self.MSG_OVERHEAD
	self.avail = self.avail - size
	self.nBypass = self.nBypass + size	-- just a statistic
end
function ChatThrottleLib.Hook_SendAddonMessageLogged(prefix, text, chattype, destination, ...)
	ChatThrottleLib.Hook_SendAddonMessage(prefix, text, chattype, destination, ...)
end
function ChatThrottleLib.Hook_BNSendGameData(destination, prefix, text)
	ChatThrottleLib.Hook_SendAddonMessage(prefix, text, "WHISPER", destination)
end



-----------------------------------------------------------------------
-- Message Handling and Bandwidth Management
-- Implements smart throttling and queuing of chat messages and addon communications
-- Uses a priority-based system with three levels: ALERT, NORMAL, and BULK
-- Each priority gets equal bandwidth share when fully loaded

---Updates available bandwidth based on time elapsed and current conditions
---Implements adaptive throttling based on FPS and server load
---@return number The updated available bandwidth
function ChatThrottleLib:UpdateAvail()
	local now = GetTime()
	local MAX_CPS = self.MAX_CPS
	local newavail = MAX_CPS * (now - self.LastAvailUpdate)
	local avail = self.avail

	if now - self.HardThrottlingBeginTime < 5 then
		-- First 5 seconds after startup/zoning: VERY hard clamping to avoid irritating the server rate limiter
		avail = m_min(avail + (newavail*0.1), MAX_CPS*0.5)
		self.bChoking = true
	elseif GetFramerate() < self.MIN_FPS then
		-- Reduce output when FPS drops to prevent client performance issues
		avail = m_min(MAX_CPS, avail + newavail*0.5)
		self.bChoking = true
	else
		avail = m_min(self.BURST, avail + newavail)
		self.bChoking = false
	end

	-- Allow negative bandwidth to handle bypass traffic, but limit duration
	avail = m_max(avail, 0-(MAX_CPS*2))

	self.avail = avail
	self.LastAvailUpdate = now

	return avail
end


-----------------------------------------------------------------------
-- Message Sending and Result Handling
-- Provides robust error handling and result mapping for message sending
-- Implements throttling detection and appropriate queue management

---Maps send function results to standardized result codes
---@param ok boolean Whether the send function executed successfully
---@param ... any Additional return values from the send function
---@return number The mapped result code
local function MapToSendResult(ok, ...)
	local result

	if not ok then
		-- The send function itself errored; don't look at anything else
		result = SendAddonMessageResult.GeneralError
	else
		-- Grab the last return value from the send function and remap
		-- it from a boolean to an enum code. If there are no results,
		-- assume success (true)
		result = select(-1, true, ...)

		if result == true then
			result = SendAddonMessageResult.Success
		elseif result == false then
			result = SendAddonMessageResult.GeneralError
		end
	end

	return result
end

---Checks if a send result indicates throttling
---@param result number The send result to check
---@return boolean Whether the result indicates throttling
local function IsThrottledSendResult(result)
	return result == SendAddonMessageResult.AddonMessageThrottle
end

---Executes a send function with error handling and traffic tracking
---@param sendFunction function The function to execute
---@param ... any Arguments to pass to the send function
---@return number The result of the send operation
local function PerformSend(sendFunction, ...)
	bMyTraffic = true
	local sendResult = MapToSendResult(xpcall(sendFunction, CallErrorHandler, ...))
	bMyTraffic = false
	return sendResult
end

---Processes messages from a priority queue up to available bandwidth
---@param Prio table The priority queue to process
function ChatThrottleLib:Despool(Prio)
	local ring = Prio.Ring
	while ring.pos and Prio.avail > ring.pos[1].nSize do
		local pipe = ring.pos
		local msg = pipe[1]
		local sendResult = PerformSend(msg.f, t_unpack(msg, 1, msg.n))

		if IsThrottledSendResult(sendResult) then
			-- Message was throttled; move the pipe into the blocked ring
			Prio.Ring:Remove(pipe)
			Prio.Blocked:Add(pipe)
		else
			-- Dequeue message after submission
			t_remove(pipe, 1)
			DelMsg(msg)

			if not pipe[1] then  -- did we remove last msg in this pipe?
				Prio.Ring:Remove(pipe)
				Prio.ByName[pipe.name] = nil
				DelPipe(pipe)
			else
				ring.pos = ring.pos.next
			end

			-- Update bandwidth counters on successful sends
			local didSend = (sendResult == SendAddonMessageResult.Success)
			if didSend then
				Prio.avail = Prio.avail - msg.nSize
				Prio.nTotalSent = Prio.nTotalSent + msg.nSize
			end

			-- Notify caller of message submission
			if msg.callbackFn then
				securecallfunction(msg.callbackFn, msg.callbackArg, didSend, sendResult)
			end
		end
	end
end


function ChatThrottleLib.OnEvent(this,event)
	-- v11: We know that the rate limiter is touchy after login. Assume that it's touchy after zoning, too.
	local self = ChatThrottleLib
	if event == "PLAYER_ENTERING_WORLD" then
		self.HardThrottlingBeginTime = GetTime()	-- Throttle hard for a few seconds after zoning
		self.avail = 0
	end
end


function ChatThrottleLib.OnUpdate(this,delay)
	local self = ChatThrottleLib

	self.OnUpdateDelay = self.OnUpdateDelay + delay
	self.BlockedQueuesDelay = self.BlockedQueuesDelay + delay
	if self.OnUpdateDelay < 0.08 then
		return
	end
	self.OnUpdateDelay = 0

	self:UpdateAvail()

	if self.avail < 0  then
		return -- argh. some bastard is spewing stuff past the lib. just bail early to save cpu.
	end

	-- Integrate blocked queues back into their rings periodically.
	if self.BlockedQueuesDelay >= 0.35 then
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

	for prioname, Prio in pairs(self.Prio) do
		if Prio.Ring.pos then
			nSendablePrios = nSendablePrios + 1
		elseif Prio.Blocked.pos then
			nBlockedPrios = nBlockedPrios + 1
		end

		-- Collect unused bandwidth from priorities with nothing to send.
		if not Prio.Ring.pos then
			self.avail = self.avail + Prio.avail
			Prio.avail = 0
		end
	end

	-- Bandwidth reclamation may take us back over the burst cap.
	self.avail = m_min(self.avail, self.BURST)

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
	local avail = self.avail / nSendablePrios
	self.avail = 0

	for prioname, Prio in pairs(self.Prio) do
		if Prio.Ring.pos then
			Prio.avail = Prio.avail + avail
			self:Despool(Prio)
		end
	end
end




-----------------------------------------------------------------------
-- Spooling logic

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

	t_insert(pipe, msg)

	self.bQueueing = true
end

-----------------------------------------------------------------------
-- Public API Methods
-- Provides throttled versions of WoW's chat and addon message functions
-- All methods support priority-based queuing and callback notifications

---Sends a chat message with priority-based throttling
---@param prio string Priority level ("BULK", "NORMAL", or "ALERT")
---@param prefix string Message prefix for queue identification
---@param text string The message text to send
---@param chattype? string Chat type (defaults to "SAY")
---@param language? string Language for chat message
---@param destination? string Target for whispers/channels
---@param queueName? string Optional custom queue name
---@param callbackFn? function Callback function for send result
---@param callbackArg? any Argument to pass to callback
function ChatThrottleLib:SendChatMessage(prio, prefix, text, chattype, language, destination, queueName, callbackFn, callbackArg)
	if not self or not prio or not prefix or not text or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:SendChatMessage("{BULK||NORMAL||ALERT}", "prefix", "text"[, "chattype"[, "language"[, "destination"]]]', 2)
	end
	if callbackFn and t_type(callbackFn)~="function" then
		error('ChatThrottleLib:ChatMessage(): callbackFn: expected function, got '..t_type(callbackFn), 2)
	end

	local nSize = str_len(text)

	if nSize>255 then
		error("ChatThrottleLib:SendChatMessage(): message length cannot exceed 255 bytes", 2)
	end

	nSize = nSize + self.MSG_OVERHEAD

	-- Check if there's room in the global available bandwidth gauge to send directly
	if not self.bQueueing and nSize < self:UpdateAvail() then
		local sendResult = PerformSend(_G.SendChatMessage, text, chattype, language, destination)

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
	msg[2] = chattype or "SAY"
	msg[3] = language
	msg[4] = destination
	msg.n = 4
	msg.nSize = nSize
	msg.callbackFn = callbackFn
	msg.callbackArg = callbackArg

	self:Enqueue(prio, queueName or prefix, msg)
end

---Internal function for handling addon message sending
---@param self table The ChatThrottleLib instance
---@param sendFunction function The function to use for sending
---@param prio string Priority level
---@param prefix string Message prefix
---@param text string Message text
---@param chattype string Chat type
---@param target? string Target for the message
---@param queueName? string Optional custom queue name
---@param callbackFn? function Callback function
---@param callbackArg? any Callback argument
local function SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
	local nSize = str_len(text) + self.MSG_OVERHEAD

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
	msg.n = (target~=nil) and 4 or 3
	msg.nSize = nSize
	msg.callbackFn = callbackFn
	msg.callbackArg = callbackArg

	self:Enqueue(prio, queueName or prefix, msg)
end

---Sends an addon message with priority-based throttling
---@param prio string Priority level ("BULK", "NORMAL", or "ALERT")
---@param prefix string Message prefix
---@param text string Message text
---@param chattype string Chat type
---@param target? string Target for the message
---@param queueName? string Optional custom queue name
---@param callbackFn? function Callback function
---@param callbackArg? any Callback argument
function ChatThrottleLib:SendAddonMessage(prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
	if not self or not prio or not prefix or not text or not chattype or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:SendAddonMessage("{BULK||NORMAL||ALERT}", "prefix", "text", "chattype"[, "target"])', 2)
	elseif callbackFn and t_type(callbackFn)~="function" then
		error('ChatThrottleLib:SendAddonMessage(): callbackFn: expected function, got '..t_type(callbackFn), 2)
	elseif str_len(text)>255 then
		error("ChatThrottleLib:SendAddonMessage(): message length cannot exceed 255 bytes", 2)
	end

	local sendFunction = _G.C_ChatInfo.SendAddonMessage
	SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
end

---Sends a logged addon message with priority-based throttling
---@param prio string Priority level ("BULK", "NORMAL", or "ALERT")
---@param prefix string Message prefix
---@param text string Message text
---@param chattype string Chat type
---@param target? string Target for the message
---@param queueName? string Optional custom queue name
---@param callbackFn? function Callback function
---@param callbackArg? any Callback argument
function ChatThrottleLib:SendAddonMessageLogged(prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
	if not self or not prio or not prefix or not text or not chattype or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:SendAddonMessageLogged("{BULK||NORMAL||ALERT}", "prefix", "text", "chattype"[, "target"])', 2)
	elseif callbackFn and t_type(callbackFn)~="function" then
		error('ChatThrottleLib:SendAddonMessageLogged(): callbackFn: expected function, got '..t_type(callbackFn), 2)
	elseif str_len(text)>255 then
		error("ChatThrottleLib:SendAddonMessageLogged(): message length cannot exceed 255 bytes", 2)
	end

	local sendFunction = _G.C_ChatInfo.SendAddonMessageLogged
	SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
end

---Helper function to reorder BNSendGameData parameters
---@param prefix string Message prefix
---@param text string Message text
---@param _ any Unused parameter
---@param gameAccountID number Battle.net account ID
---@return any Success status or nil
local function BNSendGameDataReordered(prefix, text, _, gameAccountID)
	return _G.BNSendGameData(gameAccountID, prefix, text)
end

---Sends a Battle.net game data message with priority-based throttling
---Note: Limited to 255 bytes for traffic fairness, less than native 4078 byte limit
---@param prio string Priority level ("BULK", "NORMAL", or "ALERT")
---@param prefix string Message prefix
---@param text string Message text
---@param chattype string Must be "WHISPER"
---@param gameAccountID number Battle.net account ID
---@param queueName? string Optional custom queue name
---@param callbackFn? function Callback function
---@param callbackArg? any Callback argument
function ChatThrottleLib:BNSendGameData(prio, prefix, text, chattype, gameAccountID, queueName, callbackFn, callbackArg)
	if not self or not prio or not prefix or not text or not gameAccountID or not chattype or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:BNSendGameData("{BULK||NORMAL||ALERT}", "prefix", "text", "chattype", gameAccountID)', 2)
	elseif callbackFn and t_type(callbackFn)~="function" then
		error('ChatThrottleLib:BNSendGameData(): callbackFn: expected function, got '..t_type(callbackFn), 2)
	elseif str_len(text)>255 then
		error("ChatThrottleLib:BNSendGameData(): message length cannot exceed 255 bytes", 2)
	elseif chattype ~= "WHISPER" then
		error("ChatThrottleLib:BNSendGameData(): chat type must be 'WHISPER'", 2)
	end

	local sendFunction = BNSendGameDataReordered
	SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, str_tostring(gameAccountID), queueName, callbackFn, callbackArg)
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


