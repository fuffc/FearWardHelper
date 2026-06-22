--[[ FearWardHelper ------------------------------------------------------------

A Priest helper for the spell **Fear Ward** (spell id 6346: instant, 30s
cooldown, 10 min buff that blocks the next fear). It does three things:

  1. COOLDOWN TRACKING -- lists every priest in the party/raid and shows whose
     Fear Ward is ready vs. counting down. Cooldowns are learned two ways:
       - locally, by observing SuperWoW's UNIT_CASTEVENT (which fires for *every*
         unit's casts, not just the player -- so any priest you can see starts a
         CD here, addon or not), and
       - over the air, by broadcasting your own casts to other FearWardHelper
         users (fills the gap for priests you can't see). See "Sync".
  2. WARD TRACKING -- for a configurable watch-list of player names, shows whether
     each has the Fear Ward buff and the time left. Fear Ward's duration is a FIXED
     10 min (nothing modifies it), so we only need the application *moment*:
       - event-driven, via this client's BUFF_ADDED_*/BUFF_REMOVED_* combat-log
         events -- exact application/refresh time and instant loss (a fear consumed
         it, the player cancelled it, or it expired -- the event is reason-agnostic);
       - the 0.25s buff scan + observed/synced cast act as fallback/reconciliation
         (for self the scan reads the exact remaining via GetPlayerBuffTimeLeft);
       - timers are persisted as a time() epoch, so a countdown survives /reload.
     All of these reach only combat-log range; a ward applied out of sight that we
     never saw shows "warded" without a timer until a scan or event sees it.
  3. CAST HELPER -- click a watched player's row, or call the macro globals, to
     cast Fear Ward on them without dropping your current target.

Cooldown + ward tracking work for ANY class (raid-lead observation); only the
cast helper requires being a Priest who knows Fear Ward (`canCast`).

SuperWoW (UNIT_CASTEVENT / SpellInfo / GUIDs / BUFF_* events) gives full tracking.
Without it the frames still show and the cast helper still works; ward presence is
polled via base-API UnitBuff (your own timer read exactly) and cooldowns still
arrive over sync from other FearWardHelper users -- but live cast observation and
the event-driven ward signal are gone, so your *own* cooldown after casting won't
self-populate (no UNIT_CASTEVENT to see it).

Locale-independence (like our sibling addon PrayerHelper): the spell is matched
by **id** (6346) for casts and by its **icon texture** for buff scans -- never by
the translated name. The one place a name is needed (CastSpellByName) uses the
localized name from SpellInfo(6346); without SuperWoW that comes from the
spellbook (matched by the fixed icon) instead, never a hardcoded English string.

Config via /fw (add/remove/list/up/down watch targets, merge/split, lock/unlock,
scale, reset) or the `/fw config` panel, which drives the same setters. Layout,
scale, lock, the merged-frame toggle and the watch-list live in FearWardHelperDB.
----------------------------------------------------------------------------- ]]

local FEAR_WARD_ID       = 6346
local FEAR_WARD_CD       = 30      -- seconds; this server's Fear Ward cooldown
local FEAR_WARD_DURATION = 600     -- seconds; 10 min buff
local FEAR_WARD_RANGE    = 30      -- yards; cast range (drives the hover range/LOS check)
local RANGE_SLACK        = 3       -- yards of fudge for centre-to-centre vs the server's
                                   -- edge-to-edge check (cf. pfUI's +5). Used by castBlock
                                   -- (cast/LOS gate) and oorDistance (the hover OOR gate).
local ADDON_PREFIX       = "FWH"   -- addon-message prefix for cooldown sync

-- Direction arrow shown on a watch row when the target is in object range but out
-- of cast range -- which way to run to reach them. Uses pfQuest's arrow.tga: a
-- 512x512 sheet, a 9x12 grid of 56x42 frames = 108 pre-rotated arrows (no
-- texture-rotation API on 1.12), cell 0 = pointing straight up / ahead. The world
-- bearing (UnitPosition, +X north/+Y west) and the minimap-arrow facing share a
-- north-up frame, but the atlas frame order (CW vs CCW) and the model's zero-facing
-- reference needed a one-time in-game tune (done -- the values below are calibrated
-- for this client): if the arrow ever points mirror-wrong flip ARROW_SIGN; if it's
-- off by a constant rotation nudge ARROW_OFFSET (radians, e.g. math.pi = 180, pi/2 =
-- a quarter turn).
local ARROW_TEXTURE = "Interface\\AddOns\\FearWardHelper\\textures\\arrow"
local ARROW_FRAMES  = 108
local ARROW_COLS    = 9
local ARROW_CW      = 56
local ARROW_CH      = 42
local ARROW_SHEET   = 512
local ARROW_SIGN    = 1    -- +1/-1: mirror flip (calibrated)
local ARROW_OFFSET  = 0    -- radians: constant rotation correction (calibrated)

-- The localized spell name and lowercased icon texture for Fear Ward, resolved
-- once from SpellInfo(6346). The name drives CastSpellByName; the icon drives the
-- locale-free buff scan. SpellInfo works on any id (a SuperWoW DBC lookup),
-- whether or not the player knows the spell.
local fearWardName, fearWardIcon

-- The nine vanilla class tokens (as UnitClass returns them), in the default sweep
-- priority order. Role/spec is undeterminable for other players on this 1.12 client
-- (no talent inspection), so class is the only per-unit proxy the sweep can order by.
-- Healers + casters first (most hurt by an uninterrupted fear); the user reorders.
local CLASS_TOKENS = {
	"PRIEST", "PALADIN", "DRUID", "SHAMAN",
	"MAGE", "WARLOCK", "HUNTER", "ROGUE", "WARRIOR",
}

-- Frame layout / scale / lock defaults. The two frames are configured
-- independently; `/fw reset` restores exactly these (the watch-list is kept).
local DB_DEFAULTS = {
	watchList    = {},      -- ordered list of watched names; index = priority
	watchDisabled = {},     -- lower(name) -> true for names temporarily not tracked (off)
	watchHidden  = {},      -- lower(name) -> true for names hidden from the tracker but still priority
	wards        = {},      -- name -> time() epoch the buff expires (persisted timers)
	showWhenSolo = false,   -- keep the frames up even when not grouped
	hidden       = false,   -- master toggle: hide the addon entirely regardless of group/solo
	merged       = true,    -- show CDs + targets in one frame (the CD frame) instead of two
	bgOpacity    = 0.8,     -- frame background alpha (0-1), shared by both tracker frames
	wardNextSweep = false,  -- WardNext: when all tracked are warded, ward any unwarded group member
	lowDuration  = 60,      -- seconds: a ward with less than this left shows orange + becomes a
	                        -- WardNext priority (top-off early); 0 disables (only unwarded count)
	sweepClassOrder = CLASS_TOKENS,  -- class priority order for the sweep (copied per-DB by applyDefaults)
	sweepClassDisabled = {},          -- class token -> true: that class is ignored by the sweep
	-- Notifications (the floating message area; see "Notifications" below).
	notifyApply          = true,   -- announce a Fear Ward gain (source -> target)
	notifyApplyUntracked = false,  -- also announce gains/losses for in-group players not on the watch-list
	notifyLoss           = true,   -- announce a tracked target losing Fear Ward
	notifyLowDuration    = false,  -- announce when a tracked target's ward drops below lowDuration
	notifyCastFail       = false,  -- announce when WardNext blocks on an unreachable visible tracked target
	notifyCDReady        = false,  -- announce when your *own* Fear Ward comes off cooldown
	notifyCDReadyGroup   = false,  -- also announce when other group priests' Fear Ward is ready
	notifyDuration       = 5,      -- seconds a notification stays before it fades out
	notifyFontSize       = 14,     -- notification line font size ("resize" = font size)
	cdFrame      = { point = "CENTER", x = -220, y = 120, scale = 1.0, width = 150, locked = false },
	watchFrame   = { point = "CENTER", x =  220, y = 120, scale = 1.0, width = 170, locked = false },
	notifyFrame  = { point = "CENTER", x =    0, y = 150, scale = 1.0, width = 240, locked = false },
}

-- Row geometry (frame width is per-frame in the DB; height auto-fits the rows).
local HEADER_H  = 18  -- space the title occupies at the top
local ROW_H     = 14  -- per-row height
local PAD       = 6   -- inner padding
local SUBHEAD_H = 16  -- the "Targets" sub-section header in merged mode

----------------------------------------------------------------------------
-- Live state (rebuilt from the roster; not persisted)
----------------------------------------------------------------------------

-- Roster, refreshed on every roster change. priests is ordered for display.
local priests        = {}   -- { {name=, unit=, guid=, class=}, ... } priests in group
local roster         = {}   -- ordered list of every present group member's name (sweep order)
local unitByName     = {}   -- actual name  -> unit token (for buff scan / casting)
local nameByGuid     = {}   -- guid         -> actual name (resolve cast events)
local presentLower   = {}   -- lower(name)  -> actual name (case-insensitive match)
local classByName    = {}   -- actual name  -> non-localized class token (name colour)

-- Tracked timers, keyed by actual player name.
local cdReadyAt      = {}   -- name -> GetTime() when Fear Ward comes off cooldown (transient)
local cdNotifyPending = {}  -- name -> true while we await its CD elapsing (to notify "ready" once)
local wardExpiresAt  = {}   -- name -> time() epoch their buff expires; reassigned to the
                            -- persisted FearWardHelperDB.wards at VARIABLES_LOADED so the
                            -- countdown survives /reload + relog (epoch, not GetTime)
local wardPresent    = {}   -- name -> bool/nil; bool once a buff scan has an opinion, nil
                            -- when unscanned (then the timer alone decides "warded")

-- Row widget pools (created lazily, reused across rebuilds).
local cdRows         = {}
local watchRows      = {}
local watchVisible   = 0    -- number of watch rows currently shown
local hoveredWatchRow       -- the watch row under the mouse (cast helper), or nil

local isPriest, knowsFearWard, canCast
local playerName, playerGUID
local active = false        -- whether the tracker is live (grouped / showWhenSolo)
local warnedNoSuperWoW = false

-- Forward declaration: the config panel (built lazily near the bottom) mirrors DB
-- state, so anything that mutates layout/watch-list pokes refreshConfig() to keep an
-- open panel in sync. Nil until the config section assigns it; callers guard on it.
local refreshConfig

-- Forward declaration: applyPosition converts DB anchor coords to a TOPLEFT SetPoint
-- (working around a client bug with non-TOPLEFT anchors). Called from rebuildRows
-- after sizing so the anchor edge stays fixed as height changes.
local applyPosition

-- Forward declaration: refreshDisplay (the per-tick status painter, defined lower
-- down) is poked by the watch-row hover handlers, which sit above its definition.
local refreshDisplay

-- Forward declaration: findWatchIndex (watch-list priority lookup, defined with the
-- watch-list editing functions near the bottom) is used early by the loss batcher to
-- rank simultaneous Fear Ward losses by priority.
local findWatchIndex

----------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------

-- Recursively fill missing keys in `dst` from `src` (so new defaults appear on
-- upgrade without clobbering saved values). Sub-tables are merged, not replaced.
local function applyDefaults(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			applyDefaults(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

-- "Ns" under a minute, "M:SS" at or above one.
local function fmtTime(sec)
	sec = math.floor(sec + 0.5)
	if sec < 0 then sec = 0 end
	if sec >= 60 then
		local m = math.floor(sec / 60)
		return string.format("%d:%02d", m, sec - m * 60)
	end
	return sec .. "s"
end

local function superWoW() return SpellInfo ~= nil end

-- Class-colour for a non-localized class token (RAID_CLASS_COLORS), white if
-- unknown. Used to tint the name on each row.
local function classColor(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then return c.r, c.g, c.b end
	return 1, 1, 1
end

-- A player name wrapped in its class colour as an inline |cff...|r escape, for use
-- in notification text (where a font string mixes several coloured spans). Falls
-- back to white for an unknown class, like classColor.
local function colorName(name)
	local r, g, b = classColor(classByName[name])
	return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, name)
end

-- Resolve Fear Ward's localized name + icon. SpellInfo (SuperWoW) is preferred;
-- without it, fall back to the locale-free icon path so the cast helper and
-- buff poll still work on a base client. The localized name is then filled
-- from the spellbook in scanKnowsFearWard() instead.
local function resolveFearWard()
	if fearWardName and fearWardIcon then return end          -- already fully resolved
	if SpellInfo then
		local name, _, icon = SpellInfo(FEAR_WARD_ID)
		if name then
			fearWardName = name
			fearWardIcon = icon and string.lower(icon)
		end
	elseif not fearWardIcon then
		-- No SuperWoW — use the fixed icon path (locale-free) as fallback.
		fearWardIcon = "interface\\icons\\spell_holy_excorcism"
	end
end

-- Is Fear Ward in the spellbook? Matched by icon (locale-free). Drives canCast.
-- When the icon matches and fearWardName is still nil (no SuperWoW to provide it),
-- capture the localized name from the spellbook so castOn can use it.
local function scanKnowsFearWard()
	knowsFearWard = false
	if fearWardIcon then
		local book = BOOKTYPE_SPELL or "spell"
		local i = 1
		while true do
			local name = GetSpellName(i, book)
			if not name then break end
			local tex = GetSpellTexture(i, book)
			if tex and string.lower(tex) == fearWardIcon then
				knowsFearWard = true
				-- Fill the localized name from the spellbook when SpellInfo
				-- wasn't available (base client without SuperWoW).
				if not fearWardName then fearWardName = name end
				break
			end
			i = i + 1
		end
	end
	canCast = (isPriest == true) and knowsFearWard
end

-- Is a group member offline? UnitIsConnected returns false for a disconnected
-- unit (true for the player and any present, connected member). A nil unit / not
-- in group is treated as online so we never wrongly tag a row "Offline".
local function isOffline(unit)
	return unit ~= nil and UnitExists(unit) and not UnitIsConnected(unit)
end

-- CRASH GUARD for the optional native services (UnitXP_SP3 / SuperWoW positional
-- calls). On this client those functions dereference the unit's *world object*
-- directly, so calling them on a unit with no loaded object -- offline, far out of
-- object range, or (the login/zone race) not yet streamed in even though it's in the
-- roster -- is a NATIVE access violation that hard-crashes the client. A Lua pcall
-- does NOT catch a native segfault, so the pcall wrappers below are only a backstop
-- for Lua-level errors; the REAL protection is never calling them unless the unit is
-- safe. A unit is safe only when it exists, is connected (not offline) AND is visible
-- to the client (the object is streamed in).
local function trackable(unit)
	return unit ~= nil
		and UnitExists(unit)
		and UnitIsConnected(unit)
		and UnitIsVisible(unit)
end

-- Player + unit world coords (pcall-guarded UnitPosition pairs), or nil if either is
-- unavailable. UnitPosition returns nil *gracefully* for a unit whose world object
-- isn't loaded, so a nil here doubles as the crash-safe signal that UnitXP must NOT
-- be called on this unit (UnitXP would deref that null object and native-crash). nil
-- when this client lacks UnitPosition at all (older SuperWoW).
local function worldPos(unit)
	if not UnitPosition then return nil end
	local okp, px, py = pcall(UnitPosition, "player")
	local okt, tx, ty = pcall(UnitPosition, unit)
	if okp and okt and px and py and tx and ty then return px, py, tx, ty end
	return nil
end

-- Cast-helper range / line-of-sight. UnitXP_SP3 (present on this client) exposes
-- UnitXP("distanceBetween", a, b) -> yards and UnitXP("inSight", a, b) -> bool.
-- Detected once and pcall-guarded, since UnitXP_SP3 is an optional addon. A few
-- yards of slack is added to the range because distanceBetween is centre-to-centre
-- while the server measures edge-to-edge (cf. pfUI librange's +5 fudge).
local hasUnitXP
local function detectUnitXP()
	if hasUnitXP == nil then
		hasUnitXP = false
		if UnitXP then
			local ok, val = pcall(UnitXP, "distanceBetween", "player", "player")
			if ok and val then hasUnitXP = true end
		end
	end
	return hasUnitXP
end

-- Why a cast on `unit` would fail right now: "OOR" (out of range), "LOS" (no line of
-- sight) or nil when clear. Range is checked first (the more common, definite gate).
-- Without UnitXP we fall back to CheckInteractDistance for a coarse range gate only
-- (no line-of-sight test is possible then), so LOS simply never trips.
local function castBlock(unit)
	if not unit or not UnitExists(unit) then return nil end
	-- Offline / out of object range / not yet streamed in (a different zone, just very
	-- far, or the login race) -> no position to measure, so range/LOS don't apply and
	-- it's unreachable either way. This is also the crash gate: never query a unit whose
	-- object may be null (see trackable). Avoids a false "LOS" from UnitXP too.
	if not trackable(unit) then return "OOR" end
	-- Second, definitive crash gate: only touch UnitXP once UnitPosition confirms the
	-- world object is actually loaded (UnitPosition fails *safely*; UnitXP does not).
	if UnitPosition and not worldPos(unit) then return "OOR" end
	if detectUnitXP() then
		local okD, dist = pcall(UnitXP, "distanceBetween", "player", unit)
		if okD and dist and dist > FEAR_WARD_RANGE + RANGE_SLACK then return "OOR" end
		local okS, inSight = pcall(UnitXP, "inSight", "player", unit)
		if okS and inSight == false then return "LOS" end
		return nil
	end
	-- Follow distance (~28y) is the closest interact gate to a 30y spell.
	if not CheckInteractDistance(unit, 4) then return "OOR" end
	return nil
end

-- Resolve a caster/target GUID (from UNIT_CASTEVENT) to a player name: prefer the
-- roster map, fall back to SuperWoW's "GUID as unit token" (nil if unknown).
local function guidName(guid)
	if not guid then return nil end
	if nameByGuid[guid] then return nameByGuid[guid] end
	return UnitName(guid)
end

-- Each watch-list entry is in one of three states (a linear "level of involvement"):
--   * SHOWN   -- tracked, rendered as a tracker row, a WardNext priority, notified.
--   * HIDDEN  -- still a WardNext priority and still notified, but NOT rendered as a
--               tracker row (background priority you don't want cluttering the list).
--   * OFF     -- kept in the list (with its priority slot) but otherwise inert: no
--               row, no priority, no notification -- e.g. someone not tanking tonight
--               but back next raid, so you don't remove + re-add them.
-- Stored as two sets keyed by lowercased name: watchDisabled (OFF) and watchHidden
-- (HIDDEN); OFF wins if both are somehow set. Both default empty so old lists upgrade.
local function watchState(name)
	local key = string.lower(name)
	if FearWardHelperDB.watchDisabled[key] then return "off" end
	if FearWardHelperDB.watchHidden[key] then return "hidden" end
	return "shown"
end

-- Whether the entry participates in tracking (priority/notify) at all -- true for
-- both SHOWN and HIDDEN, false only for OFF.
local function isWatchEnabled(name)
	return watchState(name) ~= "off"
end

-- The actual roster name for a watched entry that is enabled (SHOWN or HIDDEN) and
-- present in the group (nil otherwise). The gate WardNext + notifications share, so
-- an OFF name silently drops out of both; HIDDEN names stay in (display gates below).
local function activeWatchTarget(name)
	if not isWatchEnabled(name) then return nil end
	return presentLower[string.lower(name)]
end

-- The actual roster name for an entry that should be RENDERED as a tracker row:
-- active, present AND not hidden. Hidden entries are active targets that simply
-- don't draw a row (so rebuildRows / the visibleTargets count use this, not the gate
-- above). Returns the roster name or nil.
local function visibleWatchTarget(name)
	if watchState(name) ~= "shown" then return nil end
	return presentLower[string.lower(name)]
end

----------------------------------------------------------------------------
-- Tracking state setters (shared by local observation and sync)
----------------------------------------------------------------------------

local function startCD(name)
	if name then
		cdReadyAt[name] = GetTime() + FEAR_WARD_CD
		cdNotifyPending[name] = true   -- fire a "ready" notification when this elapses
	end
end

-- Mark a player warded until `expiry` (a Unix time() epoch), defaulting to a full
-- duration from now. Epoch (not GetTime) so the timer persists across /reload via
-- SavedVariables -- wardExpiresAt *is* FearWardHelperDB.wards, so writes are saved.
local function setWard(name, expiry)
	if name then
		wardExpiresAt[name] = expiry or (time() + FEAR_WARD_DURATION)
		wardPresent[name] = true
	end
end

-- Whether `name` is currently warded, plus their expiry epoch (or nil). A scan's
-- explicit true/false wins; an unscanned (nil) player is judged by the timer alone
-- (so a restored or out-of-range ward still shows). An elapsed timer = not warded.
local function isWarded(name)
	local exp = wardExpiresAt[name]
	local flag = wardPresent[name]
	local now = time()
	local present
	if flag == nil then present = (exp and exp > now) and true or false
	else present = flag end
	if present and exp and exp <= now then present = false end
	return present, exp
end

-- Mark a player's ward gone (explicitly absent), dropping its timer. Used by the
-- buff-removed event so a consumed/cancelled/expired ward clears instantly.
local function clearWard(name)
	if name then
		wardExpiresAt[name] = nil
		wardPresent[name] = false
	end
end

-- WardNext eligibility: a player needs a (re)ward if they're unwarded, OR warded but
-- with less than the configured low-duration threshold (lowDuration) remaining -- so a
-- soon-to-expire ward is topped off early rather than waiting for it to drop. A
-- threshold of 0 disables that early tier (only truly-unwarded players qualify). Shares
-- isWarded's timer logic; a "warded, no timer" (nil exp) entry is never low-duration.
local function needsWard(name)
	local present, exp = isWarded(name)
	if not present then return true end
	local low = FearWardHelperDB.lowDuration or 0
	return low > 0 and exp ~= nil and (exp - time()) < low
end

----------------------------------------------------------------------------
-- Notifications
--
-- A floating message area (FearWardHelper_Notify) showing transient lines that
-- fade out after a configurable delay. Two kinds, each independently toggleable:
--   * CAST  -- "<source>: Fear Ward > <target>" (target class-coloured); fired from
--             the cast paths (UNIT_CASTEVENT + sync) which carry source AND target.
--             An in-range addon priest fires both paths for one cast, so a tiny
--             recentApply window dedups the pair. Tracked targets only, unless
--             notifyApplyUntracked.
--   * LOSS  -- a tracked target losing Fear Ward. An AoE fear strips several at once,
--             so non-expiry losses are batched over a short window and condensed to
--             "<top priority> [and N more] lost Fear Ward"; a natural 10-min expiry
--             (predicted timer ~0 at removal) is reported on its own as "expired".
-- The notify frame is moveable + anchorable like the trackers but has no resize grip
-- -- its "size" is the font size. It is shown whenever loaded (a faint grab box +
-- handle while unlocked, fully transparent while locked + empty), so it can be placed
-- any time; only the message *generation* is gated on being active.
----------------------------------------------------------------------------

local NOTIFY_MAX   = 6     -- max simultaneous lines (a burst can't run away)
local NOTIFY_FADE  = 1.0   -- seconds of fade-out at the end of a line's life
local NOTIFY_BATCH = 0.4   -- seconds to gather simultaneous losses before condensing

local notifyLines  = {}    -- pool of font strings on the notify frame, by display row
local notifications = {}   -- active lines, newest first: { born = GetTime(), text = }
local recentApply  = {}    -- caster..":"..target -> GetTime(); dedups observed+synced
local pendingLosses = {}   -- set of names whose loss is waiting to be condensed
local lossFlushAt          -- GetTime() to emit the batched loss line, or nil
local lowNotified  = {}    -- name -> true once we've announced its ward dropping below
                           -- lowDuration; reset when it rises back above (so a re-ward
                           -- re-arms the warning). Tracks the crossing edge regardless of
                           -- the notifyLowDuration toggle (cf. cdNotifyPending).

-- Wrap a notification's non-name text in the default label colour (yellow); player
-- names are class-coloured by colorName, everything else reads as this.
local NOTIFY_LABEL_COLOR = "ffffd200"
local function notifyLabel(text)
	return "|c" .. NOTIFY_LABEL_COLOR .. text .. "|r"
end

-- A pooled notification font string for display row i (created lazily).
local function getNotifyLine(i)
	if not notifyLines[i] then
		notifyLines[i] = FearWardHelper_Notify:CreateFontString(nil, "OVERLAY")
	end
	return notifyLines[i]
end

-- The notify frame's anchor point doubles as the notification *alignment* + growth
-- direction (so the area "fills" away from the corner you pinned it to):
--   horizontal -- LEFT -> left-aligned, RIGHT -> right-aligned, else centred;
--   vertical   -- TOP -> grow down, BOTTOM or vertical-centre -> grow up.
-- Returns the line anchor point (a valid SetPoint corner/edge), the JustifyH, and the
-- vertical offset sign (newest line sits at the anchor edge, older ones stack away).
local function notifyAlignment()
	local point = FearWardHelperDB.notifyFrame.point or "CENTER"
	local hEdge, justify
	if string.find(point, "LEFT") then hEdge, justify = "LEFT", "LEFT"
	elseif string.find(point, "RIGHT") then hEdge, justify = "RIGHT", "RIGHT"
	else hEdge, justify = "", "CENTER" end
	local vEdge, grow
	if string.find(point, "TOP") then vEdge, grow = "TOP", -1   -- grow down
	else vEdge, grow = "BOTTOM", 1 end                          -- grow up (BOTTOM/centre)
	return vEdge .. hEdge, justify, grow
end

-- Inset offset (px, py) that nudges text in from whichever edges `anchor` touches, so
-- a corner-anchored line/handle clears the notify frame's border instead of escaping it.
local NOTIFY_PAD = 6
local function notifyPadOffset(anchor)
	local px, py = 0, 0
	if string.find(anchor, "LEFT") then px = NOTIFY_PAD
	elseif string.find(anchor, "RIGHT") then px = -NOTIFY_PAD end
	if string.find(anchor, "TOP") then py = -NOTIFY_PAD
	elseif string.find(anchor, "BOTTOM") then py = NOTIFY_PAD end
	return px, py
end

-- (Re)position + paint the active notifications. Newest sits at the anchor edge;
-- older lines stack away from it (direction from notifyAlignment). The font (and thus
-- line height) tracks the configurable notifyFontSize.
local function layoutNotifications()
	local size = FearWardHelperDB.notifyFontSize or 14
	local lineH = size + 4
	local anchor, justify, grow = notifyAlignment()
	local px, py = notifyPadOffset(anchor)
	local n = table.getn(notifications)
	for i = 1, n do
		local fs = getNotifyLine(i)
		fs:SetFont("Fonts\\FRIZQT__.TTF", size, "OUTLINE")
		fs:SetJustifyH(justify)
		fs:ClearAllPoints()
		fs:SetPoint(anchor, FearWardHelper_Notify, anchor, px, py + grow * (i - 1) * lineH)
		fs:SetText(notifications[i].text)
		fs:Show()
	end
	for i = n + 1, table.getn(notifyLines) do notifyLines[i]:Hide() end
end

-- Add a notification line (already colour-coded). Newest lines push older ones down;
-- past NOTIFY_MAX the oldest is dropped so a spam burst stays bounded.
local function pushNotification(text)
	table.insert(notifications, 1, { born = GetTime(), text = text })
	while table.getn(notifications) > NOTIFY_MAX do table.remove(notifications) end
	layoutNotifications()
end

-- Per-frame: age out expired lines and fade the rest over their last NOTIFY_FADE
-- seconds. Called every OnUpdate tick (not throttled) so the fade is smooth.
local function updateNotifications()
	local now = GetTime()
	local dur = FearWardHelperDB.notifyDuration or 5
	local removed = false
	local i = 1
	while i <= table.getn(notifications) do
		if now - notifications[i].born >= dur then
			table.remove(notifications, i)
			removed = true
		else
			i = i + 1
		end
	end
	if removed then layoutNotifications() end
	for j = 1, table.getn(notifications) do
		local fs = notifyLines[j]
		if fs then
			local age = now - notifications[j].born
			local a = 1
			if age > dur - NOTIFY_FADE then
				a = (dur - age) / NOTIFY_FADE
				if a < 0 then a = 0 end
			end
			fs:SetAlpha(a)
		end
	end
end

-- Drop all transient notification state (lines + pending batch). Called when the
-- tracker deactivates so a re-group starts clean.
local function clearNotifications()
	notifications = {}
	pendingLosses = {}
	lossFlushAt = nil
	recentApply = {}
	lowNotified = {}
	layoutNotifications()
end

-- Whether a Fear Ward gain/loss on `name` should notify. We only ever announce about
-- someone actually in the raid/party -- never an outsider we merely see in combat-log
-- range -- and this holds even for the include-untracked case. A tracked (enabled +
-- present) name always qualifies; an untracked one only when notifyApplyUntracked is
-- on AND they are in the group.
local function notifyAllowed(name)
	if not name then return false end
	if activeWatchTarget(name) then return true end
	if not FearWardHelperDB.notifyApplyUntracked then return false end
	return presentLower[string.lower(name)] ~= nil
end

-- A Fear Ward cast we saw (locally or over sync): announce source -> target if
-- enabled, deduping the observed+synced double-fire for one cast.
local function notifyApply(caster, target)
	if not FearWardHelperDB.notifyApply then return end
	if not caster or not target then return end
	if not notifyAllowed(target) then return end
	local key = caster .. ":" .. target
	local now = GetTime()
	if recentApply[key] and now - recentApply[key] < 1.5 then return end
	recentApply[key] = now
	pushNotification(notifyLabel("Fear Ward gained by ") .. colorName(target)
		.. notifyLabel(" (") .. colorName(caster) .. notifyLabel(")"))
end

-- Emit the condensed loss line for everyone who lost Fear Ward inside the batch
-- window, headlined by the highest-priority (lowest watch index) name.
local function flushLosses()
	lossFlushAt = nil
	local names = {}
	for name in pairs(pendingLosses) do table.insert(names, name) end
	pendingLosses = {}
	local n = table.getn(names)
	if n == 0 then return end
	local best, bestIdx
	for i = 1, n do
		local idx = findWatchIndex(names[i]) or 9999
		if not bestIdx or idx < bestIdx then bestIdx = idx; best = names[i] end
	end
	if n == 1 then
		pushNotification(notifyLabel("Fear Ward lost by ") .. colorName(best))
	else
		pushNotification(notifyLabel("Fear Ward lost by ") .. colorName(best)
			.. notifyLabel(" (+" .. (n - 1) .. " more)"))
	end
end

-- A Fear Ward just dropped (BUFF_REMOVED) on someone in the group (notifyAllowed --
-- tracked, or untracked + in-group when enabled). A predicted expiry (the timer was
-- due ~now) is its own "expired" line; any earlier loss is a fear/cancel, which we
-- batch (AoE fears strip several at once) -- see flushLosses.
local function notifyLoss(name)
	if not FearWardHelperDB.notifyLoss then return end
	if not notifyAllowed(name) then return end
	local display = presentLower[string.lower(name)] or name
	local exp = wardExpiresAt[name]
	if exp and exp <= time() + 1 then
		pushNotification(notifyLabel("Fear Ward expired on ") .. colorName(display))
	else
		pendingLosses[display] = true
		if not lossFlushAt then lossFlushAt = GetTime() + NOTIFY_BATCH end
	end
end

-- Announce a priest's Fear Ward coming off cooldown. Your own ready is gated on
-- notifyCDReady ("Fear Ward ready"); another group priest's on notifyCDReadyGroup
-- ("Fear Ward ready (<priest>)"). Non-group priests we merely observed are skipped.
local function notifyCDReadyFor(name)
	if name == playerName then
		if FearWardHelperDB.notifyCDReady then
			pushNotification(notifyLabel("Fear Ward ready"))
		end
	elseif FearWardHelperDB.notifyCDReadyGroup and presentLower[string.lower(name)] then
		pushNotification(notifyLabel("Fear Ward ready (") .. colorName(name) .. notifyLabel(")"))
	end
end

-- Poll pending cooldowns and fire the "ready" notification as each elapses (once).
-- Pending is cleared on elapse regardless of the config gates, so a disabled toggle
-- doesn't leave stale entries; a gate flipped on mid-cooldown still announces.
local function checkCDReady()
	local now = GetTime()
	for name in pairs(cdNotifyPending) do
		local ready = cdReadyAt[name]
		if not ready or now >= ready then
			cdNotifyPending[name] = nil
			notifyCDReadyFor(name)
		end
	end
end

-- Poll warded targets and announce once when one crosses below the lowDuration
-- threshold ("running low" -- top them off soon). The crossing edge is tracked in
-- lowNotified regardless of the notifyLowDuration toggle (so toggling it on mid-low
-- doesn't retroactively fire for every already-low ward, and a re-ward that lifts the
-- timer back above the threshold re-arms the warning). Only names notifyAllowed -- a
-- tracked active target, or an untracked in-group member when notifyApplyUntracked --
-- actually push a line. A 0 threshold disables the feature and forgets all crossings.
local function checkLowDuration()
	local low = FearWardHelperDB.lowDuration or 0
	if low <= 0 then
		if next(lowNotified) then lowNotified = {} end
		return
	end
	local now = time()
	for name, exp in pairs(wardExpiresAt) do
		local remaining = exp - now
		if remaining > 0 and remaining < low then
			if not lowNotified[name] then
				lowNotified[name] = true
				if FearWardHelperDB.notifyLowDuration and notifyAllowed(name) then
					local display = presentLower[string.lower(name)] or name
					pushNotification(notifyLabel("Fear Ward running low on ") .. colorName(display))
				end
			end
		else
			lowNotified[name] = nil
		end
	end
end

----------------------------------------------------------------------------
-- Sync (broadcast our own Fear Ward casts; apply others')
--
-- One tiny addon message per cast ("cast <target>"), so no throttling library is
-- needed. Receivers start the sender's cooldown and mark the target warded. This
-- only fills gaps -- casts you can see are already handled by local observation,
-- and the two paths call the same idempotent setters, so duplicates are harmless.
----------------------------------------------------------------------------

local function broadcastCast(target)
	if not SendAddonMessage then return end
	local channel
	if GetNumRaidMembers() > 0 then channel = "RAID"
	elseif GetNumPartyMembers() > 0 then channel = "PARTY" end
	if channel then
		SendAddonMessage(ADDON_PREFIX, "cast " .. (target or "-"), channel)
	end
end

local function handleAddonMessage()
	-- arg1 prefix, arg2 message, arg3 channel, arg4 sender.
	if arg1 ~= ADDON_PREFIX then return end
	if arg4 == playerName then return end   -- our own echo; handled locally already
	startCD(arg4)
	local _, _, target = string.find(arg2 or "", "^cast%s+(.+)$")
	if target and target ~= "-" then
		setWard(target)
		notifyApply(arg4, target)   -- arg4 = sender = the casting priest
	end
end

----------------------------------------------------------------------------
-- Cast detection (SuperWoW UNIT_CASTEVENT)
----------------------------------------------------------------------------

local function handleCast()
	-- Cheapest possible filter first: ignore every cast that isn't Fear Ward.
	if arg4 ~= FEAR_WARD_ID then return end
	-- Fear Ward is instant, so it emits "CAST" (no "START") when it goes off.
	if arg3 ~= "CAST" then return end
	if not playerGUID then local _, g = UnitExists("player"); playerGUID = g end

	local caster = guidName(arg1)
	if not caster then return end
	startCD(caster)

	local target = guidName(arg2)
	if target then setWard(target) end
	notifyApply(caster, target)

	-- Share our own casts so out-of-range priests' clients learn the cooldown.
	if arg1 == playerGUID then broadcastCast(target) end
end

-- Buff gain/loss, via this client's combat-log events BUFF_ADDED_*/BUFF_REMOVED_*
-- (arg1 = unit GUID, arg3 = spell id). Filtered to Fear Ward. This is the precise,
-- event-driven ward signal that the 0.25s poll only approximates:
--   ADDED   -> applied or REFRESHED right now; Fear Ward's duration is a fixed 10
--              min, so an exact application time means an exact countdown.
--   REMOVED -> gone right now for ANY reason (a fear consumed it, the player
--              cancelled it, or it expired) -> clear instantly, no poll lag.
-- The events only reach combat-log range, same as the cast event / buff scan; a
-- ward applied out of sight still falls back to the poll + persisted prediction.
local function handleBuffEvent(added)
	if tonumber(arg3) ~= FEAR_WARD_ID then return end
	local name = guidName(arg1)
	if not name then return end
	if added then
		setWard(name)
	else
		notifyLoss(name)   -- reads the predicted timer before clearWard wipes it
		clearWard(name)
	end
end

----------------------------------------------------------------------------
-- Cast helper (Priest + knows Fear Ward only)
----------------------------------------------------------------------------

-- Cast Fear Ward on `unit` without losing the current target. On a Nampower
-- client CastSpellByName takes a unit parameter directly; otherwise fall back to
-- the AutoSelfCast-off + SpellTargetUnit dance (cf. pfUI mouseover).
local function castOn(unit)
	if not unit or not UnitExists(unit) or not fearWardName then return end
	-- Refuse an unreachable target (out of object range -- a different zone or just
	-- very far): the cast can't land, and some client paths silently retarget us and
	-- ward ourselves instead. The hover row already flags this as "OOR".
	if not UnitIsVisible(unit) then return end
	if GetNampowerVersion then
		CastSpellByName(fearWardName, unit)
		return
	end
	local selfcast = GetCVar("AutoSelfCast")
	if selfcast ~= "0" then SetCVar("AutoSelfCast", "0") end
	CastSpellByName(fearWardName)
	if SpellIsTargeting() then SpellTargetUnit(unit) end
	if SpellIsTargeting() then SpellStopTargeting() end
	if selfcast ~= "0" then SetCVar("AutoSelfCast", selfcast) end
end

-- Cast Fear Ward on a named player if they are in the group. Macro-callable.
function FearWardHelper_Ward(name)
	if not canCast then
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: you can't cast Fear Ward (Priest who knows it only).")
		return
	end
	local actual = presentLower[string.lower(name or "")]
	local unit = actual and unitByName[actual]
	if not unit then
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: " .. tostring(name) .. " is not in your group.")
		return
	end
	-- Don't waste a Fear Ward (and its cooldown) topping off a target who's still safely
	-- warded: only (re)cast when they actually need it -- unwarded, or warded with less
	-- than the low-duration threshold left (needsWard, the same gate WardNext uses).
	if not needsWard(actual) then
		local _, exp = isWarded(actual)
		local left = exp and (exp - time())
		local msg = "FearWardHelper: " .. actual .. " already has Fear Ward"
		if left and left > 0 then msg = msg .. " (" .. fmtTime(left) .. " left)" end
		DEFAULT_CHAT_FRAME:AddMessage(msg .. ".")
		return
	end
	castOn(unit)
end

-- Exactly castOn's hard preconditions plus a clear range/LOS: used by the SOFT tiers to
-- skip an uncastable candidate (so they fall through instead of returning after a no-op).
-- castBlock alone isn't enough -- it returns nil for a missing unit.
local function reachable(name)
	local unit = unitByName[name]
	return unit and UnitExists(unit) and UnitIsVisible(unit) and not castBlock(unit)
end

-- The two TRACKED WardNext tiers, shared by FearWardHelper_WardNext (which then falls
-- through to the sweep) and FearWardHelper_WardNextTracked (which stops here). "Needs a
-- ward" (needsWard) means unwarded OR warded with less than the lowDuration threshold
-- left, so a soon-to-expire ward is topped off early.
--   1. SHOWN tracked (priority order) -- HARD: the highest-priority present+unwarded
--      shown target is authoritative. If it's unreachable we BLOCK (cast nobody) and
--      optionally report a failed cast, rather than warding someone lower -- you want
--      to know your top tank can't be reached. This is the only tier that blocks.
--   2. HIDDEN tracked (priority order) -- SOFT: a preferred unit before the sweep, but
--      an unreachable one is skipped (never blocks).
-- Returns true if it handled the request (a cast went out, OR tier 1 blocked on an
-- unreachable shown target); false only when nothing tracked needed a ward, so WardNext
-- may continue to the sweep.
local function wardNextTrackedTiers()
	local wl = FearWardHelperDB.watchList
	local n = table.getn(wl)

	-- Tier 1: shown tracked.
	for i = 1, n do
		local actual = visibleWatchTarget(wl[i])
		if actual and needsWard(actual) then
			local block = castBlock(unitByName[actual])
			if not block then
				castOn(unitByName[actual])
			elseif FearWardHelperDB.notifyCastFail then
				local why = (block == "LOS") and "no line of sight" or "out of range"
				pushNotification(notifyLabel("Fear Ward blocked: ") .. colorName(actual)
					.. notifyLabel(" (" .. why .. ")"))
			end
			return true   -- shown target is authoritative: cast it or block, never fall through
		end
	end

	-- Tier 2: hidden tracked (preferred, but skip-if-unreachable).
	for i = 1, n do
		local name = wl[i]
		if watchState(name) == "hidden" then
			local actual = presentLower[string.lower(name)]
			if actual and needsWard(actual) and reachable(actual) then
				castOn(unitByName[actual])
				return true
			end
		end
	end

	return false
end

-- Ward the next player. Macro-callable -- the keyboard-driven workflow. Runs the two
-- tracked tiers (see wardNextTrackedTiers) and, if neither warded anyone, sweeps:
--   3. SWEEP (wardNextSweep) -- any present group member not on the watch-list, in
--      roster order: once here we just want *a* ward out, so unreachable ones are
--      skipped and the specific target is secondary.
function FearWardHelper_WardNext()
	if not canCast then return end
	if wardNextTrackedTiers() then return end

	-- Tier 3: sweep any unwarded, reachable group member who isn't already an enabled
	-- (shown/hidden) tracked priority -- so untracked members AND disabled (off) watch
	-- entries are both eligible (off = "don't prioritize", not "never ward"); only the
	-- shown/hidden entries are skipped here since tiers 1/2 already covered them.
	-- Candidates are taken by class in sweepClassOrder (a disabled class is ignored
	-- entirely), then roster order within a class.
	if FearWardHelperDB.wardNextSweep then
		local order = FearWardHelperDB.sweepClassOrder
		local disabled = FearWardHelperDB.sweepClassDisabled
		for c = 1, table.getn(order) do
			local class = order[c]
			if not disabled[class] then
				for i = 1, table.getn(roster) do
					local name = roster[i]
					if classByName[name] == class then
						local enabledTracked = findWatchIndex(name) and isWatchEnabled(name)
						if not enabledTracked and needsWard(name) and reachable(name) then
							castOn(unitByName[name])
							return
						end
					end
				end
			end
		end
	end
end

-- Ward the next TRACKED player. Like FearWardHelper_WardNext but limited to the tracked
-- tiers (shown HARD + hidden SOFT) -- it INTENTIONALLY never sweeps untracked/off group
-- members, regardless of the wardNextSweep config. For a "top off my watch-list only"
-- keybind that won't spend a Fear Ward on someone you didn't ask to track.
function FearWardHelper_WardNextTracked()
	if not canCast then return end
	wardNextTrackedTiers()
end

----------------------------------------------------------------------------
-- Rows / display
----------------------------------------------------------------------------

-- Direction-arrow geometry / facing helpers (used by refreshHover below) --------

-- The minimap player-arrow Model, whose facing tracks the player's heading on a
-- non-rotating minimap (the arrow rotates; the map stays north-up). Found once by
-- scanning Minimap children for the Model whose path is exactly the player arrow.
-- The match is the full path segment "minimap\minimaparrow" (NOT a bare
-- "minimaparrow", which also matches the static "Rotating-MinimapArrow" decoy
-- models this client parents to the minimap -- they sit at facing 0 and would
-- freeze the heading). Locale-free, like pfQuest's compat/client.lua.
local minimapArrow
local function findMinimapArrow()
	if minimapArrow then return minimapArrow end   -- cache only a successful find
	if not Minimap then return nil end
	local kids = { Minimap:GetChildren() }
	for _, v in pairs(kids) do
		if v.IsObjectType and v:IsObjectType("Model") and v.GetModel and not v:GetName() then
			local ok, m = pcall(function() return v:GetModel() end)
			if ok and m and string.find(string.lower(m), "minimap\\minimaparrow", 1, true) then
				minimapArrow = v
				return v
			end
		end
	end
	return nil
end

-- Player heading in radians (north-up frame). Prefer a real GetPlayerFacing if the
-- client exposes one; otherwise read it off the minimap -- the compass ring on a
-- rotating minimap, else the player-arrow model. nil if none is available.
local function playerFacing()
	if GetPlayerFacing then return GetPlayerFacing() end
	-- GetCVar throws on this client for an unknown CVar, so pcall it; a missing
	-- rotateMinimap CVar just means "not rotating" -> read the player-arrow model.
	local ok, rot = pcall(GetCVar, "rotateMinimap")
	if ok and rot == "1" then
		if MiniMapCompassRing then return -MiniMapCompassRing:GetFacing() end
		return nil
	end
	local arrow = findMinimapArrow()
	if arrow then return arrow:GetFacing() end
	return nil
end

-- Distance (yards) to `unit` IF it's in object range but out of cast reach -- i.e.
-- the "chase me" case -- else nil. Also returns the world delta (dx, dy) so the
-- bearing can be derived without a second UnitPosition pair. World coords from
-- UnitPosition (+X north / +Y west) give true yards with no map-aspect fudge. This is
-- the single OOR gate for the hover (gate + number + arrow all from here), so the
-- countdown reaches 0 exactly at the flip; RANGE_SLACK is the centre-to-centre vs
-- edge-to-edge estimate that puts that flip near the true cast range.
local function oorDistance(unit)
	if not trackable(unit) then return nil end
	local px, py, tx, ty = worldPos(unit)
	if not px then return nil end
	local dx, dy = tx - px, ty - py
	local d = math.sqrt(dx * dx + dy * dy)
	if d <= FEAR_WARD_RANGE + RANGE_SLACK then return nil end
	return d, dx, dy
end

-- Relative bearing (radians, 0 = straight ahead) for a world delta (dx, dy), or nil
-- when the heading is unknown. Takes the delta directly (the caller already has it
-- from oorDistance) so the arrow uses the same UnitPosition vector as the distance.
local function arrowAngle(dx, dy)
	if dx == 0 and dy == 0 then return nil end
	local face = playerFacing()
	if not face then return nil end
	return ARROW_SIGN * (math.atan2(dy, dx) - face) + ARROW_OFFSET
end

-- Point a row's arrow texture along `rel` (radians) by selecting the matching frame
-- in the pre-rotated atlas.
local function setArrowCell(tex, rel)
	local cell = math.floor(rel / (2 * math.pi) * ARROW_FRAMES + 0.5)
	cell = cell - math.floor(cell / ARROW_FRAMES) * ARROW_FRAMES   -- mod, negatives ok
	local col = cell - math.floor(cell / ARROW_COLS) * ARROW_COLS
	local row = math.floor(cell / ARROW_COLS)
	local xs = (col * ARROW_CW) / ARROW_SHEET
	local ys = (row * ARROW_CH) / ARROW_SHEET
	tex:SetTexCoord(xs, xs + ARROW_CW / ARROW_SHEET, ys, ys + ARROW_CH / ARROW_SHEET)
end

-- World delta (dx, dy) from the player to a `unit` with a known position, else nil.
-- Unlike oorDistance this has no range gate -- used for the in-range LOS case, where
-- the unit is close but sight-blocked and we still want to point the way.
local function unitDelta(unit)
	if not trackable(unit) then return nil end
	local px, py, tx, ty = worldPos(unit)
	if not px then return nil end
	return tx - px, ty - py
end

-- Point a row's (red) direction arrow at the world delta (dx, dy), or hide it when
-- the delta or the heading is unavailable.
local function showRowArrow(row, dx, dy)
	local rel = dx and arrowAngle(dx, dy)
	if rel then
		setArrowCell(row.arrow, rel)
		row.arrow:SetVertexColor(1, 0.3, 0.3)
		row.arrow:Show()
	else
		row.arrow:Hide()
	end
end

-- Cast helper only: paint the hovered watch row's range/LOS in red, with a direction
-- arrow pointing the way. Out of cast range -> the yards still to close + arrow; LOS
-- (in range but sight-blocked) -> "LOS" + arrow (reposition for sight); a castable
-- target -> a plain grey hover tint, no arrow. Called from the hover handlers, every
-- OnUpdate frame (so the arrow + distance track you and the target moving while the
-- mouse rests on a row) and at the end of each refreshDisplay tick. hoveredWatchRow is
-- only set when canCast, so this never runs in observer mode. Off-hover, the row keeps
-- its normal ward status / timer.
local function refreshHover()
	local row = hoveredWatchRow
	if not row then return end
	local unit = unitByName[row.pname]
	if isOffline(unit) then return end   -- leave the "Offline" status untouched
	-- One distance source (UnitPosition, via oorDistance) drives the gate, the number
	-- AND the arrow, so the "Ny" countdown reaches 0 exactly when the row flips back to
	-- its ward timer. (castBlock's UnitXP distance reads a few yards lower on this
	-- client, so gating on it while numbering with UnitPosition made the value flip
	-- ~RANGE_SLACK early.) castBlock is consulted only for what UnitPosition can't
	-- measure: no line of sight, or out of object range entirely.
	local d, dx, dy = oorDistance(unit)
	if d then
		-- Out of cast range: yards still to close (red) + direction arrow.
		row.hl:SetTexture(1, 0.15, 0.15, 0.30)
		local gap = d - (FEAR_WARD_RANGE + RANGE_SLACK)
		if gap < 0 then gap = 0 end
		row.statusFS:SetText(math.floor(gap + 0.5) .. "y")
		row.statusFS:SetTextColor(1, 0.3, 0.3)
		showRowArrow(row, dx, dy)
	else
		-- In UnitPosition cast range, or unmeasurable: fall back to castBlock for the
		-- residual no-LOS / out-of-object-range flags ("LOS"/"OOR"); else it's castable.
		local block = castBlock(unit)
		if block then
			row.hl:SetTexture(1, 0.15, 0.15, 0.30)
			row.statusFS:SetText(block)
			row.statusFS:SetTextColor(1, 0.3, 0.3)
			-- LOS = in range but sight-blocked: we still have their position, so keep
			-- pointing the way (to reposition for line of sight). "OOR" here means out
			-- of object range -- no position -- so no arrow.
			if block == "LOS" then
				showRowArrow(row, unitDelta(unit))
			else
				row.arrow:Hide()
			end
		else
			row.hl:SetTexture(1, 1, 1, 0.15)         -- normal hover tint (castable)
			row.arrow:Hide()
		end
	end
	row.hl:Show()
end

local function rowOnEnter()
	-- Observer mode (not a Priest who knows Fear Ward): rows are inert, no highlight.
	if not canCast then return end
	hoveredWatchRow = this
	refreshHover()
end

local function rowOnLeave()
	-- Nothing to undo for an inert (observer-mode) row -- its highlight never showed.
	if hoveredWatchRow ~= this then return end
	hoveredWatchRow = nil
	this.hl:Hide()
	this.arrow:Hide()
	-- Restore the row's normal ward status (refreshHover may have shown the distance/LOS).
	if refreshDisplay then refreshDisplay() end
end

-- Create a row widget (a Button for the clickable watch list, a Frame otherwise)
-- with a left "name" and right "status" font string. Positioning is deferred to
-- placeRow so a row can be re-anchored (and re-parented) when the layout changes
-- -- the merged mode hangs the watch rows off the CD frame instead of the watch frame.
local function makeRow(parent, asButton)
	local f = CreateFrame(asButton and "Button" or "Frame", nil, parent)
	f:SetHeight(ROW_H)

	local nameFS = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	nameFS:SetPoint("LEFT", f, "LEFT", 0, 0)
	nameFS:SetJustifyH("LEFT")
	f.nameFS = nameFS

	local statusFS = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	statusFS:SetPoint("RIGHT", f, "RIGHT", 0, 0)
	statusFS:SetJustifyH("RIGHT")
	f.statusFS = statusFS

	if asButton then
		f:RegisterForClicks("LeftButtonUp")
		-- Only the cast helper acts on a click; in observer mode the row is inert
		-- (no cast attempt, no error spam), matching the suppressed hover highlight.
		f:SetScript("OnClick", function() if canCast then FearWardHelper_Ward(this.pname) end end)
		-- Manually toggled highlight (not a HIGHLIGHT-layer texture) so it appears
		-- only while castable, and can turn red on hover to flag an out-of-range /
		-- no-LOS target. BACKGROUND layer keeps it behind the row text.
		local hl = f:CreateTexture(nil, "BACKGROUND")
		hl:SetAllPoints(f)
		hl:SetTexture(1, 1, 1, 0.15)
		hl:Hide()
		f.hl = hl
		f:SetScript("OnEnter", rowOnEnter)
		f:SetScript("OnLeave", rowOnLeave)
		-- Direction arrow, just left of the status text. Shown only by refreshHover,
		-- on the hovered row when the target is in object range but out of cast reach.
		local arrow = f:CreateTexture(nil, "OVERLAY")
		arrow:SetTexture(ARROW_TEXTURE)
		arrow:SetWidth(16); arrow:SetHeight(12)
		arrow:SetPoint("RIGHT", statusFS, "LEFT", -3, 0)
		arrow:Hide()
		f.arrow = arrow
	end
	return f
end

-- Anchor a row inside `parent` at vertical offset `yOff` pixels below the top.
-- Re-parents if needed (merged mode moves watch rows into the CD frame), so the
-- same pooled row works in either layout.
local function placeRow(f, parent, yOff)
	if f:GetParent() ~= parent then f:SetParent(parent) end
	f:ClearAllPoints()
	f:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -yOff)
	f:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)
end

local function getCDRow(i)
	if not cdRows[i] then cdRows[i] = makeRow(FearWardHelper_CD, false) end
	return cdRows[i]
end

local function getWatchRow(i)
	if not watchRows[i] then watchRows[i] = makeRow(FearWardHelper_Watch, true) end
	return watchRows[i]
end

-- The "Targets" sub-section header + divider line, drawn inside the CD frame in
-- merged mode so one container frames both lists. Created lazily on first merge.
local function getTargetHeader()
	local cf = FearWardHelper_CD
	if not cf.targetHeader then
		local fs = cf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetJustifyH("LEFT")
		fs:SetText("Targets")
		cf.targetHeader = fs
		local div = cf:CreateTexture(nil, "ARTWORK")
		div:SetTexture(1, 1, 1, 0.20)
		div:SetHeight(1)
		cf.targetDivider = div
	end
	return cf.targetHeader, cf.targetDivider
end

-- Fit a frame's height to a (minimum-1) row count so the title is always framed.
local function sizeFrame(frame, dbKey, rows)
	if rows < 1 then rows = 1 end
	frame:SetWidth(FearWardHelperDB[dbKey].width)
	frame:SetHeight(HEADER_H + rows * ROW_H + PAD)
end

-- Rebuild which rows exist and their (static) names. Called on roster / watch-list
-- / layout-mode changes; the per-tick status text is set by refreshDisplay.
--
-- Split mode: the CD list lives in FearWardHelper_CD and the watch list in
-- FearWardHelper_Watch -- two independent frames. Merged mode (the default) stacks both inside
-- the CD frame (CD rows, a "Targets" sub-header + divider, then the watch rows) and
-- hides the watch frame; the watch rows are re-parented into the CD frame.
local function rebuildRows()
	local merged = FearWardHelperDB.merged

	-- Cooldown rows: one per priest in the group, always in the CD frame.
	local nP = table.getn(priests)
	for i = 1, nP do
		local row = getCDRow(i)
		row.pname = priests[i].name
		row.nameFS:SetText(priests[i].name)
		row.nameFS:SetTextColor(classColor(priests[i].class))
		placeRow(row, FearWardHelper_CD, HEADER_H + (i - 1) * ROW_H)
		row:Show()
	end
	for i = nP + 1, table.getn(cdRows) do cdRows[i]:Hide() end

	-- Count how many watched names get a tracker row (present + SHOWN; hidden ones
	-- are still active priorities but draw no row, so they don't count here).
	local wl = FearWardHelperDB.watchList
	local visibleTargets = 0
	for i = 1, table.getn(wl) do
		if visibleWatchTarget(wl[i]) then visibleTargets = visibleTargets + 1 end
	end

	-- Decide where the watch section lives and where it starts vertically.
	local wParent, wYStart
	if merged then
		wParent = FearWardHelper_CD
		local ySub = HEADER_H + nP * ROW_H
		if visibleTargets > 0 then
			local gap = 4
			local header, divider = getTargetHeader()
			divider:ClearAllPoints()
			divider:SetPoint("TOPLEFT", FearWardHelper_CD, "TOPLEFT", PAD, -(ySub + gap))
			divider:SetPoint("RIGHT", FearWardHelper_CD, "RIGHT", -PAD, 0)
			header:ClearAllPoints()
			header:SetPoint("TOPLEFT", FearWardHelper_CD, "TOPLEFT", PAD, -(ySub + gap + 4))
			header:Show(); divider:Show()
			wYStart = ySub + gap + SUBHEAD_H
		else
			wYStart = ySub
			if FearWardHelper_CD.targetHeader then
				FearWardHelper_CD.targetHeader:Hide()
				FearWardHelper_CD.targetDivider:Hide()
			end
		end
	else
		wParent = FearWardHelper_Watch
		wYStart = HEADER_H
		if FearWardHelper_CD.targetHeader then
			FearWardHelper_CD.targetHeader:Hide()
			FearWardHelper_CD.targetDivider:Hide()
		end
	end

	-- Watch rows: one per watched name currently present AND shown, in priority
	-- order (hidden names are active priorities but render no row).
	local w = 0
	for i = 1, table.getn(wl) do
		local actual = visibleWatchTarget(wl[i])
		if actual then
			w = w + 1
			local row = getWatchRow(w)
			row.pname = actual
			row.nameFS:SetText(actual)
			row.nameFS:SetTextColor(classColor(classByName[actual]))
			placeRow(row, wParent, wYStart + (w - 1) * ROW_H)
			row:Show()
		end
	end
	for i = w + 1, table.getn(watchRows) do watchRows[i]:Hide() end
	watchVisible = w

	-- Size the container(s). In merged mode the CD frame spans both sections and
	-- the watch frame is hidden; in split mode each frame fits its own rows.
	local hdr = getglobal("FearWardHelper_CDHeader")
	if merged then
		if visibleTargets > 0 then
			FearWardHelper_CD:SetWidth(FearWardHelperDB.cdFrame.width)
			FearWardHelper_CD:SetHeight(wYStart + w * ROW_H + PAD)
		else
			sizeFrame(FearWardHelper_CD, "cdFrame", nP)
		end
		FearWardHelper_Watch:Hide()
		if hdr then hdr:SetText("Fear Ward") end
	else
		sizeFrame(FearWardHelper_CD, "cdFrame", nP)
		if visibleTargets > 0 then
			sizeFrame(FearWardHelper_Watch, "watchFrame", w)
			if active then FearWardHelper_Watch:Show() end
		else
			FearWardHelper_Watch:Hide()
		end
		if hdr then hdr:SetText("Fear Ward CDs") end
	end
	-- Reposition after sizing so non-TOPLEFT anchors stay correct.
	applyPosition(FearWardHelper_CD)
	if not merged then applyPosition(FearWardHelper_Watch) end
end

-- Exact remaining seconds of Fear Ward on the *player*, or nil if absent. Unlike
-- other units, the player's own buffs expose a real timer (GetPlayerBuffTimeLeft),
-- so we read the truth instead of predicting -- this is what gives us an accurate
-- self timer even for a buff that was up before login/reload. Matched by icon
-- (locale-free); the GetPlayerBuff index space is separate from UnitBuff's.
local function selfWardTimeLeft()
	if not (GetPlayerBuff and GetPlayerBuffTimeLeft and GetPlayerBuffTexture and fearWardIcon) then
		return nil
	end
	local i = 0
	while true do
		local bi = GetPlayerBuff(i, "HELPFUL")
		i = i + 1
		if bi == -1 then break end
		local tex = GetPlayerBuffTexture(bi)
		if tex and string.lower(tex) == fearWardIcon then
			return GetPlayerBuffTimeLeft(bi, "HELPFUL")
		end
	end
	return nil
end

-- Reconciliation poll (the BUFF_ADDED_*/BUFF_REMOVED_* events are the primary
-- signal; this catches anything they miss -- e.g. a buff already up before we
-- arrived). For ourselves we read the exact remaining time (selfWardTimeLeft). For
-- others UnitBuff on this client returns only icon/count/spellId (no duration), so
-- we can only confirm presence by the Fear Ward icon, and only when in buff-read
-- range (UnitIsVisible) -- otherwise UnitBuff returns nothing and we'd wrongly
-- clear a real ward, so out-of-range units keep their predicted state.
local function scanWards()
	if not fearWardIcon then return end
	for i = 1, watchVisible do
		local row = watchRows[i]
		local name = row.pname
		if name == playerName then
			local tl = selfWardTimeLeft()
			if tl and tl > 0 then
				wardPresent[name] = true
				wardExpiresAt[name] = time() + tl
			else
				wardPresent[name] = false
				wardExpiresAt[name] = nil
			end
		else
			-- Other units: this client's UnitBuff returns only icon, stack count and
			-- spell id (positions 4+ are nil) -- NO duration/timeleft. So we can only
			-- confirm presence here; the timer must come from the observed/synced cast.
			local unit = unitByName[name]
			if unit and UnitIsVisible(unit) then
				local has = false
				local j = 1
				while true do
					local tex = UnitBuff(unit, j)
					if not tex then break end
					if string.lower(tex) == fearWardIcon then has = true; break end
					j = j + 1
				end
				if has then
					-- Rising edge: if we had CONFIRMED the buff absent (wardPresent is
					-- explicitly false) and now see it, it was just applied -> start a
					-- full timer, recovering a countdown even if the cast event was
					-- missed. Never infer from nil (first-ever scan): that buff could
					-- be pre-existing with unknown remaining time, so leave it timer-less.
					if wardPresent[name] == false then
						local now = time()
						if not wardExpiresAt[name] or wardExpiresAt[name] <= now then
							wardExpiresAt[name] = now + FEAR_WARD_DURATION
						end
					end
					wardPresent[name] = true
				else
					wardPresent[name] = false
					wardExpiresAt[name] = nil
				end
			end
		end
	end
end

-- Update the (dynamic) status text/colour of every shown row.
refreshDisplay = function()
	local now = GetTime()
	for i = 1, table.getn(priests) do
		local row = cdRows[i]
		if isOffline(priests[i].unit) then
			row.statusFS:SetText("Offline")
			row.statusFS:SetTextColor(0.6, 0.6, 0.6)  -- disconnected
		else
			local ready = cdReadyAt[row.pname]
			if ready and ready > now then
				row.statusFS:SetText(fmtTime(ready - now))
				row.statusFS:SetTextColor(1, 0.4, 0.4)   -- on cooldown
			else
				row.statusFS:SetText("Ready")
				row.statusFS:SetTextColor(0.4, 1, 0.4)   -- available
			end
		end
	end
	local tnow = time()
	for i = 1, watchVisible do
		local row = watchRows[i]
		if isOffline(unitByName[row.pname]) then
			row.statusFS:SetText("Offline")
			row.statusFS:SetTextColor(0.6, 0.6, 0.6)  -- disconnected
		else
			local present, exp = isWarded(row.pname)
			if present then
				row.statusFS:SetText(exp and fmtTime(exp - tnow) or "warded")
				local low = FearWardHelperDB.lowDuration or 0
				if low > 0 and exp and (exp - tnow) < low then
					row.statusFS:SetTextColor(1, 0.6, 0)     -- orange: low duration left (top off soon)
				else
					row.statusFS:SetTextColor(0.4, 1, 0.4)   -- green: well-warded
				end
			else
				row.statusFS:SetText("--")
				row.statusFS:SetTextColor(1, 0.4, 0.4)
			end
		end
	end
	-- Overlay the hovered row's range/LOS over its ward status (cast helper only).
	refreshHover()
end

-- Driver: per-frame hover refresh (smooth arrow + live distance on the hovered row)
-- + throttled buff scan / display refresh. Bound only while active.
function FearWardHelper_OnUpdate()
	refreshHover()
	this.tick = (this.tick or 0) + arg1
	if this.tick < 0.25 then return end
	this.tick = 0
	scanWards()
	checkCDReady()
	checkLowDuration()
	refreshDisplay()
end

-- Notification driver, bound to the always-shown notify frame (not gated on active)
-- so a test line fades even while solo and a fade in progress finishes after a fight.
-- Cheap when idle: the active-line list is normally empty. Loss batching is flushed
-- here too; pendingLosses is only ever populated while active, so it's a no-op idle.
function FearWardHelper_Notify_OnUpdate()
	if not FearWardHelperDB then return end   -- ticks before VARIABLES_LOADED
	updateNotifications()
	if lossFlushAt and GetTime() >= lossFlushAt then flushLosses() end
end

----------------------------------------------------------------------------
-- Frame layout / persistence
----------------------------------------------------------------------------

-- Paint a frame's background at the configured opacity. Maps the slider 1:1 to the
-- backdrop alpha (lock state no longer dims it -- the grip's visibility is the
-- lock cue now -- so 100% is genuinely opaque).
local function applyBackdropAlpha(frame)
	-- The notify frame has no persistent box: a faint grab backdrop + handle while
	-- unlocked (so it can be positioned), fully transparent once locked so the
	-- notification lines float on their own. (bgOpacity is for the two trackers.)
	if frame.dbKey == "notifyFrame" then
		local locked = FearWardHelperDB.notifyFrame.locked
		frame:SetBackdropColor(0, 0, 0, locked and 0 or 0.6)
		frame:SetBackdropBorderColor(1, 1, 1, locked and 0 or 0.5)
		local handle = getglobal(frame:GetName() .. "Handle")
		if handle then
			-- Align the handle to the notification anchor edge so it previews exactly
			-- where (and how aligned) notifications will appear while positioning.
			local anchor, justify = notifyAlignment()
			local px, py = notifyPadOffset(anchor)
			handle:ClearAllPoints()
			handle:SetPoint(anchor, frame, anchor, px, py)
			handle:SetJustifyH(justify)
			if locked then handle:Hide() else handle:Show() end
		end
		return
	end
	local base = FearWardHelperDB.bgOpacity
	if base == nil then base = 0.8 end
	frame:SetBackdropColor(0, 0, 0, base)
end

local function setLocked(frame, locked)
	local d = FearWardHelperDB[frame.dbKey]
	d.locked = locked
	frame:EnableMouse(not locked)
	applyBackdropAlpha(frame)
	-- The width grip is only interactive (and only shown) while unlocked. The notify
	-- frame has no grip (its "size" is the font size), so guard the lookup.
	local grip = getglobal(frame:GetName() .. "ResizeGrip")
	if grip then if locked then grip:Hide() else grip:Show() end end
end

-- Set the shared background opacity (0-1) and repaint both frames.
local function setBgOpacity(n)
	if not n then return end
	if n < 0 then n = 0 elseif n > 1 then n = 1 end
	FearWardHelperDB.bgOpacity = n
	applyBackdropAlpha(FearWardHelper_CD)
	applyBackdropAlpha(FearWardHelper_Watch)
	if refreshConfig then refreshConfig() end
end

-- Anchor-fraction helper: returns (fx, fy) where 0=left/bottom, 0.5=center, 1=right/top.
local function anchorFractions(point)
	local fx, fy
	if string.find(point, "LEFT") then fx = 0
	elseif string.find(point, "RIGHT") then fx = 1
	else fx = 0.5 end
	if string.find(point, "TOP") then fy = 1
	elseif string.find(point, "BOTTOM") then fy = 0
	else fy = 0.5 end
	return fx, fy
end

-- This client's SetPoint mis-positions non-TOPLEFT frame anchors, so we always
-- set TOPLEFT and compute the offset from the user-facing anchor stored in the DB.
applyPosition = function(frame)
	local d = FearWardHelperDB[frame.dbKey]
	local fx, fy = anchorFractions(d.point)
	local s = d.scale or 1
	local pw, ph = UIParent:GetWidth(), UIParent:GetHeight()
	local fw = frame:GetWidth() or d.width or 150
	local fh = frame:GetHeight() or 80
	local tlx = fx * pw / s + d.x - fx * fw
	local tly = -(1 - fy) * ph / s + d.y + (1 - fy) * fh
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", tlx, tly)
end

-- Inverse of applyPosition: read the frame's live TOPLEFT point and store it back
-- as the user-facing anchor coords in the DB. Shared by the drag- and resize-stop
-- handlers so the (sign-sensitive) conversion lives in exactly one place.
local function storeFramePos(frame)
	local d = FearWardHelperDB[frame.dbKey]
	local _, _, _, tlx, tly = frame:GetPoint()
	local fx, fy = anchorFractions(d.point)
	local s = d.scale or 1
	local pw, ph = UIParent:GetWidth(), UIParent:GetHeight()
	local fw = frame:GetWidth() or d.width or 150
	local fh = frame:GetHeight() or 80
	d.x = tlx - fx * pw / s + fx * fw
	d.y = tly + (1 - fy) * ph / s - (1 - fy) * fh
end

local function applyFrame(frame)
	applyPosition(frame)
	local d = FearWardHelperDB[frame.dbKey]
	frame:SetScale(d.scale or 1)
	setLocked(frame, d.locked)
end

function FearWardHelper_OnDragStart()
	if not FearWardHelperDB[this.dbKey].locked then this:StartMoving() end
end

function FearWardHelper_OnDragStop()
	this:StopMovingOrSizing()
	storeFramePos(this)
	if refreshConfig then refreshConfig() end
end

-- Width-only resize from the bottom-right grip. StartSizing("RIGHT") moves only
-- the right edge (height is content-driven, set by sizeFrame), so no height clamp
-- is needed. `this` is the grip button; its parent is the frame.
function FearWardHelper_StartSizing()
	this:GetParent():StartSizing("RIGHT")
end

function FearWardHelper_StopSizing()
	local f = this:GetParent()
	f:StopMovingOrSizing()
	local d = FearWardHelperDB[f.dbKey]
	d.width = f:GetWidth()
	storeFramePos(f)
	applyFrame(f)
	if active then rebuildRows(); refreshDisplay() end
	if refreshConfig then refreshConfig() end
end

----------------------------------------------------------------------------
-- Activation (live while grouped, or always if showWhenSolo)
----------------------------------------------------------------------------

local function setActive(shouldBeActive)
	if shouldBeActive == active then return end
	active = shouldBeActive
	if active then
		if superWoW() then
			FearWardHelper_CD:RegisterEvent("UNIT_CASTEVENT")
			-- Event-driven ward gain/loss (this client's combat-log events); GUID
			-- resolution leans on the SuperWoW roster, so gate them the same way.
			FearWardHelper_CD:RegisterEvent("BUFF_ADDED_SELF")
			FearWardHelper_CD:RegisterEvent("BUFF_ADDED_OTHER")
			FearWardHelper_CD:RegisterEvent("BUFF_REMOVED_SELF")
			FearWardHelper_CD:RegisterEvent("BUFF_REMOVED_OTHER")
		elseif not warnedNoSuperWoW then
			warnedNoSuperWoW = true
			DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: SuperWoW not detected -- live cast tracking off; cast helper and ward scan still work.")
		end
		FearWardHelper_CD:RegisterEvent("CHAT_MSG_ADDON")
		FearWardHelper_CD:SetScript("OnUpdate", FearWardHelper_OnUpdate)
		FearWardHelper_CD:Show()
		-- The watch frame is its own window in split mode; in merged mode the watch
		-- rows live in the CD frame and this frame stays hidden (rebuildRows enforces).
		if not FearWardHelperDB.merged then FearWardHelper_Watch:Show() end
	else
		FearWardHelper_CD:UnregisterEvent("UNIT_CASTEVENT")
		FearWardHelper_CD:UnregisterEvent("BUFF_ADDED_SELF")
		FearWardHelper_CD:UnregisterEvent("BUFF_ADDED_OTHER")
		FearWardHelper_CD:UnregisterEvent("BUFF_REMOVED_SELF")
		FearWardHelper_CD:UnregisterEvent("BUFF_REMOVED_OTHER")
		FearWardHelper_CD:UnregisterEvent("CHAT_MSG_ADDON")
		FearWardHelper_CD:SetScript("OnUpdate", nil)
		FearWardHelper_CD:Hide()
		FearWardHelper_Watch:Hide()
		-- Drop transient tracking so a re-group starts clean. Ward *timers* are not
		-- dropped: wardExpiresAt is the persisted table, and a re-group re-confirms
		-- presence by scan -- clearing here would throw away still-valid countdowns.
		cdReadyAt, wardPresent, cdNotifyPending = {}, {}, {}
		hoveredWatchRow = nil   -- frames hidden; OnLeave won't fire on Hide()
			clearNotifications()    -- drop any lingering lines + pending loss batch
	end
end

-- Rebuild the roster maps from the current party/raid, then (de)activate and
-- refresh the rows. Cheap; safe to call on every roster change.
local function rebuildRoster()
	priests, roster, unitByName, nameByGuid, presentLower, classByName = {}, {}, {}, {}, {}, {}

	local function addUnit(unit)
		if not UnitExists(unit) then return end
		local name = UnitName(unit)
		if not name then return end
		local _, guid = UnitExists(unit)
		unitByName[name] = unit
		presentLower[string.lower(name)] = name
		table.insert(roster, name)   -- ordered, for the WardNext sweep
		if guid then nameByGuid[guid] = name end
		local _, class = UnitClass(unit)
		classByName[name] = class
		if class == "PRIEST" then
			table.insert(priests, { name = name, unit = unit, guid = guid, class = class })
		end
	end

	local nraid = GetNumRaidMembers()
	local nparty = GetNumPartyMembers()
	if nraid > 0 then
		for i = 1, nraid do addUnit("raid" .. i) end
	else
		addUnit("player")
		for i = 1, nparty do addUnit("party" .. i) end
	end

	local inGroup = (nraid > 0) or (nparty > 0)
	-- Master hide toggle wins; otherwise only show when there's at least one priest
	-- present (no priest => no Fear Ward to track, so the addon stays hidden).
	local hasPriest = table.getn(priests) > 0
	setActive(not FearWardHelperDB.hidden and hasPriest and (inGroup or FearWardHelperDB.showWhenSolo))
	if active then
		rebuildRows()
		refreshDisplay()
	end
end

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------

-- Shared setup for both tracker frames (CD + Watch).  Called from each XML
-- OnLoad with the frame reference and its DB layout key.
local function setupTrackerFrame(frame, dbKey)
	frame.dbKey = dbKey
	frame:RegisterForDrag("LeftButton")
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0, 0, 0, 0.8)
	-- Width-only resize via the grip; height is driven by the row count, so the
	-- min/max here just bound the width (the height range is generous).
	frame:SetResizable(true)
	frame:SetMinResize(90, 1)
	frame:SetMaxResize(400, 1000)
	-- Keep the grip above the rows so its mouse isn't eaten (matters once rows
	-- are clickable buttons, as on the watch frame). The notify frame has no grip.
	local grip = getglobal(frame:GetName() .. "ResizeGrip")
	if grip then grip:SetFrameLevel(frame:GetFrameLevel() + 10) end
end

function FearWardHelper_OnLoad()
	setupTrackerFrame(this, "cdFrame")
	this:RegisterEvent("VARIABLES_LOADED")
	this:RegisterEvent("PLAYER_ENTERING_WORLD")
	this:RegisterEvent("RAID_ROSTER_UPDATE")
	this:RegisterEvent("PARTY_MEMBERS_CHANGED")
	this:RegisterEvent("SPELLS_CHANGED")
	this:Hide()
end

function FearWardHelper_Watch_OnLoad()
	setupTrackerFrame(this, "watchFrame")
	this:Hide()
end

function FearWardHelper_Notify_OnLoad()
	setupTrackerFrame(this, "notifyFrame")
	-- Drive notification ageing/fade independently of the trackers' active state, so
	-- a test line fades while solo and an in-progress fade finishes after a fight.
	this:SetScript("OnUpdate", FearWardHelper_Notify_OnUpdate)
	-- Shown for its whole life; transparent + inert while locked + empty (see
	-- applyBackdropAlpha). applyFrame in VARIABLES_LOADED sets the locked appearance.
	this:Show()
end

function FearWardHelper_OnEvent()
	if event == "VARIABLES_LOADED" then
		if not FearWardHelperDB then FearWardHelperDB = {} end
		applyDefaults(FearWardHelperDB, DB_DEFAULTS)
		-- Restore persisted ward timers (epoch-based, so they survive reload/relog);
		-- drop any that already expired, then point wardExpiresAt at the saved table
		-- so every later write is persisted automatically.
		local nowEpoch = time()
		for name, exp in pairs(FearWardHelperDB.wards) do
			if exp <= nowEpoch then FearWardHelperDB.wards[name] = nil end
		end
		wardExpiresAt = FearWardHelperDB.wards
		applyFrame(FearWardHelper_CD)
		applyFrame(FearWardHelper_Watch)
		applyFrame(FearWardHelper_Notify)

	elseif event == "PLAYER_ENTERING_WORLD" then
		playerName = UnitName("player")
		local _, class = UnitClass("player")
		isPriest = (class == "PRIEST")
		resolveFearWard()
		scanKnowsFearWard()
		rebuildRoster()

	elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
		rebuildRoster()

	elseif event == "SPELLS_CHANGED" then
		-- Learning/unlearning Fear Ward (or any spell) can change canCast.
		resolveFearWard()
		scanKnowsFearWard()

	elseif event == "UNIT_CASTEVENT" then
		handleCast()

	elseif event == "BUFF_ADDED_SELF" or event == "BUFF_ADDED_OTHER" then
		handleBuffEvent(true)

	elseif event == "BUFF_REMOVED_SELF" or event == "BUFF_REMOVED_OTHER" then
		handleBuffEvent(false)

	elseif event == "CHAT_MSG_ADDON" then
		handleAddonMessage()
	end
end

----------------------------------------------------------------------------
-- Watch-list editing + slash command
----------------------------------------------------------------------------

-- Capitalize the first letter so loose input ("bob") matches WoW names ("Bob").
-- Presence matching is case-insensitive anyway; this is just for tidy storage.
local function tidyName(n)
	return string.upper(string.sub(n, 1, 1)) .. string.sub(n, 2)
end

findWatchIndex = function(name)
	local wl = FearWardHelperDB.watchList
	local lname = string.lower(name)
	for i = 1, table.getn(wl) do
		if string.lower(wl[i]) == lname then return i end
	end
	return nil
end

local function refreshIfActive()
	if active then rebuildRows(); refreshDisplay() end
	if refreshConfig then refreshConfig() end
end

-- Set a watched name's state without removing it (keeps its priority slot):
--   "shown"  -- tracked + rendered as a row.
--   "hidden" -- tracked (a WardNext priority, still notified) but no row.
--   "off"    -- inert (no row, no priority, no notification).
-- The entry, its position and its state all persist in the DB.
local function setWatchState(name, state)
	if not findWatchIndex(name) then
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: " .. tidyName(name) .. " is not tracked.")
		return
	end
	local key = string.lower(name)
	FearWardHelperDB.watchDisabled[key] = (state == "off") and true or nil
	FearWardHelperDB.watchHidden[key]   = (state == "hidden") and true or nil
	local desc = (state == "off") and "disabled (kept in list)"
		or (state == "hidden") and "hidden (still a WardNext priority)"
		or "shown"
	DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: " .. tidyName(name) .. " " .. desc .. ".")
	refreshIfActive()
end

-- Cycle shown -> hidden -> off -> shown (the config-list state button).
local function cycleWatchState(name)
	local s = watchState(name)
	local nxt = (s == "shown") and "hidden" or ((s == "hidden") and "off" or "shown")
	setWatchState(name, nxt)
end

local function addWatch(name)
	if not name or name == "" or string.find(name, "[^a-zA-Z]") then
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: invalid name — only letters allowed.")
		return
	end
	name = tidyName(name)
	if findWatchIndex(name) then
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: " .. name .. " is already tracked.")
		return
	end
	table.insert(FearWardHelperDB.watchList, name)
	DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: now tracking " .. name .. ".")
	refreshIfActive()
end

local function removeWatch(name)
	local i = findWatchIndex(name)
	if not i then
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: " .. tidyName(name) .. " is not tracked.")
		return
	end
	local removed = FearWardHelperDB.watchList[i]
	table.remove(FearWardHelperDB.watchList, i)
	FearWardHelperDB.watchDisabled[string.lower(removed)] = nil
	FearWardHelperDB.watchHidden[string.lower(removed)] = nil
	DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: stopped tracking " .. removed .. ".")
	refreshIfActive()
end

-- Move a watched name up (dir -1) or down (dir +1) the priority list.
local function moveWatch(name, dir)
	local wl = FearWardHelperDB.watchList
	local i = findWatchIndex(name)
	if not i then return end
	local j = i + dir
	if j < 1 or j > table.getn(wl) then return end
	wl[i], wl[j] = wl[j], wl[i]
	refreshIfActive()
end

local function listWatch()
	local wl = FearWardHelperDB.watchList
	local n = table.getn(wl)
	if n == 0 then
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: watch-list is empty (/fw add <name>).")
		return
	end
	DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper watch-list (priority order):")
	for i = 1, n do
		local state = watchState(wl[i])
		local note
		if state == "off" then note = " - disabled"
		elseif state == "hidden" then note = " - hidden"
		elseif presentLower[string.lower(wl[i])] then note = " - in group"
		else note = "" end
		DEFAULT_CHAT_FRAME:AddMessage("  " .. i .. ". " .. wl[i] .. note)
	end
end

local function setScale(n, silent)
	if not n then return end
	if n < 0.5 then n = 0.5 elseif n > 2.0 then n = 2.0 end
	local oldScale = FearWardHelperDB.cdFrame.scale or 1
	FearWardHelperDB.cdFrame.scale = n
	FearWardHelperDB.watchFrame.scale = n
	if oldScale ~= n then
		local ratio = oldScale / n
		local cd = FearWardHelperDB.cdFrame
		cd.x = cd.x * ratio
		cd.y = cd.y * ratio
		local wf = FearWardHelperDB.watchFrame
		wf.x = wf.x * ratio
		wf.y = wf.y * ratio
	end
	applyFrame(FearWardHelper_CD)
	applyFrame(FearWardHelper_Watch)
	if not silent then
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: scale = " .. n .. ".")
	end
	if refreshConfig then refreshConfig() end
end

local function lockAll(locked)
	setLocked(FearWardHelper_CD, locked)
	setLocked(FearWardHelper_Watch, locked)
	setLocked(FearWardHelper_Notify, locked)
	DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: frames " .. (locked and "locked." or "unlocked (drag to move)."))
	if refreshConfig then refreshConfig() end
end

-- Reset both frames' layout to defaults; the watch-list is left untouched.
local function resetFrame(dbKey, frame)
	for k, v in pairs(DB_DEFAULTS[dbKey]) do FearWardHelperDB[dbKey][k] = v end
	applyFrame(frame)
end

local function resetLayout()
	resetFrame("cdFrame", FearWardHelper_CD)
	resetFrame("watchFrame", FearWardHelper_Watch)
	resetFrame("notifyFrame", FearWardHelper_Notify)
	layoutNotifications()   -- notify anchor (alignment/growth) may have changed
	if active then rebuildRows() end
	DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: frame positions/scale reset.")
	if refreshConfig then refreshConfig() end
end

----------------------------------------------------------------------------
-- Notification setters (shared by slash commands and the config panel)
----------------------------------------------------------------------------

-- Generic boolean-flag setter for every notify toggle (notifyApply / notifyLoss /
-- notifyApplyUntracked / notifyCDReady / notifyCDReadyGroup). One shared setter keeps
-- the config panel under Lua 5.0's 32-upvalue-per-function limit (it would otherwise
-- capture one upvalue per setter).
local function setNotifyFlag(flag, on)
	FearWardHelperDB[flag] = on and true or false
	if refreshConfig then refreshConfig() end
end

local function setNotifyDuration(n)
	if not n then return end
	if n < 1 then n = 1 elseif n > 30 then n = 30 end
	FearWardHelperDB.notifyDuration = n
	if refreshConfig then refreshConfig() end
end

-- Low-duration threshold (seconds): below this a ward shows orange and becomes a
-- WardNext priority. Clamped 0-300; 0 disables the feature (see needsWard / refreshDisplay).
local function setLowDuration(n)
	if not n then return end
	if n < 0 then n = 0 elseif n > 300 then n = 300 end
	FearWardHelperDB.lowDuration = n
	if refreshConfig then refreshConfig() end
end

local function setNotifyFontSize(n)
	if not n then return end
	if n < 8 then n = 8 elseif n > 32 then n = 32 end
	FearWardHelperDB.notifyFontSize = n
	layoutNotifications()   -- re-font the live lines
	if refreshConfig then refreshConfig() end
end

-- Push sample lines so the notify area can be positioned/sized while configuring.
local function notifyTest()
	pushNotification(notifyLabel("Fear Ward gained by ") .. colorName("Target")
		.. notifyLabel(" (") .. colorName(playerName or "You") .. notifyLabel(")"))
	pushNotification(notifyLabel("Fear Ward lost by ") .. colorName("Maintank")
		.. notifyLabel(" (+2 more)"))
	pushNotification(notifyLabel("Fear Ward running low on ") .. colorName("Offtank"))
	pushNotification(notifyLabel("Fear Ward ready (") .. colorName("Priest") .. notifyLabel(")"))
end

----------------------------------------------------------------------------
-- Layout-mode / anchor setters (shared by slash commands and the config panel)
----------------------------------------------------------------------------

-- The nine screen anchor points offered by the config panel's anchor picker.
local ANCHOR_POINTS = {
	"TOPLEFT", "TOP", "TOPRIGHT",
	"LEFT",    "CENTER", "RIGHT",
	"BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT",
}

-- Toggle the single-frame (merged) layout. In merged mode both lists live in the
-- CD frame (see rebuildRows); the watch frame is hidden and reuses no extra DB.
local function setMerged(on)
	on = on and true or false
	if FearWardHelperDB.merged == on then return end
	FearWardHelperDB.merged = on
	applyFrame(FearWardHelper_CD)
	applyFrame(FearWardHelper_Watch)
	if active then rebuildRows(); refreshDisplay()
	else FearWardHelper_Watch:Hide() end
	if refreshConfig then refreshConfig() end
end

-- Keep the frames up while solo; flips activation immediately via the roster pass.
local function setShowWhenSolo(on)
	FearWardHelperDB.showWhenSolo = on and true or false
	rebuildRoster()
	if refreshConfig then refreshConfig() end
end

-- Master hide toggle: when on, the addon stays hidden regardless of group/solo state.
-- Flips activation immediately via the roster pass (which gates setActive on this flag).
local function setHidden(on)
	FearWardHelperDB.hidden = on and true or false
	rebuildRoster()
	if refreshConfig then refreshConfig() end
end

-- WardNext sweep: once every tracked target (shown + hidden) is warded, let WardNext
-- ward any unwarded, reachable group member not on the watch-list (see WardNext).
local function setWardNextSweep(on)
	FearWardHelperDB.wardNextSweep = on and true or false
	DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: WardNext untracked sweep "
		.. (FearWardHelperDB.wardNextSweep and "on." or "off."))
	if refreshConfig then refreshConfig() end
end

local function setAnchor(frame, newPoint)
	local d = FearWardHelperDB[frame.dbKey]
	if newPoint == d.point then return end
	local s = d.scale or 1
	local pw, ph = UIParent:GetWidth(), UIParent:GetHeight()
	local ofx, ofy = anchorFractions(d.point)
	local nfx, nfy = anchorFractions(newPoint)
	local w = (frame:GetWidth() or d.width or 150)
	local h = (frame:GetHeight() or 80)
	d.x = d.x + (ofx - nfx) * (pw / s - w)
	d.y = d.y + (ofy - nfy) * (ph / s - h)
	d.point = newPoint
	applyFrame(frame)
	-- The notify frame's anchor also drives notification alignment/growth direction.
	if frame == FearWardHelper_Notify then layoutNotifications() end
end

local function setFramePos(frame, x, y)
	local d = FearWardHelperDB[frame.dbKey]
	if x then d.x = x end
	if y then d.y = y end
	applyFrame(frame)
end

----------------------------------------------------------------------------
-- Config panel (/fw config) -- hand-rolled, drives the setters above. Built once
-- on first open; refreshConfig() syncs every widget back from the DB so the panel,
-- slash commands and drag/resize all stay consistent.
----------------------------------------------------------------------------

local configPanel
local classPanel         -- the "Class priority" popup (built lazily; see buildClassPriority)
local VISIBLE_ROWS = 5   -- watch-list rows visible before scrolling
local ROW_HEIGHT   = 18

local PANEL_BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 16,
	insets = { left = 5, right = 5, top = 5, bottom = 5 },
}
local MENU_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
local EDITBOX_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 9,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- A small label above a widget.
local function cfgLabel(parent, text, x, y)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

-- A category header -- a touch larger than cfgLabel and in the yellow normal font,
-- to set sections apart from the per-widget labels.
local function cfgHeader(parent, text, x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetFont(STANDARD_TEXT_FONT, 13)
	fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

-- A checkbox with a label; onClick gets the new checked state (true/false).
local function cfgCheck(parent, text, onClick)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetWidth(20); cb:SetHeight(20)
	local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(text)
	cb:SetScript("OnClick", function() onClick(this:GetChecked() and true or false) end)
	return cb
end

-- A horizontal slider (OptionsSliderTemplate) with a title above it. onChange gets
-- the new value; updateTitle paints the live value into the title text. A guard flag
-- on the panel suppresses the OnValueChanged feedback while refreshConfig sets it.
local function cfgSlider(parent, name, min, max, step, onChange)
	local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
	s:SetMinMaxValues(min, max)
	s:SetValueStep(step)
	s:SetWidth(150); s:SetHeight(16)
	-- The template's Low/High end labels are noise here; the title carries the value.
	getglobal(name .. "Low"):SetText("")
	getglobal(name .. "High"):SetText("")
	s:SetScript("OnValueChanged", function()
		if configPanel and configPanel.settingSlider then return end
		onChange(this:GetValue())
	end)
	return s
end

-- A text/numeric edit box with a tooltip-style backdrop (no InputBoxTemplate —
-- that template's border textures render a black bar at small heights).
local function cfgEdit(parent, width, onCommit)
	local e = CreateFrame("EditBox", nil, parent)
	e:SetWidth(width); e:SetHeight(22)
	e:SetAutoFocus(false)
	e:SetFontObject(GameFontHighlightSmall)
	e:SetTextInsets(5, 5, 2, 2)
	e:SetBackdrop(EDITBOX_BACKDROP)
	e:SetBackdropColor(0, 0, 0, 0.7)
	e:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
	local commit = function() onCommit(this:GetText()); this:ClearFocus() end
	e:SetScript("OnEnterPressed", commit)
	e:SetScript("OnEscapePressed", function() this:ClearFocus() end)
	return e
end

-- A hand-rolled anchor "dropdown": a button showing the current point, with a popup
-- listing the nine points. Selecting one calls setAnchor on the target frame.
local function cfgAnchorDropdown(parent, getFrame)
	local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	btn:SetWidth(92); btn:SetHeight(20)

	local menu = CreateFrame("Frame", nil, btn)
	menu:SetBackdrop(MENU_BACKDROP)
	menu:SetBackdropColor(0, 0, 0, 0.95)
	menu:SetWidth(92)
	menu:SetHeight(table.getn(ANCHOR_POINTS) * 14 + 8)
	menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, 0)
	menu:SetFrameStrata("DIALOG")
	menu:Hide()
	btn.menu = menu

	for i = 1, table.getn(ANCHOR_POINTS) do
		local point = ANCHOR_POINTS[i]
		local item = CreateFrame("Button", nil, menu)
		item:SetHeight(14)
		item:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -(4 + (i - 1) * 14))
		item:SetPoint("RIGHT", menu, "RIGHT", -4, 0)
		local fs = item:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", item, "LEFT", 2, 0)
		fs:SetText(point)
		local hl = item:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(item); hl:SetTexture(0.3, 0.3, 0.8, 0.5)
		item:SetScript("OnClick", function()
			menu:Hide()
			setAnchor(getFrame(), point)
			btn:SetText(point)
		end)
	end

	btn:SetScript("OnClick", function()
		if menu:IsShown() then menu:Hide() else menu:Show() end
	end)
	return btn
end

-- Build one frame's position controls into a single row: name label + anchor
-- dropdown + X/Y edit boxes. The caller positions the row vertically (see
-- p.layoutPos) so split mode can grow the panel without reserving dead space.
local POS_ROW_H = 24
local function cfgPosRow(parent, getFrame)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(POS_ROW_H)

	row.label = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
	row.label:SetWidth(64); row.label:SetJustifyH("LEFT")

	row.anchor = cfgAnchorDropdown(row, getFrame)
	row.anchor:SetPoint("LEFT", row, "LEFT", 66, 0)

	local applyPos = function()
		local x = tonumber(row.x:GetText())
		local y2 = tonumber(row.y:GetText())
		setFramePos(getFrame(), x, y2)
	end
	local xl = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	xl:SetPoint("LEFT", row.anchor, "RIGHT", 8, 0); xl:SetText("X")
	row.x = cfgEdit(row, 40, applyPos)
	row.x:SetPoint("LEFT", xl, "RIGHT", 3, 0)
	local yl = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	yl:SetPoint("LEFT", row.x, "RIGHT", 8, 0); yl:SetText("Y")
	row.y = cfgEdit(row, 40, applyPos)
	row.y:SetPoint("LEFT", yl, "RIGHT", 3, 0)
	return row
end

-- Sync every widget in the panel from the current DB / live state.
refreshConfig = function()
	local p = configPanel
	if not p or not p:IsShown() then return end
	local db = FearWardHelperDB

	p.mergedCheck:SetChecked(db.merged)
	p.lockCheck:SetChecked(db.cdFrame.locked)
	p.soloCheck:SetChecked(db.showWhenSolo)
	p.hideCheck:SetChecked(db.hidden)
	p.sweepCheck:SetChecked(db.wardNextSweep)

	-- Sliders. Guard the value writes so OnValueChanged (which would call back into
	-- the setters) doesn't echo while we're just syncing the widgets from the DB.
	local sc   = db.cdFrame.scale or 1
	local op   = db.bgOpacity; if op == nil then op = 0.8 end
	local fade = db.notifyDuration or 5
	local font = db.notifyFontSize or 14
	local lowdur = db.lowDuration; if lowdur == nil then lowdur = 60 end
	p.settingSlider = true
	p.scaleSlider:SetValue(sc)
	p.opacitySlider:SetValue(op)
	p.lowDurSlider:SetValue(lowdur)
	p.notifyDurSlider:SetValue(fade)
	p.notifyFontSlider:SetValue(font)
	p.settingSlider = false
	getglobal("FWH_CfgScaleText"):SetText(string.format("Scale  %.1f", sc))
	getglobal("FWH_CfgOpacityText"):SetText(string.format("Background opacity  %d%%", math.floor(op * 100 + 0.5)))
	getglobal("FWH_CfgLowDurText"):SetText(lowdur > 0 and string.format("Low ward threshold  %ds", lowdur) or "Low ward threshold  off")
	getglobal("FWH_CfgFadeText"):SetText(string.format("Fade after  %ds", fade))
	getglobal("FWH_CfgFontText"):SetText(string.format("Font size  %d", font))

	-- Notification toggles.
	p.notifyApplyCheck:SetChecked(db.notifyApply)
	p.notifyUntrackedCheck:SetChecked(db.notifyApplyUntracked)
	p.notifyCastFailCheck:SetChecked(db.notifyCastFail)
	p.notifyLossCheck:SetChecked(db.notifyLoss)
	p.notifyLowCheck:SetChecked(db.notifyLowDuration)
	p.notifyCDCheck:SetChecked(db.notifyCDReady)
	p.notifyCDGroupCheck:SetChecked(db.notifyCDReadyGroup)

	-- Watch-list editor (scrollable).
	p.updateWatchList()

	-- Frame-position rows: CD row always; watch row only in split mode; notify always.
	-- layoutPos re-stacks them so split mode grows the panel rather than leaving a gap.
	p.cdPos.label:SetText(db.merged and "Frame" or "CD frame")
	p.cdPos.anchor:SetText(db.cdFrame.point)
	p.cdPos.x:SetText(string.format("%.0f", db.cdFrame.x))
	p.cdPos.y:SetText(string.format("%.0f", db.cdFrame.y))
	if not db.merged then
		p.watchPos.label:SetText("Target frame")
		p.watchPos.anchor:SetText(db.watchFrame.point)
		p.watchPos.x:SetText(string.format("%.0f", db.watchFrame.x))
		p.watchPos.y:SetText(string.format("%.0f", db.watchFrame.y))
	end
	p.notifyPos.label:SetText("Notify frame")
	p.notifyPos.anchor:SetText(db.notifyFrame.point)
	p.notifyPos.x:SetText(string.format("%.0f", db.notifyFrame.x))
	p.notifyPos.y:SetText(string.format("%.0f", db.notifyFrame.y))
	p.layoutPos(db.merged)
end

----------------------------------------------------------------------------
-- Class-priority popup (the sweep order; see WardNext tier 3)
----------------------------------------------------------------------------

local function classDisplayName(token)
	return string.upper(string.sub(token, 1, 1)) .. string.lower(string.sub(token, 2))
end

local function findClassIndex(token)
	local order = FearWardHelperDB.sweepClassOrder
	for i = 1, table.getn(order) do
		if order[i] == token then return i end
	end
	return nil
end

-- Move a class up (dir -1) / down (dir +1) the sweep priority order.
local function moveSweepClass(token, dir)
	local order = FearWardHelperDB.sweepClassOrder
	local i = findClassIndex(token)
	if not i then return end
	local j = i + dir
	if j < 1 or j > table.getn(order) then return end
	order[i], order[j] = order[j], order[i]
	if classPanel and classPanel.refresh then classPanel.refresh() end
end

-- Enable/disable a class for the sweep; a disabled class is ignored entirely.
local function setSweepClassEnabled(token, on)
	FearWardHelperDB.sweepClassDisabled[token] = (not on) and true or nil
	if classPanel and classPanel.refresh then classPanel.refresh() end
end

-- A small popup (one fixed row per class, no scroll/add/remove) for ordering the
-- sweep's class priority and toggling classes out of it. Built lazily; toggled by
-- the "Class priority" button on the config panel. Its own function = its own
-- upvalue budget (buildConfig is near Lua 5.0's 32-upvalue limit).
local function buildClassPriority()
	if classPanel then return end
	if not configPanel then return end   -- parented to the config panel; built with it
	local n = table.getn(CLASS_TOKENS)
	local CR_H = 18
	local TOP = 30          -- title strip
	local BOT = 8
	local p = CreateFrame("Frame", "FearWardHelper_ClassPriority", configPanel)
	classPanel = p
	p:SetWidth(160)
	p:SetHeight(TOP + n * CR_H + BOT)
	p:SetPoint("TOPLEFT", configPanel, "TOPRIGHT", 6, 0)
	p:SetBackdrop(PANEL_BACKDROP)
	p:SetFrameStrata("DIALOG")
	p:SetFrameLevel(configPanel:GetFrameLevel() + 10)
	p:EnableMouse(true)

	local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", p, "TOP", 0, -10)
	title:SetText("Class priority")

	local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", p, "TOPRIGHT", -2, -2)

	p.rows = {}
	for i = 1, n do
		local row = CreateFrame("Frame", nil, p)
		row:SetHeight(CR_H)
		row:SetPoint("TOPLEFT", p, "TOPLEFT", 10, -(TOP + (i - 1) * CR_H))
		row:SetPoint("RIGHT", p, "RIGHT", -8, 0)

		local en = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		en:SetWidth(18); en:SetHeight(18)
		en:SetPoint("LEFT", row, "LEFT", 0, 0)
		en:SetScript("OnClick", function()
			setSweepClassEnabled(row.token, this:GetChecked() and true or false)
		end)
		row.enable = en

		local nameFS = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		nameFS:SetPoint("LEFT", en, "RIGHT", 4, 0)
		nameFS:SetJustifyH("LEFT")
		row.name = nameFS

		local dn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		dn:SetWidth(20); dn:SetHeight(16); dn:SetText("v")
		dn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		dn:SetScript("OnClick", function() moveSweepClass(row.token, 1) end)
		row.down = dn

		local up = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		up:SetWidth(20); up:SetHeight(16); up:SetText("^")
		up:SetPoint("RIGHT", dn, "LEFT", -2, 0)
		up:SetScript("OnClick", function() moveSweepClass(row.token, -1) end)
		row.up = up

		p.rows[i] = row
	end

	p.refresh = function()
		local order = FearWardHelperDB.sweepClassOrder
		local disabled = FearWardHelperDB.sweepClassDisabled
		local cnt = table.getn(order)
		for i = 1, n do
			local row = p.rows[i]
			local token = order[i]
			row.token = token
			row.enable:SetChecked(not disabled[token])
			row.name:SetText(classDisplayName(token))
			row.name:SetTextColor(classColor(token))
			if i == 1 then row.up:Disable() else row.up:Enable() end
			if i == cnt then row.down:Disable() else row.down:Enable() end
		end
	end

	p:Hide()
end

-- buildConfig closes over a lot of chunk-level setters + widget factories. In Lua 5.0
-- every such referenced local is an *upvalue*, capped at 32 per function -- and we were
-- right at the edge. Bundling the functions into two tables (one upvalue each, reached
-- as ui.* / act.*) instead of ~19 individual ones buys generous headroom, so new
-- toggles no longer risk breaking compilation. NOTE: the roster tables that get
-- *reassigned* wholesale on every rebuild (presentLower / classByName) must stay direct
-- upvalues so the closure sees the new value -- they deliberately aren't bundled here;
-- watchState / classColor stay direct too (cheap, and used only by updateWatchList).
local ui = {
	cfgHeader = cfgHeader, cfgCheck = cfgCheck, cfgEdit = cfgEdit,
	cfgSlider = cfgSlider, cfgPosRow = cfgPosRow,
}
local act = {
	addWatch = addWatch, removeWatch = removeWatch, moveWatch = moveWatch,
	cycleWatchState = cycleWatchState, setMerged = setMerged,
	setShowWhenSolo = setShowWhenSolo, setHidden = setHidden, lockAll = lockAll, setNotifyFlag = setNotifyFlag,
	setScale = setScale, setBgOpacity = setBgOpacity, notifyTest = notifyTest,
	setNotifyDuration = setNotifyDuration, setNotifyFontSize = setNotifyFontSize,
	setLowDuration = setLowDuration, resetLayout = resetLayout,
}

local function buildConfig()
	if configPanel then return end
	local p = CreateFrame("Frame", "FearWardHelper_Config", UIParent)
	configPanel = p
	p:SetWidth(360); p:SetHeight(560)   -- height is finalized dynamically by layoutPos
	p:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	p:SetBackdrop(PANEL_BACKDROP)
	p:SetFrameStrata("DIALOG")
	p:EnableMouse(true)
	p:SetMovable(true)
	p:RegisterForDrag("LeftButton")
	p:SetScript("OnDragStart", function() this:StartMoving() end)
	p:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)

	local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetFont(STANDARD_TEXT_FONT, 14)   -- +2pt over the default header
	title:SetPoint("TOP", p, "TOP", 0, -12)
	title:SetText("FearWardHelper Options")

	local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", p, "TOPRIGHT", -4, -4)

	-- Watch-list editor (scrollable) ----------------------------------------
	ui.cfgHeader(p, "Tracked players (priority)", 16, -36)

	-- "Class priority" button (opens the sweep class-order popup beside the panel).
	local classBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	classBtn:SetWidth(96); classBtn:SetHeight(18); classBtn:SetText("Class priority")
	classBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, -34)
	-- Toggle the class-priority popup inline. buildClassPriority + classPanel become
	-- buildConfig upvalues, which the ui/act bundling above leaves room for. classPanel
	-- is reassigned wholesale in buildClassPriority, so (like presentLower/classByName)
	-- it must stay a direct upvalue -- never bundled into act -- to see the new value.
	classBtn:SetScript("OnClick", function()
		buildClassPriority()
		if not classPanel then return end
		if classPanel:IsShown() then
			classPanel:Hide()
		else
			classPanel:Show(); classPanel.refresh()
		end
	end)

	local rowTop = -54
	local listPad = 4   -- inner padding of the bordered list container
	local listH  = VISIBLE_ROWS * ROW_HEIGHT + listPad * 2

	-- Bordered container for the player list.
	local listBox = CreateFrame("Frame", nil, p)
	listBox:SetPoint("TOPLEFT", p, "TOPLEFT", 16, rowTop)
	listBox:SetPoint("RIGHT", p, "RIGHT", -16, 0)
	listBox:SetHeight(listH)
	listBox:SetBackdrop(EDITBOX_BACKDROP)
	listBox:SetBackdropColor(0, 0, 0, 0.5)
	listBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

	-- FauxScrollFrame provides the scrollbar; sized inside the container so the
	-- scrollbar sits within the border.
	local scroll = CreateFrame("ScrollFrame", "FWH_CfgScroll", listBox, "FauxScrollFrameTemplate")
	scroll:SetHeight(VISIBLE_ROWS * ROW_HEIGHT)
	scroll:SetPoint("TOPLEFT", listBox, "TOPLEFT", listPad, -listPad)
	scroll:SetPoint("RIGHT", listBox, "RIGHT", -(listPad + 18), 0)
	p.scroll = scroll

	local function forwardWheel()
		local sb = getglobal("FWH_CfgScrollScrollBar")
		if sb then sb:SetValue(sb:GetValue() - arg1 * ROW_HEIGHT) end
	end
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", forwardWheel)
	listBox:EnableMouseWheel(true)
	listBox:SetScript("OnMouseWheel", forwardWheel)

	p.rows = {}
	for i = 1, VISIBLE_ROWS do
		local row = CreateFrame("Frame", nil, listBox)
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("TOPLEFT", listBox, "TOPLEFT", listPad + 2, -listPad - (i - 1) * ROW_HEIGHT)
		row:SetPoint("RIGHT", listBox, "RIGHT", -(listPad + 22), 0)

		-- State button: cycles Shown (S) -> Hidden (H) -> Off (O). Shown = tracked +
		-- row; Hidden = tracked priority but no row; Off = inert (kept in list).
		local st = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		st:SetWidth(20); st:SetHeight(16)
		st:SetPoint("LEFT", row, "LEFT", 0, 0)
		st:SetScript("OnClick", function() act.cycleWatchState(row.wname) end)
		row.state = st

		local nameFS = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		nameFS:SetPoint("LEFT", st, "RIGHT", 4, 0)
		nameFS:SetJustifyH("LEFT")
		row.name = nameFS

		local rm = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		rm:SetWidth(20); rm:SetHeight(16); rm:SetText("X")
		rm:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		rm:SetScript("OnClick", function() act.removeWatch(row.wname) end)

		local dn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		dn:SetWidth(20); dn:SetHeight(16); dn:SetText("v")
		dn:SetPoint("RIGHT", rm, "LEFT", -2, 0)
		dn:SetScript("OnClick", function() act.moveWatch(row.wname, 1) end)

		local up = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		up:SetWidth(20); up:SetHeight(16); up:SetText("^")
		up:SetPoint("RIGHT", dn, "LEFT", -2, 0)
		up:SetScript("OnClick", function() act.moveWatch(row.wname, -1) end)

		row.up, row.down = up, dn
		row:EnableMouseWheel(true)
		row:SetScript("OnMouseWheel", forwardWheel)
		row:Hide()
		p.rows[i] = row
	end

	-- Populates the visible rows from the watch-list at the current scroll offset.
	p.updateWatchList = function()
		local wl = FearWardHelperDB.watchList
		local n = table.getn(wl)
		FauxScrollFrame_Update(scroll, n, VISIBLE_ROWS, ROW_HEIGHT)
		local offset = FauxScrollFrame_GetOffset(scroll)
		for i = 1, VISIBLE_ROWS do
			local row = p.rows[i]
			local idx = offset + i
			if idx <= n then
				local name = wl[idx]
				local actual = presentLower[string.lower(name)]
				local state = watchState(name)
				if state == "off" then
					row.state:SetText("O")
					row.name:SetText(name .. "  (off)")
					row.name:SetTextColor(0.5, 0.5, 0.5)   -- greyed: not tracked
				elseif state == "hidden" then
					row.state:SetText("H")
					row.name:SetText(name .. "  (hidden)")
					row.name:SetTextColor(0.7, 0.7, 0.7)   -- dim: tracked but no row
				else
					row.state:SetText("S")
					row.name:SetText(name .. ((not actual) and "  (away)" or ""))
					row.name:SetTextColor(classColor(actual and classByName[actual] or nil))
				end
				if idx == 1 then row.up:Disable() else row.up:Enable() end
				if idx == n then row.down:Disable() else row.down:Enable() end
				row.wname = name
				row:Show()
			else
				row:Hide()
			end
		end
	end

	scroll:SetScript("OnVerticalScroll", function()
		FauxScrollFrame_OnVerticalScroll(ROW_HEIGHT, p.updateWatchList)
	end)

	-- Add box: full width, Add button right-aligned.
	local addY = rowTop - listH - 8
	local addBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	addBtn:SetWidth(50); addBtn:SetHeight(22); addBtn:SetText("Add")
	addBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -16, addY)
	local addBox = ui.cfgEdit(p, 0, function(text)
		if text and text ~= "" then act.addWatch(text); configPanel.addBox:SetText("") end
	end)
	addBox:SetPoint("TOPLEFT", p, "TOPLEFT", 18, addY)
	addBox:SetPoint("RIGHT", addBtn, "LEFT", -6, 0)
	p.addBox = addBox
	addBtn:SetScript("OnClick", function()
		local text = configPanel.addBox:GetText()
		if text and text ~= "" then act.addWatch(text); configPanel.addBox:SetText("") end
	end)

	-- Layout columns shared by the two-up rows below.
	local COL1, COL2   = 14, 190    -- checkbox columns
	local SCOL1, SCOL2 = 18, 192    -- slider columns

	-- Toggles (two columns) -------------------------------------------------
	local togY = addY - 30
	p.mergedCheck = ui.cfgCheck(p, "Single combined frame", function(on) act.setMerged(on) end)
	p.mergedCheck:SetPoint("TOPLEFT", p, "TOPLEFT", COL1, togY)
	p.soloCheck = ui.cfgCheck(p, "Show when solo", function(on) act.setShowWhenSolo(on) end)
	p.soloCheck:SetPoint("TOPLEFT", p, "TOPLEFT", COL2, togY)
	p.lockCheck = ui.cfgCheck(p, "Lock frames", function(on) act.lockAll(on) end)
	p.lockCheck:SetPoint("TOPLEFT", p, "TOPLEFT", COL1, togY - 24)
	-- WardNext sweep: ward untracked group members once all tracked are warded. Routed
	-- through the generic setNotifyFlag (a plain boolean DB write) for brevity.
	p.sweepCheck = ui.cfgCheck(p, "Allow Ward untracked", function(on) act.setNotifyFlag("wardNextSweep", on) end)
	p.sweepCheck:SetPoint("TOPLEFT", p, "TOPLEFT", COL2, togY - 24)
	-- Master hide toggle: keep the addon hidden regardless of group/solo state.
	p.hideCheck = ui.cfgCheck(p, "Hide addon", function(on) act.setHidden(on) end)
	p.hideCheck:SetPoint("TOPLEFT", p, "TOPLEFT", COL1, togY - 48)

	-- Scale + background opacity sliders (two columns, both frames) ----------
	local sliderY = togY - 84
	p.scaleSlider = ui.cfgSlider(p, "FWH_CfgScale", 0.5, 2.0, 0.1, function(v) act.setScale(v, true) end)
	p.scaleSlider:SetPoint("TOPLEFT", p, "TOPLEFT", SCOL1, sliderY)
	p.opacitySlider = ui.cfgSlider(p, "FWH_CfgOpacity", 0, 1, 0.05, function(v) act.setBgOpacity(v) end)
	p.opacitySlider:SetPoint("TOPLEFT", p, "TOPLEFT", SCOL2, sliderY)

	-- Low-duration threshold (0 = off): a ward below this many seconds turns orange and
	-- becomes a WardNext priority. Its own row beneath scale/opacity.
	local lowDurY = sliderY - 44
	p.lowDurSlider = ui.cfgSlider(p, "FWH_CfgLowDur", 0, 300, 5, function(v) act.setLowDuration(v) end)
	p.lowDurSlider:SetPoint("TOPLEFT", p, "TOPLEFT", SCOL1, lowDurY)

	-- Notifications ---------------------------------------------------------
	local notifyY = lowDurY - 44
	local notifyHdr = ui.cfgHeader(p, "Notifications", 16, notifyY)
	local testBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	testBtn:SetWidth(50); testBtn:SetHeight(20); testBtn:SetText("Test")
	testBtn:SetPoint("LEFT", notifyHdr, "RIGHT", 10, -1)
	testBtn:SetScript("OnClick", function() act.notifyTest() end)

	-- Row 1: gains + losses. Row 2: "include untracked" (modifies both of the above,
	-- hence indented under them). Row 3: the CD-ready pair.
	p.notifyApplyCheck = ui.cfgCheck(p, "Announce casts", function(on) act.setNotifyFlag("notifyApply", on) end)
	p.notifyApplyCheck:SetPoint("TOPLEFT", p, "TOPLEFT", COL1, notifyY - 20)
	p.notifyLossCheck = ui.cfgCheck(p, "Announce ward loss", function(on) act.setNotifyFlag("notifyLoss", on) end)
	p.notifyLossCheck:SetPoint("TOPLEFT", p, "TOPLEFT", COL2, notifyY - 20)
	p.notifyUntrackedCheck = ui.cfgCheck(p, "Include untracked players", function(on) act.setNotifyFlag("notifyApplyUntracked", on) end)
	p.notifyUntrackedCheck:SetPoint("TOPLEFT", p, "TOPLEFT", COL1 + 14, notifyY - 42)
	p.notifyCastFailCheck = ui.cfgCheck(p, "Announce failed casts", function(on) act.setNotifyFlag("notifyCastFail", on) end)
	p.notifyCastFailCheck:SetPoint("TOPLEFT", p, "TOPLEFT", COL2, notifyY - 42)
	p.notifyCDCheck = ui.cfgCheck(p, "Announce CD ready", function(on) act.setNotifyFlag("notifyCDReady", on) end)
	p.notifyCDCheck:SetPoint("TOPLEFT", p, "TOPLEFT", COL1, notifyY - 64)
	p.notifyCDGroupCheck = ui.cfgCheck(p, "Announce group CD ready", function(on) act.setNotifyFlag("notifyCDReadyGroup", on) end)
	p.notifyCDGroupCheck:SetPoint("TOPLEFT", p, "TOPLEFT", COL2, notifyY - 64)
	-- Row 4: low-ward warning (fires when a tracked ward drops below the lowDuration slider).
	p.notifyLowCheck = ui.cfgCheck(p, "Announce low ward", function(on) act.setNotifyFlag("notifyLowDuration", on) end)
	p.notifyLowCheck:SetPoint("TOPLEFT", p, "TOPLEFT", COL1, notifyY - 86)

	-- Fade + font size sliders (two columns) --------------------------------
	local notifySliderY = notifyY - 120
	p.notifyDurSlider = ui.cfgSlider(p, "FWH_CfgFade", 1, 10, 1, function(v) act.setNotifyDuration(v) end)
	p.notifyDurSlider:SetPoint("TOPLEFT", p, "TOPLEFT", SCOL1, notifySliderY)
	p.notifyFontSlider = ui.cfgSlider(p, "FWH_CfgFont", 8, 24, 1, function(v) act.setNotifyFontSize(v) end)
	p.notifyFontSlider:SetPoint("TOPLEFT", p, "TOPLEFT", SCOL2, notifySliderY)

	-- Frame position --------------------------------------------------------
	local posHdrY = notifySliderY - 40
	ui.cfgHeader(p, "Frame position", 16, posHdrY)
	p.cdPos     = ui.cfgPosRow(p, function() return FearWardHelper_CD end)
	p.watchPos  = ui.cfgPosRow(p, function() return FearWardHelper_Watch end)
	p.notifyPos = ui.cfgPosRow(p, function() return FearWardHelper_Notify end)

	local resetBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	resetBtn:SetWidth(120); resetBtn:SetHeight(22); resetBtn:SetText("Reset positions")
	resetBtn:SetScript("OnClick", function() act.resetLayout() end)
	p.resetBtn = resetBtn

	-- Stack the position rows from posTop. In merged mode the Target row is hidden
	-- and its space reclaimed (rows below shift up); then size the panel and pin
	-- Reset just below the last row so split mode grows the panel instead of gapping.
	p.posTop = posHdrY - 24
	p.layoutPos = function(merged)
		local y = p.posTop
		local function place(row)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", p, "TOPLEFT", 16, y)
			row:SetPoint("RIGHT", p, "RIGHT", -16, 0)
			row:Show()
			y = y - POS_ROW_H
		end
		place(p.cdPos)
		if merged then p.watchPos:Hide() else place(p.watchPos) end
		place(p.notifyPos)
		resetBtn:ClearAllPoints()
		resetBtn:SetPoint("TOP", p, "TOP", 0, y - 8)
		p:SetHeight(-(y - 8 - 22) + 14)
	end
	p.layoutPos(FearWardHelperDB and FearWardHelperDB.merged)

	p:Hide()
end

function FearWardHelper_ToggleConfig()
	buildConfig()
	if configPanel:IsShown() then
		configPanel:Hide()
	else
		configPanel:Show()
		refreshConfig()
	end
end

local function printHelp()
	DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper commands:")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw config         - open the options panel")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw add <name>     - track a player's Fear Ward")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw remove <name>  - stop tracking a player")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw disable <name> - keep in list but stop tracking")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw hide <name>    - hide from list but keep WardNext priority")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw enable <name>  - show + resume tracking (undo hide/disable)")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw list           - show the watch-list (priority order)")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw up|down <name> - change a player's priority")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw sweep on|off   - WardNext wards untracked once all tracked are warded")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw merge | split  - one combined frame, or two")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw lock | unlock  - lock/unlock both frames")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw hide | unhide  - hide/show the whole addon")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw scale <0.5-2>  - resize both frames")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw low <0-120>    - warn (orange + WardNext) below N seconds left; 0 off")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw reset          - reset frame positions/scale")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw notify cast|loss|low|castfail|cd|groupcd|untracked on|off")
	DEFAULT_CHAT_FRAME:AddMessage("  /fw notify duration <s> | font <size> | test")
	DEFAULT_CHAT_FRAME:AddMessage("  macros: /script FearWardHelper_WardNext()  or  FearWardHelper_Ward(\"Name\")")
end

-- /fw notify <sub> [value]: toggle the notification options or push a test line.
local function notifyCmd(sub, val)
	local on = (string.lower(val or "") == "on")
	if sub == "cast" or sub == "apply" then
		setNotifyFlag("notifyApply", on)
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: cast notifications " .. (on and "on." or "off."))
	elseif sub == "untracked" then
		setNotifyFlag("notifyApplyUntracked", on)
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: notifications for untracked players " .. (on and "on." or "off."))
	elseif sub == "loss" then
		setNotifyFlag("notifyLoss", on)
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: loss notifications " .. (on and "on." or "off."))
	elseif sub == "low" or sub == "lowduration" or sub == "lowdur" then
		setNotifyFlag("notifyLowDuration", on)
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: low-ward notifications " .. (on and "on." or "off."))
	elseif sub == "castfail" or sub == "fail" then
		setNotifyFlag("notifyCastFail", on)
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: failed-cast notifications " .. (on and "on." or "off."))
	elseif sub == "cd" then
		setNotifyFlag("notifyCDReady", on)
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: own CD-ready notifications " .. (on and "on." or "off."))
	elseif sub == "groupcd" then
		setNotifyFlag("notifyCDReadyGroup", on)
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: group CD-ready notifications " .. (on and "on." or "off."))
	elseif sub == "duration" or sub == "dur" then
		setNotifyDuration(tonumber(val))
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: notifications fade after " .. (FearWardHelperDB.notifyDuration) .. "s.")
	elseif sub == "font" or sub == "fontsize" then
		setNotifyFontSize(tonumber(val))
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: notification font size " .. (FearWardHelperDB.notifyFontSize) .. ".")
	elseif sub == "test" then
		notifyTest()
	else
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: /fw notify cast|loss|low|castfail|cd|groupcd|untracked on|off, duration <s>, font <size>, test")
	end
end

SLASH_FEARWARDHELPER1 = "/fw"
SLASH_FEARWARDHELPER2 = "/fearward"
SlashCmdList["FEARWARDHELPER"] = function(msg)
	-- Preserve case for names; only the command verb is lowercased.
	local args = {}
	for w in string.gfind(msg or "", "%S+") do table.insert(args, w) end
	local cmd = string.lower(args[1] or "")

	if cmd == "config" or cmd == "options" or cmd == "opt" then
		FearWardHelper_ToggleConfig()
	elseif cmd == "add" and args[2] then
		addWatch(args[2])
	elseif (cmd == "remove" or cmd == "rem" or cmd == "del") and args[2] then
		removeWatch(args[2])
	elseif (cmd == "enable" or cmd == "on" or cmd == "show") and args[2] then
		setWatchState(args[2], "shown")
	elseif cmd == "hide" and args[2] then
		setWatchState(args[2], "hidden")
	elseif cmd == "hide" then
		setHidden(true)
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: addon hidden. Use /fw unhide to bring it back.")
	elseif cmd == "unhide" or cmd == "reveal" then
		setHidden(false)
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: addon shown.")
	elseif (cmd == "disable" or cmd == "off") and args[2] then
		setWatchState(args[2], "off")
	elseif cmd == "sweep" or cmd == "wardnext" then
		setWardNextSweep(string.lower(args[2] or "") == "on")
	elseif cmd == "list" then
		listWatch()
	elseif cmd == "up" and args[2] then
		moveWatch(args[2], -1)
	elseif cmd == "down" and args[2] then
		moveWatch(args[2], 1)
	elseif cmd == "merge" then
		setMerged(true)
	elseif cmd == "split" then
		setMerged(false)
	elseif cmd == "lock" then
		lockAll(true)
	elseif cmd == "unlock" then
		lockAll(false)
	elseif cmd == "scale" and args[2] then
		setScale(tonumber(args[2]))
	elseif (cmd == "lowduration" or cmd == "lowdur" or cmd == "low") and args[2] then
		setLowDuration(tonumber(args[2]))
		local ld = FearWardHelperDB.lowDuration
		DEFAULT_CHAT_FRAME:AddMessage("FearWardHelper: low-ward warning " .. (ld > 0 and ("below " .. ld .. "s.") or "disabled."))
	elseif cmd == "reset" then
		resetLayout()
	elseif cmd == "notify" then
		notifyCmd(string.lower(args[2] or ""), args[3])
	else
		printHelp()
	end
end
