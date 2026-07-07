# FearWardHelper — Developer Notes

## What this is

FearWardHelper is a World of Warcraft addon for the **1.12 client** (private
servers — OctoWoW / Turtle-style) that helps Priests (and raid leaders) manage
**Fear Ward** (spell id `6346`: instant, 30s cooldown, 10 min buff that blocks
the next fear). It does three things:

1. **Cooldown tracking** — a frame (`FearWardHelper_CD`) listing every priest in
   the party/raid with their Fear Ward cooldown (green "Ready" / red countdown).
2. **Ward tracking** — a second frame (`FearWardHelper_Watch`) listing a
   configurable **watch-list** of player names who are currently in the group,
   showing whether each has the Fear Ward buff and the time left when known.
3. **Cast helper** — click a watched player's row, or call the macro globals, to
   cast Fear Ward on them without dropping your current target.
4. **Notifications** — a floating message area (`FearWardHelper_Notify`) that
   announces Fear Ward **casts** (source → target), **losses** on watched targets
   (batched for AoE fears) and **low-duration** warnings (a ward dropping below the
   threshold), fading out after a configurable delay. See "Notifications".

CD + ward tracking work for **any class** (raid-lead observation); the cast
helper requires being a Priest who knows Fear Ward (`canCast`). Row names are
class-coloured via `RAID_CLASS_COLORS` (class token captured per unit in the
roster scan; `classColor` falls back to white). PrayerHelper (a
sibling addon, `../PrayerHelper/`) was the scaffolding and the reference for the
1.12 gotchas, the moveable-frame pattern, SavedVariables, and `UNIT_CASTEVENT`.

## How cooldowns are learned (two layers)

- **Local observation** — SuperWoW's `UNIT_CASTEVENT` fires for **every unit's**
  casts, not just the player (`arg1` is the caster GUID). We filter to Fear Ward
  by id (`arg4 == 6346`) on the `"CAST"` action (Fear Ward is instant, so it emits
  `"CAST"`, never `"START"`), resolve the caster GUID to a name, and start a 30s
  cooldown. This works for any priest you can see, addon or not.
- **Sync (broadcast own casts)** — fills the gap for priests you *can't* see. On
  our own Fear Ward `"CAST"` we `SendAddonMessage(ADDON_PREFIX, "cast <target>",
  "RAID"|"PARTY")`. Receivers start the **sender's** cooldown (sender = the
  `CHAT_MSG_ADDON` `arg4`) and mark the target warded. One tiny message per cast,
  so no `ChatThrottleLib` is needed. The two layers call the same idempotent
  setters (`startCD` / `setWard`), so an observed-and-synced cast is harmless.

We only broadcast **our own** casts (not observed ones) — by design, the simplest
sync that still covers the out-of-range case.

## Ward (buff) tracking

Fear Ward's duration is a **fixed 10 min** — nothing modifies it — so we never need
to *read* a remaining duration, only the **moment** it is applied or removed.

### Event-driven (primary) — `handleBuffEvent`

This client fires custom combat-log events (discovered via DoiteAuras; see
[../DoiteAuras/Modules/DoiteTargetAuras.lua](../DoiteAuras/Modules/DoiteTargetAuras.lua)):
`BUFF_ADDED_SELF` / `BUFF_ADDED_OTHER` / `BUFF_REMOVED_SELF` / `BUFF_REMOVED_OTHER`,
each with **`arg1` = unit GUID, `arg3` = spell id**. Filtered to Fear Ward (6346):

- **ADDED** → applied or **refreshed** now → `setWard(name)` (exact start ⇒ exact
  10-min countdown; a recast just restarts it).
- **REMOVED** → gone now, **reason-agnostic** (a fear consumed it, the player
  cancelled it, or it expired) → `clearWard(name)` instantly, no poll lag.

(There is also an `AURA_CAST_ON_OTHER` with `arg8` = durationMs, but we don't use it
— the duration is fixed.) These events reach only **combat-log range**, same as the
cast event / buff scan. Registered in `setActive` under the SuperWoW gate (GUID
resolution via `guidName` leans on the roster). **Open question:** whether
`BUFF_*_OTHER` fires for *other* players' casts or only your own — either way the
poll below covers others, so it degrades gracefully.

### Poll + cast observation (fallback / reconciliation)

A throttled `scanWards()` (every 0.25s, in `FearWardHelper_OnUpdate`) reconciles:

- **Yourself** — reads the *exact* remaining time via `selfWardTimeLeft()`
  (`GetPlayerBuff` loop → `GetPlayerBuffTimeLeft`, matched by icon). Accurate even
  for a buff up before login/reload. (The `GetPlayerBuff` index space is separate
  from `UnitBuff`'s.)
- **Others** — `UnitBuff(unit, i)` on this client returns only `icon, stackCount,
  spellId` (positions 4+ `nil` — **no duration**; confirmed in-game). So it can only
  confirm *presence* (Fear Ward icon = `Spell_Holy_Excorcism`; `spellId` at pos 3 ==
  6346 is an alternative match), and only in range (`UnitIsVisible`) so an
  out-of-range unit isn't wrongly cleared. **Rising edge:** a CONFIRMED-absent
  (`wardPresent == false`) → present transition is treated as a fresh application
  (full timer); never inferred from `nil` (could be a pre-existing buff of unknown
  age, which is the only remaining "warded, no timer" case).

Observed/synced casts (`handleCast` / sync) also call `setWard`. All paths feed the
same setters, so they reconcile harmlessly.

### Persistence

`wardExpiresAt` is a **Unix `time()` epoch** (not `GetTime`) and is reassigned to
the saved `FearWardHelperDB.wards` table at `VARIABLES_LOADED` (pruning
already-expired entries), so every `setWard` write is persisted and the countdown
**survives a `/reload` or relog**. `setActive(false)` deliberately does *not* wipe
it (only the transient `cdReadyAt` / `wardPresent`). `wardPresent[name]` is
tri-state: `nil` until a scan has an opinion (then the timer alone decides
"warded", so restored/out-of-range timers still show), `true`/`false` once scanned.
`isWarded(name)` centralizes that logic for both the display and `WardNext()`.

### Low-duration warning

`FearWardHelperDB.lowDuration` (seconds, default **60**, configurable 0–120 via the
config slider / `/fw low`; **0 disables**) marks a ward as "running low". Two effects,
both reading the same `(exp - now) < lowDuration` test:

- **Display** — in `refreshDisplay` a still-present ward whose remaining time is under the
  threshold paints its countdown **orange** (`1, 0.6, 0`) instead of the normal green, so a
  soon-to-expire ward stands out.
- **WardNext priority** — `needsWard(name)` (the WardNext eligibility test that replaced the
  bare `not isWarded` in all three tiers) treats a low-duration ward as needing a (re)ward,
  so a top-off happens early rather than waiting for the ward to drop. A "warded, no timer"
  (nil `exp`, unknown-age) ward is **never** low-duration — we don't guess at an unknown age.

## Casting

`castOn(unit)` casts Fear Ward on a unit **without a target switch**. On a
Nampower client `CastSpellByName(name, unit)` takes the unit directly; otherwise
the fallback is the `AutoSelfCast`-off + `SpellTargetUnit` dance (cf. pfUI
`modules/mouseover.lua`). The spell **name** comes from `SpellInfo(6346)` (the
localized name); without SuperWoW, `resolveFearWard` falls back to the fixed icon
path (`spell_holy_excorcism`) and `scanKnowsFearWard` then reads the localized name
from the spellbook (matched by that icon), so the cast helper works on a base
client too — never a hardcoded "Fear Ward" string. Three macro globals:

- `FearWardHelper_Ward("Name")` — ward a specific player (if in the group). Gated on
  `needsWard(name)` (same as WardNext): if the target is still safely warded (warded with
  ≥ `lowDuration` left, or a "warded, no timer" entry) the cast is **refused** with a chat
  line ("`<name> already has Fear Ward (M:SS left)`") rather than wasting a Fear Ward + its
  30s cooldown topping off a full ward. A recast is only allowed when they're unwarded or
  under the low-duration threshold. Also drives the watch-row click, so clicking a
  still-warded row no-ops with that message.
- `FearWardHelper_WardNextTracked()` — like `WardNext` but **only the two tracked tiers**
  (shown + hidden); it **intentionally never sweeps**, regardless of `wardNextSweep`. For a
  "top off my watch-list only" keybind. Shares `wardNextTrackedTiers()` with `WardNext`.
- `FearWardHelper_WardNext()` — ward the next player, in **three tiers** (watch-list
  order = priority); tiers 1+2 are `wardNextTrackedTiers()`, tier 3 is the sweep:
  1. **Shown tracked** — the highest-priority present + unwarded *shown* entry is
     authoritative. Reachable (`castBlock` clear) → cast; unreachable → **block** (cast
     nobody) and, if `notifyCastFail`, push a "`Fear Ward blocked: <name> (out of range
     / no line of sight)`" line. Never falls through — you want to know your top tank is
     unreachable rather than silently warding someone lower. This is the only tier that
     blocks.
  2. **Hidden tracked** — entries in the `hidden` state: still WardNext priorities (and
     still notified), but rendered as no tracker row. Walked in priority order; the
     first present + unwarded **and reachable** one is warded. Unreachable ones are
     skipped (soft — never block), so a hidden target is a *preference* before the
     sweep, not a gate.
  3. **Sweep** (`wardNextSweep`) — any present group member who isn't already an
     **enabled (shown/hidden) tracked priority** — so untracked members *and* disabled
     (off) watch entries are both eligible (`off` = "don't prioritize", not "never
     ward"; shown/hidden are skipped here because tiers 1/2 covered them). Candidates
     are taken **by class** in `sweepClassOrder` (a class in `sweepClassDisabled` is
     ignored entirely — never swept), then `roster` order within a class; first unwarded
     **and reachable** one is warded. Once here we just want *a* ward out, so the
     specific target is secondary and unreachable ones are skipped. **Role/spec is
     undeterminable** for other players on this 1.12 client (no talent inspection —
     `INSPECT_TALENT_READY` is TBC+, `GetTalentInfo` is self-only), so **class**
     (`UnitClass` token, already in `classByName`) is the only per-unit proxy the sweep
     orders by.
  The soft tiers gate on `reachable()` (castOn's hard preconditions —
  `UnitExists`/`UnitIsVisible`/clear `castBlock`) so a stale/offline name is skipped
  rather than aborting the search (`castBlock` returns nil for a missing unit).

Casting sets no ward state itself; the resulting `UNIT_CASTEVENT "CAST"` (CD +
broadcast) and `BUFF_ADDED_*` (ward timer) events do.

### Row interaction (hover highlight + range/LOS)

The watch rows are clickable only as a **cast helper** (`canCast`). In **observer
mode** (not a Priest, or Fear Ward unknown) the rows are inert — the click is gated
on `canCast` (no cast attempt, no error spam) and the hover highlight never shows.
The highlight is a manually toggled `BACKGROUND` texture (`row.hl`), not a
`HIGHLIGHT`-layer texture, precisely so it can be suppressed in observer mode and
**recoloured** on hover.

When the mouse rests on a castable row, `refreshHover()` paints its range/LOS in red
with a **direction arrow** pointing the way to the target. Three states:

- **Out of cast range** — the status column shows the **yards still to close** (red),
  the arrow points which way to run. Gate, number *and* arrow all come from one source,
  `oorDistance()` (SuperWoW `UnitPosition`), so the countdown hits `0y` exactly when the
  row flips back to its ward timer. (Mixing sources is the trap we avoid: `castBlock`'s
  UnitXP `distanceBetween` reads ~`RANGE_SLACK` yards *lower* than raw `UnitPosition` on
  this client, so gating on one while numbering with the other flips the value early.)
- **No line of sight** (`LOS`) — in range but sight-blocked: status shows `LOS` (red)
  and the arrow still points the way so you can reposition for sight.
- **Castable** — a plain grey hover tint, no arrow.

`oorDistance` is the single OOR gate for the hover; `castBlock` is consulted only for
what `UnitPosition` can't measure — line of sight, or a unit out of object range
entirely (no position → a bare `OOR`, no arrow). `refreshHover` is called from the hover
handlers (snappy), **every `OnUpdate` frame** (so the arrow + distance track you and the
target moving), and at the end of every `refreshDisplay` tick. `hoveredWatchRow` holds
the active row; cleared (and the arrow hidden) on `OnLeave` and `setActive(false)`.
Off-hover the row keeps its normal ward status / timer — the OOR/arrow display is purely
a hover overlay (so a still-running ward timer stays visible when not pointed at).

`castBlock` uses **UnitXP_SP3** (`../UnitXP_SP3_Addon/`): `UnitXP("distanceBetween",
"player", unit)` (yards) and `UnitXP("inSight", "player", unit)` (LOS bool), detected
once and `pcall`-guarded since the addon is optional (`detectUnitXP`). Range is checked
first (the definite, common gate) with `RANGE_SLACK` yards of fudge (centre-to-centre
vs. the server's edge-to-edge, cf. pfUI `libs/librange.lua`); the same constant offsets
`oorDistance`'s threshold. Without UnitXP it falls back to `CheckInteractDistance(unit,
4)` (~28y follow range) for a coarse range gate only — no LOS test is possible, so `LOS`
never trips (and the OOR display leans on `UnitPosition` distance alone).

### Direction arrow

The arrow is a small texture on each watch row (left of the status text), shown only by
`refreshHover`, on the hovered row, when the target is out of cast reach (or LOS-blocked).

- **Atlas** — `textures/arrow.tga` (copied from pfQuest): a 512×512 sheet, a 9×12 grid
  of 56×42 frames = **108 pre-rotated arrows** (1.12 has no texture-rotation API), cell 0
  = pointing straight up / ahead. `setArrowCell` selects the frame for a relative angle
  via `SetTexCoord` — the sprite-atlas trick TomTom/pfQuest use. Geometry is fixed in the
  `ARROW_*` constants.
- **Bearing** — `arrowAngle(dx, dy)` = `ARROW_SIGN * (atan2(dy, dx) - facing) +
  ARROW_OFFSET`, with the world delta `(dx, dy)` from `UnitPosition` (+X north / +Y west)
  and `facing` from `playerFacing()`. `ARROW_SIGN`/`ARROW_OFFSET` are the one-time
  calibration of the atlas frame order vs. the facing convention (`1`/`0` for this
  client). `math.atan2` (radians) is used, not the global `atan2` (degrees).
- **Facing** — `playerFacing()` reads the heading with no dedicated API (this client has
  no `GetPlayerFacing`, and `UnitPosition` returns only x/y/z, no facing): it finds the
  **minimap player-arrow Model** — the one that rotates on a non-rotating minimap — by
  scanning `Minimap:GetChildren()` for a Model whose path is exactly `minimap\minimaparrow`,
  **not** a bare `minimaparrow` (which also matches the static `Rotating-MinimapArrow`
  decoy models this client parents to the minimap; they sit at facing 0 and would freeze
  the heading — found the hard way). Mirrors pfQuest's `compat/client.lua`. A rotating
  minimap would instead read `MiniMapCompassRing:GetFacing()`, but this client has no
  `rotateMinimap` CVar — `GetCVar` *throws* on an unknown CVar, hence the `pcall`.
- **Helpers** — `unitDelta(unit)` gives the player→unit delta with no range gate (the
  in-range LOS case); `showRowArrow(row, dx, dy)` points the (red) arrow or hides it when
  the delta/heading is unavailable.

## Notifications

A floating message area, `FearWardHelper_Notify`, showing transient lines that fade
out after a configurable delay. Two independently-toggleable kinds, all fed through
the same `pushNotification(text)` so colouring/stacking/fade are uniform.

### The stack engine

`notifications` is an active list (`{ born = GetTime(), text = }`, **newest first**)
backed by a pool of OVERLAY font strings (`notifyLines`, one per display row).
`pushNotification` prepends and drops the oldest past `NOTIFY_MAX` (so a burst stays
bounded); `layoutNotifications` (re)anchors each line and applies the **font size**
(`notifyFontSize` — the notify frame's "size", there is *no* resize grip).
`updateNotifications` ages lines out at `notifyDuration` and fades the last
`NOTIFY_FADE` seconds via `SetAlpha`. Player names are class-coloured with
`colorName(name)` (a `|cff…|r` span, white for unknown); the rest of each line is
wrapped in the default label colour (yellow) by `notifyLabel(text)`.

**Alignment/growth follow the frame's anchor point** (`notifyAlignment`): the anchor
you pin the area to is also where notifications align *and* the direction they fill,
so the corner stays put as lines come and go. Horizontal — `LEFT` → left-aligned,
`RIGHT` → right-aligned, else centred. Vertical — `TOP` → grow **down**, `BOTTOM` (and
vertical-centre) → grow **up**. The newest line sits at the anchor edge and older lines
stack away from it (each line is anchored by the matching corner — e.g. a `BOTTOMRIGHT`
area right-aligns and grows up). The lines have no fixed width, so the per-line anchor
point does the aligning (JustifyH only matters within a wrapped line). Lines (and the
unlocked handle) are inset from the touched edges by `NOTIFY_PAD` (`notifyPadOffset`)
so corner-anchored text clears the frame border instead of escaping it. `setAnchor` /
`resetLayout` re-run `layoutNotifications` since the point changed; a plain drag
(`OnDragStop`) keeps the point, so it doesn't.

The driver (`FearWardHelper_Notify_OnUpdate`) is bound to the notify frame in its
OnLoad and runs **independently of `active`** (guarded on `FearWardHelperDB` existing,
since it ticks before `VARIABLES_LOADED`), so a `Test` line fades while solo and an
in-flight fade finishes after a fight. Message *generation* is still gated on being
active (the events are). `clearNotifications` (called from `setActive(false)`) drops
the lines + pending batch.

### Who we announce about (`notifyAllowed`)

Both gains and losses share one gate: we **only ever notify about a unit actually in
the raid/party** (never an outsider we merely see in combat-log range). A tracked
(`activeWatchTarget` — enabled + present) name always qualifies; an **untracked** one
only when `notifyApplyUntracked` is on *and* they are in the group (`presentLower`). So
"Include untracked group members" widens both gain and loss to in-group non-watch-list
players, and the group requirement holds either way.

### Cast notifications (`notifyApply`)

Needs **source + target**, which only the cast paths carry (`BUFF_ADDED` has no
caster). Fired from `handleCast` (local `UNIT_CASTEVENT`) and `handleAddonMessage`
(sync, sender = caster). An in-range addon-running priest fires *both* for one cast,
so a `recentApply[caster..":"..target]` window (~1.5s) **dedups** the pair. Gated on
`notifyAllowed(target)`. Line: "`Fear Ward gained by <target> (<caster>)`" — both names
class-coloured.

### Loss notifications (`notifyLoss` + batching)

Fired from `handleBuffEvent(false)` (BUFF_REMOVED) **before** `clearWard` wipes the
timer, gated on `notifyAllowed(name)`. A predicted **expiry** (the persisted
`wardExpiresAt` is due within ~1s of `time()`) is reported on its own —
"`Fear Ward expired on <name>`" — and never batched (expiries don't cluster). Any
earlier loss is a fear/cancel and goes into `pendingLosses` (a name set); the first
such loss arms `lossFlushAt = GetTime() + NOTIFY_BATCH` (~0.4s). `flushLosses`
(polled in the notify OnUpdate) condenses the window: the **highest priority** name
(lowest `findWatchIndex`, forward-declared so the early batcher can call it) headlines
"`Fear Ward lost by <name>`" plus a "`(+N more)`" suffix when several dropped at once.
This is the AoE-fear de-spam.

### Low-duration notifications (`notifyLowDuration` + `checkLowDuration`)

Announces once when a warded target's countdown crosses **below** the `lowDuration`
threshold (the same threshold that paints the row orange / makes it a WardNext priority —
see "Low-duration warning"): "`Fear Ward running low on <name>`". Not event-driven (the
crossing happens with the passage of time, not on a combat-log event) — polled in the
throttled tick by `checkLowDuration`, which walks `wardExpiresAt` and, for each timer with
`0 < remaining < lowDuration`, fires if it hasn't already. The crossing edge is held in the
transient `lowNotified` set **regardless** of the `notifyLowDuration` toggle (cleared in
`clearNotifications`), so toggling the flag on mid-low doesn't retroactively fire for every
already-low ward, and a re-ward that lifts the timer back above the threshold re-arms the
warning. Only names `notifyAllowed` (a tracked active target, or an untracked in-group
member when `notifyApplyUntracked`) actually push a line; a `lowDuration` of 0 disables the
feature and forgets all crossings.

### CD-ready notifications (`checkCDReady` + `notifyCDReadyFor`)

`startCD(name)` marks `cdNotifyPending[name]`; the throttled tick's `checkCDReady`
fires once as each cooldown elapses (`GetTime() >= cdReadyAt`) and clears the pending
flag — **regardless** of the config gates (so a toggle flipped off mid-cooldown leaves
no stale entry, and one flipped on still announces). `notifyCDReadyFor` then gates by
who: **your own** ready (`name == playerName`) on `notifyCDReady` → "`Fear Ward ready`";
**another group priest's** on `notifyCDReadyGroup` → "`Fear Ward ready (<priest>)`"
(class-coloured, `presentLower`-gated so a non-group priest you merely observed in range
is skipped). Two independent toggles. `cdNotifyPending` is transient — cleared with
`cdReadyAt` in `setActive(false)`.

### Failed-cast notifications (`notifyCastFail`)

Not event-driven — pushed directly by `WardNext` (see "Casting") when its tier-1 (shown
tracked) target is present + unwarded but unreachable, so the cast is blocked rather
than dropped to a lower-priority unit. Line: "`Fear Ward blocked: <name> (out of range /
no line of sight)`", the reason taken from `castBlock`'s `"OOR"`/`"LOS"` return. Off by
default; only the shown-tracked tier blocks, so the hidden/sweep tiers never fire it.

### The frame

Moveable + anchorable like the trackers (`setupTrackerFrame`, `notifyFrame` DB layout,
default anchor **CENTER**) but with **no resize grip** — `setupTrackerFrame` and
`setLocked` guard the grip lookup. `applyBackdropAlpha` special-cases it: a faint grab
box + the `$parentHandle` label only while **unlocked** (positioning aid), fully
transparent while **locked** (the lines float on their own). That handle is re-pinned
to the notification anchor edge (via `notifyAlignment`) each time, so it previews
exactly where and how notifications will line up while you place the frame. It is `Show()`n for its
whole life (the lines, not the box, are the visible part). `lockAll`/`resetLayout`
include it; `setBgOpacity` does **not** (that's the two trackers).

## Activation

Active (frames shown; `UNIT_CASTEVENT`, `BUFF_ADDED_*`/`BUFF_REMOVED_*` and
`CHAT_MSG_ADDON` bound; `OnUpdate` running) while **grouped**, or always if
`showWhenSolo` — but **only when at least one priest is present** (`priests`
non-empty: no priest ⇒ no Fear Ward to track, so the addon stays hidden) and the
master **`hidden`** toggle (`/fw hide` · "Hide addon" checkbox) is off. Both gates are
applied in `rebuildRoster` before the `setActive(...)` call; the config panel itself is
not active-gated, so `/fw config` still opens to un-hide. `setActive` is idempotent and clears transient tracking on
deactivation. In `merged` mode `setActive`/`rebuildRows` keep `FearWardHelper_Watch`
hidden (its rows render inside the CD frame instead), so only the CD frame shows.
In split mode the watch frame is also hidden when no watched players are present.
The roster is rebuilt on `RAID_ROSTER_UPDATE` /
`PARTY_MEMBERS_CHANGED` / `PLAYER_ENTERING_WORLD` into `priests` (ordered, for the
CD frame), `roster` (ordered list of every present member's name, for the `WardNext`
sweep tier), `unitByName`, `nameByGuid` (resolve cast/buff events), `presentLower`
(case-insensitive name match), and `classByName` (name colour). GUIDs come from
`UnitExists(unit)`'s second return (SuperWoW), the same format as `UNIT_CASTEVENT`
`arg1` and the `BUFF_*` events' `arg1`. `canCast` is re-evaluated on
`SPELLS_CHANGED`. The `FearWardHelper_Notify` frame is the exception to active-gating:
it is `Show()`n for its whole life (transparent while locked + empty) and runs its own
`OnUpdate` regardless of `active`, so notifications fade and the area can be positioned
any time; only message *generation* is active-gated (`setActive(false)` calls
`clearNotifications`).

## Config (`/fw` + `/fw config` panel)

Slash: `config` (toggle the panel), `add` / `remove` / `list` / `up` / `down`
(watch-list + priority), `enable` (alias `show`) / `hide <name>` / `disable` (the three
watch states, below), `hide` / `unhide` (no name — the master `hidden` toggle that hides
the whole addon; alias `reveal`), `sweep <on|off>` (the WardNext untracked fallback),
`merge` / `split` (single vs two frames; **merged is the default**), `lock` / `unlock`, `scale <0.5-2>`,
`low <0-120>` (the low-duration warning threshold; alias `lowdur`/`lowduration`),
`reset` (layout only; watch-list kept), and
`notify <cast|loss|low|castfail|cd|groupcd|untracked> <on|off>` / `notify duration <s>` /
`notify font <size>` / `notify test` (the `notifyCmd` dispatcher). Stored in
`FearWardHelperDB` (`watchList` ordered array, `watchDisabled` + `watchHidden` sets,
`sweepClassOrder` ordered class-token array + `sweepClassDisabled` set (the sweep's
class priority), per-frame `cdFrame` / `watchFrame` / `notifyFrame` layout,
`showWhenSolo`, `hidden`, `merged`, `bgOpacity`, `wardNextSweep`, `lowDuration`, and the notification flags
`notifyApply` /
`notifyApplyUntracked` / `notifyLoss` / `notifyLowDuration` / `notifyCastFail` / `notifyCDReady` /
`notifyCDReadyGroup` / `notifyDuration` / `notifyFontSize`). Names are stored tidied
(first letter capitalized) and matched case-insensitively.

**Watch states (shown / hidden / off)** — each watch-list entry (keeping its priority
slot) is in one of three states, a linear "level of involvement":

- **shown** — tracked, rendered as a tracker row, a WardNext priority, notified.
- **hidden** — still a WardNext priority and still notified, but **no tracker row**
  (background priority you don't want cluttering the list); e.g. an off-tank you want
  topped off by `WardNext` but not staring at.
- **off** (*disabled*) — kept in the list but not a tracked priority (no row, no
  priority slot in `WardNext` tiers 1/2, no notification); e.g. someone not tanking
  tonight but back next raid, so you don't remove + re-add them. Still **sweep-eligible**
  (tier 3) — off means "don't prioritize", not "never ward".

Stored as two sets keyed by lowercased name — `watchDisabled` (off) and `watchHidden`
(hidden), both default-empty so old lists upgrade; off wins if both are set.
`watchState(name)` returns `"shown"`/`"hidden"`/`"off"`. **Two gates, not one**:
`activeWatchTarget(name)` (enabled — shown *or* hidden — **and** present ⇒ roster name)
is what `WardNext`, `notifyAllowed` and the loss-batcher use, so hidden entries stay
in priority + notifications; `visibleWatchTarget(name)` (shown **and** present) is the
narrower gate `rebuildRows` (the rows + `visibleTargets` count) uses, so hidden entries
draw no row. `setWatchState(name, state)` writes both sets; `cycleWatchState` rotates
shown → hidden → off (the config-list button); `removeWatch` clears both so a re-add
starts shown.

**Config UI** (`/fw config`) — a hand-rolled panel (`FearWardHelper_Config`, built
lazily in Lua in `buildConfig`, *not* pfUI's framework / not Blizzard's
`UIDropDownMenu`). It is purely a front-end: every widget calls the same setters
the slash commands do (`addWatch` / `removeWatch` / `moveWatch` / `setMerged` /
`lockAll` / `setShowWhenSolo` / `setScale` / `setBgOpacity` / `setAnchor` /
`setFramePos` / `resetLayout`). The DB is the single source of truth; `refreshConfig()` re-reads it
into every widget and is poked by **all** of those setters and by the frames'
drag/resize handlers (`OnDragStop` / `StopSizing`), so the panel, the slash
commands and live dragging never disagree. `refreshConfig` is forward-declared up
top (nil until assigned; callers guard `if refreshConfig then`) and no-ops when the
panel is closed.

Panel contents (a **two-column** layout — the panel is widened to ~360 so paired
checkboxes/sliders sit side by side): a scrollable watch-list editor
(`VISIBLE_ROWS` = 5 visible at a time, backed by a `FauxScrollFrame`; each row has a
**tri-state button** (`S`/`H`/`O`) + ^/v/X buttons — the button calls `cycleWatchState`
to rotate shown → hidden → off, the name greying/tagging to match (`(hidden)` dim grey,
`(off)` grey, else class-coloured, `(away)` if absent)), an add box, five checkboxes
(single combined frame / lock / show-when-solo / "Hide addon" = `hidden` (the master
hide toggle, routed through `setHidden`) / "Allow Ward untracked" =
`wardNextSweep`), and **five sliders** (`LibWidgets.NewSlider`, an
`OptionsSliderTemplate` whose `$parentText` carries the live value via each
slider's own `format(v)` spec field): **scale** (0.5–2.0, driving `setScale`
with a `silent` arg so dragging doesn't spam chat), **background opacity** (0–1,
`setBgOpacity`), **low-ward warning** (0–120s, step 5, `setLowDuration` — its own row
under scale/opacity; `0` = off, see "Low-duration warning"), **fade duration** (1–10s,
`setNotifyDuration`) and **font size** (8–24, `setNotifyFontSize`). Each slider guards
its own `.setValue(v)` internally, so `refreshConfig` just calls it to resync from the
DB without a panel-level flag or echoing back through `onChange`. A **Notifications**
block (its `cfgHeader` carries the **Test** button — a `LibWidgets.NewButton` — to its
right, which pushes sample lines via `notifyTest`) holds seven
checkboxes — announce casts / announce ward loss, then include untracked players
(indented under them, since it modifies both gains and losses) beside announce failed
casts (`notifyCastFail`), then announce CD ready / announce group CD ready, then announce
low ward (`notifyLowDuration` — fires when a tracked ward drops below the low-ward slider) —
above the fade/font sliders. All boolean notify toggles **and** the `wardNextSweep` toggle route
through one shared `setNotifyFlag(flag, on)` (a plain boolean DB write + `refreshConfig`)
rather than a setter each. (The slash-only `setWardNextSweep` exists just to also print
a chat line; the panel deliberately doesn't reference it.)

**Upvalue budget.** Lua 5.0 caps a function at **32 upvalues** (every chunk-level local
a nested handler references counts as one for the enclosing `buildConfig`), and the panel
was right at the edge. To stay clear, the local widget factories + setters `buildConfig`
closes over are **bundled into two tables built just above it** — `ui` (the remaining
`cfg*` factories: `cfgHeader` / `cfgCheck` / `cfgPosRow`) and `act` (the
setters) — so the body reaches them as `ui.cfgCheck` / `act.setMerged`, costing **one
upvalue per table** instead of one per function. Buttons, text boxes, sliders and the
anchor drop button are `LibWidgets.NewButton` / `NewTextBox` / `NewSlider` /
`NewDropButton` calls instead — `LibWidgets` is a *global* (assigned via
`LibStub:NewLibrary`, not a chunk-level `local`), so referencing it from inside
`buildConfig` costs **no upvalue at all**, same as the `LibWidgets.NewListEditor` calls
already used for the watch-list and class-priority editors. That's headroom freed, not
spent, when a widget moves to the shared library. The roster tables that are
*reassigned* wholesale each `rebuildRoster` (`presentLower`, `classByName`) must stay
**direct** upvalues so the closure sees the new value — they're deliberately not
bundled; `watchState` / `classColor` stay direct too (cheap). So adding a new
widget/setter: reach for a `LibWidgets.New*` call first: if none fits, put the function
in `ui`/`act` (or reuse `setNotifyFlag` for a plain boolean) rather than referencing a
fresh chunk-level local from inside `buildConfig`.
Finally per-frame **anchor** controls — each a single row
(`cfgPosRow`): a name label, a `LibWidgets.NewDropButton` (values = the nine
`ANCHOR_POINTS`, no labels needed since the point name **is** the label) and X/Y
`LibWidgets.NewTextBox` boxes, one row each for the CD, Target and Notify frames.
`p.layoutPos(merged)` (called from `refreshConfig`) stacks those rows, **hides the
Target row and reclaims its space in merged mode**, then pins the Reset button below
the last row and resizes the panel — so split mode grows the panel rather than leaving
a gap. Category headers use `cfgHeader` (a slightly larger yellow font than the
per-widget `cfgLabel`); the title is +2pt. The remaining small local factories
(`cfgLabel` / `cfgHeader` / `cfgCheck` / `cfgPosRow`) keep it terse; standard 1.12
templates (`UICheckButtonTemplate` / `UIPanelCloseButton`) back the checkbox/close-X,
while buttons, edit boxes, sliders, the anchor picker and the watch-list's own add
row are all `LibWidgets` widgets sharing one tooltip-style backdrop look (see
[Libs/LibWidgets/CLAUDE.md](Libs/LibWidgets/CLAUDE.md)) instead of a
per-addon `InputBoxTemplate`/`UIPanelButtonTemplate` mix. At most one anchor-picker
popup is ever open at once (`LibWidgets.CloseAllMenus()`, closed by touching any
other widget in the panel); `buildConfig` also wires the panel's own `OnMouseDown`
(a blank-area click) and `OnHide` to it, since those are the one gap the library's
own per-widget closing can't reach (see LibWidgets' CLAUDE.md for why there's no
screen-covering click-catcher instead).

**Class-priority popup** — a **Class priority** button beside the "Tracked players"
header opens `FearWardHelper_ClassPriority` (`buildClassPriority`, built lazily), a small
separate frame parented to the config panel: one **fixed** row per class (the nine
`CLASS_TOKENS`, *no* add/remove and no scroll — all visible at once), each a
class-coloured class name with an enable checkbox + ^/v buttons. Reordering
(`moveSweepClass`) sets `sweepClassOrder`; the checkbox (`setSweepClassEnabled`) flips
`sweepClassDisabled` — an **unchecked class is ignored entirely by the sweep** (tier 3),
not just deprioritized. It has its own `refresh` (re-reads the DB) and its own
`buildClassPriority` upvalue budget — and the config button's toggle is an **inline
`OnClick` handler** that calls `buildClassPriority` then shows/hides `classPanel`. (It
was once the global `FearWardHelper_ToggleClassPriority` to spend zero `buildConfig`
upvalues, but the `ui`/`act` bundling freed enough room to inline it; `classPanel` is
reassigned wholesale in `buildClassPriority`, so — like `presentLower`/`classByName` —
it must stay a **direct** upvalue, never bundled into `act`, to see the new value.)
Being a *child* of the config panel, it hides automatically when the panel
closes (no `OnHide` handler — which would itself capture `classPanel` as a `buildConfig`
upvalue).

## Layout

- [FearWardHelper.lua](FearWardHelper.lua) — all logic (including the config panel,
  built in Lua so it can reach the existing local setters directly).
- [FearWardHelper.xml](FearWardHelper.xml) — the two moveable tracker frames
  (`FearWardHelper_CD` = engine + CD list, `FearWardHelper_Watch` = watch/cast
  list) plus the `FearWardHelper_Notify` notification area (see "Notifications").
  Rows / notification lines are built in Lua; backdrops applied in `OnLoad`. The two
  tracker frames have a bottom-right **width grip** (`$parentResizeGrip`, shown only
  while unlocked, its frame level raised in `OnLoad` so the clickable watch rows
  don't eat its mouse): `StartSizing("RIGHT")` resizes **width only** — height is
  content-driven (`sizeFrame` fits the row count), so no height clamp is needed.
  Saved width is `cdFrame.width` / `watchFrame.width`. The notify frame has **no
  grip** (its "size" is the font size) — `setupTrackerFrame` / `setLocked` guard the
  grip lookup so it works without one.
- **Merged (single-frame) mode** (`merged` in the DB) — `rebuildRows` stacks both
  lists inside `FearWardHelper_CD`: CD rows, then a divider line + "Targets"
  sub-header (`getTargetHeader`, lazily created on the CD frame), then the watch
  rows, and hides `FearWardHelper_Watch`. The divider sits above the header text
  (with a small gap from the last CD row) so it visually separates the two
  sections. The target section (divider + header + watch rows) is only shown when
  at least one watched player is present in the group; otherwise the CD frame sizes
  to just the priest rows. Rows no longer self-anchor at creation; `makeRow` just
  builds the widgets and `placeRow` (re-)parents + positions them each rebuild, so
  a pooled watch row works in either frame. Merged mode reuses the `cdFrame` layout
  entry (position/scale/lock/width) — toggling merge does not introduce a third
  layout. The CD title swaps between "Fear Ward CDs" (split) and "Fear Ward"
  (merged).
- `textures/ResizeGrip.tga` — the grip glyph, bundled because this client lacks
  Blizzard's chat SizeGrabber textures (copied from PrayerHelper).
- `textures/arrow.tga` — the 108-frame pre-rotated arrow atlas for the hover direction
  arrow (copied from pfQuest; see "Direction arrow").
- [FearWardHelper.toc](FearWardHelper.toc) — manifest + SavedVariables.
- [pack.ps1](pack.ps1) — builds `FearWardHelper.zip`.

## Open TODOs / known gaps

1. **Config UI polish** — no minimap button, no per-frame scale (scale is shared).
   The custom anchor "dropdown" doesn't auto-close on outside click (re-click the
   button or pick an item). All deliberately minimal — the panel is a thin front-end
   over the setters, so extending it is additive.
2. **Out-of-range / pre-existing ward state** — wards applied in combat-log range
   are tracked exactly (events); a ward applied out of sight, or already up before
   you arrived, falls back to the predicted/persisted timer or a bare "warded"
   until a scan or event sees it (see "Ward tracking").
3. **`BUFF_*_OTHER` caster scope** unconfirmed — may fire for all in-range casts or
   only your own; the poll covers others regardless, so it's not load-bearing.
4. **Reduced (not absent) tracking without SuperWoW** — frames still show, the cast
   helper works (icon-fallback name resolution, see "Casting"), ward presence is
   polled via base-API `UnitBuff` (your own timer exact via `GetPlayerBuffTimeLeft`),
   and cooldowns still arrive over sync from other FearWardHelper users. What's lost:
   local cast observation (`UNIT_CASTEVENT`) and the event-driven `BUFF_*` ward
   signal — so your *own* cooldown after casting won't self-populate, and others'
   wards are only seen in buff-scan range. A warning prints once.

## Reference addons

We edit in place inside a live `Interface/AddOns` directory, so sibling addons
double as API references. The ones that actually shaped this addon:

- **PrayerHelper** (`../PrayerHelper/`) — our other 1.12 Priest addon and the direct
  scaffolding here. Source for the moveable/resizable frame pattern, the
  SavedVariables defaults merge, the slash-command shape, activation gating, the
  `UNIT_CASTEVENT` plumbing, locale-independent icon matching, and the bundled
  `ResizeGrip.tga` (this client lacks Blizzard's chat SizeGrabber textures).
- **DoiteAuras** (`../DoiteAuras/Modules/DoiteTargetAuras.lua`) — where the custom
  combat-log buff events came from. Confirms `BUFF_ADDED_*`/`BUFF_REMOVED_*` exist
  on this client and their arg layout (`arg1` = unit GUID, `arg3` = spell id), and
  `AURA_CAST_ON_*` (`arg1` = spellId, `arg2` = caster, `arg3` = target, `arg8` =
  durationMs — which we don't need, Fear Ward's duration is fixed).
- **pfUI** — general 1.12/SuperWoW API reference:
  - `modules/mouseover.lua` — the targeted-cast idiom we mirror in `castOn`: Nampower
    `CastSpellByName(spell, unit)`, else `AutoSelfCast`-off + `SpellTargetUnit`.
  - `api/unitframes.lua` / `modules/buff.lua` — `GetPlayerBuffTimeLeft` for the
    player's own buff durations (our `selfWardTimeLeft`); also showed `UnitBuff`'s
    extended returns, which an in-game probe then pinned down for this client.
  - `libs/librange.lua` / `modules/unitxp.lua` — the UnitXP_SP3 range/LOS idiom our
    `castBlock` mirrors: `pcall(UnitXP, "distanceBetween"/"inSight", "player", unit)`,
    detected once, with a small range fudge (centre-to-centre vs. edge-to-edge). Its
    `UnitPosition` distance path is also what `oorDistance` uses for the hover arrow.
- **pfQuest** (`../pfQuest/`) — the model for the hover **direction arrow** (see
  "Direction arrow"). `route.lua` is the sprite-atlas arrow: the bundled `img/arrow.tga`
  (copied to our `textures/`) and the 108-frame `SetTexCoord` cell math (no
  texture-rotation API on 1.12). `compat/client.lua` is the locale-free **player-facing**
  read off the minimap player-arrow Model (with the rotating-minimap `MiniMapCompassRing`
  branch). TomTom-TWOW (`../TomTom-TWOW/`) is the same atlas/`atan2` idiom one step
  upstream. World coords for the bearing come from SuperWoW `UnitPosition` (x/y/z — no
  facing, which is why the heading is read off the minimap).
- **UnitXP_SP3** (`../UnitXP_SP3_Addon/`) — the client-side service exposing
  `UnitXP("distanceBetween", a, b)` (yards) and `UnitXP("inSight", a, b)` (LOS bool),
  used by the watch-row hover range/LOS check (`castBlock`). Optional: without it the
  check degrades to a coarse `CheckInteractDistance` range gate and no LOS.
- **DPSMate** (`../DPSMate/DPSMate_Sync.lua`) — proof that `SendAddonMessage` works
  on this client (via `ChatThrottleLib:SendAddonMessage`); the model for our cast
  broadcast (we send direct, one tiny message per cast, so no ChatThrottleLib).
- **ShaguTweaks** (`../ShaguTweaks/mods/superwow.lua`) — the canonical `UNIT_CASTEVENT`
  handler: it fires for **every** unit's casts (`arg1` GUID, `arg3` action, `arg4`
  spellId, `arg5` cast time), which is what lets us observe other priests' casts.
  Also uses `StartSizing("RIGHT")` (via Waterfall) — confirms width-only resize.

## 1.12 client gotchas

Same as PrayerHelper — see `../PrayerHelper/CLAUDE.md`. Most relevant here:
`UNIT_CASTEVENT` (SuperWoW) for casts, no `C_*` namespaces, vanilla Lua 5.0
(`string.gfind`, `table.getn`, no `#`), `getglobal`, and addon comms via
`SendAddonMessage` + `CHAT_MSG_ADDON` (`arg1` prefix … `arg4` sender).

**No Lua compiler / interpreter is available in this environment** — do not try to
`lua`, `luac`, `luajit`, etc. to syntax-check or run the addon. There is nothing to
run it against outside the game client (the runtime is vanilla Lua 5.0 *inside* WoW,
with the WoW API). Verification is by reading the code and loading it in-game; there
is no offline build/lint/run step.
