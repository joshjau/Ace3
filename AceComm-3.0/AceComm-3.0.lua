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

local MAJOR, MINOR = "AceComm-3.0", 22 -- Version bump for The War Within optimizations
local AceComm, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceComm then return end

-- Lua APIs - Cache frequently used functions to improve performance
local type, next, pairs, tostring = type, next, pairs, tostring
local strsub, strfind, strmatch, strformat = string.sub, string.find, string.match, string.format
-- Fix for Lua 5.1 compatibility - table.pack doesn't exist in Lua 5.1
local tinsert, tconcat, tremove = table.insert, table.concat, table.remove
local tpack = rawget(table, "pack") or function(...) return {..., n = select("#", ...)} end
local error, assert, select = error, assert, select
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

-- WoW APIs
local Ambiguate = Ambiguate
local C_Timer = C_Timer
local InCombatLockdown = InCombatLockdown
local GetTime = GetTime
local debugprofilestop = debugprofilestop

-- Check for The War Within+ API availability - safer detection method
local isNewAPI = C_ChatInfo and C_ChatInfo.SendAddonMessage and
                type(select(1, pcall(function()
                    return C_ChatInfo.SendAddonMessage("", "", "WHISPER", "player")
                end))) == "boolean"

local hasSendAddonMessageEnum = Enum and Enum.SendAddonMessageResult and true or false
local AddonMessageThrottle = hasSendAddonMessageEnum and Enum.SendAddonMessageResult.AddonMessageThrottle or nil

AceComm.embeds = AceComm.embeds or {}

-- for sanity and performance, let's give the message type bytes some names and cache them
local MSG_MULTI_FIRST = "\001"
local MSG_MULTI_NEXT  = "\002"
local MSG_MULTI_LAST  = "\003"
local MSG_ESCAPE = "\004"

-- Control bytes pattern (cache this for performance)
local CONTROL_PATTERN = "^([\001-\009])(.*)"

-- remove old structures (pre WoW 4.0)
AceComm.multipart_origprefixes = nil
AceComm.multipart_reassemblers = nil

-- the multipart message spool: indexed by a combination of sender+distribution+
AceComm.multipart_spool = AceComm.multipart_spool or {}

-- Cache of registered prefixes for quick lookups
AceComm.registeredPrefixes = AceComm.registeredPrefixes or {}

-- Performance optimization: cache key generation function
local function GetSpoolKey(prefix, distribution, sender)
    return prefix.."\t"..distribution.."\t"..sender
end

-- Combat-optimized table pool implementation
do
    -- Create a weak-keyed table to hold recycled tables
    local tablePool = setmetatable({}, {__mode = "k"})
    local poolSize = 0
    local MAX_POOL_SIZE = 50 -- Prevent excessive memory usage

    -- Get a table from the pool or create a new one
    function AceComm:GetTable()
        local t = next(tablePool)
        if t then
            tablePool[t] = nil
            poolSize = poolSize - 1
            return t
        end
        return {}
    end

    -- Return a table to the pool
    function AceComm:ReleaseTable(t)
        if type(t) ~= "table" then return end
        -- Clear the table
        for k in pairs(t) do t[k] = nil end

        -- Only store if we're not at pool limit
        if poolSize < MAX_POOL_SIZE then
            tablePool[t] = true
            poolSize = poolSize + 1
        end
    end
end

-- Performance profiling system
do
    local profilingEnabled = false
    local profileData = {}
    local lastFlushTime = 0
    local PROFILE_FLUSH_INTERVAL = 60 -- Save to file every minute if profiling enabled
    local FILE_PREFIX = "AceComm3_Profile_"

    -- Safely write data to file if we can
    local function SaveProfileToFile()
        if not profilingEnabled or not profileData or #profileData == 0 then return end

        -- Create a timestamp for the filename
        local timestamp = date("%Y%m%d%H%M%S")
        local fileName = FILE_PREFIX .. timestamp .. ".lua"

        -- Try to open file and save
        local success, fileHandle = pcall(function() return io.open(fileName, "w") end)
        if success and fileHandle then
            -- Write file header
            fileHandle:write("-- AceComm-3.0 Performance Profile: " .. date("%Y-%m-%d %H:%M:%S") .. "\n")
            fileHandle:write("return {\n")

            -- Write each profile entry
            for i, entry in ipairs(profileData) do
                fileHandle:write(strformat("  [%d] = {op = %q, duration = %.3f, msgSize = %d, timestamp = %d},\n",
                                  i, entry.op, entry.duration, entry.size or 0, entry.timestamp))
            end

            fileHandle:write("}\n")
            fileHandle:close()

            -- Clear profile data after saving
            wipe(profileData)

            if AceComm.debugMode then
                print(strformat("AceComm-3.0: Profile data saved to %s", fileName))
            end
        elseif AceComm.debugMode then
            print("AceComm-3.0: Failed to save profile data to file.")
        end

        lastFlushTime = GetTime()
    end

    -- Record a profiling data point
    function AceComm:ProfileOperation(operation, startTime, messageSize)
        if not profilingEnabled then return end

        local duration = debugprofilestop() - startTime
        tinsert(profileData, {
            op = operation,
            duration = duration,
            size = messageSize,
            timestamp = GetTime()
        })

        -- Check if we should flush to file
        if GetTime() - lastFlushTime > PROFILE_FLUSH_INTERVAL then
            SaveProfileToFile()
        end
    end

    -- Enable or disable profiling
    function AceComm:SetProfiling(enable, autoSave)
        profilingEnabled = enable and true or false

        -- If turning off and we have data, save it
        if not enable and #profileData > 0 and autoSave then
            SaveProfileToFile()
        end

        return profilingEnabled
    end

    -- Force saving current profile data
    function AceComm:SaveProfile()
        SaveProfileToFile()
    end
end

-- Pre-cache formatted error messages for performance
local ERROR_PREFIX_LENGTH = "AceComm:RegisterComm(prefix,method): prefix length is limited to 16 characters"
local ERROR_SENDCOMM_USAGE = 'Usage: SendCommMessage(addon, "prefix", "text", "distribution"[, "target"[, "prio"[, callbackFn, callbackarg]]])'

--- Register for Addon Traffic on a specified prefix
-- @param prefix A printable character (\032-\255) classification of the message (typically AddonName or AddonNameEvent), max 16 characters
-- @param method Callback to call on message reception: Function reference, or method name (string) to call on self. Defaults to "OnCommReceived"
function AceComm:RegisterComm(prefix, method)
    if method == nil then
        method = "OnCommReceived"
    end

    if #prefix > 16 then
        error(ERROR_PREFIX_LENGTH)
    end

    -- Use C_ChatInfo API if available (8.0+)
    if C_ChatInfo then
        C_ChatInfo.RegisterAddonMessagePrefix(prefix)
    else
        RegisterAddonMessagePrefix(prefix)
    end

    -- Cache registered prefixes for quick access
    AceComm.registeredPrefixes[prefix] = true

    return AceComm._RegisterComm(self, prefix, method)    -- created by CallbackHandler
end

-- Special handling for throttled messages, with intelligent retry logic
local throttledPrefixes = {}
local function HandleThrottledMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
    -- If this prefix is already scheduled for retry, update with latest parameters
    if throttledPrefixes[prefix] then
        local retry = throttledPrefixes[prefix]
        retry.text = text
        retry.distribution = distribution
        retry.target = target
        retry.prio = prio
        retry.callbackFn = callbackFn
        retry.callbackArg = callbackArg
        -- Keep the existing timer running
        return
    end

    -- Store info for retry
    throttledPrefixes[prefix] = {
        text = text,
        distribution = distribution,
        target = target,
        prio = prio,
        callbackFn = callbackFn,
        callbackArg = callbackArg,
        attempts = 0
    }

    -- Schedule retry after 1.2 seconds (slightly longer than throttle rate)
    C_Timer.After(1.2, function()
        local retry = throttledPrefixes[prefix]
        if not retry then return end

        retry.attempts = retry.attempts + 1
        -- Only retry up to 3 times to prevent infinite loops
        if retry.attempts > 3 then
            throttledPrefixes[prefix] = nil
            return
        end

        -- Try sending again
        AceComm:SendCommMessage(prefix, retry.text, retry.distribution, retry.target, retry.prio, retry.callbackFn, retry.callbackArg)
        throttledPrefixes[prefix] = nil
    end)
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
    local profileStart = AceComm.profilingEnabled and debugprofilestop()

    prio = prio or "NORMAL"
    if not(type(prefix)=="string" and
           type(text)=="string" and
           type(distribution)=="string" and
           (target==nil or type(target)=="string" or type(target)=="number") and
           (prio=="BULK" or prio=="NORMAL" or prio=="ALERT")
          ) then
        error(ERROR_SENDCOMM_USAGE, 2)
    end

    local textlen = #text
    local maxtextlen = 255  -- Max character limit (4.1+)
    local queueName = prefix

    -- Debug logging
    if AceComm.debugMode then
        print(strformat("AceComm-3.0: Sending message on prefix '%s', %d bytes, distribution '%s'",
              prefix, textlen, distribution))
    end

    -- Optimize callback creation - only create when needed
    local ctlCallback
    if callbackFn then
        ctlCallback = function(sent, sendResult)
            -- Handle new API return values in The War Within+
            if isNewAPI and sendResult and hasSendAddonMessageEnum then
                -- If throttled, attempt intelligent retry
                if sendResult == AddonMessageThrottle then
                    HandleThrottledMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
                    return
                end
            end
            return callbackFn(callbackArg, sent, textlen, sendResult)
        end
    elseif isNewAPI and hasSendAddonMessageEnum then
        -- Create a minimal callback to handle throttling even when no user callback provided
        ctlCallback = function(sent, sendResult)
            if sendResult == AddonMessageThrottle then
                HandleThrottledMessage(prefix, text, distribution, target, prio, nil, nil)
            end
        end
    end

    -- Quickly check if we need to handle control characters in first position
    local forceMultipart
    local firstChar = strsub(text, 1, 1)
    if firstChar >= "\001" and firstChar <= "\009" then
        if textlen+1 > maxtextlen then    -- would we go over the size limit?
            forceMultipart = true    -- just make it multipart, no escape problems then
        else
            text = MSG_ESCAPE .. text
        end
    end

    if not forceMultipart and textlen <= maxtextlen then
        -- Single part message - most efficient path
        CTL:SendAddonMessage(prio, prefix, text, distribution, target, queueName, ctlCallback, textlen)
    else
        -- Multipart message handling
        maxtextlen = maxtextlen - 1    -- 1 extra byte for part indicator

        -- Performance optimization: pre-calculate chunk positions
        local numChunks = math.ceil(textlen / maxtextlen)
        local positions = AceComm:GetTable()

        -- Calculate all chunk bounds in one go
        for i = 1, numChunks do
            local startPos = 1 + (i-1) * maxtextlen
            local endPos = math.min(startPos + maxtextlen - 1, textlen)
            positions[i] = {startPos, endPos}
        end

        -- Send first part
        local startPos, endPos = positions[1][1], positions[1][2]
        local chunk = strsub(text, startPos, endPos)
        CTL:SendAddonMessage(prio, prefix, MSG_MULTI_FIRST..chunk, distribution, target, queueName, ctlCallback, maxtextlen)

        -- Send middle parts (if any)
        for i = 2, numChunks-1 do
            startPos, endPos = positions[i][1], positions[i][2]
            chunk = strsub(text, startPos, endPos)
            CTL:SendAddonMessage(prio, prefix, MSG_MULTI_NEXT..chunk, distribution, target, queueName, ctlCallback, endPos)
        end

        -- Send final part
        if numChunks > 1 then
            startPos, endPos = positions[numChunks][1], positions[numChunks][2]
            chunk = strsub(text, startPos, endPos)
            CTL:SendAddonMessage(prio, prefix, MSG_MULTI_LAST..chunk, distribution, target, queueName, ctlCallback, textlen)
        end

        -- Release the table back to the pool
        AceComm:ReleaseTable(positions)
    end

    -- Record profiling data if enabled
    if profileStart then
        AceComm:ProfileOperation("send", profileStart, textlen)
    end
end

----------------------------------------
-- Message receiving
----------------------------------------

-- Declare multipart handlers at file level
local OnReceiveMultipartFirst, OnReceiveMultipartNext, OnReceiveMultipartLast

do
    -- Error messages for common issues - preallocated strings for performance
    local WARNING_LOST_DATA = "%s: Warning: lost network data regarding '%s' from '%s' (in %s)"

    -- Queue for cleanup of multipart messages
    local staleMessages = {}
    local STALE_MESSAGE_TIMEOUT = 300 -- 5 minutes timeout for abandoned multipart messages

    -- Function to clean up stale multipart messages
    local function CleanupStaleMessages()
        local now = GetTime()
        local spool = AceComm.multipart_spool
        local count = 0

        -- Check for stale messages
        for key, message in pairs(spool) do
            local timestamp = staleMessages[key]
            if not timestamp then
                -- Track when we first saw this message
                staleMessages[key] = now
            elseif now - timestamp > STALE_MESSAGE_TIMEOUT then
                -- Message has been around too long, remove it
                spool[key] = nil
                staleMessages[key] = nil
                count = count + 1

                if AceComm.debugMode then
                    print(strformat("AceComm-3.0: Cleaned up stale multipart message with key '%s'", key))
                end
            end
        end

        -- Clean up staleMessages entries for messages that no longer exist
        for key in pairs(staleMessages) do
            if not spool[key] then
                staleMessages[key] = nil
            end
        end

        if AceComm.debugMode and count > 0 then
            print(strformat("AceComm-3.0: Cleaned up %d stale multipart messages", count))
        end

        -- Schedule next cleanup
        C_Timer.After(60, CleanupStaleMessages)
    end

    -- Start the cleanup timer
    C_Timer.After(60, CleanupStaleMessages)

    -- Define the function implementations
    OnReceiveMultipartFirst = function(self, prefix, message, distribution, sender)
        local profileStart = self.profilingEnabled and debugprofilestop()

        local key = GetSpoolKey(prefix, distribution, sender)
        local spool = self.multipart_spool

        -- Debug logging
        if self.debugMode and spool[key] then
            print(strformat("AceComm-3.0: Received overlapping first part for '%s' from '%s', overwriting previous data",
                  prefix, sender))
        end

        spool[key] = message  -- plain string for now

        -- Record profiling data if enabled
        if profileStart then
            self:ProfileOperation("recv_first", profileStart, #message)
        end
    end

    OnReceiveMultipartNext = function(self, prefix, message, distribution, sender)
        local profileStart = self.profilingEnabled and debugprofilestop()

        local key = GetSpoolKey(prefix, distribution, sender)
        local spool = self.multipart_spool
        local olddata = spool[key]

        if not olddata then
            if self.debugMode then
                print(strformat("AceComm-3.0: Received next part with no first part for '%s' from '%s'", prefix, sender))
            end
            return
        end

        if type(olddata) ~= "table" then
            -- ... but what we have is not a table. So make it one.
            local t = self:GetTable()
            t[1] = olddata    -- add old data as first string
            t[2] = message    -- and new message as second string
            spool[key] = t    -- and put the table in the spool instead of the old string
        else
            tinsert(olddata, message)
        end

        -- Record profiling data if enabled
        if profileStart then
            self:ProfileOperation("recv_next", profileStart, #message)
        end
    end

    OnReceiveMultipartLast = function(self, prefix, message, distribution, sender)
        local profileStart = self.profilingEnabled and debugprofilestop()

        local key = GetSpoolKey(prefix, distribution, sender)
        local spool = self.multipart_spool
        local olddata = spool[key]

        if not olddata then
            if self.debugMode then
                print(strformat("AceComm-3.0: Received last part with no first part for '%s' from '%s'", prefix, sender))
            end
            return
        end

        spool[key] = nil
        -- Also remove from stale tracking
        staleMessages[key] = nil

        if type(olddata) == "table" then
            -- if we've received a "next", the spooled data will be a table for rapid & garbage-free tconcat
            tinsert(olddata, message)

            local finalMessage = tconcat(olddata, "")

            -- Debug logging
            if self.debugMode then
                print(strformat("AceComm-3.0: Successfully assembled multipart message for '%s' from '%s', %d bytes in %d parts",
                      prefix, sender, #finalMessage, #olddata))
            end

            -- Use direct callback firing for performance
            self.callbacks:Fire(prefix, finalMessage, distribution, sender)
            -- Return table to pool
            self:ReleaseTable(olddata)
        else
            -- if we've only received a "first", the spooled data will still only be a string
            local finalMessage = olddata..message

            -- Debug logging
            if self.debugMode then
                print(strformat("AceComm-3.0: Successfully assembled 2-part message for '%s' from '%s', %d bytes",
                      prefix, sender, #finalMessage))
            end

            self.callbacks:Fire(prefix, finalMessage, distribution, sender)
        end

        -- Record profiling data if enabled
        if profileStart then
            self:ProfileOperation("recv_last", profileStart, #message)
        end
    end
end

----------------------------------------
-- Pre-Combat Message Caching and Intelligent Processing
----------------------------------------

-- Add combat-aware processing
do
    local pendingMessages = {}
    local processingTimer

    local function ProcessPendingMessages()
        if InCombatLockdown() then
            -- If still in combat, check again later
            processingTimer = C_Timer.After(0.5, ProcessPendingMessages)
            return
        end

        processingTimer = nil

        -- Process up to 10 messages at a time to avoid lag spikes
        local count = 0
        for i = 1, #pendingMessages do
            if count >= 10 then
                -- Schedule another pass to handle the rest
                processingTimer = C_Timer.After(0.1, ProcessPendingMessages)
                break
            end

            local msg = tremove(pendingMessages, 1)
            if msg then
                AceComm.callbacks:Fire(msg.prefix, msg.message, msg.distribution, msg.sender)
                count = count + 1
            else
                break
            end
        end
    end

    -- Function to add a received message to the processing queue
    function AceComm:QueueMessageProcessing(prefix, message, distribution, sender)
        tinsert(pendingMessages, {
            prefix = prefix,
            message = message,
            distribution = distribution,
            sender = sender
        })

        -- Start processing if not already running
        if not processingTimer then
            processingTimer = C_Timer.After(0.1, ProcessPendingMessages)
        end
    end

    -- Combat optimization toggle
    AceComm.optimizeCombat = true
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

-- Optimized event handler
local function OnEvent(self, event, prefix, message, distribution, sender)
    local profileStart = AceComm.profilingEnabled and debugprofilestop()

    if event == "CHAT_MSG_ADDON" then
        sender = Ambiguate(sender, "none")

        -- Debug mode logging
        if AceComm.debugMode then
            print(strformat("AceComm-3.0: Received message on prefix '%s' from '%s', %d bytes",
                  prefix, sender, #message))
        end

        -- Optimization: use pattern matching with cached pattern
        local control, rest = strmatch(message, CONTROL_PATTERN)

        if control then
            -- Using direct comparisons rather than sequential if/elseif for performance
            if control == MSG_MULTI_FIRST then
                OnReceiveMultipartFirst(AceComm, prefix, rest, distribution, sender)
            elseif control == MSG_MULTI_NEXT then
                OnReceiveMultipartNext(AceComm, prefix, rest, distribution, sender)
            elseif control == MSG_MULTI_LAST then
                OnReceiveMultipartLast(AceComm, prefix, rest, distribution, sender)
            elseif control == MSG_ESCAPE then
                -- Check if we should delay processing during combat
                if AceComm.optimizeCombat and InCombatLockdown() then
                    AceComm:QueueMessageProcessing(prefix, rest, distribution, sender)
                else
                    AceComm.callbacks:Fire(prefix, rest, distribution, sender)
                end
            end
            -- Silently ignore other control characters (future extensions)
        else
            -- single part message
            -- Check if we should delay processing during combat
            if AceComm.optimizeCombat and InCombatLockdown() then
                AceComm:QueueMessageProcessing(prefix, message, distribution, sender)
            else
                AceComm.callbacks:Fire(prefix, message, distribution, sender)
            end
        end
    else
        assert(false, "Received "..tostring(event).." event?!")
    end

    -- Record profiling data if enabled
    if profileStart then
        AceComm:ProfileOperation("handle_event", profileStart, #message or 0)
    end
end

AceComm.frame = AceComm.frame or CreateFrame("Frame", "AceComm30Frame")
AceComm.frame:SetScript("OnEvent", OnEvent)
AceComm.frame:UnregisterAllEvents()
AceComm.frame:RegisterEvent("CHAT_MSG_ADDON")

----------------------------------------
-- Public Utility Functions
----------------------------------------

-- Debug mode setting
AceComm.debugMode = false

-- Profiling setting
AceComm.profilingEnabled = false

-- Allow addons to pre-cache critical data
function AceComm:PreCachePrefix(prefix)
    if not prefix or type(prefix) ~= "string" or #prefix > 16 then
        error("AceComm:PreCachePrefix(prefix): prefix must be a string of at most 16 characters")
        return
    end

    -- Register the prefix if not already registered
    if not AceComm.registeredPrefixes[prefix] then
        if C_ChatInfo then
            C_ChatInfo.RegisterAddonMessagePrefix(prefix)
        else
            RegisterAddonMessagePrefix(prefix)
        end
        AceComm.registeredPrefixes[prefix] = true
    end

    return true
end

-- Configure combat optimization
function AceComm:SetCombatOptimization(enable)
    AceComm.optimizeCombat = enable and true or false
end

-- Get current API status information
function AceComm:GetAPIInfo()
    local info = AceComm:GetTable()
    info.isNewAPI = isNewAPI
    info.hasSendAddonMessageEnum = hasSendAddonMessageEnum
    info.version = MINOR
    return info
end

-- Enable or disable debug mode
function AceComm:SetDebugMode(enable)
    self.debugMode = enable and true or false
    return self.debugMode
end

-- Enable or disable profiling
function AceComm:EnableProfiling(enable, autoSave)
    self.profilingEnabled = enable and true or false
    return self:SetProfiling(enable, autoSave)
end

----------------------------------------
-- Base library stuff
----------------------------------------

local mixins = {
    "RegisterComm",
    "UnregisterComm",
    "UnregisterAllComm",
    "SendCommMessage",
    "PreCachePrefix",
    "SetCombatOptimization",
    "GetAPIInfo",
    "SetDebugMode",
    "EnableProfiling",
    "SaveProfile",
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
