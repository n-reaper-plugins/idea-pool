-- @description IdeaPool: stash items as ideas, keep variants, place them as linked copies, audition them at markers
-- @version @@VERSION@@
-- @author _n_plugins
-- @about
--   Select items (any tracks) and stash them as an idea. Ideas keep variants (A, B, ...) with optional loudness matching,
--   are placed back as linked placements on an IDEAS track (edit one, all follow; freeze or detach any), and a marker
--   named like an idea auditions it right there in the song. Everything is stored in the project.
--   Needs ReaImGui (ReaPack > ReaTeam Extensions). Run the action again while the window is open to close it.

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
  pcall(app.shutdown, app)                 -- a running solo audition is cleaned up
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
