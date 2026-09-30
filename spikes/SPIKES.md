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
