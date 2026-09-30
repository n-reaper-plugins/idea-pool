-- spike_1_level.lua - run inside REAPER with one audio item selected. Measures it the way IdeaPool does
-- (50 ms gated RMS frames through a take audio accessor, trying item time and project time) and prints the result.
-- Changes nothing in the project.
local r = reaper
local it = r.GetSelectedMediaItem(0, 0)
if not it then r.MB("Select one audio item first.", "IdeaPool level spike", 0) return end
local tk = r.GetActiveTake(it)
if not tk or r.TakeIsMIDI(tk) then r.MB("Select an AUDIO item.", "IdeaPool level spike", 0) return end
local src = r.GetMediaItemTake_Source(tk)
local sr = math.floor(r.GetMediaSourceSampleRate(src) + 0.5)
local nch = math.max(1, math.min(2, r.GetMediaSourceNumChannels(src)))
local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")
local ipos = r.GetMediaItemInfo_Value(it, "D_POSITION")
local aa = r.CreateTakeAudioAccessor(tk)
local N = 8192
local buf = r.new_array(N * nch)
local function scan(delta)
  local frames, acc, cnt, FL, peak = {}, 0, 0, math.floor(sr * 0.05), 0
  local total, done = math.floor(len * sr), 0
  while done < total do
    local n = math.min(N, total - done)
    buf.clear()
    r.GetAudioAccessorSamples(aa, sr, nch, delta + done / sr, n, buf)
    local t = buf.table()
    for i = 0, n - 1 do
      local s = 0
      for c = 1, nch do local x = t[i * nch + c] or 0; s = s + x * x; if math.abs(x) > peak then peak = math.abs(x) end end
      acc = acc + s / nch; cnt = cnt + 1
      if cnt == FL then frames[#frames + 1] = acc / FL; acc, cnt = 0, 0 end
    end
    done = done + n
  end
  local mx = 0
  for _, p in ipairs(frames) do if p > mx then mx = p end end
  local db = function(p) return 10 * math.log(p + 1e-30, 10) end
  local gate = math.max(-70, db(mx) - 45)
  local sum, k = 0, 0
  for _, p in ipairs(frames) do if db(p) > gate then sum = sum + p; k = k + 1 end end
  return k > 0 and db(sum / k) or nil, 20 * math.log(peak + 1e-12, 10), #frames
end
local t0 = r.time_precise()
local a_lvl, a_pk, nfr = scan(0)
local b_lvl, b_pk = scan(ipos)
r.DestroyAudioAccessor(aa)
r.ShowConsoleMsg(string.format(
  "IdeaPool level spike (REAPER %s)\n  item time    : level %s dB, peak %.1f dB\n  project time : level %s dB, peak %.1f dB\n  %d frames, %d Hz, %d ch, %.2f s for both scans\n  -> IdeaPool uses %s time.\n\n",
  r.GetAppVersion(), a_lvl and string.format("%.2f", a_lvl) or "none", a_pk, b_lvl and string.format("%.2f", b_lvl) or "none",
  b_pk, nfr, sr, nch, r.time_precise() - t0, (a_pk > -120) and "ITEM" or ((b_pk > -120) and "PROJECT" or "NO (silent?)")))
