package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local S = Mock.install()
local Stub = require("imgui_stub")
local st = Stub.install(reaper)
local App = require("IPApp")
local UI = require("IPUI")

local gtr = Mock.track("Guitar", 0)
local g = Mock.item(gtr, 10, 2, "/s/riff.wav")
local app = App.new()
local ui = UI.new(app)
local function frame() st.calls, st.texts = {}, {}; return ui.frame() end
local function has(call) for _, c in ipairs(st.calls) do if c == call then return true end end return false end
local function has_text(sub) for _, t in ipairs(st.texts) do if t:find(sub, 1, true) then return true end end return false end

local pushes, pops = 0, 0
reaper.ImGui_PushStyleColor = function() pushes = pushes + 1 end
reaper.ImGui_PopStyleColor = function(_, n) pops = pops + (n or 1) end
T.ok(frame(), "window open"); T.eq(ui.state.err, nil, "draws without error")
T.eq(pushes, 17, "17 theme colours"); T.eq(pops, 17, "balanced when open")
local real_begin = reaper.ImGui_Begin
reaper.ImGui_Begin = function() return false, true end
pushes, pops = 0, 0; frame()
T.eq(pushes, pops, "balanced when collapsed"); T.eq(pushes, 17, "theme pushed when collapsed")
reaper.ImGui_Begin = real_begin

frame()
T.ok(has_text("No ideas yet"), "empty pool hint"); T.ok(has_text("Select items on any tracks"), "selection hint")

-- stash via the button
Mock.select({ g })
frame()
st.input_text = "Hook"; frame()
st.clicks["Stash selected items"] = true; frame()
T.eq(#app.view.cards, 1, "button stashes"); T.eq(app.view.cards[1].name, "Hook", "named from the field")
frame()
T.ok(has_text("Idea: Hook"), "new idea opened"); T.ok(has("Selectable:Hook##sel"), "listed in the middle pane"); T.ok(has("Button:Place at cursor"), "place buttons shown")
T.ok(has_text("A: -6.0 dB"), "variant level shown")

-- place, then the placement row
S.cursor = 30
st.clicks["Place at cursor"] = true; frame(); frame()
T.ok(has("SmallButton:Freeze"), "placement row with Freeze"); T.ok(has_text("1 item(s)"), "item count")
st.clicks["Freeze"] = true; frame(); frame()
T.ok(has("SmallButton:Unfreeze"), "frozen row offers Unfreeze")
st.clicks["Unfreeze"] = true; frame()

-- variants
st.clicks["Duplicate"] = true; frame(); frame()
T.eq(#app.view.cards[1].variants, 2, "Duplicate adds variant B")
T.ok(has("Button:[B]##var2"), "active variant bracketed")
st.clicks["A"] = true; frame(); frame()
T.eq(app.view.cards[1].active, "1", "variant button switches A/B")
st.clicks["Match loudness between variants##match"] = true; frame(); frame()
T.ok(app.view.cards[1].match, "match checkbox")
T.ok(has("SmallButton:Reference##ref1"), "reference buttons while matching")

-- numeric edit commits when the field is left
reaper.ImGui_InputDouble = function(_, label, v) if label == "##fin" then return true, 0.2 end return false, v end
st.deact = false
local deact = reaper.ImGui_IsItemDeactivatedAfterEdit
local fired = false
reaper.ImGui_IsItemDeactivatedAfterEdit = function() if not fired then fired = true; return false end return true end
frame()
reaper.ImGui_InputDouble = function(_, _, v) return false, v end
reaper.ImGui_IsItemDeactivatedAfterEdit = function() return false end
local placed
for _, it in ipairs(gtr.items) do if math.abs(it.p.D_POSITION - 30) < 1e-6 then placed = it end end
T.ok(placed and math.abs(placed.p.D_FADEINLEN - 0.2) < 1e-6, "fade typed in the window reaches the placement")

-- three panes: every BeginChild has its EndChild, also when a pane is clipped
local begins, ends = 0, 0
reaper.ImGui_BeginChild = function() begins = begins + 1; return true end
reaper.ImGui_EndChild = function() ends = ends + 1 end
frame(); T.eq(begins, 3, "three panes"); T.eq(ends, 3, "and every one is closed")
begins, ends = 0, 0
reaper.ImGui_BeginChild = function() begins = begins + 1; return false end
frame(); T.eq(begins, ends, "balanced when the panes are clipped")
reaper.ImGui_BeginChild, reaper.ImGui_EndChild = nil, nil

-- Play on its own, from the list
S.cursor = 50
st.clicks["Play"] = true; frame(); frame()
T.ok(app.aud ~= nil, "Play in the list starts a solo audition")
T.ok(S.playing, "and playback")
frame()
T.ok(has_text("PLAYING: Chords") or has_text("PLAYING: Hook"), "the status line says what is playing")
T.ok(has("SmallButton:Stop##aud"), "the list row offers Stop")
st.clicks["Stop"] = true; frame(); frame()
T.ok(app.aud == nil, "Stop removes the audition")
T.eq(#S.markers, 0, "no marker is involved")

-- a marker placement, then Rename in the list renames the marker too
local placed_before = #app.view.cards[1].places
Mock.marker("Hook", 70); app:sync(); frame()
T.eq(#app.view.cards[1].places, placed_before + 1, "the marker placed the idea")
st.clicks["Rename"] = true; frame()
T.eq(ui.state.rename, app.view.cards[1].cid, "Rename opens an input in the list")
ui.state.rename_buf = "Hook v2"; frame()
st.clicks["OK"] = true; frame(); frame()
T.eq(app.view.cards[1].name, "Hook v2", "renamed in the list")
T.eq(S.markers[1].name, "Hook v2", "the marker followed the new name")
T.eq(#app.view.cards[1].places, placed_before + 1, "and still places the idea")

-- v0.2: the idea view -------------------------------------------------------------------------------
local draws = { line = 0, rect = 0, text = {} }
reaper.ImGui_GetCursorScreenPos = function() return 0, 0 end
reaper.ImGui_GetWindowDrawList = function() return "dl" end
reaper.ImGui_DrawList_AddLine = function() draws.line = draws.line + 1 end
reaper.ImGui_DrawList_AddRectFilled = function() draws.rect = draws.rect + 1 end
reaper.ImGui_DrawList_AddRect = function() end
reaper.ImGui_DrawList_AddText = function(_, _, _, _, t) draws.text[#draws.text + 1] = t end
local mouse = { x = -1, y = -1, activated = false, active = false, deactivated = false }
reaper.ImGui_GetMousePos = function() return mouse.x, mouse.y end
reaper.ImGui_IsItemActivated = function() return mouse.activated end
reaper.ImGui_IsItemActive = function() return mouse.active end
reaper.ImGui_IsItemDeactivated = function() return mouse.deactivated end
local function vframe() draws = { line = 0, rect = 0, text = {} }; return frame() end
-- press at (x, y), move to (x2, y2), release: three frames like ImGui reports them
local function drag(x, y, x2, y2)
  mouse.x, mouse.y, mouse.activated, mouse.active, mouse.deactivated = x, y, true, true, false; vframe()
  mouse.x, mouse.y, mouse.activated = x2, y2, false; vframe()
  mouse.active, mouse.deactivated = false, true; vframe()
  mouse.deactivated = false; mouse.x, mouse.y = -1, -1; vframe()
end
local function item_at(track, pos)
  for _, it in ipairs(track.items) do if math.abs(it.p.D_POSITION - pos) < 1e-6 then return it end end
end

vframe()
T.eq(ui.state.err, nil, "view draws without error")
T.ok(#ui.last_boxes == 1, "one item box for the one-item idea")
local b = ui.last_boxes[1]
T.eq(b.x0, 96, "box starts after the track-name gutter"); T.eq(b.x1, 576, "2 s at 240 px/s")
local has_draw = function(t) for _, x in ipairs(draws.text) do if x == t then return true end end return false end
T.ok(has_draw("Guitar"), "row labelled with its track"); T.ok(has_draw("reading peaks...") or draws.line > 0, "waveform or a waiting note")
app:work_peaks(1); vframe()
T.ok(draws.line > 400, "waveform drawn from the peaks: " .. draws.line .. " lines")

local undo_before = #S.undo
drag(300, 50, 360, 50)                                        -- body: +60 px = +0.25 s
T.ok(item_at(gtr, 30.25) ~= nil, "dragging the body moves the item in the placement")
T.eq(#S.undo, undo_before + 1, "one undo step for the drag")
T.eq(ui.state.sel_mid, 1, "the dragged item is selected")
drag(300, 23, 300, -1)                                        -- top edge: 24 px up = +6 dB
T.ok(math.abs(20 * math.log(item_at(gtr, 30.25).p.D_VOL, 10) - 6) < 0.01, "dragging the top edge changes the gain (+6 dB)")
local vw = ui.last_view                                       -- the view refitted to the longer idea
local rx = ui.last_boxes[1].x1
drag(rx - 2, 50, rx - 62, 50)                                 -- right edge: 60 px to the left
local want = 2 - 60 * (vw.t1 - vw.t0) / vw.w
T.ok(math.abs(item_at(gtr, 30.25).p.D_LENGTH - want) < 1e-6, "dragging the right edge trims (" .. want .. " s)")
local n_undo = #S.undo
drag(300, 50, 301, 50)                                        -- a click (1 px) only selects
T.eq(#S.undo, n_undo, "a click without a drag changes nothing")

-- snap: moves land on 1/16 notes (120 BPM -> 0.125 s)
ui.state.snap = true
drag(300, 50, 330, 50)                                        -- +0.125 s exactly on the grid from 0.25
T.ok(item_at(gtr, 30.375) ~= nil, "snapped move")
ui.state.snap = false

-- piano roll for a MIDI idea
local keys = Mock.track("Keys", 0)
local mi = Mock.item(keys, 5, 2, nil, { midi = true, name = "chords", events = { "E 0 90 3c 64", "E 480 80 3c 00", "E 0 90 43 64", "E 480 80 43 00" } })
Mock.select({ mi }); app:stash("Chords"); vframe()
T.ok(ui.last_roll == nil, "no piano roll until a MIDI item is selected")
drag(300, 50, 300, 50)
T.ok(ui.last_roll and #ui.last_roll == 2, "clicking the MIDI item shows its notes in the piano roll")
T.ok(has_draw("C4"), "octaves labelled")
T.ok(draws.rect > 10, "notes drawn")

-- settings + delete with confirmation
st.clicks["Edits of placed items change the idea"] = true; frame()
T.eq(app.cfg.propagate, false, "setting checkbox")
local rb = reaper.ImGui_RadioButton
reaper.ImGui_RadioButton = function(_, label) return label:find("stash_link", 1, true) ~= nil end
frame()
T.eq(app.cfg.stash_mode, "link", "stash mode radio")
reaper.ImGui_RadioButton = rb
local n_cards = #app.view.cards
st.clicks["Delete idea..."] = true; frame()
T.eq(#app.view.cards, n_cards, "first click only asks")
st.clicks["Yes, delete"] = true; frame()
T.eq(#app.view.cards, n_cards - 1, "confirmed: deleted")

T.done("test_ui")
