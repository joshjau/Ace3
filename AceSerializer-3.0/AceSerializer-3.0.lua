--- **AceSerializer-3.0** can serialize any variable (except functions or userdata) into a string format,
-- that can be send over the addon comm channel. AceSerializer was designed to keep all data intact, especially
-- very large numbers or floating point numbers, and table structures. The only caveat currently is, that multiple
-- references to the same table will be send individually.
--
-- **AceSerializer-3.0** can be embeded into your addon, either explicitly by calling AceSerializer:Embed(MyAddon) or by
-- specifying it as an embeded library in your AceAddon. All functions will be available on your addon object
-- and can be accessed directly, without having to explicitly call AceSerializer itself.\\
-- It is recommended to embed AceSerializer, otherwise you'll have to specify a custom `self` on all calls you
-- make into AceSerializer.
-- @class file
-- @name AceSerializer-3.0
-- @release $Id$
local MAJOR,MINOR = "AceSerializer-3.0", 13 -- Increased minor version for the enhanced optimization
local AceSerializer, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceSerializer then return end

-- Lua APIs
local strbyte, strchar, gsub, gmatch, format = string.byte, string.char, string.gsub, string.gmatch, string.format
local assert, error, pcall = assert, error, pcall
local type, tostring, tonumber = type, tostring, tonumber
local pairs, select, frexp = pairs, select, math.frexp
local tconcat, tinsert, tsort = table.concat, table.insert, table.sort
local tremove = table.remove
local rawset, rawget, next = rawset, rawget, next
local floor, ceil, min = math.floor, math.ceil, math.min
-- Proper Lua 5.1 compatible bitwise implementation for WoW
local band = bit and bit.band or function(a, b)
    local result = 0
    local bitval = 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then
            result = result + bitval
        end
        bitval = bitval * 2
        a = floor(a / 2)
        b = floor(b / 2)
    end
    return result
end
-- Define our own unpack function for WoW's Lua 5.1 environment
local unpack = function(t, i, j)
    if not t then return nil end

    i = i or 1
    j = j or #t

    -- Check for valid indices to avoid errors
    if i > j then return nil end

    -- Non-recursive implementation to avoid stack overflow
    if i == j then return t[i] end

    -- For small ranges, use the recursive approach
    if (j - i) < 10 then
        return t[i], unpack(t, i+1, j)
    end

    -- For larger ranges, manually build return values
    local n = j - i + 1
    local values = {}
    for k = 1, n do
        values[k] = t[i + k - 1]
    end

    -- Manually return values (up to 20 - enough for most cases)
    if n == 1 then return values[1]
    elseif n == 2 then return values[1], values[2]
    elseif n == 3 then return values[1], values[2], values[3]
    elseif n == 4 then return values[1], values[2], values[3], values[4]
    elseif n == 5 then return values[1], values[2], values[3], values[4], values[5]
    elseif n > 5 then
        -- For more than 5 values, recursively handle them in chunks
        return values[1], values[2], values[3], values[4], values[5], unpack(values, 6, n)
    end
    return nil
end
local wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end -- WoW has wipe built-in

-- Check for native serialization support
local hasNativeSerialization = false
do
    -- Try to detect if C_Util.Serialize exists
    local success, hasUtil = pcall(function() return C_Util and C_Util.Serialize end)
    if success and hasUtil then
        hasNativeSerialization = true
    end
end

-- Configuration settings for optimization
local config = {
    -- Basic config
    tablePoolMaxSize = 100,
    numberCacheSize = 1024,
    stringCacheSize = 512,

    -- Advanced config
    enableDeterministicMode = false,
    useInternedStrings = true,
    maxInternedStrings = 1000,
    trackTableReferences = true,
    useNativeSerialization = hasNativeSerialization,

    -- Adaptive config based on environment
    adaptiveCacheSize = true,

    -- Combat settings
    inCombat = {
        numberCacheSize = 512,     -- Smaller cache in combat
        tablePoolMaxSize = 50,     -- Conservative table pooling
        aggressiveGC = false       -- Avoid GC during combat
    },
    outOfCombat = {
        numberCacheSize = 2048,    -- Larger cache out of combat
        tablePoolMaxSize = 200,    -- More generous table pooling
        aggressiveGC = true        -- More aggressive cleanup
    }
}

-- Constants for improved performance
local TYPE_NIL = "nil"
local TYPE_STRING = "string"
local TYPE_NUMBER = "number"
local TYPE_TABLE = "table"
local TYPE_BOOLEAN = "boolean"
local TYPE_FUNCTION = "function"
local TYPE_USERDATA = "userdata"

-- Cache for string pattern matches to avoid regex recompilation
local escapeCharCache = {}

-- Interned strings cache for frequently used values
local internedStrings = {}
local internedStringsCount = 0

-- quick copies of string representations of wonky numbers
local inf = math.huge

local serNaN  -- can't do this in 4.3, see ace3 ticket 268
local serInf, serInfMac = "1.#INF", "inf"
local serNegInf, serNegInfMac = "-1.#INF", "-inf"

-- Table recycling pool to reduce garbage collection pressure
local tablePool = {}
local tablePoolSize = 0 -- Keep track of actual pool size

-- Get a table from the pool or create a new one
local function getTable()
    local t = next(tablePool)
    if t then
        tablePool[t] = nil
        tablePoolSize = tablePoolSize - 1
        return t
    else
        return {}
    end
end

-- Release a table back to the pool
local function releaseTable(t)
    if not t then return end
    -- Clear the table
    for k in pairs(t) do t[k] = nil end
    -- Add to pool if we have room
    if tablePoolSize < config.tablePoolMaxSize then
        tablePool[t] = true
        tablePoolSize = tablePoolSize + 1
    end
end

-- Add a string to the interned strings cache
local function internString(str)
    if not config.useInternedStrings then return str end

    if internedStrings[str] then
        return internedStrings[str]
    end

    if internedStringsCount < config.maxInternedStrings then
        internedStrings[str] = str
        internedStringsCount = internedStringsCount + 1
    end

    return str
end

-- Function for deterministic table iteration
local function sortedPairs(t)
    local keys = getTable()
    for k in pairs(t) do
        tinsert(keys, k)
    end

    tsort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then
            -- Sort by type first (nil < boolean < number < string < table)
            if ta == TYPE_NIL then return true end
            if tb == TYPE_NIL then return false end
            if ta == TYPE_BOOLEAN then return true end
            if tb == TYPE_BOOLEAN then return false end
            if ta == TYPE_NUMBER then return true end
            if tb == TYPE_NUMBER then return false end
            if ta == TYPE_STRING then return true end
            if tb == TYPE_STRING then return false end
            return false
        else
            -- Then sort within the same type
            if ta == TYPE_NUMBER or ta == TYPE_STRING then
                return a < b
            elseif ta == TYPE_BOOLEAN then
                return a == false -- false before true
            else
                -- For tables, just use tostring
                return tostring(a) < tostring(b)
            end
        end
    end)

    local i = 0
    return function()
        i = i + 1
        local k = keys[i]
        if k ~= nil then
            return k, t[k]
        end
        releaseTable(keys)
        return nil
    end
end

-- Serialization functions
local SerializeValue -- Forward declaration

local function SerializeStringHelper(ch)	-- Used by SerializeValue for strings
    if escapeCharCache[ch] then
        return escapeCharCache[ch]
    end

    -- We use \126 ("~") as an escape character for all nonprints plus a few more
    local n = strbyte(ch)
    local result
    if n==30 then           -- v3 / ticket 115: catch a nonprint that ends up being "~^" when encoded... DOH
        result = "\126\122"
    elseif n<=32 then 			-- nonprint + space
        result = "\126"..strchar(n+64)
    elseif n==94 then		-- value separator
        result = "\126\125"
    elseif n==126 then		-- our own escape character
        result = "\126\124"
    elseif n==127 then		-- nonprint (DEL)
        result = "\126\123"
    else
        assert(false)	-- can't be reached if caller uses a sane regex
    end

    escapeCharCache[ch] = result
    return result
end

-- Fast lookup tables for type detection
local isType = {
    [TYPE_STRING] = function(v, res, nres, serializedTables, options)
        res[nres+1] = "^S"
        res[nres+2] = gsub(v,"[%c \94\126\127]", SerializeStringHelper)
        return nres+2
    end,

    [TYPE_NUMBER] = function(v, res, nres, serializedTables, options)
        local str = tostring(v)
        if tonumber(str)==v then
            -- translates just fine, transmit as-is
            res[nres+1] = "^N"
            res[nres+2] = str
            return nres+2
        elseif v == inf or v == -inf then
            res[nres+1] = "^N"
            res[nres+2] = v == inf and serInf or serNegInf
            return nres+2
        else
            local m,e = frexp(v)
            res[nres+1] = "^F"
            res[nres+2] = format("%.0f",m*2^53)	-- force mantissa to become integer (it's originally 0.5--0.9999)
            res[nres+3] = "^f"
            res[nres+4] = tostring(e-53)	-- adjust exponent to counteract mantissa manipulation
            return nres+4
        end
    end,

    [TYPE_TABLE] = function(v, res, nres, serializedTables, options)
        -- Check for table serialization loop
        if serializedTables[v] then
            error(MAJOR..": Cannot serialize recursive table references")
        end

        serializedTables[v] = true

        nres=nres+1
        res[nres] = "^T"

        -- If deterministic mode enabled, use sorted pairs
        local iterFunc = (options and options.deterministic) and sortedPairs or pairs

        for key,value in iterFunc(v) do
            nres = SerializeValue(key, res, nres, serializedTables, options)
            nres = SerializeValue(value, res, nres, serializedTables, options)
        end

        nres=nres+1
        res[nres] = "^t"

        serializedTables[v] = nil
        return nres
    end,

    [TYPE_BOOLEAN] = function(v, res, nres, serializedTables, options)
        nres=nres+1
        res[nres] = v and "^B" or "^b"
        return nres
    end,

    [TYPE_NIL] = function(v, res, nres, serializedTables, options)
        nres=nres+1
        res[nres] = "^Z"
        return nres
    end
}

-- Now implement the forward declared function
SerializeValue = function(v, res, nres, serializedTables, options)
    -- We use "^" as a value separator, followed by one byte for type indicator
    local t = type(v)

    local handler = isType[t]
    if handler then
        return handler(v, res, nres, serializedTables, options)
    else
        error(MAJOR..": Cannot serialize a value of type '"..t.."'")	-- can't produce error on right level, this is wildly recursive
    end
end

-- Reusable table for serialization to reduce GC pressure
local serializeTbl = { "^1" }	-- "^1" = Hi, I'm data serialized by AceSerializer protocol rev 1

-- Profiling data
local profiling = nil

--- Serialize the data passed into the function.
-- Takes a list of values (strings, numbers, booleans, nils, tables)
-- and returns it in serialized form (a string).\\
-- May throw errors on invalid data types.
-- @param ... List of values to serialize
-- @return The data in its serialized form (string)
function AceSerializer:Serialize(...)
    -- Try native serialization if available and enabled
    if config.useNativeSerialization and hasNativeSerialization then
        local success, result = pcall(C_Util.Serialize, ...)
        if success then
            return result
        end
        -- Fall back to Lua implementation on failure
    end

    -- Track profiling data if enabled
    if profiling then
        profiling.serializeCalls = profiling.serializeCalls + 1
    end

    local nres = 1
    local serializedTables = getTable() -- Track tables to prevent recursion
    local options = getTable()

    -- Set serialization options
    options.deterministic = config.enableDeterministicMode

    for i=1,select("#", ...) do
        local v = select(i, ...)
        nres = SerializeValue(v, serializeTbl, nres, serializedTables, options)
    end

    serializeTbl[nres+1] = "^^"	-- "^^" = End of serialized data

    local result = tconcat(serializeTbl, "", 1, nres+1)

    -- Track bytes processed for profiling
    if profiling then
        profiling.bytesProcessed = profiling.bytesProcessed + #result
    end

    -- Clean up table for reuse
    for i = nres+1, #serializeTbl do
        serializeTbl[i] = nil
    end

    releaseTable(serializedTables)
    releaseTable(options)
    return result
end

--- Serialize with deterministic output.
-- This ensures that the same input will always produce the same output,
-- making it suitable for checksums and comparing data.
-- @param ... List of values to serialize
-- @return The data in its serialized form (string)
function AceSerializer:SerializeDeterministic(...)
    local prev = config.enableDeterministicMode
    config.enableDeterministicMode = true
    local result = self:Serialize(...)
    config.enableDeterministicMode = prev
    return result
end

-- Deserialization functions

-- Cache for deserialization helpers
local deserializeStringHelperCache = {}

local function DeserializeStringHelper(escape)
    if deserializeStringHelperCache[escape] then
        return deserializeStringHelperCache[escape]
    end

    local result
    if escape<"~\122" then
        result = strchar(strbyte(escape,2,2)-64)
    elseif escape=="~\122" then	-- v3 / ticket 115: special case encode since 30+64=94 ("^") - OOPS.
        result = "\030"
    elseif escape=="~\123" then
        result = "\127"
    elseif escape=="~\124" then
        result = "\126"
    elseif escape=="~\125" then
        result = "\94"
    else
        error("DeserializeStringHelper got called for '"..escape.."'?!?")  -- can't be reached unless regex is screwed up
    end

    deserializeStringHelperCache[escape] = result
    return result
end

-- Cache for number deserialization
local numberCache = {}
local numberCacheSize = 1024
local numberCachePtr = 0

local function DeserializeNumberHelper(number)
    -- Check cache first
    if numberCache[number] ~= nil then
        return numberCache[number]
    end

    local result
    --[[ not in 4.3 if number == serNaN then
        result = 0/0
    else]]if number == serNegInf or number == serNegInfMac then
        result = -inf
    elseif number == serInf or number == serInfMac then
        result = inf
    else
        result = tonumber(number)
    end

    -- Add to circular cache
    numberCachePtr = (numberCachePtr % numberCacheSize) + 1
    local oldNumber = numberCache[numberCachePtr]
    if oldNumber then
        numberCache[oldNumber] = nil
    end
    numberCache[number] = result
    numberCache[numberCachePtr] = number

    return result
end

-- Enhanced string deserialization with interning
local function EnhancedDeserializeString(data)
    local result = gsub(data, "~.", DeserializeStringHelper)
    return internString(result)
end

-- DeserializeValue: worker function for :Deserialize()
-- It works in two modes:
--   Main (top-level) mode: Deserialize a list of values and return them all
--   Recursive (table) mode: Deserialize only a single value (_may_ of course be another table with lots of subvalues in it)
--
-- The function _always_ works recursively due to having to build a list of values to return
--
-- Callers are expected to pcall(DeserializeValue) to trap errors

local function DeserializeValue(iter, single, ctl, data)
    if not single then
        ctl, data = iter()
    end

    if not ctl then
        error("Supplied data misses AceSerializer terminator ('^^')")
    end

    if ctl=="^^" then
        -- ignore extraneous data
        return
    end

    local res

    if ctl=="^S" then
        res = config.useInternedStrings and EnhancedDeserializeString(data) or gsub(data, "~.", DeserializeStringHelper)
    elseif ctl=="^N" then
        res = DeserializeNumberHelper(data)
        if not res then
            error("Invalid serialized number: '"..tostring(data).."'")
        end
    elseif ctl=="^F" then     -- ^F<mantissa>^f<exponent>
        local ctl2, e = iter()
        if ctl2~="^f" then
            error("Invalid serialized floating-point number, expected '^f', not '"..tostring(ctl2).."'")
        end
        local m = tonumber(data)
        e = tonumber(e)
        if not (m and e) then
            error("Invalid serialized floating-point number, expected mantissa and exponent, got '"..tostring(m).."' and '"..tostring(e).."'")
        end
        res = m*(2^e)
    elseif ctl=="^B" then	-- yeah yeah ignore data portion
        res = true
    elseif ctl=="^b" then   -- yeah yeah ignore data portion
        res = false
    elseif ctl=="^Z" then	-- yeah yeah ignore data portion
        res = nil
    elseif ctl=="^T" then
        -- ignore ^T's data, future extensibility?
        res = {}
        local k,v
        while true do
            ctl, data = iter()
            if ctl=="^t" then break end	-- ignore ^t's data
            k = DeserializeValue(iter, true, ctl, data)
            if k==nil then
                error("Invalid AceSerializer table format (no table end marker)")
            end
            ctl, data = iter()
            v = DeserializeValue(iter, true, ctl, data)
            if v==nil then
                error("Invalid AceSerializer table format (no table end marker)")
            end

            -- Set the value only if both key and value are not nil
            if k ~= nil then
                res[k] = v
            end
        end
    else
        error("Invalid AceSerializer control code '"..ctl.."'")
    end

    if not single then
        return res, DeserializeValue(iter)
    else
        return res
    end
end

-- Pre-compile frequently used patterns
local whitespacePattern = "[%c ]"

--- Deserializes the data into its original values.
-- Accepts serialized data, ignoring all control characters and whitespace.
-- @param str The serialized data (from :Serialize)
-- @return true followed by a list of values, OR false followed by an error message
function AceSerializer:Deserialize(str)
    -- Try native deserialization if available
    if config.useNativeSerialization and hasNativeSerialization and C_Util.DeserializeOrdered then
        local success, result = pcall(C_Util.DeserializeOrdered, str)
        if success and result then
            -- Check for nil result before unpacking
            if type(result) == "table" then
                return true, unpack(result)
            end
            return true
        end
        -- Fall back to Lua implementation on failure
    end

    -- Track profiling if enabled
    if profiling then
        profiling.deserializeCalls = profiling.deserializeCalls + 1
        profiling.bytesProcessed = profiling.bytesProcessed + #str
    end

    str = gsub(str, whitespacePattern, "")	-- ignore all control characters; nice for embedding in email and stuff

    local iter = gmatch(str, "(^.)([^^]*)")	-- Any ^x followed by string of non-^
    local ctl, data = iter()
    if not ctl or ctl~="^1" then
        -- we purposefully ignore the data portion of the start code, it can be used as an extension mechanism
        return false, "Supplied data is not AceSerializer data (rev 1)"
    end

    return pcall(DeserializeValue, iter)
end

-- Pre-compile the string patterns for common operations
local stringCacheSize = 512
local stringCache = setmetatable({}, {
    __index = function(t, k)
        if #t > stringCacheSize then
            wipe(t)
        end
        local pattern = "([" .. k .. "])"
        t[k] = pattern
        return pattern
    end
})

-- Combat optimization: avoid intensive operations during combat
local inCombat = false
local pendingCacheClear = false

local function UpdateConfigForCombatState()
    if inCombat then
        numberCacheSize = config.inCombat.numberCacheSize
        config.tablePoolMaxSize = config.inCombat.tablePoolMaxSize
    else
        numberCacheSize = config.outOfCombat.numberCacheSize
        config.tablePoolMaxSize = config.outOfCombat.tablePoolMaxSize
    end
end

local function OnCombatEvent(self, event)
    if not event then return end

    local wasInCombat = inCombat
    local newCombatState = InCombatLockdown()

    -- Protect against nil returns
    inCombat = newCombatState ~= nil and newCombatState or false

    -- If combat state changed, update config
    if wasInCombat ~= inCombat then
        UpdateConfigForCombatState()
    end

    -- If we exited combat and have pending cache clears, do them now
    if not inCombat and pendingCacheClear then
        if escapeCharCache then wipe(escapeCharCache) end
        if deserializeStringHelperCache then wipe(deserializeStringHelperCache) end
        if numberCache then wipe(numberCache) end
        pendingCacheClear = false
    end
end

-- Register for combat events to optimize resource usage
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
combatFrame:SetScript("OnEvent", OnCombatEvent)

-- Pre-cache combat state
inCombat = InCombatLockdown()
UpdateConfigForCombatState()

-- Cache maintenance function (called periodically or when memory pressure is high)
function AceSerializer:ClearCaches()
    if inCombat then
        pendingCacheClear = true
        return
    end

    -- Check sizes and enforce limits before wiping
    if escapeCharCache and next(escapeCharCache) then
        local count = 0
        for _ in pairs(escapeCharCache) do count = count + 1 end
        if count > 1000 then -- Hard limit
            wipe(escapeCharCache)
        end
    end

    if deserializeStringHelperCache and next(deserializeStringHelperCache) then
        local count = 0
        for _ in pairs(deserializeStringHelperCache) do count = count + 1 end
        if count > 1000 then -- Hard limit
            wipe(deserializeStringHelperCache)
        end
    end

    -- Clear number cache if it gets too large
    if numberCache and next(numberCache) then
        if numberCacheSize > 2048 then -- Hard cap at extremely high values
            numberCacheSize = 2048
            wipe(numberCache)
            numberCachePtr = 0
        end
    end

    -- Release some tables back to the system
    local count = 0
    local toRemove = floor(tablePoolSize / 2)
    for t in pairs(tablePool) do
        if count < toRemove then
            tablePool[t] = nil
            count = count + 1
            tablePoolSize = tablePoolSize - 1
        else
            break
        end
    end

    -- Only clear interned strings when memory pressure is high
    if config.useInternedStrings then
        if internedStringsCount > config.maxInternedStrings then
            wipe(internedStrings)
            internedStringsCount = 0
        end
    end

    -- Return success
    return true
end

-- Configure serializer options
function AceSerializer:Configure(options)
    if type(options) ~= "table" then
        error("Usage: Configure(options): 'options' - table expected")
        return false
    end

    -- Validate configuration values
    for k, v in pairs(options) do
        if config[k] ~= nil then
            -- Type checking for common config options
            if k == "tablePoolMaxSize" or k == "numberCacheSize" or k == "stringCacheSize" or k == "maxInternedStrings" then
                if type(v) ~= "number" then
                    error("Configure: '" .. k .. "' must be a number")
                    return false
                end
            elseif k == "enableDeterministicMode" or k == "useInternedStrings" or k == "trackTableReferences" or
                   k == "useNativeSerialization" or k == "adaptiveCacheSize" then
                if type(v) ~= "boolean" then
                    error("Configure: '" .. k .. "' must be a boolean")
                    return false
                end
            end

            config[k] = v
        else
            -- Unknown config key, just warn
            if geterrorhandler then  -- WoW specific
                local errorHandler = geterrorhandler()
                errorHandler("AceSerializer: Unknown configuration option: " .. k)
            end
        end
    end

    -- Update derived settings
    UpdateConfigForCombatState()
    return true
end

-- Profiling functions
function AceSerializer:StartProfiling(label)
    -- Make sure we have debugprofilestop available
    if not debugprofilestop then
        return false, "debugprofilestop function not available"
    end

    profiling = {
        label = label or "AceSerializer",
        startTime = debugprofilestop(),
        serializeCalls = 0,
        deserializeCalls = 0,
        bytesProcessed = 0
    }
    return true
end

function AceSerializer:StopProfiling()
    if not profiling then return nil end
    if not debugprofilestop then
        profiling = nil
        return nil, "debugprofilestop function not available"
    end

    local result = profiling
    result.endTime = debugprofilestop()
    result.totalTime = result.endTime - result.startTime

    profiling = nil
    return true, result
end

-- Data pattern registration (for optimization hints)
local patterns = {}

function AceSerializer:RegisterFrequentPattern(name, sampleValue)
    if not name or type(name) ~= "string" then
        return false, "Pattern name must be a string"
    end

    -- Serialize the sample to pre-warm caches
    self:Serialize(sampleValue)

    patterns[name] = true
    return true
end

-- Async serialization queue for intensive operations during combat
local serializationQueue = {}
local isProcessingQueue = false
local queueProcessorFrame = nil -- Persistent frame for queue processing

local function ProcessSerializationQueue()
    if isProcessingQueue or #serializationQueue == 0 then return end
    isProcessingQueue = true

    -- Process a small batch of items (up to 5) per frame
    local processCount = min(5, #serializationQueue)
    for i = 1, processCount do
        local item = tremove(serializationQueue, 1)
        if item then
            local success, serialized = pcall(AceSerializer.Serialize, AceSerializer, unpack(item.data))
            if success then
                item.callback(serialized)
            else
                -- If serialization fails, provide an error message
                item.callback(nil, "Serialization error: " .. (serialized or "unknown error"))
            end
        end
    end

    isProcessingQueue = false
    if #serializationQueue > 0 then
        -- Use C_Timer.After when available, otherwise fallback to next frame via OnUpdate
        if C_Timer and C_Timer.After then
            C_Timer.After(0.001, ProcessSerializationQueue)
        else
            -- Fallback for when C_Timer is not available
            if not queueProcessorFrame then
                queueProcessorFrame = CreateFrame("Frame")
            end
            queueProcessorFrame:SetScript("OnUpdate", function(self)
                self:SetScript("OnUpdate", nil)
                ProcessSerializationQueue()
            end)
        end
    end
end

function AceSerializer:SerializeAsync(callback, ...)
    if not callback or type(callback) ~= "function" then
        error("Usage: SerializeAsync(callback, ...): 'callback' - function was expected")
        return false
    end

    if inCombat and #serializationQueue < 100 then
        -- Queue during combat
        tinsert(serializationQueue, {callback = callback, data = {...}})
        ProcessSerializationQueue()
        return true
    else
        -- Direct serialization when not in combat
        local success, result = pcall(self.Serialize, self, ...)
        if success then
            callback(result)
        else
            callback(nil, "Serialization error: " .. (result or "unknown error"))
        end
        return success
    end
end

----------------------------------------
-- Base library stuff
----------------------------------------

AceSerializer.internals = {	-- for test scripts
    SerializeValue = SerializeValue,
    SerializeStringHelper = SerializeStringHelper,
    tablePool = tablePool,
    escapeCharCache = escapeCharCache,
    deserializeStringHelperCache = deserializeStringHelperCache,
    numberCache = numberCache,
    config = config
}

local mixins = {
    "Serialize",
    "SerializeDeterministic",
    "Deserialize",
    "ClearCaches",
    "Configure",
    "StartProfiling",
    "StopProfiling",
    "RegisterFrequentPattern",
    "SerializeAsync"
}

AceSerializer.embeds = AceSerializer.embeds or {}

function AceSerializer:Embed(target)
    for k, v in pairs(mixins) do
        target[v] = self[v]
    end
    self.embeds[target] = true
    return target
end

-- Update embeds
for target, v in pairs(AceSerializer.embeds) do
    AceSerializer:Embed(target)
end

-- Clear caches when memory gets low
local function OnLowMemory()
    if not AceSerializer then return end -- Safety check

    AceSerializer:ClearCaches()

    -- Aggressively clean table pool
    if tablePool then wipe(tablePool) end
    tablePoolSize = 0

    -- Force garbage collection
    collectgarbage("collect")
end

local lowMemoryFrame = CreateFrame("Frame")
lowMemoryFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
lowMemoryFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
lowMemoryFrame:RegisterEvent("LOADING_SCREEN_DISABLED")
lowMemoryFrame:RegisterEvent("ENCOUNTER_START")
lowMemoryFrame:RegisterEvent("ENCOUNTER_END")
lowMemoryFrame:RegisterEvent("CHALLENGE_MODE_START")
lowMemoryFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")

lowMemoryFrame:SetScript("OnEvent", function(self, event, ...)
    if not event then return end

    if event == "PLAYER_LEAVING_WORLD" then
        OnLowMemory()
    elseif event == "LOADING_SCREEN_DISABLED" then
        -- Clear caches after loading screen
        if AceSerializer then AceSerializer:ClearCaches() end
    elseif event == "ENCOUNTER_START" then
        -- Prepare for intensive combat
        inCombat = true
        UpdateConfigForCombatState()
    elseif event == "ENCOUNTER_END" then
        -- Return to normal operation after a short delay
        inCombat = InCombatLockdown() or false
        UpdateConfigForCombatState()

        -- Delayed cache refresh
        if C_Timer and C_Timer.After then
            local function safeRefresh()
                if AceSerializer then
                    AceSerializer:ClearCaches()
                end
            end
            C_Timer.After(2, safeRefresh)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        inCombat = InCombatLockdown() or false
        UpdateConfigForCombatState()
    elseif event == "CHALLENGE_MODE_START" then
        -- Optimize for high performance during M+
        inCombat = true
        UpdateConfigForCombatState()
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        -- Clean up after M+ is done
        inCombat = InCombatLockdown() or false
        UpdateConfigForCombatState()

        if C_Timer and C_Timer.After then
            local function safeRefresh()
                if AceSerializer then
                    AceSerializer:ClearCaches()
                end
            end
            C_Timer.After(2, safeRefresh)
        end
    end
end)
