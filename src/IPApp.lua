-- IPApp.lua
-- State, settings, the debounced tick, the sync engine and the commands of IdeaPool.
-- The sync engine is AliasTrack's (v0.1.0), with: card = group, variant = def, placement = alias instance,
-- all placements on ONE lane (the IDEAS track, card found by the "[id]" in the take name), tracks mapped per placement,
-- auditions driven by markers, frozen placements, and loudness matching between variants.
--
-- One sync = up to 4 passes of:  scan -> build model -> (cuts? split placements, rescan) -> reconcile

local r = reaper
local C = require("IPCore")
local RA = require("IPReaper")

local App = {}
App.__index = App

local EXT = "IdeaPool"
local DEBOUNCE = 0.3

App.DEFAULTS = {
  live = true,
  undo_mode = "silent",      -- "silent" | "steps"
  propagate = true,          -- edits of placed items go into the card's active variant
  delete_with_alias = true,  -- deleting a placement deletes its items (off: they are released)
  clipfade_ms = 5,
  keep_pool = true,          -- MIDI stays pooled between linked placements
  stash_mode = "keep",       -- after Stash, the selected items: "keep" (copy) | "link" (become a placement) | "remove"
  color_items = true,        -- items of placements get their idea's colour (frozen ones are always grey)
  sub_lanes = false,         -- place the items on a sub-lane under each original track (inside its FX chain)
  audition_fx = true,        -- a solo audition copies the original tracks' FX chains (instruments!)
  audition_loop = true,      -- a solo audition loops over the idea
  match_max_db = 24,
}

local PALETTE = { { 0x85, 0x42, 0xFA }, { 0x3F, 0xA7, 0xD6 }, { 0x59, 0xCD, 0x90 }, { 0xFA, 0xC0, 0x5E },
                  { 0xF7, 0x9D, 0x84 }, { 0xEE, 0x63, 0x52 }, { 0xB3, 0x8C, 0xF8 }, { 0x5E, 0xD1, 0xC4 } }

---------------------------------------------------------------------------------------------------------- settings
function App.new()
  local self = setmetatable({}, App)
  self.cfg = {}
  for k, v in pairs(App.DEFAULTS) do self.cfg[k] = v end
  local raw = r.GetExtState(EXT, "cfg")
  for k, v in raw:gmatch("([%w_]+)=([^;]*)") do
    local d = App.DEFAULTS[k]
    if type(d) == "boolean" then self.cfg[k] = (v == "1")
    elseif type(d) == "number" then self.cfg[k] = tonumber(v) or d
    elseif d ~= nil then self.cfg[k] = v end
  end
  self.view = { cards = {} }
  self.requests = {}         -- ["cid|pid"] = "apply" | "revert"
  self.push = {}
  self.pending = true
  self.changed_at = -1e9
  self.seen = -1
  self.stats = {}
  self.peak_cache, self.peak_jobs, self.note_cache = {}, {}, {}
  return self
end

function App:save()
  local out = {}
  for k in pairs(App.DEFAULTS) do
    local v = self.cfg[k]
    if type(v) == "boolean" then v = v and "1" or "0" end
    out[#out + 1] = k .. "=" .. tostring(v):gsub("[;=]", "")
  end
  table.sort(out)
  r.SetExtState(EXT, "cfg", table.concat(out, ";"), true)
end

function App:set(k, v) self.cfg[k] = v; self:save(); self:refresh() end
function App:refresh() self.pending = true; self.changed_at = -1e9 end

---------------------------------------------------------------------------------------------------------- v0.2 view data
-- waveform overview of a file: the table, false (not available), or nil (being prepared - ask again next frame)
function App:peaks(file)
  if not file or file == "" then return false end
  local c = self.peak_cache[file]
  if c ~= nil then return c end
  if not self.peak_jobs[file] then
    local h = RA.peaks_begin(file)
    if not h then self.peak_cache[file] = false; return false end
    self.peak_jobs[file] = h
  end
  return nil
end

-- let REAPER build peaks for a little while (called every frame from tick)
function App:work_peaks(budget)
  local t0 = r.time_precise()
  for file, h in pairs(self.peak_jobs) do
    local ok, ready = pcall(RA.peaks_step, h)
    if not ok then self.peak_cache[file] = false; self.peak_jobs[file] = nil
    elseif ready then
      local ok2, ov = pcall(RA.peaks_read, h)
      self.peak_cache[file] = ok2 and ov or false
      self.peak_jobs[file] = nil
    end
    if r.time_precise() - t0 > (budget or 0.01) then break end
  end
end

function App:notes(chunk)
  if not chunk then return nil end
  local c = self.note_cache[chunk]
  if not c then c = C.midi_notes(chunk); self.note_cache[chunk] = c end
  return c
end

-- idea-local playhead of card view c: the solo audition, else the first (non-frozen) placement under the play position
function App:playhead(c)
  local p = RA.play_pos()
  if not p or not c then return nil end
  local a = c.aud
  if a and p >= a.pos and p < a.pos + a.len + 1e-6 then return p - a.pos + a.offs end
  for _, pl in ipairs(c.places) do
    if pl.kind ~= "frozen" and p >= pl.pos and p < pl.pos + pl.len then return p - pl.pos + (pl.offs or 0) end
  end
  return nil
end

---------------------------------------------------------------------------------------------------------- tick
function App:tick()
  self:work_peaks(0.01)
  if self.aud and r.time_precise() - self.aud.t0 > 0.5 and not RA.is_playing() then self:stop_audition() end
  local cc = RA.change_count()
  local now = r.time_precise()
  if cc ~= self.seen then self.seen = cc; self.changed_at = now; self.pending = true end
  if not self.pending or now - self.changed_at < DEBOUNCE then return end
  if not self.cfg.live then self.pending = false; self:sync(true); return end
  if RA.mouse_down() then return end
  if self.cfg.undo_mode == "steps" and RA.redo_label() == RA.SYNC_LABEL then
    self.paused = true; self.pending = false
    return
  end
  self.paused = false
  self.pending = false
  self:sync()
  self.seen = RA.change_count()
end

---------------------------------------------------------------------------------------------------------- model
local function parse_bar(s)
  local p = C.split_bar(s)
  local pid = p[2] and p[2]:match("^%d+$") and p[2] or nil
  return p[1], pid, p[3]
end

local function track_of(W, guid) return guid and W.by_guid[guid] end

local function split_list(s)
  local out = {}
  for v in (s or ""):gmatch("[^,]+") do out[#out + 1] = v end
  return out
end

-- the lane, the pool and every card's placements and members, from one scan. No writes.
function App:build(W)
  local M = { W = W, cards = {}, order = {}, stray = {}, release_lanes = {}, free = {}, foreign = {}, sub = {}, aud_tracks = {} }
  for _, T in ipairs(W.tracks) do
    if T.lane == "ideas" then
      if M.lane then M.release_lanes[#M.release_lanes + 1] = T else M.lane = T end
    elseif T.lane == "audition" then M.aud_tracks[#M.aud_tracks + 1] = T
    elseif T.lane:sub(1, 4) == "sub:" then
      local owner = T.lane:sub(5)
      if M.sub[owner] then M.release_lanes[#M.release_lanes + 1] = T else M.sub[owner] = T end
    elseif T.lane ~= "" then M.release_lanes[#M.release_lanes + 1] = T end
  end
  local pool = M.lane and C.json_decode(M.lane.pool or "")
  if type(pool) ~= "table" or type(pool.cards) ~= "table" then pool = { v = 1, next_card = 1, cards = {}, order = {} } end
  pool.order = pool.order or {}
  M.pool, M.raw = pool, M.lane and M.lane.pool or ""
  M.by_name = {}
  for _, cid in ipairs(pool.order) do
    local card = pool.cards[cid]
    if card then
      M.cards[cid] = { cid = cid, card = card, inst = {}, order = {}, untagged = {}, orphans = {}, dups = {} }
      M.order[#M.order + 1] = cid
      M.by_name[C.norm_name(card.name)] = M.by_name[C.norm_name(card.name)] or cid
    end
  end

  if M.lane then
    for _, I in ipairs(M.lane.items) do
      local G
      if I.take and I.midi then
        local cid, pid = parse_bar(I.tag_i)
        G = M.cards[cid or ""]
        if G and pid and not G.inst[pid] then
          local w0 = C.split_bar(I.tag_w)
          G.inst[pid] = {
            pid = pid, item = I, members = {}, mixed = {}, known = true,
            W = { pos = I.pos, len = I.len, offs = I.soffs },
            W0 = (#w0 >= 3) and { pos = tonumber(w0[1]), len = tonumber(w0[2]), offs = tonumber(w0[3]) } or nil,
            has = C.list_decode(I.tag_h), map = split_list(I.tag_map), mode = I.tag_mode or "", var_last = I.tag_v,
            col = I.tag_col or "",
          }
          if G.inst[pid].mode:sub(1, 2) == "a:" then G.inst[pid].mode = "m:" .. G.inst[pid].mode:sub(3) end   -- v0.2.0 tag
          G.order[#G.order + 1] = pid
        else
          G = M.cards[C.card_code(I.tname) or ""]
          if G then G.untagged[#G.untagged + 1] = I else M.foreign[#M.foreign + 1] = I end
        end
      else
        M.foreign[#M.foreign + 1] = I
      end
    end
  end

  for _, I in ipairs(W.items) do
    if I.T.lane == "" or I.T.lane == "audition" or I.T.lane:sub(1, 4) == "sub:" then
      if I.tag_m ~= "" then
        local cid, pid, mid = parse_bar(I.tag_m)
        mid = tonumber(mid)
        local G = M.cards[cid or ""]
        if not G or not pid or not mid then M.stray[#M.stray + 1] = I
        else
          local P = G.inst[pid]
          if not P then G.orphans[#G.orphans + 1] = I
          elseif P.members[mid] then G.dups[#G.dups + 1] = I
          else P.members[mid] = { I = I, S = C.snap_decode(I.tag_a) } end
        end
      else
        local L = M.free[I.T.guid] or {}
        L[#L + 1] = I
        M.free[I.T.guid] = L
      end
    end
  end
  for _, G in pairs(M.cards) do
    for _, I in ipairs(G.dups) do local L = M.free[I.T.guid] or {}; L[#L + 1] = I; M.free[I.T.guid] = L end
    self:levels(G)
  end
  return M
end

-- level of every variant and the loudness-match factor of each (1 when matching is off)
function App:levels(G)
  local card = G.card
  G.level, G.factor, G.cover = {}, {}, {}
  for vid, def in pairs(card.variants) do G.level[vid], G.cover[vid] = C.variant_level(def) end
  local ref = G.level[card.ref or "1"]
  if not ref then for _, vid in ipairs(self:variant_ids(card)) do if G.level[vid] then ref = G.level[vid]; break end end end
  for vid in pairs(card.variants) do
    G.factor[vid] = card.match and C.db_to_lin(C.match_gain(ref, G.level[vid], self.cfg.match_max_db)) or 1
  end
end

function App:variant_ids(card)
  local ids = {}
  for vid in pairs(card.variants) do ids[#ids + 1] = vid end
  table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
  return ids
end

local function same_source(I, m)
  if (I.midi or false) ~= (m.midi or false) then return false end
  if m.midi then return true end
  return (I.file or "") == (m.file or "")
end

local function find_piece(M, N, m)
  for _, I in ipairs(M.free[N.track] or {}) do
    if not I.used and same_source(I, m) and C.approx(I.pos, N.pos, 1e-4) and C.approx(I.len, N.len, 1e-4)
       and C.approx(I.soffs, N.soffs, 1e-4) then return I end
  end
end

-- which track does slot k of placement P use? (its own map; the card's original track if the map has none)
local function slot_guid(G, P, k)
  local g = P.map and P.map[k]
  if g and g ~= "" then return g end
  local s = G.card.slots[k]
  return s and s.guid
end

-- a full, explicit map: new placements get one, so later mapping changes never move existing placements
local function full_map(card, base)
  local out = {}
  for k, s in ipairs(card.slots) do
    local g = base and base[k]
    out[k] = (g and g ~= "") and g or s.guid
  end
  return out
end

-- the wanted piece of member m in placement P (track mapped, loudness match applied)
function App:piece(G, P, m)
  local mm = setmetatable({ track = slot_guid(G, P, m.slot) }, { __index = m })
  local N = C.visible(mm, P.W, (self.cfg.clipfade_ms or 0) / 1000)
  if N and not m.midi then N.vol = N.vol * (G.factor[P.def] or 1) end
  return N
end

local function syncs(P) return P.mode ~= "frozen" end
local function is_marker(P) return P.mode:sub(1, 2) == "m:" end       -- follows a marker (and goes with it)
local function is_temp(P) return P.mode == "t" end                     -- a solo audition (temporary tracks)
local function driven(P) return is_marker(P) or is_temp(P) end         -- no cut detection, no split children
local function kind_of(P) return (P.mode == "frozen" and "frozen") or (is_marker(P) and "marker") or (is_temp(P) and "audition") or "linked" end

local FROZEN_RGB = { 110, 110, 125 }
local function grey() return r.ColorToNative(FROZEN_RGB[1], FROZEN_RGB[2], FROZEN_RGB[3]) end

-- item colour of a placement's items: frozen = grey, else the idea's colour (option), else what the item had when stashed
function App:paint(ptr, G, kind, m)
  local col
  if kind == "g" then col = grey()
  elseif kind == "i" then col = G.card.color
  else col = m and m.color or 0 end
  RA.set_item_color(ptr, col)
end

---------------------------------------------------------------------------------------------------------- cuts
function App:do_cuts(M)
  local did = false
  for _, cid in ipairs(M.order) do
    local G = M.cards[cid]
    local def = G.card.variants[G.card.active]
    for _, pid in ipairs(G.order) do
      local P = G.inst[pid]
      local times = {}
      if def and syncs(P) and not driven(P) then
        for mid, mem in pairs(P.members) do
          local m = C.member_by_mid(def, mid)
          if m and mem.S then
            local pieces = {}
            for _, I in ipairs(M.free[mem.I.T.guid] or {}) do
              if same_source(I, m) then pieces[#pieces + 1] = { pos = I.pos, len = I.len, soffs = I.soffs, rate = I.rate } end
            end
            for _, t in ipairs(C.find_cuts(mem.S, RA.snap(mem.I), pieces)) do
              if t > P.W.pos + C.EPS and t < P.W.pos + P.W.len - C.EPS then
                local dup = false
                for _, x in ipairs(times) do if C.approx(x, t) then dup = true end end
                if not dup then times[#times + 1] = t end
              end
            end
          end
        end
      end
      table.sort(times, function(a, b) return a > b end)
      for _, t in ipairs(times) do
        RA.touch()
        if RA.split(P.item.ptr, t) then did = true; self.stats.cuts = (self.stats.cuts or 0) + 1 end
      end
    end
  end
  return did
end

---------------------------------------------------------------------------------------------------------- reconcile
local function new_pid(card)
  local id = tostring(card.next_pid or 1)
  card.next_pid = tonumber(id) + 1
  return id
end

function App:new_alias(M, G, pos, len, mode, map)
  local card = G.card
  local def = card.variants[card.active]
  RA.touch()
  mode = mode or ""
  local style = (mode:sub(1, 2) == "m:" and "marker") or (mode == "t" and "audition") or ""
  local it = RA.create_alias(M.lane.ptr, pos, len, 0, C.card_take_name(card.name, def and def.name, G.cid, style), card.color)
  local pid = new_pid(card)
  local fm = full_map(card, map)
  -- tags now: a placement is recognised by them, and a later sync must not take it for a copy
  RA.set_item_tag(it, "inst", G.cid .. "|" .. pid)
  RA.set_item_tag(it, "map", table.concat(fm, ","))
  RA.set_item_tag(it, "mode", mode)
  RA.set_item_tag(it, "var", card.active)
  local I = RA.read_item(it, M.lane)
  G.inst[pid] = { pid = pid, item = I, members = {}, mixed = {}, W = { pos = pos, len = len, offs = 0 }, has = {},
                  map = fm, mode = mode, copy = true, col = "" }
  G.order[#G.order + 1] = pid
  return G.inst[pid]
end

-- a marker named like an idea puts the idea there (a region trims it); the placement goes with the marker.
-- Also: leftovers of a solo audition (after an undo, a crash) are marked dead.
function App:markers(M)
  local want = {}                                   -- [marker key] = { cid, mk }
  for _, mk in ipairs(M.W.markers) do
    local cid = C.marker_card(mk.name, "", M.by_name)
    if cid then want[mk.key] = { cid = cid, mk = mk } end
  end
  local have = {}
  for _, cid in ipairs(M.order) do
    local G = M.cards[cid]
    for _, pid in ipairs(G.order) do
      local P = G.inst[pid]
      if is_temp(P) and not (self.aud and self.aud.cid == cid and self.aud.pid == pid) then P.dead = true end
      if is_marker(P) then
        local key = P.mode:sub(3)
        local w = want[key]
        if w and w.cid == cid and not have[key] then
          have[key] = P
          local def = G.card.variants[G.card.active]
          local len = w.mk.isrgn and (w.mk.rgnend - w.mk.pos) or (def and C.def_extent(def) or P.W.len)
          local Wn = { pos = w.mk.pos, len = math.max(len, 0.01), offs = 0 }
          if not (C.approx(Wn.pos, P.W.pos) and C.approx(Wn.len, P.W.len) and C.approx(P.W.offs, 0)) then
            RA.touch(); RA.set_window(P.item.ptr, Wn)
            P.W = Wn; P.W0 = nil
          end
        else
          P.dead = true                             -- marker gone, renamed, or a duplicate
        end
      end
    end
  end
  for key, w in pairs(want) do
    if not have[key] then
      local G = M.cards[w.cid]
      local def = G.card.variants[G.card.active]
      local len = w.mk.isrgn and (w.mk.rgnend - w.mk.pos) or (def and C.def_extent(def) or 1)
      self:new_alias(M, G, w.mk.pos, math.max(len, 0.01), "m:" .. key)
      self.stats.markers = (self.stats.markers or 0) + 1
    end
  end
end

function App:resolve_instances(G, M)
  local card = G.card
  -- 1. split pieces of known placements (same card, same anchor, inside the old extent)
  for _, pid in ipairs({ table.unpack(G.order) }) do
    local K = G.inst[pid]
    if K.known and syncs(K) and not driven(K) and not K.dead then
      local cands = {}
      for _, I in ipairs(G.untagged) do cands[#cands + 1] = { pos = I.pos, len = I.len, offs = I.soffs, I = I } end
      for _, c in ipairs(C.split_children(K.W0, K.W, cands)) do
        for k, I in ipairs(G.untagged) do if I == c.I then table.remove(G.untagged, k); break end end
        local nid = new_pid(card)
        G.inst[nid] = { pid = nid, item = c.I, members = {}, mixed = {}, has = {}, parent = K, split = true,
                        W = { pos = c.pos, len = c.len, offs = c.offs }, map = { table.unpack(K.map) }, mode = "" }
        G.order[#G.order + 1] = nid
      end
    end
  end
  -- 2. copies of placements (ctrl-drag, paste): linked, on the tracks the idea was last placed on
  for _, I in ipairs(G.untagged) do
    local nid = new_pid(card)
    G.inst[nid] = { pid = nid, item = I, members = {}, mixed = {}, has = {}, copy = true,
                    W = { pos = I.pos, len = I.len, offs = I.soffs }, map = full_map(card, card.map), mode = "" }
    G.order[#G.order + 1] = nid
    self.stats.copies = (self.stats.copies or 0) + 1
  end
  -- 3. every placement shows the active variant; a variant switch is not an edit
  for _, pid in ipairs(G.order) do
    local P = G.inst[pid]
    P.def = card.active
    if P.known and P.var_last and P.var_last ~= "" and P.var_last ~= card.active then P.relinked = true end
  end
  -- 4. hand members of a split placement over to the piece they now lie in (as AliasTrack)
  local by_parent = {}
  for _, pid in ipairs(G.order) do
    local X = G.inst[pid]
    if X.split then by_parent[X.parent] = by_parent[X.parent] or {}; table.insert(by_parent[X.parent], X) end
  end
  for P, kids in pairs(by_parent) do
    local bounds = {}
    for _, X in ipairs(kids) do bounds[#bounds + 1] = X.W.pos; bounds[#bounds + 1] = X.W.pos + X.W.len end
    for mid in pairs(P.has) do
      for _, X in ipairs(kids) do X.has[mid] = true end
      local pm = P.members[mid]
      if pm then
        local s, e = pm.I.pos, pm.I.pos + pm.I.len
        local cuts = {}
        for _, t in ipairs(bounds) do
          if t > s + C.EPS and t < e - C.EPS then
            local dup = false
            for _, x in ipairs(cuts) do if C.approx(x, t) then dup = true end end
            if not dup then cuts[#cuts + 1] = t end
          end
        end
        table.sort(cuts, function(a, b) return a > b end)
        local L = M.free[pm.I.T.guid] or {}
        M.free[pm.I.T.guid] = L
        for _, t in ipairs(cuts) do
          RA.touch()
          local rgt = RA.split(pm.I.ptr, t)
          if rgt then L[#L + 1] = RA.read_item(rgt, pm.I.T) end
        end
        if #cuts > 0 then pm.I = RA.read_item(pm.I.ptr, pm.I.T) end
        local pw = P.W
        if not (pm.I.pos >= pw.pos - C.EPS and pm.I.pos + pm.I.len <= pw.pos + pw.len + C.EPS) then
          P.members[mid] = nil
          L[#L + 1] = pm.I
        end
      end
    end
  end
end

function App:classify_edits(G, M)
  local card = G.card
  local edited = {}
  local no_move = function() return false end          -- a member moved to another track = mixed (Apply remaps)
  for _, pid in ipairs(G.order) do
    local P = G.inst[pid]
    local def = card.variants[P.def]
    if P.known and def and syncs(P) and not P.relinked and not P.dead then
      for mid, mem in pairs(P.members) do
        local m = C.member_by_mid(def, mid)
        if m then
          local N = self:piece(G, P, m)
          local res = C.classify(RA.snap(mem.I), mem.S, N,
            { in_folder = no_move, window = P.W, def_member = setmetatable({ track = N and N.track }, { __index = m }) })
          if res.kind == "mixed" then P.mixed[mid] = res.reason
          elseif res.kind == "edit" then
            if not self.cfg.propagate then P.mixed[mid] = "edited"
            elseif not edited[mid] then
              edited[mid] = true
              local e = res.edit
              e.track = nil
              if e.props.vol and not m.midi then e.props.vol = e.props.vol / (G.factor[P.def] or 1) end
              C.apply_edit(m, e)
              self.stats.edits = (self.stats.edits or 0) + 1
            end
          end
        end
      end
    end
  end
  -- members a placement had that are gone and not found as pieces = deleted by you
  for _, pid in ipairs(G.order) do
    local P = G.inst[pid]
    local def = card.variants[P.def]
    if def and syncs(P) and not P.relinked and not P.dead then
      for _, m in ipairs(def.members) do
        if P.has[m.mid] and not P.members[m.mid] and not P.mixed[m.mid] then
          local N = self:piece(G, P, m)
          if N and track_of(M.W, N.track) and not find_piece(M, N, m) then P.mixed[m.mid] = "missing" end
        end
      end
    end
  end
end

function App:handle_requests(G, M)
  local card = G.card
  for _, pid in ipairs(G.order) do
    local P = G.inst[pid]
    local key = G.cid .. "|" .. pid
    local req = self.requests[key]
    local def = card.variants[P.def]
    if req and def then
      for mid, reason in pairs(P.mixed) do
        local m = C.member_by_mid(def, mid)
        local mem = P.members[mid]
        if req == "revert" then
          if reason == "missing" then P.has[mid] = nil end
          P.mixed[mid] = nil
        elseif m then
          if reason == "missing" then
            local N = self:piece(G, P, m)
            if N then C.def_cut(def, mid, N.a, N.b) end
          elseif reason == "outside_folder" and mem then
            -- moved to another track: this placement now uses that track for the member's slot
            for k = 1, #card.slots do P.map[k] = slot_guid(G, P, k) or "" end
            P.map[m.slot] = mem.I.T.guid
          elseif mem then
            local A = RA.snap(mem.I)
            if reason == "outside_window" then
              local w = P.W
              local p0 = math.min(w.pos, A.pos)
              local p1 = math.max(w.pos + w.len, A.pos + A.len)
              P.W = { pos = p0, len = p1 - p0, offs = w.offs - (w.pos - p0) }
              RA.touch(); RA.set_window(P.item.ptr, P.W)
            end
            m.rel, m.len, m.soffs = A.pos - P.W.pos + P.W.offs, A.len, A.soffs
            for _, k in ipairs(C.PROPS) do m[k] = A[k] end
            m.vol = m.midi and A.vol or A.vol / (G.factor[P.def] or 1)
            m.fin, m.fout = A.fin, A.fout
          end
          P.mixed[mid] = nil
        end
      end
      self.requests[key] = nil
    end
  end
end

function App:materialize(G, M)
  local card = G.card
  local W = M.W
  local push = self.push[G.cid] or {}
  local leftovers = {}
  for _, pid in ipairs(G.order) do
    local P = G.inst[pid]
    local def = card.variants[P.def]
    if syncs(P) or P.dead then
      for mid, mem in pairs(P.members) do
        local m = def and C.member_by_mid(def, mid)
        if P.dead or (not P.mixed[mid] and not (m and self:piece(G, P, m))) then
          P.members[mid] = nil
          local L = M.free[mem.I.T.guid] or {}
          M.free[mem.I.T.guid] = L
          L[#L + 1] = mem.I
          leftovers[#leftovers + 1] = mem.I
        end
      end
    end
  end
  for _, pid in ipairs(G.order) do
    local P = G.inst[pid]
    local def = card.variants[P.def]
    local has_new, wanted, present, missing = {}, 0, 0, 0
    local ckind = (P.mode == "frozen" and "g") or (self.cfg.color_items and "i") or "o"
    if P.dead then
      RA.touch(); RA.delete_item(P.item.ptr); P.removed = true
    elseif not syncs(P) then
      for mid in pairs(P.members) do has_new[mid] = true; present = present + 1 end
    elseif def then
      for _, m in ipairs(def.members) do
        local N = self:piece(G, P, m)
        local mem = P.members[m.mid]
        local T = N and track_of(W, N.track)
        if N and not T then P.mixed[m.mid] = "track_gone" end
        if P.mixed[m.mid] then
          has_new[m.mid] = true
          if P.mixed[m.mid] == "missing" then missing = missing + 1 end
          if N then wanted = wanted + 1 end
        elseif N then
          wanted = wanted + 1
          local rebuild = false
          if mem and push[m.mid] and push[m.mid] ~= pid then
            RA.touch(); RA.delete_item(mem.I.ptr); mem = nil; rebuild = true
          end
          if mem then
            local A = RA.snap(mem.I)
            if not C.snap_eq(A, N) then
              RA.touch()
              local S = RA.write_member(mem.I.ptr, N, T.ptr)
              RA.set_item_tag(mem.I.ptr, "app", C.snap_encode(S))
              self.stats.updated = (self.stats.updated or 0) + 1
            else
              A.clipL, A.clipR = N.clipL, N.clipR
              local enc = C.snap_encode(A)
              if enc ~= mem.I.tag_a then RA.touch(); RA.set_item_tag(mem.I.ptr, "app", enc) end
            end
            present = present + 1
            has_new[m.mid] = true
          else
            local adopted = find_piece(M, N, m)
            if adopted then
              adopted.used = true
              RA.touch()
              RA.set_item_tag(adopted.ptr, "mem", G.cid .. "|" .. pid .. "|" .. m.mid)
              local S = RA.write_member(adopted.ptr, N, T.ptr)
              RA.set_item_tag(adopted.ptr, "app", C.snap_encode(S))
              self:paint(adopted.ptr, G, ckind, m)
              present = present + 1
              has_new[m.mid] = true
              self.stats.adopted = (self.stats.adopted or 0) + 1
            elseif P.has[m.mid] and not rebuild and not P.relinked then
              P.mixed[m.mid] = "missing"; has_new[m.mid] = true; missing = missing + 1
            else
              RA.touch()
              local it, S = RA.create_member(T.ptr, m.chunk, N, self.cfg.keep_pool)
              RA.set_item_tag(it, "mem", G.cid .. "|" .. pid .. "|" .. m.mid)
              RA.set_item_tag(it, "app", C.snap_encode(S))
              self:paint(it, G, ckind, m)
              present = present + 1
              has_new[m.mid] = true
              self.stats.created = (self.stats.created or 0) + 1
            end
          end
        end
      end
    end
    if not P.dead and (P.col or "") ~= ckind then                       -- frozen / colour option changed: recolour its items
      for mid, mem in pairs(P.members) do
        RA.touch(); self:paint(mem.I.ptr, G, ckind, def and C.member_by_mid(def, mid))
      end
    end
    local others = 0
    for _, why in pairs(P.mixed) do if why ~= "missing" and why ~= "track_gone" then others = others + 1 end end
    P.count = present + others
    if not P.removed then
      if P.split and wanted > 0 and present == 0 and missing == wanted then
        RA.touch(); RA.delete_item(P.item.ptr); P.removed = true
      else
        local I = P.item
        local want = {
          inst = G.cid .. "|" .. pid,
          win = string.format("%.10g|%.10g|%.10g", P.W.pos, P.W.len, P.W.offs),
          has = C.list_encode(has_new),
          map = table.concat(P.map, ","),
          mode = P.mode,
          var = syncs(P) and P.def or (P.var_last or ""),
          col = ckind,
        }
        local cur = { inst = I.tag_i, win = I.tag_w, has = I.tag_h or "", map = I.tag_map or "", mode = I.tag_mode or "",
                      var = I.tag_v or "", col = I.tag_col or "" }
        for k, v in pairs(want) do if cur[k] ~= v then RA.touch(); RA.set_item_tag(I.ptr, k, v) end end
        local shown = syncs(P) and def or card.variants[P.var_last or ""] or def
        local def_name = shown and shown.name or "?"
        local style = (P.mode == "frozen" and "frozen") or (is_marker(P) and "marker") or (is_temp(P) and "audition") or ""
        local want_name = C.card_take_name(card.name, def_name, G.cid, style)
        if I.tname ~= want_name or not P.known then
          RA.touch(); RA.style_alias(I.ptr, want_name, P.mode == "frozen" and grey() or card.color)
        end
      end
    end
  end
  for _, I in ipairs(leftovers) do
    if not I.used then RA.touch(); RA.delete_item(I.ptr); self.stats.deleted = (self.stats.deleted or 0) + 1 end
  end
  self.push[G.cid] = nil
end

function App:finish_card(G, M)
  for _, I in ipairs(G.orphans) do
    RA.touch()
    if self.cfg.delete_with_alias then RA.delete_item(I.ptr); self.stats.deleted = (self.stats.deleted or 0) + 1
    else RA.set_item_tag(I.ptr, "mem", ""); RA.set_item_tag(I.ptr, "app", "") end
  end
  for _, I in ipairs(G.dups) do
    if I.tag_m ~= "" and not I.used then RA.touch(); RA.set_item_tag(I.ptr, "mem", ""); RA.set_item_tag(I.ptr, "app", "") end
  end
  for _, def in pairs(G.card.variants) do def.len = C.def_extent(def) end
end

function App:reconcile(M)
  if M.lane then self:markers(M) end
  for _, cid in ipairs(M.order) do
    local G = M.cards[cid]
    self:resolve_instances(G, M)
    self:classify_edits(G, M)
    self:handle_requests(G, M)
    self:levels(G)
    self:materialize(G, M)
    self:finish_card(G, M)
  end
  for _, I in ipairs(M.stray) do RA.touch(); RA.set_item_tag(I.ptr, "mem", ""); RA.set_item_tag(I.ptr, "app", "") end
  for _, T in ipairs(M.release_lanes) do
    RA.touch(); RA.set_track_tag(T.ptr, "lane", ""); RA.set_track_tag(T.ptr, "pool", "")
    for _, I in ipairs(T.items) do if I.tag_i ~= "" then RA.set_item_tag(I.ptr, "inst", "") end end
  end
  if M.lane then
    local enc = C.json_encode(M.pool)
    if enc ~= M.raw then RA.touch(); RA.set_track_tag(M.lane.ptr, "pool", enc) end
  end
  -- temporary audition tracks that nobody is playing (after an undo or a crash): their items went with the dead
  -- placements above; the tracks go last, so no item pointer is used after its track is deleted
  if not self.aud then
    for _, T in ipairs(M.aud_tracks) do RA.touch(); RA.delete_track(T.ptr) end
  end
end

---------------------------------------------------------------------------------------------------------- view
function App:make_view(M)
  local v = { cards = {}, lane = M.lane ~= nil, foreign = #M.foreign }
  for _, cid in ipairs(M.order) do
    local G = M.cards[cid]
    local card = G.card
    local c = { cid = cid, name = card.name, color = card.color, active = card.active, match = card.match or false,
                bpm = card.bpm or 120,
                variants = {}, slots = {}, places = {}, markers = 0, frozen = 0,
                auditioning = (self.aud and self.aud.cid == cid) or false }
    for _, vid in ipairs(self:variant_ids(card)) do
      local def = card.variants[vid]
      local members = {}
      for _, m in ipairs(def.members) do
        local s = card.slots[m.slot]
        members[#members + 1] = { mid = m.mid, slot = m.slot, track = s and s.name or "?", rel = m.rel, len = m.len,
                                  fin = m.fin or 0, fout = m.fout or 0, vol = m.vol or 1, mute = m.mute or 0,
                                  midi = m.midi, measured = m.stats ~= nil, soffs = m.soffs or 0, rate = m.rate or 1,
                                  file = m.file, notes = m.midi and self:notes(m.chunk) or nil }
      end
      c.variants[#c.variants + 1] = { vid = vid, name = def.name, len = C.def_extent(def), level = G.level[vid],
                                      cover = G.cover[vid] or 0, gain_db = C.lin_to_db(G.factor[vid] or 1),
                                      members = members, active = vid == card.active }
    end
    for k, s in ipairs(card.slots) do
      local T = track_of(M.W, s.guid)
      c.slots[k] = { name = T and T.name or s.name, gone = T == nil, midi = s.midi or false }
    end
    for _, pid in ipairs(G.order) do
      local P = G.inst[pid]
      if not P.removed then
        local reasons = {}
        for _, why in pairs(P.mixed) do reasons[#reasons + 1] = why end
        table.sort(reasons)
        local kind = kind_of(P)
        if kind == "audition" then                                   -- a solo audition is not a placement: no row, but a playhead
          c.aud = { pid = pid, pos = P.W.pos, len = P.W.len, offs = P.W.offs }
        else
          if kind == "marker" then c.markers = c.markers + 1 elseif kind == "frozen" then c.frozen = c.frozen + 1 end
          local count = P.count
          if not count then count = 0; for _ in pairs(P.members) do count = count + 1 end end
          c.places[#c.places + 1] = { pid = pid, pos = P.W.pos, len = P.W.len, offs = P.W.offs, kind = kind, mixed = #reasons,
                                      reasons = reasons, members = count }
        end
      end
    end
    table.sort(c.places, function(a, b) return a.pos < b.pos end)
    v.cards[#v.cards + 1] = c
  end
  self.view = v
end

function App:card_view(cid)
  for _, c in ipairs(self.view.cards) do if c.cid == cid then return c end end
end

---------------------------------------------------------------------------------------------------------- sync
function App:sync(view_only, mode_override)
  self.stats = {}
  if view_only then self:make_view(self:build(RA.scan())); return false end
  RA.begin_writes(mode_override or self.cfg.undo_mode)
  local done
  local ok, err = pcall(function()
    for _ = 1, 4 do
      local M = self:build(RA.scan())
      if not self:do_cuts(M) then
        self:reconcile(M); done = M
        if next(M.sub) or self.cfg.sub_lanes then self:cleanup_sublanes() end
        break
      end
    end
  end)
  local changed = RA.end_writes()
  if not ok then self.err = tostring(err) else self.err = nil end
  self:make_view(done or self:build(RA.scan()))
  self.last_sync = { changed = changed, stats = self.stats }
  return changed
end

---------------------------------------------------------------------------------------------------------- commands
-- run fn(M) inside one undo step, save the pool it changed, then sync
function App:edit(label, fn)
  local res
  RA.with_undo("IdeaPool: " .. label, function()
    local M = self:build(RA.scan())
    res = fn(M)
    if M.lane then RA.set_track_tag(M.lane.ptr, "pool", C.json_encode(M.pool)) end
    self:sync(false, "none")
  end)
  return res
end

function App:ensure_lane()
  local W = RA.scan()
  for _, T in ipairs(W.tracks) do if T.lane == "ideas" then return T.ptr end end
  local tr = RA.insert_track(0, "IDEAS", 0)
  RA.set_track_tag(tr, "lane", "ideas")
  RA.set_track_tag(tr, "pool", C.json_encode({ v = 1, next_card = 1, cards = {}, order = {} }))
  return tr
end

-- the track an item "belongs to": its own, or the owner of the sub-lane it is on
function App:home(W, T)
  if T.lane:sub(1, 4) == "sub:" then return W.by_guid[T.lane:sub(5)] or T end
  return T
end

function App:selection()
  local W = RA.scan()
  local sel, n_members = {}, 0
  for _, I in ipairs(W.items) do
    if I.sel and (I.T.lane == "" or I.T.lane:sub(1, 4) == "sub:") then
      sel[#sel + 1] = I
      if I.tag_m ~= "" then n_members = n_members + 1 end
    end
  end
  local tracks = {}
  local nt = 0
  for _, I in ipairs(sel) do if not tracks[I.T.i] then tracks[I.T.i] = true; nt = nt + 1 end end
  return { W = W, sel = sel, n = #sel, tracks = nt, members = n_members }
end

function App:unique_name(pool, name)
  local taken = {}
  for _, c in pairs(pool.cards) do taken[C.norm_name(c.name)] = true end
  if not taken[C.norm_name(name)] then return name end
  local k = 2
  while taken[C.norm_name(name .. " " .. k)] do k = k + 1 end
  return name .. " " .. k
end

-- selected items -> a new card (variant A). mode: "keep" | "link" | "remove" (default: the setting)
function App:stash(name, mode)
  mode = mode or self.cfg.stash_mode
  local info = self:selection()
  if info.n == 0 then self.msg = "Select the items to stash first."; return false end
  local sel = info.sel
  table.sort(sel, function(a, b) if a.T.i ~= b.T.i then return a.T.i < b.T.i end return a.pos < b.pos end)
  local P0, E = math.huge, -math.huge
  for _, I in ipairs(sel) do P0 = math.min(P0, I.pos); E = math.max(E, I.pos + I.len) end
  local stats = {}
  for k, I in ipairs(sel) do stats[k] = RA.measure(I.ptr) end          -- read the audio before anything moves
  local cid
  RA.with_undo("IdeaPool: stash items", function()
    local lane = self:ensure_lane()
    local M = self:build(RA.scan())
    local pool = M.pool
    cid = tostring(pool.next_card or 1)
    pool.next_card = tonumber(cid) + 1
    local slots, slot_of = {}, {}
    for _, I in ipairs(sel) do
      local H = self:home(info.W, I.T)                              -- an item on a sub-lane belongs to its owner track
      if not slot_of[H.guid] then slots[#slots + 1] = { guid = H.guid, name = H.name }; slot_of[H.guid] = #slots end
      if I.midi then slots[slot_of[H.guid]].midi = true end         -- MIDI slots stay on the original track
    end
    local members = {}
    for k, I in ipairs(sel) do
      members[k] = { mid = k, slot = slot_of[self:home(info.W, I.T).guid], rel = I.pos - P0, len = I.len, soffs = I.soffs, rate = I.rate,
                     pitch = I.pitch, tvol = I.tvol, vol = I.vol, mute = I.mute, fin = I.fin, fout = I.fout,
                     file = I.file, midi = I.midi, chunk = RA.item_chunk(I.ptr), stats = stats[k], color = I.color }
    end
    local base = (name and name:match("%S")) and name:gsub("^%s+", ""):gsub("%s+$", "")
                 or ((sel[1].tname ~= "" and sel[1].tname:gsub("%.%w+$", "")) or ("Idea " .. cid))
    local c = PALETTE[((tonumber(cid) - 1) % #PALETTE) + 1]
    local card = { id = cid, name = self:unique_name(pool, base), color = r.ColorToNative(c[1], c[2], c[3]), active = "1",
                   ref = "1", next_var = 2, next_pid = 1, match = false, slots = slots, map = {}, origin = P0,
                   bpm = RA.tempo_at(P0),
                   variants = { ["1"] = { name = "A", members = members, next_mid = #members + 1, len = E - P0 } } }
    pool.cards[cid] = card
    pool.order[#pool.order + 1] = cid
    if mode == "link" then
      local G = { cid = cid, card = card, inst = {}, order = {} }
      local it = RA.create_alias(lane, P0, E - P0, 0, C.card_take_name(card.name, "A", cid, ""), card.color)
      local pid = new_pid(card)
      local has = {}
      for k in ipairs(sel) do has[k] = true end
      local map = {}
      for k, s in ipairs(slots) do map[k] = s.guid end
      RA.set_item_tag(it, "inst", cid .. "|" .. pid)
      RA.set_item_tag(it, "win", string.format("%.10g|%.10g|%.10g", P0, E - P0, 0))
      RA.set_item_tag(it, "has", C.list_encode(has))
      RA.set_item_tag(it, "map", table.concat(map, ","))
      RA.set_item_tag(it, "var", "1")
      for k, I in ipairs(sel) do
        RA.set_item_tag(I.ptr, "mem", cid .. "|" .. pid .. "|" .. k)
        RA.set_item_tag(I.ptr, "app", C.snap_encode(RA.snap(I)))
      end
    elseif mode == "remove" then
      for _, I in ipairs(sel) do RA.delete_item(I.ptr) end
    end
    RA.set_track_tag(lane, "pool", C.json_encode(pool))
    self:sync(false, "none")
  end)
  self.msg = string.format("Stashed %d item(s) as '%s'.", #sel, self.view.cards[#self.view.cards] and self.view.cards[#self.view.cards].name or "?")
  self.selected = cid
  return cid
end

-- a new linked placement. where: "cursor" (original tracks) | "selected" (slot 1 on the selected track) | "origin"
-- the track that carries slot k's items for this placement: the owner itself, or (option) its sub-lane.
-- MIDI slots always stay on the original track: a child track cannot reach the parent's instrument.
local SUB_RGB = { 0x85, 0x42, 0xFA }
function App:ensure_sublane(owner_guid)
  local W = RA.scan()
  local owner = W.by_guid[owner_guid]
  if not owner then return owner_guid end
  local tag = "sub:" .. owner_guid
  for _, T in ipairs(W.tracks) do if T.lane == tag then return T.guid end end
  local new_owner, child = C.sublane_insert(owner.depth)
  local tr, guid = RA.insert_track(owner.i, "-> " .. owner.name .. " (ideas)", r.ColorToNative(SUB_RGB[1], SUB_RGB[2], SUB_RGB[3]))
  RA.set_depth(owner.ptr, new_owner)
  RA.set_depth(tr, child)
  RA.set_track_tag(tr, "lane", tag)
  return guid
end

-- empty sub-lanes that no placement refers to go away; the folder depths are put back
function App:cleanup_sublanes()
  local M = self:build(RA.scan())
  if next(M.sub) == nil then return end
  local refs = {}
  for _, cid in ipairs(M.order) do
    local G = M.cards[cid]
    for _, pid in ipairs(G.order) do for _, g in ipairs(G.inst[pid].map) do refs[g] = true end end
  end
  local doomed = {}
  for _, T in pairs(M.sub) do if #T.items == 0 and not refs[T.guid] then doomed[#doomed + 1] = T end end
  table.sort(doomed, function(a, b) return a.i > b.i end)
  for _, T in ipairs(doomed) do
    local prev = M.W.tracks[T.i - 1]
    RA.touch()
    if prev and T.depth < 0 then RA.set_depth(prev.ptr, C.depth_after_removal(prev.depth, T.depth)) end
    RA.set_depth(T.ptr, 0)
    RA.delete_track(T.ptr)
  end
end

-- a new linked placement. where: "cursor" (original tracks) | "selected" (first track on the selected track) | "origin"
function App:place(cid, where)
  local W = RA.scan()
  local sel_tracks = RA.selected_tracks()
  if where == "selected" and #sel_tracks == 0 then self.msg = "Select a track first."; return false end
  return self:edit("place idea", function(M)
    local G = M.cards[cid]
    if not G then return false end
    local card = G.card
    local def = card.variants[card.active]
    local len = C.def_extent(def)
    local pos = (where == "origin") and (card.origin or W.cursor) or W.cursor
    -- owners: slot k -> the real track it belongs to (lanes are not counted when tracks are mapped by distance)
    local real, ridx = {}, {}
    for _, T in ipairs(W.tracks) do if T.lane == "" then real[#real + 1] = T; ridx[T.guid] = #real end end
    local owners = {}
    if where == "selected" then
      local home = self:home(W, W.by_guid[RA.track_guid(sel_tracks[1])] or W.tracks[1])
      local origin = {}
      for k, s in ipairs(card.slots) do origin[k] = ridx[s.guid] end
      for k, idx in ipairs(C.map_slots(origin, ridx[home.guid] or 1, #real, #card.slots)) do owners[k] = real[idx].guid end
    else
      for k, s in ipairs(card.slots) do owners[k] = s.guid end
    end
    local map = {}
    for k, s in ipairs(card.slots) do
      map[k] = (self.cfg.sub_lanes and not s.midi) and self:ensure_sublane(owners[k]) or owners[k]
    end
    card.map = full_map(card, map)                  -- copies of placements use the last mapping
    self:new_alias(M, G, pos, len, "", map)
    return true
  end)
end

---------------------------------------------------------------------------------------------------------- solo audition
-- Temporary tracks (one per original track, with its FX chain), the idea placed on them as an ordinary placement,
-- everything else un-soloed, a loop over the idea, play. When playback stops everything is removed again.
-- Syncs and A/B switches work as for any placement; no undo points are made.
function App:silent(fn)
  RA.begin_writes("none")
  local ok, err = pcall(fn)
  RA.end_writes()
  if not ok then error(err, 0) end
end

function App:audition(cid)
  cid = tostring(cid)
  if self.aud then self:stop_audition() end
  local M0 = self:build(RA.scan())
  local G0 = M0.cards[cid]
  if not G0 or not M0.lane then self.msg = "Nothing to audition."; return false end
  local W = M0.W
  local card = G0.card
  local def = card.variants[card.active]
  local len = math.max(C.def_extent(def), 0.05)
  local pos = W.cursor
  local aud = { cid = cid, solo = {}, t0 = r.time_precise(), pos = pos, len = len }
  for _, T in ipairs(W.tracks) do aud.solo[T.guid] = T.solo end
  local ok, err = pcall(function()
    self:silent(function()
      local map = {}
      for k, s in ipairs(card.slots) do
        local tr, guid = RA.insert_track(RA.track_count(), "IdeaPool audition: " .. s.name, r.ColorToNative(SUB_RGB[1], SUB_RGB[2], SUB_RGB[3]))
        RA.set_track_tag(tr, "lane", "audition")
        local owner = W.by_guid[s.guid]
        if self.cfg.audition_fx and owner then
          local blk = RA.track_fxchain(owner.ptr)
          if blk then RA.add_fxchain(tr, blk) end
        end
        map[k] = guid
      end
      for _, T in ipairs(W.tracks) do if T.solo ~= 0 then RA.set_solo(T.ptr, 0) end end
      local W2 = RA.scan()
      for _, g in ipairs(map) do local T = W2.by_guid[g]; if T then RA.set_solo(T.ptr, 2) end end
      local M = self:build(W2)
      local P = self:new_alias(M, M.cards[cid], pos, len, "t", map)
      aud.pid = P.pid
      self.aud = aud                                   -- from now on the placement is expected (not a leftover)
      RA.set_track_tag(M.lane.ptr, "pool", C.json_encode(M.pool))
    end)
    self:sync(false, "none")
  end)
  if not ok then
    self.aud = aud
    pcall(self.stop_audition, self)
    self.err = "Audition failed: " .. tostring(err)
    return false
  end
  if self.cfg.audition_loop then aud.loop = RA.loop_save(); RA.loop_set(pos, pos + len) end
  RA.play_from(pos)
  aud.t0 = r.time_precise()
  return true
end

function App:stop_audition()
  local aud = self.aud
  if not aud then return end
  self.aud = nil
  if RA.is_playing() then RA.stop() end
  if aud.loop then RA.loop_restore(aud.loop) end
  local ok, err = pcall(function()
    self:silent(function()
      local M = self:build(RA.scan())
      local G = M.cards[aud.cid]
      local P = G and G.inst[aud.pid]
      if P then
        for _, mem in pairs(P.members) do RA.delete_item(mem.I.ptr) end
        RA.delete_item(P.item.ptr)
      end
      local W = RA.scan()                              -- items first, tracks last: no pointer is used after its track is gone
      for _, T in ipairs(W.tracks) do if T.lane == "audition" then RA.delete_track(T.ptr) end end
      local W3 = RA.scan()
      for guid, v in pairs(aud.solo) do
        local T = W3.by_guid[guid]
        if T and T.solo ~= v then RA.set_solo(T.ptr, v) end
      end
    end)
  end)
  if not ok then self.err = "Audition cleanup failed: " .. tostring(err) end
  self:refresh()
end

function App:shutdown() self:stop_audition() end

function App:find(cid, pid)
  local M = self:build(RA.scan())
  local G = M.cards[tostring(cid)]
  return M, G, G and G.inst[tostring(pid)]
end

-- marker placement -> ordinary linked placement: it stays, the marker is removed (it would place the idea again)
function App:keep(cid, pid)
  local M, G, P = self:find(cid, pid)
  if not P or not is_marker(P) then return end
  local key = P.mode:sub(3)
  RA.with_undo("IdeaPool: keep marker placement", function()
    for _, mk in ipairs(M.W.markers) do if mk.key == key then RA.delete_marker(mk) end end
    RA.set_item_tag(P.item.ptr, "mode", "")
    self:sync(false, "none")
  end)
end

function App:freeze(cid, pid, on)
  local M, G, P = self:find(cid, pid)
  if not P or driven(P) then return end
  -- unfreezing = the placement shows the card again; what it looked like while frozen is replaced
  -- (use "Save as variant" first to keep it)
  RA.with_undo(on and "IdeaPool: freeze placement" or "IdeaPool: unfreeze placement", function()
    RA.set_item_tag(P.item.ptr, "mode", on and "frozen" or "")
    if not on then RA.set_item_tag(P.item.ptr, "var", "relink") end
    self:sync(false, "none")
  end)
end

-- members become plain items, the placement is removed (a marker placement: its marker goes too)
function App:detach(cid, pid)
  local M, G, P = self:find(cid, pid)
  if not P then return end
  RA.with_undo("IdeaPool: detach placement", function()
    for _, mem in pairs(P.members) do RA.set_item_tag(mem.I.ptr, "mem", ""); RA.set_item_tag(mem.I.ptr, "app", "") end
    if is_marker(P) then
      local key = P.mode:sub(3)
      for _, mk in ipairs(M.W.markers) do if mk.key == key then RA.delete_marker(mk) end end
    end
    RA.delete_item(P.item.ptr)
    self:sync(false, "none")
  end)
end

-- what a placement looks like now -> a new variant of its card (made active)
function App:save_variant(cid, pid)
  local vid
  local _, _, P0 = self:find(cid, pid)
  if not P0 then return end
  local measured = {}
  for mid, mem in pairs(P0.members) do measured[mid] = RA.measure(mem.I.ptr) end
  self:edit("save placement as variant", function(M)
    local G = M.cards[tostring(cid)]
    local P = G and G.inst[tostring(pid)]
    if not P then return end
    local card = G.card
    local src = card.variants[P.def] or card.variants[card.active]
    vid = tostring(card.next_var or 2)
    card.next_var = tonumber(vid) + 1
    local slot_of = {}
    for k = 1, #card.slots do slot_of[slot_guid(G, P, k)] = k end
    local members = {}
    for mid, mem in pairs(P.members) do
      local I = mem.I
      local old = src and C.member_by_mid(src, mid)
      local slot = slot_of[I.T.guid] or (old and old.slot) or 1
      members[#members + 1] = {
        mid = mid, slot = slot, rel = I.pos - P.W.pos + P.W.offs, len = I.len, soffs = I.soffs, rate = I.rate,
        pitch = I.pitch, tvol = I.tvol, vol = I.midi and I.vol or I.vol / (G.factor[P.def] or 1), mute = I.mute,
        fin = I.fin, fout = I.fout, color = old and old.color,
        file = I.file, midi = I.midi, chunk = RA.item_chunk(I.ptr), stats = measured[mid] or (old and old.stats) }
    end
    table.sort(members, function(a, b) return a.mid < b.mid end)
    local next_mid = 1
    for _, m in ipairs(members) do next_mid = math.max(next_mid, m.mid + 1) end
    card.variants[vid] = { name = C.variant_letter(tonumber(vid)), members = members, next_mid = next_mid }
    card.active = vid
    if P.mode == "frozen" then RA.set_item_tag(P.item.ptr, "mode", "") end
    RA.set_item_tag(P.item.ptr, "var", vid)
  end)
  return vid
end

function App:duplicate_variant(cid, vid)
  local nv
  self:edit("duplicate variant", function(M)
    local G = M.cards[tostring(cid)]
    if not G then return end
    local card = G.card
    local src = card.variants[tostring(vid)]
    if not src then return end
    nv = tostring(card.next_var or 2)
    card.next_var = tonumber(nv) + 1
    local d = C.copy(src)
    d.name = C.variant_letter(tonumber(nv))
    card.variants[nv] = d
    card.active = nv
  end)
  return nv
end

function App:set_active(cid, vid)
  self:edit("switch variant", function(M)
    local G = M.cards[tostring(cid)]
    if G and G.card.variants[tostring(vid)] then G.card.active = tostring(vid) end
  end)
end

function App:delete_variant(cid, vid)
  self:edit("delete variant", function(M)
    local G = M.cards[tostring(cid)]
    if not G then return end
    local card = G.card
    vid = tostring(vid)
    local ids = self:variant_ids(card)
    if #ids <= 1 or not card.variants[vid] then return end
    card.variants[vid] = nil
    if card.active == vid then card.active = self:variant_ids(card)[1] end
    if card.ref == vid then card.ref = self:variant_ids(card)[1] end
  end)
end

function App:set_match(cid, on)
  self:edit(on and "match loudness" or "stop matching loudness", function(M)
    local G = M.cards[tostring(cid)]
    if G then G.card.match = on end
  end)
end

function App:set_ref(cid, vid)
  self:edit("loudness reference", function(M)
    local G = M.cards[tostring(cid)]
    if G and G.card.variants[tostring(vid)] then G.card.ref = tostring(vid) end
  end)
end

-- edit members of a variant from the window (numbers or a drag in the waveform view): one undo step.
-- fields: rel, len, soffs, fin, fout, vol (linear), mute (bool)
function App:set_member_fields(cid, vid, mid, fields, label)
  self:edit(label or "edit idea", function(M)
    local G = M.cards[tostring(cid)]
    local def = G and G.card.variants[tostring(vid)]
    local m = def and C.member_by_mid(def, mid)
    if not m then return end
    local f = fields
    if f.rel then m.rel = math.max(0, f.rel) end
    if f.len then m.len = math.max(C.MIN_LEN, f.len) end
    if f.soffs then m.soffs = f.soffs end
    if f.vol then m.vol = math.max(0, f.vol) end
    if f.mute ~= nil then m.mute = f.mute and 1 or 0 end
    if f.fin then m.fin = math.max(0, math.min(f.fin, m.len)) end
    if f.fout then m.fout = math.max(0, math.min(f.fout, m.len)) end
    m.fin = math.min(m.fin or 0, m.len); m.fout = math.min(m.fout or 0, m.len)
  end)
end

function App:set_member(cid, vid, mid, field, value)
  self:set_member_fields(cid, vid, mid, { [field] = value })
end

function App:rename(cid, name)
  if not name or not name:match("%S") then return end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  self:edit("rename idea", function(M)
    local G = M.cards[tostring(cid)]
    if not G then return end
    local others = {}
    for k, c in pairs(M.pool.cards) do if k ~= G.cid then others[k] = c end end
    local old = C.norm_name(G.card.name)
    G.card.name = self:unique_name({ cards = others }, name)
    -- markers that placed this idea follow its new name
    for _, mk in ipairs(M.W.markers) do
      if C.norm_name(mk.name) == old and M.by_name[old] == G.cid then RA.rename_marker(mk, G.card.name) end
    end
  end)
end

-- the card leaves the pool; its placements become plain items (auditions are removed)
function App:delete_card(cid)
  if self.aud and self.aud.cid == tostring(cid) then self:stop_audition() end
  self:edit("delete idea", function(M)
    local G = M.cards[tostring(cid)]
    if not G then return end
    for _, pid in ipairs(G.order) do
      local P = G.inst[pid]
      for _, mem in pairs(P.members) do
        if driven(P) then RA.delete_item(mem.I.ptr)
        else RA.set_item_tag(mem.I.ptr, "mem", ""); RA.set_item_tag(mem.I.ptr, "app", "") end
      end
      RA.delete_item(P.item.ptr)
    end
    M.pool.cards[G.cid] = nil
    for i, id in ipairs(M.pool.order) do if id == G.cid then table.remove(M.pool.order, i); break end end
  end)
  if self.selected == tostring(cid) then self.selected = nil end
end

function App:measure(cid, pid)
  local _, _, P0 = self:find(cid, pid)
  if not P0 then return end
  local measured = {}
  for mid, mem in pairs(P0.members) do measured[mid] = RA.measure(mem.I.ptr) end
  self:edit("measure idea", function(M)
    local G = M.cards[tostring(cid)]
    local P = G and G.inst[tostring(pid)]
    local def = P and G.card.variants[G.card.active]
    if not def then return end
    for mid, st in pairs(measured) do
      local m = C.member_by_mid(def, mid)
      if m and st then m.stats = st end
    end
  end)
end

function App:request(cid, pid, what)
  self.requests[tostring(cid) .. "|" .. tostring(pid)] = what
  RA.with_undo(what == "apply" and "IdeaPool: apply placement edits" or "IdeaPool: revert placement", function()
    self:sync(false, "none")
  end)
end

function App:select_placement(cid, pid)
  local _, _, P = self:find(cid, pid)
  if not P then return end
  local list = { P.item.ptr }
  for _, mem in pairs(P.members) do list[#list + 1] = mem.I.ptr end
  RA.select_only(list)
  RA.set_cursor(P.W.pos)
end

function App:detach_all()
  local W = RA.scan()
  RA.with_undo("IdeaPool: detach all", function()
    for _, T in ipairs(W.tracks) do
      if T.lane ~= "" then RA.set_track_tag(T.ptr, "lane", ""); RA.set_track_tag(T.ptr, "pool", "") end
    end
    for _, I in ipairs(W.items) do
      if I.tag_i ~= "" then for _, k in ipairs({ "inst", "win", "has", "map", "mode", "var", "col" }) do RA.set_item_tag(I.ptr, k, "") end end
      if I.tag_m ~= "" then RA.set_item_tag(I.ptr, "mem", ""); RA.set_item_tag(I.ptr, "app", "") end
    end
  end)
  self:sync(true)
end

return App
