-- IPUI.lua
-- ReaImGui window of IdeaPool. Reads App state, calls App methods.

local r = reaper
local V = require("IPVersion")
local C = require("IPCore")

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

local function num(x, d) return type(x) == "number" and x or d end
local function with_alpha(c, a) return (c & 0xFFFFFF00) | a end
local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local function note_name(p) return NOTE_NAMES[p % 12 + 1] .. (p // 12 - 1) end

local ROW_H, RULER_H, GUTTER, ROLL_H = 56, 18, 96, 170
local COL_CANVAS, COL_ROW, COL_GRID, COL_TEXT = 0x101212FF, 0x1E2121FF, 0x2C3030FF, 0xB8B8B8FF
local COL_SEL, COL_FADE, COL_PLAY, COL_WAVE = 0xFFFFFFFF, 0xFFCC44FF, 0x5FE07FFF, 0xE8E0FFFF

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
      r.ImGui_Text(ctx, (state.sel_mid == m.mid and "> " or "") .. m.track .. (m.midi and " (MIDI)" or "") .. (m.measured and "" or " *"))
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


  ------------------------------------------------------------------------------------------------ v0.2: idea view
  -- the active variant drawn like a tiny arrange view: one row per track, a waveform or notes per item.
  -- Drag: body = move, edges = trim (left edge also moves the file offset, like REAPER), top corners = fades,
  -- top edge = gain. One undo step per drag, applied to every linked placement.
  state.zoom, state.scroll, state.snap = 1, 0, false

  local function member_preview(m)
    local d = state.drag
    if not (d and d.mid == m.mid and d.fields) then return m end
    return setmetatable(d.fields, { __index = m })
  end

  local function draw_view(c, v)
    if state.view_cid ~= c.cid then                  -- another idea: selection, drag and zoom start fresh
      state.view_cid, state.sel_mid, state.drag, state.zoom, state.scroll = c.cid, nil, nil, 1, 0
    end
    local dl = r.ImGui_GetWindowDrawList(ctx)
    -- toolbar
    if small("-##zoom_out", "Zoom out") then state.zoom = math.max(1, state.zoom / 1.5) end
    r.ImGui_SameLine(ctx)
    if small("+##zoom_in", "Zoom in") then state.zoom = math.min(64, state.zoom * 1.5) end
    r.ImGui_SameLine(ctx)
    if small("Fit##zoom_fit") then state.zoom, state.scroll = 1, 0 end
    if state.zoom > 1 then
      r.ImGui_SameLine(ctx)
      r.ImGui_SetNextItemWidth(ctx, 160)
      local ch, sv = r.ImGui_SliderDouble(ctx, "##scroll", state.scroll, 0, 1, "scroll")
      if ch then state.scroll = sv end
    end
    r.ImGui_SameLine(ctx)
    local ch, sn = r.ImGui_Checkbox(ctx, "Snap to 1/16##snap", state.snap)
    if ch then state.snap = sn end
    tip(string.format("Grid of 1/16 notes at %.1f BPM (the tempo where the idea was stashed).", c.bpm))

    local aw = num(r.ImGui_GetContentRegionAvail(ctx), 600)
    local w = math.max(240, aw)
    local nrows = math.max(1, #c.slots)
    local h = RULER_H + nrows * ROW_H
    local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
    x0, y0 = num(x0, 0), num(y0, 0)
    r.ImGui_InvisibleButton(ctx, "##ideaview", w, h)
    local hovered = r.ImGui_IsItemHovered(ctx)
    local activated = r.ImGui_IsItemActivated(ctx)
    local active = r.ImGui_IsItemActive(ctx)
    local deactivated = r.ImGui_IsItemDeactivated(ctx)
    local mx, my = r.ImGui_GetMousePos(ctx)
    mx, my = num(mx, -1e9), num(my, -1e9)

    local t0, t1 = C.view_range(v.len, state.zoom, state.scroll)
    local vw = { x0 = x0 + GUTTER, w = w - GUTTER, t0 = t0, t1 = t1 }
    local pps = vw.w / (t1 - t0)
    local step = state.snap and (60 / c.bpm / 4) or nil

    -- boxes (with the drag preview applied)
    local boxes = {}
    for _, m0 in ipairs(v.members) do
      local m = member_preview(m0)
      local row = math.max(1, math.min(nrows, m.slot or 1))
      local by0 = y0 + RULER_H + (row - 1) * ROW_H + 3
      local b = { m = m, m0 = m0, x0 = C.t2x(vw, m.rel), x1 = C.t2x(vw, m.rel + m.len), y0 = by0, y1 = by0 + ROW_H - 6,
                  fin_px = (m.fin or 0) * pps, fout_px = (m.fout or 0) * pps }
      boxes[#boxes + 1] = b
    end

    -- mouse
    local function hit()
      for i = #boxes, 1, -1 do
        local z = C.hit_zone(boxes[i], mx, my)
        if z then return boxes[i], z end
      end
    end
    if activated then
      local b, z = hit()
      if b then
        state.sel_mid = b.m0.mid
        state.drag = { mid = b.m0.mid, kind = z, mx0 = mx, my0 = my }
      else state.sel_mid = nil; state.drag = nil end
    end
    if state.drag and active then
      local d = state.drag
      local m0
      for _, m in ipairs(v.members) do if m.mid == d.mid then m0 = m end end
      if m0 then
        local ov = (not m0.midi) and app:peaks(m0.file) or nil
        d.moved = d.moved or math.abs(mx - d.mx0) > 2 or math.abs(my - d.my0) > 2
        d.fields = d.moved and C.drag(m0, d.kind, (mx - d.mx0) / pps, my - d.my0, ov and ov.len or nil, step) or nil
      end
    end
    if deactivated and state.drag then
      local d = state.drag
      state.drag = nil
      if d.moved and d.fields and next(d.fields) then
        app:set_member_fields(c.cid, v.vid, d.mid, d.fields, "drag in idea view")
      end
    end
    if hovered and not active and r.ImGui_SetMouseCursor then
      local _, z = hit()
      if (z == "left" or z == "right") and r.ImGui_MouseCursor_ResizeEW then r.ImGui_SetMouseCursor(ctx, r.ImGui_MouseCursor_ResizeEW())
      elseif z == "gain" and r.ImGui_MouseCursor_ResizeNS then r.ImGui_SetMouseCursor(ctx, r.ImGui_MouseCursor_ResizeNS())
      elseif z and r.ImGui_MouseCursor_Hand then r.ImGui_SetMouseCursor(ctx, r.ImGui_MouseCursor_Hand()) end
    end

    -- background, rows, grid
    r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, COL_CANVAS)
    for k = 1, nrows do
      local ry = y0 + RULER_H + (k - 1) * ROW_H
      r.ImGui_DrawList_AddRectFilled(dl, x0, ry + 1, x0 + w, ry + ROW_H - 1, COL_ROW)
      local s = c.slots[k]
      r.ImGui_DrawList_AddText(dl, x0 + 4, ry + 4, s and s.gone and COL_ERR or COL_TEXT, s and s.name or "?")
    end
    local gs = C.nice_step(pps)
    local t = math.ceil(t0 / gs) * gs
    while t <= t1 do
      local x = C.t2x(vw, t)
      r.ImGui_DrawList_AddLine(dl, x, y0 + RULER_H - 4, x, y0 + h, COL_GRID)
      r.ImGui_DrawList_AddText(dl, x + 2, y0, COL_DIM, string.format(gs < 1 and "%.2f" or "%.0f s", t))
      t = t + gs
    end

    -- items
    local base = rgba(c.color)
    for _, b in ipairs(boxes) do
      local m = b.m
      local cx0, cx1 = math.max(b.x0, vw.x0), math.min(b.x1, vw.x0 + vw.w)
      if cx1 > cx0 then
        local muted = (m.mute or 0) ~= 0
        r.ImGui_DrawList_AddRectFilled(dl, cx0, b.y0, cx1, b.y1, with_alpha(base, muted and 0x28 or 0x55))
        local mid_y, half = (b.y0 + b.y1) / 2, (b.y1 - b.y0) / 2 - 2
        if m.midi then
          local notes, lo, hi = C.member_notes(m.notes, m, c.bpm)
          local nh = math.max(1, (b.y1 - b.y0 - 4) / (hi - lo + 1))
          for _, n in ipairs(notes) do
            local nx0, nx1 = C.t2x(vw, m.rel + n.a), C.t2x(vw, m.rel + n.b)
            local ny = b.y1 - 2 - (n.pitch - lo + 1) * nh
            if nx1 > cx0 and nx0 < cx1 then
              r.ImGui_DrawList_AddRectFilled(dl, math.max(nx0, cx0), ny, math.min(math.max(nx1, nx0 + 1), cx1), ny + math.max(1, nh - 1),
                with_alpha(COL_WAVE, muted and 0x50 or 0xD0))
            end
          end
        else
          local ov = app:peaks(m.file)
          if ov == nil then
            r.ImGui_DrawList_AddText(dl, cx0 + 4, mid_y - 7, COL_DIM, "reading peaks...")
          elseif ov then
            local ncol = math.max(1, math.min(1200, math.floor(b.x1 - b.x0)))
            local cols = C.peak_columns(ov, m.soffs, m.len, m.rate, ncol)
            local g = math.min(4, m.vol or 1)
            for i, col in ipairs(cols) do
              local x = b.x0 + (i - 0.5) * (b.x1 - b.x0) / ncol
              if col and x >= cx0 and x <= cx1 then
                local tl = (i - 0.5) / ncol * m.len                    -- fade envelope on the waveform
                local f = 1
                if (m.fin or 0) > 0 and tl < m.fin then f = tl / m.fin end
                if (m.fout or 0) > 0 and tl > m.len - m.fout then f = math.min(f, (m.len - tl) / m.fout) end
                local a, z = math.min(1, col[1] * g * f), math.max(-1, col[2] * g * f)
                r.ImGui_DrawList_AddLine(dl, x, mid_y - a * half, x, mid_y - z * half, with_alpha(COL_WAVE, muted and 0x50 or 0xC0))
              end
            end
          else
            r.ImGui_DrawList_AddText(dl, cx0 + 4, mid_y - 7, COL_DIM, "no peaks")
          end
        end
        -- fades and handles
        if (m.fin or 0) > 0 then r.ImGui_DrawList_AddLine(dl, b.x0, b.y1, b.x0 + b.fin_px, b.y0, COL_FADE, 1.5) end
        if (m.fout or 0) > 0 then r.ImGui_DrawList_AddLine(dl, b.x1 - b.fout_px, b.y0, b.x1, b.y1, COL_FADE, 1.5) end
        r.ImGui_DrawList_AddRectFilled(dl, b.x0 + b.fin_px - 3, b.y0, b.x0 + b.fin_px + 3, b.y0 + 6, COL_FADE)
        r.ImGui_DrawList_AddRectFilled(dl, b.x1 - b.fout_px - 3, b.y0, b.x1 - b.fout_px + 3, b.y0 + 6, COL_FADE)
        local sel = state.sel_mid == b.m0.mid
        r.ImGui_DrawList_AddRect(dl, cx0, b.y0, cx1, b.y1, sel and COL_SEL or with_alpha(base, 0xFF), 0, 0, sel and 2 or 1)
        local label = string.format("%+.1f dB", db(m.vol or 1))
        r.ImGui_DrawList_AddText(dl, cx0 + 3, b.y1 - 14, COL_TEXT, label)
      end
    end

    -- playhead (the first placement of this idea under the play position)
    local ph = app:playhead(c)
    if ph and ph >= t0 and ph <= t1 then
      local x = C.t2x(vw, ph)
      r.ImGui_DrawList_AddLine(dl, x, y0, x, y0 + h, COL_PLAY, 1.5)
    end

    -- readout
    if hovered or state.drag then
      local b
      if state.drag then for _, x in ipairs(boxes) do if x.m0.mid == state.drag.mid then b = x end end
      else b = hit() end
      if b and r.ImGui_SetTooltip then
        local m = b.m
        r.ImGui_SetTooltip(ctx, string.format("%s\nstart %.3f s   length %.3f s\nfade in %.3f   fade out %.3f   gain %+.1f dB",
          b.m0.track, m.rel, m.len, m.fin or 0, m.fout or 0, db(m.vol or 1)))
      end
    end
    ui.last_boxes, ui.last_view = boxes, vw           -- for the tests
  end

  -- larger read-only piano roll of the selected MIDI item
  local function draw_roll(c, v)
    local m
    for _, x in ipairs(v.members) do if x.mid == state.sel_mid and x.midi then m = x end end
    if not m then return end
    local dl = r.ImGui_GetWindowDrawList(ctx)
    r.ImGui_TextColored(ctx, COL_DIM, "Piano roll: " .. m.track .. " (read-only: edit notes in a placement; pooled placements share them, Save as variant keeps them in the idea)")
    local w = math.max(240, num(r.ImGui_GetContentRegionAvail(ctx), 600))
    local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
    x0, y0 = num(x0, 0), num(y0, 0)
    r.ImGui_Dummy(ctx, w, ROLL_H)
    local notes, lo, hi = C.member_notes(m.notes, m, c.bpm)
    lo, hi = math.max(0, lo - 2), math.min(127, hi + 2)
    local vw = { x0 = x0 + 36, w = w - 36, t0 = 0, t1 = math.max(m.len, 0.01) }
    local nh = ROLL_H / (hi - lo + 1)
    r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + ROLL_H, COL_CANVAS)
    for p = lo, hi do
      local y = y0 + ROLL_H - (p - lo + 1) * nh
      local black = ({ [1] = true, [3] = true, [6] = true, [8] = true, [10] = true })[p % 12]
      if black then r.ImGui_DrawList_AddRectFilled(dl, vw.x0, y, x0 + w, y + nh, COL_ROW) end
      if p % 12 == 0 then
        r.ImGui_DrawList_AddLine(dl, vw.x0, y + nh, x0 + w, y + nh, COL_GRID)
        r.ImGui_DrawList_AddText(dl, x0 + 2, y + nh - 13, COL_TEXT, note_name(p))
      end
    end
    local base = rgba(c.color)
    for _, n in ipairs(notes) do
      local y = y0 + ROLL_H - (n.pitch - lo + 1) * nh
      r.ImGui_DrawList_AddRectFilled(dl, C.t2x(vw, n.a), y + 1, math.max(C.t2x(vw, n.b), C.t2x(vw, n.a) + 2), y + nh - 1,
        with_alpha(base, 0x60 + math.floor((n.vel or 100) / 127 * 0x9F)))
    end
    ui.last_roll = notes
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
    if act then draw_view(c, act); draw_roll(c, act) end
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
    r.ImGui_SetNextWindowSize(ctx, 1000, 820, r.ImGui_Cond_FirstUseEver())
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
