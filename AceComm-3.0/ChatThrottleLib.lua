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

---@class _G
---@field SendChatMessage function
---@field SendAddonMessage function
---@field ChatThrottleLib table

local CTL_VERSION = 30  -- Optimized version

local _G = _G

-- Create if it doesn't exist
if not _G.ChatThrottleLib then
	_G.ChatThrottleLib = {version = 0}
end

-- Check for existing version and handle upgrading
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

-- Set up our main library object
ChatThrottleLib = _G.ChatThrottleLib  -- in case some addon does "local ChatThrottleLib" above us and we're copypasted (AceComm-2, sigh)
local ChatThrottleLib = _G.ChatThrottleLib

ChatThrottleLib.version = CTL_VERSION

------------------ SYSTEM-SPECIFIC CONFIGURATION -----------------
-- Flags for high-end systems (32GB RAM, RTX 2060, Ryzen 7 3800XT)
ChatThrottleLib.HIGH_END_SYSTEM = true  -- Set to true for high-end systems

if ChatThrottleLib.HIGH_END_SYSTEM then
    -- Increased bandwidth limits for high-end systems
    ChatThrottleLib.MAX_CPS = 1600           -- Boosted for high-end Ryzen 7 3800XT system
    ChatThrottleLib.MSG_OVERHEAD = 40        -- Overhead per message
    ChatThrottleLib.BURST = 8000             -- Significantly increased burst size for 32GB RAM
    -- Skip FPS checks completely for high-end systems
    ChatThrottleLib.SKIP_FPS_THROTTLING = true
    ChatThrottleLib.MIN_FPS = 60             -- Set a default value even though we're skipping checks
else
    -- Default settings for normal systems
    ChatThrottleLib.MAX_CPS = 800            -- Default safe value
    ChatThrottleLib.MSG_OVERHEAD = 40        -- Overhead per message
    ChatThrottleLib.BURST = 4000             -- Default burst size
    ChatThrottleLib.MIN_FPS = 20             -- Default FPS threshold
end

-- Pre-compute commonly used values
ChatThrottleLib.MIN_FPS_THRESHOLD = ChatThrottleLib.MIN_FPS * 1.5  -- Pre-compute threshold for fast path



------------------ TWEAKABLES -----------------

-- These settings are now handled in SYSTEM-SPECIFIC CONFIGURATION section above
-- Keeping empty section for compatibility with addons that might check for this section

-- Localize frequently used functions for performance
local setmetatable = setmetatable
local table_remove = table.remove
local tostring = tostring
local GetTime = GetTime
local math_min = math.min
local math_max = math.max
local next = next
local strlen = string.len
local GetFramerate = GetFramerate
local unpack,type,pairs,wipe = unpack,type,pairs,table.wipe
local select = select
local error = error
local securecallfunction = securecallfunction
local xpcall = xpcall
local geterrorhandler = geterrorhandler
local hooksecurefunc = hooksecurefunc
local CreateFrame = CreateFrame
local tinsert = table.insert
local tremove = table.remove
local format = string.format
local strsub = string.sub


-----------------------------------------------------------------------
-- Double-linked ring implementation

local Ring = {}
local RingMeta = { __index = Ring }

function Ring:New()
	local ret = {}
	setmetatable(ret, RingMeta)
	return ret
end

-- Optimized Add function with direct access for performance
function Ring:Add(obj)	-- Append at the "far end" of the ring (aka just before the current position)
	if self.pos then
		-- Direct access without redundant lookups
		local pos = self.pos
		local prev = pos.prev
		obj.prev = prev
		obj.next = pos
		prev.next = obj
		pos.prev = obj
	else
		obj.next = obj
		obj.prev = obj
		self.pos = obj
	end
end

-- Optimized Remove function with direct access
function Ring:Remove(obj)
	local next, prev = obj.next, obj.prev
	next.prev = prev
	prev.next = next
	if self.pos == obj then
		self.pos = next
		if self.pos == obj then
			self.pos = nil
		end
	end
end

-- Note that this is local because there's no upgrade logic for existing ring
-- metatables, and this isn't present on rings created in versions older than
-- v25.
local function Ring_Link(self, other)  -- Move and append all contents of another ring to this ring
	if not self.pos then
		-- This ring is empty, so just transfer ownership.
		self.pos = other.pos
		other.pos = nil
	elseif other.pos then
		-- Direct access for performance
		local selfPos, otherPos = self.pos, other.pos
		local selfTail, otherTail = selfPos.prev, otherPos.prev

		-- Our tail should point to their head, and their tail to our head.
		selfTail.next, otherTail.next = otherPos, selfPos

		-- Our head should point to their tail, and their head to our tail.
		selfPos.prev, otherPos.prev = otherTail, selfTail

		other.pos = nil
	end
end



-----------------------------------------------------------------------
-- Recycling bin for pipes
-- A pipe is a plain integer-indexed queue of messages
-- Pipes normally live in Rings of pipes  (3 rings total, one per priority)

ChatThrottleLib.PipeBin = nil -- pre-v19, drastically different

-- Pre-allocate pipe bin with stronger references (not weak tables)
-- This increases memory usage but improves performance by avoiding GC churn
local PipeBin = {}
local PIPE_BIN_SIZE = 128  -- Pre-allocate space for high throughput scenarios

-- Pre-fill the pipe bin
do
	for i = 1, PIPE_BIN_SIZE do
		PipeBin[i] = {}
	end
end

local PipeBinCount = PIPE_BIN_SIZE
local PipeBinTop = 1

local function DelPipe(pipe)
	if PipeBinCount < PIPE_BIN_SIZE * 2 then  -- Limit growth to avoid excessive memory usage
		wipe(pipe)
		PipeBin[PipeBinTop] = pipe
		PipeBinTop = PipeBinTop + 1
		PipeBinCount = PipeBinCount + 1
	end
end

local function NewPipe()
	if PipeBinTop > 1 then
		PipeBinTop = PipeBinTop - 1
		PipeBinCount = PipeBinCount - 1
		return PipeBin[PipeBinTop]
	end
	return {}
end




-----------------------------------------------------------------------
-- Recycling bin for messages

ChatThrottleLib.MsgBin = nil -- pre-v19, drastically different

-- Pre-allocate message bin with stronger references
-- This increases memory usage but improves performance
local MsgBin = {}
local MSG_BIN_SIZE = 256  -- Pre-allocate for high throughput

-- Pre-fill the message bin
do
	for i = 1, MSG_BIN_SIZE do
		MsgBin[i] = {}
	end
end

local MsgBinCount = MSG_BIN_SIZE
local MsgBinTop = 1

local function DelMsg(msg)
	if MsgBinCount < MSG_BIN_SIZE * 2 then  -- Limit growth to avoid excessive memory usage
		msg[1] = nil  -- Clear the first parameter to avoid keeping references
		MsgBin[MsgBinTop] = msg
		MsgBinTop = MsgBinTop + 1
		MsgBinCount = MsgBinCount + 1
	end
end

local function NewMsg()
	if MsgBinTop > 1 then
		MsgBinTop = MsgBinTop - 1
		MsgBinCount = MsgBinCount - 1
		return MsgBin[MsgBinTop]
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
		if _G.C_ChatInfo and _G.C_ChatInfo.SendAddonMessage then
			hooksecurefunc(_G.C_ChatInfo, "SendAddonMessage", function(...)
				return ChatThrottleLib.Hook_SendAddonMessage(...)
			end)
		end
	end

	-- v26: Hook SendAddonMessageLogged for traffic logging
	if not self.securelyHookedLogged then
		self.securelyHookedLogged = true
		if _G.C_ChatInfo and _G.C_ChatInfo.SendAddonMessageLogged then
			hooksecurefunc(_G.C_ChatInfo, "SendAddonMessageLogged", function(...)
				return ChatThrottleLib.Hook_SendAddonMessageLogged(...)
			end)
		end
	end

	-- v29: Hook BNSendGameData for traffic logging
	if not self.securelyHookedBNGameData then
		self.securelyHookedBNGameData = true
		if _G.BNSendGameData then
			hooksecurefunc("BNSendGameData", function(...)
				return ChatThrottleLib.Hook_BNSendGameData(...)
			end)
		end
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
	local size = strlen(tostring(text or "")) + strlen(tostring(destination or "")) + self.MSG_OVERHEAD
	self.avail = self.avail - size
	self.nBypass = self.nBypass + size	-- just a statistic
end
function ChatThrottleLib.Hook_SendAddonMessage(prefix, text, chattype, destination, ...)
	if bMyTraffic then
		return
	end
	local self = ChatThrottleLib
	local size = tostring(text or ""):len() + tostring(prefix or ""):len();
	size = size + tostring(destination or ""):len() + self.MSG_OVERHEAD
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
	if not self then return 0 end

	local now = GetTime()
	local MAX_CPS = self.MAX_CPS or 800 -- Default if not set
	local newavail = MAX_CPS * (now - (self.LastAvailUpdate or now))
	local avail = self.avail or 0

	if now - (self.HardThrottlingBeginTime or 0) < 5 then
		-- First 5 seconds after startup/zoning: VERY hard clamping to avoid irritating the server rate limiter, it seems very cranky then
		avail = math_min(avail + (newavail*0.1), MAX_CPS*0.5)
		self.bChoking = true
	elseif self.HIGH_END_SYSTEM and self.SKIP_FPS_THROTTLING then
		-- Fast path for high-end Ryzen 7 system - skip FPS checks completely
		-- Always use maximum bandwidth for high-end systems
		avail = math_min(self.BURST or 4000, avail + newavail)
		self.bChoking = false
	elseif self.HIGH_END_SYSTEM then
		-- Fast path for high-end systems - check FPS less often and use a higher threshold
		-- Only check FPS every 0.5 seconds to reduce overhead
		if not self.lastFpsCheck or now - self.lastFpsCheck > 0.5 then
			self.lastFpsCheck = now
			self.lastFps = GetFramerate()
		end

		if self.lastFps < (self.MIN_FPS or 20) then
			-- Still throttle if FPS is too low, even on high-end systems
			avail = math_min(MAX_CPS, avail + newavail*0.5)
			self.bChoking = true
		else
			-- Fast path for high-end systems with good framerate
			avail = math_min(self.BURST or 4000, avail + newavail)
			self.bChoking = false
		end
	else
		-- Standard path for normal systems - check FPS every update
		if GetFramerate() < (self.MIN_FPS or 20) then
			avail = math_min(MAX_CPS, avail + newavail*0.5)
			self.bChoking = true
		else
			avail = math_min(self.BURST or 4000, avail + newavail)
			self.bChoking = false
		end
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

local SendAddonMessageResult = Enum.SendAddonMessageResult or {
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

function ChatThrottleLib:Despool(Prio)
	local ring = Prio.Ring
	local pos = ring.pos

	-- Fast path: if nothing to send or no bandwidth, return immediately
	if not pos or Prio.avail <= 0 then
		return
	end

	-- Use direct table access for better performance
	while pos and Prio.avail > pos[1].nSize do
		local pipe = pos
		local msg = pipe[1]

		-- Direct variable access for performance
		local f = msg.f
		local callbackFn = msg.callbackFn
		local callbackArg = msg.callbackArg
		local nSize = msg.nSize

		-- Perform the send operation
		local sendResult = PerformSend(f, unpack(msg, 1, msg.n))

		if IsThrottledSendResult(sendResult) then
			-- Message was throttled; move the pipe into the blocked ring.
			-- Use direct access to Ring objects
			ring:Remove(pipe)
			Prio.Blocked:Add(pipe)
			pos = ring.pos -- Update position after Ring modification
		else
			-- Dequeue message after submission.
			tremove(pipe, 1)
			DelMsg(msg)

			if not pipe[1] then  -- did we remove last msg in this pipe?
				ring:Remove(pipe)
				Prio.ByName[pipe.name] = nil
				DelPipe(pipe)
				pos = ring.pos -- Update position after Ring modification
			else
				pos = pos.next
			end

			-- Update bandwidth counters on successful sends.
			local didSend = (sendResult == SendAddonMessageResult.Success)
			if didSend then
				Prio.avail = Prio.avail - nSize
				Prio.nTotalSent = Prio.nTotalSent + nSize
			end

			-- Notify caller of message submission.
			if callbackFn then
				securecallfunction(callbackFn, callbackArg, didSend, sendResult)
			end
		end

		-- Update ring position for next iteration
		ring.pos = pos
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
	if not ChatThrottleLib then return end -- Safety check

	local self = ChatThrottleLib
	if not self.Prio then return end -- Not initialized yet

	self.OnUpdateDelay = (self.OnUpdateDelay or 0) + delay
	self.BlockedQueuesDelay = (self.BlockedQueuesDelay or 0) + delay

	-- Fast path for high-end systems: process very frequently
	local updateInterval = self.HIGH_END_SYSTEM and 0.03 or 0.08
	if self.OnUpdateDelay < updateInterval then
		return
	end
	self.OnUpdateDelay = 0

	-- Pre-compute available bandwidth once
	local avail = self:UpdateAvail()
	if not avail then return end -- UpdateAvail failed

	if avail < 0 then
		return -- argh. some bastard is spewing stuff past the lib. just bail early to save cpu.
	end

	-- Fast path for high-end systems: process blocked queues more frequently
	local blockedInterval = self.HIGH_END_SYSTEM and 0.15 or 0.35
	if self.BlockedQueuesDelay >= blockedInterval then
		for _, Prio in pairs(self.Prio) do
			if Prio and Prio.Ring and Prio.Blocked then
				Ring_Link(Prio.Ring, Prio.Blocked)
			end
		end

		self.BlockedQueuesDelay = 0
	end

	-- See how many of our priorities have queued messages. This is split
	-- into two counters because priorities that consist only of blocked
	-- queues must keep our OnUpdate alive, but shouldn't count toward
	-- bandwidth distribution.
	local nSendablePrios = 0
	local nBlockedPrios = 0

	-- Create a local cache of priorities with data to send for faster iteration
	local sendablePrios = {}

	for prioname, Prio in pairs(self.Prio) do
		if Prio.Ring.pos then
			nSendablePrios = nSendablePrios + 1
			sendablePrios[nSendablePrios] = Prio
		elseif Prio.Blocked.pos then
			nBlockedPrios = nBlockedPrios + 1
		end

		-- Collect unused bandwidth from priorities with nothing to send.
		if not Prio.Ring.pos then
			avail = avail + Prio.avail
			Prio.avail = 0
		end
	end

	-- Bandwidth reclamation may take us back over the burst cap.
	avail = math_min(avail, self.BURST)
	self.avail = avail

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
	local availPerPrio = avail / nSendablePrios

	-- Fast iteration through prioritized cache of sendable priorities
	for i = 1, nSendablePrios do
		local Prio = sendablePrios[i]
		Prio.avail = Prio.avail + availPerPrio
		self:Despool(Prio)
	end

	-- Reset avail to 0 after distribution
	self.avail = 0
end




-----------------------------------------------------------------------
-- Spooling logic

function ChatThrottleLib:Enqueue(prioname, pipename, msg)
	-- Direct access to priority for performance
	local Prio = self.Prio[prioname]
	local pipe = Prio.ByName[pipename]

	if not pipe then
		-- Only show the frame when we actually have something to process
		if not self.Frame:IsShown() then
			self.Frame:Show()
		end

		-- Create a new pipe and add it directly to the ring
		pipe = NewPipe()
		pipe.name = pipename

		-- Store in lookup table for quick access
		Prio.ByName[pipename] = pipe

		-- Add to ring immediately
		Prio.Ring:Add(pipe)
	end

	-- Add message to pipe directly with table insert
	tinsert(pipe, msg)

	-- Set queueing flag to true
	self.bQueueing = true
end

-----------------------------------------------------------------------
-- String pooling to reduce memory churn
-- For high-end systems with heavy addon usage, this reduces GC pressure

local StringPool = {}
local StringPoolSize = 0
local StringPoolMaxSize = 512  -- Configure based on available RAM (32GB)

-- Pre-populate string pool with commonly used strings
do
    local common_strings = {
        -- Common channel types
        "PARTY", "RAID", "GUILD", "OFFICER", "WHISPER", "CHANNEL", "SAY",
        -- Common prefixes
        "BigWigs", "DBM", "WeakAuras", "Plater", "Details", "RCLC", "Hekili"
    }

    for _, str in ipairs(common_strings) do
        StringPool[str] = str
        StringPoolSize = StringPoolSize + 1
    end
end

-- Get a string from the pool or add it if not present
local function GetPooledString(text)
    if not text then return nil end

    -- Fast check for empty strings
    if text == "" then return "" end

    -- Fast path for already pooled strings
    if StringPool[text] then
        return StringPool[text]
    end

    -- Only pool strings below a certain length to avoid memory bloat
    -- and only if they're actual strings (not numbers converted to strings)
    if type(text) == "string" and #text <= 64 and StringPoolSize < StringPoolMaxSize then
        StringPool[text] = text
        StringPoolSize = StringPoolSize + 1
    end

    return text
end

-- Original SendChatMessage wrapper function
function ChatThrottleLib:SendChatMessage(prio, prefix, text, chattype, language, destination, queueName, callbackFn, callbackArg)
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

	-- Pool commonly used strings for frequently used channel types
	chattype = chattype and GetPooledString(chattype) or "SAY"
	destination = destination and GetPooledString(destination)

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
	msg[2] = chattype
	msg[3] = language
	msg[4] = destination
	msg.n = 4
	msg.nSize = nSize
	msg.callbackFn = callbackFn
	msg.callbackArg = callbackArg

	self:Enqueue(prio, queueName or prefix, msg)
end


local function SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
	if not sendFunction then
		error("SendAddonMessageInternal: sendFunction is nil", 2)
		return
	end

	local nSize = #text + self.MSG_OVERHEAD

	-- Apply string pooling to commonly used values
	prefix = GetPooledString(prefix or "")
	chattype = GetPooledString(chattype or "PARTY")
	target = target and GetPooledString(target)
	queueName = queueName and GetPooledString(queueName) or prefix

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
	msg.n = (target~=nil) and 4 or 3;
	msg.nSize = nSize
	msg.callbackFn = callbackFn
	msg.callbackArg = callbackArg

	self:Enqueue(prio, queueName, msg)
end


function ChatThrottleLib:SendAddonMessage(prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
	if not self or not prio or not prefix or not text or not chattype or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:SendAddonMessage("{BULK||NORMAL||ALERT}", "prefix", "text", "chattype"[, "target"])', 2)
	elseif callbackFn and type(callbackFn)~="function" then
		error('ChatThrottleLib:SendAddonMessage(): callbackFn: expected function, got '..type(callbackFn), 2)
	elseif #text>255 then
		error("ChatThrottleLib:SendAddonMessage(): message length cannot exceed 255 bytes", 2)
	end

	local sendFunction = _G.C_ChatInfo and _G.C_ChatInfo.SendAddonMessage
	if not sendFunction then
		error("ChatThrottleLib:SendAddonMessage(): C_ChatInfo.SendAddonMessage not available", 2)
		return
	end
	SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
end


function ChatThrottleLib:SendAddonMessageLogged(prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
	if not self or not prio or not prefix or not text or not chattype or not self.Prio[prio] then
		error('Usage: ChatThrottleLib:SendAddonMessageLogged("{BULK||NORMAL||ALERT}", "prefix", "text", "chattype"[, "target"])', 2)
	elseif callbackFn and type(callbackFn)~="function" then
		error('ChatThrottleLib:SendAddonMessageLogged(): callbackFn: expected function, got '..type(callbackFn), 2)
	elseif #text>255 then
		error("ChatThrottleLib:SendAddonMessageLogged(): message length cannot exceed 255 bytes", 2)
	end

	local sendFunction = _G.C_ChatInfo and _G.C_ChatInfo.SendAddonMessageLogged
	if not sendFunction then
		error("ChatThrottleLib:SendAddonMessageLogged(): C_ChatInfo.SendAddonMessageLogged not available", 2)
		return
	end
	SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, target, queueName, callbackFn, callbackArg)
end

local function BNSendGameDataReordered(prefix, text, _, gameAccountID)
	return _G.BNSendGameData(gameAccountID, prefix, text)
end

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
	elseif chattype ~= "WHISPER" then
		error("ChatThrottleLib:BNSendGameData(): chat type must be 'WHISPER'", 2)
	end

	if not _G.BNSendGameData then
		error("ChatThrottleLib:BNSendGameData(): BNSendGameData not available", 2)
		return
	end

	local sendFunction = BNSendGameDataReordered
	SendAddonMessageInternal(self, sendFunction, prio, prefix, text, chattype, gameAccountID, queueName, callbackFn, callbackArg)
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


