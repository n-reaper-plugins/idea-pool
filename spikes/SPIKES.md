# Real-REAPER spikes for IdeaPool

Everything AliasTrack's `spikes/SPIKES.md` lists applies here too (empty MIDI item offsets, P_EXT not copied, GUIDs
in chunks, undo of P_EXT, razor piece identity). Specific to IdeaPool:

| # | Assumption | How to check | If wrong |
|---|---|---|---|
| I1 | A **take audio accessor** reads item time (0 = item start); older versions may read project time | `spike_1_level.lua` on a selected audio item: it reports which time base had signal and the level | `RA.measure` already probes both; if neither works, measure through a track accessor |
| I2 | The level matches GainStageEQ's "average (RMS)" for the same item | Run both on one item (GainStageEQ: time selection = the item) | Compare the frame/gate code, both are in `IPCore` / `GainStageCore` |
| I3 | `EnumProjectMarkers3` returns markers of all ruler lanes, `SetProjectMarker4` renames without moving, `DeleteProjectMarker` removes the right one | Rename an idea with markers; press Keep | Use `SetProjectMarkerByIndex2` / `DeleteProjectMarkerByIndex` |
| I4 | `OnPlayButton` after `SetEditCurPos(…, true, false)` starts at the new cursor | Play on its own | Use `Main_OnCommand(1007)` |
| I5 | Changing `D_VOL` of placed items for loudness matching is not heard as a click during playback | Toggle matching while looping | Ramp is impossible from a script; switch only when stopped |
| I6 | Measuring a 2-minute item stays under ~0.3 s | Stash a long item, watch for a hitch | Measure incrementally over several defer cycles (as GainStageEQ does) |
| I7 | `PCM_Source_BuildPeaks` modes 0/1/2 and `PCM_Source_GetPeaks` buffer layout (all maxima, then all minima, channels interleaved; low 20 bits of the return = peaks read) | Open an idea with a long, never-played file: "reading peaks..." then the waveform | Read with `GetMediaItemTake_Peaks` from a placement instead |
| I8 | ReaImGui draw list (`AddLine`, `AddRectFilled`, `AddText`), `InvisibleButton` + `IsItemActivated/Active/Deactivated` behave like Dear ImGui | Drag in the view; a red "UI:" line = send it | – |
| I9 | Item chunks of MIDI items contain `<SOURCE MIDI ... HASDATA 1 <tpq> QN ... E <delta> <status> <d1> <d2>` | Stash a MIDI item, open it: the notes must match the MIDI editor | Adapt `C.midi_notes` |
| I10 | A new item created from a stored chunk with a kept `POOLEDEVTS` shows the pool's *current* notes | Edit notes in one placement, then Place again | Keep MIDI unpooled for new placements, or refresh the chunk on Save as variant only |

## v0.2.1
| # | Assumption | How to check | If wrong |
|---|---|---|---|
| A1 | `GetTrackStateChunk` shows an `<FXCHAIN` block and `SetTrackStateChunk` with it appended before the final `>` loads the plug-ins on a new track | Press Play on an idea whose track has an instrument / FX: the temporary track must show the same chain | Build the chain with `TrackFX_AddByName` from the names in the block |
| A2 | `I_SOLO = 2` on the temporary tracks mutes everything else; clearing and restoring `I_SOLO` of the others works | Play with a track soloed beforehand; stop: your solo is back | Use `SoloAllTracks(0)` and restore from the saved list |
| A3 | `GetSet_LoopTimeRange` + `GetSetRepeat` save/restore leaves your loop points exactly as they were | Set a loop, Play, Stop, compare | Skip looping (setting is there) |
| A4 | A child track's audio passes through the parent's FX chain; folder depths after creating / removing a sub-lane look right (also: owner is the last child of a folder, owner is already a folder) | Place with "Sub-lane" on a track with FX, in a nested project, then delete the placements | Tell me the structure you see |
| A5 | Item fades and item volume do not affect MIDI events | Put a fade / volume change on a MIDI item driving a synth | Re-enable the handles for MIDI |
| A6 | Temporary tracks, solo and loop changes made without an undo block do not add undo points and do not break the next undo | Play, stop, Ctrl+Z: undoes your last real action | Wrap in a block and delete the point |
| A7 | Deleting a track without an undo point is safe while the transport has just stopped | Stop playback quickly after Play | Delay the cleanup by one defer cycle |
| A8 | `ImGui_BeginChild(ctx, id, 0, h)`, `CollapsingHeader(ctx, label, nil, flags)`, `Selectable`, `Indent` work in your ReaImGui version; draggable borders of the pane table | Open the window | A red "UI:" line = send it |
