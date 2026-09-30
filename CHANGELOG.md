# Changelog

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
