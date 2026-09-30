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
