# Real-REAPER spikes for IdeaPool

Everything AliasTrack's `spikes/SPIKES.md` lists applies here too (empty MIDI item offsets, P_EXT not copied, GUIDs
in chunks, undo of P_EXT, razor piece identity). Specific to IdeaPool:

| # | Assumption | How to check | If wrong |
|---|---|---|---|
| I1 | A **take audio accessor** reads item time (0 = item start); older versions may read project time | `spike_1_level.lua` on a selected audio item: it reports which time base had signal and the level | `RA.measure` already probes both; if neither works, measure through a track accessor |
| I2 | The level matches GainStageEQ's "average (RMS)" for the same item | Run both on one item (GainStageEQ: time selection = the item) | Compare the frame/gate code, both are in `IPCore` / `GainStageCore` |
| I3 | `EnumProjectMarkers3` returns markers of all ruler lanes, `SetProjectMarker4` renames without moving | Commit an audition in a project with marker lanes | Use `SetProjectMarkerByIndex2` |
| I4 | `OnPlayButton` after `SetEditCurPos(…, true, false)` starts at the new cursor | Audition at cursor | Use `Main_OnCommand(1007)` |
| I5 | Changing `D_VOL` of placed items for loudness matching is not heard as a click during playback | Toggle matching while looping | Ramp is impossible from a script; switch only when stopped |
| I6 | Measuring a 2-minute item stays under ~0.3 s | Stash a long item, watch for a hitch | Measure incrementally over several defer cycles (as GainStageEQ does) |
| I7 | `PCM_Source_BuildPeaks` modes 0/1/2 and `PCM_Source_GetPeaks` buffer layout (all maxima, then all minima, channels interleaved; low 20 bits of the return = peaks read) | Open an idea with a long, never-played file: "reading peaks..." then the waveform | Read with `GetMediaItemTake_Peaks` from a placement instead |
| I8 | ReaImGui draw list (`AddLine`, `AddRectFilled`, `AddText`), `InvisibleButton` + `IsItemActivated/Active/Deactivated` behave like Dear ImGui | Drag in the view; a red "UI:" line = send it | – |
| I9 | Item chunks of MIDI items contain `<SOURCE MIDI ... HASDATA 1 <tpq> QN ... E <delta> <status> <d1> <d2>` | Stash a MIDI item, open it: the notes must match the MIDI editor | Adapt `C.midi_notes` |
| I10 | A new item created from a stored chunk with a kept `POOLEDEVTS` shows the pool's *current* notes | Edit notes in one placement, then Place again | Keep MIDI unpooled for new placements, or refresh the chunk on Save as variant only |
