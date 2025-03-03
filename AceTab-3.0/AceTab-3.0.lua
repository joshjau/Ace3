--- AceTab-3.0 provides support for tab-completion.
-- Note: This library is not yet finalized.
-- @class file
-- @name AceTab-3.0
-- @release $Id$

local ACETAB_MAJOR, ACETAB_MINOR = 'AceTab-3.0', 10
local AceTab, oldminor = LibStub:NewLibrary(ACETAB_MAJOR, ACETAB_MINOR)

if not AceTab then return end -- No upgrade needed

AceTab.registry = AceTab.registry or {}

-- local upvalues for Lua functions (reduces global lookups)
local _G = _G
local pairs = pairs
local ipairs = ipairs
local type = type
local next = next
local select = select
local tonumber = tonumber
local tostring = tostring
local wipe = table.wipe or wipe -- Support both WoW's global wipe and table.wipe
local tinsert = table.insert
local tremove = table.remove
local min = math.min
local max = math.max

-- Local references to string functions (heavily used)
local strfind = string.find
local strsub = string.sub
local strlower = string.lower
local strformat = string.format
local strmatch = string.match
local strlen = string.len
local strgsub = string.gsub

-- Local references to WoW API functions
local ChatEdit_GetActiveWindow = ChatEdit_GetActiveWindow
local ChatEdit_CustomTabPressed = ChatEdit_CustomTabPressed
local IsSecureCmd = IsSecureCmd
local GetTime = GetTime
local NUM_CHAT_WINDOWS = NUM_CHAT_WINDOWS

-- Local reference to the registry for faster access
local registry = AceTab.registry

-- Pre-allocate reusable tables to reduce garbage collection
local fallbacks, notfallbacks = {}, {}  -- classifies completions into those which have preconditions and those which do not
local pmolengths = {}  -- holds the number of characters to overwrite according to pmoverwrite and the current prematch
local candUsage = {}   -- reusable table for usage function
local stringCache = {} -- cache for frequently used strings
local hookedFrames = {} -- track which frames have been hooked
local frameData = {}   -- store frame-specific data instead of attaching to frames directly

-- Local variables for state tracking (reduces table creation/destruction)
local cursor, cMatch, matched, postmatch
local firstMatch, hasNonFallback, allGCBS, setGCBS, usage
local text_precursor, text_all, text_pmendToCursor
local pms, pme, pmt, prematchStart, prematchEnd, text_prematch, entry
local previousLength

-- String pooling mechanism to reduce memory usage and garbage collection
local stringPool = setmetatable({}, {__mode = "k"})  -- weak keys to allow garbage collection when strings are no longer used
local stringPoolSize = 0

-- Get a string from the pool or create a new one
local function getPooledString(str)
	if not str then return nil end

	if not stringPool[str] then
		stringPool[str] = str
		stringPoolSize = stringPoolSize + 1

		-- Clear pool if it gets too large
		if stringPoolSize > 10000 then
			wipe(stringPool)
			stringPoolSize = 1
			stringPool[str] = str
		end
	end

	return stringPool[str]
end

-- Clear the string pool when it gets too large (called periodically)
local function clearStringPool()
	if stringPoolSize > 10000 then
		wipe(stringPool)
		stringPoolSize = 0
	end
end

-- Cache management - periodically clean up caches to prevent memory bloat
local lastCacheCleanup = 0
local CACHE_CLEANUP_INTERVAL = 300  -- 5 minutes in seconds
local stringCacheSize = 0

local function cleanupCaches()
	local currentTime = GetTime()
	if currentTime - lastCacheCleanup > CACHE_CLEANUP_INTERVAL then
		-- Clear string cache if it's too large
		local count = 0
		for _ in pairs(stringCache) do
			count = count + 1
			if count > 1000 then
				wipe(stringCache)
				stringCacheSize = 0
				break
			end
		end

		-- Clear string pool
		clearStringPool()

		lastCacheCleanup = currentTime
	end
end

local function printf(...)
	DEFAULT_CHAT_FRAME:AddMessage(strformat(...))
end

local function getTextBeforeCursor(this, start)
	return strsub(this:GetText(), start or 1, this:GetCursorPosition())
end

-- Hook OnTabPressed and OnTextChanged for the frame, give it an empty matches table, and set its curMatch to 0, if we haven't done so already.
local function hookFrame(f)
	if hookedFrames[f] then return end
	hookedFrames[f] = true

	-- Pre-allocate tables for this frame to avoid creating them during gameplay
	frameData[f] = frameData[f] or {}
	frameData[f].curMatch = 0
	frameData[f].matches = {}
	frameData[f].cached_completions = {}

	if f == ChatEdit_GetActiveWindow() then
		local origCTP = ChatEdit_CustomTabPressed
		function ChatEdit_CustomTabPressed(self, ...)
			if AceTab:OnTabPressed(f) then
				return origCTP(self, ...)
			else
				return true
			end
		end
	else
		local origOTP = f:GetScript('OnTabPressed')
		if type(origOTP) ~= 'function' then
			origOTP = function() end
		end

		-- Use direct function reference for better performance
		local function onTabPressed(...)
			if AceTab:OnTabPressed(f) then
				if origOTP then
					return origOTP()
				end
				return
			end
		end

		f:SetScript('OnTabPressed', onTabPressed)
	end
end

-- ------------------------------------------------------------------------------
-- RegisterTabCompletion( descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite )
-- See http://www.wowace.com/wiki/AceTab-2.0 for detailed API documentation
--
-- descriptor	string					Unique identifier for this tab completion set
--
-- prematches	string|table|nil		String match(es) AFTER which this tab completion will apply.
--										AceTab will ignore tabs NOT preceded by the string(s).
--										If no value is passed, will check all tabs pressed in the specified editframe(s) UNLESS a more-specific tab complete applies.
--
-- wordlist		function|table			Function that will be passed a table into which it will insert strings corresponding to all possible completions, or an equivalent table.
--										The text in the editbox, the position of the start of the word to be completed, and the uncompleted partial word
--										are passed as second, third, and fourth arguments, to facilitate pre-filtering or conditional formatting, if desired.
--
-- usagefunc	function|boolean|nil	Usage statement function.  Defaults to the wordlist, one per line.  A boolean true squelches usage output.
--
-- listenframes	string|table|nil		EditFrames to monitor.  Defaults to ChatFrameEditBox.
--
-- postfunc		function|nil			Post-processing function.  If supplied, matches will be passed through this function after they've been identified as a match.
--
-- pmoverwrite	boolean|number|nil		Offset the beginning of the completion string in the editbox when making a completion.  Passing a boolean true indicates that we want to overwrite
--										the entire prematch string, and passing a number will overwrite that many characters prior to the cursor.
--										This is useful when you want to use the prematch as an indicator character, but ultimately do not want it as part of the text, itself.
--
-- no return
-- ------------------------------------------------------------------------------

-- Hook into existing functions to use string pooling
local originalRegisterTabCompletion = AceTab.RegisterTabCompletion

function AceTab:RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite)
	-- Pool the descriptor string
	descriptor = getPooledString(descriptor)

	-- Pool prematch strings if they're strings
	if type(prematches) == 'string' then
		prematches = getPooledString(prematches)
	elseif type(prematches) == 'table' then
		for i, v in ipairs(prematches) do
			if type(v) == 'string' then
				prematches[i] = getPooledString(v)
			end
		end
	end

	-- Arg checks
	if type(descriptor) ~= 'string' then error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'descriptor' - string expected.", 3) end
	if prematches and type(prematches) ~= 'string' and type(prematches) ~= 'table' then error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'prematches' - string, table, or nil expected.", 3) end
	if type(wordlist) ~= 'function' and type(wordlist) ~= 'table' then error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'wordlist' - function or table expected.", 3) end
	if usagefunc and type(usagefunc) ~= 'function' and type(usagefunc) ~= 'boolean' then error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'usagefunc' - function or boolean expected.", 3) end
	if listenframes and type(listenframes) ~= 'string' and type(listenframes) ~= 'table' then error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'listenframes' - string or table expected.", 3) end
	if postfunc and type(postfunc) ~= 'function' then error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'postfunc' - function expected.", 3) end
	if pmoverwrite and type(pmoverwrite) ~= 'boolean' and type(pmoverwrite) ~= 'number' then error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'pmoverwrite' - boolean or number expected.", 3) end

	local pmtable

	if type(prematches) == 'table' then
		pmtable = prematches
		notfallbacks[descriptor] = true
	else
		pmtable = {}
		-- Mark this group as a fallback group if no value was passed.
		if not prematches then
			pmtable[1] = ""
			fallbacks[descriptor] = true
		-- Make prematches into a one-element table if it was passed as a string.
		elseif type(prematches) == 'string' then
			pmtable[1] = prematches
			if prematches == "" then
				fallbacks[descriptor] = true
			else
				notfallbacks[descriptor] = true
			end
		end
	end

	-- Make listenframes into a one-element table if it was not passed a table of frames.
	if not listenframes then  -- default
		listenframes = {}
		for i = 1, NUM_CHAT_WINDOWS do
			listenframes[i] = _G["ChatFrame"..i.."EditBox"]
		end
	elseif type(listenframes) ~= 'table' or type(listenframes[0]) == 'userdata' and type(listenframes.IsObjectType) == 'function' then  -- single frame or framename
		listenframes = { listenframes }
	end

	-- Hook each registered listenframe and give it a matches table.
	for _, f in pairs(listenframes) do
		if type(f) == 'string' then
			f = _G[f]
		end
		if type(f) ~= 'table' or type(f[0]) ~= 'userdata' or type(f.IsObjectType) ~= 'function' then
			error(strformat(ACETAB_MAJOR..": Cannot register frame %q; it does not exist", f:GetName()))
		end
		if f then
			if f:GetObjectType() ~= 'EditBox' then
				error(strformat(ACETAB_MAJOR..": Cannot register frame %q; it is not an EditBox", f:GetName()))
			else
				hookFrame(f)
			end
		end
	end

	-- Everything checks out; register this completion.
	if not registry[descriptor] then
		registry[descriptor] = { prematches = pmtable, wordlist = wordlist, usagefunc = usagefunc, listenframes = listenframes, postfunc = postfunc, pmoverwrite = pmoverwrite }
	end
end

function AceTab:IsTabCompletionRegistered(descriptor)
	return registry and registry[descriptor]
end

function AceTab:UnregisterTabCompletion(descriptor)
	registry[descriptor] = nil
	pmolengths[descriptor] = nil
	fallbacks[descriptor] = nil
	notfallbacks[descriptor] = nil
end

-- ------------------------------------------------------------------------------
-- gcbs( s1, s2 )
--
-- s1		string		First string to be compared
--
-- s2		string		Second string to be compared
--
-- returns the greatest common substring beginning s1 and s2
-- ------------------------------------------------------------------------------
local function gcbs(s1, s2)
	-- Check cache first for common string pairs
	local cacheKey = (s1 or "") .. "\001" .. (s2 or "")
	if stringCache[cacheKey] then
		return stringCache[cacheKey]
	end

	if not s1 and not s2 then return end
	if not s1 then s1 = s2 end
	if not s2 then s2 = s1 end

	-- Optimize by swapping to ensure s1 is the shorter string
	if #s2 < #s1 then
		s1, s2 = s2, s1
	end

	-- Fast path for exact match
	if s1 == s2 then
		stringCache[cacheKey] = s1
		stringCacheSize = stringCacheSize + 1
		return s1
	end

	-- Fast path for prefix match
	local s1lower, s2lower = strlower(s1), strlower(s2)
	if strfind(s2lower, "^" .. s1lower) then
		stringCache[cacheKey] = s1
		stringCacheSize = stringCacheSize + 1
		return s1
	else
		-- Limit recursion depth to avoid stack overflow on very long strings
		if #s1 > 1 then
			local result = gcbs(strsub(s1, 1, -2), s2)
			stringCache[cacheKey] = result
			stringCacheSize = stringCacheSize + 1
			return result
		end
		return ""
	end
end

-- ------------------------------------------------------------------------------
-- cycleTab()
-- For when a tab press has multiple possible completions, we need to allow the user to press tab repeatedly to cycle through them.
-- If we have multiple possible completions, all tab presses after the first will call this function to cycle through and insert the different possible matches.
-- This function will stop being called after OnTextChanged() is triggered by something other than AceTab (i.e. the user inputs a character).
-- ------------------------------------------------------------------------------
local function cycleTab(this)
	local data = frameData[this]
	if not data then return end

	-- Use cached match count if available
	local matchCount = data.cached_match_count or 0

	-- If no matches, return early
	if matchCount == 0 then
		return
	end

	-- If we have a cached completion list, use it directly
	if data.cached_completions and #data.cached_completions > 0 then
		local nextIndex = data.curMatch
		if nextIndex > matchCount or nextIndex < 1 then
			nextIndex = 1
		end

		local completion = data.cached_completions[nextIndex]
		if completion then
			data.lastMatch = completion.match
			data.lastWord = completion.word
			data.curMatch = nextIndex + 1

			-- Insert the completion
			this:HighlightText(data.matchStart-1, cursor)
			this:Insert(data.lastWord or '')
			data.last_precursor = getTextBeforeCursor(this) or ''
		end
		return
	end

	-- Traditional method if cache isn't available
	cMatch = 0  -- Counter across all sets.  The pseudo-index relevant to this value and corresponding to the current match is held in data.curMatch
	matched = false

	-- Build cache if needed
	if not data.cached_completions then
		data.cached_completions = {}
	else
		wipe(data.cached_completions)
	end

	-- Check each completion group registered to this frame.
	for desc, compgrp in pairs(data.matches) do
		-- Loop through the valid completions for this set.
		for m, pm in pairs(compgrp) do
			cMatch = cMatch + 1
			tinsert(data.cached_completions, {match = m, word = pm})

			if cMatch == data.curMatch then  -- we're back to where we left off last time through the combined list
				data.lastMatch = m
				data.lastWord = pm
				data.curMatch = cMatch + 1 -- save the new cMatch index
				matched = true
			end
		end
	end

	data.cached_match_count = cMatch

	-- If our index is beyond the end of the list, reset the original uncompleted substring and let the cycle start over next time tab is pressed.
	if not matched then
		data.lastMatch = data.origMatch
		data.lastWord = data.origWord
		data.curMatch = 1
	end

	-- Insert the completion.
	this:HighlightText(data.matchStart-1, cursor)
	this:Insert(data.lastWord or '')
	data.last_precursor = getTextBeforeCursor(this) or ''
end

local numMatches = 0

-- Fill the data.matches[descriptor] tables with matching completion pairs for each entry, based on
-- the partial string preceding the cursor position and using the corresponding registered wordlist.
--
-- The entries of the matches tables are of the format raw_match = formatted_match, where raw_match is the plaintext completion and
-- formatted_match is the match after being formatted/altered/processed by the registered postfunc.
-- If no postfunc exists, then the formatted and raw matches are the same.
local function fillMatches(this, desc, fallback)
	entry = registry[desc]
	if not entry then return end

	local data = frameData[this]
	if not data then return end

	-- Quick check if this frame is registered for this completion group
	local isRegistered = false
	for _, f in ipairs(entry.listenframes) do
		if f == this then
			isRegistered = true
			break
		end
	end

	if not isRegistered then return end

	-- Try each precondition string registered for this completion group.
	for _, prematch in ipairs(entry.prematches) do
		-- Test if our prematch string is satisfied.
		-- If it is, then we find its last occurence prior to the cursor, calculate and store its pmoverwrite value (if applicable), and start considering completions.
		if fallback then prematch = "%s" end

		-- Find the last occurence of the prematch before the cursor.
		pms, pme, pmt = nil, 1, ''
		text_prematch, prematchEnd, prematchStart = nil, nil, nil

		-- Cache pattern for faster lookup
		local pattern = prematch and "(" .. prematch .. ")" or "(%s)"

		while true do
			pms, pme, pmt = strfind(text_precursor, pattern, pme)
			if pms then
				prematchStart, prematchEnd, text_prematch = pms, pme, pmt
				pme = pme + 1
			else
				break
			end
		end

		if not prematchStart and fallback then
			prematchStart, prematchEnd, text_prematch = 0, 0, ''
		end

		if prematchStart then
			-- text_pmendToCursor should be the sub-word/phrase to be completed.
			text_pmendToCursor = strsub(text_precursor, prematchEnd + 1)

			-- How many characters should we eliminate before the completion before writing it in.
			pmolengths[desc] = entry.pmoverwrite == true and #text_prematch or entry.pmoverwrite or 0

			-- This is where we will insert completions, taking the prematch overwrite into account.
			data.matchStart = prematchEnd + 1 - (pmolengths[desc] or 0)

			-- We're either a non-fallback set or all completions thus far have been fallback sets, and the precondition matches.
			-- Create cands from the registered wordlist, filling it with all potential (unfiltered) completion strings.
			local wordlist = entry.wordlist

			-- Reuse existing table if possible
			local cands
			if type(wordlist) == 'table' then
				cands = wordlist
			else
				-- Pre-allocate a table for wordlist function to fill
				if not data.temp_cands then
					data.temp_cands = {}
				else
					wipe(data.temp_cands)
				end
				cands = data.temp_cands

				if type(wordlist) == 'function' then
					wordlist(cands, text_all, prematchEnd + 1, text_pmendToCursor)
				end
			end

			if cands ~= false then
				local matches = data.matches[desc]
				if not matches then
					matches = {}
					data.matches[desc] = matches
				else
					wipe(matches)
				end

				-- Pre-calculate lowercase version of text_pmendToCursor for faster comparison
				local lowerPmendToCursor = strlower(text_pmendToCursor)

				-- Check each of the entries in cands to see if it completes the word before the cursor.
				-- Finally, increment our match count and set firstMatch, if appropriate.
				for _, m in ipairs(cands) do
					if strfind(strlower(m), lowerPmendToCursor, 1, true) == 1 then  -- we have a matching completion!
						hasNonFallback = hasNonFallback or not fallback

						-- Apply postfunc if available
						local formatted = m
						if entry.postfunc then
							formatted = entry.postfunc(m, prematchEnd + 1, text_all)
						end

						matches[m] = formatted
						numMatches = numMatches + 1
						if numMatches == 1 then
							firstMatch = formatted
						end
					end
				end

				-- Remove empty matches table to save memory
				if numMatches == 0 then
					data.matches[desc] = nil
				end
			end
		end
	end
end

-- Store the original function before we override it
local originalOnTabPressed = AceTab.OnTabPressed

function AceTab:OnTabPressed(this)
	-- Periodically clean up caches
	cleanupCaches()

	if not this or this:GetText() == '' then return true end

	local data = frameData[this]
	if not data then
		hookFrame(this)
		data = frameData[this]
	end

	-- allow Blizzard to handle slash commands, themselves
	if this == ChatEdit_GetActiveWindow() then
		local command = this:GetText()
		if strfind(command, "^/[%a%d_]+$") then
			return true
		end
		local cmd = strmatch(command, "^/[%a%d_]+")
		if cmd and IsSecureCmd(cmd) then
			return true
		end
	end

	cursor = this:GetCursorPosition()
	if not cursor then return true end

	text_all = this:GetText()
	text_precursor = getTextBeforeCursor(this) or ''

	-- If we've already found some matches and haven't done anything since the last tab press, then (continue) cycling matches.
	-- Otherwise, reset this frame's matches and proceed to creating our list of possible completions.
	data.lastMatch = data.curMatch > 0 and (data.lastMatch or data.origWord)

	-- Detects if we've made any edits since the last tab press. If not, continue cycling completions.
	if text_precursor == data.last_precursor then
		return cycleTab(this)
	else
		-- Clear matches and reset state
		if data.matches then
			wipe(data.matches)
		else
			data.matches = {}
		end

		-- Clear cached completions
		if data.cached_completions then
			wipe(data.cached_completions)
		end

		data.curMatch = 0
		data.origWord = nil
		data.origMatch = nil
		data.lastWord = nil
		data.lastMatch = nil
		data.last_precursor = text_precursor
		data.cached_match_count = 0
	end

	numMatches = 0
	firstMatch = nil
	hasNonFallback = false

	-- Clear pmolengths table
	for i in pairs(pmolengths) do
		pmolengths[i] = nil
	end

	-- First try non-fallback completions
	for desc in pairs(notfallbacks) do
		fillMatches(this, desc)
	end

	-- If no non-fallback completions matched, try fallbacks
	if not hasNonFallback then
		for desc in pairs(fallbacks) do
			fillMatches(this, desc, true)
		end
	end

	if not firstMatch then
		data.last_precursor = "\0"
		return true
	end

	-- We want to replace the entire word with our completion, so highlight it up to the cursor.
	-- If only one match exists, then stick it in there and append a space.
	if numMatches == 1 then
		-- HighlightText takes the value AFTER which the highlighting starts, so we have to subtract 1 to have it start before the first character.
		this:HighlightText(data.matchStart-1, cursor)
		this:Insert(firstMatch)
		this:Insert(" ")
	else
		-- Otherwise, we want to begin cycling through the valid completions.
		-- Beginning a cycle also causes the usage statement to be printed, if one exists.

		-- Print usage statements for each possible completion (and gather up the GCBS of all matches while we're walking the tables).
		allGCBS = nil

		-- Cache for usage statements to avoid duplicates
		local usageCache = {}

		for desc, matches in pairs(data.matches) do
			-- Skip if matches is nil
			if matches then
				-- Don't print usage statements for fallback completion groups if we have 'real' completion groups with matches.
				if hasNonFallback and fallbacks[desc] then break end

				-- Use the group's description as a heading for its usage statements.
				DEFAULT_CHAT_FRAME:AddMessage(desc..":")

				local usagefunc = registry[desc].usagefunc
				if not usagefunc then
					-- No special usage processing; just print a list of the (formatted) matches.
					for m, fm in pairs(matches) do
						-- Avoid duplicate usage statements
						if not usageCache[fm] then
							DEFAULT_CHAT_FRAME:AddMessage(fm)
							usageCache[fm] = true
						end
						allGCBS = gcbs(allGCBS, m)
					end
				else
					-- Print a usage statement based on the corresponding registered usagefunc.
					-- candUsage is the table passed to usagefunc to be filled with candidate = usage_statement pairs.
					if type(usagefunc) == 'function' then
						wipe(candUsage)

						-- usagefunc takes the greatest common substring of valid matches as one of its args, so let's find that now.
						-- TODO: Make the GCBS function accept a vararg or table, after which we can just pass in the list of matches.
						setGCBS = nil
						for m in pairs(matches) do
							setGCBS = gcbs(setGCBS, m)
						end
						allGCBS = gcbs(allGCBS, setGCBS)
						usage = usagefunc(candUsage, matches, setGCBS, strsub(text_precursor, 1, prematchEnd))

						-- If the usagefunc returns a string, then the entire usage statement has been taken care of by usagefunc, and we need only to print it...
						if type(usage) == 'string' then
							DEFAULT_CHAT_FRAME:AddMessage(usage)

						-- ...otherwise, it should have filled candUsage with candidate-usage statement pairs, and we need to print the matching ones.
						elseif next(candUsage) and numMatches > 0 then
							for m, fm in pairs(matches) do
								if candUsage[m] and not usageCache[fm] then
									DEFAULT_CHAT_FRAME:AddMessage(strformat("%s - %s", fm, candUsage[m]))
									usageCache[fm] = true
								end
							end
						end
					end
				end

				if next(matches) then
					-- Replace the original string with the greatest common substring of all valid completions.
					data.curMatch = 1
					data.origWord = (strsub(text_precursor, data.matchStart, data.matchStart + pmolengths[desc] - 1) .. (allGCBS or ""))
					data.origMatch = allGCBS or ""
					data.lastWord = data.origWord
					data.lastMatch = data.origMatch

					this:HighlightText(data.matchStart-1, cursor)
					this:Insert(data.origWord)
					data.last_precursor = getTextBeforeCursor(this) or ''
				end
			end
		end
	end
end
