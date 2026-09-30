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

------------------------------------------------------------------------------------------------ auditions
do
  local P = fresh(); stash(P, "Riff", "remove")
  Mock.marker("riff", 50)
  P.app:sync()
  T.ok(at(P.gtr, 50) ~= nil and at(P.bass, 50) ~= nil, "a marker named like the idea auditions it there")
  local c = card(P)
  T.eq(c.auditions, 1, "counted as audition"); T.eq(c.places[1].kind, "audition", "kind audition")
  T.eq(Mock.items_on(P.lane)[1].takes[1].name:sub(1, 2), "> ", "audition marked in its name")
  local idx = Mock.S.markers[1].idx
  Mock.move_marker(idx, 55); P.app:sync()
  T.ok(at(P.gtr, 55) ~= nil and at(P.gtr, 50) == nil, "the audition follows its marker")
  -- the marker wins over a hand move
  Mock.nudge(Mock.items_on(P.lane)[1], 3); P.app:sync()
  T.ok(at(P.gtr, 55) ~= nil, "moving the audition by hand snaps back to the marker")
  Mock.marker("Riff", 70, 70.5); P.app:sync()
  T.ok(at(P.gtr, 70) ~= nil and approx(at(P.gtr, 70).p.D_LENGTH, 0.5), "a region trims the audition")
  T.eq(card(P).auditions, 2, "two auditions")
  Mock.S.markers[1].name = "Verse"; P.app:sync()
  T.ok(at(P.gtr, 55) == nil, "renaming the marker removes the audition and its items")
  -- commit
  local pid = card(P).places[1].pid
  P.app:commit(P.cid, pid)
  T.eq(card(P).places[1].kind, "linked", "commit: ordinary placement")
  T.ok(Mock.S.markers[2].name == "(placed) Riff", "its marker is renamed: " .. Mock.S.markers[2].name)
  T.ok(at(P.gtr, 70) ~= nil, "items stay")
  -- audition button: marker at the cursor, playback starts
  Mock.S.cursor = 90; P.app:audition(P.cid, true)
  T.ok(at(P.gtr, 90) ~= nil, "Audition at cursor places it"); T.ok(Mock.S.playing, "and plays")
  -- prefix
  local Q = fresh({ marker_prefix = "idea:" }); stash(Q, "Riff", "remove")
  Mock.marker("Riff", 20); Q.app:sync()
  T.ok(at(Q.gtr, 20) == nil, "with a prefix, a plain name does not audition")
  Mock.marker("idea: Riff", 25); Q.app:sync()
  T.ok(at(Q.gtr, 25) ~= nil, "'idea: Riff' does")
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

T.done("test_sync")
