--- AceTab-3.0 provides support for tab-completion.
-- Note: This library is not yet finalized.
-- @class file
-- @name AceTab-3.0
-- @release $Id$

local ACETAB_MAJOR, ACETAB_MINOR = 'AceTab-3.0', 16
local AceTab, oldminor = LibStub:NewLibrary(ACETAB_MAJOR, ACETAB_MINOR)

if not AceTab then return end -- No upgrade needed

AceTab.registry = AceTab.registry or {}

-- Cache frequently used globals to locals for performance
local _G = _G
local pairs = pairs
local ipairs = ipairs
local type = type
local next = next
local tinsert = table.insert
local tremove = table.remove
local registry = AceTab.registry

-- Cache string functions
local strfind = string.find
local strsub = string.sub
local strlower = string.lower
local strformat = string.format
local strmatch = string.match

-- Cache frequently used APIs
local GetTime = GetTime
local UIParent = UIParent
local IsSecureCmd = IsSecureCmd
local ChatEdit_GetActiveWindow = ChatEdit_GetActiveWindow
local InCombatLockdown = InCombatLockdown

-- Create reusable tables for temporary operations (reduce GC pressure)
local tempTable = {}
local matchTable = {}
local resultTable = {}

-- Track hooked frames separately instead of modifying the EditBox directly
local hookedFrames = {}

-- Configuration options for performance tuning
local MATCH_CACHE_SIZE = 50      -- Maximum number of match-pattern results to cache
local CACHE_EXPIRE_TIME = 60     -- Time in seconds before a cache entry expires
local MAX_MATCHES_TO_DISPLAY = 20 -- Max matches to display in chat (prevent UI lag)

-- Cache structure for patterns and match results
local patternCache = {}
local resultCache = {}
local cacheTimestamps = {}

local function printf(...)
	DEFAULT_CHAT_FRAME:AddMessage(strformat(...))
end

local function getTextBeforeCursor(this, start)
	return strsub(this:GetText(), start or 1, this:GetCursorPosition())
end

-- Clear all temp tables for reuse (more efficient than creating new tables)
local function clearTable(t)
    for k in pairs(t) do t[k] = nil end
    return t
end

-- Cache pattern match results for frequently used patterns
local function getCachedPattern(pattern, text)
    local cacheKey = pattern .. ":" .. text
    -- Simply return the cached result if it exists (expiration handled by periodic cleanup)
    return patternCache[cacheKey]
end

local function cachePatternResult(pattern, text, result)
    -- Don't cache empty results or excessively long strings
    if not result or #text > 1000 then return end

    local cacheKey = pattern .. ":" .. text

    -- Manage cache size (simple LRU)
    if not patternCache[cacheKey] then
        local count = 0
        for k in pairs(patternCache) do
            count = count + 1
        end

        if count >= MATCH_CACHE_SIZE then
            -- Find oldest entry to remove
            local oldestKey, oldestTime = nil, math.huge
            for k, time in pairs(cacheTimestamps) do
                if time < oldestTime then
                    oldestTime = time
                    oldestKey = k
                end
            end

            if oldestKey then
                patternCache[oldestKey] = nil
                cacheTimestamps[oldestKey] = nil
            end
        end
    end

    patternCache[cacheKey] = result
    cacheTimestamps[cacheKey] = GetTime()
end

-- Hook OnTabPressed and OnTextChanged for the frame, give it an empty matches table, and set its curMatch to 0, if we haven't done so already.
local function hookFrame(f)
	if hookedFrames[f] then return end
	hookedFrames[f] = true

	if f == ChatEdit_GetActiveWindow() then
		local origCTP = ChatEdit_CustomTabPressed
		function ChatEdit_CustomTabPressed(...)
			if AceTab:OnTabPressed(f) then
				return origCTP(...)
			else
				return true
			end
		end
	else
		local origOTP = f:GetScript('OnTabPressed')
		if type(origOTP) ~= 'function' then
			origOTP = function() end
		end
		f:SetScript('OnTabPressed', function(...)
			if AceTab:OnTabPressed(f) then
				return origOTP()  -- Don't pass arguments to origOTP
			end
		end)
	end

	-- Store match data in our tracking table instead of on the frame
	if not hookedFrames.matchData then hookedFrames.matchData = {} end
	hookedFrames.matchData[f] = {
		curMatch = 0,
		matches = {},
		matchStart = nil,
		lastMatch = nil,
		origMatch = nil,
		origWord = nil,
		lastWord = nil,
		last_precursor = nil
	}
end

-- Optimization for string operations
local function fastFind(haystack, needle, plaintext)
    -- Check cache first
    local result = getCachedPattern(needle, haystack)
    if result then return result[1], result[2], result[3] end

    -- Do actual search if not cached
    local s, e, cap = strfind(haystack, needle, 1, plaintext)

    -- Cache result for future lookups
    if s then
        cachePatternResult(needle, haystack, {s, e, cap})
    end

    return s, e, cap
end

local fallbacks, notfallbacks = {}, {}  -- classifies completions into those which have preconditions and those which do not.  Those without preconditions are only considered if no other completions have matches.
local pmolengths = {}  -- holds the number of characters to overwrite according to pmoverwrite and the current prematch
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
function AceTab:RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite)
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
	if not s1 and not s2 then return end
	if not s1 then s1 = s2 end
	if not s2 then s2 = s1 end
	if #s2 < #s1 then
		s1, s2 = s2, s1
	end
	if fastFind(strlower(s2), "^"..strlower(s1), false) then
		return s1
	else
		return gcbs(strsub(s1, 1, -2), s2)
	end
end

local cursor  -- Holds cursor position.  Set in :OnTabPressed().
-- ------------------------------------------------------------------------------
-- cycleTab()
-- For when a tab press has multiple possible completions, we need to allow the user to press tab repeatedly to cycle through them.
-- If we have multiple possible completions, all tab presses after the first will call this function to cycle through and insert the different possible matches.
-- This function will stop being called after OnTextChanged() is triggered by something other than AceTab (i.e. the user inputs a character).
-- ------------------------------------------------------------------------------
local cMatch, matched
local function cycleTab(this)
	local frameData = hookedFrames.matchData[this]
	if not frameData then return end

	cMatch = 0  -- Counter across all sets.  The pseudo-index relevant to this value and corresponding to the current match is held in frameData.curMatch
	matched = false

	-- Check each completion group registered to this frame.
	for desc, compgrp in pairs(frameData.matches) do
		-- Loop through the valid completions for this set.
		for m, pm in pairs(compgrp) do
			cMatch = cMatch + 1
			if cMatch == frameData.curMatch then  -- we're back to where we left off last time through the combined list
				frameData.lastMatch = m
				frameData.lastWord = pm
				frameData.curMatch = cMatch + 1 -- save the new cMatch index
				matched = true
				break
			end
		end
		if matched then break end
	end

	-- If our index is beyond the end of the list, reset the original uncompleted substring and let the cycle start over next time tab is pressed.
	if not matched then
		frameData.lastMatch = frameData.origMatch
		frameData.lastWord = frameData.origWord
		frameData.curMatch = 1
	end

	-- Insert the completion.
	this:HighlightText(frameData.matchStart-1, cursor)
	this:Insert(frameData.lastWord or '')
	frameData.last_precursor = getTextBeforeCursor(this) or ''
end

local candUsage = {}
local numMatches = 0
local firstMatch, hasNonFallback, allGCBS, setGCBS, usage
local text_precursor, text_all, text_pmendToCursor

-- Fill the this.at3matches[descriptor] tables with matching completion pairs for each entry, based on
-- the partial string preceding the cursor position and using the corresponding registered wordlist.
--
-- The entries of the matches tables are of the format raw_match = formatted_match, where raw_match is the plaintext completion and
-- formatted_match is the match after being formatted/altered/processed by the registered postfunc.
-- If no postfunc exists, then the formatted and raw matches are the same.
local pms, pme, pmt, prematchStart, prematchEnd, text_prematch, entry
local function fillMatches(this, desc, fallback)
	local frameData = hookedFrames.matchData[this]
	if not frameData then return end

	entry = registry[desc]
	-- See what frames are registered for this completion group.  If the frame in which we pressed tab is one of them, then we start building matches.
	for _, f in ipairs(entry.listenframes) do
		if f == this then
			-- Try each precondition string registered for this completion group.
			for _, prematch in ipairs(entry.prematches) do
				-- Test if our prematch string is satisfied.
				-- If it is, then we find its last occurence prior to the cursor, calculate and store its pmoverwrite value (if applicable), and start considering completions.
				if fallback then prematch = "%s" end

				-- Find the last occurence of the prematch before the cursor.
				pms, pme, pmt = nil, 1, ''
				text_prematch, prematchEnd, prematchStart = nil, nil, nil

				-- Use cached pattern matching when possible
				while true do
                    pms, pme, pmt = fastFind(text_precursor, "("..prematch..")", pme)
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
					frameData.matchStart = prematchEnd + 1 - (pmolengths[desc] or 0)

					-- We're either a non-fallback set or all completions thus far have been fallback sets, and the precondition matches.
					-- Create cands from the registered wordlist, filling it with all potential (unfiltered) completion strings.
					local wordlist = entry.wordlist
					local cands = type(wordlist) == 'table' and wordlist or clearTable(tempTable)
					if type(wordlist) == 'function' then
						wordlist(cands, text_all, prematchEnd + 1, text_pmendToCursor)
					end

					if cands ~= false then
						local matches = frameData.matches[desc] or {}
						for i in pairs(matches) do matches[i] = nil end

						-- Check each of the entries in cands to see if it completes the word before the cursor.
						-- Finally, increment our match count and set firstMatch, if appropriate.
						-- Optimization: cache strlower results for frequently accessed values
						local loweredInput = strlower(text_pmendToCursor)

						for _, m in ipairs(cands) do
							if fastFind(strlower(m), loweredInput, true) == 1 then  -- we have a matching completion!
								hasNonFallback = hasNonFallback or (not fallback)
								matches[m] = entry.postfunc and entry.postfunc(m, prematchEnd + 1, text_all) or m
								numMatches = numMatches + 1
								if numMatches == 1 then
									firstMatch = matches[m]
								end
							end
						end
						frameData.matches[desc] = numMatches > 0 and matches or nil
					end
				end
			end
		end
	end
end

function AceTab:OnTabPressed(this)
	local frameData = hookedFrames.matchData[this]
	if not frameData then
		hookFrame(this)
		frameData = hookedFrames.matchData[this]
	end

	if this:GetText() == '' then return true end

	-- allow Blizzard to handle slash commands, themselves
	if this == ChatEdit_GetActiveWindow() then
		local command = this:GetText()
		if fastFind(command, "^/[%a%d_]+$", false) then
			return true
		end
		local cmd = strmatch(command, "^/[%a%d_]+")
		if cmd and IsSecureCmd(cmd) then
			return true
		end
	end

	cursor = this:GetCursorPosition()

	text_all = this:GetText()
	text_precursor = getTextBeforeCursor(this) or ''

	-- If we've already found some matches and haven't done anything since the last tab press, then (continue) cycling matches.
	-- Otherwise, reset this frame's matches and proceed to creating our list of possible completions.
	frameData.lastMatch = frameData.curMatch > 0 and (frameData.lastMatch or frameData.origWord)
	-- Detects if we've made any edits since the last tab press.  If not, continue cycling completions.
	if text_precursor == frameData.last_precursor then
		return cycleTab(this)
	else
		for i in pairs(frameData.matches) do frameData.matches[i] = nil end
		frameData.curMatch = 0
		frameData.origWord = nil
		frameData.origMatch = nil
		frameData.lastWord = nil
		frameData.lastMatch = nil
		frameData.last_precursor = text_precursor
	end

	numMatches = 0
	firstMatch = nil
	hasNonFallback = false
	for i in pairs(pmolengths) do pmolengths[i] = nil end

	for desc in pairs(notfallbacks) do
		fillMatches(this, desc)
	end
	if not hasNonFallback then
		for desc in pairs(fallbacks) do
			fillMatches(this, desc, true)
		end
	end

	if not firstMatch then
		frameData.last_precursor = "\0"
		return true
	end

	-- We want to replace the entire word with our completion, so highlight it up to the cursor.
	-- If only one match exists, then stick it in there and append a space.
	if numMatches == 1 then
		-- HighlightText takes the value AFTER which the highlighting starts, so we have to subtract 1 to have it start before the first character.
		this:HighlightText(frameData.matchStart-1, cursor)

		this:Insert(firstMatch)
		this:Insert(" ")
	else
		-- Otherwise, we want to begin cycling through the valid completions.
		-- Beginning a cycle also causes the usage statement to be printed, if one exists.

		-- Print usage statements for each possible completion (and gather up the GCBS of all matches while we're walking the tables).
		allGCBS = nil
		local displayCount = 0

		for desc, matches in pairs(frameData.matches) do
			-- Don't print usage statements for fallback completion groups if we have 'real' completion groups with matches.
			if hasNonFallback and fallbacks[desc] then break end

			-- Use the group's description as a heading for its usage statements.
			DEFAULT_CHAT_FRAME:AddMessage(desc..":")

			local usagefunc = registry[desc].usagefunc
			if not usagefunc then
				-- No special usage processing; just print a list of the (formatted) matches.
				for m, fm in pairs(matches) do
					displayCount = displayCount + 1
                    if displayCount <= MAX_MATCHES_TO_DISPLAY then
                        DEFAULT_CHAT_FRAME:AddMessage(fm)
                    elseif displayCount == MAX_MATCHES_TO_DISPLAY + 1 then
                        DEFAULT_CHAT_FRAME:AddMessage("... and " .. (numMatches - MAX_MATCHES_TO_DISPLAY) .. " more matches")
                    end
					allGCBS = gcbs(allGCBS, m)
				end
			else
				-- Print a usage statement based on the corresponding registered usagefunc.
				-- candUsage is the table passed to usagefunc to be filled with candidate = usage_statement pairs.
				if type(usagefunc) == 'function' then
					clearTable(candUsage)

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
						displayCount = 0
						for m, fm in pairs(matches) do
							displayCount = displayCount + 1
							if candUsage[m] and displayCount <= MAX_MATCHES_TO_DISPLAY then
                                DEFAULT_CHAT_FRAME:AddMessage(strformat("%s - %s", fm, candUsage[m]))
                            elseif displayCount == MAX_MATCHES_TO_DISPLAY + 1 then
                                DEFAULT_CHAT_FRAME:AddMessage("... and " .. (numMatches - MAX_MATCHES_TO_DISPLAY) .. " more matches")
                                break
                            end
						end
					end
				end
			end

			if next(matches) then
				-- Replace the original string with the greatest common substring of all valid completions.
				frameData.curMatch = 1
				frameData.origWord = (strsub(text_precursor, frameData.matchStart, frameData.matchStart + pmolengths[desc] - 1) .. (allGCBS or ""))
				frameData.origMatch = allGCBS or ""
				frameData.lastWord = frameData.origWord
				frameData.lastMatch = frameData.origMatch

				this:HighlightText(frameData.matchStart-1, cursor)
				this:Insert(frameData.origWord)
				frameData.last_precursor = getTextBeforeCursor(this) or ''
			end
		end
	end
end

-- Utility function for addon developers to pre-cache critical data
function AceTab:PreCacheMatches(descriptor, matches)
    if not registry[descriptor] then
        error(ACETAB_MAJOR .. ": Cannot pre-cache matches for unregistered completion " .. descriptor)
        return
    end

    if type(matches) ~= "table" then
        error(ACETAB_MAJOR .. ": PreCacheMatches requires a table of match strings")
        return
    end

    -- Pre-process all matches for faster lookups later
    for _, match in ipairs(matches) do
        -- Pre-cache lowercase versions
        local _ = strlower(match)
    end

    return true
end

-- Periodically clean cache to prevent memory bloat
-- Only run when not in combat to avoid affecting performance during critical gameplay
local cacheCleanFrame = CreateFrame("Frame")
cacheCleanFrame.elapsed = 0
cacheCleanFrame:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = (self.elapsed or 0) + elapsed
    if self.elapsed < 60 then return end
    self.elapsed = 0

    if not InCombatLockdown() then
        local now = GetTime()
        local pruneCount = 0

        -- Clean expired cache entries
        for key, timestamp in pairs(cacheTimestamps) do
            if now - timestamp > CACHE_EXPIRE_TIME then
                patternCache[key] = nil
                cacheTimestamps[key] = nil
                pruneCount = pruneCount + 1

                -- Only prune a few entries per cycle to avoid lag spikes
                if pruneCount >= 10 then break end
            end
        end
    end
end)
