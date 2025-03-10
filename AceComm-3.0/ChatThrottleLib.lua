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

local CTL_VERSION = 30  -- 30 for The War Within optimizations

local _G = _G
---@class _G
---@field SendChatMessage function
---@field SendAddonMessage function

---@class ChatThrottleLib
---@field version number
---@field securelyHooked boolean
---@field securelyHookedLogged boolean
---@field securelyHookedBNGameData boolean
---@field ORIG_SendChatMessage function
---@field ORIG_SendAddonMessage function
---@field MAX_CPS number
---@field MSG_OVERHEAD number
---@field BURST number
---@field MIN_FPS number
---@field PipeBin table|nil
---@field MsgBin table|nil
---@field Frame table|nil
---@field avail number
---@field nTotalSent number
---@field Prio table|nil
---@field OnUpdateDelay number
---@field BlockedQueuesDelay number
---@field LastAvailUpdate number
---@field HardThrottlingBeginTime number
---@field bQueueing boolean
---@field nBypass number
---@field bChoking boolean
---@field ticker table|nil
---@field cacheCleaner table|nil
---@field blockedQueueTimer table|nil
---@field Init function
---@field OnUpdate function
---@field OnEvent function
---@field UpdateAvail function
---@field Despool function
---@field Enqueue function
---@field SendChatMessage function
---@field SendAddonMessage function
---@field SendAddonMessageLogged function
---@field BNSendGameData function
---@field Hook_SendChatMessage function
---@field Hook_SendAddonMessage function
---@field Hook_SendAddonMessageLogged function
---@field Hook_BNSendGameData function

if _G.ChatThrottleLib then
	if (_G.ChatThrottleLib.version or 0) >= CTL_VERSION then
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
	_G.ChatThrottleLib = {
		version = 0,
		securelyHooked = false,
		securelyHookedLogged = false,
		securelyHookedBNGameData = false,
		ORIG_SendChatMessage = function() end,
		ORIG_SendAddonMessage = function() end,
		Prio = nil,
		MAX_CPS = 800,
		MSG_OVERHEAD = 40,
		BURST = 4000,
		MIN_FPS = 20,
		PipeBin = nil,
		MsgBin = nil,
		Frame = nil,
		avail = 0,
		nTotalSent = 0,
		OnUpdateDelay = 0,
		BlockedQueuesDelay = 0,
		LastAvailUpdate = 0,
		HardThrottlingBeginTime = 0,
		bQueueing = false,
		nBypass = 0,
		bChoking = false,
		ticker = nil,
		cacheCleaner = nil,
		blockedQueueTimer = nil,
		Init = function() end,
		OnUpdate = function() end,
		OnEvent = function() end,
		UpdateAvail = function() end,
		Despool = function() end,
		Enqueue = function() end,
		SendChatMessage = function() end,
		SendAddonMessage = function() end,
		SendAddonMessageLogged = function() end,
		BNSendGameData = function() end,
		Hook_SendChatMessage = function() end,
		Hook_SendAddonMessage = function() end,
		Hook_SendAddonMessageLogged = function() end,
		Hook_BNSendGameData = function() end
	}
end

ChatThrottleLib = _G.ChatThrottleLib  -- in case some addon does "local ChatThrottleLib" above us and we're copypasted (AceComm-2, sigh)
local ChatThrottleLib = _G.ChatThrottleLib

ChatThrottleLib.version = CTL_VERSION

-- Stub functions to satisfy required type fields
ChatThrottleLib.Init = ChatThrottleLib.Init or function() end
ChatThrottleLib.OnUpdate = ChatThrottleLib.OnUpdate or function() end
ChatThrottleLib.OnEvent = ChatThrottleLib.OnEvent or function() end
ChatThrottleLib.UpdateAvail = ChatThrottleLib.UpdateAvail or function() end
ChatThrottleLib.Despool = ChatThrottleLib.Despool or function() end
ChatThrottleLib.Enqueue = ChatThrottleLib.Enqueue or function() end
ChatThrottleLib.SendChatMessage = ChatThrottleLib.SendChatMessage or function() end
ChatThrottleLib.SendAddonMessage = ChatThrottleLib.SendAddonMessage or function() end
ChatThrottleLib.SendAddonMessageLogged = ChatThrottleLib.SendAddonMessageLogged or function() end
ChatThrottleLib.BNSendGameData = ChatThrottleLib.BNSendGameData or function() end
ChatThrottleLib.Hook_SendChatMessage = ChatThrottleLib.Hook_SendChatMessage or function() end
ChatThrottleLib.Hook_SendAddonMessage = ChatThrottleLib.Hook_SendAddonMessage or function() end
ChatThrottleLib.Hook_SendAddonMessageLogged = ChatThrottleLib.Hook_SendAddonMessageLogged or function() end
ChatThrottleLib.Hook_BNSendGameData = ChatThrottleLib.Hook_BNSendGameData or function() end



------------------ TWEAKABLES -----------------

ChatThrottleLib.MAX_CPS = 800			  -- 2000 seems to be safe if NOTHING ELSE is happening. let's call it 800.
ChatThrottleLib.MSG_OVERHEAD = 40		-- Guesstimate overhead for sending a message; source+dest+chattype+protocolstuff

ChatThrottleLib.BURST = 4000				-- WoW's server buffer seems to be about 32KB. 8KB should be safe, but seen disconnects on _some_ servers. Using 4KB now.

ChatThrottleLib.MIN_FPS = 20				-- Reduce output CPS to half (and don't burst) if FPS drops below this value


-- Cache lua functions locally for better performance
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
local format = string.format
local pcall, xpcall = pcall, xpcall

-- Check for modern APIs
local C_ChatInfo = _G.C_ChatInfo
local C_Timer = _G.C_Timer
local InCombatLockdown = _G.InCombatLockdown

-- Define timer functions, with fallbacks for pre-War Within clients
local useC_Timer = C_Timer and C_Timer.NewTicker and type(select(1, pcall(function() return C_Timer.NewTicker(1, function() end) end))) == "userdata"
local TimerAfter = useC_Timer and C_Timer.After or false
local TimerNewTicker = useC_Timer and C_Timer.NewTicker or false

-- Check for enum support
local hasSendAddonMessageEnum = Enum and Enum.SendAddonMessageResult and true or false

-----------------------------------------------------------------------
-- Double-linked ring implementation

local Ring = {}
local RingMeta = { __index = Ring }

function Ring:New()
	local ret = {}
	setmetatable(ret, RingMeta)
	return ret
end

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

local function Ring_Link(self, other)  -- Move and append all contents of another ring to this ring
	if not other then
		-- Can't link with a nil ring
		return
	end

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

local function DelPipe(pipe)
	PipeBin[pipe] = true
end

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

local function DelMsg(msg)
	msg[1] = nil
	-- there's more parameters, but they're very repetetive so the string pool doesn't suffer really, and it's faster to just not delete them.
	MsgBin[msg] = true
end

local function NewMsg()
	local msg = next(MsgBin)
	if msg then
		MsgBin[msg] = nil
		return msg
	end
	return {}
end

-- Local cache for size calculations to avoid redundant calculations
local sizeCache = setmetatable({}, {__mode="k"})  -- Weak keys

local function CalculateMessageSize(text, destination, chattype, overhead)
	local cacheKey = format("%s|%s|%s", text or "", destination or "", chattype or "")
	if sizeCache[cacheKey] then
		return sizeCache[cacheKey]
	end

	local size = strlen(tostring(text or "")) + strlen(tostring(destination or "")) + overhead
	sizeCache[cacheKey] = size
	return size
end

-- Clear cache periodically to prevent memory bloat
local function ClearSizeCache()
	wipe(sizeCache)
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

	-- Use C_Timer for OnUpdate if available, otherwise fall back to frame
	if useC_Timer then
		self.Frame:SetScript("OnUpdate", nil)
		if self.ticker then
			self.ticker:Cancel()
		end
		if TimerNewTicker then
			local this = self -- Capture self in closure
			self.ticker = TimerNewTicker(0.08, function() this:OnUpdate(0.08) end)
		end

		-- Periodic cleaner for size cache to prevent memory bloat
		if self.cacheCleaner then
			self.cacheCleaner:Cancel()
		end
		if TimerNewTicker then
			self.cacheCleaner = TimerNewTicker(60, ClearSizeCache)
		end
	else
		self.Frame:SetScript("OnUpdate", self.OnUpdate)
	end

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
	local size = CalculateMessageSize(text, destination, chattype, self.MSG_OVERHEAD)
	self.avail = self.avail - size
	self.nBypass = self.nBypass + size	-- just a statistic
end

function ChatThrottleLib.Hook_SendAddonMessage(prefix, text, chattype, destination, ...)
	if bMyTraffic then
		return
	end
	local self = ChatThrottleLib
	local size = strlen(tostring(text or "")) + strlen(tostring(prefix or ""));
	size = size + strlen(tostring(destination or "")) + self.MSG_OVERHEAD
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
-- ChatThrottleLib:UpdateAvail
-- Update self.avail with how much bandwidth is currently available

function ChatThrottleLib:UpdateAvail()
	local now = GetTime()
	local MAX_CPS = self.MAX_CPS;
	local newavail = MAX_CPS * (now - self.LastAvailUpdate)
	local avail = self.avail

	-- Adjust based on combat state for The War Within - reduce bandwidth in combat
	if InCombatLockdown and InCombatLockdown() then
		MAX_CPS = MAX_CPS * 0.8  -- Reduce to 80% in combat to prioritize game performance
	end

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

local SendAddonMessageResult = Enum and Enum.SendAddonMessageResult or {
	Success = 0,
	AddonMessageThrottle = 3,
	NotInGroup = 5,
	ChannelThrottle = 8,
	GeneralError = 9,
}

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

local function IsThrottledSendResult(result)
	return result == SendAddonMessageResult.AddonMessageThrottle
end

-- A copy of this function exists in FrameXML, but for clarity it's here too.
local function CallErrorHandler(...)
	return geterrorhandler()(...)
end

local function PerformSend(sendFunction, ...)
	bMyTraffic = true
	local sendResult = MapToSendResult(xpcall(sendFunction, CallErrorHandler, ...))
	bMyTraffic = false
	return sendResult
end

local function ProcessBlockedPipes(self)
	for _, Prio in pairs(self.Prio) do
		if Prio.Ring and Prio.Blocked then
			Ring_Link(Prio.Ring, Prio.Blocked)
		elseif not Prio.Blocked then
			-- Create Blocked ring if missing
			Prio.Blocked = Ring:New()
		end
	end
end

function ChatThrottleLib:Despool(Prio)
	local ring = Prio.Ring
	while ring.pos and Prio.avail > ring.pos[1].nSize do
		local pipe = ring.pos
		local msg = pipe[1]
		local sendResult = PerformSend(msg.f, unpack(msg, 1, msg.n))

		if IsThrottledSendResult(sendResult) then
			-- Message was throttled; move the pipe into the blocked ring.
			Prio.Ring:Remove(pipe)
			Prio.Blocked:Add(pipe)

			-- In The War Within, we'll use C_Timer to more efficiently process blocked queues
			if useC_Timer and TimerAfter and not self.blockedQueueTimer then
				local this = self -- Capture self in closure
				self.blockedQueueTimer = TimerAfter(0.35, function()
					ProcessBlockedPipes(this)
					this.blockedQueueTimer = nil
				end)
			end
		else
			-- Dequeue message after submission.
			table_remove(pipe, 1)
			DelMsg(msg)

			if not pipe[1] then  -- did we remove last msg in this pipe?
				Prio.Ring:Remove(pipe)
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
				if useC_Timer and TimerAfter then
					local fn, arg = msg.callbackFn, msg.callbackArg
					TimerAfter(0, function()
						if fn then
							xpcall(fn, CallErrorHandler, arg, didSend, sendResult)
						end
					end)
				else
					xpcall(msg.callbackFn, CallErrorHandler, msg.callbackArg, didSend, sendResult)
				end
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
	if useC_Timer == false then  -- Only use this delay logic for old frame-based update
		self.BlockedQueuesDelay = self.BlockedQueuesDelay + delay
		if self.OnUpdateDelay < 0.08 then
			return
		end
		self.OnUpdateDelay = 0
	end

	self:UpdateAvail()

	if self.avail < 0  then
		return -- argh. some bastard is spewing stuff past the lib. just bail early to save cpu.
	end

	-- Integrate blocked queues back into their rings periodically.
	if not useC_Timer and self.BlockedQueuesDelay >= 0.35 then
		ProcessBlockedPipes(self)
		self.BlockedQueuesDelay = 0
	end

	-- See how many of our priorities have queued messages. This is split
	-- into two counters because priorities that consist only of blocked
	-- queues must keep our OnUpdate alive, but shouldn't count toward
	-- bandwidth distribution.
	local nSendablePrios = 0
	local nBlockedPrios = 0

	for prioname, Prio in pairs(self.Prio) do
		if Prio.Ring and Prio.Ring.pos then
			nSendablePrios = nSendablePrios + 1
		elseif Prio.Blocked and Prio.Blocked.pos then
			nBlockedPrios = nBlockedPrios + 1
		end

		-- Store priority name for easier debugging
		Prio.name = prioname

		-- Ensure Blocked exists
		if not Prio.Blocked then
			Prio.Blocked = Ring:New()
		end

		-- Collect unused bandwidth from priorities with nothing to send.
		if not Prio.Ring or not Prio.Ring.pos then
			self.avail = self.avail + Prio.avail
			Prio.avail = 0
		end
	end

	-- Bandwidth reclamation may take us back over the burst cap.
	self.avail = math_min(self.avail, self.BURST)

	-- If we can't currently send on any priorities, stop processing early.
	if nSendablePrios == 0 then
		-- If we're completely out of data to send, disable queue processing.
		if nBlockedPrios == 0 then
			self.bQueueing = false

			-- For frame-based updates, hide the frame
			if not useC_Timer then
				self.Frame:Hide()
			end
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
		if not useC_Timer then
			self.Frame:Show()
		end
		pipe = NewPipe()
		pipe.name = pipename
		Prio.ByName[pipename] = pipe
		Prio.Ring:Add(pipe)
	end

	pipe[#pipe + 1] = msg

	self.bQueueing = true
end

function ChatThrottleLib:SendChatMessage(prio, prefix, text, chattype, language, destination, queueName, callbackFn, callbackArg)
	-- Initialize if needed
	if not self.Prio then
		self:Init()
	end

	if not self or not prio or not prefix or not text or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:SendChatMessage("{BULK||NORMAL||ALERT}", "prefix", "text"[, "chattype"[, "language"[, "destination"]]]', 2)
	end
	if callbackFn and type(callbackFn)~="function" then
		error('ChatThrottleLib:ChatMessage(): callbackFn: expected function, got '..type(callbackFn), 2)
	end

	local nSize = text:len()

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
				if useC_Timer and TimerAfter then
					local fn, arg = callbackFn, callbackArg
					TimerAfter(0, function()
						if fn then
							xpcall(fn, CallErrorHandler, arg, didSend, sendResult)
						end
					end)
				else
					xpcall(callbackFn, CallErrorHandler, callbackArg, didSend, sendResult)
				end
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


local function SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
	local nSize = strlen(text) + self.MSG_OVERHEAD

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
				if useC_Timer and TimerAfter then
					local fn, arg = callbackFn, callbackArg
					TimerAfter(0, function()
						if fn then
							xpcall(fn, CallErrorHandler, arg, didSend, sendResult)
						end
					end)
				else
					xpcall(callbackFn, CallErrorHandler, callbackArg, didSend, sendResult)
				end
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
	msg.n = (target~=nil) and 4 or 3;
	msg.nSize = nSize
	msg.callbackFn = callbackFn
	msg.callbackArg = callbackArg

	self:Enqueue(prio, queueName or prefix, msg)
end


function ChatThrottleLib:SendAddonMessage(prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
	-- Initialize if needed
	if not self.Prio then
		self:Init()
	end

	if not self or not prio or not prefix or not text or not chattype or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:SendAddonMessage("{BULK||NORMAL||ALERT}", "prefix", "text", "chattype"[, "target"])', 2)
	elseif callbackFn and type(callbackFn)~="function" then
		error('ChatThrottleLib:SendAddonMessage(): callbackFn: expected function, got '..type(callbackFn), 2)
	elseif strlen(text)>255 then
		error("ChatThrottleLib:SendAddonMessage(): message length cannot exceed 255 bytes", 2)
	end

	local sendFunction = C_ChatInfo and C_ChatInfo.SendAddonMessage or _G.SendAddonMessage
	SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
end


function ChatThrottleLib:SendAddonMessageLogged(prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
	-- Initialize if needed
	if not self.Prio then
		self:Init()
	end

	if not self or not prio or not prefix or not text or not chattype or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:SendAddonMessageLogged("{BULK||NORMAL||ALERT}", "prefix", "text", "chattype"[, "target"])', 2)
	elseif callbackFn and type(callbackFn)~="function" then
		error('ChatThrottleLib:SendAddonMessageLogged(): callbackFn: expected function, got '..type(callbackFn), 2)
	elseif strlen(text)>255 then
		error("ChatThrottleLib:SendAddonMessageLogged(): message length cannot exceed 255 bytes", 2)
	end

	local sendFunction = C_ChatInfo and C_ChatInfo.SendAddonMessageLogged or function(...) error("SendAddonMessageLogged not available", 2) end
	SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
end

local function BNSendGameDataReordered(prefix, text, _, gameAccountID)
	return _G.BNSendGameData(gameAccountID, prefix, text)
end

function ChatThrottleLib:BNSendGameData(prio, prefix, text, chattype, gameAccountID, queueName, callbackFn, callbackArg)
	-- Initialize if needed
	if not self.Prio then
		self:Init()
	end

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
	elseif strlen(text)>255 then
		error("ChatThrottleLib:BNSendGameData(): message length cannot exceed 255 bytes", 2)
	elseif chattype ~= "WHISPER" then
		error("ChatThrottleLib:BNSendGameData(): chat type must be 'WHISPER'", 2)
	end

	local sendFunction = BNSendGameDataReordered
	SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, gameAccountID, queueName, callbackFn, callbackArg)
end


-----------------------------------------------------------------------
-- Initialization methods for ChatThrottleLib

-- Start with using C_Timer if available
if C_Timer and C_Timer.After then
	C_Timer.After(0, function()
		ChatThrottleLib:Init()
	end)
else
	-- Fall back to traditional init
	ChatThrottleLib:Init()
end

--[[ WoWBench debugging snippet
if(WOWB_VER) then
	local function SayTimer()
		print("SAY: "..GetTime().." "..arg1)
	end
	ChatThrottleLib.Frame:SetScript("OnEvent", SayTimer)
	ChatThrottleLib.Frame:RegisterEvent("CHAT_MSG_SAY")
end
]]

-- Ensure all required methods are present for type checking
ChatThrottleLib.SendChatMessage = ChatThrottleLib.SendChatMessage
ChatThrottleLib.SendAddonMessage = ChatThrottleLib.SendAddonMessage
ChatThrottleLib.SendAddonMessageLogged = ChatThrottleLib.SendAddonMessageLogged
ChatThrottleLib.BNSendGameData = ChatThrottleLib.BNSendGameData


