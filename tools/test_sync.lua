package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")

local function approx(a, b, e) return math.abs(a - b) < (e or 1e-6) end

local function fresh(cfg)
  Mock.install()
  for _, m in ipairs({ "IPCore", "IPReaper", "IPApp" }) do package.loaded[m] = nil end
  local App = require("IPApp")
  local app = App.new()
  for k, v in pairs(cfg or {}) do app.cfg[k] = v end
  local P = { app = app }
  P.gtr   = Mock.track("Guitar", 0)
  P.bass  = Mock.track("Bass", 0)
  P.drums = Mock.track("Drums", 0)
  P.keys  = Mock.track("Keys", 0)
  P.g = Mock.item(P.gtr, 10, 2, "/s/riff.wav")
  P.b = Mock.item(P.bass, 10, 1, "/s/bass.wav")
  return P
end

local function stash(P, name, mode)
  Mock.select({ P.g, P.b })
  local cid = P.app:stash(name or "Riff", mode)
  P.lane = Mock.track_named("IDEAS")
  P.cid = cid
  return cid
end

local function card(P) return P.app:card_view(P.cid) end
local function at(track, pos)
  for _, it in ipairs(track.items) do if approx(it.p.D_POSITION, pos, 1e-4) then return it end end
end
local function n(track) return #track.items end
local function pool(P) return require("IPCore").json_decode(P.lane.ext.IP_pool) end

------------------------------------------------------------------------------------------------ stash
do
  local P = fresh()
  local cid = stash(P)
  T.ok(cid ~= nil, "stash returns the new idea")
  T.eq(Mock.S.tracks[1].name, "IDEAS", "IDEAS lane created at the top")
  local c = card(P)
  T.eq(c.name, "Riff", "idea named"); T.eq(#c.variants, 1, "one variant"); T.eq(c.variants[1].name, "A", "called A")
  T.eq(#c.slots, 2, "two track slots"); T.eq(c.slots[1].name, "Guitar", "slot 1 = Guitar")
  T.eq(#c.variants[1].members, 2, "two items in the variant")
  T.ok(P.g.ext.IP_m == nil, "default 'keep': the selected items stay plain (copy)")
  T.eq(n(P.gtr) + n(P.bass), 2, "nothing added to the timeline")
  T.ok(c.variants[1].level and approx(c.variants[1].level, -4.26, 0.05), "level measured (gated average: 1 s at -3 dB, 1 s at -6 dB)")
  T.eq(Mock.S.undo[#Mock.S.undo], "IdeaPool: stash items", "one undo step")
  T.eq(P.app.selected, cid, "new idea is opened")
  T.ok(not P.app:sync(), "stable")

  Mock.select({ P.g }); local c2 = P.app:stash("riff")
  T.eq(P.app:card_view(c2).name, "riff 2", "names stay unique (case-insensitive)")
  local k = Mock.item(P.keys, 5, 1, "/s/pad.wav")
  Mock.select({ k }); local c3 = P.app:stash("")
  T.eq(P.app:card_view(c3).name, "pad", "default name from the take")
  Mock.select({}); T.ok(not P.app:stash("x"), "nothing selected is refused")

  local L = fresh(); stash(L, "Riff", "link")
  T.ok(L.g.ext.IP_m ~= nil, "'link': the items become the first placement")
  T.eq(#Mock.items_on(L.lane), 1, "placement on the IDEAS lane")
  T.eq(card(L).places[1].kind, "linked", "linked placement")
  T.ok(not L.app:sync(), "stable after link")

  local R = fresh(); stash(R, "Riff", "remove")
  T.eq(n(R.gtr) + n(R.bass), 0, "'remove': the items are gone from the timeline")
  T.eq(#card(R).variants[1].members, 2, "but kept in the idea")
end

------------------------------------------------------------------------------------------------ place / linked
do
  local P = fresh(); stash(P, "Riff", "remove")
  Mock.S.cursor = 30; P.app:place(P.cid, "cursor")
  Mock.S.cursor = 40; P.app:place(P.cid, "cursor")
  T.eq(#Mock.items_on(P.lane), 2, "two placements")
  local g30, g40 = at(P.gtr, 30), at(P.gtr, 40)
  T.ok(g30 and g40 and at(P.bass, 30) and at(P.bass, 40), "items placed on the tracks they came from")
  T.eq(g30.p.D_LENGTH, 2, "full length")
  T.eq(Mock.all_guids(), 0, "fresh GUIDs for every placed item")
  T.eq(Mock.items_on(P.lane)[1].takes[1].name, "Riff · A [" .. P.cid .. "]", "placement shows idea and variant")
  Mock.set(g30, "D_VOL", 0.5); P.app:sync()
  T.ok(approx(g40.p.D_VOL, 0.5), "editing one placement changes the other (linked)")
  Mock.nudge(at(P.bass, 30), 0.5); P.app:sync()
  T.ok(at(P.bass, 40.5) ~= nil, "moving an item inside a placement moves it in the others")
  T.ok(not P.app:sync(), "stable")
  -- the placement item works like an AliasTrack alias
  local a40 = Mock.items_on(P.lane)[2]
  Mock.nudge(a40, 5); P.app:sync()
  T.ok(at(P.gtr, 45) ~= nil and at(P.gtr, 40) == nil, "moving a placement moves its items")
  Mock.split(a40, 46); P.app:sync()
  T.eq(#Mock.items_on(P.lane), 3, "splitting a placement = two placements")
  T.eq(n(P.gtr), 3, "guitar split once, not doubled")
  local c = Mock.copy(Mock.items_on(P.lane)[1], P.lane, 60); P.app:sync()
  T.ok(at(P.gtr, 60) ~= nil, "a copied placement is linked and filled")
  T.ok(approx(at(P.gtr, 60).p.D_VOL, 0.5), "with the idea's current state")
  Mock.delete(c); P.app:sync()
  T.ok(at(P.gtr, 60) == nil, "deleting a placement deletes its items")

  -- on the selected track: slot 1 there, slot 2 keeps its distance
  Mock.S.cursor = 80; Mock.select_track(P.drums); P.app:place(P.cid, "selected")
  T.ok(at(P.drums, 80) ~= nil, "guitar part on the selected track (Drums)")
  T.ok(at(P.keys, 80.5) ~= nil, "bass part one track below (Keys)")
  T.ok(at(P.gtr, 80) == nil, "not on the original track")
  T.ok(at(P.gtr, 30) ~= nil and at(P.drums, 30) == nil, "existing placements did not move to the new tracks")
  -- origin
  P.app:place(P.cid, "origin")
  T.ok(at(P.gtr, 10) ~= nil, "placed where it came from, on its own tracks")
end

------------------------------------------------------------------------------------------------ freeze / detach
do
  local P = fresh(); stash(P, "Riff", "remove")
  Mock.S.cursor = 30; P.app:place(P.cid, "cursor")
  Mock.S.cursor = 40; P.app:place(P.cid, "cursor")
  local p40 = card(P).places[2].pid
  P.app:freeze(P.cid, p40, true)
  T.eq(card(P).places[2].kind, "frozen", "frozen")
  T.ok(Mock.items_on(P.lane)[2].takes[1].name:sub(1, 2) == "* ", "frozen placement marked in its name")
  Mock.set(at(P.gtr, 30), "D_VOL", 0.25); P.app:sync()
  T.ok(approx(at(P.gtr, 40).p.D_VOL, 1), "a frozen placement does not follow")
  Mock.set(at(P.gtr, 40), "D_VOL", 0.8); P.app:sync()
  T.ok(approx(at(P.gtr, 30).p.D_VOL, 0.25), "and its own edits do not reach the idea")
  P.app:freeze(P.cid, p40, false)
  T.ok(approx(at(P.gtr, 40).p.D_VOL, 0.25), "unfreeze: shows the idea again")
  T.eq(card(P).places[2].kind, "linked", "linked again")
  P.app:detach(P.cid, p40)
  T.eq(#Mock.items_on(P.lane), 1, "detach removes the placement")
  T.ok(at(P.gtr, 40) ~= nil and at(P.gtr, 40).ext.IP_m == nil, "its items stay as plain items")
  Mock.set(at(P.gtr, 30), "D_VOL", 0.1); P.app:sync()
  T.ok(approx(at(P.gtr, 40).p.D_VOL, 0.25), "and are independent")
end

------------------------------------------------------------------------------------------------ variants + loudness
do
  local P = fresh(); stash(P, "Riff", "remove")
  Mock.S.cursor = 30; P.app:place(P.cid, "cursor")
  Mock.S.cursor = 40; P.app:place(P.cid, "cursor")
  local g30 = at(P.gtr, 30)
  local vA = card(P).variants[1].vid
  local vB = P.app:duplicate_variant(P.cid, vA)
  T.eq(#card(P).variants, 2, "duplicate = second variant"); T.eq(card(P).active, vB, "and active")
  T.eq(card(P).variants[2].name, "B", "called B")
  Mock.set(g30, "D_VOL", 0.5); P.app:sync()
  local c = card(P)
  T.ok(approx(c.variants[2].members[1].vol, 0.5), "edit goes into B")
  T.ok(approx(c.variants[1].members[1].vol, 1), "A is untouched")
  T.ok(approx(c.variants[2].level, c.variants[1].level - 3.01, 0.05), "B's level follows its volume (guitar -6 dB)")
  P.app:set_active(P.cid, vA)
  T.ok(approx(at(P.gtr, 40).p.D_VOL, 1) and approx(g30.p.D_VOL, 1), "switch to A: every placement shows A")
  T.ok(at(P.gtr, 30) == g30, "same items, updated in place (A and B share their items)")
  T.eq(Mock.items_on(P.lane)[1].takes[1].name, "Riff · A [" .. P.cid .. "]", "placement names the variant")
  P.app:set_active(P.cid, vB)
  T.ok(approx(g30.p.D_VOL, 0.5), "back to B")

  -- loudness match: B is quieter, it is played louder so A/B compares the sound
  P.app:set_match(P.cid, true)
  c = card(P)
  T.ok(c.variants[2].gain_db > 3, "B gets a positive match gain: " .. c.variants[2].gain_db)
  T.ok(g30.p.D_VOL > 0.7, "and its items play louder")
  T.ok(approx(c.variants[1].gain_db, 0, 0.01), "A is the reference")
  -- an edit while matched is stored without the match gain
  local shown = g30.p.D_VOL
  Mock.set(g30, "D_VOL", shown * 0.5); P.app:sync()
  c = card(P)
  T.ok(approx(c.variants[2].members[1].vol, 0.25, 1e-3), "edit while matched: the idea gets the real volume (0.25)")
  P.app:set_match(P.cid, false)
  T.ok(approx(g30.p.D_VOL, 0.25, 1e-3), "matching off: plain volumes again")
  P.app:delete_variant(P.cid, vB)
  T.eq(#card(P).variants, 1, "variant deleted"); T.eq(card(P).active, vA, "A active again")
  T.ok(approx(g30.p.D_VOL, 1), "placements show A")

  -- save a (frozen, edited) placement as a variant
  local p40 = card(P).places[2].pid
  P.app:freeze(P.cid, p40, true)
  Mock.set(at(P.gtr, 40), "D_FADEINLEN", 0.3); Mock.nudge(at(P.bass, 40), 0.25)
  local vC = P.app:save_variant(P.cid, p40)
  c = card(P)
  T.eq(c.active, vC, "saved variant is active"); T.eq(c.variants[#c.variants].name, "C", "named C")
  T.eq(card(P).places[2].kind, "linked", "the placement follows again")
  T.ok(approx(at(P.gtr, 30).p.D_FADEINLEN, 0.3), "the other placement shows the new variant (fade)")
  T.ok(at(P.bass, 30.25) ~= nil, "and the moved bass")
  T.ok(not P.app:sync(), "stable")

  -- numeric edit from the window
  P.app:set_member(P.cid, vC, 1, "fout", 0.4)
  T.ok(approx(at(P.gtr, 30).p.D_FADEOUTLEN, 0.4) and approx(at(P.gtr, 40).p.D_FADEOUTLEN, 0.4), "fade edited in the window reaches every placement")
  P.app:set_member(P.cid, vC, 1, "len", 1)
  T.ok(approx(at(P.gtr, 30).p.D_LENGTH, 1), "length edited in the window")
end

------------------------------------------------------------------------------------------------ markers
do
  local P = fresh(); stash(P, "Riff", "remove")
  T.ok(P.app.cfg.marker_prefix == nil, "no prefix setting any more")
  Mock.marker("riff", 50); P.app:sync()
  T.ok(at(P.gtr, 50) ~= nil and at(P.bass, 50) ~= nil, "a marker named like the idea places it there")
  local c = card(P)
  T.eq(c.markers, 1, "counted"); T.eq(c.places[1].kind, "marker", "kind marker")
  T.eq(Mock.items_on(P.lane)[1].takes[1].name:sub(1, 2), "> ", "marked in its name")
  local idx = Mock.S.markers[1].idx
  Mock.move_marker(idx, 55); P.app:sync()
  T.ok(at(P.gtr, 55) ~= nil and at(P.gtr, 50) == nil, "the placement follows its marker")
  Mock.nudge(Mock.items_on(P.lane)[1], 3); P.app:sync()
  T.ok(at(P.gtr, 55) ~= nil, "a hand move snaps back to the marker")
  Mock.marker("Riff", 70, 70.5); P.app:sync()
  T.ok(at(P.gtr, 70) ~= nil and approx(at(P.gtr, 70).p.D_LENGTH, 0.5), "a region trims it")
  T.eq(card(P).markers, 2, "two marker placements")

  -- renaming the idea renames the markers that place it
  P.app:rename(P.cid, "Hook")
  T.eq(Mock.S.markers[1].name, "Hook", "marker 1 follows the idea's name"); T.eq(Mock.S.markers[2].name, "Hook", "region too")
  T.ok(at(P.gtr, 55) ~= nil and at(P.gtr, 70) ~= nil, "and the placements stay")
  T.eq(card(P).name, "Hook", "renamed")
  Mock.marker("Verse", 5); P.app:rename(P.cid, "Chorus")
  T.eq(Mock.S.markers[3].name, "Verse", "other markers are left alone")

  -- renaming a marker away removes its placement and items
  Mock.S.markers[1].name = "Verse 2"; P.app:sync()
  T.ok(at(P.gtr, 55) == nil, "marker renamed away: the placement and its items go")
  -- Keep: the placement stays, the marker goes
  local pid = card(P).places[1].pid
  P.app:keep(P.cid, pid)
  T.eq(card(P).places[1].kind, "linked", "kept: an ordinary placement")
  local left = {}
  for _, mk in ipairs(Mock.S.markers) do left[#left + 1] = mk.name end
  T.ok(not table.concat(left, ","):find("Chorus"), "its marker is removed")
  T.ok(at(P.gtr, 70) ~= nil, "items stay"); T.eq(#Mock.items_on(P.lane), 1, "and nothing is placed twice")
  T.ok(not P.app:sync(), "stable")
  -- Detach on a marker placement removes the marker too
  Mock.marker("Chorus", 90); P.app:sync()
  local p90
  for _, p in ipairs(card(P).places) do if approx(p.pos, 90) then p90 = p.pid end end
  P.app:detach(P.cid, p90)
  T.ok(at(P.gtr, 90) ~= nil and at(P.gtr, 90).ext.IP_m == nil, "detached: plain items")
  local names = {}
  for _, mk in ipairs(Mock.S.markers) do names[#names + 1] = mk.name end
  T.ok(not table.concat(names, ","):find("Chorus"), "and the marker is gone, so nothing is placed again")
  -- a v0.2.0 project: "a:" marker tags still work
  local Q = fresh(); stash(Q, "Riff", "remove"); Mock.marker("Riff", 20); Q.app:sync()
  local al = Mock.items_on(Q.lane)[1]
  al.ext.IP_mode = al.ext.IP_mode:gsub("^m:", "a:"); Q.app:sync()
  T.eq(card(Q).places[1].kind, "marker", "old 'a:' tag is read as a marker placement"); T.eq(#Mock.items_on(Q.lane), 1, "not duplicated")
end

------------------------------------------------------------------------------------------------ solo audition
do
  local P = fresh(); stash(P, "Riff", "remove")
  P.gtr.fxchain = "<FXCHAIN\nSHOW 0\n<VST \"ReaEQ\"\nFXID {AAAA0001-0000-4000-8000-000000000001}\n>\n>"
  P.keys.solo = 1                                        -- the user had Keys soloed
  Mock.S.cursor = 20
  P.app:sync()
  local undo_before = #Mock.S.undo
  T.ok(P.app:audition(P.cid), "audition starts")
  local tmp = {}
  for _, t in ipairs(Mock.S.tracks) do if t.ext.IP_lane == "audition" then tmp[#tmp + 1] = t end end
  T.eq(#tmp, 2, "one temporary track per original track")
  T.eq(tmp[1].name, "IdeaPool audition: Guitar", "named")
  T.ok(at(tmp[1], 20) ~= nil and at(tmp[2], 20) ~= nil, "the idea is placed on them, at the cursor")
  T.ok(at(P.gtr, 20) == nil, "not on the original tracks")
  T.eq(tmp[1].solo, 2, "temporary tracks soloed"); T.eq(P.keys.solo, 0, "the user's own solo is cleared meanwhile")
  T.ok(tmp[1].fxchain and tmp[1].fxchain:find("ReaEQ"), "the original track's FX chain is copied")
  T.ok(not tmp[1].fxchain:find("AAAA0001"), "with a fresh FX GUID"); T.ok(tmp[2].fxchain == nil, "a track without FX gets none")
  T.ok(Mock.S.playing, "playing"); T.eq(Mock.S.repeat_on, 1, "looping"); T.ok(approx(Mock.S.loop[1], 20) and approx(Mock.S.loop[2], 22), "over the idea")
  T.eq(#Mock.S.undo, undo_before, "no undo points")
  local c = card(P)
  T.ok(c.auditioning, "view knows it"); T.eq(#c.places, 0, "a solo audition is not a placement row"); T.ok(c.aud ~= nil, "but it has a playhead range")
  Mock.S.play_pos = 21; Mock.S.playing = true
  T.ok(approx(P.app:playhead(c), 1), "playhead in idea time")
  T.eq(Mock.items_on(P.lane)[1].takes[1].name:sub(1, 2), "~ ", "marked in its name")
  T.eq(Mock.all_guids(), 0, "fresh GUIDs")

  -- A/B while playing: the temporary items follow the active variant at once
  local vA = card(P).variants[1].vid
  local vB = P.app:duplicate_variant(P.cid, vA)
  P.app:set_member(P.cid, vB, 1, "vol", 0.5)
  T.ok(approx(at(tmp[1], 20).p.D_VOL, 0.5), "variant B is heard immediately")
  P.app:set_active(P.cid, vA)
  T.ok(approx(at(tmp[1], 20).p.D_VOL, 1), "and A again")
  Mock.S.clock = 100; P.app:tick()
  T.ok(P.app.aud ~= nil, "still playing: nothing is cleaned up")

  -- playback stopped: everything is removed and restored
  Mock.S.playing = false; Mock.S.clock = 101; P.app:tick()
  T.ok(P.app.aud == nil, "cleaned up after stop")
  for _, t in ipairs(Mock.S.tracks) do T.ok(t.ext.IP_lane ~= "audition", "no temporary track is left") end
  T.eq(#Mock.items_on(P.lane), 0, "no placement is left"); T.eq(#Mock.S.tracks, 5, "tracks as before (IDEAS + 4)")
  T.eq(P.keys.solo, 1, "the user's solo is back"); T.eq(Mock.S.repeat_on, 0, "repeat restored"); T.ok(Mock.S.loop[1] == 0 and Mock.S.loop[2] == 0, "loop points restored")
  T.eq(n(P.gtr) + n(P.bass), 0, "nothing was put on the original tracks")
  -- stop button path and starting another one while one plays
  P.app:audition(P.cid); P.app:audition(P.cid)
  local cnt = 0
  for _, t in ipairs(Mock.S.tracks) do if t.ext.IP_lane == "audition" then cnt = cnt + 1 end end
  T.eq(cnt, 2, "a second audition replaces the first")
  P.app:stop_audition(); P.app:sync()
  T.eq(#Mock.S.tracks, 5, "stopped"); T.ok(not Mock.S.playing, "stops the transport")

  -- leftovers (undo, crash): removed by the next sync
  local Q = fresh(); stash(Q, "Riff", "remove"); Mock.S.cursor = 20; Q.app:audition(Q.cid)
  Q.app.aud = nil; Mock.S.playing = false             -- as if the script had died
  Q.app:sync()
  local left = 0
  for _, t in ipairs(Mock.S.tracks) do if t.ext.IP_lane == "audition" then left = left + 1 end end
  T.eq(left, 0, "leftover temporary tracks are removed"); T.eq(#Mock.items_on(Q.lane), 0, "and their placement")
  -- options
  local R = fresh({ audition_fx = false, audition_loop = false }); stash(R, "Riff", "remove")
  R.gtr.fxchain = "<FXCHAIN\n>"; Mock.S.cursor = 20; R.app:audition(R.cid)
  local t1 = Mock.track_named("IdeaPool audition: Guitar")
  T.ok(t1.fxchain == nil, "FX chain copying can be switched off"); T.eq(Mock.S.repeat_on, 0, "so can looping")
  R.app:shutdown()
  T.ok(Mock.track_named("IdeaPool audition: Guitar") == nil, "closing the script cleans up")
  -- deleting the idea while it plays
  local D = fresh(); stash(D, "Riff", "remove"); D.app:audition(D.cid); D.app:delete_card(D.cid)
  T.ok(D.app.aud == nil and #Mock.S.tracks == 5, "deleting an idea stops its audition")
end

------------------------------------------------------------------------------------------------ colours
do
  local P = fresh()
  Mock.set(P.g, "I_CUSTOMCOLOR", 0x1000000 | 0x336699)
  stash(P, "Riff", "remove")
  Mock.S.cursor = 30; P.app:place(P.cid, "cursor")
  local idea = pool(P).cards[P.cid].color
  local grey = reaper.ColorToNative(110, 110, 125) | 0x1000000
  local g = at(P.gtr, 30)
  T.eq(g.p.I_CUSTOMCOLOR, idea | 0x1000000, "placed items get their idea's colour")
  local pid = card(P).places[1].pid
  P.app:freeze(P.cid, pid, true)
  T.eq(g.p.I_CUSTOMCOLOR, grey, "frozen: items are grey"); T.eq(Mock.items_on(P.lane)[1].p.I_CUSTOMCOLOR, grey, "and so is the placement item")
  T.ok(not P.app:sync(), "stable while frozen")
  P.app:freeze(P.cid, pid, false)
  T.eq(g.p.I_CUSTOMCOLOR, idea | 0x1000000, "unfrozen: the idea's colour again")
  T.eq(Mock.items_on(P.lane)[1].p.I_CUSTOMCOLOR, idea | 0x1000000, "placement item too")
  P.app:set("color_items", false); P.app:sync()
  T.eq(g.p.I_CUSTOMCOLOR, 0x1000000 | 0x336699, "option off: back to the colour it had when stashed")
  P.app:freeze(P.cid, pid, true)
  T.eq(g.p.I_CUSTOMCOLOR, grey, "frozen is grey even then")
  P.app:freeze(P.cid, pid, false)
  T.eq(g.p.I_CUSTOMCOLOR, 0x1000000 | 0x336699, "and unfrozen restores the original")
  Mock.set(g, "I_CUSTOMCOLOR", 0x1000000 | 0x00FF00); P.app:sync()
  T.eq(g.p.I_CUSTOMCOLOR, 0x1000000 | 0x00FF00, "with the option off a hand-picked colour is left alone")
end

------------------------------------------------------------------------------------------------ MIDI: no fades, no loudness match
do
  local P = fresh()
  local mi = Mock.item(P.keys, 5, 2, nil, { midi = true, name = "chords", events = { "E 0 90 3c 64", "E 960 80 3c 00" } })
  Mock.select({ P.g, mi }); local cid = P.app:stash("Mix", "remove"); P.cid = cid; P.lane = Mock.track_named("IDEAS")
  Mock.S.cursor = 30; P.app:place(cid, "cursor")
  local m = at(P.keys, 30)
  T.ok(m ~= nil, "MIDI item placed")
  P.app:set_member_fields(cid, card(P).variants[1].vid, 2, { fin = 0.3, fout = 0.3 })
  T.ok(approx(m.p.D_FADEINLEN, 0) and approx(m.p.D_FADEOUTLEN, 0), "fades are not written to MIDI items")
  T.ok(approx(at(P.gtr, 35).p.D_FADEINLEN, 0) , "audio unaffected here (fade was only set on the MIDI member)")
  local vA = card(P).variants[1].vid
  local vB = P.app:duplicate_variant(cid, vA)
  P.app:set_member(cid, vB, 1, "vol", 0.25)
  P.app:set_match(cid, true)
  T.ok(at(P.gtr, 35).p.D_VOL > 0.25, "audio of the quieter variant is matched louder")
  T.ok(approx(m.p.D_VOL, 1), "MIDI item volume is not touched by loudness matching")
  Mock.set(at(P.gtr, 35), "D_VOL", at(P.gtr, 35).p.D_VOL * 0.5); P.app:sync()
  T.ok(approx(m.p.D_VOL, 1), "still not touched")
  T.ok(not P.app:sync(), "stable")
end

------------------------------------------------------------------------------------------------ sub-lanes
do
  local function names() local st = Mock.structure(); return table.concat(st, "|") end
  local P = fresh({ sub_lanes = true }); stash(P, "Riff", "remove")
  Mock.S.cursor = 30; P.app:place(P.cid, "cursor")
  local st, depth = Mock.structure()
  T.eq(st[2], "Guitar", "Guitar"); T.eq(st[3], "  -> Guitar (ideas)", "its sub-lane right below, inside the folder")
  T.eq(st[4], "Bass", "Bass"); T.eq(st[5], "  -> Bass (ideas)", "and Bass's"); T.eq(depth, 0, "folders balanced")
  local gl, bl = Mock.track_named("-> Guitar (ideas)"), Mock.track_named("-> Bass (ideas)")
  T.eq(P.gtr.depth, 1, "the original track became a folder"); T.eq(gl.depth, -1, "the lane closes it")
  T.ok(at(gl, 30) ~= nil and at(bl, 30) ~= nil, "items are on the lanes"); T.ok(at(P.gtr, 30) == nil, "not on the original tracks")
  T.ok(gl.ext.IP_lane == "sub:" .. P.gtr.guid, "lane tagged with its owner")
  T.ok(gl.color ~= 0, "lane is coloured")
  T.eq(at(gl, 30).p.I_CUSTOMCOLOR, pool(P).cards[P.cid].color | 0x1000000, "items coloured like the idea")
  T.ok(not P.app:sync(), "stable")
  Mock.S.cursor = 40; P.app:place(P.cid, "cursor")
  T.eq(#Mock.S.tracks, 7, "the second placement reuses the lanes (IDEAS + 4 + 2 lanes)")
  Mock.set(at(gl, 30), "D_VOL", 0.5); P.app:sync()
  T.ok(approx(at(gl, 40).p.D_VOL, 0.5), "linked as ever")
  -- stash from the lanes: the item belongs to its owner track
  Mock.select({ at(gl, 30) }); local c2 = P.app:stash("Again", "keep")
  T.eq(P.app:card_view(c2).slots[1].name, "Guitar", "an item on a sub-lane stashes as its owner's")
  -- gone with the last placement
  for _, it in ipairs(Mock.items_on(P.lane)) do Mock.delete(it) end
  P.app:sync()
  st, depth = Mock.structure()
  T.eq(table.concat(st, "|"), "IDEAS|Guitar|Bass|Drums|Keys", "lanes removed again: " .. table.concat(st, "|")); T.eq(depth, 0, "balanced")
  T.eq(P.gtr.depth, 0, "Guitar is a plain track again")

  -- the owner is the last child of a folder
  local Q = fresh({ sub_lanes = true }); Q.drums.depth = 1; Q.keys.depth = -1
  local k = Mock.item(Q.keys, 5, 1, "/s/pad.wav"); Mock.select({ k }); local cid = Q.app:stash("Pad", "remove")
  Q.lane = Mock.track_named("IDEAS")
  Mock.S.cursor = 30; Q.app:place(cid, "cursor")
  local _, d2 = Mock.structure()
  T.eq(d2, 0, "balanced"); T.eq(Q.keys.depth, 1, "Keys opens its own folder"); T.eq(Mock.track_named("-> Keys (ideas)").depth, -2, "and the lane closes it and Drums")
  Mock.delete(Mock.items_on(Q.lane)[1]); Q.app:sync()
  T.eq(Q.keys.depth, -1, "Keys closes Drums again"); T.ok(Mock.track_named("-> Keys (ideas)") == nil, "lane gone")
  _, d2 = Mock.structure(); T.eq(d2, 0, "balanced")

  -- the owner is already a folder: the lane becomes its first child
  local F = fresh({ sub_lanes = true }); F.drums.depth = 1; F.keys.depth = -1
  local gi = Mock.item(F.drums, 5, 1, "/s/loop.wav"); Mock.select({ gi }); local cf = F.app:stash("Loop", "remove")
  F.lane = Mock.track_named("IDEAS"); Mock.S.cursor = 30; F.app:place(cf, "cursor")
  local sf = Mock.structure()
  T.eq(sf[5], "  -> Drums (ideas)", "first child of the Drums folder"); T.eq(F.drums.depth, 1, "Drums unchanged")
  T.eq(Mock.track_named("-> Drums (ideas)").depth, 0, "lane depth 0"); T.eq(select(2, Mock.structure()), 0, "balanced")

  -- MIDI items stay on the original track
  local R = fresh({ sub_lanes = true })
  local mi = Mock.item(R.keys, 5, 2, nil, { midi = true, name = "chords", events = { "E 0 90 3c 64", "E 960 80 3c 00" } })
  Mock.select({ R.g, mi }); local cm = R.app:stash("Mix", "remove"); R.lane = Mock.track_named("IDEAS")
  Mock.S.cursor = 30; R.app:place(cm, "cursor")
  T.ok(at(Mock.track_named("-> Guitar (ideas)"), 35) ~= nil, "audio goes to the sub-lane")
  T.ok(at(R.keys, 30) ~= nil and Mock.track_named("-> Keys (ideas)") == nil, "MIDI stays on its track (a child track cannot reach the instrument)")

  -- Place on selected track: lanes are skipped when tracks are counted
  local S2 = fresh({ sub_lanes = true }); stash(S2, "Riff", "remove")
  Mock.S.cursor = 30; S2.app:place(S2.cid, "cursor")                   -- Guitar + Bass now have lanes
  Mock.select_track(S2.drums); Mock.S.cursor = 50; S2.app:place(S2.cid, "selected")
  T.ok(at(Mock.track_named("-> Drums (ideas)"), 50) ~= nil, "first track goes to the selected track's lane")
  T.ok(at(Mock.track_named("-> Keys (ideas)"), 50) ~= nil, "the next track in order (not the lane) gets the second")
  local ok_depth = select(2, Mock.structure()); T.eq(ok_depth, 0, "folders balanced")
  -- Detach all leaves the lanes as ordinary tracks
  S2.app:detach_all()
  T.ok(Mock.track_named("-> Guitar (ideas)").ext.IP_lane == nil, "detach all untags the lanes")
  T.eq(select(2, Mock.structure()), 0, "balanced")
end

------------------------------------------------------------------------------------------------ mixed / delete / misc
do
  local P = fresh(); stash(P, "Riff", "remove")
  Mock.S.cursor = 30; P.app:place(P.cid, "cursor")
  local pid = card(P).places[1].pid
  Mock.delete(at(P.bass, 30)); P.app:sync()
  T.eq(card(P).places[1].reasons[1], "missing", "deleted item = mixed")
  P.app:request(P.cid, pid, "revert")
  T.ok(at(P.bass, 30) ~= nil, "revert brings it back")
  Mock.move_track(at(P.bass, 30), P.keys); P.app:sync()
  T.eq(card(P).places[1].reasons[1], "outside_folder", "moved to another track = mixed")
  P.app:request(P.cid, pid, "apply")
  T.eq(card(P).places[1].mixed, 0, "apply: this placement now uses that track")
  T.ok(at(P.keys, 30) ~= nil, "item stays on Keys")
  T.ok(not P.app:sync(), "stable after remap")
  Mock.S.cursor = 40; P.app:place(P.cid, "cursor")
  T.ok(at(P.bass, 40) ~= nil, "other placements keep the card's tracks")

  -- delete the idea: placements become plain items, auditions disappear
  Mock.marker("Riff", 60); P.app:sync()
  T.ok(at(P.gtr, 60) ~= nil, "audition present")
  P.app:delete_card(P.cid)
  T.eq(#P.app.view.cards, 0, "idea deleted")
  T.ok(at(P.gtr, 30) ~= nil and at(P.gtr, 30).ext.IP_m == nil, "placement items stay, untagged")
  T.ok(at(P.gtr, 60) == nil, "audition items removed")
  T.eq(#Mock.items_on(P.lane), 0, "no placements left")

  -- undo modes
  local U = fresh({ undo_mode = "steps" }); stash(U, "Riff", "remove")
  Mock.S.cursor = 30; U.app:place(U.cid, "cursor")
  local before = #Mock.S.undo
  Mock.nudge(Mock.items_on(U.lane)[1], 1); U.app:sync()
  T.eq(Mock.S.undo[#Mock.S.undo], "IdeaPool: sync", "steps mode labels its syncs"); T.eq(#Mock.S.undo, before + 1, "one step")
  local S2 = fresh(); stash(S2, "Riff", "remove")
  Mock.S.cursor = 30; S2.app:place(S2.cid, "cursor")
  before = #Mock.S.undo
  Mock.nudge(Mock.items_on(S2.lane)[1], 1); S2.app:sync()
  T.eq(#Mock.S.undo, before, "silent mode: no undo step for syncs")

  -- robustness
  local R = fresh(); stash(R, "Riff", "remove")
  local dup = Mock.track("IDEAS copy", 0); dup.ext.IP_lane = "ideas"; dup.ext.IP_pool = R.lane.ext.IP_pool
  R.app:sync()
  T.ok(dup.ext.IP_lane == nil, "a duplicated IDEAS track is released"); T.eq(#R.app.view.cards, 1, "pool intact")
  Mock.item(R.lane, 5, 1, "/s/oops.wav"); R.app:sync()
  T.eq(R.app.view.foreign, 1, "foreign items on the lane are reported")
  T.ok(pool(R).cards[R.cid].variants["1"].members[1].chunk ~= nil, "items are stored with their chunk (take FX, envelopes)")
  R.app:detach_all()
  T.ok(R.lane.ext.IP_lane == nil and #R.app.view.cards == 0, "detach all forgets the pool")
end

------------------------------------------------------------------------------------------------ v0.2: view data
do
  local P = fresh(); Mock.S.tempo = 96
  stash(P, "Riff", "remove")
  Mock.S.cursor = 30; P.app:place(P.cid, "cursor")
  Mock.S.cursor = 40; P.app:place(P.cid, "cursor")
  local c = card(P)
  T.eq(c.bpm, 96, "the tempo where the idea was stashed is kept (for the grid and MIDI)")
  local m = c.variants[1].members[1]
  T.eq(m.file, "/s/riff.wav", "view knows the file"); T.eq(m.soffs, 0, "and the offset"); T.eq(m.rate, 1, "and the rate")
  T.eq(c.places[1].offs, 0, "placements carry their window offset")

  -- a drag = several fields in one undo step, applied to every placement
  local before = #Mock.S.undo
  P.app:set_member_fields(P.cid, c.variants[1].vid, m.mid, { rel = 0.5, len = 1.5, soffs = 0.5 }, "drag in idea view")
  T.eq(#Mock.S.undo, before + 1, "one undo step"); T.eq(Mock.S.undo[#Mock.S.undo], "IdeaPool: drag in idea view", "labelled")
  local g = at(P.gtr, 30.5)
  T.ok(g and approx(g.p.D_LENGTH, 1.5) and approx(g.takes[1].p.D_STARTOFFS, 0.5), "left trim reaches placement 1 (start, length, offset)")
  T.ok(at(P.gtr, 40.5) ~= nil, "and placement 2")
  P.app:set_member_fields(P.cid, c.variants[1].vid, m.mid, { fin = 5 })
  T.ok(approx(at(P.gtr, 30.5).p.D_FADEINLEN, 1.5), "fades are limited to the item length")

  -- peaks: prepared over a few frames, then cached
  Mock.S.peak_steps["/s/riff.wav"] = 2
  T.ok(P.app:peaks("/s/riff.wav") == nil, "peaks not ready at first")
  P.app:work_peaks(1); T.ok(P.app:peaks("/s/riff.wav") == nil, "still building")
  P.app:work_peaks(1)
  local ov = P.app:peaks("/s/riff.wav")
  T.ok(ov and ov.rate == 200 and #ov.mx == 2000, "overview: 10 s at 200 peaks/s")
  T.ok(approx(ov.mx[1], 0.5) and approx(ov.mn[1], -0.5), "peak values")
  T.ok(P.app:peaks("/s/riff.wav") == ov, "cached")
  T.eq(P.app:peaks(""), false, "no file = no peaks")

  -- playhead
  Mock.S.playing, Mock.S.play_pos = true, 41
  T.ok(approx(P.app:playhead(card(P)), 1), "playhead in idea time, from the placement under the play position")
  Mock.S.play_pos = 99; T.ok(P.app:playhead(card(P)) == nil, "no placement there: no playhead")
  Mock.S.playing = false

  -- MIDI ideas bring their notes
  local Q = fresh()
  local mi = Mock.item(Q.keys, 5, 2, nil, { midi = true, name = "chords", events = { "E 0 90 3c 64", "E 960 80 3c 00" } })
  Mock.select({ mi }); local cid = Q.app:stash("Chords")
  local mm = Q.app:card_view(cid).variants[1].members[1]
  T.ok(mm.midi and mm.notes and #mm.notes.notes == 1, "the view has the MIDI notes of the stored item")
  T.eq(mm.notes.notes[1].pitch, 60, "C4")
  Mock.S.cursor = 20; Q.app:place(cid, "cursor")
  local placed = at(Q.keys, 20)
  T.ok(placed and #placed.takes[1].src.events == 2, "placed MIDI carries its notes")
end

T.done("test_sync")
