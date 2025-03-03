--- **AceLocale-3.0** manages localization in addons, allowing for multiple locale to be registered with fallback to the base locale for untranslated strings.
-- @class file
-- @name AceLocale-3.0
-- @release $Id$
local MAJOR,MINOR = "AceLocale-3.0", 7

local AceLocale, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceLocale then return end -- no upgrade needed

-- Lua APIs
local assert, tostring, error = assert, tostring, error
local getmetatable, setmetatable, rawset, rawget = getmetatable, setmetatable, rawset, rawget
local type, pairs, select = type, pairs, select
local format, gsub, concat = string.format, string.gsub, table.concat
local next = next

-- WoW APIs
local GetLocale = GetLocale

-- Initialize game locale
local gameLocale = GetLocale()
if gameLocale == "enGB" then
	gameLocale = "enUS"
end

-- String pool for common operations
local STRING_POOL = {
	MISSING_ENTRY = ": Missing entry for '",
	USAGE_ERROR = "Usage: GetLocale(application[, silent]): 'application' - No locales registered for '",
	SILENT_ERROR = "Usage: NewLocale(application, locale[, isDefault[, silent]]): 'silent' must be specified for the first locale registered",
}

-- Efficient string concatenation helper
local function fastconcat(...)
	return concat({...}, "")
end

AceLocale.apps = AceLocale.apps or {}          -- array of ["AppName"]=localetableref
AceLocale.appnames = AceLocale.appnames or {}  -- array of [localetableref]="AppName"

-- Cache for error handler to avoid repeated lookups
local geterrorhandler = geterrorhandler
local errorhandler = geterrorhandler()

-- Optimized error message generation
local function generateErrorMessage(self, key)
	return fastconcat(MAJOR, ": ", tostring(AceLocale.appnames[self]), STRING_POOL.MISSING_ENTRY, tostring(key), "'")
end

-- This metatable is used on all tables returned from GetLocale
local readmeta = {
	__index = function(self, key) -- requesting totally unknown entries: fire off a nonbreaking error and return key
		if key == nil then return nil end
		rawset(self, key, key)      -- only need to see the warning once, really
		errorhandler(generateErrorMessage(self, key))
		return key
	end
}

-- This metatable is used on all tables returned from GetLocale if the silent flag is true
local readmetasilent = {
	__index = function(self, key) -- requesting totally unknown entries: return key
		if key == nil then return nil end
		rawset(self, key, key)      -- only need to invoke this function once
		return key
	end
}

-- Remember the locale table being registered right now (it gets set by :NewLocale())
-- NOTE: Do never try to register 2 locale tables at once and mix their definition.
local registering

-- local assert false function
local assertfalse = function() assert(false) end

-- Optimized write proxy for non-default locales
local writeproxy = setmetatable({}, {
	__newindex = function(self, key, value)
		if key == nil then return end
		rawset(registering, key, value == true and key or value)
	end,
	__index = assertfalse
})

-- Optimized write proxy for default locale
local writedefaultproxy = setmetatable({}, {
	__newindex = function(self, key, value)
		if key == nil then return end
		if not rawget(registering, key) then
			rawset(registering, key, value == true and key or value)
		end
	end,
	__index = assertfalse
})

-- Pre-allocated tables for common operations
local EMPTY_TABLE = {}
local DEFAULT_TABLE_SIZE = 128  -- Typical size for most locale tables

-- Table pool for reuse
local tablePool = setmetatable({}, {__mode = "k"})  -- Weak keys for GC

-- Get a clean table from pool or create new
local function acquireTable()
	local tbl = next(tablePool)
	if tbl then
		tablePool[tbl] = nil
		return tbl
	end
	return {}, DEFAULT_TABLE_SIZE
end

-- Release table back to pool
local function releaseTable(tbl)
	if type(tbl) == "table" then
		for k in pairs(tbl) do
			tbl[k] = nil
		end
		tablePool[tbl] = true
	end
end

--- Register a new locale (or extend an existing one) for the specified application.
-- :NewLocale will return a table you can fill your locale into, or nil if the locale isn't needed for the players
-- game locale.
-- @paramsig application, locale[, isDefault[, silent]]
-- @param application Unique name of addon / module
-- @param locale Name of the locale to register, e.g. "enUS", "deDE", etc.
-- @param isDefault If this is the default locale being registered (your addon is written in this language, generally enUS)
-- @param silent If true, the locale will not issue warnings for missing keys. Must be set on the first locale registered. If set to "raw", nils will be returned for unknown keys (no metatable used).
-- @usage
-- -- enUS.lua
-- local L = LibStub("AceLocale-3.0"):NewLocale("TestLocale", "enUS", true)
-- L["string1"] = true
--
-- -- deDE.lua
-- local L = LibStub("AceLocale-3.0"):NewLocale("TestLocale", "deDE")
-- if not L then return end
-- L["string1"] = "Zeichenkette1"
-- @return Locale Table to add localizations to, or nil if the current locale is not required.
function AceLocale:NewLocale(application, locale, isDefault, silent)
	-- GAME_LOCALE allows translators to test translations of addons without having that wow client installed
	local activeGameLocale = GAME_LOCALE or gameLocale

	local app = AceLocale.apps[application]

	if silent and app and getmetatable(app) ~= readmetasilent then
		geterrorhandler()(STRING_POOL.SILENT_ERROR)
	end

	if not app then
		if silent=="raw" then
			app = acquireTable()
		else
			app = setmetatable(acquireTable(), silent and readmetasilent or readmeta)
		end
		AceLocale.apps[application] = app
		AceLocale.appnames[app] = application
	end

	if locale ~= activeGameLocale and not isDefault then
		return -- nop, we don't need these translations
	end

	registering = app -- remember globally for writeproxy and writedefaultproxy

	if isDefault then
		return writedefaultproxy
	end

	return writeproxy
end

--- Returns localizations for the current locale (or default locale if translations are missing).
-- Errors if nothing is registered (spank developer, not just a missing translation)
-- @param application Unique name of addon / module
-- @param silent If true, the locale is optional, silently return nil if it's not found (defaults to false, optional)
-- @return The locale table for the current language.
function AceLocale:GetLocale(application, silent)
	if not silent and not AceLocale.apps[application] then
		error(fastconcat(STRING_POOL.USAGE_ERROR, tostring(application), "'"), 2)
	end
	return AceLocale.apps[application]
end
