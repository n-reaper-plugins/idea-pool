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
  if m.midi then fin, fout = 0, 0 end                 -- fades do not act on MIDI items
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
  local pre = ({ frozen = "* ", marker = "> ", audition = "~ " })[mode] or ""
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

----------------------------------------------------------------------------- v0.2: waveform / piano-roll view
-- Everything the view needs that is not drawing: time <-> pixels, which part of a member the mouse is on, what a drag
-- does to a member, peak columns for a waveform, notes for a piano roll, grid lines.

-- view = { x0, w, t0, t1 }: x0/w in pixels, t0..t1 = the visible idea-local time
function C.t2x(v, t) return v.x0 + (t - v.t0) / (v.t1 - v.t0) * v.w end
function C.x2t(v, x) return v.t0 + (x - v.x0) / v.w * (v.t1 - v.t0) end

-- visible range for a zoom factor (1 = fit) and a scroll position 0..1
function C.view_range(len, zoom, scroll)
  len = math.max(len or 0, 0.1) * 1.05
  zoom = math.max(1, zoom or 1)
  local span = len / zoom
  local t0 = (len - span) * math.max(0, math.min(1, scroll or 0))
  return t0, t0 + span
end

-- a "nice" grid step for about `px_per_s` pixels per second (at least ~60 px between lines)
function C.nice_step(px_per_s)
  local want = 60 / math.max(px_per_s, 1e-6)
  for _, s in ipairs({ 0.01, 0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300 }) do
    if s >= want then return s end
  end
  return 600
end

function C.snap(t, step) if not step or step <= 0 then return t end return math.floor(t / step + 0.5) * step end

-- box = { x0, y0, x1, y1, fin_px, fout_px }: where is (mx, my)? -> "fin" | "fout" | "gain" | "left" | "right" | "move" | nil
C.EDGE_PX, C.HANDLE_PX = 5, 8
function C.hit_zone(box, mx, my)
  if mx < box.x0 - 2 or mx > box.x1 + 2 or my < box.y0 - 2 or my > box.y1 + 2 then return nil end
  local near_top = (not box.midi) and my <= box.y0 + C.HANDLE_PX      -- no fade / gain handles on MIDI items
  if near_top and mx <= box.x0 + math.max(C.HANDLE_PX, box.fin_px or 0) + 2 and mx <= (box.x0 + box.x1) / 2 then return "fin" end
  if near_top and mx >= box.x1 - math.max(C.HANDLE_PX, box.fout_px or 0) - 2 and mx > (box.x0 + box.x1) / 2 then return "fout" end
  if mx <= box.x0 + C.EDGE_PX then return "left" end
  if mx >= box.x1 - C.EDGE_PX then return "right" end
  if near_top then return "gain" end
  return "move"
end

-- what a drag does. m = member (rel, len, soffs, rate, fin, fout, vol, midi), dt = seconds, dy = pixels (down = +),
-- srclen = source length (nil = unknown / MIDI), step = snap step (nil = off). Returns the changed fields only.
C.MIN_LEN = 0.01
function C.drag(m, kind, dt, dy, srclen, step)
  local rate = m.rate or 1
  local rel, len, soffs = m.rel, m.len, m.soffs or 0
  if kind == "move" then
    return { rel = math.max(0, C.snap(rel + dt, step)) }
  elseif kind == "left" then
    local nrel = C.snap(rel + dt, step)
    local d = nrel - rel
    d = math.min(d, len - C.MIN_LEN)                        -- keep some length
    if not m.midi then d = math.max(d, -soffs / rate) end    -- not before the start of the file
    d = math.max(d, -rel)                                    -- not before the idea's start
    local nlen = len - d
    return { rel = rel + d, len = nlen, soffs = soffs + d * rate,
             fin = math.min(m.fin or 0, nlen), fout = math.min(m.fout or 0, nlen) }
  elseif kind == "right" then
    local e = C.snap(rel + len + dt, step)
    local nlen = math.max(C.MIN_LEN, e - rel)
    if srclen and not m.midi then nlen = math.min(nlen, (srclen - soffs) / rate) end
    return { len = nlen, fin = math.min(m.fin or 0, nlen), fout = math.min(m.fout or 0, nlen) }
  elseif kind == "fin" then
    return { fin = math.max(0, math.min((m.fin or 0) + dt, len - (m.fout or 0))) }
  elseif kind == "fout" then
    return { fout = math.max(0, math.min((m.fout or 0) - dt, len - (m.fin or 0))) }
  elseif kind == "gain" then
    local db = C.lin_to_db(m.vol or 1) - (dy or 0) * 0.25          -- 4 px per dB, drag up = louder
    db = math.max(-60, math.min(24, db))
    return { vol = C.db_to_lin(db) }
  end
  return {}
end

-- peak columns for the part of a source a member shows. ov = { rate = peaks per second, mx = {}, mn = {} } in source
-- time; the member shows source time soffs .. soffs + len * playrate. Returns n columns { mx, mn } (nil = no data).
function C.peak_columns(ov, soffs, len, rate, n)
  local out = {}
  if not ov or not ov.mx or n < 1 then return out end
  local s0, s1 = soffs or 0, (soffs or 0) + len * (rate or 1)
  for i = 1, n do
    local a = s0 + (s1 - s0) * (i - 1) / n
    local b = s0 + (s1 - s0) * i / n
    local k0 = math.floor(a * ov.rate) + 1
    local k1 = math.max(k0, math.ceil(b * ov.rate))
    local mx, mn
    for k = k0, k1 do
      local x, y = ov.mx[k], ov.mn[k]
      if x then mx = mx and math.max(mx, x) or x end
      if y then mn = mn and math.min(mn, y) or y end
    end
    out[i] = mx and { mx, mn or -mx } or false
  end
  return out
end

-- notes of a MIDI item chunk (REAPER's text format: HASDATA 1 <ticks per QN> QN, then E/e/X/x <delta> ...).
-- Returns { tpq, notes = { { s = start QN, e = end QN, pitch, vel } } }; notes still on at the end are closed there.
function C.midi_notes(chunk)
  local tpq = 960
  local notes, on, ticks = {}, {}, 0
  local in_src = false
  for line in (chunk or ""):gmatch("[^\n]+") do
    local l = line:match("^%s*(.-)%s*$")
    if l:match("^<SOURCE MIDI") then in_src = true
    elseif in_src then
      local t = l:match("^HASDATA%s+%d+%s+(%d+)")
      if t then tpq = tonumber(t) end
      local kind, d, st, a, b = l:match("^([EeXx])m?%s+(%d+)%s+(%x+)%s*(%x*)%s*(%x*)")
      if kind then
        ticks = ticks + tonumber(d)
        if kind == "E" or kind == "e" then
          local status = tonumber(st, 16) or 0
          local hi, ch = status & 0xF0, status & 0x0F
          local p, v = tonumber(a, 16), tonumber(b, 16)
          if p then
            local key = ch * 128 + p
            if hi == 0x90 and v and v > 0 then
              on[key] = on[key] or {}
              table.insert(on[key], { s = ticks, vel = v })
            elseif hi == 0x80 or (hi == 0x90 and v == 0) then
              local list = on[key]
              if list and #list > 0 then
                local n = table.remove(list, 1)
                notes[#notes + 1] = { s = n.s, e = ticks, pitch = p, vel = n.vel }
              end
            end
          end
        end
      elseif l == ">" then in_src = false end
    end
  end
  for key, list in pairs(on) do
    for _, n in ipairs(list) do notes[#notes + 1] = { s = n.s, e = ticks, pitch = key % 128, vel = n.vel } end
  end
  for _, n in ipairs(notes) do n.s = n.s / tpq; n.e = n.e / tpq end
  table.sort(notes, function(x, y) if x.s ~= y.s then return x.s < y.s end return x.pitch < y.pitch end)
  return { tpq = tpq, notes = notes }
end

-- notes of member m in member-local seconds (MIDI take offset in seconds, constant tempo bpm), clipped to the member,
-- plus the pitch range to draw
function C.member_notes(parsed, m, bpm)
  local spq = 60 / (bpm or 120)
  local out, lo, hi = {}, 127, 0
  for _, n in ipairs(parsed and parsed.notes or {}) do
    local a = n.s * spq - (m.soffs or 0)
    local b = n.e * spq - (m.soffs or 0)
    if b > 0 and a < m.len then
      out[#out + 1] = { a = math.max(0, a), b = math.min(m.len, b), pitch = n.pitch, vel = n.vel }
      lo = math.min(lo, n.pitch); hi = math.max(hi, n.pitch)
    end
  end
  if #out == 0 then lo, hi = 60, 72 end
  if hi - lo < 12 then local c = (hi + lo) / 2; lo, hi = math.floor(c - 6), math.ceil(c + 6) end
  return out, lo, hi
end

----------------------------------------------------------------------------- v0.2.1: sub-lanes
-- A sub-lane is a child track directly under an original track (the "owner"). Folder depth is a delta per track:
-- +1 opens a folder, -n closes n levels. Returns the new depth of the owner and the depth of the new first child.
function C.sublane_insert(owner_depth)
  if owner_depth > 0 then return owner_depth, 0 end           -- already a folder: the lane is its first child
  return 1, owner_depth - 1                                    -- the owner opens a folder; the child closes it and whatever the owner closed
end

-- Removing a track that closes folders (negative depth): the track before it takes over the closing, so the total is kept.
-- Returns the new depth of the previous track.
function C.depth_after_removal(prev_depth, removed_depth)
  if removed_depth < 0 then return prev_depth + removed_depth end
  return prev_depth
end

return C
