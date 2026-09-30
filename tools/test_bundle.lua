-- The shipped single file must work without src/ on the path.
package.path = "./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local Stub = require("imgui_stub")

for k in pairs(package.loaded) do if k:match("^IP") then package.loaded[k] = nil end end
local S = Mock.install()
local st = Stub.install(reaper)
local deferred
reaper.defer = function(f) deferred = f end
local gtr = Mock.track("Guitar", 0)
local g = Mock.item(gtr, 1, 1, "/s/g.wav")

local ok, err = pcall(assert(loadfile("dist/IdeaPool.lua")))
T.ok(ok, "bundle runs: " .. tostring(err))
T.ok(deferred ~= nil, "main loop scheduled")
local src = io.open("dist/IdeaPool.lua"):read("*a")
T.ok(src:find("@version 0.2.0", 1, true) ~= nil, "version stamped"); T.ok(not src:find("@@VERSION@@", 1, true), "no placeholder")
T.ok(src:find("copied from AliasTrack", 1, true) ~= nil, "copied core says where it comes from")

local function frames(n) for _ = 1, n do S.clock = S.clock + 1; local d = deferred; deferred = nil; local ok2, e = pcall(d); T.ok(ok2, "frame: " .. tostring(e)) end end
Mock.select({ g })
st.clicks["Stash selected items"] = true
frames(3)
T.ok(Mock.track_named("IDEAS") ~= nil, "stashed from the bundled UI")
Mock.marker("g", 20)
frames(3)
local found = false
for _, it in ipairs(gtr.items) do if math.abs(it.p.D_POSITION - 20) < 1e-6 then found = true end end
T.ok(found, "the running loop auditions a marker")

reaper.GetExtState = function(sec, key) if key == "running" then return "1" end if key == "hb" then return tostring(os.time()) end return S.ext[sec .. "/" .. key] or "" end
T.ok(pcall(assert(loadfile("dist/IdeaPool.lua"))), "second start runs"); T.eq(S.ext["IdeaPoolApp/stop"], "1", "and asks the first to stop")
T.done("test_bundle")
