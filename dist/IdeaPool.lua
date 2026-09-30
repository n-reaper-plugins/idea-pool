-- @description IdeaPool: stash items as ideas, keep variants, place them as linked copies, audition them at markers
-- @version 0.1.0
-- @author _n_plugins
-- @about
--   Select items (any tracks) and stash them as an idea. Ideas keep variants (A, B, ...) with optional loudness matching,
--   are placed back as linked placements on an IDEAS track (edit one, all follow; freeze or detach any), and a marker
--   named like an idea auditions it right there in the song. Everything is stored in the project.
--   Needs ReaImGui (ReaPack > ReaTeam Extensions). Run the action again while the window is open to close it.
-- BUNDLED BUILD of IdeaPool v0.1.0 - edit the files in src/, not this one.
local __preload = package.preload
__preload["IPVersion"] = function(...)
return { VERSION = "0.1.0" }

end
__preload["IPCore"] = function(...)
-- IPCore.lua  (copied from AliasTrack ATCore v0.1.0, then extended - see the "IdeaPool" section at the end)
-- Pure logic for IdeaPool. No reaper.* calls here, so everything in this file is tested with plain Lua.
--
-- Model
--   group      one ALIAS lane track (linked instances) + optional COPIES lane (unique instances), inside one folder
--   def        a definition: member items in def-local time 0..len (the "virtual source" of an alias)
--   instance   one alias item = a window { pos, len, offs } onto a def (offs = the alias take's start offset)
--   member     a real item materialised from a def member, clipped to the window and shifted to the window's position

local C = {}

C.EPS = 1e-5            -- seconds; positions/lengths closer than this are equal

local function approx(a, b, eps) return math.abs((a or 0) - (b or 0)) <= (eps or C.EPS) end
C.approx = approx

--------------------------------------------------------------------------------------------------- snapshots
-- A snapshot is what one member item looks like: geometry + the properties we propagate.
C.GEOM  = { "pos", "len", "soffs" }
C.PROPS = { "vol", "mute", "rate", "pitch", "tvol" }
C.FADES = { "fin", "fout" }
C.FIELDS = { "pos", "len", "soffs", "vol", "mute", "rate", "pitch", "tvol", "fin", "fout", "track" }

local function num(v) return string.format("%.10g", v or 0) end

-- the last field carries the clip flags (1 = left edge clipped, 2 = right edge clipped)
function C.snap_encode(s)
  local out = {}
  for i, k in ipairs(C.FIELDS) do out[i] = (k == "track") and (s.track or "") or num(s[k]) end
  out[#out + 1] = tostring((s.clipL and 1 or 0) + (s.clipR and 2 or 0))
  return table.concat(out, "|")
end

function C.snap_decode(str)
  if not str or str == "" then return nil end
  local parts, s = {}, {}
  for p in (str .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = p end
  if #parts < #C.FIELDS then return nil end
  for i, k in ipairs(C.FIELDS) do
    if k == "track" then s[k] = parts[i] else s[k] = tonumber(parts[i]) or 0 end
  end
  local clip = tonumber(parts[#C.FIELDS + 1]) or 0
  s.clipL, s.clipR = clip % 2 == 1, clip >= 2
  return s
end

function C.geom_eq(a, b)
  if not a or not b then return false end
  return approx(a.pos, b.pos) and approx(a.len, b.len) and approx(a.soffs, b.soffs) and (a.track or "") == (b.track or "")
end

function C.props_eq(a, b)
  if not a or not b then return false end
  for _, k in ipairs(C.PROPS) do if not approx(a[k], b[k]) then return false end end
  return true
end

-- equal as far as we care: geometry, props and the fades on edges that are not clipped
function C.snap_eq(a, b)
  if not (C.geom_eq(a, b) and C.props_eq(a, b)) then return false end
  if not b.clipL and not approx(a.fin, b.fin) then return false end
  if not b.clipR and not approx(a.fout, b.fout) then return false end
  return true
end

--------------------------------------------------------------------------------------------------- windows
-- anchor = the project time at which def-local time 0 sits. All pieces of one window share it (splits keep it).
function C.anchor(pos, offs, rate) return pos - (offs or 0) / (rate or 1) end

-- The part of def member m visible through window w, as a snapshot (or nil if nothing is visible).
-- m: { track, rel, len, soffs, rate, pitch, tvol, vol, mute, fin, fout }   w: { pos, len, offs }
function C.visible(m, w, clipfade)
  local a = math.max(m.rel, w.offs)
  local b = math.min(m.rel + m.len, w.offs + w.len)
  if b - a <= C.EPS then return nil end
  local clipL = a > m.rel + C.EPS
  local clipR = b < m.rel + m.len - C.EPS
  local len = b - a
  local cf = math.min(clipfade or 0, len / 2)
  local fin  = clipL and cf or math.min(m.fin or 0, len)
  local fout = clipR and cf or math.min(m.fout or 0, len)
  return {
    track = m.track, pos = w.pos + (a - w.offs), len = len,
    soffs = (m.soffs or 0) + (a - m.rel) * (m.rate or 1),
    vol = m.vol or 1, mute = m.mute or 0, rate = m.rate or 1, pitch = m.pitch or 0, tvol = m.tvol or 1,
    fin = fin, fout = fout, clipL = clipL, clipR = clipR, a = a, b = b,
  }
end

function C.window_end(w) return w.pos + w.len end

--------------------------------------------------------------------------------------------------- classification
-- What happened to one member item since we last wrote it?
--   A = actual (now), S = applied (last written by us), N = wanted (from the def and the CURRENT window; nil = not visible)
--   info = { in_folder = function(track_guid) -> bool, window = { pos, len, offs }, def_member = m }
-- Returns { kind = "ok" | "write" | "edit" | "mixed", reason, edit = { geom = {...}, props = {...}, track = guid } }
function C.classify(A, S, N, info)
  if N and C.snap_eq(A, N) then return { kind = "ok" } end
  if S and C.snap_eq(A, S) then return { kind = "write" } end
  if not S then return { kind = "write" } end
  local edit = { props = {} }
  local changed = false
  -- track
  if (A.track or "") ~= (S.track or "") and (not N or (A.track or "") ~= (N.track or "")) then
    if info.in_folder(A.track) then edit.track = A.track; changed = true
    else return { kind = "mixed", reason = "outside_folder" } end
  end
  -- geometry: fine when it matches the wanted piece (window explains it) or the applied one (window moved)
  local gA = { pos = A.pos, len = A.len, soffs = A.soffs }
  local function geq(x) return x and approx(gA.pos, x.pos) and approx(gA.len, x.len) and approx(gA.soffs, x.soffs) end
  if not (geq(N) or geq(S)) then
    local m, w = info.def_member, info.window
    local was_clipped = S.clipL or S.clipR or not (approx(S.len, m.len) and approx(S.soffs, m.soffs))
    if was_clipped then return { kind = "mixed", reason = "clipped_edit" } end
    if A.pos < w.pos - C.EPS or A.pos + A.len > w.pos + w.len + C.EPS then
      return { kind = "mixed", reason = "outside_window" }
    end
    edit.geom = { rel = A.pos - w.pos + w.offs, len = A.len, soffs = A.soffs }
    changed = true
  end
  -- properties
  for _, k in ipairs(C.PROPS) do
    if not approx(A[k], S[k]) and not (N and approx(A[k], N[k])) then edit.props[k] = A[k]; changed = true end
  end
  -- fades, only on edges that are not clipped (clipped edges carry our own short fade)
  local refL, refR = N or S, N or S
  if not refL.clipL and not approx(A.fin, S.fin) and not approx(A.fin, refL.fin) then edit.props.fin = A.fin; changed = true end
  if not refR.clipR and not approx(A.fout, S.fout) and not approx(A.fout, refR.fout) then edit.props.fout = A.fout; changed = true end
  if not changed then return { kind = "write" } end
  return { kind = "edit", edit = edit }
end

-- apply an edit (from classify) to a def member, in place
function C.apply_edit(m, edit)
  if edit.track then m.track = edit.track end
  if edit.geom then m.rel, m.len, m.soffs = edit.geom.rel, edit.geom.len, edit.geom.soffs end
  for k, v in pairs(edit.props or {}) do m[k] = v end
end

--------------------------------------------------------------------------------------------------- cuts
-- A member item was split / partly deleted by the user (razor, S key, ...). REAPER keeps the LEFT piece as the original
-- item (our tags stay on it) and makes new, untagged items for the rest. All pieces keep the anchor.
-- S = applied snapshot of the original, A = its actual state, pieces = untagged candidates on the same track with the same
-- source: { pos, len, soffs, rate }. Returns cut times (sorted, strictly inside S's extent) and the matched pieces.
function C.find_cuts(S, A, pieces)
  if not S or not A then return {}, {} end
  local s0, s1 = S.pos, S.pos + S.len
  if not (approx(A.pos, S.pos) and A.len < S.len - C.EPS) then return {}, {} end
  local anc = C.anchor(S.pos, S.soffs, S.rate)
  local matched, bounds = {}, { A.pos + A.len }
  for _, p in ipairs(pieces) do
    if approx(C.anchor(p.pos, p.soffs, p.rate or S.rate), anc, 1e-4)
       and p.pos >= s0 - C.EPS and p.pos + p.len <= s1 + C.EPS and p.pos >= A.pos + A.len - C.EPS then
      matched[#matched + 1] = p
      bounds[#bounds + 1] = p.pos
      bounds[#bounds + 1] = p.pos + p.len
    end
  end
  if #matched == 0 then return {}, {} end      -- only shortened: a trim, not a cut
  table.sort(bounds)
  local cuts = {}
  for _, t in ipairs(bounds) do
    if t > s0 + C.EPS and t < s1 - C.EPS and (#cuts == 0 or not approx(cuts[#cuts], t)) then cuts[#cuts + 1] = t end
  end
  return cuts, matched
end

-- Untagged alias items that are pieces of a known alias item which was split (same lane, same anchor, inside its old extent).
-- W0 = last known window of the parent, now = its current window. Returns the matching candidates.
function C.split_children(W0, now, cands)
  if not W0 then return {} end
  local anc = C.anchor(W0.pos, W0.offs)
  -- a split keeps the anchor and makes the original shorter; a move keeps the length
  local shrunk = now.len < W0.len - C.EPS and approx(C.anchor(now.pos, now.offs), anc, 1e-4)
  if not shrunk then return {} end
  local out = {}
  for _, c in ipairs(cands) do
    if approx(C.anchor(c.pos, c.offs), anc, 1e-4) and c.pos >= W0.pos - C.EPS
       and c.pos + c.len <= W0.pos + W0.len + C.EPS then out[#out + 1] = c end
  end
  return out
end

--------------------------------------------------------------------------------------------------- defs
function C.copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = C.copy(v) end
  return o
end

function C.member_by_mid(def, mid)
  for i, m in ipairs(def.members) do if m.mid == mid then return m, i end end
end

-- Remove def-local range [a, b) from member mid. The member is kept, shortened or split in two (the right part gets a new mid).
-- Returns the list of mids that now exist for that material.
function C.def_cut(def, mid, a, b)
  local m, i = C.member_by_mid(def, mid)
  if not m then return {} end
  local s, e = m.rel, m.rel + m.len
  if b <= s + C.EPS or a >= e - C.EPS then return { mid } end
  local left  = (a > s + C.EPS) and { s, a } or nil
  local right = (b < e - C.EPS) and { b, e } or nil
  if not left and not right then table.remove(def.members, i); return {} end
  local out = {}
  if left then
    local keep_fout = m.fout
    m.len = left[2] - left[1]; m.fout = 0
    out[#out + 1] = mid
    if right then
      local r = C.copy(m)
      def.next_mid = (def.next_mid or #def.members + 1)
      r.mid = def.next_mid; def.next_mid = def.next_mid + 1
      r.rel, r.len = right[1], right[2] - right[1]
      r.soffs = (m.soffs or 0) + (right[1] - s) * (m.rate or 1)
      r.fin, r.fout = 0, keep_fout
      table.insert(def.members, i + 1, r)
      out[#out + 1] = r.mid
    end
  else
    m.soffs = (m.soffs or 0) + (right[1] - s) * (m.rate or 1)
    m.rel, m.len, m.fin = right[1], right[2] - right[1], 0
    out[#out + 1] = mid
  end
  return out
end

-- recompute def.len as the end of its last member (never shorter than before unless shrink = true)
function C.def_extent(def)
  local e = 0
  for _, m in ipairs(def.members) do e = math.max(e, m.rel + m.len) end
  return e
end

--------------------------------------------------------------------------------------------------- tracks
-- parent index for every track (1-based list of I_FOLDERDEPTH values). parent[i] = index of the folder track or 0.
function C.parents(depths)
  local parent, stack = {}, {}
  for i, d in ipairs(depths) do
    parent[i] = stack[#stack] or 0
    if d > 0 then stack[#stack + 1] = i
    elseif d < 0 then for _ = 1, -d do stack[#stack] = nil end end
  end
  return parent
end

function C.is_desc(parent, i, f)
  local p = parent[i]
  while p and p ~= 0 do
    if p == f then return true end
    p = parent[p]
  end
  return false
end

-- deepest folder that contains all of the given track indices (not the tracks themselves); 0 = none
function C.common_folder(parent, idxs)
  if #idxs == 0 then return 0 end
  local chain = {}
  local p = parent[idxs[1]]
  while p and p ~= 0 do chain[#chain + 1] = p; p = parent[p] end
  for _, f in ipairs(chain) do
    local all = true
    for _, i in ipairs(idxs) do if not C.is_desc(parent, i, f) then all = false; break end end
    if all then return f end
  end
  return 0
end

--------------------------------------------------------------------------------------------------- names / tags
function C.take_name(group_name, defno, main)
  if defno == main then return group_name end
  return group_name .. " #" .. tostring(defno)
end

function C.take_code(name)
  return name and name:match("#(%d+)%s*$")
end

-- "a|b|c" helpers
function C.split_bar(s)
  local out = {}
  if not s or s == "" then return out end
  for p in (s .. "|"):gmatch("([^|]*)|") do out[#out + 1] = p end
  return out
end

function C.list_encode(t)
  local k = {}
  for mid in pairs(t) do k[#k + 1] = tonumber(mid) end
  table.sort(k)
  for i, v in ipairs(k) do k[i] = tostring(v) end
  return table.concat(k, ",")
end

function C.list_decode(s)
  local t = {}
  for v in (s or ""):gmatch("[^,]+") do t[tonumber(v)] = true end
  return t
end

--------------------------------------------------------------------------------------------------- chunks
-- Fresh GUIDs for a copied item chunk. IGUID (item), GUID (takes), FXID (take FX) always get new ones.
-- POOLEDEVTS (pooled MIDI source) is kept when keep_pool is true: linked instances then share MIDI natively.
function C.refresh_guids(chunk, gen, keep_pool)
  local out = {}
  for line in (chunk .. "\n"):gmatch("([^\n]*)\n") do
    local ind, key = line:match("^(%s*)(%u+)%s+{[%x%-]+}%s*$")
    if key == "IGUID" or key == "GUID" or key == "FXID" or (key == "POOLEDEVTS" and not keep_pool) then
      line = ind .. key .. " " .. gen()
    end
    out[#out + 1] = line
  end
  if out[#out] == "" then out[#out] = nil end
  return table.concat(out, "\n")
end

--------------------------------------------------------------------------------------------------- overlaps
-- instances whose windows overlap in time (only meaningful inside one group). list of { a, b } iids.
function C.overlaps(list)
  local s = {}
  for _, x in ipairs(list) do s[#s + 1] = x end
  table.sort(s, function(a, b) return a.pos < b.pos end)
  local out = {}
  for i = 1, #s do
    for j = i + 1, #s do
      if s[j].pos < s[i].pos + s[i].len - C.EPS then out[#out + 1] = { s[i].iid, s[j].iid } else break end
    end
  end
  return out
end

--------------------------------------------------------------------------------------------------- tiny JSON
local function jenc(v, out)
  local t = type(v)
  if t == "nil" then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then v = 0 end
    out[#out + 1] = (math.type and math.type(v) == "integer") and tostring(v) or string.format("%.14g", v)
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
      local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
      return map[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "table" then
    local n = #v
    local is_arr = n > 0 or next(v) == nil
    if is_arr then for k in pairs(v) do if type(k) ~= "number" then is_arr = false; break end end end
    if is_arr and next(v) ~= nil then
      out[#out + 1] = "["
      for i = 1, n do if i > 1 then out[#out + 1] = "," end; jenc(v[i], out) end
      out[#out + 1] = "]"
    elseif next(v) == nil then out[#out + 1] = "{}"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        jenc(k, out); out[#out + 1] = ":"
        local val = v[k]; if val == nil then val = v[tonumber(k)] end
        jenc(val, out)
      end
      out[#out + 1] = "}"
    end
  else error("json: cannot encode " .. t) end
end

function C.json_encode(v) local out = {}; jenc(v, out); return table.concat(out) end

function C.json_decode(s)
  local i = 1
  local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
  local val
  local function str()
    local buf = {}
    i = i + 1
    while true do
      local c = s:sub(i, i)
      if c == "" then error("json: open string") end
      if c == '"' then i = i + 1; break end
      if c == "\\" then
        local e = s:sub(i + 1, i + 1)
        local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f" }
        if e == "u" then buf[#buf + 1] = utf8 and utf8.char(tonumber(s:sub(i + 2, i + 5), 16)) or "?"; i = i + 6
        else buf[#buf + 1] = map[e] or e; i = i + 2 end
      else buf[#buf + 1] = c; i = i + 1 end
    end
    return table.concat(buf)
  end
  function val()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      local o = {}; i = i + 1; ws()
      if s:sub(i, i) == "}" then i = i + 1; return o end
      while true do
        ws(); local k = str(); ws()
        assert(s:sub(i, i) == ":", "json: ':' expected"); i = i + 1
        o[k] = val(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == "}" then return o end
        assert(d == ",", "json: ',' expected")
      end
    elseif c == "[" then
      local a = {}; i = i + 1; ws()
      if s:sub(i, i) == "]" then i = i + 1; return a end
      while true do
        a[#a + 1] = val(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == "]" then return a end
        assert(d == ",", "json: ',' expected")
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
    else
      local n = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
      assert(n and n ~= "", "json: bad value at " .. i)
      i = i + #n
      return tonumber(n)
    end
  end
  local ok, r = pcall(val)
  if not ok then return nil, r end
  return r
end

--------------------------------------------------------------------------------------------------- IdeaPool
-- card     = a pool entry: slots (the tracks it came from), variants (defs), the active variant, loudness settings
-- variant  = a def (members in card-local time), named A, B, C ...
-- placement= an alias item on the IDEAS lane, showing the card's active variant (linked), frozen, or an audition

-- take name of a placement: "Riff · B [3]"  (the [3] is the card id: copies are recognised by it)
function C.card_take_name(name, varname, cid, mode)
  local pre = (mode == "frozen" and "* ") or (mode == "audition" and "> ") or ""
  return string.format("%s%s · %s [%s]", pre, name, varname or "?", tostring(cid))
end

function C.card_code(tname)
  return tname and tname:match("%[(%d+)%]%s*$")
end

function C.variant_letter(n)
  n = tonumber(n) or 1
  local s = ""
  repeat
    local r = (n - 1) % 26
    s = string.char(65 + r) .. s
    n = (n - 1 - r) // 26
  until n <= 0
  return s
end

local function norm_name(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")):lower() end
C.norm_name = norm_name

-- which card does a marker name ask for? prefix "" = the whole name must be the card name (like PrototypeSequence)
-- by_name: lowercased card name -> card id. Returns the card id or nil.
function C.marker_card(mname, prefix, by_name)
  local n = norm_name(mname)
  local p = norm_name(prefix)
  if p ~= "" then
    if n:sub(1, #p) ~= p then return nil end
    n = norm_name(n:sub(#p + 1))
  end
  if n == "" then return nil end
  return by_name[n]
end

----------------------------------------------------------------------------- level (as in GainStageEQ)
-- 50 ms frames of mean power; the level of a variant is the gated average of the frames of all its members summed
-- (members are assumed uncorrelated: powers add). Frames are kept per member in SOURCE time, so trims and moves only
-- re-select frames; nothing has to be measured again unless new material becomes audible.
C.FRAME = 0.05
C.GATE_REL, C.GATE_ABS = 45, -70

local function db10(x) return 10 * math.log(x + 1e-30, 10) end
C.db10 = db10

function C.new_meter(sr, nch)
  return { sr = sr, nch = nch, FL = math.max(1, math.floor(sr * C.FRAME)), acc = 0, cnt = 0, frames = {}, peak = 0 }
end

-- t: interleaved samples (1-based), n sample frames
function C.meter_block(m, t, n)
  local nch, FL = m.nch, m.FL
  local acc, cnt, frames, peak = m.acc, m.cnt, m.frames, m.peak
  for i = 0, n - 1 do
    local s = 0
    for c = 1, nch do
      local x = t[i * nch + c] or 0
      s = s + x * x
      if x < 0 then x = -x end
      if x > peak then peak = x end
    end
    acc = acc + s / nch
    cnt = cnt + 1
    if cnt == FL then frames[#frames + 1] = acc / FL; acc, cnt = 0, 0 end
  end
  m.acc, m.cnt, m.peak = acc, cnt, peak
end

-- -> list of frame levels in dB (0.1 dB resolution, small in JSON)
function C.meter_finish(m)
  if m.cnt > m.FL // 2 then m.frames[#m.frames + 1] = m.acc / m.cnt end
  local out = {}
  for i, p in ipairs(m.frames) do out[i] = math.floor(db10(p) * 10 + 0.5) / 10 end
  return out, 20 * math.log(m.peak + 1e-12, 10)
end

-- power of member m at member-local time t (seconds from its start); nil = not measured there
function C.member_power(m, t)
  local st = m.stats
  if not st or not st.fr then return nil end
  local src = (m.soffs or 0) + t * (m.rate or 1)
  local k = math.floor((src - (st.s0 or 0)) / (C.FRAME * (st.rate or 1))) + 1
  local db = st.fr[k]
  if not db then return nil end
  return 10 ^ (db / 10)
end

-- gated average level of a variant in dB (nil when nothing is measured) and the measured share of its material (0..1)
-- gain(m) -> linear factor applied to member m (item volume, take volume, loudness match ...)
function C.variant_level(def, gain)
  local len = C.def_extent(def)
  local n = math.max(1, math.ceil(len / C.FRAME))
  local frames, have, need = {}, 0, 0
  for i = 1, n do
    local t = (i - 0.5) * C.FRAME
    local p = 0
    for _, m in ipairs(def.members) do
      if (m.mute or 0) == 0 and t >= m.rel and t < m.rel + m.len then
        need = need + 1
        local pw = C.member_power(m, t - m.rel)
        if pw then
          have = have + 1
          local g = (gain and gain(m)) or ((m.vol or 1) * (m.tvol or 1))
          p = p + pw * g * g
        end
      end
    end
    frames[i] = p
  end
  if have == 0 then return nil, 0 end
  local mx = -300
  for _, p in ipairs(frames) do if p > 0 then mx = math.max(mx, db10(p)) end end
  local gate = math.max(C.GATE_ABS, mx - C.GATE_REL)
  local sum, cnt = 0, 0
  for _, p in ipairs(frames) do if p > 0 and db10(p) > gate then sum = sum + p; cnt = cnt + 1 end end
  if cnt == 0 then return nil, have / need end
  return db10(sum / cnt), have / need
end

-- gain (dB) that brings `level` to `ref`, limited
function C.match_gain(ref, level, maxg)
  if not ref or not level then return 0 end
  maxg = maxg or 24
  local g = ref - level
  if g > maxg then g = maxg elseif g < -maxg then g = -maxg end
  return g
end

function C.db_to_lin(db) return 10 ^ ((db or 0) / 20) end
function C.lin_to_db(x) return 20 * math.log(math.max(x or 0, 1e-12), 10) end

----------------------------------------------------------------------------- track slots
-- A card remembers the tracks it came from as slots (in track order). Putting it back "on the selected track" moves
-- slot 1 there and keeps the others at the same distance (in track order). origin_idx: track index per slot (nil =
-- track gone); target: index for the first slot whose track still exists; ntracks: number of tracks; n: number of
-- slots (origin_idx may contain nils). Returns an index per slot (clamped to the project); gone slots use the order.
function C.map_slots(origin_idx, target, ntracks, n)
  n = n or #origin_idx
  local first
  for k = 1, n do if origin_idx[k] then first = origin_idx[k]; break end end
  local out = {}
  for k = 1, n do
    local o = origin_idx[k]
    local want = o and first and (target + (o - first)) or (target + k - 1)
    if want > ntracks then want = ntracks end
    if want < 1 then want = 1 end
    out[k] = want
  end
  return out
end

return C

end
__preload["IPReaper"] = function(...)
-- IPReaper.lua  (copied from AliasTrack ATReaper v0.1.0, then extended)
-- Every reaper.* call of IdeaPool lives here. scan() turns the project into plain tables; the write functions change it.
-- Identity never depends on names: tracks and items are recognised by P_EXT tags (see TAG).

local r = reaper
local C = require("IPCore")

local RA = {}

RA.TAG = {
  lane  = "P_EXT:IP_lane",    -- track: "ideas" = the IDEAS lane (holds every placement)
  pool  = "P_EXT:IP_pool",    -- IDEAS lane: the pool (JSON: cards, variants, counters)
  inst  = "P_EXT:IP_p",       -- placement (alias item): "<cid>|<pid>"
  win   = "P_EXT:IP_w",       -- placement: last window "pos|len|offs"
  has   = "P_EXT:IP_h",       -- placement: mids materialised "1,2,5"
  map   = "P_EXT:IP_map",     -- placement: track GUID per card slot "{..},{..}"
  mode  = "P_EXT:IP_mode",    -- placement: "" (linked) | "frozen" | "m:<isrgn>:<idx>" (audition of a marker)
  var   = "P_EXT:IP_v",       -- placement: variant id it showed last
  mem   = "P_EXT:IP_m",       -- member item: "<cid>|<pid>|<mid>"
  app   = "P_EXT:IP_a",       -- member item: applied snapshot (C.snap_encode)
}

local function tstr(tr, k) local ok, v = r.GetSetMediaTrackInfo_String(tr, k, "", false); return ok and v or "" end
local function istr(it, k) local ok, v = r.GetSetMediaItemInfo_String(it, k, "", false); return ok and v or "" end
function RA.track_tag(tr, k) return tstr(tr, RA.TAG[k]) end
function RA.item_tag(it, k) return istr(it, RA.TAG[k]) end
function RA.set_track_tag(tr, k, v) r.GetSetMediaTrackInfo_String(tr, RA.TAG[k], v or "", true) end
function RA.set_item_tag(it, k, v) r.GetSetMediaItemInfo_String(it, RA.TAG[k], v or "", true) end

function RA.gen_guid() return r.genGuid("") end

---------------------------------------------------------------------------------------------------------- scan
-- W = { tracks = {T...}, parent = {...}, by_guid = {guid -> T}, items = {I...} }
function RA.scan()
  local W = { tracks = {}, by_guid = {}, items = {} }
  local depths = {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local T = {
      ptr = tr, i = i + 1, guid = r.GetTrackGUID(tr), name = tstr(tr, "P_NAME"),
      depth = math.floor(r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") + 0.5),
      lane = tstr(tr, RA.TAG.lane), items = {},
    }
    if T.lane ~= "" then T.pool = tstr(tr, RA.TAG.pool) end
    W.tracks[#W.tracks + 1] = T
    W.by_guid[T.guid] = T
    depths[#depths + 1] = T.depth
    for j = 0, r.CountTrackMediaItems(tr) - 1 do
      local it = r.GetTrackMediaItem(tr, j)
      local I = RA.read_item(it, T)
      T.items[#T.items + 1] = I
      W.items[#W.items + 1] = I
    end
  end
  W.parent = C.parents(depths)
  W.markers = RA.markers()
  W.cursor = r.GetCursorPosition()
  return W
end

function RA.read_item(it, T)
  local gv = r.GetMediaItemInfo_Value
  local I = {
    ptr = it, T = T,
    pos = gv(it, "D_POSITION"), len = gv(it, "D_LENGTH"),
    vol = gv(it, "D_VOL"), mute = gv(it, "B_MUTE"),
    fin = gv(it, "D_FADEINLEN"), fout = gv(it, "D_FADEOUTLEN"),
    sel = gv(it, "B_UISEL") ~= 0,
    tag_i = istr(it, RA.TAG.inst), tag_m = istr(it, RA.TAG.mem),
  }
  if I.tag_i ~= "" then
    I.tag_w = istr(it, RA.TAG.win); I.tag_h = istr(it, RA.TAG.has)
    I.tag_map = istr(it, RA.TAG.map); I.tag_mode = istr(it, RA.TAG.mode); I.tag_v = istr(it, RA.TAG.var)
  end
  if I.tag_m ~= "" then I.tag_a = istr(it, RA.TAG.app) end
  local tk = r.GetActiveTake(it)
  I.soffs, I.rate, I.pitch, I.tvol = 0, 1, 0, 1
  if tk then
    local tv = r.GetMediaItemTakeInfo_Value
    I.take = true
    I.midi = r.TakeIsMIDI(tk) and true or false
    I.soffs, I.rate, I.pitch, I.tvol = tv(tk, "D_STARTOFFS"), tv(tk, "D_PLAYRATE"), tv(tk, "D_PITCH"), tv(tk, "D_VOL")
    local _, nm = r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)
    I.tname = nm or ""
    local src = r.GetMediaItemTake_Source(tk)
    I.file = src and r.GetMediaSourceFileName(src, "") or ""
  end
  return I
end

function RA.snap(I)
  return { pos = I.pos, len = I.len, soffs = I.soffs, vol = I.vol, mute = I.mute, rate = I.rate, pitch = I.pitch,
           tvol = I.tvol, fin = I.fin, fout = I.fout, track = I.T.guid }
end

---------------------------------------------------------------------------------------------------------- undo
-- mode "silent": no undo points for syncs (your own action is the undo step; the result is derived again after undo)
-- mode "steps":  every sync that changes something is its own undo step "AliasTrack: sync"
RA.SYNC_LABEL = "IdeaPool: sync"
local W_open, W_mode, W_changed = false, "silent", false

function RA.begin_writes(mode) W_open, W_mode, W_changed = true, mode or "silent", false end
function RA.touch()
  if W_open and not W_changed then
    W_changed = true
    r.PreventUIRefresh(1)
    if W_mode == "steps" then r.Undo_BeginBlock2(0) end
  end
end
function RA.end_writes()
  if W_open and W_changed then
    if W_mode == "steps" then r.Undo_EndBlock2(0, RA.SYNC_LABEL, -1)
    elseif r.MarkProjectDirty then r.MarkProjectDirty(0) end
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
  end
  local changed = W_changed
  W_open, W_changed = false, false
  return changed
end

-- explicit user commands always get a real undo point
function RA.with_undo(label, fn)
  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  local ok, err = pcall(fn)
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock2(0, label, -1)
  r.UpdateArrange()
  if not ok then error(err, 0) end
end

function RA.redo_label() local s = r.Undo_CanRedo2 and r.Undo_CanRedo2(0); return s end
function RA.change_count() return r.GetProjectStateChangeCount(0) end
function RA.mouse_down()
  if r.JS_Mouse_GetState then return (r.JS_Mouse_GetState(1) or 0) & 1 == 1 end
  return false
end

---------------------------------------------------------------------------------------------------------- tracks
function RA.insert_track(index0, name, color)
  r.InsertTrackAtIndex(index0, true)
  local tr = r.GetTrack(0, index0)
  r.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  if color and color ~= 0 then r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", color | 0x1000000) end
  return tr, r.GetTrackGUID(tr)
end
function RA.delete_track(tr) r.DeleteTrack(tr) end
function RA.set_depth(tr, d) r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", d) end
function RA.track_index0(tr) return math.floor(r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") + 0.5) - 1 end
function RA.track_depth(tr) return math.floor(r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") + 0.5) end

---------------------------------------------------------------------------------------------------------- items
function RA.item_chunk(it) local ok, c = r.GetItemStateChunk(it, "", false); return ok and c or "" end

-- the alias item: an empty MIDI item, so REAPER itself keeps its take start offset (= window offset) through
-- trims, splits and copies. Looping is switched off so extending it does not repeat anything.
function RA.create_alias(lane, pos, len, offs, name, color)
  local it = r.CreateNewMIDIItemInProj(lane, pos, pos + len, false)
  r.SetMediaItemInfo_Value(it, "B_LOOPSRC", 0)
  local tk = r.GetActiveTake(it)
  if tk then
    r.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", offs or 0)
    r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", name or "", true)
  end
  if color and color ~= 0 then r.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", color | 0x1000000) end
  return it
end

function RA.style_alias(it, name, color)
  local tk = r.GetActiveTake(it)
  if tk then
    local _, cur = r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)
    if cur ~= name then r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", name, true) end
  end
  if color and color ~= 0 then
    local want = color | 0x1000000
    if r.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR") ~= want then r.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", want) end
  end
end

function RA.set_window(it, w)
  r.SetMediaItemInfo_Value(it, "D_POSITION", w.pos)
  r.SetMediaItemInfo_Value(it, "D_LENGTH", w.len)
  local tk = r.GetActiveTake(it)
  if tk then r.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", w.offs) end
end

function RA.split(it, t) return r.SplitMediaItem(it, t) end
function RA.delete_item(it) r.DeleteTrackMediaItem(r.GetMediaItem_Track(it), it) end
function RA.move_to_track(it, tr) r.MoveMediaItemToTrack(it, tr) end

-- write a wanted snapshot onto an item; returns what REAPER now reports (the new "applied" snapshot)
function RA.write_member(it, N, track_ptr)
  local sv = r.SetMediaItemInfo_Value
  if track_ptr and r.GetMediaItem_Track(it) ~= track_ptr then r.MoveMediaItemToTrack(it, track_ptr) end
  sv(it, "D_POSITION", N.pos); sv(it, "D_LENGTH", N.len)
  sv(it, "D_VOL", N.vol); sv(it, "B_MUTE", N.mute)
  sv(it, "D_FADEINLEN", N.fin); sv(it, "D_FADEOUTLEN", N.fout)
  local tk = r.GetActiveTake(it)
  if tk then
    local st = r.SetMediaItemTakeInfo_Value
    st(tk, "D_PLAYRATE", N.rate); st(tk, "D_STARTOFFS", N.soffs); st(tk, "D_PITCH", N.pitch); st(tk, "D_VOL", N.tvol)
  end
  local T = { guid = r.GetTrackGUID(r.GetMediaItem_Track(it)) }
  local A = RA.snap(RA.read_item(it, T))
  A.clipL, A.clipR = N.clipL, N.clipR
  return A
end

function RA.create_member(track_ptr, chunk, N, keep_pool)
  local it = r.AddMediaItemToTrack(track_ptr)
  if chunk and chunk ~= "" then r.SetItemStateChunk(it, C.refresh_guids(chunk, RA.gen_guid, keep_pool), false) end
  return it, RA.write_member(it, N)
end

---------------------------------------------------------------------------------------------------------- markers
function RA.markers()
  local out = {}
  local i = 0
  while true do
    local ret, isrgn, pos, rgnend, name, idx = r.EnumProjectMarkers3(0, i)
    if ret == 0 then break end
    out[#out + 1] = { isrgn = isrgn, pos = pos, rgnend = rgnend, name = name or "", idx = idx, key = (isrgn and "r" or "m") .. idx }
    i = i + 1
  end
  return out
end

function RA.add_marker(pos, name) return r.AddProjectMarker2(0, false, pos, 0, name, -1, 0) end

function RA.rename_marker(mk, name)
  r.SetProjectMarker4(0, mk.idx, mk.isrgn, mk.pos, mk.rgnend, name, 0, name == "" and 1 or 0)
end

function RA.delete_marker(mk) r.DeleteProjectMarker(0, mk.idx, mk.isrgn) end

---------------------------------------------------------------------------------------------------------- level
-- 50 ms frame levels of one audio item's visible audio, in dB (see C.new_meter). Returns nil for MIDI / no take.
-- The take accessor's time base differs between REAPER versions (GainStageEQ probes it the same way): we try item
-- time 0 and the item position and keep whichever has signal.
RA.MEASURE_MAX = 120      -- seconds per item at most
function RA.measure(it)
  local tk = r.GetActiveTake(it)
  if not tk or r.TakeIsMIDI(tk) then return nil end
  local src = r.GetMediaItemTake_Source(tk)
  local sr = math.floor((src and r.GetMediaSourceSampleRate(src) or 0) + 0.5)
  if sr <= 0 then sr = 44100 end
  local nch = math.max(1, math.min(2, src and r.GetMediaSourceNumChannels(src) or 2))
  local len = math.min(r.GetMediaItemInfo_Value(it, "D_LENGTH"), RA.MEASURE_MAX)
  local ipos = r.GetMediaItemInfo_Value(it, "D_POSITION")
  local aa = r.CreateTakeAudioAccessor(tk)
  if not aa then return nil end
  local N = 8192
  local buf = r.new_array(N * nch)
  local function peak_at(delta)
    local pk = 0
    for _, f in ipairs({ 0.1, 0.5, 0.9 }) do
      buf.clear()
      r.GetAudioAccessorSamples(aa, sr, nch, delta + len * f, math.min(N, math.floor(sr * 0.2)), buf)
      for _, v in ipairs(buf.table()) do if v < 0 then v = -v end; if v > pk then pk = v end end
    end
    return pk
  end
  local delta = 0
  if peak_at(0) < 1e-6 and peak_at(ipos) > 1e-6 then delta = ipos end
  local m = C.new_meter(sr, nch)
  local total = math.floor(len * sr)
  local done = 0
  while done < total do
    local n = math.min(N, total - done)
    buf.clear()
    r.GetAudioAccessorSamples(aa, sr, nch, delta + done / sr, n, buf)
    C.meter_block(m, buf.table(), n)
    done = done + n
  end
  r.DestroyAudioAccessor(aa)
  local fr = C.meter_finish(m)
  return { s0 = r.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"), rate = r.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE"), fr = fr }
end

---------------------------------------------------------------------------------------------------------- misc
function RA.cursor() return r.GetCursorPosition() end
function RA.set_cursor(pos) r.SetEditCurPos(pos, true, false) end
function RA.play_from(pos) r.SetEditCurPos(pos, true, false); r.OnPlayButton() end
function RA.selected_tracks()
  local out = {}
  for i = 0, r.CountSelectedTracks(0) - 1 do out[#out + 1] = r.GetSelectedTrack(0, i) end
  return out
end

function RA.select_only(items)
  r.SelectAllMediaItems(0, false)
  for _, it in ipairs(items) do r.SetMediaItemSelected(it, true) end
  r.UpdateArrange()
end

return RA

end
__preload["IPApp"] = function(...)
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
  marker_prefix = "",        -- "" = a marker named exactly like a card auditions it (PrototypeSequence rule)
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

---------------------------------------------------------------------------------------------------------- tick
function App:tick()
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
  local M = { W = W, cards = {}, order = {}, stray = {}, release_lanes = {}, free = {}, foreign = {} }
  for _, T in ipairs(W.tracks) do
    if T.lane == "ideas" then
      if M.lane then M.release_lanes[#M.release_lanes + 1] = T else M.lane = T end
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
          }
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
    if I.T.lane == "" then
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
  if N then N.vol = N.vol * (G.factor[P.def] or 1) end
  return N
end

local function syncs(P) return P.mode ~= "frozen" end
local function is_audition(P) return P.mode:sub(1, 2) == "a:" end

---------------------------------------------------------------------------------------------------------- cuts
function App:do_cuts(M)
  local did = false
  for _, cid in ipairs(M.order) do
    local G = M.cards[cid]
    local def = G.card.variants[G.card.active]
    for _, pid in ipairs(G.order) do
      local P = G.inst[pid]
      local times = {}
      if def and syncs(P) and not is_audition(P) then
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
  local it = RA.create_alias(M.lane.ptr, pos, len, 0,
    C.card_take_name(card.name, def and def.name, G.cid, is_audition({ mode = mode or "" }) and "audition" or ""), card.color)
  local pid = new_pid(card)
  local I = RA.read_item(it, M.lane)
  G.inst[pid] = { pid = pid, item = I, members = {}, mixed = {}, W = { pos = pos, len = len, offs = 0 }, has = {},
                  map = full_map(card, map), mode = mode or "", copy = true }
  G.order[#G.order + 1] = pid
  return G.inst[pid]
end

-- markers named like a card -> audition placements that follow them
function App:auditions(M)
  local want = {}                                   -- [marker key] = { cid, mk }
  for _, mk in ipairs(M.W.markers) do
    local cid = C.marker_card(mk.name, self.cfg.marker_prefix, M.by_name)
    if cid then want[mk.key] = { cid = cid, mk = mk } end
  end
  local have = {}
  for _, cid in ipairs(M.order) do
    local G = M.cards[cid]
    for _, pid in ipairs(G.order) do
      local P = G.inst[pid]
      if is_audition(P) then
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
      self:new_alias(M, G, w.mk.pos, math.max(len, 0.01), "a:" .. key)
      self.stats.auditions = (self.stats.auditions or 0) + 1
    end
  end
end

function App:resolve_instances(G, M)
  local card = G.card
  -- 1. split pieces of known placements (same card, same anchor, inside the old extent)
  for _, pid in ipairs({ table.unpack(G.order) }) do
    local K = G.inst[pid]
    if K.known and syncs(K) and not is_audition(K) and not K.dead then
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
              if e.props.vol then e.props.vol = e.props.vol / (G.factor[P.def] or 1) end
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
            m.vol = A.vol / (G.factor[P.def] or 1)
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
              present = present + 1
              has_new[m.mid] = true
              self.stats.created = (self.stats.created or 0) + 1
            end
          end
        end
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
        }
        local cur = { inst = I.tag_i, win = I.tag_w, has = I.tag_h or "", map = I.tag_map or "", mode = I.tag_mode or "", var = I.tag_v or "" }
        for k, v in pairs(want) do if cur[k] ~= v then RA.touch(); RA.set_item_tag(I.ptr, k, v) end end
        local shown = syncs(P) and def or card.variants[P.var_last or ""] or def
        local def_name = shown and shown.name or "?"
        local style = (P.mode == "frozen" and "frozen") or (is_audition(P) and "audition") or ""
        local want_name = C.card_take_name(card.name, def_name, G.cid, style)
        if I.tname ~= want_name or not P.known then RA.touch(); RA.style_alias(I.ptr, want_name, card.color) end
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
  if M.lane then self:auditions(M) end
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
end

---------------------------------------------------------------------------------------------------------- view
function App:make_view(M)
  local v = { cards = {}, lane = M.lane ~= nil, foreign = #M.foreign }
  for _, cid in ipairs(M.order) do
    local G = M.cards[cid]
    local card = G.card
    local c = { cid = cid, name = card.name, color = card.color, active = card.active, match = card.match or false,
                variants = {}, slots = {}, places = {}, auditions = 0, frozen = 0 }
    for _, vid in ipairs(self:variant_ids(card)) do
      local def = card.variants[vid]
      local members = {}
      for _, m in ipairs(def.members) do
        local s = card.slots[m.slot]
        members[#members + 1] = { mid = m.mid, slot = m.slot, track = s and s.name or "?", rel = m.rel, len = m.len,
                                  fin = m.fin or 0, fout = m.fout or 0, vol = m.vol or 1, mute = m.mute or 0,
                                  midi = m.midi, measured = m.stats ~= nil }
      end
      c.variants[#c.variants + 1] = { vid = vid, name = def.name, len = C.def_extent(def), level = G.level[vid],
                                      cover = G.cover[vid] or 0, gain_db = C.lin_to_db(G.factor[vid] or 1),
                                      members = members, active = vid == card.active }
    end
    for k, s in ipairs(card.slots) do
      local T = track_of(M.W, s.guid)
      c.slots[k] = { name = T and T.name or s.name, gone = T == nil }
    end
    for _, pid in ipairs(G.order) do
      local P = G.inst[pid]
      if not P.removed then
        local reasons = {}
        for _, why in pairs(P.mixed) do reasons[#reasons + 1] = why end
        table.sort(reasons)
        local kind = (P.mode == "frozen" and "frozen") or (is_audition(P) and "audition") or "linked"
        if kind == "audition" then c.auditions = c.auditions + 1 elseif kind == "frozen" then c.frozen = c.frozen + 1 end
        local count = P.count
        if not count then count = 0; for _ in pairs(P.members) do count = count + 1 end end
        c.places[#c.places + 1] = { pid = pid, pos = P.W.pos, len = P.W.len, kind = kind, mixed = #reasons,
                                    reasons = reasons, members = count }
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
      if not self:do_cuts(M) then self:reconcile(M); done = M; break end
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

function App:selection()
  local W = RA.scan()
  local sel, n_members = {}, 0
  for _, I in ipairs(W.items) do
    if I.sel and I.T.lane == "" then
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
      if not slot_of[I.T.guid] then slots[#slots + 1] = { guid = I.T.guid, name = I.T.name }; slot_of[I.T.guid] = #slots end
    end
    local members = {}
    for k, I in ipairs(sel) do
      members[k] = { mid = k, slot = slot_of[I.T.guid], rel = I.pos - P0, len = I.len, soffs = I.soffs, rate = I.rate,
                     pitch = I.pitch, tvol = I.tvol, vol = I.vol, mute = I.mute, fin = I.fin, fout = I.fout,
                     file = I.file, midi = I.midi, chunk = RA.item_chunk(I.ptr), stats = stats[k] }
    end
    local base = (name and name:match("%S")) and name:gsub("^%s+", ""):gsub("%s+$", "")
                 or ((sel[1].tname ~= "" and sel[1].tname:gsub("%.%w+$", "")) or ("Idea " .. cid))
    local c = PALETTE[((tonumber(cid) - 1) % #PALETTE) + 1]
    local card = { id = cid, name = self:unique_name(pool, base), color = r.ColorToNative(c[1], c[2], c[3]), active = "1",
                   ref = "1", next_var = 2, next_pid = 1, match = false, slots = slots, map = {}, origin = P0,
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
    local map = {}
    if where == "selected" then
      local target = RA.track_index0(sel_tracks[1]) + 1
      local origin = {}
      for k, s in ipairs(card.slots) do local T = W.by_guid[s.guid]; origin[k] = T and T.i end
      for k, idx in ipairs(C.map_slots(origin, target, #W.tracks, #card.slots)) do map[k] = W.tracks[idx].guid end
      card.map = map                                 -- copies of placements use the last mapping
    end
    if where ~= "selected" then card.map = full_map(card, nil) end
    self:new_alias(M, G, pos, len, "", map)
    local P = G.inst[G.order[#G.order]]
    RA.set_item_tag(P.item.ptr, "inst", cid .. "|" .. P.pid)
    RA.set_item_tag(P.item.ptr, "map", table.concat(P.map, ","))
    RA.set_item_tag(P.item.ptr, "var", card.active)
    return true
  end)
end

-- audition in context: a marker named like the card at the edit cursor (the sync puts an audition placement there)
function App:audition(cid, play)
  local W = RA.scan()
  local c = self:card_view(cid)
  if not c then return end
  RA.with_undo("IdeaPool: audition idea", function()
    RA.add_marker(W.cursor, (self.cfg.marker_prefix ~= "" and (self.cfg.marker_prefix .. " ") or "") .. c.name)
    self:sync(false, "none")
  end)
  if play then RA.play_from(W.cursor) end
end

function App:find(cid, pid)
  local M = self:build(RA.scan())
  local G = M.cards[tostring(cid)]
  return M, G, G and G.inst[tostring(pid)]
end

-- audition -> ordinary linked placement; its marker is renamed so it no longer auditions
function App:commit(cid, pid)
  local M, G, P = self:find(cid, pid)
  if not P or not is_audition(P) then return end
  local key = P.mode:sub(3)
  RA.with_undo("IdeaPool: commit audition", function()
    for _, mk in ipairs(M.W.markers) do
      if mk.key == key then RA.rename_marker(mk, "(placed) " .. mk.name) end
    end
    RA.set_item_tag(P.item.ptr, "mode", "")
    self:sync(false, "none")
  end)
end

function App:freeze(cid, pid, on)
  local M, G, P = self:find(cid, pid)
  if not P or is_audition(P) then return end
  -- unfreezing = the placement shows the card again; what it looked like while frozen is replaced
  -- (use "Save as variant" first to keep it)
  RA.with_undo(on and "IdeaPool: freeze placement" or "IdeaPool: unfreeze placement", function()
    RA.set_item_tag(P.item.ptr, "mode", on and "frozen" or "")
    if not on then RA.set_item_tag(P.item.ptr, "var", "relink") end
    self:sync(false, "none")
  end)
end

-- members become plain items, the placement is removed (auditions: the marker is renamed too)
function App:detach(cid, pid)
  local M, G, P = self:find(cid, pid)
  if not P then return end
  RA.with_undo("IdeaPool: detach placement", function()
    for _, mem in pairs(P.members) do RA.set_item_tag(mem.I.ptr, "mem", ""); RA.set_item_tag(mem.I.ptr, "app", "") end
    if is_audition(P) then
      local key = P.mode:sub(3)
      for _, mk in ipairs(M.W.markers) do if mk.key == key then RA.rename_marker(mk, "(placed) " .. mk.name) end end
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
        pitch = I.pitch, tvol = I.tvol, vol = I.vol / (G.factor[P.def] or 1), mute = I.mute, fin = I.fin, fout = I.fout,
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

-- numeric edit of one member of a variant (from the window): rel, len, fin, fout, vol (linear), mute
function App:set_member(cid, vid, mid, field, value)
  self:edit("edit idea", function(M)
    local G = M.cards[tostring(cid)]
    local def = G and G.card.variants[tostring(vid)]
    local m = def and C.member_by_mid(def, mid)
    if not m then return end
    if field == "rel" then m.rel = math.max(0, value)
    elseif field == "len" then m.len = math.max(0.001, value)
    elseif field == "fin" or field == "fout" then m[field] = math.max(0, math.min(value, m.len))
    elseif field == "vol" then m.vol = math.max(0, value)
    elseif field == "mute" then m.mute = value and 1 or 0 end
  end)
end

function App:rename(cid, name)
  if not name or not name:match("%S") then return end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  self:edit("rename idea", function(M)
    local G = M.cards[tostring(cid)]
    if not G then return end
    local others = {}
    for k, c in pairs(M.pool.cards) do if k ~= G.cid then others[k] = c end end
    G.card.name = self:unique_name({ cards = others }, name)
  end)
end

-- the card leaves the pool; its placements become plain items (auditions are removed)
function App:delete_card(cid)
  self:edit("delete idea", function(M)
    local G = M.cards[tostring(cid)]
    if not G then return end
    for _, pid in ipairs(G.order) do
      local P = G.inst[pid]
      for _, mem in pairs(P.members) do
        if is_audition(P) then RA.delete_item(mem.I.ptr)
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
      if I.tag_i ~= "" then for _, k in ipairs({ "inst", "win", "has", "map", "mode", "var" }) do RA.set_item_tag(I.ptr, k, "") end end
      if I.tag_m ~= "" then RA.set_item_tag(I.ptr, "mem", ""); RA.set_item_tag(I.ptr, "app", "") end
    end
  end)
  self:sync(true)
end

return App

end
__preload["IPUI"] = function(...)
-- IPUI.lua
-- ReaImGui window of IdeaPool. Reads App state, calls App methods.

local r = reaper
local V = require("IPVersion")

local UI = {}

local COL_HEAD = 0xFFCC44FF
local COL_DIM  = 0x999999FF
local COL_WARN, COL_ERR, COL_OK = 0xFFAA33FF, 0xFF5F5FFF, 0x5FE07FFF

-- Accent colour scheme. Hue 262 deg (from #4700C2); saturation, brightness and alpha are those of ImGui's default dark
-- style (its blue is hue 212 deg), so buttons/headers are translucent like the default instead of solid and heavy.
local BG = 0x181A1AFF
local THEME = {
  { "WindowBg", BG }, { "PopupBg", BG }, { "ChildBg", BG },
  { "FrameBg", 0x47297A8A }, { "FrameBgHovered", 0x8542FA66 }, { "FrameBgActive", 0x8542FAAB },
  { "Button", 0x8542FA66 }, { "ButtonHovered", 0x8542FAFF }, { "ButtonActive", 0x650FFAFF },
  { "SliderGrab", 0x793DE0FF }, { "SliderGrabActive", 0x8542FAFF }, { "CheckMark", 0x8542FAFF },
  { "Header", 0x8542FA4F }, { "HeaderHovered", 0x8542FACC }, { "HeaderActive", 0x8542FAFF },
  { "PlotHistogram", 0x8542FAFF }, { "TitleBgActive", 0x47297AFF },
}

-- pushes the theme and returns how many colours were pushed
-- (a colour name missing in an older ReaImGui is skipped instead of raising an error)
local function push_theme(ctx)
  local n = 0
  for _, c in ipairs(THEME) do
    local get = r["ImGui_Col_" .. c[1]]
    if get then r.ImGui_PushStyleColor(ctx, get(), c[2]); n = n + 1 end
  end
  return n
end

local REASON = {
  missing = "deleted", edited = "edited", clipped_edit = "edited at a cut edge", outside_window = "moved outside",
  outside_folder = "moved to another track", track_gone = "track deleted",
}

local function fmt_time(t)
  if r.format_timestr_pos then return r.format_timestr_pos(t, "", -1) end
  return string.format("%.3f", t)
end

local function rgba(native)
  if not native or native == 0 or not r.ColorFromNative then return COL_DIM end
  local R, G, B = r.ColorFromNative(native)
  return (R << 24) | (G << 16) | (B << 8) | 0xFF
end

local function db(x) return 20 * math.log(math.max(x, 1e-12), 10) end

function UI.new(app)
  local ui = {}
  local ctx = r.ImGui_CreateContext("IdeaPool")
  local title = "IdeaPool v" .. V.VERSION .. "###idea_pool_main"
  local state = { name = "", rename = nil, confirm = nil, play = true, buf = {}, sel_cc = -1 }
  ui.state = state

  local function tip(t) if r.ImGui_IsItemHovered(ctx) and r.ImGui_SetTooltip then r.ImGui_SetTooltip(ctx, t) end end
  local function heading(t) r.ImGui_Spacing(ctx); r.ImGui_TextColored(ctx, COL_HEAD, t); r.ImGui_Separator(ctx) end
  local function btn(label, t, disabled)
    if disabled and r.ImGui_BeginDisabled then r.ImGui_BeginDisabled(ctx, true) end
    local clicked = r.ImGui_Button(ctx, label)
    if disabled and r.ImGui_EndDisabled then r.ImGui_EndDisabled(ctx) end
    if t then tip(t) end
    return clicked and not disabled
  end
  local function small(label, t, disabled)
    if disabled and r.ImGui_BeginDisabled then r.ImGui_BeginDisabled(ctx, true) end
    local clicked = r.ImGui_SmallButton(ctx, label)
    if disabled and r.ImGui_EndDisabled then r.ImGui_EndDisabled(ctx) end
    if t then tip(t) end
    return clicked and not disabled
  end
  local function checkbox(label, key, t)
    local ch, v = r.ImGui_Checkbox(ctx, label, app.cfg[key])
    if t then tip(t) end
    if ch then app:set(key, v) end
  end
  -- a number field that commits once, when you leave it
  local function num_field(key, label, value, fmt, commit)
    r.ImGui_SetNextItemWidth(ctx, 80)
    local cur = state.buf[key]
    if cur == nil then cur = value end
    local ch, v = r.ImGui_InputDouble(ctx, label, cur, 0, 0, fmt)
    if ch then state.buf[key] = v end
    if r.ImGui_IsItemDeactivatedAfterEdit(ctx) and state.buf[key] ~= nil then
      local nv = state.buf[key]
      state.buf[key] = nil
      commit(nv)
    end
  end

  ------------------------------------------------------------------------------------------------ sections
  local function draw_top()
    if app.cfg.live then
      r.ImGui_TextColored(ctx, COL_OK, "LIVE")
      r.ImGui_SameLine(ctx)
      r.ImGui_Text(ctx, app.paused and "- paused after your undo (undo again, or edit to continue)" or "- placements follow their ideas")
    else
      r.ImGui_TextColored(ctx, COL_WARN, "FROZEN")
      r.ImGui_SameLine(ctx)
      r.ImGui_Text(ctx, "- nothing is changed until you go live again")
    end
    if btn(app.cfg.live and "Freeze all" or "Go live", "Stop following edits and markers everywhere (placements stay as they are).") then app:set("live", not app.cfg.live) end
    r.ImGui_SameLine(ctx)
    if btn("Sync now", nil, not app.cfg.live) then app:sync(); app.seen = -1 end
    local ls = app.last_sync
    if ls and ls.stats then
      local parts = {}
      for _, k in ipairs({ "created", "updated", "deleted", "adopted", "cuts", "copies", "auditions", "edits" }) do
        if ls.stats[k] and ls.stats[k] > 0 then parts[#parts + 1] = ls.stats[k] .. " " .. k end
      end
      if #parts > 0 then r.ImGui_TextColored(ctx, COL_DIM, "Last sync: " .. table.concat(parts, ", ")) end
    end
    if app.err then r.ImGui_TextColored(ctx, COL_ERR, app.err) end
    if state.err then r.ImGui_TextColored(ctx, COL_ERR, "UI: " .. state.err) end
  end

  local function draw_stash()
    heading("Stash")
    local cc = r.GetProjectStateChangeCount(0)
    if cc ~= state.sel_cc or not state.sel then state.sel_cc = cc; state.sel = app:selection() end
    local info = state.sel
    r.ImGui_SetNextItemWidth(ctx, 200)
    local ch, v = r.ImGui_InputText(ctx, "Name##stash_name", state.name)
    if ch then state.name = v end
    r.ImGui_SameLine(ctx)
    if btn("Stash selected items", "Selected items (any tracks) become a new idea.", info.n == 0) then
      app:stash(state.name); state.name = ""; state.sel = nil
    end
    r.ImGui_Text(ctx, "Afterwards the items:")
    for _, o in ipairs({ { "keep", "stay (copy)" }, { "link", "become a placement" }, { "remove", "are removed" } }) do
      r.ImGui_SameLine(ctx)
      if r.ImGui_RadioButton(ctx, o[2] .. "##stash_" .. o[1], app.cfg.stash_mode == o[1]) then app:set("stash_mode", o[1]) end
    end
    if info.n == 0 then r.ImGui_TextColored(ctx, COL_DIM, "Select items on any tracks to stash them.")
    else r.ImGui_TextColored(ctx, COL_OK, string.format("%d item(s) on %d track(s) selected", info.n, info.tracks)) end
  end

  local function draw_cards()
    local cards = app.view.cards or {}
    heading(string.format("Ideas (%d)", #cards))
    if #cards == 0 then r.ImGui_TextColored(ctx, COL_DIM, "No ideas yet. Select items and press 'Stash selected items'."); return end
    if not r.ImGui_BeginTable(ctx, "cards", 5, (r.ImGui_TableFlags_Borders and r.ImGui_TableFlags_Borders() or 0)) then return end
    for _, h in ipairs({ "Idea", "Variants", "Tracks", "Placed", "" }) do r.ImGui_TableSetupColumn(ctx, h) end
    r.ImGui_TableHeadersRow(ctx)
    for _, c in ipairs(cards) do
      r.ImGui_PushID(ctx, "card" .. c.cid)
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableSetColumnIndex(ctx, 0)
      r.ImGui_TextColored(ctx, rgba(c.color), "■"); r.ImGui_SameLine(ctx)
      r.ImGui_Text(ctx, (app.selected == c.cid and "> " or "") .. c.name)
      r.ImGui_TableSetColumnIndex(ctx, 1)
      local names = {}
      for _, v in ipairs(c.variants) do names[#names + 1] = v.active and ("[" .. v.name .. "]") or v.name end
      r.ImGui_Text(ctx, table.concat(names, " "))
      r.ImGui_TableSetColumnIndex(ctx, 2); r.ImGui_Text(ctx, tostring(#c.slots))
      r.ImGui_TableSetColumnIndex(ctx, 3)
      r.ImGui_Text(ctx, string.format("%d", #c.places - c.auditions) .. (c.auditions > 0 and string.format(" + %d audition", c.auditions) or ""))
      r.ImGui_TableSetColumnIndex(ctx, 4)
      if small("Open", "Show this idea below.") then app.selected = c.cid end
      r.ImGui_PopID(ctx)
    end
    r.ImGui_EndTable(ctx)
  end

  local function draw_variants(c)
    r.ImGui_Text(ctx, "Variants:")
    for _, v in ipairs(c.variants) do
      r.ImGui_SameLine(ctx)
      if btn((v.active and "[" .. v.name .. "]" or v.name) .. "##var" .. v.vid, "Show this variant in every linked placement (A/B).") then
        app:set_active(c.cid, v.vid)
      end
    end
    r.ImGui_SameLine(ctx)
    local act
    for _, v in ipairs(c.variants) do if v.active then act = v end end
    if small("Duplicate", "New variant from the active one (then edit it in a placement).") and act then app:duplicate_variant(c.cid, act.vid) end
    r.ImGui_SameLine(ctx)
    if small("Delete variant", nil, #c.variants <= 1) and act then app:delete_variant(c.cid, act.vid) end
    -- loudness
    local ch, on = r.ImGui_Checkbox(ctx, "Match loudness between variants##match", c.match)
    tip("Every variant is played at the level of the reference variant (gated RMS, as in GainStageEQ),\nso switching A/B compares the sound, not the volume.")
    if ch then app:set_match(c.cid, on) end
    for _, v in ipairs(c.variants) do
      local lvl = v.level and string.format("%.1f dB", v.level) or "not measured"
      if v.level and v.cover < 0.999 then lvl = lvl .. string.format(" (%d%% measured)", math.floor(v.cover * 100)) end
      local g = (c.match and math.abs(v.gain_db) > 0.05) and string.format(", played %+.1f dB", v.gain_db) or ""
      r.ImGui_TextColored(ctx, v.active and COL_OK or COL_DIM, string.format("  %s: %s%s", v.name, lvl, g))
      if c.match then
        r.ImGui_SameLine(ctx)
        if small("Reference##ref" .. v.vid, "Match the others to this one.") then app:set_ref(c.cid, v.vid) end
      end
    end
    return act
  end

  local function draw_members(c, v)
    if not v then return end
    r.ImGui_Text(ctx, string.format("Variant %s: %.3f s, %d item(s). Edits here apply to every linked placement.", v.name, v.len, #v.members))
    if not r.ImGui_BeginTable(ctx, "members", 7, (r.ImGui_TableFlags_Borders and r.ImGui_TableFlags_Borders() or 0)) then return end
    for _, h in ipairs({ "Track", "Start (s)", "Length (s)", "Fade in", "Fade out", "Gain (dB)", "Mute" }) do r.ImGui_TableSetupColumn(ctx, h) end
    r.ImGui_TableHeadersRow(ctx)
    for _, m in ipairs(v.members) do
      local k = c.cid .. ":" .. v.vid .. ":" .. m.mid
      r.ImGui_PushID(ctx, k)
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableSetColumnIndex(ctx, 0)
      r.ImGui_Text(ctx, m.track .. (m.midi and " (MIDI)" or "") .. (m.measured and "" or " *"))
      if not m.measured and not m.midi then tip("Not measured: press Measure on a placement.") end
      r.ImGui_TableSetColumnIndex(ctx, 1); num_field(k .. "rel", "##rel", m.rel, "%.3f", function(x) app:set_member(c.cid, v.vid, m.mid, "rel", x) end)
      r.ImGui_TableSetColumnIndex(ctx, 2); num_field(k .. "len", "##len", m.len, "%.3f", function(x) app:set_member(c.cid, v.vid, m.mid, "len", x) end)
      r.ImGui_TableSetColumnIndex(ctx, 3); num_field(k .. "fin", "##fin", m.fin, "%.3f", function(x) app:set_member(c.cid, v.vid, m.mid, "fin", x) end)
      r.ImGui_TableSetColumnIndex(ctx, 4); num_field(k .. "fout", "##fout", m.fout, "%.3f", function(x) app:set_member(c.cid, v.vid, m.mid, "fout", x) end)
      r.ImGui_TableSetColumnIndex(ctx, 5); num_field(k .. "vol", "##vol", db(m.vol), "%.1f", function(x) app:set_member(c.cid, v.vid, m.mid, "vol", 10 ^ (x / 20)) end)
      r.ImGui_TableSetColumnIndex(ctx, 6)
      local ch, mu = r.ImGui_Checkbox(ctx, "##mute", m.mute ~= 0)
      if ch then app:set_member(c.cid, v.vid, m.mid, "mute", mu) end
      r.ImGui_PopID(ctx)
    end
    r.ImGui_EndTable(ctx)
  end

  local function draw_places(c)
    if #c.places == 0 then r.ImGui_TextColored(ctx, COL_DIM, "Not placed yet."); return end
    if not r.ImGui_BeginTable(ctx, "places", 4, (r.ImGui_TableFlags_Borders and r.ImGui_TableFlags_Borders() or 0)) then return end
    for _, h in ipairs({ "Position", "Kind", "Status", "" }) do r.ImGui_TableSetupColumn(ctx, h) end
    r.ImGui_TableHeadersRow(ctx)
    for _, p in ipairs(c.places) do
      r.ImGui_PushID(ctx, "p" .. c.cid .. "_" .. p.pid)
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableSetColumnIndex(ctx, 0); r.ImGui_Text(ctx, fmt_time(p.pos))
      r.ImGui_TableSetColumnIndex(ctx, 1); r.ImGui_Text(ctx, p.kind)
      r.ImGui_TableSetColumnIndex(ctx, 2)
      if p.mixed > 0 then
        local words = {}
        for _, why in ipairs(p.reasons) do words[#words + 1] = REASON[why] or why end
        r.ImGui_TextColored(ctx, COL_WARN, "MIXED: " .. table.concat(words, ", "))
        tip("Apply = make the idea like this placement. Revert = make this placement like the idea.")
      else
        r.ImGui_TextColored(ctx, p.kind == "frozen" and COL_DIM or COL_OK, p.members .. " item(s)")
      end
      r.ImGui_TableSetColumnIndex(ctx, 3)
      if small("Select", "Select the placement and its items, move the edit cursor there.") then app:select_placement(c.cid, p.pid) end
      if p.kind == "audition" then
        r.ImGui_SameLine(ctx)
        if small("Commit", "Keep it: becomes an ordinary placement, its marker is renamed '(placed) ...'.") then app:commit(c.cid, p.pid) end
      elseif p.kind == "linked" then
        r.ImGui_SameLine(ctx)
        if small("Freeze", "Stop following the idea: this placement keeps its items as they are.") then app:freeze(c.cid, p.pid, true) end
      else
        r.ImGui_SameLine(ctx)
        if small("Unfreeze", "Follow the idea again (the frozen state is replaced).") then app:freeze(c.cid, p.pid, false) end
      end
      r.ImGui_SameLine(ctx)
      if small("Save as variant", "What this placement looks like now becomes a new variant (made active).") then app:save_variant(c.cid, p.pid) end
      r.ImGui_SameLine(ctx)
      if small("Measure", "Measure the level of its items (for loudness matching).") then app:measure(c.cid, p.pid) end
      if p.mixed > 0 then
        r.ImGui_SameLine(ctx)
        if small("Apply") then app:request(c.cid, p.pid, "apply") end
        r.ImGui_SameLine(ctx)
        if small("Revert") then app:request(c.cid, p.pid, "revert") end
      end
      r.ImGui_SameLine(ctx)
      if small("Detach", "Its items become plain items, the placement is removed.") then app:detach(c.cid, p.pid) end
      r.ImGui_PopID(ctx)
    end
    r.ImGui_EndTable(ctx)
  end

  local function draw_detail()
    local c = app.selected and app:card_view(app.selected)
    if not c then return end
    heading("Idea: " .. c.name)
    if state.rename == c.cid then
      r.ImGui_SetNextItemWidth(ctx, 200)
      local ch, v = r.ImGui_InputText(ctx, "##rename", state.rename_buf or c.name)
      if ch then state.rename_buf = v end
      r.ImGui_SameLine(ctx)
      if small("OK") then app:rename(c.cid, state.rename_buf or c.name); state.rename = nil end
      r.ImGui_SameLine(ctx)
      if small("Cancel") then state.rename = nil end
    else
      if small("Rename", "Markers auditioning it must use the new name.") then state.rename = c.cid; state.rename_buf = c.name end
      r.ImGui_SameLine(ctx)
      if state.confirm == c.cid then
        r.ImGui_TextColored(ctx, COL_WARN, "Delete this idea? Its placements become plain items.")
        r.ImGui_SameLine(ctx)
        if small("Yes, delete") then app:delete_card(c.cid); state.confirm = nil end
        r.ImGui_SameLine(ctx)
        if small("Cancel##del") then state.confirm = nil end
      elseif small("Delete idea...") then state.confirm = c.cid end
    end
    local tracks = {}
    for _, s in ipairs(c.slots) do tracks[#tracks + 1] = s.name .. (s.gone and " (deleted)" or "") end
    r.ImGui_TextColored(ctx, COL_DIM, "Tracks: " .. table.concat(tracks, ", "))
    if btn("Place at cursor", "A linked placement at the edit cursor, on the tracks it came from.") then app:place(c.cid, "cursor") end
    r.ImGui_SameLine(ctx)
    if btn("Place on selected track", "At the edit cursor; its first track goes to the selected track, the others follow in order.") then app:place(c.cid, "selected") end
    r.ImGui_SameLine(ctx)
    if btn("Place where it came from") then app:place(c.cid, "origin") end
    if btn("Audition at cursor", "Adds a marker named '" .. c.name .. "' at the edit cursor: the idea plays there until you move or delete the marker, or Commit it.") then
      app:audition(c.cid, state.play)
    end
    r.ImGui_SameLine(ctx)
    local ch, pl = r.ImGui_Checkbox(ctx, "and play##play", state.play)
    if ch then state.play = pl end
    r.ImGui_Spacing(ctx)
    local act = draw_variants(c)
    r.ImGui_Spacing(ctx)
    draw_members(c, act)
    r.ImGui_Spacing(ctx)
    draw_places(c)
  end

  local function draw_settings()
    heading("Settings")
    r.ImGui_Text(ctx, "Undo:")
    r.ImGui_SameLine(ctx)
    if r.ImGui_RadioButton(ctx, "One step per edit##undo_silent", app.cfg.undo_mode == "silent") then app:set("undo_mode", "silent") end
    tip("Syncs add no undo points: Ctrl+Z undoes your own edit and the placements are derived again.")
    r.ImGui_SameLine(ctx)
    if r.ImGui_RadioButton(ctx, "Separate sync steps##undo_steps", app.cfg.undo_mode == "steps") then app:set("undo_mode", "steps") end
    checkbox("Edits of placed items change the idea", "propagate", "Off: the placement shows MIXED until you Apply or Revert.")
    checkbox("Deleting a placement deletes its items", "delete_with_alias")
    checkbox("Keep MIDI pooled between placements", "keep_pool")
    r.ImGui_SetNextItemWidth(ctx, 120)
    local ch, v = r.ImGui_InputText(ctx, "Marker prefix for auditions##prefix", app.cfg.marker_prefix)
    tip("Empty: a marker named exactly like an idea auditions it (as in PrototypeSequence).\nWith a prefix, e.g. 'idea:', only 'idea: Riff' does.")
    if ch then app:set("marker_prefix", v) end
    r.ImGui_SetNextItemWidth(ctx, 90)
    local ch2, v2 = r.ImGui_InputInt(ctx, "ms fade on edges cut by a placement", app.cfg.clipfade_ms)
    if ch2 then app:set("clipfade_ms", math.max(0, math.min(1000, v2))) end
    if state.confirm ~= "detach" then
      if btn("Detach all...", "Remove every IdeaPool tag: tracks and items stay, the pool is forgotten.") then state.confirm = "detach" end
    else
      r.ImGui_TextColored(ctx, COL_WARN, "Forget the pool and remove every IdeaPool tag from this project?")
      r.ImGui_SameLine(ctx)
      if btn("Yes, detach") then app:detach_all(); state.confirm = nil end
      r.ImGui_SameLine(ctx)
      if btn("Cancel##detach") then state.confirm = nil end
    end
  end

  local function draw_ui()
    draw_top()
    draw_stash()
    draw_cards()
    draw_detail()
    draw_settings()
    if app.view.foreign and app.view.foreign > 0 then
      r.ImGui_TextColored(ctx, COL_WARN, app.view.foreign .. " item(s) on the IDEAS track are not placements - ignored.")
    end
    if app.msg then r.ImGui_Spacing(ctx); r.ImGui_TextColored(ctx, COL_DIM, app.msg) end
  end
  ui.draw_ui = draw_ui

  function ui.frame()
    local pushed = push_theme(ctx)
    r.ImGui_SetNextWindowSize(ctx, 1000, 700, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, title, true)
    if visible then
      local ok, e = pcall(draw_ui)
      if not ok then state.err = tostring(e) end
      r.ImGui_End(ctx)
    end
    r.ImGui_PopStyleColor(ctx, pushed)   -- also when the window is collapsed: the colour stack must stay balanced
    return open
  end

  return ui
end

return UI

end

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. package.path

if not r.ImGui_CreateContext then
  r.MB("This script needs the ReaImGui extension.\n\nInstall it via ReaPack (Extensions > ReaPack > Browse packages > 'ReaImGui').", "IdeaPool", 0)
  return
end

local App = require("IPApp")
local UI  = require("IPUI")

local EXT = "IdeaPoolApp"

-- running again while open = close
local hb_age = os.time() - (tonumber(r.GetExtState(EXT, "hb")) or 0)
if r.GetExtState(EXT, "running") == "1" and hb_age < 3 then
  r.SetExtState(EXT, "stop", "1", false)
  return
end
r.SetExtState(EXT, "running", "1", false)
r.SetExtState(EXT, "stop", "0", false)
r.SetExtState(EXT, "hb", tostring(os.time()), false)

local _, _, sec, cmdid = r.get_action_context()
local function set_toggle(on)
  if cmdid and cmdid ~= 0 then r.SetToggleCommandState(sec, cmdid, on and 1 or 0); r.RefreshToolbar2(sec, cmdid) end
end
set_toggle(true)

local app = App.new()
local ui = UI.new(app)

local function shutdown()
  app:save()
  set_toggle(false)
  r.SetExtState(EXT, "running", "0", false)
  r.SetExtState(EXT, "stop", "0", false)
end
r.atexit(shutdown)

local last_hb, last_err = 0, nil
local function loop()
  if r.GetExtState(EXT, "stop") == "1" then shutdown(); return end
  local now = r.time_precise()
  if now - last_hb > 1 then r.SetExtState(EXT, "hb", tostring(os.time()), false); last_hb = now end
  local ok, err = pcall(app.tick, app)
  if not ok and tostring(err) ~= last_err then last_err = tostring(err); app.err = "Error: " .. last_err end
  if ui.frame() then r.defer(loop) else shutdown() end
end

loop()

