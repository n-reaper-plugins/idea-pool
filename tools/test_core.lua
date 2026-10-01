package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local C = require("IPCore")

local function m(rel, len, extra)
  local x = { mid = 1, track = "T", rel = rel, len = len, soffs = 0, rate = 1, pitch = 0, tvol = 1, vol = 1, mute = 0, fin = 0.01, fout = 0.02 }
  for k, v in pairs(extra or {}) do x[k] = v end
  return x
end

-------------------------------------------------------------------- visible()
do
  local w = { pos = 10, len = 4, offs = 0 }
  local p = C.visible(m(1, 2), w, 0.005)
  T.eq(p.pos, 11, "unclipped piece position")
  T.eq(p.len, 2, "unclipped piece length")
  T.ok(not p.clipL and not p.clipR, "unclipped flags")
  T.eq(p.fin, 0.01, "own fade-in kept"); T.eq(p.fout, 0.02, "own fade-out kept")

  p = C.visible(m(3, 3), w, 0.005)                       -- 3..6 seen through 0..4
  T.eq(p.len, 1, "right-clipped length"); T.ok(p.clipR and not p.clipL, "right clip flag"); T.eq(p.fout, 0.005, "clip fade right")

  local w2 = { pos = 20, len = 2, offs = 2 }             -- window 2..4 at 20
  p = C.visible(m(1, 2, { soffs = 5, rate = 2 }), w2, 0)  -- member 1..3, visible 2..3
  T.eq(p.pos, 20, "left-clipped position"); T.eq(p.len, 1, "left-clipped length")
  T.eq(p.soffs, 7, "left-clipped source offset follows rate (5 + 1*2)")
  T.ok(p.clipL, "left clip flag")
  T.ok(C.visible(m(5, 1), w, 0) == nil, "outside window = nil")
  T.ok(C.visible(m(4, 1), w, 0) == nil, "touching edge = nil")
  local tiny = C.visible(m(0, 4), { pos = 0, len = 0.004, offs = 0 }, 1)
  T.ok(tiny.fout <= 0.002 + 1e-12, "clip fade limited to half the piece")
end

-------------------------------------------------------------------- snapshots
do
  local s = { pos = 1.5, len = 2, soffs = 0.25, vol = 0.5, mute = 1, rate = 1, pitch = -2, tvol = 1, fin = 0, fout = 0.1, track = "{G}", clipR = true }
  local d = C.snap_decode(C.snap_encode(s))
  T.eq(d.pos, 1.5, "snap pos"); T.eq(d.track, "{G}", "snap track"); T.eq(d.pitch, -2, "snap pitch")
  T.ok(d.clipR and not d.clipL, "snap clip flags survive")
  T.ok(C.snap_decode("") == nil, "empty snapshot = nil")
  local a = C.copy(s); a.fout = 0.3
  T.ok(C.snap_eq(a, s), "fade on a clipped edge is ignored")
  a.fin = 0.3
  T.ok(not C.snap_eq(a, s), "fade on an unclipped edge matters")
end

-------------------------------------------------------------------- classify()
do
  local w = { pos = 10, len = 4, offs = 0 }
  local dm = m(1, 2)
  local S = C.visible(dm, w, 0)
  local info = { in_folder = function(g) return g ~= "OUT" end, window = w, def_member = dm }
  local A = C.copy(S)
  T.eq(C.classify(A, S, S, info).kind, "ok", "unchanged = ok")

  local w2 = { pos = 12, len = 4, offs = 0 }                  -- alias moved by +2
  local N2 = C.visible(dm, w2, 0)
  T.eq(C.classify(A, S, N2, info).kind, "write", "alias moved, member not = write")
  local A2 = C.copy(A); A2.pos = A2.pos + 2
  T.eq(C.classify(A2, S, N2, info).kind, "ok", "both moved (ripple) = ok")

  local A3 = C.copy(A); A3.pos = 11.5
  local r = C.classify(A3, S, S, info)
  T.eq(r.kind, "edit", "member moved inside = edit"); T.eq(r.edit.geom.rel, 1.5, "edit gives new def-local position")

  local A4 = C.copy(A); A4.vol = 0.5
  r = C.classify(A4, S, S, info)
  T.eq(r.kind, "edit", "volume = edit"); T.eq(r.edit.props.vol, 0.5, "edit carries volume"); T.ok(r.edit.geom == nil, "no geometry edit")

  local A5 = C.copy(A); A5.pos = 13.5
  T.eq(C.classify(A5, S, S, info).reason, "outside_window", "moved beyond the alias = mixed")
  local A6 = C.copy(A); A6.track = "OUT"
  T.eq(C.classify(A6, S, S, info).reason, "outside_folder", "moved out of folder = mixed")
  local A7 = C.copy(A); A7.track = "T2"
  r = C.classify(A7, S, S, info)
  T.eq(r.kind, "edit", "moved to another track in folder = edit"); T.eq(r.edit.track, "T2", "edit carries track")

  -- clipped member: geometry edit is ambiguous
  local dm2 = m(3, 3)
  local S2 = C.visible(dm2, w, 0)
  local A8 = C.copy(S2); A8.pos = A8.pos - 0.5
  T.eq(C.classify(A8, S2, S2, { in_folder = info.in_folder, window = w, def_member = dm2 }).reason, "clipped_edit", "clipped geometry edit = mixed")

  -- the left piece of a user split: shorter, its fade-out reset; the (already split) window explains it
  local wsplit = { pos = 10, len = 1.5, offs = 0 }
  local Nsplit = C.visible(dm, wsplit, 0.005)
  local A9 = C.copy(S); A9.len = 0.5; A9.fout = 0
  T.eq(C.classify(A9, S, Nsplit, info).kind, "ok", "split left piece matches the split window")
end

-------------------------------------------------------------------- find_cuts()
do
  local S = { pos = 10, len = 4, soffs = 1, rate = 1, track = "T" }
  local A = { pos = 10, len = 1.5, soffs = 1 }
  local cuts, matched = C.find_cuts(S, A, { { pos = 11.5, len = 2.5, soffs = 2.5, rate = 1 } })
  T.eq(#cuts, 1, "one split = one cut"); T.eq(cuts[1], 11.5, "cut time"); T.eq(#matched, 1, "piece matched")
  cuts = C.find_cuts(S, A, { { pos = 12, len = 2, soffs = 3, rate = 1 } })     -- razor: middle 11.5..12 deleted
  T.eq(#cuts, 2, "razor gap = two cuts"); T.eq(cuts[2], 12, "second cut")
  cuts = C.find_cuts(S, A, {})
  T.eq(#cuts, 0, "shortened without pieces = trim, not cut")
  cuts = C.find_cuts(S, A, { { pos = 12, len = 2, soffs = 9, rate = 1 } })
  T.eq(#cuts, 0, "piece with another anchor is not ours")
  cuts = C.find_cuts(S, A, { { pos = 11.5, len = 1, soffs = 2.5 }, { pos = 12.5, len = 1.5, soffs = 3.5 } })
  T.eq(#cuts, 2, "two splits = two cuts")
end

-------------------------------------------------------------------- split_children()
do
  local W0 = { pos = 10, len = 4, offs = 0 }
  local now = { pos = 10, len = 1, offs = 0 }
  local kids = C.split_children(W0, now, { { pos = 11, len = 3, offs = 1 }, { pos = 20, len = 4, offs = 0 }, { pos = 12, len = 1, offs = 0 } })
  T.eq(#kids, 1, "only the same-anchor piece inside the old extent is a split child")
  T.eq(#C.split_children(W0, { pos = 12, len = 4, offs = 0 }, { { pos = 11, len = 3, offs = 1 } }), 0, "a moved alias has no split children")
  T.eq(#C.split_children(nil, now, { { pos = 11, len = 3, offs = 1 } }), 0, "no last window = nothing")
end

-------------------------------------------------------------------- def_cut()
do
  local def = { members = { m(0, 10, { mid = 1, soffs = 2 }) }, next_mid = 2 }
  local out = C.def_cut(def, 1, 3, 5)
  T.eq(#out, 2, "cut in the middle = two parts"); T.eq(#def.members, 2, "def has two members")
  T.eq(def.members[1].len, 3, "left part length"); T.eq(def.members[2].rel, 5, "right part start")
  T.eq(def.members[2].soffs, 7, "right part source offset"); T.eq(def.members[2].mid, 2, "right part new mid")
  C.def_cut(def, 2, 4, 20)
  T.eq(#def.members, 1, "cutting everything of a member removes it")
  C.def_cut(def, 1, -1, 1)
  T.eq(def.members[1].rel, 1, "cutting the head moves the start"); T.eq(def.members[1].soffs, 3, "head cut offset")
  T.eq(C.def_extent(def), 3, "extent")
end

-------------------------------------------------------------------- folders
do
  -- 1 Drums(+1)  2 Kick  3 Snare(-1)  4 Bass  5 FX(+1) 6 Sub(+1) 7 Verb(-2)
  local p = C.parents({ 1, 0, -1, 0, 1, 1, -2 })
  T.eq(p[2], 1, "kick in drums"); T.eq(p[4], 0, "bass top level"); T.eq(p[7], 6, "verb in sub")
  T.eq(C.common_folder(p, { 2, 3 }), 1, "common folder of kick+snare")
  T.eq(C.common_folder(p, { 6, 7 }), 5, "sub + verb -> FX")
  T.eq(C.common_folder(p, { 2, 4 }), 0, "kick + bass: none")
  T.eq(C.common_folder(p, { 1 }), 0, "folder track itself is not inside itself")
  T.ok(C.is_desc(p, 7, 5), "verb inside FX (nested)")
end

-------------------------------------------------------------------- chunks
do
  local n = 0
  local gen = function() n = n + 1; return "{NEW-" .. n .. "}" end
  local chunk = "<ITEM\nIGUID {AAAA-1}\n  GUID {BBBB-2}\nPOOLEDEVTS {CCCC-3}\n  FXID {DDDD-4}\nNAME \"x\"\n>"
  local out = C.refresh_guids(chunk, gen, true)
  T.ok(not out:find("AAAA") and not out:find("BBBB") and not out:find("DDDD"), "item, take and FX GUIDs replaced")
  T.ok(out:find("CCCC"), "MIDI pool kept for linked copies")
  T.ok(out:find("\n  GUID {NEW"), "indentation kept")
  out = C.refresh_guids(chunk, gen, false)
  T.ok(not out:find("CCCC"), "MIDI pool replaced for unique copies")
end

-------------------------------------------------------------------- names, lists, json, overlaps
do
  T.eq(C.take_name("Drums", "1", "1"), "Drums", "linked alias name")
  T.eq(C.take_name("Drums", "3", "1"), "Drums #3", "unique alias name")
  T.eq(C.take_code("Drums #3"), "3", "code from name"); T.ok(C.take_code("Drums") == nil, "no code")
  local l = C.list_decode("3,1,2"); T.ok(l[1] and l[2] and l[3], "list decode")
  T.eq(C.list_encode({ [10] = true, [2] = true }), "2,10", "list encode sorted numerically")
  local data = { name = "Dr\"um\ns", defs = { ["1"] = { members = { { mid = 1, chunk = "<ITEM\n>" } } }, ["2"] = { members = {} } }, n = 1.25 }
  local back = C.json_decode(C.json_encode(data))
  T.eq(back.name, data.name, "json string escapes"); T.eq(back.defs["1"].members[1].chunk, "<ITEM\n>", "json nested")
  T.eq(back.n, 1.25, "json number")
  T.eq(#back.defs["2"].members, 0, "json empty list")
  T.ok(C.json_decode("{bad") == nil, "bad json = nil")
  local ov = C.overlaps({ { iid = "1", pos = 0, len = 4 }, { iid = "2", pos = 3, len = 2 }, { iid = "3", pos = 10, len = 1 } })
  T.eq(#ov, 1, "one overlap"); T.eq(ov[1][2], "2", "overlap pair")
end


-------------------------------------------------------------------- IdeaPool: names, markers
do
  T.eq(C.card_take_name("Riff", "B", 3, ""), "Riff · B [3]", "placement name")
  T.eq(C.card_take_name("Riff", "A", 3, "frozen"), "* Riff · A [3]", "frozen placement name")
  T.eq(C.card_code("> Riff · A [12]"), "12", "card id from any placement name")
  T.ok(C.card_code("Riff") == nil, "no id")
  T.eq(C.variant_letter(2), "B", "variant letters"); T.eq(C.variant_letter(26), "Z", "Z"); T.eq(C.variant_letter(28), "AB", "AB")
  local by = { riff = "1", ["big drop"] = "2" }
  T.eq(C.marker_card("Riff", "", by), "1", "marker = card name")
  T.eq(C.marker_card("  big DROP ", "", by), "2", "case and spaces ignored (as PrototypeSequence)")
  T.ok(C.marker_card("Verse", "", by) == nil, "other markers ignored")
  T.eq(C.marker_card("idea: Riff", "idea:", by), "1", "with prefix")
  T.ok(C.marker_card("Riff", "idea:", by) == nil, "prefix required when set")
end

-------------------------------------------------------------------- IdeaPool: level
do
  local mt = C.new_meter(1000, 1)
  local t = {}
  for i = 1, 1000 do t[i] = 0.5 end
  C.meter_block(mt, t, 1000)
  local fr = C.meter_finish(mt)
  T.eq(#fr, 20, "1 s = 20 frames of 50 ms")
  T.ok(math.abs(fr[1] - (-6.0)) < 0.05, "0.5 amplitude = -6 dB power")

  local function member(rel, len, db, extra)
    local m = { mid = 1, slot = 1, rel = rel, len = len, soffs = 0, rate = 1, vol = 1, tvol = 1, mute = 0,
                stats = { s0 = 0, rate = 1, fr = {} } }
    for i = 1, math.ceil(len / 0.05) do m.stats.fr[i] = db end
    for k, v in pairs(extra or {}) do m[k] = v end
    return m
  end
  local lvl, cov = C.variant_level({ members = { member(0, 1, -12) } })
  T.ok(math.abs(lvl + 12) < 0.01, "one member: its level"); T.eq(cov, 1, "fully measured")
  lvl = C.variant_level({ members = { member(0, 1, -12, { vol = 0.5 }) } })
  T.ok(math.abs(lvl + 18.02) < 0.05, "item volume counts")
  lvl = C.variant_level({ members = { member(0, 1, -12), member(0, 1, -12) } })
  T.ok(math.abs(lvl + 8.99) < 0.05, "two equal members add +3 dB")
  lvl = C.variant_level({ members = { member(0, 1, -12), member(1, 3, -80) } })
  T.ok(math.abs(lvl + 12) < 0.05, "silence below the gate does not lower the level")
  local m = member(0, 1, -12); m.soffs = 0.5                                  -- trimmed: half the frames are unknown
  lvl, cov = C.variant_level({ members = { m } })
  T.ok(math.abs(cov - 0.5) < 0.06, "trim past the measured audio lowers coverage")
  T.ok(C.variant_level({ members = { { mid = 1, rel = 0, len = 1, soffs = 0, rate = 1 } } }) == nil, "nothing measured = nil")
  T.eq(C.match_gain(-12, -18), 6, "match gain"); T.eq(C.match_gain(-12, -60, 24), 24, "limited")
  T.eq(C.match_gain(nil, -3), 0, "no reference = 0")
end

-------------------------------------------------------------------- IdeaPool: slots
do
  local out = C.map_slots({ 3, 5 }, 10, 20)
  T.eq(out[1], 10, "slot 1 to the target"); T.eq(out[2], 12, "slot 2 keeps its distance")
  out = C.map_slots({ 3, 5 }, 19, 20)
  T.eq(out[2], 20, "clamped to the last track")
  out = C.map_slots({ nil, 4 }, 2, 9, 2)
  T.eq(out[2], 2, "the first slot whose track exists is the anchor"); T.eq(out[1], 2, "a slot whose track is gone lands on the target")
end

-------------------------------------------------------------------- v0.2: view geometry
do
  local v = { x0 = 100, w = 400, t0 = 0, t1 = 4 }
  T.eq(C.t2x(v, 2), 300, "time to x"); T.eq(C.x2t(v, 200), 1, "x to time")
  local a, b = C.view_range(4, 1, 0)
  T.eq(a, 0, "fit starts at 0"); T.ok(math.abs(b - 4.2) < 1e-9, "fit shows the idea plus 5%")
  a, b = C.view_range(4, 2, 1)
  T.ok(math.abs(b - 4.2) < 1e-9 and math.abs(b - a - 2.1) < 1e-9, "zoom 2, scrolled to the end")
  T.eq(C.nice_step(100), 1, "100 px/s -> 1 s grid"); T.eq(C.nice_step(1000), 0.1, "1000 px/s -> 0.1 s grid")
  T.eq(C.snap(1.12, 0.125), 1.125, "snap"); T.eq(C.snap(1.12, nil), 1.12, "snap off")

  local box = { x0 = 100, x1 = 300, y0 = 10, y1 = 60, fin_px = 20, fout_px = 0 }
  T.eq(C.hit_zone(box, 110, 12), "fin", "top-left = fade in")
  T.eq(C.hit_zone(box, 295, 12), "fout", "top-right = fade out")
  T.eq(C.hit_zone(box, 200, 12), "gain", "top middle = gain")
  T.eq(C.hit_zone(box, 102, 40), "left", "left edge")
  T.eq(C.hit_zone(box, 298, 40), "right", "right edge")
  T.eq(C.hit_zone(box, 200, 40), "move", "body")
  T.ok(C.hit_zone(box, 400, 40) == nil, "outside")
end

-------------------------------------------------------------------- v0.2: drags
do
  local m = { rel = 1, len = 2, soffs = 0.5, rate = 2, fin = 0.1, fout = 0.2, vol = 1 }
  local f = C.drag(m, "move", 0.5)
  T.eq(f.rel, 1.5, "move"); T.ok(f.len == nil, "move keeps length")
  T.eq(C.drag(m, "move", -5).rel, 0, "not before the idea's start")
  f = C.drag(m, "left", 0.5)
  T.eq(f.rel, 1.5, "left trim start"); T.eq(f.len, 1.5, "left trim length"); T.eq(f.soffs, 1.5, "offset moves with rate 2")
  f = C.drag(m, "left", -1)
  T.eq(f.rel, 0.75, "left trim stops at the file start (offset 0.5 / rate 2)"); T.eq(f.soffs, 0, "offset 0")
  f = C.drag(m, "left", 5)
  T.ok(math.abs(f.len - C.MIN_LEN) < 1e-9, "left trim keeps a minimum length")
  f = C.drag(m, "right", 1)
  T.eq(f.len, 3, "right trim"); f = C.drag(m, "right", 10, 0, 4)
  T.eq(f.len, 1.75, "right trim stops at the file end ((4 - 0.5) / 2)")
  T.eq(C.drag({ rel = 1, len = 2, soffs = 0, midi = true }, "right", 10, 0, 4).len, 12, "MIDI: no file end")
  T.ok(math.abs(C.drag(m, "fin", 0.3).fin - 0.4) < 1e-9, "fade in"); T.eq(C.drag(m, "fin", 5).fin, 1.8, "fade in stops at the fade out")
  T.ok(math.abs(C.drag(m, "fout", -0.3).fout - 0.5) < 1e-9, "fade out (drag left = longer)")
  T.ok(math.abs(C.lin_to_db(C.drag(m, "gain", 0, -24).vol) - 6) < 1e-9, "gain: 24 px up = +6 dB")
  T.ok(math.abs(C.drag(m, "move", 0.49, 0, nil, 0.25).rel - 1.5) < 1e-9, "snap applies to moves")
end

-------------------------------------------------------------------- v0.2: peaks
do
  local ov = { rate = 10, mx = {}, mn = {} }
  for i = 1, 100 do ov.mx[i] = i / 100; ov.mn[i] = -i / 100 end            -- 10 s ramp
  local cols = C.peak_columns(ov, 2, 1, 1, 2)                              -- source 2..3 s in two columns
  T.eq(#cols, 2, "two columns"); T.eq(cols[1][1], 0.25, "column max over its range"); T.eq(cols[2][2], -0.3, "column min")
  cols = C.peak_columns(ov, 0, 1, 2, 1)                                     -- rate 2: 1 s of item = 2 s of source
  T.eq(cols[1][1], 0.2, "playrate widens the source range")
  cols = C.peak_columns(ov, 9.5, 2, 1, 2)
  T.ok(cols[2] == false, "past the end of the file: no data")
end

-------------------------------------------------------------------- v0.2: MIDI
do
  local chunk = table.concat({
    "<ITEM", "<SOURCE MIDI", "HASDATA 1 960 QN",
    "E 0 90 3c 64", "E 480 80 3c 00",         -- C4 0..0.5 QN
    "E 0 90 40 50", "X 240 ff 01 00",         -- E4 starts at 0.5, a meta event in between counts its delta
    "E 240 90 40 00",                           -- E4 note-off as velocity 0 at 1.0
    "e 960 91 43 7f", "E 960 81 43 00",        -- G4 channel 2, 2.0..3.0
    "E 0 90 48 64",                             -- C5 never ends -> closed at the end (3.0)
    ">", ">" }, "\n")
  local p = C.midi_notes(chunk)
  T.eq(#p.notes, 4, "four notes"); T.eq(p.tpq, 960, "ticks per QN")
  T.eq(p.notes[1].pitch, 60, "C4"); T.eq(p.notes[1].e, 0.5, "C4 ends at 0.5 QN")
  T.eq(p.notes[2].pitch, 64, "E4"); T.eq(p.notes[2].s, 0.5, "E4 start"); T.eq(p.notes[2].e, 1.0, "E4 ends (velocity 0 = off, X delta counted)")
  T.eq(p.notes[3].s, 2, "G4 start"); T.eq(p.notes[3].vel, 127, "velocity")
  T.eq(p.notes[4].e, 3, "hanging note closed at the end")
  local notes, lo, hi = C.member_notes(p, { rel = 0, len = 1.2, soffs = 0.25 }, 120)   -- 0.5 s per QN
  T.eq(#notes, 2, "only E4 and G4 are inside the member window (C4 lies before the 0.25 s offset)")
  T.eq(notes[1].pitch, 64, "E4 first"); T.eq(notes[1].a, 0, "E4 at the member start"); T.eq(notes[1].b, 0.25, "E4 length 0.25 s")
  T.ok(math.abs(notes[2].b - 1.2) < 1e-9, "G4 clipped at the member end"); T.ok(hi - lo >= 12, "pitch range at least an octave")
  T.eq(#C.midi_notes("").notes, 0, "empty chunk")
end

-------------------------------------------------------------------- v0.2.1
do
  local w = { pos = 10, len = 4, offs = 0 }
  local mid = C.visible({ mid = 1, track = "T", rel = 1, len = 5, soffs = 0, rate = 1, vol = 1, fin = 0.3, fout = 0.4, midi = true }, w, 0.005)
  T.eq(mid.fin, 0, "MIDI: no fade in even on a clipped edge"); T.eq(mid.fout, 0, "MIDI: no fade out")
  local au = C.visible({ mid = 1, track = "T", rel = 1, len = 5, soffs = 0, rate = 1, vol = 1, fin = 0.3, fout = 0.4 }, w, 0.005)
  T.eq(au.fin, 0.3, "audio keeps its fade in"); T.eq(au.fout, 0.005, "and the clip fade on a cut edge")
  local box = { x0 = 100, x1 = 300, y0 = 10, y1 = 60, fin_px = 20, fout_px = 0, midi = true }
  T.eq(C.hit_zone(box, 110, 12), "move", "MIDI top-left corner is not a fade handle")
  T.eq(C.hit_zone(box, 200, 12), "move", "MIDI top edge is not a gain handle")
  T.eq(C.hit_zone(box, 102, 40), "left", "MIDI still trims")
  T.eq(C.card_take_name("R", "A", 1, "marker"), "> R · A [1]", "marker placement name")
  T.eq(C.card_take_name("R", "A", 1, "audition"), "~ R · A [1]", "solo audition name")

  local o, c = C.sublane_insert(0);  T.eq(o, 1, "plain track opens a folder"); T.eq(c, -1, "child closes it")
  o, c = C.sublane_insert(-1);       T.eq(o, 1, "last child of a folder: opens its own"); T.eq(c, -2, "child closes both")
  o, c = C.sublane_insert(-3);       T.eq(c, -4, "deep close is kept")
  o, c = C.sublane_insert(1);        T.eq(o, 1, "folder track stays"); T.eq(c, 0, "lane = first child")
  T.eq(C.depth_after_removal(1, -1), 0, "owner back to a plain track")
  T.eq(C.depth_after_removal(1, -2), -1, "owner closes the outer folder again")
  T.eq(C.depth_after_removal(1, 0), 1, "a lane in the middle changes nothing")
end

T.done("test_core")
