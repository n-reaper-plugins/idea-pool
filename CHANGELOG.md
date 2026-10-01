# Changelog

## 0.2.1 – three panes, play on its own
* **Layout**: three resizable panes – preview (50%), stash + ideas list, idea actions + settings (collapsible).
* **Play on its own** replaces "Audition at cursor": temporary tracks (one per original track, FX chain copied), solo,
  loop, A/B switching live, full cleanup on stop / close / leftovers after a crash or undo; no undo points.
* **Frozen placements are grey** (items and placement item); items of placements are coloured like their idea (option);
  originals restored when the option is switched off.
* **Rename in the ideas list**; renaming an idea renames the markers that place it.
* **Markers simplified**: marker name = idea name (no prefix); **Keep** replaces Commit and removes the marker; Detach removes it too.
* **MIDI items**: no fade / gain handles, no fades written, excluded from loudness matching.
* **Sub-lanes** (option): items on a child track under each original track (through its FX chain), created on demand,
  removed when empty, folder depths restored; MIDI stays on the original track.
* 498 offline checks (core 185, sync 239, UI 59, bundle 15).

## 0.2.0 – the idea view
* Waveform view of the active variant in the window: one row per track, peaks read from REAPER's .reapeaks of the
  file (built in the background, a little per frame), fade shapes drawn on the waveform, gain label, playhead.
* Mouse editing: move, trim either edge (left edge moves the file offset; limited to the file), fade handles, gain by
  the top edge; one undo step per drag; optional snap to 1/16 at the tempo where the idea was stashed.
* Zoom (− / + / Fit) and scroll; hover readout.
* MIDI items: notes drawn in their box, and a larger read-only piano roll with octave labels for the selected item
  (notes parsed from the stored item chunk, so it works without any placement).
* Ideas remember the tempo at the stash position.
* 362 offline checks (core 166, sync 134, UI 47, bundle 15).

## 0.1.0 – first version
* Stash selected items (any tracks) as an idea: copy (default), link as first placement, or remove.
* Ideas keep variants A, B, …: duplicate, switch (items updated in place), delete, save a placement as a variant,
  numeric editing of start / length / fades / gain / mute.
* Linked placements on one IDEAS track, built on the AliasTrack v0.1.0 engine (move, trim, split, copy, cuts,
  adoption, MIXED with Apply / Revert); Freeze / Unfreeze / Detach per placement; placing on the original tracks,
  on the selected track, or at the original position.
* Auditions driven by markers named like an idea (regions trim), Audition at cursor (+ play), Commit.
* Loudness-matched A/B: 50 ms gated-RMS frames per item (GainStageEQ's method), stored in source time so trims and
  moves need no re-measuring; reference variant; volumes restored when matching is off.
* Undo modes, debounced live sync, freeze all, detach all; 262° theme; macOS installer; 268 offline checks.
