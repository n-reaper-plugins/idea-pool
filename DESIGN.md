# IdeaPool design (v0.2.0)

## Model
| IdeaPool | AliasTrack equivalent | Notes |
|---|---|---|
| **idea** (card) | group | name, colour, the tracks it came from (*slots*), variants, active variant, loudness settings |
| **variant** A, B … | def | items in idea-local time, each with its chunk, slot and level frames |
| **placement** | alias instance | empty MIDI item on the IDEAS track; window `{pos, len, offs}` onto the **active** variant |
| **audition** | – | a placement owned by a marker: follows it, disappears with it, **Commit** keeps it |
| **frozen** placement | – | not synced in either direction until **Unfreeze** |

All placements share **one** IDEAS track. A copied placement (tags are not copied) is recognised by the `[id]` at the
end of its take name, `Riff · B [3]`, and by the same-anchor rule for split pieces (as in AliasTrack).

Each placement has its own **track map** (slot → track). Placing "on the selected track" maps slot 1 there and keeps
the other slots' distance in track order. Existing placements never move when a new mapping is used; copies use the
mapping of the last placement made.

## Your decisions
* No EQ: per-item processing stays in your own take FX, which travel inside the stored chunks.
* Project only: the pool is JSON in the IDEAS track's P_EXT (saved with the .rpp, part of undo).
* Linked placements with **Freeze** and **Detach**.
* Stash defaults to **copy**; the setting switches it to "become a placement" or "remove".
* Multi-item ideas use the AliasTrack logic: moves, trims, splits, cuts of items cut the placement, adoption of pieces.
* Audition in context uses markers, PrototypeSequence-style: marker name = idea name, case and spaces ignored, region = trim,
  the marker wins over a hand move.
* Loudness-matched A/B using GainStageEQ's level method (50 ms frames, gate 45 dB below the loudest frame and -70 dB absolute).

## Loudness matching, in detail
* Each item is measured once, at stash / Save as variant / **Measure**, through a take audio accessor: 50 ms mean-power frames.
* Frames are stored in **source time** (`s0` = take offset when measured, playrate). So when an item is moved, trimmed
  or re-faded, the variant's level is recomputed from the stored frames without reading audio again. Only material
  that was never audible needs a new **Measure**; the window shows "(NN% measured)" then.
* Variant level = gated average of the summed item powers × (item vol × take vol)². Items are assumed uncorrelated
  (powers add). Fades and take FX are not included.
* With matching on, variant *v* plays with `ref - level(v)` dB extra item volume (limited to ±24 dB). A volume edit made
  while matching is stored without that extra gain, so turning matching off gives the real volumes back.

## Undo
Same as AliasTrack. By default syncs add no undo points: your action is the undo step and the result is derived again.
Optionally every sync is a step ("IdeaPool: sync"), and syncing pauses after you undo one. Every button is one step.

## Shared code with AliasTrack, and how to organise the repos
**Now (v0.1.0): a copy.** `IPCore.lua` and `IPReaper.lua` start as copies of AliasTrack's `ATCore` / `ATReaper` v0.1.0
(the file headers say so), plus IdeaPool sections. The copy is kept honest by a test: IdeaPool's `test_core` runs
AliasTrack's entire core suite unchanged against `IPCore`, so a divergence in the shared part fails the build.

**Later: one small shared library, vendored by version.**
```
n-reaper-plugins/nlib            (own repo, own tests, tagged v0.x)
  nlib/window.lua    visible(), snapshots, classify(), find_cuts(), split_children(), def_cut()
  nlib/tracks.lua    parents(), common_folder(), is_desc()
  nlib/json.lua      tiny JSON
  nlib/chunk.lua     refresh_guids()
  nlib/level.lua     50 ms gated-RMS frames (from GainStageEQ)
  nlib/theme.lua     the 262° THEME + push_theme
  testkit/           mock_reaper.lua, imgui_stub.lua, t.lua
<plugin>/vendor/nlib/            a pinned copy + VERSION file, refreshed by tools/vendor.sh <tag>
```
* **Vendored copy, not git submodules**: contributors clone one repo and everything works; ReaPack still ships the one
  bundled file, and each plugin moves to a new nlib version when it is ready (no version skew at runtime, because every
  ReaScript runs in its own Lua state and carries its own bundled copy).
* **Not a separate ReaPack "library" package**: a user updating one plugin would change the library under the others.
* `tools/vendor.sh` copies `nlib` at a tag into `vendor/nlib/` and writes the tag into `vendor/nlib/VERSION`;
  `build.lua` bundles vendor modules like its own; CI (GitHub Actions) runs `run_tests.sh` in every repo and
  checks that `vendor/nlib` matches the tag it claims.
* Order: extract `window`, `json`, `chunk`, `theme` and the testkit first (used by both), `level` when GainStageEQ adopts it.

## The idea view (v0.2.0)
* Pure geometry lives in `IPCore` and is tested: time <-> pixels, zoom range, grid step, snapping, hit zones
  (fade handles, edges, gain edge, body), the effect of each drag on a member (limits: minimum length, file start and
  end, fades never longer than the item), peak columns, the MIDI chunk parser and member-local notes.
* Peaks: `PCM_Source_BuildPeaks` is stepped a little per frame from `tick` (10 ms budget), then the whole file is read
  once at 200 peaks/s (channels folded) and cached per file. Columns are picked from that overview in source time, so
  trims and playrate need no new reads. Files longer than 15 minutes show their first 15.
* MIDI: notes come from the stored chunk (`HASDATA` ticks per QN, `E`/`e` events, `X` deltas counted), placed with
  the tempo recorded at stash. Tempo changes inside an idea are not drawn.
* A drag is previewed without writing anything; releasing it writes the def once (one undo step), and the sync
  updates every linked placement.

## Limits in v0.2.0
* One active variant per idea for all linked placements (no per-placement variant pin yet).
* Level ignores fades and take FX; MIDI items are not measured.
* Frozen mode (freeze all) shows the pool but not MIXED states.

## Open questions
1. **Per-placement variant pin**: should a placement be able to stay on B while others switch to A?
2. **Solo audition** (hear an idea on its own, not in context): worth a hidden audition track, or is the marker enough?
3. **Commit**: rename the marker to "(placed) …" (now), delete it, or leave it and just stop matching?
4. **Tempo**: store ideas in beats and stretch on placing?
5. **Fade shapes**: the view draws linear fades; show REAPER's curve shapes, and let a right-click pick one?
6. **Note editing** in the piano roll (move / add / delete), or keep it read-only and edit in placements?
7. **nlib extraction**: start right after IdeaPool's first real-REAPER test, or wait for a third plugin to need it?
