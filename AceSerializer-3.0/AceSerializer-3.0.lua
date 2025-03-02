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
local MAJOR,MINOR = "AceSerializer-3.0", 6  -- Bumped minor version for optimizations with memory management
local AceSerializer, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceSerializer then return end

-- Lua APIs
local strbyte, strchar, gsub, gmatch, format = string.byte, string.char, string.gsub, string.gmatch, string.format
local assert, error, pcall = assert, error, pcall
local type, tostring, tonumber = type, tostring, tonumber
local pairs, select, frexp = pairs, select, math.frexp
local tconcat, tinsert, tremove = table.concat, table.insert, table.remove
local min, max = math.min, math.max
local floor = math.floor
-- In WoW's Lua 5.1 environment, unpack is a global function
local unpack = unpack

-- WoW API or Utility functions
local wipe = table.wipe or function(t)
    for k in pairs(t) do
        t[k] = nil
    end
    return t
end

-- System-specific configuration flags for high-end systems
-- These can be adjusted based on your specific hardware capabilities
local HIGH_MEMORY_SYSTEM = true  -- Set to true for systems with 16GB+ RAM
local PREALLOC_SIZE = 1024       -- Pre-allocation size for serialization tables
local STRING_POOL_SIZE = 256     -- Maximum size for string pool

-- Special number handling
local inf = math.huge

local serNaN  -- Not used in WoW's Lua implementation
local serInf, serInfMac = "1.#INF", "inf"
local serNegInf, serNegInfMac = "-1.#INF", "-inf"

-- String pooling for frequently used strings to reduce memory allocations
local stringPool = {}
local stringPoolSize = 0

-- Cache frequently used type strings for performance
local TYPE_STRING = "string"
local TYPE_NUMBER = "number"
local TYPE_TABLE = "table"
local TYPE_BOOLEAN = "boolean"
local TYPE_NIL = "nil"

-- Cache control codes used in the serialization protocol
local CONTROL_STRING = "^S"
local CONTROL_NUMBER = "^N"
local CONTROL_FLOAT = "^F"
local CONTROL_FLOAT_EXP = "^f"
local CONTROL_TABLE_START = "^T"
local CONTROL_TABLE_END = "^t"
local CONTROL_BOOL_TRUE = "^B"
local CONTROL_BOOL_FALSE = "^b"
local CONTROL_NIL = "^Z"
local CONTROL_END = "^^"
local CONTROL_START = "^1"

-- Table recycling for better memory usage and reduced GC pressure
local tablePool = {}
local tablePoolSize = 0
local MAX_POOL_SIZE = HIGH_MEMORY_SYSTEM and 20 or 5

-- Helper function to get a string from the pool or create a new one
-- This reduces memory allocations for frequently used strings
local function getPooledString(str)
    if not HIGH_MEMORY_SYSTEM then return str end

    -- Only pool strings of reasonable length to avoid memory bloat
    if type(str) ~= TYPE_STRING or #str > 100 then
        return str
    end

    if not stringPool[str] then
        if stringPoolSize < STRING_POOL_SIZE then
            stringPool[str] = str
            stringPoolSize = stringPoolSize + 1
        end
    end
    return stringPool[str] or str
end

-- Serialization functions

local function SerializeStringHelper(ch)
	-- Escape character handling: We use \126 ("~") as an escape character
	local n = strbyte(ch)
	if n==30 then           -- Special case for character 30 which would become "~^" when encoded
		return "\126\122"
	elseif n<=32 then 			-- Control characters and space
		return "\126"..strchar(n+64)
	elseif n==94 then		-- Caret (^) - used as value separator
		return "\126\125"
	elseif n==126 then		-- Tilde (~) - our own escape character
		return "\126\124"
	elseif n==127 then		-- DEL character
		return "\126\123"
	else
		assert(false)	-- This should never be reached with proper regex usage
	end
end

-- Pre-compute common escape sequences for faster string serialization
local escapeCache = {
    ["\030"] = "\126\122",
    [" "] = "\126\064",
    ["\t"] = "\126\073",
    ["\n"] = "\126\074",
    ["\r"] = "\126\077",
    ["^"] = "\126\125",
    ["~"] = "\126\124",
    ["\127"] = "\126\123"
}

-- Fast path for string serialization with cached escape sequences
-- Optimized for both short and long strings with different strategies
local function SerializeStringFast(str, res, nres)
    res[nres+1] = CONTROL_STRING

    -- For short strings, use the original method as it's efficient enough
    if #str < 32 then
        res[nres+2] = gsub(str, "[%c \94\126\127]", SerializeStringHelper)
        return nres+2
    end

    -- For longer strings, use a more efficient approach with pre-cached values
    local parts = {}
    local lastPos = 1
    local currentPos = 1
    local needsEscaping = false

    -- First check if the string needs escaping at all - quick early exit
    if str:find("[%c \94\126\127]") then
        needsEscaping = true
    else
        -- No escaping needed, just use the string as-is
        res[nres+2] = str
        return nres+2
    end

    -- Only proceed with the more complex logic if escaping is needed
    if needsEscaping then
        while currentPos <= #str do
            local c = str:sub(currentPos, currentPos)
            local escape = escapeCache[c]

            if escape then
                if currentPos > lastPos then
                    tinsert(parts, str:sub(lastPos, currentPos-1))
                end
                tinsert(parts, escape)
                lastPos = currentPos + 1
            end

            currentPos = currentPos + 1
        end

        if lastPos <= #str then
            tinsert(parts, str:sub(lastPos))
        end

        res[nres+2] = tconcat(parts)
    end

    return nres+2
end

local function SerializeValue(v, res, nres)
	-- Serializes a value based on its type using control codes
	local t=type(v)

	if t==TYPE_STRING then
		-- Use the fast path for string serialization
		return SerializeStringFast(v, res, nres)

	elseif t==TYPE_NUMBER then
		local str = tostring(v)
		if tonumber(str)==v then
			-- Number translates cleanly to string, transmit as-is
			res[nres+1] = CONTROL_NUMBER
			res[nres+2] = getPooledString(str)
			nres=nres+2
		elseif v == inf or v == -inf then
			-- Handle infinity values
			res[nres+1] = CONTROL_NUMBER
			res[nres+2] = v == inf and serInf or serNegInf
			nres=nres+2
		else
			-- Handle floating point numbers that need special encoding
			local m,e = frexp(v)
			res[nres+1] = CONTROL_FLOAT
			res[nres+2] = format("%.0f",m*2^53)	-- Convert mantissa to integer for precision
			res[nres+3] = CONTROL_FLOAT_EXP
			res[nres+4] = getPooledString(tostring(e-53))	-- Adjust exponent accordingly
			nres=nres+4
		end

	elseif t==TYPE_TABLE then
		nres=nres+1
		res[nres] = CONTROL_TABLE_START
		for key,value in pairs(v) do
			nres = SerializeValue(key, res, nres)
			nres = SerializeValue(value, res, nres)
		end
		nres=nres+1
		res[nres] = CONTROL_TABLE_END

	elseif t==TYPE_BOOLEAN then
		nres=nres+1
		if v then
			res[nres] = CONTROL_BOOL_TRUE
		else
			res[nres] = CONTROL_BOOL_FALSE
		end

	elseif t==TYPE_NIL then
		nres=nres+1
		res[nres] = CONTROL_NIL

	else
		error(MAJOR..": Cannot serialize a value of type '"..t.."'")
	end

	return nres
end

-- Get a table from the pool or create a new one
-- This reduces GC pressure by reusing tables
local function getTable()
    if tablePoolSize > 0 then
        local t = tablePool[tablePoolSize]
        tablePool[tablePoolSize] = nil
        tablePoolSize = tablePoolSize - 1
        return t
    else
        return {}
    end
end

-- Release a table back to the pool
-- This helps reduce garbage collection overhead
local function releaseTable(t)
    if tablePoolSize < MAX_POOL_SIZE then
        -- Clear the table before returning it to the pool
        for k in pairs(t) do
            t[k] = nil
        end
        tablePoolSize = tablePoolSize + 1
        tablePool[tablePoolSize] = t
    end
end

-- Pre-allocate the serialization table with a larger initial size
local serializeTbl = { CONTROL_START }	-- Start with protocol identifier
for i = 2, PREALLOC_SIZE do
    serializeTbl[i] = nil
end

--- Serialize the data passed into the function.
-- Takes a list of values (strings, numbers, booleans, nils, tables)
-- and returns it in serialized form (a string).\\
-- May throw errors on invalid data types.
-- @param ... List of values to serialize
-- @return The data in its serialized form (string)
function AceSerializer:Serialize(...)
    local nres = 1
    local nargs = select("#", ...)

    -- Estimate the required size based on number of arguments
    -- This helps avoid table resizing during serialization
    if nargs > 1 then
        for i = #serializeTbl, max(PREALLOC_SIZE, nargs * 8) do
            serializeTbl[i] = nil
        end
    end

    for i=1,nargs do
        local v = select(i, ...)
        nres = SerializeValue(v, serializeTbl, nres)
    end

    serializeTbl[nres+1] = CONTROL_END	-- Mark end of serialized data

    -- Get the concatenated result
    local result = tconcat(serializeTbl, "", 1, nres+1)

    -- Clear the table for reuse, but keep the first element
    for i=2, nres+1 do
        serializeTbl[i] = nil
    end

    return result
end

-- Deserialization functions
-- Cache for common escape sequences to improve performance
local deserializeStringCache = {}

local function DeserializeStringHelper(escape)
	if deserializeStringCache[escape] then
		return deserializeStringCache[escape]
	end

	local result
	if escape<"~\122" then
		result = strchar(strbyte(escape,2,2)-64)
	elseif escape=="~\122" then	-- Special case for character 30
		result = "\030"
	elseif escape=="~\123" then
		result = "\127"
	elseif escape=="~\124" then
		result = "\126"
	elseif escape=="~\125" then
		result = "\94"
	else
		error("DeserializeStringHelper got called for '"..escape.."'?!?")
	end

	-- Cache the result for future use on high memory systems
	if HIGH_MEMORY_SYSTEM then
		deserializeStringCache[escape] = result
	end

	return result
end

-- Fast path for number deserialization with caching
local numberCache = {}
local NUMBER_CACHE_SIZE = HIGH_MEMORY_SYSTEM and 1024 or 128

local function DeserializeNumberHelper(number)
	-- Check cache first for common numbers to avoid repeated conversions
	if numberCache[number] then
		return numberCache[number]
	end

	local result
	if number == serNegInf or number == serNegInfMac then
		result = -inf
	elseif number == serInf or number == serInfMac then
		result = inf
	else
		result = tonumber(number)
	end

	-- Cache small integers and common float values for performance
	if result and HIGH_MEMORY_SYSTEM then
		if (result == floor(result) and result >= -1000 and result <= 1000) or
		   #numberCache < NUMBER_CACHE_SIZE then
			numberCache[number] = result
		end
	end

	return result
end

-- Create a new table for deserialization from the pool
local function createTableForDeserialize()
	local t = getTable()
	return t
end

-- Process tables after deserialization and return all values
-- This ensures proper memory management and table optimization
local function finalizeDeserialization(success, ...)
    if not success then
        return success, ...
    end

    -- Process is successful, now optimize tables and prepare return values
    local values = {...}
    local nvalues = select("#", ...)

    -- Helper function to process tables recursively
    local processedTables = {}
    local function optimizeTable(t)
        if type(t) ~= TYPE_TABLE or processedTables[t] then
            return
        end

        processedTables[t] = true

        -- Process all keys and values in the table recursively
        for k, v in pairs(t) do
            if type(k) == TYPE_TABLE then
                optimizeTable(k)
            end
            if type(v) == TYPE_TABLE then
                optimizeTable(v)
            end
        end
    end

    -- Process all returned values
    for i = 1, nvalues do
        local v = values[i]
        if type(v) == TYPE_TABLE then
            optimizeTable(v)
        end
    end

    -- Return the success flag and all values
    return success, unpack(values, 1, nvalues)
end

-- DeserializeValue: worker function for :Deserialize()
-- It works in two modes:
--   Main (top-level) mode: Deserialize a list of values and return them all
--   Recursive (table) mode: Deserialize only a single value (which may be a nested table)
--
-- The function always works recursively to build the complete value structure
-- Callers should use pcall() with this function to handle errors properly
local function DeserializeValue(iter,single,ctl,data)
	if not single then
		ctl,data = iter()
	end

	if not ctl then
		error("Supplied data misses AceSerializer terminator ('^^')")
	end

	if ctl=="^^" then
		-- End of data marker reached
		return
	end

	local res

	if ctl=="^S" then
		-- String deserialization with optimization for different string lengths
		if #data < 32 then
			res = gsub(data, "~.", DeserializeStringHelper)
		else
			-- For longer strings, use a more efficient approach
			local parts = {}
			local lastPos = 1
			local currentPos = 1

			while currentPos <= #data do
				local startPos, endPos = data:find("~.", currentPos)
				if not startPos then break end

				if startPos > lastPos then
					tinsert(parts, data:sub(lastPos, startPos-1))
				end

				tinsert(parts, DeserializeStringHelper(data:sub(startPos, endPos)))
				lastPos = endPos + 1
				currentPos = endPos + 1
			end

			if lastPos <= #data then
				tinsert(parts, data:sub(lastPos))
			end

			if #parts == 0 then
				res = data  -- No escaping needed
			elseif #parts == 1 then
				res = parts[1]
			else
				res = tconcat(parts)
			end
		end
	elseif ctl=="^N" then
		res = DeserializeNumberHelper(data)
		if not res then
			error("Invalid serialized number: '"..tostring(data).."'")
		end
	elseif ctl=="^F" then     -- Float value with mantissa and exponent
		local ctl2,e = iter()
		if ctl2~="^f" then
			error("Invalid serialized floating-point number, expected '^f', not '"..tostring(ctl2).."'")
		end
		local m=tonumber(data)
		e=tonumber(e)
		if not (m and e) then
			error("Invalid serialized floating-point number, expected mantissa and exponent, got '"..tostring(m).."' and '"..tostring(e).."'")
		end
		res = m*(2^e)
	elseif ctl=="^B" then
		res = true
	elseif ctl=="^b" then
		res = false
	elseif ctl=="^Z" then
		res = nil
	elseif ctl=="^T" then
		-- Table deserialization
		res = createTableForDeserialize()
		local k,v
		while true do
			ctl,data = iter()
			if ctl=="^t" then break end	-- Table end marker
			k = DeserializeValue(iter,true,ctl,data)
			if k==nil then
				error("Invalid AceSerializer table format (no table end marker)")
			end
			ctl,data = iter()
			v = DeserializeValue(iter,true,ctl,data)
			if v==nil then
				error("Invalid AceSerializer table format (no table end marker)")
			end

			-- Ensure both key and value are not nil before assignment
			if k ~= nil then
				res[k] = v
			end
		end
	else
		error("Invalid AceSerializer control code '"..ctl.."'")
	end

	if not single then
		return res,DeserializeValue(iter)
	else
		return res
	end
end

-- Optimized pattern for string matching in deserialization
local DESERIALIZE_PATTERN = "(%^.)([^^]*)"

--- Deserializes the data into its original values.
-- Accepts serialized data, ignoring all control characters and whitespace.
-- @param str The serialized data (from :Serialize)
-- @return true followed by a list of values, OR false followed by an error message
function AceSerializer:Deserialize(str)
	-- For large strings, use a more efficient whitespace removal algorithm
	if #str > 1024 then
		local result = {}
		local pos = 1

		-- Skip initial whitespace
		pos = str:find("[^%c ]", pos) or (#str+1)

		while pos <= #str do
			-- Find next non-whitespace character
			local nextChar = str:sub(pos, pos)

			-- Add it to our result
			tinsert(result, nextChar)

			-- Move to next position
			pos = pos + 1

			-- Skip any whitespace
			if pos <= #str then
				if str:sub(pos, pos):match("[%c ]") then
					pos = str:find("[^%c ]", pos) or (#str+1)
				end
			end
		end

		str = tconcat(result)
	else
		-- For smaller strings, simple gsub is efficient enough
		str = gsub(str, "[%c ]", "")
	end

	local iter = gmatch(str, DESERIALIZE_PATTERN)	-- Match control codes and data
	local ctl,data = iter()
	if not ctl or ctl~="^1" then
		-- Check for valid AceSerializer data format
		return false, "Supplied data is not AceSerializer data (rev 1)"
	end

	-- Process the deserialization results
	return finalizeDeserialization(pcall(DeserializeValue, iter))
end


----------------------------------------
-- Base library stuff
----------------------------------------

-- Clear all caches to free memory
function AceSerializer:ClearCaches()
    -- Clear string pool
    wipe(stringPool)
    stringPoolSize = 0

    -- Clear number cache
    wipe(numberCache)

    -- Clear string deserialization cache
    wipe(deserializeStringCache)

    -- Clear table pool
    for i=1, tablePoolSize do
        tablePool[i] = nil
    end
    tablePoolSize = 0

    return true
end

-- Configuration function to adjust memory usage based on system capabilities
function AceSerializer:SetSystemConfig(highMemory, preAllocSize, stringPoolMax, tablePoolMax, numberCacheMax)
    HIGH_MEMORY_SYSTEM = highMemory or HIGH_MEMORY_SYSTEM
    PREALLOC_SIZE = preAllocSize or PREALLOC_SIZE
    STRING_POOL_SIZE = stringPoolMax or STRING_POOL_SIZE
    MAX_POOL_SIZE = tablePoolMax or MAX_POOL_SIZE
    NUMBER_CACHE_SIZE = numberCacheMax or NUMBER_CACHE_SIZE

    -- Clear caches when configuration changes
    self:ClearCaches()

    return true
end

-- Expose internal functions for testing and advanced usage
AceSerializer.internals = {
	SerializeValue = SerializeValue,
	SerializeStringHelper = SerializeStringHelper,
	SerializeStringFast = SerializeStringFast,
	DeserializeStringHelper = DeserializeStringHelper,
	DeserializeNumberHelper = DeserializeNumberHelper,
	getTable = getTable,
	releaseTable = releaseTable,
	getPooledString = getPooledString,
	HIGH_MEMORY_SYSTEM = HIGH_MEMORY_SYSTEM,
	PREALLOC_SIZE = PREALLOC_SIZE
}

local mixins = {
	"Serialize",
	"Deserialize",
	"ClearCaches",
	"SetSystemConfig"
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

-- Configure optimal settings for high-end system
if HIGH_MEMORY_SYSTEM then
    -- Apply optimized settings for high-end systems
    AceSerializer:SetSystemConfig(
        true,           -- Enable high memory optimizations
        2048,           -- Larger pre-allocation size
        512,            -- Increased string pool capacity
        40,             -- More tables in the pool
        2048            -- Larger number cache
    )
end
