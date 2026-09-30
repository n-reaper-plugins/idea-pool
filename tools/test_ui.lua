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
T.ok(has_text("Idea: Hook"), "new idea opened"); T.ok(has("Button:Place at cursor"), "place buttons shown")
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

-- audition button
S.cursor = 50
st.clicks["Audition at cursor"] = true; frame(); frame()
T.eq(#S.markers, 1, "audition adds a marker"); T.eq(S.markers[1].name, "Hook", "named like the idea")
T.ok(has("SmallButton:Commit"), "audition row offers Commit")

-- settings + delete with confirmation
st.clicks["Edits of placed items change the idea"] = true; frame()
T.eq(app.cfg.propagate, false, "setting checkbox")
local rb = reaper.ImGui_RadioButton
reaper.ImGui_RadioButton = function(_, label) return label:find("stash_link", 1, true) ~= nil end
frame()
T.eq(app.cfg.stash_mode, "link", "stash mode radio")
reaper.ImGui_RadioButton = rb
st.clicks["Delete idea..."] = true; frame()
T.eq(#app.view.cards, 1, "first click only asks")
st.clicks["Yes, delete"] = true; frame()
T.eq(#app.view.cards, 0, "confirmed: deleted")

T.done("test_ui")
