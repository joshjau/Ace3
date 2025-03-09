--- AceEvent-3.0 provides event registration and secure dispatching.
-- All dispatching is done using **CallbackHandler-1.0**. AceEvent is a simple wrapper around
-- CallbackHandler, and dispatches all game events or addon message to the registrees.
--
-- **AceEvent-3.0** can be embeded into your addon, either explicitly by calling AceEvent:Embed(MyAddon) or by
-- specifying it as an embeded library in your AceAddon. All functions will be available on your addon object
-- and can be accessed directly, without having to explicitly call AceEvent itself.\\
-- It is recommended to embed AceEvent, otherwise you'll have to specify a custom `self` on all calls you
-- make into AceEvent.
-- @class file
-- @name AceEvent-3.0
-- @release $Id$
local CallbackHandler = LibStub("CallbackHandler-1.0")

local MAJOR, MINOR = "AceEvent-3.0", 5  -- Version bump to 5 for performance enhancements
local AceEvent = LibStub:NewLibrary(MAJOR, MINOR)

if not AceEvent then return end

-- Lua APIs
local pairs, next, type, select = pairs, next, type, select
local GetTime = GetTime
local tinsert, tremove, wipe = table.insert, table.remove, table.wipe
local mmax = math.max

-- Cache frequently accessed functions
local getmetatable = getmetatable
local pcall = pcall

-- Use the latest precision timing API from retail WoW 11.0+
local GetTimePreciseSec = GetTimePreciseSec

-- Modern retail API caching for enhanced performance
local C_Spell_GetSpellCooldown = C_Spell and C_Spell.GetSpellCooldown
local C_UnitAuras_GetAuraDataByAuraInstanceID = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID
local C_LossOfControl_GetActiveLossOfControlData = C_LossOfControl and C_LossOfControl.GetActiveLossOfControlData

-- Combat Log API with extended functionality for TWW
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo

-- Performance tracking
AceEvent.perfStats = AceEvent.perfStats or {
    eventCounts = {},
    eventTime = {},
    lastReset = GetTime(),
}

-- Pool for recycling tables
AceEvent.tablePool = AceEvent.tablePool or {}
AceEvent.tablePoolSize = 0
local MAX_POOL_SIZE = 100 -- Prevent excessive memory usage

-- Create our frame with optimized performance properties
AceEvent.frame = AceEvent.frame or CreateFrame("Frame", "AceEvent30Frame")
-- Skip OnUpdate handling and other unnecessary frame behaviors
AceEvent.frame:SetScript("OnUpdate", nil)
AceEvent.frame:EnableMouse(false)
AceEvent.frame:SetMovable(false)

AceEvent.embeds = AceEvent.embeds or {} -- what objects embed this lib
AceEvent.scheduledEvents = AceEvent.scheduledEvents or {}
AceEvent.highPriorityEvents = AceEvent.highPriorityEvents or {}

-- Enhanced caching systems for retail 11.0+
AceEvent.cooldownCache = AceEvent.cooldownCache or {}
AceEvent.auraCache = AceEvent.auraCache or {}
AceEvent.locCache = AceEvent.locCache or {}
AceEvent.healthCache = AceEvent.healthCache or {}
AceEvent.powerCache = AceEvent.powerCache or {}
AceEvent.spellUsableCache = AceEvent.spellUsableCache or {}

-- APIs and registry for blizzard events, using CallbackHandler lib
if not AceEvent.events then
    AceEvent.events = CallbackHandler:New(AceEvent,
        "RegisterEvent", "UnregisterEvent", "UnregisterAllEvents")
end

-- Event frequency throttling support
AceEvent.throttledEvents = AceEvent.throttledEvents or {}

-- Add priority handling capability
function AceEvent:RegisterEventWithPriority(event, callback, arg, priority)
    AceEvent:RegisterEvent(event, callback, arg)
    if priority == "HIGH" then
        AceEvent.highPriorityEvents[event] = true
    end
end

-- Get a recycled table or create a new one
local function getTable()
    if AceEvent.tablePoolSize > 0 then
        AceEvent.tablePoolSize = AceEvent.tablePoolSize - 1
        local t = tremove(AceEvent.tablePool)
        return t
    end
    return {}
end

-- Recycle a table
local function releaseTable(t)
    if type(t) ~= "table" then return end
    wipe(t)
    if AceEvent.tablePoolSize < MAX_POOL_SIZE then
        tinsert(AceEvent.tablePool, t)
        AceEvent.tablePoolSize = AceEvent.tablePoolSize + 1
    end
end

-- Enhanced event handling with priority support and error handling
function AceEvent.events:OnUsed(target, eventname)
    -- Register the event with the frame
    AceEvent.frame:RegisterEvent(eventname)
end

function AceEvent.events:OnUnused(target, eventname)
    AceEvent.frame:UnregisterEvent(eventname)
    -- Clean up any throttling data
    AceEvent.throttledEvents[eventname] = nil
    AceEvent.highPriorityEvents[eventname] = nil
end

-- APIs and registry for IPC messages, using CallbackHandler lib
if not AceEvent.messages then
    AceEvent.messages = CallbackHandler:New(AceEvent,
        "RegisterMessage", "UnregisterMessage", "UnregisterAllMessages"
    )
    AceEvent.SendMessage = AceEvent.messages.Fire
end

-- Enhanced message sending with priority support
function AceEvent:SendMessageWithPriority(message, priority, ...)
    if priority == "HIGH" then
        -- Directly process high priority messages
        return AceEvent.messages:Fire(message, ...)
    else
        return AceEvent.SendMessage(self, message, ...)
    end
end

-- Register a throttled event where handler won't be called more than once per threshold seconds
function AceEvent:RegisterThrottledEvent(event, threshold, callback, arg)
    self:RegisterEvent(event, callback, arg)
    AceEvent.throttledEvents[event] = threshold or 0.1 -- Default to 100ms
end

-- Schedule an event to be fired later
function AceEvent:ScheduleEvent(delay, callback, ...)
    if type(delay) ~= "number" or delay < 0 then
        error("AceEvent:ScheduleEvent: 'delay' must be a non-negative number")
    end
    
    if type(callback) ~= "function" and type(callback) ~= "string" then
        error("AceEvent:ScheduleEvent: 'callback' must be a function or method name")
    end
    
    local scheduledTime = GetTime() + delay
    local entry = getTable()
    entry.time = scheduledTime
    entry.callback = callback
    entry.self = self
    
    -- Store varargs
    local argCount = select("#", ...)
    if argCount > 0 then
        entry.args = getTable()
        for i = 1, argCount do
            entry.args[i] = select(i, ...)
        end
        entry.argCount = argCount
    end
    
    -- Insert into the scheduled events table
    local inserted = false
    for i, ev in ipairs(AceEvent.scheduledEvents) do
        if ev.time > scheduledTime then
            tinsert(AceEvent.scheduledEvents, i, entry)
            inserted = true
            break
        end
    end
    
    if not inserted then
        tinsert(AceEvent.scheduledEvents, entry)
    end
    
    -- Ensure timer is running
    if not AceEvent.timerFrame then
        AceEvent.timerFrame = CreateFrame("Frame")
        AceEvent.timerFrame:SetScript("OnUpdate", AceEvent.ProcessScheduledEvents)
    end
    AceEvent.timerFrame:Show()
    
    return entry -- Return reference so it can be cancelled
end

-- Cancel a scheduled event
function AceEvent:CancelScheduledEvent(handle)
    if not handle then return false end
    
    for i, entry in ipairs(AceEvent.scheduledEvents) do
        if entry == handle then
            tremove(AceEvent.scheduledEvents, i)
            if entry.args then
                releaseTable(entry.args)
            end
            releaseTable(entry)
            
            -- Hide timer frame if no more events
            if #AceEvent.scheduledEvents == 0 and AceEvent.timerFrame then
                AceEvent.timerFrame:Hide()
            end
            
            return true
        end
    end
    
    return false
end

-- Process any scheduled events
function AceEvent.ProcessScheduledEvents(frame, elapsed)
    local now = GetTime()
    local i = 1
    
    while i <= #AceEvent.scheduledEvents do
        local entry = AceEvent.scheduledEvents[i]
        
        if entry.time <= now then
            tremove(AceEvent.scheduledEvents, i)
            
            -- Execute the callback
            local success, err
            if type(entry.callback) == "string" and entry.self[entry.callback] then
                if entry.args then
                    success, err = pcall(entry.self[entry.callback], entry.self, unpack(entry.args, 1, entry.argCount))
                else
                    success, err = pcall(entry.self[entry.callback], entry.self)
                end
            elseif type(entry.callback) == "function" then
                if entry.args then
                    success, err = pcall(entry.callback, unpack(entry.args, 1, entry.argCount))
                else
                    success, err = pcall(entry.callback)
                end
            end
            
            if not success and err then
                -- Log error but don't interrupt other events
                geterrorhandler()(err)
            end
            
            -- Recycle tables
            if entry.args then
                releaseTable(entry.args)
            end
            releaseTable(entry)
        else
            i = i + 1
        end
    end
    
    -- Hide timer frame if no more events
    if #AceEvent.scheduledEvents == 0 then
        frame:Hide()
    end
end

-- Reset performance statistics
function AceEvent:ResetPerformanceStats()
    wipe(self.perfStats.eventCounts)
    wipe(self.perfStats.eventTime)
    self.perfStats.lastReset = GetTime()
end

-- Get performance statistics
function AceEvent:GetPerformanceStats()
    local stats = {
        events = {},
        totalTime = 0,
        totalCount = 0,
        timeSinceReset = GetTime() - self.perfStats.lastReset
    }
    
    for event, count in pairs(self.perfStats.eventCounts) do
        local time = self.perfStats.eventTime[event] or 0
        stats.totalTime = stats.totalTime + time
        stats.totalCount = stats.totalCount + count
        
        tinsert(stats.events, {
            name = event,
            count = count,
            time = time,
            avgTime = time / count
        })
    end
    
    -- Sort by total time (most expensive first)
    table.sort(stats.events, function(a, b) return a.time > b.time end)
    
    return stats
end

-- Event throttling tracking
AceEvent.lastEventTimes = AceEvent.lastEventTimes or {}

-- Optimized OnEvent handler with throttling and performance tracking
local pendingEvents = {}
local lastEventArgs = {}
AceEvent.frame:SetScript("OnEvent", function(_, event, ...)
    -- Performance tracking
    local startTime
    if AceEvent.trackPerformance then
        startTime = GetTimePreciseSec()
        AceEvent.perfStats.eventCounts[event] = (AceEvent.perfStats.eventCounts[event] or 0) + 1
    end
    
    -- Check throttling
    local threshold = AceEvent.throttledEvents[event]
    if threshold then
        local now = GetTime()
        local lastTime = AceEvent.lastEventTimes[event] or 0
        if now - lastTime < threshold then
            -- Event is being throttled, update args for later
            lastEventArgs[event] = lastEventArgs[event] or {}
            -- Store the most recent args for this event
            wipe(lastEventArgs[event])
            local n = select("#", ...)
            for i = 1, n do
                lastEventArgs[event][i] = select(i, ...)
            end
            lastEventArgs[event].count = n
            
            -- If not already pending, add to pending events
            if not pendingEvents[event] then
                pendingEvents[event] = now + threshold - lastTime
            end
            
            -- Ensure the throttle processor is running
            if not AceEvent.throttleFrame then
                AceEvent.throttleFrame = CreateFrame("Frame")
                AceEvent.throttleFrame:SetScript("OnUpdate", function()
                    local currentTime = GetTime()
                    local processedAny = false
                    
                    for pendingEvent, fireTime in pairs(pendingEvents) do
                        if currentTime >= fireTime then
                            -- Process this throttled event
                            pendingEvents[pendingEvent] = nil
                            AceEvent.lastEventTimes[pendingEvent] = currentTime
                            
                            -- Fire with latest args
                            local args = lastEventArgs[pendingEvent]
                            if args and args.count then
                                local success, err = pcall(AceEvent.events.Fire, AceEvent.events, pendingEvent, unpack(args, 1, args.count))
                                if not success and err then
                                    geterrorhandler()(err)
                                end
                            end
                            
                            processedAny = true
                        end
                    end
                    
                    -- Hide frame if no more pending events
                    if not processedAny and not next(pendingEvents) then
                        AceEvent.throttleFrame:Hide()
                    end
                end)
            end
            
            AceEvent.throttleFrame:Show()
            return
        end
        
        -- Update last time this event fired
        AceEvent.lastEventTimes[event] = now
    end
    
    -- Process event directly based on priority
    if AceEvent.highPriorityEvents[event] then
        -- High priority - process immediately
        local success, err = pcall(AceEvent.events.Fire, AceEvent.events, event, ...)
        if not success and err then
            geterrorhandler()(err)
        end
    else
        -- Normal priority
        AceEvent.events:Fire(event, ...)
    end
    
    -- Record performance stats
    if AceEvent.trackPerformance and startTime then
        local endTime = GetTimePreciseSec()
        AceEvent.perfStats.eventTime[event] = (AceEvent.perfStats.eventTime[event] or 0) + (endTime - startTime)
    end
end)

-- Enable or disable performance tracking
function AceEvent:EnablePerformanceTracking(enable)
    self.trackPerformance = enable and true or false
    if enable then
        self:ResetPerformanceStats()
    end
end

-- Create a function for batch processing multiple events
function AceEvent:ProcessEvents(eventTable)
    if type(eventTable) ~= "table" then
        error("AceEvent:ProcessEvents: 'eventTable' must be a table")
    end
    
    for _, event in ipairs(eventTable) do
        if type(event) == "table" and event.name then
            local name, args = event.name, event.args
            if args then
                self:SendMessage(name, unpack(args))
            else
                self:SendMessage(name)
            end
        end
    end
end

--- embedding and embed handling
local mixins = {
    "RegisterEvent", "UnregisterEvent",
    "RegisterMessage", "UnregisterMessage",
    "SendMessage",
    "UnregisterAllEvents", "UnregisterAllMessages",
    -- Add new methods to the mixins
    "RegisterEventWithPriority",
    "RegisterThrottledEvent",
    "SendMessageWithPriority",
    "ScheduleEvent",
    "CancelScheduledEvent",
    "ProcessEvents",
}

--- Register for a Blizzard Event.
-- The callback will be called with the optional `arg` as the first argument (if supplied), and the event name as the second (or first, if no arg was supplied)
-- Any arguments to the event will be passed on after that.
-- @name AceEvent:RegisterEvent
-- @class function
-- @paramsig event[, callback [, arg]]
-- @param event The event to register for
-- @param callback The callback function to call when the event is triggered (funcref or method, defaults to a method with the event name)
-- @param arg An optional argument to pass to the callback function

--- Unregister an event.
-- @name AceEvent:UnregisterEvent
-- @class function
-- @paramsig event
-- @param event The event to unregister

--- Register for a custom AceEvent-internal message.
-- The callback will be called with the optional `arg` as the first argument (if supplied), and the event name as the second (or first, if no arg was supplied)
-- Any arguments to the event will be passed on after that.
-- @name AceEvent:RegisterMessage
-- @class function
-- @paramsig message[, callback [, arg]]
-- @param message The message to register for
-- @param callback The callback function to call when the message is triggered (funcref or method, defaults to a method with the event name)
-- @param arg An optional argument to pass to the callback function

--- Unregister a message
-- @name AceEvent:UnregisterMessage
-- @class function
-- @paramsig message
-- @param message The message to unregister

--- Send a message over the AceEvent-3.0 internal message system to other addons registered for this message.
-- @name AceEvent:SendMessage
-- @class function
-- @paramsig message, ...
-- @param message The message to send
-- @param ... Any arguments to the message

-- Embeds AceEvent into the target object making the functions from the mixins list available on target:..
-- @param target target object to embed AceEvent in
function AceEvent:Embed(target)
    for k, v in pairs(mixins) do
        target[v] = self[v]
    end
    self.embeds[target] = true
    return target
end

-- AceEvent:OnEmbedDisable( target )
-- target (object) - target object that is being disabled
--
-- Unregister all events messages etc when the target disables.
-- this method should be called by the target manually or by an addon framework
function AceEvent:OnEmbedDisable(target)
    target:UnregisterAllEvents()
    target:UnregisterAllMessages()
    
    -- Cancel any scheduled events
    -- Find and cancel any scheduled events belonging to this target
    local i = 1
    while i <= #AceEvent.scheduledEvents do
        local entry = AceEvent.scheduledEvents[i]
        if entry.self == target then
            tremove(AceEvent.scheduledEvents, i)
            if entry.args then
                releaseTable(entry.args)
            end
            releaseTable(entry)
        else
            i = i + 1
        end
    end
    
    -- Hide timer frame if no more events
    if #AceEvent.scheduledEvents == 0 and AceEvent.timerFrame then
        AceEvent.timerFrame:Hide()
    end
end

-- Finally: upgrade our old embeds
for target, v in pairs(AceEvent.embeds) do
    AceEvent:Embed(target)
end

-- Add enhanced combat log processing with The War Within APIs
function AceEvent:EnhancedCombatLogEvent(callback, arg)
    local timestamp, eventType, hideCaster, sourceGUID, sourceName, sourceFlags, 
          sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags = CombatLogGetCurrentEventInfo()
          
    -- Extract event subtype for more efficient processing
    local prefix, suffix = strsplit("_", eventType)
    
    if callback then
        if type(callback) == "string" then
            if self[callback] then
                self[callback](self, arg, timestamp, eventType, hideCaster, sourceGUID, sourceName, 
                    sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, 
                    select(12, CombatLogGetCurrentEventInfo()))
            end
        else
            callback(arg, timestamp, eventType, hideCaster, sourceGUID, sourceName, 
                sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, 
                select(12, CombatLogGetCurrentEventInfo()))
        end
    end
end

-- Enhanced cooldown tracking using modern C_Spell.GetSpellCooldown API (11.0+)
function AceEvent:GetCachedSpellCooldown(spellID)
    if not C_Spell_GetSpellCooldown then return nil end
    
    local now = GetTime()
    local cache = self.cooldownCache[spellID]
    
    -- Use cached value if still fresh (within 50ms)
    if cache and (now - cache.time < 0.05) then
        return cache.cooldownInfo
    end
    
    -- Get fresh cooldown from API
    local cooldownInfo = C_Spell_GetSpellCooldown(spellID)
    
    if cooldownInfo then
        -- Cache the result
        self.cooldownCache[spellID] = {
            time = now,
            cooldownInfo = cooldownInfo
        }
        return cooldownInfo
    end
    
    return nil
end

-- Enhanced Loss of Control tracking using C_LossOfControl (11.0+)
function AceEvent:GetLossOfControlInfo()
    if not C_LossOfControl_GetActiveLossOfControlData then return nil end
    
    local now = GetTime()
    
    -- Use cached value if still fresh (within 50ms)
    if self.locCacheTime and (now - self.locCacheTime < 0.05) then
        return self.locCache
    end
    
    -- Get fresh LoC data
    local locData = C_LossOfControl_GetActiveLossOfControlData(1)
    
    -- Cache the result
    self.locCache = locData
    self.locCacheTime = now
    
    return locData
end

-- Register with enhanced combat log processing
function AceEvent:RegisterEnhancedCombatLog(callback, arg)
    self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", "EnhancedCombatLogEvent", arg or callback)
    return true
end

-- Get enhanced aura information using latest APIs
function AceEvent:GetEnhancedAuraInfo(unit, auraInstanceID)
    if not C_UnitAuras_GetAuraDataByAuraInstanceID then return nil end
    
    local cacheKey = unit .. "-" .. auraInstanceID
    local now = GetTime()
    local cache = self.auraCache[cacheKey]
    
    -- Use cached value if still fresh (within 50ms)
    if cache and (now - cache.time < 0.05) then
        return cache.auraData
    end
    
    -- Get fresh aura data
    local auraData = C_UnitAuras_GetAuraDataByAuraInstanceID(unit, auraInstanceID)
    
    if auraData then
        -- Cache the result
        self.auraCache[cacheKey] = {
            time = now,
            auraData = auraData
        }
        return auraData
    end
    
    return nil
end

-- Enhanced health tracking with modifier support
function AceEvent:GetEnhancedUnitHealth(unit)
    if not unit then return nil end
    
    local cacheKey = unit
    local now = GetTime()
    local cache = self.healthCache and self.healthCache[cacheKey]
    
    -- Use cached value if still fresh (within 50ms)
    if cache and (now - cache.time < 0.05) then
        return cache.healthData
    end
    
    -- Initialize cache if needed
    if not self.healthCache then
        self.healthCache = {}
    end
    
    local healthData = {
        current = UnitHealth(unit),
        max = UnitHealthMax(unit),
        percent = 0
    }
    
    -- Add health modifier data if available (raid mechanics)
    if GetUnitHealthModifier then
        healthData.modifier = GetUnitHealthModifier(unit)
        healthData.effectiveMax = healthData.max * (healthData.modifier or 1)
        healthData.effectiveCurrent = healthData.current * (healthData.modifier or 1)
    end
    
    -- Calculate percentage
    if healthData.max > 0 then
        healthData.percent = healthData.current / healthData.max * 100
    end
    
    -- Cache the result
    self.healthCache[cacheKey] = {
        time = now,
        healthData = healthData
    }
    
    return healthData
end

-- Enhanced power tracking with all power types
function AceEvent:GetEnhancedUnitPower(unit, powerType)
    if not unit then return nil end
    
    powerType = powerType or UnitPowerType(unit)
    local cacheKey = unit .. "-" .. (powerType or "primary")
    local now = GetTime()
    local cache = self.powerCache and self.powerCache[cacheKey]
    
    -- Use cached value if still fresh (within 50ms)
    if cache and (now - cache.time < 0.05) then
        return cache.powerData
    end
    
    -- Initialize cache if needed
    if not self.powerCache then
        self.powerCache = {}
    end
    
    local powerData = {
        current = UnitPower(unit, powerType),
        max = UnitPowerMax(unit, powerType),
        percent = 0,
        powerType = powerType
    }
    
    -- Calculate percentage
    if powerData.max > 0 then
        powerData.percent = powerData.current / powerData.max * 100
    end
    
    -- Cache the result
    self.powerCache[cacheKey] = {
        time = now,
        powerData = powerData
    }
    
    return powerData
end

-- Event categories with smart optimization
AceEvent.eventCategories = {
    combat = {
        -- Combat events need immediate processing
        events = {
            "COMBAT_LOG_EVENT_UNFILTERED",
            "ENCOUNTER_START", 
            "ENCOUNTER_END",
            "UNIT_SPELLCAST_SUCCEEDED",
            "UNIT_SPELLCAST_START",
            "UNIT_COMBAT"
        },
        priority = "HIGH",
        throttle = nil -- No throttling for combat events
    },
    targeting = {
        -- Target switching is critical for rotations
        events = {
            "PLAYER_TARGET_CHANGED",
            "UNIT_TARGET",
            "TARGET_CHANGED"
        },
        priority = "HIGH", 
        throttle = nil
    },
    spellUpdates = {
        -- Spell updates can be slightly throttled
        events = {
            "SPELL_UPDATE_COOLDOWN",
            "SPELL_UPDATE_CHARGES",
            "SPELL_UPDATE_USABLE"
        },
        priority = "NORMAL",
        throttle = 0.05 -- 50ms throttle is safe for most rotations
    },
    uiUpdates = {
        -- UI can be throttled more aggressively
        events = {
            "PLAYER_EQUIPMENT_CHANGED",
            "PLAYER_TALENT_UPDATE",
            "ACTIONBAR_SLOT_CHANGED",
            "ADDON_LOADED"
        },
        priority = "LOW",
        throttle = 0.1 -- 100ms throttle for UI
    },
    nameplates = {
        -- Nameplate updates happen frequently in combat
        events = {
            "NAME_PLATE_UNIT_ADDED",
            "NAME_PLATE_UNIT_REMOVED",
            "UNIT_THREAT_LIST_UPDATE",
            "UNIT_THREAT_SITUATION_UPDATE"
        },
        priority = "NORMAL",
        throttle = 0.03 -- 30ms throttle for smooth updates
    },
    resources = {
        -- Resource updates for rotations
        events = {
            "UNIT_POWER_UPDATE",
            "UNIT_POWER_FREQUENT",
            "UNIT_HEALTH",
            "UNIT_MANA"
        },
        priority = "HIGH",
        throttle = 0.02 -- Small throttle for resource updates
    }
}

-- Apply category-based optimizations
function AceEvent:OptimizeEventHandling()
    -- Apply category settings to all events
    for category, settings in pairs(self.eventCategories) do
        for _, event in ipairs(settings.events) do
            if settings.priority == "HIGH" then
                self.highPriorityEvents[event] = true
            end
            
            if settings.throttle then
                self.throttledEvents[event] = settings.throttle
            end
        end
    end
end

-- Initialize optimizations based on event types, not specific addons
AceEvent:OptimizeEventHandling()

-- Optimized aura tracking setup using modern 11.0+ APIs
function AceEvent:SetupEnhancedAuraTracking()
    if not C_UnitAuras_GetAuraDataByAuraInstanceID then return end
    
    -- Create specialized frame for UNIT_AURA processing
    if not self.auraFrame then
        self.auraFrame = CreateFrame("Frame")
        self.auraFrame:RegisterEvent("UNIT_AURA")
        self.auraFrame:SetScript("OnEvent", function(_, event, unit, updateInfo)
            -- The War Within enhanced UNIT_AURA with updateInfo parameter
            if updateInfo then
                -- Process added auras 
                if updateInfo.addedAuras then
                    for _, aura in ipairs(updateInfo.addedAuras) do
                        -- Cache the new aura
                        local cacheKey = unit .. "-" .. aura.auraInstanceID
                        self.auraCache[cacheKey] = {
                            time = GetTime(),
                            auraData = aura
                        }
                    end
                end
                
                -- Process updated auras
                if updateInfo.updatedAuraInstanceIDs then
                    for _, auraInstanceID in ipairs(updateInfo.updatedAuraInstanceIDs) do
                        -- Update the cache with fresh data
                        local auraData = C_UnitAuras_GetAuraDataByAuraInstanceID(unit, auraInstanceID)
                        if auraData then
                            local cacheKey = unit .. "-" .. auraInstanceID
                            self.auraCache[cacheKey] = {
                                time = GetTime(),
                                auraData = auraData
                            }
                        end
                    end
                end
                
                -- Clear removed auras from cache
                if updateInfo.removedAuraInstanceIDs then
                    for _, auraInstanceID in ipairs(updateInfo.removedAuraInstanceIDs) do
                        local cacheKey = unit .. "-" .. auraInstanceID
                        self.auraCache[cacheKey] = nil
                    end
                end
                
                -- If full update, clear all auras for this unit
                if updateInfo.isFullUpdate then
                    -- Clear existing cache for this unit
                    for cacheKey in pairs(self.auraCache) do
                        if cacheKey:match("^" .. unit .. "%-") then
                            self.auraCache[cacheKey] = nil
                        end
                    end
                end
            end
            
            -- Fire normal event handlers
            AceEvent.events:Fire(event, unit, updateInfo)
        end)
    end
    
    -- Set up spell cooldown tracking
    if not self.cooldownFrame and C_Spell_GetSpellCooldown then
        self.cooldownFrame = CreateFrame("Frame")
        self.cooldownFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        self.cooldownFrame:SetScript("OnEvent", function()
            -- Clear cooldown cache on cooldown updates
            wipe(self.cooldownCache)
            
            -- Fire normal event handlers
            AceEvent.events:Fire("SPELL_UPDATE_COOLDOWN")
        end)
    end
    
    -- Set up Loss of Control tracking
    if not self.locFrame and C_LossOfControl_GetActiveLossOfControlData then
        self.locFrame = CreateFrame("Frame")
        self.locFrame:RegisterEvent("LOSS_OF_CONTROL_UPDATE")
        self.locFrame:SetScript("OnEvent", function()
            -- Clear LOC cache
            self.locCacheTime = nil
            
            -- Fire normal event handlers
            AceEvent.events:Fire("LOSS_OF_CONTROL_UPDATE")
        end)
    end
    
    -- Set up health and power tracking
    if not self.unitFrame then
        self.unitFrame = CreateFrame("Frame")
        self.unitFrame:RegisterEvent("UNIT_HEALTH")
        self.unitFrame:RegisterEvent("UNIT_MAXHEALTH")
        self.unitFrame:RegisterEvent("UNIT_POWER_UPDATE")
        self.unitFrame:RegisterEvent("UNIT_MAXPOWER")
        self.unitFrame:RegisterEvent("UNIT_POWER_FREQUENT")
        self.unitFrame:RegisterEvent("UNIT_DISPLAYPOWER")
        
        -- Add raid mechanics events if available (commented out for compatibility)
        -- Attempting to register UNIT_HEALTH_MODIFIER_CHANGED causes errors in some WoW versions
        -- if GetUnitHealthModifier then
        --     self.unitFrame:RegisterEvent("UNIT_HEALTH_MODIFIER_CHANGED")
        -- end
        
        self.unitFrame:SetScript("OnEvent", function(_, event, unit)
            -- Clear appropriate cache based on event type
            if event:match("HEALTH") then
                if self.healthCache and unit then
                    self.healthCache[unit] = nil
                end
            elseif event:match("POWER") then
                if self.powerCache and unit then
                    -- Clear all power entries for this unit
                    for cacheKey in pairs(self.powerCache) do
                        if cacheKey:match("^" .. unit .. "%-") then
                            self.powerCache[cacheKey] = nil
                        end
                    end
                end
            end
            
            -- Fire normal event handlers
            AceEvent.events:Fire(event, unit)
        end)
    end
end

-- Set up enhanced tracking with modern APIs
AceEvent:SetupEnhancedAuraTracking()

-- Add new functions to mixins
tinsert(mixins, "RegisterEnhancedCombatLog")
tinsert(mixins, "GetCachedSpellCooldown") 
tinsert(mixins, "GetEnhancedAuraInfo")
tinsert(mixins, "GetLossOfControlInfo")
tinsert(mixins, "GetEnhancedUnitHealth")
tinsert(mixins, "GetEnhancedUnitPower")

-- Return the library table for direct usage
return AceEvent